--[[
  KNUCK virtual terminals (multi-tty)
  ===================================
  N virtual terminals /dev/tty1..ttyN. Each has an output buffer. Only the
  ACTIVE tty renders to the physical CraftOS terminal; inactive ttys buffer
  their output. Input (char/key) is routed to the active tty's readers.

  Switching: ioctl(fd, "tty_switch", id) on /dev/console, or a devctl
  write. Each process is bound to a tty (proc.tty, default 1).
]]

return function(K)
  local M = {}

  local N = 6
  local ttys = {}
  local active = 1
  for i = 1, N do
    ttys[i] = { id = i, buffer = "", readers = {} }
  end

  function M.init(K)
    -- nothing yet
  end

  function M.count() return N end
  function M.active_id() return active end

  -- Write to a process's tty. If that tty is active, render to physical term.
  function M.write(proc, data)
    local id = (proc and proc.tty) or 1
    local t = ttys[id]
    local s = tostring(data or "")
    t.buffer = t.buffer .. s
    if id == active then
      term.write(s)
    end
    return #s
  end

  -- Read from a process's tty. Blocks until input arrives on that tty.
  function M.read(proc, n)
    local id = (proc and proc.tty) or 1
    K.sched.wait(proc, "tty_input", id)
    return proc.pending_result
  end

  -- Switch the active tty and render its buffer.
  function M.switch(id)
    if not ttys[id] then return false end
    active = id
    term.clear()
    term.setCursorPos(1, 1)
    term.write(ttys[id].buffer)
    return true
  end

  -- Route an input event to the active tty's readers.
  function M.handle_input(ev)
    K.sched.wake("tty_input", active, ev)
  end

  -- Bind a process to a tty (inherited from parent on spawn).
  function M.bind(proc, id)
    proc.tty = id or 1
  end

  -- Device driver for /dev/ttyN
  function M.make_driver(id)
    return {
      mode = 0x1B6,
      write = function(data)
        local proc = K.sched.current()
        local t = ttys[id]
        local s = tostring(data or "")
        t.buffer = t.buffer .. s
        if id == active then term.write(s) end
        return #s
      end,
      read = function(n)
        local proc = K.sched.current()
        K.sched.wait(proc, "tty_input", id)
        return proc.pending_result
      end,
    }
  end

  return M
end