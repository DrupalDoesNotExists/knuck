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
    -- Capture all handler return values into a table (pcall keeps only the
    -- first, so wrap). The process wrapper unpacks this table.
    local results = { pcall(handler, proc, table.unpack(args or {})) }
    local ok = table.remove(results, 1)
    if not ok then
      proc_mod.die(proc, "SIGSYS", name .. ": " .. tostring(results[1]))
      return
    end
    -- If the handler blocked the process, it is now "waiting"; do not resume.
    -- Otherwise resume with the handler's results.
    if proc.state == "running" then
      K.sched.resume(proc, results)
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

  -- spawn a child process
  M.register("spawn", function(proc, path, ...)
    local args = { ... }
    return proc_mod.spawn(path, proc.pid, proc.uid, proc.gid, args, proc.tty)
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
    return { type = fd.type, mode = 0x1A4, uid = proc.uid, gid = proc.gid, nlink = 1, size = 0 }
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
  M.register("select", function(proc, readfds, writefds, exceptfds, timeout)
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
  M.register("send", function(proc, fdnum, data)
    local fd = proc.fds[fdnum]
    if not fd then return nil, "bad fd" end
    return K.ipc.socket_send(proc, fd, data)
  end)

  -- recv(fd, n)
  M.register("recv", function(proc, fdnum, n)
    local fd = proc.fds[fdnum]
    if not fd then return nil, "bad fd" end
    return K.ipc.socket_recv(proc, fd, n)
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

  -- shutdown(fd, how)
  M.register("shutdown", function(proc, fdnum, how)
    local fd = proc.fds[fdnum]
    if not fd then return nil, "bad fd" end
    return K.ipc.socket_close(fd)
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

  -- setsockopt / getsockopt (SO_BROADCAST for AF_MODEM)
  M.register("setsockopt", function(proc, fdnum, level, opt, val)
    local fd = proc.fds[fdnum]
    if not fd then return nil, "bad fd" end
    if level == 1 and opt == 6 then  -- SOL_SOCKET, SO_BROADCAST
      if fd.sock then fd.sock.broadcast = val == true or val == 1 end
      return true
    end
    return true
  end)
  M.register("getsockopt", function(proc, fdnum, level, opt)
    local fd = proc.fds[fdnum]
    if not fd then return nil, "bad fd" end
    if level == 1 and opt == 6 and fd.sock then  -- SO_BROADCAST
      return fd.sock.broadcast and 1 or 0
    end
    return nil
  end)

  -- ============================================================
  -- Virtual terminals (tty)
  -- ============================================================

  -- ioctl(fd, request, arg): tty_switch switches the active terminal.
  M.register("ioctl", function(proc, fdnum, request, arg)
    if request == "tty_switch" then
      return K.tty.switch(arg)
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