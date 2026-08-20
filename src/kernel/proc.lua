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

  -- Safe stdlibs exposed to processes
  local SAFE_LIBS = { "string", "math", "table", "coroutine" }

  function M.init(K)
    -- nothing yet
  end

  -- Build a sandbox env for a process: safe libs + syscall wrappers
  local function make_env()
    local env = {}
    for _, lib in ipairs(SAFE_LIBS) do
      env[lib] = _G[lib]
    end
    -- basic functions
    for _, f in ipairs({ "type", "tostring", "pairs", "ipairs", "select",
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
        if type(res) == "table" then
          return table.unpack(res)
        else
          return res
        end
      end
    end
    return env
  end

  -- Load process code from a VFS path with a sandbox env
  local function load_process(path, env)
    local f, err = K.vfs.loadfile(path, env)
    if not f then return nil, err end
    return f
  end

  -- Spawn a process from a VFS path
  function M.spawn(path, ppid, uid, gid, args, tty)
    local env = make_env()
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
      cwd = "/",
      root = "/",
      umask = 0x12,  -- 0022 octal
      state = "ready",
      tty = tty or 1,
      env = env,
      fds = { [0] = { type = "console", mode = "r" }, [1] = { type = "console", mode = "w" }, [2] = { type = "console", mode = "w" } },
      children = {},
      exitcode = nil,
      pending_result = nil,
    }

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

  -- Kill a process by signal
  function M.kill(proc, pid, sig)
    local target = processes[pid]
    if not target then return nil, "no such process" end
    -- permission: same uid or root
    if proc.uid ~= 0 and proc.uid ~= target.uid then
      return nil, "permission denied"
    end
    if sig == 0 then
      return true -- signal 0 = existence check
    end
    if sig == 9 or sig == 15 or sig == 2 then
      target.state = "zombie"
      target.exitcode = 128 + (sig or 0)
      target.exitstatus = { "killed", sig }
      M.notify_parent(target)
    elseif sig == 17 then -- SIGSTOP
      target.state = "stopped"
    elseif sig == 19 then -- SIGCONT
      if target.state == "stopped" then
        K.sched.enqueue(target)
      end
    end
    return true
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
      }
    end
    return out
  end

  return M
end