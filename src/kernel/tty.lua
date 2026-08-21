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
  local SCROLLBACK = 500
  local ttys = {}
  local active = 1
  for i = 1, N do
    ttys[i] = { id = i, buffer = "", line = "", readers = {}, scroll = 0 }
  end

  local function get_h()
    local ok, w, h = pcall(function() return term.getSize() end)
    if ok and h then return h end
    if term and term.getSize then
      local _, hh = term.getSize()
      return hh or 19
    end
    return 19
  end
  local function trim_buffer(t)
    local cnt = 0
    for _ in t.buffer:gmatch("\n") do cnt = cnt + 1 end
    if cnt > SCROLLBACK then
      local excess = cnt - SCROLLBACK
      local pos = 1
      for i = 1, excess do
        local nl = t.buffer:find("\n", pos, true)
        if not nl then break end
        pos = nl + 1
      end
      t.buffer = t.buffer:sub(pos)
      if t.scroll > 0 then t.scroll = math.max(0, t.scroll - excess) end
    end
  end
  local function redraw(t)
    term.clear()
    term.setCursorPos(1, 1)
    if t.scroll == 0 then
      K.term_write(t.buffer)
    else
      local buf = t.buffer
      local lines = {}
      local i = 1
      while true do
        local nl = buf:find("\n", i, true)
        if nl then
          lines[#lines+1] = buf:sub(i, nl-1)
          i = nl + 1
        else
          lines[#lines+1] = buf:sub(i)
          break
        end
      end
      if buf:sub(-1) == "\n" and lines[#lines] == "" then table.remove(lines) end
      local h = get_h()
      local total = #lines
      local start = math.max(1, total - h - t.scroll + 1)
      local finish = math.min(total, total - t.scroll)
      local slice = {}
      for idx = start, finish do slice[#slice+1] = lines[idx] end
      local text = table.concat(slice, "\n")
      if total > 0 and buf:sub(-1) == "\n" and finish == total then text = text .. "\n" end
      K.term_write(text)
    end
  end
  function M.do_scroll(id, delta)
    local t = ttys[id]
    if not t then return end
    local h = get_h()
    local cnt = 0
    for _ in t.buffer:gmatch("\n") do cnt = cnt + 1 end
    if t.buffer:sub(-1) ~= "\n" and #t.buffer > 0 then cnt = cnt + 1 end
    local max_scroll = math.max(0, cnt - h)
    if max_scroll == 0 then return end
    t.scroll = t.scroll + delta
    if t.scroll < 0 then t.scroll = 0 end
    if t.scroll > max_scroll then t.scroll = max_scroll end
    redraw(t)
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
    trim_buffer(t)
    if id == active then
      if t.scroll == 0 then
        K.term_write(s)
      end
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
    ttys[id].scroll = 0
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
    if ev[1] == "key" then
      local k = ev[2]
      if k == 201 or k == 199 then
        M.do_scroll(active, -(get_h() - 1))
        return
      elseif k == 209 then
        M.do_scroll(active, get_h() - 1)
        return
      end
    end
    local t = ttys[active]
    if t.scroll ~= 0 then
      if ev[1] == "char" or (ev[1] == "key" and (ev[2] == 14 or ev[2] == 259 or ev[2] == 28 or ev[2] == 13 or ev[2] == 257 or ev[2] == 200 or ev[2] == 208)) then
        t.scroll = 0
        redraw(t)
      end
    end
    -- Wake raw readers on the active tty (only the active VT receives input,
    -- matching real terminal behavior). Getty must call VT_ACTIVATE to make
    -- its tty active before reading.
    -- Shift+PageUp/PageDown already handled above (also handle held shift variant bare PageUp)
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
        trim_buffer(t)
        if id == active and t.scroll == 0 then K.term_write(s) end
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