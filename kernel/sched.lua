--[[
  KNUCK scheduler
  ===============
  Preemptive round-robin with priorities. Each process is a coroutine.
  The kernel owns os.pullEvent (the only code that touches the OS event loop).

  Preemption: debug.sethook count-hook fires every QUANTUM instructions and
  yields {"preempt"}; the kernel requeues the process. If yield-from-hook is
  unavailable (selfcheck.preempt == false), falls back to cooperative.

  Processes yield to the kernel with:
    {"syscall", name, args}   -- a syscall request
    {"preempt"}               -- quantum expired (from count hook)
    nil                       -- process returned (exit 0)
  An error unwinding the coroutine = process death (SIGSEGV).
]]

return function(K)
  local M = {}

  local QUANTUM = 1000          -- instructions per quantum
  local ready = {}              -- ready queue (list of processes)
  local waiting = {}            -- waiting processes: waiting[reason][key] = proc
  local current = nil           -- currently running process
  local running = false

  local proc_mod = nil          -- set in init()

  function M.init(K)
    proc_mod = K.proc
  end

  -- Enqueue a ready process
  function M.enqueue(proc)
    proc.state = "ready"
    ready[#ready + 1] = proc
  end

  -- Dequeue highest-priority ready process (lower priority number = higher)
  function M.dequeue()
    if #ready == 0 then return nil end
    local best, best_idx = ready[1], 1
    for i = 2, #ready do
      if ready[i].priority < best.priority then
        best, best_idx = ready[i], i
      end
    end
    table.remove(ready, best_idx)
    return best
  end

  -- Mark a process as waiting on reason/key. resume_fn (optional) computes
  -- the value to resume the process with on wake; if absent, the wake
  -- result is used.
  function M.wait(proc, reason, key, resume_fn)
    proc.state = "waiting"
    proc.wait_reason = reason
    proc.wait_key = key
    proc.resume_fn = resume_fn
    waiting[reason] = waiting[reason] or {}
    waiting[reason][key] = proc
  end

  -- Wake a waiting process (resume it with a result)
  function M.wake(reason, key, result)
    local w = waiting[reason]
    if not w then return end
    local proc = w[key]
    if not proc then return end
    w[key] = nil
    proc.wait_reason = nil
    proc.wait_key = nil
    local r = result
    if proc.resume_fn then
      r = proc.resume_fn()
      proc.resume_fn = nil
    end
    M.resume(proc, r)
  end

  -- Resume a process with a result (or nil). Re-enqueues it.
  function M.resume(proc, result)
    proc.pending_result = result
    M.enqueue(proc)
  end

  -- Run one process to its next yield/exit/error
  local function run(proc)
    current = proc
    proc.state = "running"

    -- Set count hook for preemption
    if K.selfcheck.preempt then
      debug.sethook(proc.co, function()
        coroutine.yield({ "preempt" })
      end, "", QUANTUM)
    end

    local ok, req = coroutine.resume(proc.co, proc.pending_result)
    proc.pending_result = nil

    -- Remove hook
    if K.selfcheck.preempt then
      debug.sethook(proc.co)
    end

    current = nil

    if not ok then
      -- Process died with an error -> SIGSEGV
      proc_mod.die(proc, "SIGSEGV", req)
      return
    end

    if req == nil then
      -- Process returned -> exit(0)
      proc_mod.exit(proc, 0)
    elseif type(req) == "table" then
      if req[1] == "syscall" then
        K.syscall.handle(proc, req[2], req[3])
      elseif req[1] == "preempt" then
        -- Quantum expired: requeue
        M.enqueue(proc)
      end
    end
  end

  -- Main scheduler loop. Never returns.
  function M.start()
    running = true
    while true do
      local proc = M.dequeue()
      if proc then
        run(proc)
      else
        -- Idle: wait for an OS event, dispatch to waiting processes
        local ev = { K.env.os.pullEvent() }
        K.events.dispatch(ev)
      end
    end
  end

  -- Event dispatch: wake processes waiting on the event
  K.events = {
    dispatch = function(ev)
      local name = ev[1]
      if name == "timer" then
        -- network timers (ARP expiry, etc.) are handled first
        if K.net and K.net.timer_fired and K.net.timer_fired(ev[2]) then return end
        M.wake("timer", ev[2], true)
      elseif name == "modem_message" then
        if K.net and K.net.on_modem_message then
          K.net.on_modem_message(ev[2], ev[3], ev[4], ev[5], ev[6])
        end
      elseif name == "char" or name == "key" or name == "key_up" or name == "mouse_click" then
        -- console input: route to the active virtual terminal
        if K.tty then
          K.tty.handle_input(ev)
        else
          M.wake("input", "console", ev)
        end
      elseif name == "peripheral" then
        -- device hotplug: wake devctl readers
        M.wake("devctl", "devctl", ev)
      end
    end,
  }

  return M
end