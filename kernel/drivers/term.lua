--[[
  KNUCK term driver
  =================
  Backs the /dev/console device node. Writes go to the CraftOS terminal.
  Reads block on console input (char/key events) via the scheduler's
  event dispatch.
]]

return function(K)
  local M = {}

  -- Write data to the console. Returns bytes written.
  function M.write(data)
    local s = tostring(data or "")
    term.write(s)
    return #s
  end

  -- Read from the console. Blocks until a key/char event.
  -- Returns a table { event, ... } describing the input.
  function M.read(n)
    -- Block the calling process on console input.
    -- The scheduler wakes it via sched.wake("input", "console", ev).
    local proc = K.sched.current
    if proc then
      K.sched.wait(proc, "input", "console")
    end
    -- When resumed, pending_result holds the event table.
    return proc and proc.pending_result or nil
  end

  return M
end