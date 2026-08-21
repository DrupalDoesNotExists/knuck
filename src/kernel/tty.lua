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
        M.do_scroll(active, get_h() - 1)
        return
      elseif k == 209 then
        M.do_scroll(active, -(get_h() - 1))
        return
      elseif k == 200 then
        M.do_scroll(active, 1)
        return
      elseif k == 208 then
        M.do_scroll(active, -1)
        return
      end
    elseif ev[1] == "mouse_scroll" then
      -- Wheel scroll: direction -1 = up (view older), 1 = down (view newer).
      -- Map to a single-line scroll in the matching direction.
      M.do_scroll(active, ev[2] == -1 and 1 or -1)
      return
    end
    local t = ttys[active]
    if t.scroll ~= 0 then
      if ev[1] == "char" or (ev[1] == "key" and (ev[2] == 14 or ev[2] == 259 or ev[2] == 28 or ev[2] == 13 or ev[2] == 257)) then
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

  -- ===== PTY (pseudo-terminal) subsystem =====
  -- General master/slave pty, like Linux pts. open("/dev/ptmx") creates a
  -- master+slave pair; the slave (/dev/ptsN) is a full tty (input fed by the
  -- master, output read by the master, with echo/raw/cooked line discipline).
  -- A proxy (e.g. ttybcd) opens the master, runs a shell on the slave, and
  -- shuttles bytes between the slave and a real terminal — optionally
  -- broadcasting the slave's output to other consumers (monitors). The shell
  -- runs on the slave and works unchanged (it does its own raw mode + echo).

  local ptys = {}        -- slave_id -> pty state
  local next_pts = 0

  local function pty_echo(pty, s)
    pty.output[#pty.output + 1] = s
    K.sched.wake("pty_output", pty.slave_id, true)
  end

  -- Feed a raw input event from the master into the pty's input side.
  -- Discipline (raw/cooked) follows the current reader's console_mode.
  local function pty_feed(pty, ev)
    if pty.mode == "raw" then
      pty.input_raw[#pty.input_raw + 1] = ev
      K.sched.wake("pty_input", pty.slave_id, true)
      return
    end
    -- cooked: build line + echo to output (master displays it)
    if type(ev) == "table" then
      if ev[1] == "char" then
        local ch = ev[2]
        if ch == "\b" or ch == "\x7f" then
          if #pty.line > 0 then pty.line = pty.line:sub(1, -2); pty_echo(pty, "\b \b") end
        elseif ch == "\n" or ch == "\r" then
          pty_echo(pty, "\n")
          pty.line_ready = pty.line
          pty.line = ""
          K.sched.wake("pty_cooked", pty.slave_id, true)
        else
          pty.line = pty.line .. ch
          pty_echo(pty, ch)
        end
      elseif ev[1] == "key" then
        local k = ev[2]
        if k == 14 or k == 259 then
          if #pty.line > 0 then pty.line = pty.line:sub(1, -2); pty_echo(pty, "\b \b") end
        elseif k == 28 or k == 13 or k == 257 then
          pty_echo(pty, "\n")
          pty.line_ready = pty.line
          pty.line = ""
          K.sched.wake("pty_cooked", pty.slave_id, true)
        end
      end
    elseif type(ev) == "string" then
      pty.line = pty.line .. ev
      pty_echo(pty, ev)
    end
  end

  -- Create a pty. Returns { pty, slave_id, master_drv, slave_drv }.
  function M.create_pty()
    local slave_id = next_pts
    next_pts = next_pts + 1
    local pty = {
      slave_id = slave_id,
      input_raw = {},
      output = {},
      line = "",
      line_ready = nil,
      mode = "cooked",
    }
    ptys[slave_id] = pty

    -- Slave driver: the tty the shell runs on.
    local slave_drv = {
      mode = 0x1B6,
      open = function()
        local proc = K.sched.current()
        if proc then proc.tty = slave_id end
      end,
      read = function(n)
        local proc = K.sched.current()
        pty.mode = proc.console_mode or "cooked"
        if pty.mode == "raw" then
          if #pty.input_raw > 0 then return table.remove(pty.input_raw, 1) end
          K.sched.wait(proc, "pty_input", pty.slave_id, function()
            if #pty.input_raw > 0 then return table.remove(pty.input_raw, 1) end
            return nil
          end)
        else
          if pty.line_ready then
            local l = pty.line_ready
            pty.line_ready = nil
            return l
          end
          K.sched.wait(proc, "pty_cooked", pty.slave_id, function()
            if pty.line_ready then
              local l = pty.line_ready
              pty.line_ready = nil
              return l
            end
            return nil
          end)
        end
      end,
      write = function(data)
        local s = tostring(data or "")
        pty.output[#pty.output + 1] = s
        K.sched.wake("pty_output", pty.slave_id, true)
        return #s
      end,
      ioctl = function(request, arg)
        return true
      end,
    }

    -- Master driver: the proxy end (read = slave output, write = slave input).
    local master_drv = {
      mode = 0x1B6,
      read = function(n)
        if #pty.output > 0 then return table.remove(pty.output, 1) end
        local proc = K.sched.current()
        K.sched.wait(proc, "pty_output", pty.slave_id, function()
          if #pty.output > 0 then return table.remove(pty.output, 1) end
          return nil
        end)
      end,
      write = function(data)
        if type(data) == "table" then
          pty_feed(pty, data)
        elseif type(data) == "string" then
          for i = 1, #data do
            pty_feed(pty, { "char", data:sub(i, i) })
          end
        end
        return #tostring(data or "")
      end,
    }

    -- Register the slave device so it can be opened at /dev/ptsN.
    K.vfs.register_device("pts" .. slave_id, slave_drv)

    return { pty = pty, slave_id = slave_id, master_drv = master_drv, slave_drv = slave_drv }
  end

  -- Build a master fd object for an already-created pty (used by open()).
  function M.pty_master_fd(slave_id)
    local pty = ptys[slave_id]
    if not pty then return nil end
    return { type = "device", device = "ptmx", driver = pty.master_drv, pty = pty, slave_id = slave_id }
  end

  -- Device driver for /dev/tyN
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