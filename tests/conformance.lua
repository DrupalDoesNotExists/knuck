--[[
  KNUCK Platform Conformance Test
  ================================
  Probes the CC/Lua environment on a real computer.
  Run on a real CC computer (CraftOS / CC:Tweaked).

  Result: OK / LIMITED / CUT / ERROR per function, shown line by line.
  Press any key to advance, screen clears between lines.

  Safe: does not reboot, delete, or write to system paths.
]]

local results = {}
local function report(name, status, detail)
  results[#results + 1] = { name = name, status = status, detail = detail }
end

-- Paged output: line -> wait for key -> clear screen
local function page(text)
  term.clear()
  term.setCursorPos(1, 1)
  io.write(text .. "\n")
  io.write("--- press any key ---")
  os.pullEvent("key")
end

local function section(title)
  page("===== " .. title .. " =====")
end

-- Check + show immediately + collect
local function check(name, status, detail)
  detail = detail or ""
  report(name, status, detail)
  page(string.format("[%s] %s%s", status, name, detail ~= "" and (" - " .. detail) or ""))
end

local function ok(name, detail)
  check(name, "OK", detail)
end

local function limited(name, detail)
  check(name, "LIMITED", detail)
end

local function cut(name, detail)
  check(name, "CUT", detail)
end

local function err(name, detail)
  check(name, "ERROR", detail)
end

-- Run fn, report OK on success / ERROR on failure
local function probe(name, fn)
  local ok_, res = pcall(fn)
  if ok_ then
    ok(name, tostring(res))
  else
    err(name, tostring(res))
  end
end

-- Check a library function exists
local function libfn(lib, fn)
  return type(lib) == "table" and type(lib[fn]) == "function"
end

-- ============================================================
-- SECTION 1: LUA RUNTIME
-- ============================================================
section("1. LUA RUNTIME")

-- 1.1 Version
local luaver = _VERSION or "unknown"
page("Lua version: " .. tostring(luaver))
if luaver:find("5.2") or luaver:find("5.3") or luaver:find("5.4") then
  ok("lua_version", luaver)
else
  limited("lua_version", luaver)
end
page("CraftOS: " .. tostring(os.version and os.version() or "unknown"))

-- 1.2 Standard libraries
local stdlibs = { "string", "table", "math", "coroutine", "io", "os", "debug" }
for _, lib in ipairs(stdlibs) do
  if type(_G[lib]) == "table" then
    ok("lib." .. lib, "present")
  else
    cut("lib." .. lib, "missing")
  end
end

-- 1.3 Optional libraries
local optlibs = { "bit32", "bit", "utf8", "package" }
for _, lib in ipairs(optlibs) do
  if type(_G[lib]) == "table" then
    ok("lib." .. lib, "present")
  else
    cut("lib." .. lib, "missing")
  end
end

-- 1.4 string functions
local string_funcs = { "byte", "char", "find", "format", "gmatch", "gsub",
  "len", "lower", "match", "rep", "reverse", "sub", "upper" }
local missing = {}
for _, f in ipairs(string_funcs) do
  if not libfn(string, f) then missing[#missing + 1] = f end
end
if #missing == 0 then
  ok("string.api", "all core functions present")
else
  limited("string.api", "missing: " .. table.concat(missing, ", "))
end

-- 1.5 table functions
local table_funcs = { "concat", "insert", "remove", "sort", "unpack" }
missing = {}
for _, f in ipairs(table_funcs) do
  if not libfn(table, f) then missing[#missing + 1] = f end
end
if #missing == 0 then
  ok("table.api", "all core functions present")
else
  limited("table.api", "missing: " .. table.concat(missing, ", "))
end

-- 1.6 math functions (5.2 set; pow/log10/atan2/cosh/sinh/tanh are 5.1-only)
local math_funcs = { "abs", "ceil", "floor", "max", "min", "random", "randomseed",
  "sqrt", "sin", "cos", "tan", "log", "exp", "fmod", "modf", "deg", "rad" }
missing = {}
for _, f in ipairs(math_funcs) do
  if not libfn(math, f) then missing[#missing + 1] = f end
end
-- math constants (numbers, not functions)
local math_consts = { "huge", "pi" }
local missing_consts = {}
for _, c in ipairs(math_consts) do
  if type(math[c]) ~= "number" then missing_consts[#missing_consts + 1] = c end
end
if #missing == 0 and #missing_consts == 0 then
  ok("math.api", "all core functions and constants present")
else
  local parts = {}
  if #missing > 0 then parts[#parts + 1] = "funcs: " .. table.concat(missing, ", ") end
  if #missing_consts > 0 then parts[#parts + 1] = "consts: " .. table.concat(missing_consts, ", ") end
  limited("math.api", table.concat(parts, "; "))
end

-- 1.7 coroutine
local coro_funcs = { "create", "resume", "yield", "status", "wrap", "isyieldable" }
missing = {}
for _, f in ipairs(coro_funcs) do
  if not libfn(coroutine, f) then missing[#missing + 1] = f end
end
if #missing == 0 then
  ok("coroutine.api", "all core functions present")
else
  limited("coroutine.api", "missing: " .. table.concat(missing, ", "))
end

-- 1.8 error handling
if type(pcall) == "function" and type(xpcall) == "function" then
  ok("error_handling", "pcall/xpcall present")
else
  cut("error_handling", "pcall/xpcall missing")
end

-- 1.9 collectgarbage
if type(collectgarbage) == "function" then
  ok("collectgarbage", "present, count=" .. tostring(collectgarbage("count")))
else
  cut("collectgarbage", "missing")
end

-- 1.10 load / loadstring
if type(load) == "function" then
  ok("load", "present")
else
  cut("load", "missing")
end
if type(loadstring) == "function" then
  ok("loadstring", "present")
else
  cut("loadstring", "missing")
end

-- 1.11 Sandbox: load with custom _ENV
local function make_sandbox()
  return {
    print = print, string = string, math = math, table = table,
    type = type, tostring = tostring, pairs = pairs, ipairs = ipairs,
    select = select, error = error, pcall = pcall, xpcall = xpcall,
    next = next, rawget = rawget, rawset = rawset,
    setmetatable = setmetatable, getmetatable = getmetatable,
    unpack = table.unpack or unpack,
  }
end
local ok_load, load_res = pcall(function()
  local chunk = load("return type(os) == 'nil' and type(fs) == 'nil'", "sandbox-test", "t", make_sandbox())
  return chunk and chunk()
end)
if ok_load and load_res == true then
  ok("sandbox_env", "load with custom _ENV works, os/fs invisible")
else
  limited("sandbox_env", "load with env: " .. tostring(load_res))
end

-- 1.12 debug.sethook + count hook
local sethook_ok = libfn(debug, "sethook")
if sethook_ok then
  ok("debug.sethook", "present")
else
  cut("debug.sethook", "debug library or sethook missing")
end

-- 1.13 yield from count hook (key for preemptive scheduler)
if sethook_ok then
  local co = coroutine.create(function()
    local n = 0
    for i = 1, 10000 do n = n + i end
    return n
  end)
  local hook_fired = false
  local hook_yielded = false
  local ok_hook, res_hook = pcall(function()
    debug.sethook(co, function()
      hook_fired = true
      coroutine.yield("HOOK_YIELD")
    end, "", 100)
    local ok_res, val = coroutine.resume(co)
    if ok_res and val == "HOOK_YIELD" then
      hook_yielded = true
      local ok_res2, val2 = coroutine.resume(co)
      return ok_res2, val2
    end
    return ok_res, val
  end)
  if hook_fired and hook_yielded then
    ok("yield_from_hook", "count hook fired and yielded, coroutine resumed")
  else
    cut("yield_from_hook", "hook fired=" .. tostring(hook_fired) ..
      " yielded=" .. tostring(hook_yielded) .. " res=" .. tostring(res_hook))
  end
  debug.sethook(co)
else
  cut("yield_from_hook", "no sethook")
end

-- 1.14 debug functions
local debug_funcs = { "traceback", "getinfo", "getlocal", "setlocal", "getupvalue",
  "setupvalue", "getmetatable", "setmetatable", "getregistry" }
missing = {}
for _, f in ipairs(debug_funcs) do
  if not libfn(debug, f) then missing[#missing + 1] = f end
end
if #missing == 0 then
  ok("debug.api", "all core functions present")
else
  limited("debug.api", "missing: " .. table.concat(missing, ", "))
end

-- ============================================================
-- SECTION 2: CRAFTOS APIS
-- ============================================================
section("2. CRAFTOS APIS")

-- 2.1 os
local os_funcs = { "time", "clock", "startTimer", "cancelTimer", "pullEvent",
  "pullEventRaw", "queueEvent", "sleep", "shutdown", "reboot", "setComputerLabel",
  "getComputerLabel", "day", "epoch", "version" }
missing = {}
for _, f in ipairs(os_funcs) do
  if not libfn(os, f) then missing[#missing + 1] = f end
end
if #missing == 0 then
  ok("os.api", "all core functions present")
else
  limited("os.api", "missing: " .. table.concat(missing, ", "))
end

probe("os.time", function() return os.time() end)
probe("os.clock", function() return os.clock() end)
probe("os.version", function() return os.version() end)
probe("os.day", function() return os.day() end)
probe("os.epoch", function() return os.epoch("utc") end)
probe("os.getComputerLabel", function() return os.getComputerLabel() or "none" end)

-- 2.2 fs
local fs_funcs = { "open", "list", "exists", "isDir", "isReadOnly", "getSize",
  "makeDir", "delete", "rename", "getDrive", "getFreeSpace", "find", "getCapacity",
  "attributes", "combine", "getName", "getDir" }
missing = {}
for _, f in ipairs(fs_funcs) do
  if not libfn(fs, f) then missing[#missing + 1] = f end
end
if #missing == 0 then
  ok("fs.api", "all core functions present")
else
  limited("fs.api", "missing: " .. table.concat(missing, ", "))
end

-- fs handle methods (close/read/write/seek are handle methods, not fs.*)
probe("fs.handle", function()
  local h = fs.open("/tmp/knuck_handle.txt", "w+")
  if not h then error("open failed") end
  local methods = { "close", "read", "write", "seek", "readAll", "readLine", "writeLine" }
  local miss = {}
  for _, m in ipairs(methods) do
    if type(h[m]) ~= "function" then miss[#miss + 1] = m end
  end
  h.close()
  fs.delete("/tmp/knuck_handle.txt")
  if #miss > 0 then error("missing: " .. table.concat(miss, ", ")) end
  return "all handle methods present"
end)

-- fs read/write roundtrip in /tmp
probe("fs.rw", function()
  local h = fs.open("/tmp/knuck_probe.txt", "w")
  if not h then error("open failed") end
  h.write("probe")
  h.close()
  h = fs.open("/tmp/knuck_probe.txt", "r")
  local data = h.readAll()
  h.close()
  fs.delete("/tmp/knuck_probe.txt")
  return data
end)

-- 2.3 term
local term_funcs = { "write", "clear", "clearLine", "getCursorPos", "setCursorPos",
  "getSize", "scroll", "setTextColor", "setBackgroundColor", "isColor", "blit",
  "redirect", "nativePaletteColor", "setPaletteColor", "getPaletteColor" }
missing = {}
for _, f in ipairs(term_funcs) do
  if not libfn(term, f) then missing[#missing + 1] = f end
end
if #missing == 0 then
  ok("term.api", "all core functions present")
else
  limited("term.api", "missing: " .. table.concat(missing, ", "))
end

probe("term.getSize", function()
  local w, h = term.getSize()
  return w .. "x" .. h
end)
probe("term.isColor", function() return tostring(term.isColor()) end)

-- 2.4 peripheral
if type(peripheral) == "table" then
  ok("peripheral.api", "present")
  local sides = peripheral.getNames and peripheral.getNames() or {}
  page("  peripherals: " .. table.concat(sides, ", "))
  for _, side in ipairs(sides) do
    probe("peripheral." .. side, function()
      local t = peripheral.getType(side)
      local methods = peripheral.getMethods and peripheral.getMethods(side) or {}
      return t .. " methods=" .. #methods
    end)
  end
else
  cut("peripheral.api", "peripheral table missing")
end

-- 2.5 http
if type(http) == "table" then
  ok("http.api", "present")
  local http_funcs = { "get", "post", "request", "checkURL", "websocket" }
  missing = {}
  for _, f in ipairs(http_funcs) do
    if not libfn(http, f) then missing[#missing + 1] = f end
  end
  if #missing == 0 then
    ok("http.api", "all core functions present")
  else
    limited("http.api", "missing: " .. table.concat(missing, ", "))
  end
else
  cut("http.api", "http table missing")
end

-- 2.6 rednet
if type(rednet) == "table" then
  ok("rednet.api", "present")
  local rednet_funcs = { "open", "close", "send", "broadcast", "receive", "host",
    "unhost", "lookup", "isOpen" }
  missing = {}
  for _, f in ipairs(rednet_funcs) do
    if not libfn(rednet, f) then missing[#missing + 1] = f end
  end
  if #missing == 0 then
    ok("rednet.api", "all core functions present")
  else
    limited("rednet.api", "missing: " .. table.concat(missing, ", "))
  end
else
  cut("rednet.api", "rednet table missing")
end

-- 2.7 colors
if type(colors) == "table" then
  ok("colors.api", "present")
else
  cut("colors.api", "colors table missing")
end

-- 2.8 component (CC:Tweaked)
if type(component) == "table" then
  ok("component.api", "present")
  probe("component.list", function()
    local n = 0
    for _ in component.list() do n = n + 1 end
    return n .. " components"
  end)
else
  cut("component.api", "component table missing")
end

-- 2.9 textutils
if type(textutils) == "table" then
  ok("textutils.api", "present")
  local textutils_funcs = { "serialize", "unserialize", "format", "pagedPrint",
    "tabulate", "slowPrint", "complete", "serializeJSON", "unserializeJSON" }
  missing = {}
  for _, f in ipairs(textutils_funcs) do
    if not libfn(textutils, f) then missing[#missing + 1] = f end
  end
  if #missing == 0 then
    ok("textutils.api", "all core functions present")
  else
    limited("textutils.api", "missing: " .. table.concat(missing, ", "))
  end
else
  cut("textutils.api", "textutils table missing")
end

-- 2.10 settings
if type(settings) == "table" then
  ok("settings.api", "present")
else
  cut("settings.api", "settings table missing")
end

-- 2.11 keys
if type(keys) == "table" then
  ok("keys.api", "present")
else
  cut("keys.api", "keys table missing")
end

-- 2.12 vector
if type(vector) == "table" then
  ok("vector.api", "present")
else
  cut("vector.api", "vector table missing")
end

-- 2.13 turtle (turtle computer only)
if type(turtle) == "table" then
  ok("turtle.api", "present")
else
  cut("turtle.api", "not a turtle computer")
end

-- 2.14 pocket (pocket computer only)
if type(pocket) == "table" then
  ok("pocket.api", "present")
else
  cut("pocket.api", "not a pocket computer")
end

-- 2.15 commands (command computer only)
if type(commands) == "table" then
  ok("commands.api", "present")
else
  cut("commands.api", "not a command computer")
end

-- 2.16 multishell
if type(multishell) == "table" then
  ok("multishell.api", "present")
else
  cut("multishell.api", "multishell table missing")
end

-- 2.17 io
if type(io) == "table" then
  ok("io.api", "present")
  local io_funcs = { "open", "close", "read", "write", "lines", "flush", "input", "output" }
  missing = {}
  for _, f in ipairs(io_funcs) do
    if not libfn(io, f) then missing[#missing + 1] = f end
  end
  if #missing == 0 then
    ok("io.api", "all core functions present")
  else
    limited("io.api", "missing: " .. table.concat(missing, ", "))
  end
else
  cut("io.api", "io table missing")
end

-- ============================================================
-- SECTION 3: EVENTS
-- ============================================================
section("3. EVENTS")

-- 3.1 timer event roundtrip
probe("event.timer", function()
  local id = os.startTimer(0.05)
  local ev, tid = os.pullEvent("timer")
  if ev ~= "timer" or tid ~= id then error("bad timer event") end
  return "timer fired"
end)

-- 3.2 queueEvent roundtrip
probe("event.queue", function()
  os.queueEvent("knuck_probe", 42)
  local ev, val = os.pullEvent("knuck_probe")
  if ev ~= "knuck_probe" or val ~= 42 then error("bad queued event") end
  return "queued event received"
end)

-- 3.3 pullEventRaw
if libfn(os, "pullEventRaw") then
  ok("event.pullEventRaw", "present")
else
  cut("event.pullEventRaw", "missing")
end

-- 3.4 cancelTimer
probe("event.cancelTimer", function()
  local id = os.startTimer(0.05)
  os.cancelTimer(id)
  return "cancelled"
end)

-- ============================================================
-- SECTION 4: HARDWARE
-- ============================================================
section("4. HARDWARE")

-- 4.1 Modem
local modem_side = nil
if type(peripheral) == "table" and peripheral.find then
  modem_side = peripheral.find("modem")
end
if modem_side then
  ok("hw.modem", "found on " .. tostring(modem_side))
  probe("hw.modem.open", function()
    local m = peripheral.wrap(modem_side)
    m.open(1)
    local ok_ = rednet.isOpen and rednet.isOpen(1)
    m.close(1)
    return "channel 1 ok"
  end)
else
  cut("hw.modem", "no modem attached")
end

-- 4.2 Monitor
local monitor_side = nil
if type(peripheral) == "table" and peripheral.find then
  monitor_side = peripheral.find("monitor")
end
if monitor_side then
  ok("hw.monitor", "found on " .. tostring(monitor_side))
else
  cut("hw.monitor", "no monitor attached")
end

-- 4.3 Disk drive
local disk_side = nil
if type(peripheral) == "table" and peripheral.find then
  disk_side = peripheral.find("drive")
end
if disk_side then
  ok("hw.drive", "found on " .. tostring(disk_side))
  probe("hw.drive.hasDisk", function()
    local d = peripheral.wrap(disk_side)
    return tostring(d.hasDisk())
  end)
else
  cut("hw.drive", "no disk drive attached")
end

-- 4.4 Printer
local printer_side = nil
if type(peripheral) == "table" and peripheral.find then
  printer_side = peripheral.find("printer")
end
if printer_side then
  ok("hw.printer", "found on " .. tostring(printer_side))
else
  cut("hw.printer", "no printer attached")
end

-- 4.5 Speaker
local speaker_side = nil
if type(peripheral) == "table" and peripheral.find then
  speaker_side = peripheral.find("speaker")
end
if speaker_side then
  ok("hw.speaker", "found on " .. tostring(speaker_side))
else
  cut("hw.speaker", "no speaker attached")
end

-- 4.6 Storage
probe("hw.storage", function()
  local root = fs.getDrive("/")
  local free = fs.getFreeSpace("/")
  return "drive=" .. tostring(root) .. " free=" .. tostring(free)
end)

-- ============================================================
-- SECTION 5: SANDBOX / ISOLATION
-- ============================================================
section("5. SANDBOX / ISOLATION")

-- 5.1 _ENV visibility
probe("sandbox.env_visibility", function()
  local env = getfenv and getfenv(1) or _ENV
  local visible = {}
  for _, name in ipairs({ "os", "fs", "term", "peripheral", "http", "rednet", "io", "debug" }) do
    if env[name] ~= nil then visible[#visible + 1] = name end
  end
  return "visible in env: " .. table.concat(visible, ", ")
end)

-- 5.2 load with custom env (isolation feasibility)
probe("sandbox.load_env", function()
  local chunk = load("return type(os) == 'nil' and type(fs) == 'nil' and type(term) == 'nil'", "s", "t", make_sandbox())
  return chunk and chunk()
end)

-- 5.3 setfenv/getfenv (5.1 compat)
if type(setfenv) == "function" and type(getfenv) == "function" then
  ok("sandbox.setfenv", "present (5.1 compat)")
else
  cut("sandbox.setfenv", "missing (5.2 _ENV only)")
end

-- ============================================================
-- SECTION 6: PRECISION / TIMING
-- ============================================================
section("6. TIMING")

-- 6.1 sleep precision
probe("timing.sleep", function()
  local t0 = os.clock()
  os.sleep(0.05)
  local dt = os.clock() - t0
  return string.format("%.3fs", dt)
end)

-- 6.2 timer precision
probe("timing.timer", function()
  local t0 = os.clock()
  os.startTimer(0.05)
  os.pullEvent("timer")
  local dt = os.clock() - t0
  return string.format("%.3fs", dt)
end)

-- 6.3 clock monotonicity
probe("timing.clock", function() return os.clock() end)

-- ============================================================
-- SUMMARY
-- ============================================================
section("SUMMARY")
local counts = { OK = 0, LIMITED = 0, CUT = 0, ERROR = 0 }
for _, r in ipairs(results) do
  counts[r.status] = (counts[r.status] or 0) + 1
end
page(string.format("OK: %d   LIMITED: %d   CUT: %d   ERROR: %d",
  counts.OK or 0, counts.LIMITED or 0, counts.CUT or 0, counts.ERROR or 0))

page("--- Details ---")
for _, r in ipairs(results) do
  page(string.format("[%s] %s%s", r.status, r.name, r.detail ~= "" and (" - " .. r.detail) or ""))
end

page("Test finished. Copy the output and send it to the developer.")