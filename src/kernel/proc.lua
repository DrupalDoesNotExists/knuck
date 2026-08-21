--[[
  KNUCK process management
  ========================
  A process is a coroutine running in a sandboxed _ENV. The sandbox exposes
  only safe stdlibs + named syscall wrappers (no os/fs/term/...).

  States: ready | running | waiting | stopped | zombie | dead
  Zombies hold the exit code until the parent waitpid()s; orphans are
  adopted by init (pid 1).
]]

return function(K)
  local M = {}

  local processes = {}          -- pid -> process
  local next_pid = 1
  local init_pid = nil
  local alarm_timers = {}       -- CC timer id -> proc (alarm() SIGALRM delivery)

  -- Safe stdlibs exposed to processes
  local SAFE_LIBS = { "string", "math", "table", "coroutine", "bit" }

  function M.init(K)
    -- nothing yet
  end

  -- Build a sandbox env for a process: safe libs + syscall wrappers.
  -- system=true grants full env (load, io, os, etc.) for privileged processes.
  local function make_env(system)
    local env = {}
    for _, lib in ipairs(SAFE_LIBS) do
      env[lib] = _G[lib]
    end
    -- basic functions
    for _, f in ipairs({ "type", "tostring", "tonumber", "pairs", "ipairs", "select",
      "error", "pcall", "xpcall", "next", "rawget", "rawset",
      "setmetatable", "getmetatable" }) do
      env[f] = _G[f]
    end
    -- unpack: Lua 5.2+ has no global unpack (it is table.unpack)
    env.unpack = table.unpack
    -- syscall wrappers: each yields {"syscall", name, args}
    for _, name in ipairs(K.syscall.names()) do
      env[name] = function(...)
        local args = { ... }
        local res = coroutine.yield({ "syscall", name, args })
        -- Signal delivery: the kernel may inject {"__signal", sig, handler}
        -- instead of the syscall result. Run the handler, then ack.
        while type(res) == "table" and res[1] == "__signal" do
          local sig_num, handler = res[2], res[3]
          if handler == "default" then
            error("killed by signal " .. sig_num)
          elseif handler == "ignore" then
            -- no-op
          elseif type(handler) == "function" then
            handler(sig_num)
          end
          res = coroutine.yield({ "__ack_signal" })
        end
        -- Packed syscall results carry an explicit count (.n) and use a
        -- sentinel for nil so nil,err results survive the table round-trip.
        if type(res) == "table" and res.n then
          local out = {}
          for i = 1, res.n do
            if res[i] == K.syscall.NIL then
              out[i] = nil
            else
              out[i] = res[i]
            end
          end
          return table.unpack(out, 1, res.n)
        end
        return res
      end
    end
    -- signal number constants (POSIX) for userspace
    env.signals = {
      HUP = 1, INT = 2, QUIT = 3, KILL = 9, USR1 = 10, USR2 = 12,
      PIPE = 13, ALRM = 14, TERM = 15, CHLD = 17, CONT = 18, STOP = 19,
    }
    -- network address family / protocol constants for userspace
    env.AF_UNIX   = 1
    env.AF_MODEM4 = 2     -- IPv4 over modem link
    env.AF_INET   = 2     -- alias for AF_MODEM4
    env.AF_ICMP   = 2     -- DEPRECATED: alias for AF_MODEM4
    env.AF_HTTP   = 3
    env.AF_MODEM6 = 10    -- IPv6 over modem link (reserved)
    env.AF_INET6  = 10    -- alias for AF_MODEM6
    env.SOCK_STREAM = 1
    env.SOCK_DGRAM  = 2
    env.SOCK_RAW    = 3
    env.IPPROTO_IP   = 0
    env.IPPROTO_ICMP = 1
    env.IPPROTO_TCP  = 6
    env.IPPROTO_UDP  = 17
    if system then
      -- Full env for system processes (pine.lua, hook scripts): grant
      -- load/loadfile/dofile/io/os/require so they can load and run
      -- Lua chunks that need raw filesystem or OS access.
      env.load = load
      if _G.loadstring then env.loadstring = _G.loadstring end
      env.loadfile = loadfile
      env.dofile = dofile
      env.io = _G.io
      env.os = _G.os
      env.require = _G.require
      -- print uses io.write for system processes (full io available)
      env.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
        env.io.write(table.concat(parts, "\t") .. "\n")
      end
    else
      -- print: write to fd 1 (no io library in the sandbox)
      env.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
        env.write(1, table.concat(parts, "\t") .. "\n")
      end
    end
    return env
  end

  -- Expose the env builder so exec() (syscall.lua) can build a fresh sandbox
  M.make_env = make_env

  -- Load process code from a VFS path with a sandbox env
  local function load_process(path, env)
    local f, err = K.vfs.loadfile(path, env)
    if not f then return nil, err end
    return f
  end

  -- Spawn a process from a VFS path. system=true grants privileged env.
  function M.spawn(path, ppid, uid, gid, args, tty, fds, parent, system)
    local env = make_env(system)
    local fn, err = load_process(path, env)
    if not fn then return nil, err end

    local pid = next_pid
    next_pid = next_pid + 1

    local proc = {
      pid = pid,
      ppid = ppid or 0,
      name = path,
      uid = uid or 0,
      euid = uid or 0,
      gid = gid or 0,
      egid = gid or 0,
      pgid = pid,
      priority = 0,
      sched_policy = "other",  -- "rr" | "fifo" | "other"
      -- Inherit parent's cwd/root so `cd` in a shell affects spawned children
      -- (e.g. `ls` lists the shell's current directory, not always "/").
      cwd = (parent and parent.cwd) or "/",
      root = (parent and parent.root) or "/",
      umask = 0x12,  -- 0022 octal
      state = "ready",
      tty = (tty == nil and 1 or tty),
      console_mode = "cooked",  -- /dev/console input: "cooked" (lines) | "raw" (events)
      env = env,
      environ = {},  -- environment variables (name -> value), inherited on spawn
      fds = { [0] = { type = "console", mode = "r" }, [1] = { type = "console", mode = "w" }, [2] = { type = "console", mode = "w" } },
      children = {},
      exitcode = nil,
      pending_result = nil,
      system = system or false,  -- system process: full env (load/io/os)
      sig = {
        handlers = {},    -- sig_num -> fn | "ignore" | "default"
        pending = {},     -- set of sig_nums awaiting delivery
        blocked = {},     -- set of sig_nums blocked from delivery
        _pending_result = nil,  -- saved syscall result during signal delivery
      },
    }

    -- Wire child stdin/stdout/stderr to the parent's open fds (for shell
    -- redirection and pipelines). Shares the underlying open file
    -- description, so the child and parent see the same offset/socket.
    if fds and parent and parent.fds then
      -- Explicit fds table: map child slots to parent fd numbers
      for slot, src in pairs(fds) do
        if parent.fds[src] then
          proc.fds[slot] = parent.fds[src]
        end
      end
    elseif parent and parent.fds then
      -- No explicit fds: inherit parent's fds (POSIX fork semantics).
      -- This ensures children of getty/login services inherit the tty
      -- device fds that the parent dup2'd, so writes go to the correct tty.
      for slot, fd in pairs(parent.fds) do
        proc.fds[slot] = fd
      end
    end

    -- Inherit environment variables from the parent.
    if parent and parent.environ then
      for k, v in pairs(parent.environ) do
        proc.environ[k] = v
      end
    end

    -- Create the coroutine; pass args
    proc.co = coroutine.create(function()
      return fn(table.unpack(args or {}))
    end)

    processes[pid] = proc
    if ppid and processes[ppid] then
      processes[ppid].children[pid] = proc
    end

    K.sched.enqueue(proc)
    return pid
  end

  -- Look up a process by pid
  function M.lookup(pid)
    return processes[pid]
  end

  -- Find a child of parent (pid=-1 = any child)
  function M.find_child(ppid, pid)
    local parent = processes[ppid]
    if not parent then return nil end
    if pid == -1 then
      for _, child in pairs(parent.children) do
        if child.state == "zombie" then return child end
      end
      return nil
    end
    return parent.children[pid]
  end

  -- Reap a zombie: return (pid, "exited", code) or (pid, "killed", sig)
  function M.reap(child)
    local pid = child.pid
    local status = child.exitstatus or { "exited", child.exitcode or 0 }
    processes[pid] = nil
    if child.ppid and processes[child.ppid] then
      processes[child.ppid].children[pid] = nil
    end
    return pid, status[1], status[2]
  end

  -- Exit a process (self-terminate)
  function M.exit(proc, code)
    proc.state = "zombie"
    proc.exitcode = code or 0
    proc.exitstatus = { "exited", code or 0 }
    M.notify_parent(proc)
  end

  -- Send a signal to a process. KILL(9)/STOP(19) are immediate and
  -- unblockable; other signals are queued for delivery at the next resume
  -- boundary (unless blocked or ignored).
  function M.send_signal(target, sig_num)
    if sig_num == 9 then  -- SIGKILL: immediate death
      target.state = "zombie"
      target.exitcode = 128 + 9
      target.exitstatus = { "killed", 9 }
      M.notify_parent(target)
      return true
    elseif sig_num == 19 then  -- SIGSTOP: immediate stop
      target.state = "stopped"
      return true
    elseif sig_num == 18 then  -- SIGCONT: resume a stopped process
      if target.state == "stopped" then
        K.sched.enqueue(target)
      end
      return true
    end
    -- Blocked signals are dropped (POSIX: pending while blocked; this kernel
    -- keeps it simple: blocked = lost).
    if target.sig.blocked[sig_num] then return true end
    local handler = target.sig.handlers[sig_num]
    if handler == "ignore" then return true end
    target.sig.pending[sig_num] = true
    return true
  end

  -- Pick the next deliverable signal for a process about to be resumed.
  -- Returns sig_num or nil. Called from sched.resume, which fires both after
  -- a syscall (state "running") and when waking from a wait (state "waiting";
  -- M.wake already removed the proc from the waiting table, so enqueueing is
  -- safe). STOP/CONT are handled directly in send_signal.
  function M.check_signal(proc)
    if proc.state ~= "ready" and proc.state ~= "running" and proc.state ~= "waiting" then return nil end
    for sig_num in pairs(proc.sig.pending) do
      if not proc.sig.blocked[sig_num] then
        return sig_num
      end
    end
    return nil
  end

  -- Kill a process by signal. pid: positive = specific, 0 = own group,
  -- -1 = all except self (root only). sig 0 = existence check.
  function M.kill(proc, pid, sig)
    sig = sig or 15  -- default SIGTERM
    if pid == 0 then
      for _, p in pairs(processes) do
        if p.pgid == proc.pgid and p.pid ~= proc.pid then
          M.send_signal(p, sig)
        end
      end
      return true
    end
    if pid == -1 then
      if proc.uid ~= 0 then return nil, "permission denied" end
      for _, p in pairs(processes) do
        if p.pid ~= proc.pid then
          M.send_signal(p, sig)
        end
      end
      return true
    end
    local target = processes[pid]
    if not target then return nil, "no such process" end
    -- permission: same uid or root
    if proc.uid ~= 0 and proc.uid ~= target.uid then
      return nil, "permission denied"
    end
    if sig == 0 then
      return true -- signal 0 = existence check
    end
    return M.send_signal(target, sig)
  end

  -- Die from an error/signal (uncaught error -> SIGSEGV)
  function M.die(proc, sig, detail)
    proc.state = "zombie"
    proc.exitcode = 128 + 11 -- SIGSEGV
    proc.exitstatus = { "killed", sig }
    if detail then
      K.log("process " .. proc.pid .. " (" .. proc.name .. ") died: " .. tostring(detail))
    end
    M.notify_parent(proc)
  end

  -- Notify parent (SIGCHLD) and wake a waiting waitpid
  function M.notify_parent(proc)
    local reap = { proc.pid, proc.exitstatus[1], proc.exitstatus[2] }
    local parent = processes[proc.ppid]
    if parent then
      K.sched.wake("child", proc.ppid, reap)
      -- SIGCHLD (17): deliver to parent if it installed a handler
      if parent.sig and parent.sig.handlers[17] and
         parent.sig.handlers[17] ~= "ignore" and
         not parent.sig.blocked[17] then
        parent.sig.pending[17] = true
      end
    else
      -- orphan: adopt by init
      if init_pid and processes[init_pid] then
        processes[init_pid].children[proc.pid] = proc
        proc.ppid = init_pid
        K.sched.wake("child", init_pid, reap)
      end
    end
  end

  -- Set init process (pid 1)
  function M.set_init(pid)
    init_pid = pid
  end

  -- Alarm timer map (timer id -> proc); read by sched.lua event dispatch
  M.alarm_timers = alarm_timers

  -- Snapshot for /proc
  function M.snapshot()
    local out = {}
    for pid, p in pairs(processes) do
      out[pid] = {
        name = p.name,
        state = p.state,
        ppid = p.ppid,
        uid = p.uid,
        priority = p.priority,
        fds = p.fds,
      }
    end
    return out
  end

  return M
end