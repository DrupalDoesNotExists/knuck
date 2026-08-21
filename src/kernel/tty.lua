--[[
  KNUCK virtual terminals (multi-tty)
  ===================================
  N virtual terminals /dev/tty1..ttyN. Each has an output buffer. Only the
  ACTIVE tty renders to the physical CraftOS terminal; inactive ttys buffer
  their output. Input (char/key) is routed to the active tty's readers.

  Switching: ioctl(fd, "VT_ACTIVATE", id) on /dev/console, or a devctl
  write. Each process is bound to a tty (proc.tty, default 1).
]]

return function(K)
  local M = {}

  local N = 6
  local ttys = {}
  local active = 1
  for i = 1, N do
    ttys[i] = { id = i, buffer = "", line = "", readers = {} }
  end

  function M.init(K)
    -- nothing yet
  end

  function M.count() return N end
  function M.active_id() return active end

  -- Write to a process's tty. If that tty is active, render to physical term.
  -- Detached (tty 0/nil) writes go nowhere (or to log ring) — init is detached.
  function M.write(proc, data)
    local id = (proc and proc.tty)
    if not id or id == 0 then return #(tostring(data or "")) end
    local t = ttys[id]
    if not t then return #(tostring(data or "")) end
    local s = tostring(data or "")
    t.buffer = t.buffer .. s
    if id == active then
      K.term_write(s)
    end
    return #s
  end

  -- Read from a process's tty. Blocks until input arrives on that tty.
  -- Cooked mode (default): returns a line of text on Enter.
  -- Raw mode: returns the raw input event table.
  -- Detached has no tty to read from — return nil.
  function M.read(proc, n)
    local id = (proc and proc.tty)
    if not id or id == 0 then return nil, "no tty" end
    if not ttys[id] then return nil, "no tty" end
    if proc and proc.console_mode == "raw" then
      K.sched.wait(proc, "tty_input", id)
      return proc.pending_result
    end
    K.sched.wait(proc, "tty_cooked", id)
    return proc.pending_result
  end

  -- Switch the active tty and render its buffer.
  function M.switch(id)
    if not ttys[id] then return false end
    active = id
    term.clear()
    term.setCursorPos(1, 1)
    K.term_write(ttys[id].buffer)
    return true
  end

  -- Route an input event to the active tty's readers.
  -- Raw readers get the event directly; cooked readers accumulate chars
  -- into the line buffer and are woken with the line on Enter.
  -- Echo helpers for cooked mode — user must see what they type.
  local function echo(s)
    if active == ttys[active].id then K.term_write(s) end
  end

  function M.handle_input(ev)
    -- Wake raw readers on the active tty (only the active VT receives input,
    -- matching real terminal behavior). Getty must call VT_ACTIVATE to make
    -- its tty active before reading.
    local t = ttys[active]
    K.sched.wake("tty_input", active, ev)

    -- Cooked processing only when a cooked waiter exists.
    -- In raw mode (login password prompt, etc.) no cooked waiter is present,
    -- so line buffering, echo, and cooked wake are all skipped — preventing
    -- double echo and password leakage.
    if not K.sched.is_waiting("tty_cooked", active) then return end

    -- Backspace / delete — erase last char from cooked line buffer
    if ev[1] == "key" and (ev[2] == 14 or ev[2] == 259) then  -- Backspace(14), Delete(259)
      if #t.line > 0 then
        t.line = t.line:sub(1, -2)
        echo("\b \b")
      end
      return
    end

    if ev[1] == "char" then
      local ch = ev[2]
      -- Also handle \b and DEL (\x7f) as backspace in char events
      if ch == "\b" or ch == "\x7f" then
        if #t.line > 0 then
          t.line = t.line:sub(1, -2)
          echo("\b \b")
        end
      elseif ch == "\n" or ch == "\r" then
        echo("\n")
        local line = t.line
        t.line = ""
        K.sched.wake("tty_cooked", active, line)
      else
        t.line = t.line .. ch
        echo(ch)  -- echo typed character to active terminal
      end
    elseif ev[1] == "key" and (ev[2] == 28 or ev[2] == 13 or ev[2] == 257) then  -- Enter key
      echo("\n")
      local line = t.line
      t.line = ""
      K.sched.wake("tty_cooked", active, line)
    end
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
        if id == active then K.term_write(s) end
        return #s
      end,
      read = function(n)
        local proc = K.sched.current()
        if proc and proc.console_mode == "raw" then
          K.sched.wait(proc, "tty_input", id)
          return proc.pending_result
        end
        K.sched.wait(proc, "tty_cooked", id)
        return proc.pending_result
      end,
    }
  end

  return M
end