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

  -- write to stdout (fd 1) via term driver
  M.register("write", function(proc, data)
    local fd = proc.fds[1]
    if not fd then return nil, "no stdout" end
    return K.vfs.write(fd, data)
  end)

  -- print: write args to stdout with a newline
  M.register("print", function(proc, ...)
    local parts = { ... }
    for i, v in ipairs(parts) do parts[i] = tostring(v) end
    local line = table.concat(parts, "\t") .. "\n"
    local fd = proc.fds[1]
    if not fd then return nil, "no stdout" end
    return K.vfs.write(fd, line)
  end)

  -- spawn a child process
  M.register("spawn", function(proc, path, ...)
    local args = { ... }
    return proc_mod.spawn(path, proc.pid, proc.uid, proc.gid, args)
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
    if not K.vfs.is_dir(resolved) then return nil, "not a directory" end
    proc.cwd = resolved
    return true
  end)

  return M
end