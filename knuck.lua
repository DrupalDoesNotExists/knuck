--[[
  KNUCK kernel entry
  ==================
  Boot sequence:
    1. Build kernel namespace K (kernel env = full globals).
    2. Load module loader.
    3. Run self-diagnostics (diag).
    4. Load core modules (sched, syscall, proc, vfs).
    5. Init modules, mount VFS.
    6. Start scheduler -> run init process.

  Run: lua /knuck/knuck.lua
]]

-- Kernel namespace. Kernel code runs with full globals (os/fs/term/...).
local K = {
  env = _G,
  modules = {},
  selfcheck = {},
}

-- Bit helpers (CraftOS 1.9 = Lua 5.2/Cobalt: no bitwise operators, no bit32)
K.bit = {
  band = function(a, b)
    local r, bit = 0, 1
    while a > 0 and b > 0 do
      if a % 2 == 1 and b % 2 == 1 then r = r + bit end
      a = math.floor(a / 2); b = math.floor(b / 2); bit = bit * 2
    end
    return r
  end,
  bor = function(a, b)
    local r, bit = 0, 1
    while a > 0 or b > 0 do
      if a % 2 == 1 or b % 2 == 1 then r = r + bit end
      a = math.floor(a / 2); b = math.floor(b / 2); bit = bit * 2
    end
    return r
  end,
  bnot = function(a)
    -- 32-bit complement
    return 0xFFFFFFFF - a
  end,
}

-- Kernel log (writes to stderr/console)
function K.log(msg)
  term.setTextColor(colors.yellow)
  K.term_write("[k] " .. tostring(msg) .. "\n")
  term.setTextColor(colors.white)
end

-- Terminal writer with explicit newline/wrap handling.
-- CC's term.write does not reliably wrap or advance lines across versions,
-- so the kernel manages cursor movement itself: split on \n, write in
-- screen-width chunks, scroll at the bottom edge. A line is advanced ONLY
-- on a real \n, so raw partial writes (e.g. shell input echo) stay inline.
function K.term_write(s)
  local t = term
  local text = tostring(s or "")
  if not t or not t.getSize or not t.getCursorPos or not t.setCursorPos then
    -- fallback (host stub / minimal env): plain write
    if t and t.write then t.write(text) end
    return
  end
  local w, h = t.getSize()
  if not w or w < 1 or not h or h < 1 then
    if t.write then t.write(text) end
    return
  end
  local pos = 1
  while pos <= #text do
    local nl = text:find("\n", pos, true)
    local seg, has_nl
    if nl then
      seg = text:sub(pos, nl - 1)
      has_nl = true
      pos = nl + 1
    else
      seg = text:sub(pos)
      has_nl = false
      pos = #text + 1
    end
    -- write seg with wrapping
    local cx, cy = t.getCursorPos()
    local col = cx or 1
    local i = 1
    while i <= #seg do
      local avail = w - col + 1
      if avail < 1 then avail = 1 end
      local chunk = seg:sub(i, i + avail - 1)
      t.write(chunk)
      i = i + #chunk
      col = col + #chunk
      if col > w then
        cy = cy + 1
        if cy > h then
          t.scroll(1)
          cy = h
        end
        t.setCursorPos(1, cy)
        col = 1
      end
    end
    -- advance line only on an actual newline
    if has_nl then
      cy = cy + 1
      if cy > h then
        t.scroll(1)
        cy = h
      end
      t.setCursorPos(1, cy)
    end
  end
end

-- 1. Loader
K.loader = loadfile("/knuck/kernel/loader.lua", "t", K.env)()

-- 2. Self-diagnostics
local diag = K.loader.load("/knuck/kernel/diag.lua", K)
K.diag = diag
K.selfcheck = diag.run(K)

-- 3. Core modules
K.sched = K.loader.load("/knuck/kernel/sched.lua", K)
K.syscall = K.loader.load("/knuck/kernel/syscall.lua", K)
K.proc = K.loader.load("/knuck/kernel/proc.lua", K)
K.fs = K.loader.load("/knuck/kernel/fs.lua", K)
K.vfs = K.loader.load("/knuck/kernel/vfs.lua", K)
K.ipc = K.loader.load("/knuck/kernel/ipc.lua", K)
K.net = K.loader.load("/knuck/kernel/net.lua", K)
K.net_transport = K.loader.load("/knuck/kernel/net_transport.lua", K)
K.auth = K.loader.load("/knuck/kernel/auth.lua", K)
K.tty = K.loader.load("/knuck/kernel/tty.lua", K)

-- 4. Init modules (dependency order)
K.syscall.init(K)
K.proc.init(K)
K.vfs.init(K)
K.sched.init(K)

-- 5. Mount VFS
K.vfs.mount_root()

-- 5b. Init network (gracefully disables if no modem)
K.net.init()
K.net_transport.init()

-- 5c. Load account database
K.auth.init(K)

-- 5d. Init virtual terminals
K.tty.init(K)

-- 6. Boot banner
term.clear()
term.setCursorPos(1, 1)
term.setTextColor(colors.green)
print("KNUCK " .. (K.selfcheck.craftos or "?") .. " boot")
term.setTextColor(colors.white)
if K.selfcheck.preempt then
  print("  scheduler: preemptive")
else
  print("  scheduler: cooperative (no yield-from-hook)")
end
if not K.selfcheck.collectgarbage then
  print("  memory: soft mode (no collectgarbage)")
end

-- 7. Spawn init (pid 1)
local init_pid = K.proc.spawn("/knuck/sbin/init.lua", 0, 0, 0, {})
if init_pid then
  K.proc.set_init(init_pid)
  print("  init pid " .. init_pid)
else
  print("  ERROR: failed to spawn init")
end

-- 8. Start scheduler (never returns)
K.sched.start()