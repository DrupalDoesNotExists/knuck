--[[
  KNUCK term driver
  =================
  Backs the /dev/console device node. Delegates to the virtual-terminal
  layer (K.tty) so each process writes to its bound tty and only the
  active tty renders to the physical CraftOS terminal.
]]

return function(K)
  local M = {}

  -- Write data to the process's tty. Returns bytes written.
  function M.write(data)
    local proc = K.sched.current()
    if K.tty then
      return K.tty.write(proc, data)
    end
    local s = tostring(data or "")
    term.write(s)
    return #s
  end

  -- Read from the process's tty. Blocks until input on that tty.
  function M.read(n)
    local proc = K.sched.current()
    if K.tty then
      return K.tty.read(proc, n)
    end
    if proc then
      K.sched.wait(proc, "input", "console")
    end
    return proc and proc.pending_result or nil
  end

  return M
end