--[[
  KNUCK syscall dispatcher
  ========================
  Processes yield {"syscall", name, args}; the scheduler calls handle().
  Handlers either return a result (process resumes) or block the process
  (proc.wait -> resumed later by an event).

  The syscall registry also drives the process sandbox env (proc.lua builds
  named wrappers from it).
]]

return function(K)
  local M = {}

  local syscalls = {}
  local proc_mod = nil

  -- Sentinel for nil in packed syscall results. Lua tables can't hold a nil
  -- in the middle of an array without breaking #t / table.unpack, so nil
  -- results are stored as this sentinel and converted back in the wrapper.
  local NIL = {}
  local function pack(...)
    local t = { n = select("#", ...) }
    for i = 1, t.n do
      local v = select(i, ...)
      t[i] = (v == nil) and NIL or v
    end
    return t
  end
  -- Expose the nil sentinel so the process wrapper (proc.lua) can convert it
  -- back to nil when unpacking syscall results.
  M.NIL = NIL

  function M.init(K)
    proc_mod = K.proc
  end

  -- Register a syscall handler
  function M.register(name, handler)
    syscalls[name] = handler
  end

  -- List of registered syscall names (for building process env)
  function M.names()
    local out = {}
    for name in pairs(syscalls) do out[#out + 1] = name end
    return out
  end

  -- Handle a syscall request from a process
  function M.handle(proc, name, args)
    local handler = syscalls[name]
    if not handler then
      proc_mod.die(proc, "SIGSYS", "unknown syscall: " .. tostring(name))
      return
    end
    -- Pack all handler return values (preserving nil, err) into a table.
    -- pcall wraps so an error kills the process (SIGSYS).
    local ok, packed = pcall(function()
      return pack(handler(proc, table.unpack(args or {})))
    end)
    if not ok then
      proc_mod.die(proc, "SIGSYS", name .. ": " .. tostring(packed))
      return
    end
    -- If the handler blocked the process, it is now "waiting"; do not resume.
    -- Otherwise resume with the packed results.
    if proc.state == "running" then
      K.sched.resume(proc, packed)
    end
  end

  -- ============================================================
  -- Syscall handlers
  -- ============================================================

  -- proc identity
  M.register("getpid", function(proc) return proc.pid end)
  M.register("getppid", function(proc) return proc.ppid end)
  M.register("getuid", function(proc) return proc.uid end)
  M.register("geteuid", function(proc) return proc.euid end)
  M.register("getgid", function(proc) return proc.gid end)
  M.register("getegid", function(proc) return proc.egid end)
  M.register("getpgrp", function(proc) return proc.pgid end)
  M.register("getcwd", function(proc) return proc.cwd end)

  -- getenv / setenv: process environment variables
  M.register("getenv", function(proc, name)
    return proc.environ and proc.environ[name]
  end)
  M.register("setenv", function(proc, name, value)
    if not name then return false end
    if value == nil then
      if proc.environ then proc.environ[name] = nil end
    else
      if not proc.environ then proc.environ = {} end
      proc.environ[name] = tostring(value)
    end
    return true
  end)

  -- exit
  M.register("exit", function(proc, code)
    proc_mod.exit(proc, code or 0)
  end)

  -- sleep (blocking)
  M.register("sleep", function(proc, secs)
    local id = K.env.os.startTimer(secs or 0)
    K.sched.wait(proc, "timer", id)
  end)

  -- print: write args to stdout with a newline
  M.register("print", function(proc, ...)
    local parts = { ... }
    for i, v in ipairs(parts) do parts[i] = tostring(v) end
    local line = table.concat(parts, "\t") .. "\n"
    local fd = proc.fds[1]
    if not fd then return nil, "no stdout" end
    return K.vfs.write(proc, fd, line)
  end)

  -- clear: clear the terminal screen (userspace has no term access)
  M.register("clear", function(proc)
    K.env.term.clear()
    K.env.term.setCursorPos(1, 1)
    return true
  end)

  -- diag: report terminal/tty state so the shell can self-diagnose rendering.
  -- Returns { tty, active, cx, cy, w, h, out } where out is the type of fd 1.
  M.register("diag", function(proc)
    local cx, cy = 0, 0
    local w, h = 0, 0
    local t = K.env.term
    if t and t.getCursorPos then cx, cy = t.getCursorPos() end
    if t and t.getSize then w, h = t.getSize() end
    local out = "?"
    if proc and proc.fds and proc.fds[1] then
      out = tostring(proc.fds[1].type or "?")
    end
    local res = {
      tty = (proc and proc.tty) or 1,
      active = K.tty and K.tty.active_id() or 1,
      cx = cx, cy = cy, w = w, h = h, out = out,
    }
    if K.log then
      K.log("diag: tty=" .. tostring(res.tty) .. " active=" .. tostring(res.active)
        .. " cur=" .. tostring(cx) .. "," .. tostring(cy)
        .. " size=" .. tostring(w) .. "x" .. tostring(h)
        .. " out=" .. tostring(out))
    end
    return res
  end)

  -- spawn a child process
  M.register("spawn", function(proc, path, ...)
    local args = { ... }
    -- optional trailing fds table: { [0]=fdnum, [1]=fdnum, [2]=fdnum }
    -- wires the child's stdin/stdout/stderr to the parent's open fds
    -- (shares the underlying open file description, like dup).
    local fds = nil
    if type(args[#args]) == "table" then
      fds = args[#args]
      args[#args] = nil
    end
    -- optional trailing boolean: system flag (full env, root-only)
    local system = false
    if type(args[#args]) == "boolean" and args[#args] then
      system = true
      args[#args] = nil
    end
    if system and proc.uid ~= 0 then
      return nil, "permission denied: only root may spawn system processes"
    end
    return proc_mod.spawn(path, proc.pid, proc.uid, proc.gid, args, proc.tty, fds, proc, system)
  end)

  -- exec(path, ...) — execve(2) analog: replace the current process image.
  -- On success never returns; on failure returns nil, err (old image keeps
  -- running). Applies setuid/setgid bits and resets signal handlers (POSIX).
  M.register("exec", function(proc, path, ...)
    local args = { ... }
    local resolved = K.vfs.resolve(proc, path)
    if not resolved then return nil, "no such file" end
    local ino = K.vfs.get_inode(resolved)
    if not ino then return nil, "no such file" end
    if ino.type ~= "file" then return nil, "not a file" end
    if not K.fs.check_access(proc, ino, "x") then
      return nil, "permission denied"
    end
    -- setuid/setgid bits (04000=0x800, 02000=0x400 octal)
    if K.bit.band(ino.mode, 0x800) ~= 0 then proc.euid = ino.uid end
    if K.bit.band(ino.mode, 0x400) ~= 0 then proc.egid = ino.gid end
    -- fresh sandbox env + load the new image (preserve system flag)
    local env = proc_mod.make_env(proc.system)
    local fn, err = K.vfs.loadfile(resolved, env)
    if not fn then return nil, err end
    proc.co = coroutine.create(function()
      return fn(table.unpack(args))
    end)
    proc.env = env
    proc.name = path
    -- POSIX exec semantics: reset signal handlers/mask to default
    proc.sig.handlers = {}
    proc.sig.pending = {}
    proc.sig.blocked = {}
    proc.sig._pending_result = nil
    -- Enqueue with nil result. handle() sees state ~= "running" and skips
    -- its own resume, so the process runs the new image exactly once.
    K.sched.resume(proc, nil)
  end)

  -- waitpid (blocking)
  M.register("waitpid", function(proc, pid, opt)
    if opt == "nohang" then
      local child = proc_mod.find_child(proc.pid, pid)
      if child and child.state == "zombie" then
        return proc_mod.reap(child)
      end
      return nil
    end
    -- blocking: wait for a child to become zombie
    local child = proc_mod.find_child(proc.pid, pid)
    if child and child.state == "zombie" then
      return proc_mod.reap(child)
    end
    K.sched.wait(proc, "child", proc.pid)
  end)

  -- kill
  M.register("kill", function(proc, pid, sig)
    return proc_mod.kill(proc, pid, sig)
  end)

  -- signal(sig, handler|nil|"ignore") — sigaction(2) analog
  M.register("signal", function(proc, sig, handler)
    if sig == 9 or sig == 19 then
      return nil, "cannot change handler for SIGKILL/SIGSTOP"
    end
    if handler == nil then
      proc.sig.handlers[sig] = "default"
    elseif handler == "ignore" then
      proc.sig.handlers[sig] = "ignore"
    elseif type(handler) == "function" then
      proc.sig.handlers[sig] = handler
    else
      return nil, "invalid handler"
    end
    return true
  end)

  -- sigprocmask(how, set) — "block"|"unblock"|"set". KILL/STOP never blockable.
  M.register("sigprocmask", function(proc, how, set)
    if how == "block" then
      for _, s in ipairs(set or {}) do
        if s ~= 9 and s ~= 19 then proc.sig.blocked[s] = true end
      end
    elseif how == "unblock" then
      for _, s in ipairs(set or {}) do
        proc.sig.blocked[s] = nil
      end
    elseif how == "set" then
      proc.sig.blocked = {}
      for _, s in ipairs(set or {}) do
        if s ~= 9 and s ~= 19 then proc.sig.blocked[s] = true end
      end
    else
      return nil, "invalid how"
    end
    return true
  end)

  -- alarm(secs) — SIGALRM after secs; 0/nil cancels the pending alarm
  M.register("alarm", function(proc, secs)
    if proc.sig._alarm_timer then
      K.env.os.cancelTimer(proc.sig._alarm_timer)
      proc_mod.alarm_timers[proc.sig._alarm_timer] = nil
      proc.sig._alarm_timer = nil
    end
    if secs and secs > 0 then
      local id = K.env.os.startTimer(secs)
      proc.sig._alarm_timer = id
      proc_mod.alarm_timers[id] = proc
    end
    return true
  end)

  -- sched_yield
  M.register("sched_yield", function(proc)
    K.sched.enqueue(proc)
  end)

  -- getpriority / setpriority
  M.register("getpriority", function(proc, pid)
    local p = proc_mod.lookup(pid or proc.pid)
    if not p then return nil, "no such process" end
    return p.priority
  end)
  M.register("setpriority", function(proc, pid, prio)
    local target = proc_mod.lookup(pid or proc.pid)
    if not target then return nil, "no such process" end
    if proc.uid ~= 0 and proc.uid ~= target.uid then
      return nil, "permission denied"
    end
    target.priority = prio or 0
    return true
  end)

  -- time / clock
  M.register("time", function() return K.env.os.time() end)
  M.register("clock", function() return K.env.os.clock() end)

  -- clock_gettime(clock) -> secs, nsecs. CLOCK_REALTIME=0, CLOCK_MONOTONIC=1.
  M.register("clock_gettime", function(proc, clock)
    if clock == 1 then  -- CLOCK_MONOTONIC
      local s = K.env.os.clock()
      local secs = math.floor(s)
      return secs, math.floor((s - secs) * 1e9)
    end
    -- CLOCK_REALTIME (default)
    return K.env.os.time(), 0
  end)

  -- reboot() / halt() — power control via CC os API
  M.register("reboot", function(proc)
    if proc.uid ~= 0 then return nil, "permission denied" end
    if K.env.os.reboot then K.env.os.reboot() end
    return true
  end)
  M.register("halt", function(proc)
    if proc.uid ~= 0 then return nil, "permission denied" end
    if K.env.os.shutdown then K.env.os.shutdown() end
    return true
  end)

  -- setpgid(pid, pgid) — set process group
  M.register("setpgid", function(proc, pid, pgid)
    local target = proc_mod.lookup(pid or proc.pid)
    if not target then return nil, "no such process" end
    if proc.uid ~= 0 and proc.uid ~= target.uid then
      return nil, "permission denied"
    end
    target.pgid = pgid or target.pid
    return true
  end)

  -- sched_setscheduler(pid?, policy) — "rr" | "fifo" | "other"
  M.register("sched_setscheduler", function(proc, pid, policy)
    local target = proc_mod.lookup(pid or proc.pid)
    if not target then return nil, "no such process" end
    if proc.uid ~= 0 and proc.uid ~= target.uid then
      return nil, "permission denied"
    end
    if policy ~= "rr" and policy ~= "fifo" and policy ~= "other" then
      return nil, "invalid policy"
    end
    target.sched_policy = policy
    return true
  end)

  -- insmod(path) — load a kernel module at runtime (root only)
  M.register("insmod", function(proc, path)
    if proc.uid ~= 0 then return nil, "permission denied" end
    if not path then return nil, "no path" end
    local ok, mod = pcall(K.loader.load, path, K)
    if not ok then return nil, tostring(mod) end
    local name = path:match("([^/]+)%.lua$") or path
    K.modules[name] = mod
    K.module_paths = K.module_paths or {}
    K.module_paths[name] = path
    return true
  end)

  -- rmmod(name) — unload a kernel module (root only)
  M.register("rmmod", function(proc, name)
    if proc.uid ~= 0 then return nil, "permission denied" end
    if not K.modules[name] then return nil, "no such module" end
    K.modules[name] = nil
    if K.module_paths and K.module_paths[name] then
      K.loader.unload(K.module_paths[name])
      K.module_paths[name] = nil
    end
    return true
  end)

  -- chdir
  M.register("chdir", function(proc, path)
    local resolved = K.vfs.resolve(proc, path)
    local ino = K.vfs.get_inode(resolved)
    if not ino or ino.type ~= "dir" then return nil, "not a directory" end
    if not K.fs.check_access(proc, ino, "x") then return nil, "permission denied" end
    proc.cwd = resolved
    return true
  end)

  -- ============================================================
  -- File syscalls
  -- ============================================================

  -- Allocate a new fd number for a process
  local function alloc_fd(proc, fd)
    for i = 3, 1024 do
      if not proc.fds[i] then
        proc.fds[i] = fd
        return i
      end
    end
    return nil
  end

  M.register("open", function(proc, path, flags, mode)
    -- Normalize flags: accept POSIX numeric flags (O_RDONLY=0, O_WRONLY=1,
    -- O_RDWR=2, O_APPEND=0x400) or string modes ("r"/"w"/"a"). CraftOS
    -- fs.open only understands string modes.
    if type(flags) == "number" then
      local n = flags
      local acc = n % 8
      if acc == 1 then flags = "w"
      elseif acc == 2 then flags = "r"
      else flags = "r" end
      if math.floor(n / 0x400) % 2 == 1 then flags = flags .. "a" end
    end
    local fd, err = K.vfs.open(proc, path, flags or "r", mode, function(f)
      local n = alloc_fd(proc, f)
      if not n then return nil, "too many open files" end
      return n
    end)
    if not fd then return nil, err end
    local n = alloc_fd(proc, fd)
    if not n then return nil, "too many open files" end
    return n
  end)

  M.register("close", function(proc, fdnum)
    local fd = proc.fds[fdnum]
    if not fd then return nil, "bad fd" end
    K.vfs.close(fd)
    proc.fds[fdnum] = nil
    return true
  end)

  -- dup(fdnum) — duplicate an fd to the lowest free number (shares the
  -- underlying open file description: same offset, same socket).
  M.register("dup", function(proc, fdnum)
    local fd = proc.fds[fdnum]
    if not fd then return nil, "bad fd" end
    local n = alloc_fd(proc, fd)
    if not n then return nil, "too many open files" end
    return n
  end)

  -- dup2(fdnum, newfd) — duplicate fd to a specific number, closing newfd
  -- first if it is open. Returns newfd on success.
  M.register("dup2", function(proc, fdnum, newfd)
    local fd = proc.fds[fdnum]
    if not fd then return nil, "bad fd" end
    if newfd == fdnum then return newfd end
    local old = proc.fds[newfd]
    if old then
      K.vfs.close(old)
      proc.fds[newfd] = nil
    end
    proc.fds[newfd] = fd
    return newfd
  end)

  M.register("read", function(proc, fdnum, n)
    local fd = proc.fds[fdnum]
    if not fd then return nil, "bad fd" end
    return K.vfs.read(proc, fd, n)
  end)

  M.register("write", function(proc, fdnum, data)
    local fd = proc.fds[fdnum]
    if not fd then return nil, "bad fd" end
    return K.vfs.write(proc, fd, data)
  end)

  M.register("lseek", function(proc, fdnum, offset, whence)
    local fd = proc.fds[fdnum]
    if not fd then return nil, "bad fd" end
    return K.vfs.lseek(fd, offset or 0, whence or "set")
  end)

  M.register("stat", function(proc, path)
    return K.vfs.stat(proc, path)
  end)

  M.register("fstat", function(proc, fdnum)
    local fd = proc.fds[fdnum]
    if not fd then return nil, "bad fd" end
    local ino = fd.path and K.vfs.get_inode(fd.path)
    if ino then
      return { type = ino.type, mode = ino.mode, uid = ino.uid, gid = ino.gid,
        nlink = ino.nlink, size = ino.size or 0, path = fd.path }
    end
    -- fd without a path (console, pipe, device, socket)
    local mode = 0x1B6
    local ftype = fd.type
    if fd.type == "pipe_r" or fd.type == "pipe_w" then
      ftype = "fifo"
    elseif fd.type == "file" then
      mode = 0x1A4
    end
    return { type = ftype, mode = mode, uid = proc.uid, gid = proc.gid, nlink = 1, size = 0 }
  end)

  M.register("readdir", function(proc, path)
    return K.vfs.readdir(proc, path)
  end)

  M.register("mkdir", function(proc, path, mode)
    return K.vfs.mkdir(proc, path, mode)
  end)

  M.register("rmdir", function(proc, path)
    return K.vfs.rmdir(proc, path)
  end)

  M.register("unlink", function(proc, path)
    return K.vfs.unlink(proc, path)
  end)

  M.register("rename", function(proc, old, new)
    return K.vfs.rename(proc, old, new)
  end)

  M.register("chmod", function(proc, path, mode)
    return K.vfs.chmod(proc, path, mode)
  end)

  M.register("chown", function(proc, path, uid, gid)
    return K.vfs.chown(proc, path, uid, gid)
  end)

  M.register("chgrp", function(proc, path, gid)
    return K.vfs.chown(proc, path, nil, gid)
  end)

  M.register("symlink", function(proc, target, path)
    return K.vfs.symlink(proc, target, path)
  end)

  M.register("readlink", function(proc, path)
    return K.vfs.readlink(proc, path)
  end)

  M.register("link", function(proc, old, new)
    return K.vfs.link(proc, old, new)
  end)

  M.register("chroot", function(proc, path)
    return K.vfs.chroot(proc, path)
  end)

  M.register("mount", function(proc, source, target, fstype, flags)
    return K.vfs.mount(proc, source, target, fstype, flags)
  end)

  M.register("umount", function(proc, target)
    return K.vfs.umount(proc, target)
  end)

  M.register("umask", function(proc, mask)
    return K.vfs.umask(proc, mask)
  end)

  -- ============================================================
  -- IPC syscalls
  -- ============================================================

  -- pipe() -> read_fd, write_fd
  M.register("pipe", function(proc)
    local rfd, wfd = K.ipc.pipe()
    local rn = alloc_fd(proc, rfd)
    local wn = alloc_fd(proc, wfd)
    if not rn or not wn then return nil, "too many open files" end
    return rn, wn
  end)

  -- mkfifo(path, mode)
  M.register("mkfifo", function(proc, path, mode)
    return K.vfs.mkfifo(proc, path, mode)
  end)

  -- select(readfds, writefds, exceptfds, timeout) -> r, w, e
  M.register("fdselect", function(proc, readfds, writefds, exceptfds, timeout)
    local r, w, e = {}, {}, {}
    local function check()
      r, w, e = {}, {}, {}
      for _, n in ipairs(readfds or {}) do
        local fd = proc.fds[n]
        if fd and K.ipc.fd_readable(fd) then r[#r + 1] = n end
      end
      for _, n in ipairs(writefds or {}) do
        local fd = proc.fds[n]
        if fd and K.ipc.fd_writable(fd) then w[#w + 1] = n end
      end
    end
    check()
    if #r > 0 or #w > 0 then return r, w, e end
    if timeout and timeout > 0 then
      -- block once for the full timeout; on wake, re-check
      local id = K.env.os.startTimer(timeout)
      K.sched.wait(proc, "timer", id, function()
        check()
        return { r, w, e }
      end)
    elseif not timeout then
      -- block indefinitely until fd activity; on wake, re-check
      K.ipc.wait_fd_ready(proc, function()
        check()
        return { r, w, e }
      end)
    end
    return r, w, e
  end)

  -- poll(fds, timeout) -> ready fds
  M.register("poll", function(proc, fds, timeout)
    local ready = {}
    local function check()
      ready = {}
      for _, spec in ipairs(fds or {}) do
        local n = spec.fd
        local fd = proc.fds[n]
        local events = 0
        if fd and K.ipc.fd_readable(fd) then events = K.bit.bor(events, 1) end  -- POLLIN
        if fd and K.ipc.fd_writable(fd) then events = K.bit.bor(events, 4) end  -- POLLOUT
        if events ~= 0 then ready[#ready + 1] = { fd = n, revents = events } end
      end
    end
    check()
    if #ready > 0 then return ready end
    if timeout and timeout > 0 then
      local id = K.env.os.startTimer(timeout)
      K.sched.wait(proc, "timer", id, function()
        check()
        return ready
      end)
    elseif not timeout then
      K.ipc.wait_fd_ready(proc, function()
        check()
        return ready
      end)
    end
    return ready
  end)

  -- socket(domain, type, proto) -> fd
  M.register("socket", function(proc, domain, socktype, proto)
    local fd = K.ipc.socket(domain, socktype, proto)
    local n = alloc_fd(proc, fd)
    if not n then return nil, "too many open files" end
    return n
  end)

  -- bind(fd, path)
  M.register("bind", function(proc, fdnum, path)
    local fd = proc.fds[fdnum]
    if not fd then return nil, "bad fd" end
    return K.ipc.socket_bind(proc, fd, path)
  end)

  -- listen(fd, backlog)
  M.register("listen", function(proc, fdnum, backlog)
    local fd = proc.fds[fdnum]
    if not fd then return nil, "bad fd" end
    return K.ipc.socket_listen(proc, fd, backlog)
  end)

  -- accept(fd) -> new fd
  M.register("accept", function(proc, fdnum)
    local fd = proc.fds[fdnum]
    if not fd then return nil, "bad fd" end
    local connfd = K.ipc.socket_accept(proc, fd, function(cfd)
      local n = alloc_fd(proc, cfd)
      if not n then return nil, "too many open files" end
      return n
    end)
    if not connfd then return nil end
    local n = alloc_fd(proc, connfd)
    if not n then return nil, "too many open files" end
    return n
  end)

  -- connect(fd, path)
  M.register("connect", function(proc, fdnum, path)
    local fd = proc.fds[fdnum]
    if not fd then return nil, "bad fd" end
    return K.ipc.socket_connect(proc, fd, path)
  end)

  -- send(fd, data)
  M.register("send", function(proc, fdnum, data, flags)
    local fd = proc.fds[fdnum]
    if not fd then return nil, "bad fd" end
    return K.ipc.socket_send(proc, fd, data, flags)
  end)

  -- recv(fd, n, flags) — flags: MSG_DONTWAIT=1, MSG_PEEK=2
  M.register("recv", function(proc, fdnum, n, flags)
    local fd = proc.fds[fdnum]
    if not fd then return nil, "bad fd" end
    return K.ipc.socket_recv(proc, fd, n, flags)
  end)

  -- sendto(fd, data, dest_ip, dest_port)  (AF_MODEM)
  M.register("sendto", function(proc, fdnum, data, dest_ip, dest_port)
    local fd = proc.fds[fdnum]
    if not fd then return nil, "bad fd" end
    return K.ipc.socket_sendto(proc, fd, data, dest_ip, dest_port)
  end)

  -- recvfrom(fd) -> data, src_ip, src_port  (AF_MODEM)
  M.register("recvfrom", function(proc, fdnum)
    local fd = proc.fds[fdnum]
    if not fd then return nil, "bad fd" end
    return K.ipc.socket_recvfrom(proc, fd)
  end)

  -- shutdown(fd, how) — "read" | "write" | "both"
  M.register("shutdown", function(proc, fdnum, how)
    local fd = proc.fds[fdnum]
    if not fd then return nil, "bad fd" end
    if not fd.sock then return nil, "not a socket" end
    return K.ipc.socket_shutdown(fd, how)
  end)

  -- getsockname(fd)
  M.register("getsockname", function(proc, fdnum)
    local fd = proc.fds[fdnum]
    if not fd then return nil, "bad fd" end
    return fd.sock.path
  end)

  -- getpeername(fd)
  M.register("getpeername", function(proc, fdnum)
    local fd = proc.fds[fdnum]
    if not fd then return nil, "bad fd" end
    return fd.sock.peer
  end)

  -- setsockopt / getsockopt (SO_BROADCAST, SO_REUSEADDR, SO_RCVTIMEO; HTTP options)
  -- HTTP level = 2: METHOD=1 (GET|POST), HEADERS=2 (table), BODY=3 (string)
  M.register("setsockopt", function(proc, fdnum, level, opt, val)
    local fd = proc.fds[fdnum]
    if not fd then return nil, "bad fd" end
    if level == 1 then  -- SOL_SOCKET
      if opt == 2 then  -- SO_REUSEADDR
        if fd.sock then fd.sock.reuseaddr = val == true or val == 1 end
        return true
      elseif opt == 20 then  -- SO_RCVTIMEO (seconds)
        local t = tonumber(val)
        if t and t < 0 then return nil, "invalid timeout" end
        if fd.sock then fd.sock.rcvtimeo = t or 0 end
        return true
      elseif opt == 6 then  -- SO_BROADCAST
        if fd.sock then fd.sock.broadcast = val == true or val == 1 end
        return true
      end
    end
    if fd.sock and fd.sock.domain == "http" and level == 2 then
      if opt == 1 then fd.sock.http_method = tostring(val or "GET"):upper(); return true
      elseif opt == 2 then fd.sock.http_headers = val or {}; return true
      elseif opt == 3 then fd.sock.http_body = val; return true end
    end
    return true
  end)
  M.register("getsockopt", function(proc, fdnum, level, opt)
    local fd = proc.fds[fdnum]
    if not fd then return nil, "bad fd" end
    if level == 1 and fd.sock then  -- SOL_SOCKET
      if opt == 2 then  -- SO_REUSEADDR
        return fd.sock.reuseaddr and 1 or 0
      elseif opt == 20 then  -- SO_RCVTIMEO
        return fd.sock.rcvtimeo or 0
      elseif opt == 6 then  -- SO_BROADCAST
        return fd.sock.broadcast and 1 or 0
      end
    end
    return nil
  end)

  -- ============================================================
  -- Virtual terminals (tty)
  -- ============================================================

  -- ioctl(fd, request, arg): tty_switch switches the active terminal;
  -- console_mode switches /dev/console between "cooked" (lines) and "raw"
  -- (events) input.
  M.register("ioctl", function(proc, fdnum, request, arg)
    if request == "tty_switch" then
      return K.tty.switch(arg)
    elseif request == "console_mode" then
      proc.console_mode = (arg == "raw") and "raw" or "cooked"
      return true
    end
    return nil
  end)

  -- ============================================================
  -- Account database (auth)
  -- ============================================================
  M.register("getpwnam", function(proc, name)
    return K.auth.getpwnam(name)
  end)

  -- getpwuid(uid) -> entry table or nil
  M.register("getpwuid", function(proc, uid)
    return K.auth.getpwuid(uid)
  end)

  -- getgrnam(name) -> group table or nil
  M.register("getgrnam", function(proc, name)
    return K.auth.getgrnam(name)
  end)

  -- getgrgid(gid) -> group table or nil
  M.register("getgrgid", function(proc, gid)
    return K.auth.getgrgid(gid)
  end)

  -- login(name, pass) -> uid, gid or nil
  M.register("login", function(proc, name, pass)
    return K.auth.login(name, pass)
  end)

  -- setuid(uid): only root may change to arbitrary uid; else must match own
  M.register("setuid", function(proc, uid)
    if proc.uid ~= 0 and uid ~= proc.uid then return nil, "permission denied" end
    proc.uid, proc.euid = uid, uid
    return true
  end)

  -- setgid(gid): only root may change to arbitrary gid
  M.register("setgid", function(proc, gid)
    if proc.uid ~= 0 and gid ~= proc.gid then return nil, "permission denied" end
    proc.gid, proc.egid = gid, gid
    return true
  end)

  return M
end