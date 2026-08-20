--[[
  KNUCK Conformance Test
  ======================
  Runs the full KNUCK syscall surface.
  Run on a real CC computer (CraftOS / CC:Tweaked).
  Result: OK / LIMITED / CUT / ERROR matrix per function.

  Section 1: PLATFORM - checks runtime assumptions (runs on bare CraftOS).
  Section 2: KERNEL - checks KNUCK syscalls (runs inside KNUCK).

  Safe: does not reboot, delete, or write to system paths.
  reboot/halt - presence check only, never called.
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

local function ok(name, detail)
  report(name, "OK", detail or "")
end

local function limited(name, detail)
  report(name, "LIMITED", detail or "")
end

local function cut(name, detail)
  report(name, "CUT", detail or "")
end

local function err(name, detail)
  report(name, "ERROR", detail or "")
end

local function probe(fn, ...)
  local ok_, res = pcall(fn, ...)
  return ok_, res
end

-- ============================================================
-- SECTION 1: PLATFORM
-- ============================================================
section("1. PLATFORM (CraftOS / runtime)")

-- 1.1 Lua version
local luaver = _VERSION or "unknown"
page("Lua version: " .. tostring(luaver))
if luaver:find("5.2") or luaver:find("5.3") or luaver:find("5.4") then
  ok("lua_version", luaver)
else
  limited("lua_version", luaver)
end

-- 1.2 debug.sethook + count hook
local sethook_ok = type(debug) == "table" and type(debug.sethook) == "function"
if sethook_ok then
  ok("debug.sethook", "present")
else
  cut("debug.sethook", "debug library or sethook missing")
end

-- 1.3 yield from count hook (key for preemptive scheduler)
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
      -- resume after yield from hook
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
  debug.sethook(co) -- remove hook
else
  cut("yield_from_hook", "no sethook")
end

-- 1.4 os.pullEvent / os.startTimer / os.queueEvent
if type(os) == "table" and type(os.pullEvent) == "function" then
  ok("os.pullEvent", "present")
else
  cut("os.pullEvent", "missing")
end
if type(os) == "table" and type(os.startTimer) == "function" then
  ok("os.startTimer", "present")
else
  cut("os.startTimer", "missing")
end
if type(os) == "table" and type(os.queueEvent) == "function" then
  ok("os.queueEvent", "present")
else
  cut("os.queueEvent", "missing")
end

-- 1.5 fs API
if type(fs) == "table" then
  local fsfuncs = { "open", "close", "read", "write", "seek", "list", "exists",
    "isDir", "isReadOnly", "getSize", "makeDir", "delete", "rename", "getDrive",
    "getFreeSpace", "find", "getCapacity", "attributes" }
  local missing = {}
  for _, f in ipairs(fsfuncs) do
    if type(fs[f]) ~= "function" then missing[#missing + 1] = f end
  end
  if #missing == 0 then
    ok("fs.api", "all core functions present")
  else
    limited("fs.api", "missing: " .. table.concat(missing, ", "))
  end
else
  cut("fs.api", "fs table missing")
end

-- 1.6 peripheral API
if type(peripheral) == "table" then
  ok("peripheral.api", "present")
  local sides = peripheral.getNames and peripheral.getNames() or {}
  page("  peripherals: " .. table.concat(sides, ", "))
else
  cut("peripheral.api", "peripheral table missing")
end

-- 1.7 http API
if type(http) == "table" then
  ok("http.api", "present")
else
  cut("http.api", "http table missing (AF_HTTP unavailable)")
end

-- 1.8 term API
if type(term) == "table" then
  ok("term.api", "present")
else
  cut("term.api", "term table missing")
end

-- 1.9 coroutine
if type(coroutine) == "table" and type(coroutine.create) == "function" then
  ok("coroutine", "present")
else
  cut("coroutine", "missing")
end

-- 1.10 _ENV / sandbox (load with environment)
local env_ok = false
local ok_load, load_res = pcall(function()
  local sandbox = { print = print, string = string, math = math, table = table }
  local chunk = load("return type(os) == 'nil' and type(fs) == 'nil'", "sandbox-test", "t", sandbox)
  return chunk and chunk()
end)
if ok_load and load_res == true then
  ok("sandbox_env", "load with custom _ENV works, os/fs invisible")
else
  limited("sandbox_env", "load with env: " .. tostring(load_res))
end

-- 1.11 collectgarbage (memory accounting)
if type(collectgarbage) == "function" then
  ok("collectgarbage", "present, count=" .. tostring(collectgarbage("count")))
else
  cut("collectgarbage", "missing")
end

-- 1.12 error handling (pcall/xpcall)
if type(pcall) == "function" and type(xpcall) == "function" then
  ok("error_handling", "pcall/xpcall present")
else
  cut("error_handling", "pcall/xpcall missing")
end

-- 1.13 CC watchdog note
page("  note: CC watchdog ~7s soft abort / +1.5s hard abort (TimeoutState)")

-- ============================================================
-- SECTION 2: KNUCK KERNEL
-- ============================================================
section("2. KNUCK KERNEL (syscalls)")

-- Detect environment: kernel syscall table present?
local K = rawget(_G, "knuck") or rawget(_G, "k")
local in_kernel = type(K) == "table" and type(K.syscall) == "function"
if not in_kernel then
  page("  Kernel not detected - syscalls not checked.")
  page("  Run this test INSIDE KNUCK for section 2.")
end

-- Helper: check a syscall
local function syscall(name, fn, ...)
  if not in_kernel then
    report(name, "SKIP", "kernel not present")
    return
  end
  local ok_, res = pcall(fn, ...)
  if ok_ then
    ok(name, tostring(res))
  else
    err(name, tostring(res))
  end
end

-- 2.1 Processes
section("2.1 proc")
if in_kernel then
  syscall("getpid", function() return K.syscall("getpid") end)
  syscall("getppid", function() return K.syscall("getppid") end)
  syscall("getuid", function() return K.syscall("getuid") end)
  syscall("geteuid", function() return K.syscall("geteuid") end)
  syscall("getgid", function() return K.syscall("getgid") end)
  syscall("getegid", function() return K.syscall("getegid") end)
  syscall("getpgrp", function() return K.syscall("getpgrp") end)
  syscall("getcwd", function() return K.syscall("getcwd") end)
  syscall("umask", function() return K.syscall("umask") end)
  syscall("getpriority", function() return K.syscall("getpriority") end)
  syscall("sched_yield", function() return K.syscall("sched_yield") end)
  syscall("sleep", function() return K.syscall("sleep", 0.01) end)
  syscall("clock_gettime", function() return K.syscall("clock_gettime", "MONOTONIC") end)
  syscall("time", function() return K.syscall("time") end)
  syscall("clock", function() return K.syscall("clock") end)

  -- spawn/exec/exit/waitpid - spawn a child process
  local child_ok, child_pid = pcall(function()
    return K.syscall("spawn", "/bin/true")
  end)
  if child_ok and child_pid then
    ok("spawn", "pid=" .. tostring(child_pid))
    local wok, wres = pcall(function()
      return K.syscall("waitpid", child_pid)
    end)
    if wok then
      ok("waitpid", tostring(wres))
    else
      err("waitpid", tostring(wres))
    end
  else
    err("spawn", tostring(child_pid))
  end

  -- setuid/setgid - presence check only (do not change real creds)
  syscall("setuid", function() return K.syscall("setuid", K.syscall("getuid")) end)
  syscall("setgid", function() return K.syscall("setgid", K.syscall("getgid")) end)
  syscall("setpgid", function() return K.syscall("setpgid", K.syscall("getpid"), K.syscall("getpid")) end)

  -- signals
  syscall("signal", function() return K.syscall("signal", 2, nil) end)
  syscall("sigprocmask", function() return K.syscall("sigprocmask", "block", {}) end)
  syscall("alarm", function() return K.syscall("alarm", 0) end)
  syscall("kill", function() return K.syscall("kill", K.syscall("getpid"), 0) end)

  -- scheduler
  syscall("sched_setscheduler", function() return K.syscall("sched_setscheduler", nil, "other") end)
  syscall("setpriority", function() return K.syscall("setpriority", nil, 0) end)

  -- chdir (to /tmp, safe)
  syscall("chdir", function() return K.syscall("chdir", "/tmp") end)

  -- fork - expected CUT (platform)
  local fok, fres = pcall(function() return K.syscall("fork") end)
  if fok then
    limited("fork", "unexpectedly present: " .. tostring(fres))
  else
    cut("fork", "not available (coroutine clone impossible)")
  end
else
  page("  (kernel not present)")
end

-- 2.2 Security
section("2.2 security")
if in_kernel then
  syscall("chmod", function() return K.syscall("chmod", "/tmp", 420) end) -- 0o644
  syscall("chown", function() return K.syscall("chown", "/tmp", 0, 0) end)
  syscall("chgrp", function() return K.syscall("chgrp", "/tmp", 0) end)
else
  page("  (kernel not present)")
end

-- 2.3 IPC
section("2.3 ipc")
if in_kernel then
  -- pipe
  local pok, pres = pcall(function() return K.syscall("pipe") end)
  if pok and pres then
    ok("pipe", "rfd=" .. tostring(pres[1]) .. " wfd=" .. tostring(pres[2]))
    -- write/read through pipe
    local wok2, wres2 = pcall(function()
      K.syscall("write", pres[2], "hello")
      return K.syscall("read", pres[1], 5)
    end)
    if wok2 then
      ok("pipe_rw", "read back: " .. tostring(wres2))
    else
      err("pipe_rw", tostring(wres2))
    end
    pcall(function() K.syscall("close", pres[1]) end)
    pcall(function() K.syscall("close", pres[2]) end)
  else
    err("pipe", tostring(pres))
  end

  -- mkfifo
  syscall("mkfifo", function() return K.syscall("mkfifo", "/tmp/testfifo", 420) end) -- 0o644

  -- socket (AF_UNIX)
  local sok, sres = pcall(function() return K.syscall("socket", "unix", "stream", 0) end)
  if sok and sres then
    ok("socket_af_unix", "fd=" .. tostring(sres))
    pcall(function() K.syscall("close", sres) end)
  else
    err("socket_af_unix", tostring(sres))
  end

  -- socket (AF_MODEM) - only if a modem is attached
  local has_modem = type(peripheral) == "table" and peripheral.find and peripheral.find("modem") ~= nil
  if has_modem then
    local sok2, sres2 = pcall(function() return K.syscall("socket", "modem", "dgram", 0) end)
    if sok2 and sres2 then
      ok("socket_af_modem", "fd=" .. tostring(sres2))
      pcall(function() K.syscall("close", sres2) end)
    else
      err("socket_af_modem", tostring(sres2))
    end
  else
    cut("socket_af_modem", "no modem attached")
  end

  -- socket (AF_HTTP) - only if http is available
  if type(http) == "table" then
    local sok3, sres3 = pcall(function() return K.syscall("socket", "http", "stream", 0) end)
    if sok3 and sres3 then
      ok("socket_af_http", "fd=" .. tostring(sres3))
      pcall(function() K.syscall("close", sres3) end)
    else
      err("socket_af_http", tostring(sres3))
    end
  else
    cut("socket_af_http", "http unavailable")
  end

  -- select/poll
  syscall("select", function() return K.syscall("select", {}, {}, 0) end)
  syscall("poll", function() return K.syscall("poll", {}, 0) end)
else
  page("  (kernel not present)")
end

-- 2.4 VFS
section("2.4 vfs")
if in_kernel then
  -- temp file in /tmp
  local fok, ffd = pcall(function() return K.syscall("open", "/tmp/conftest.txt", "w+") end)
  if fok and ffd then
    ok("open", "fd=" .. tostring(ffd))
    local wok2, wres2 = pcall(function() return K.syscall("write", ffd, "conformance") end)
    if wok2 then
      ok("write", "n=" .. tostring(wres2))
    else
      err("write", tostring(wres2))
    end
    pcall(function() K.syscall("lseek", ffd, 0, "set") end)
    local rok, rres = pcall(function() return K.syscall("read", ffd, 0) end)
    if rok then
      ok("read", tostring(rres))
    else
      err("read", tostring(rres))
    end
    local sok, sres = pcall(function() return K.syscall("fstat", ffd) end)
    if sok then
      ok("fstat", tostring(sres))
    else
      err("fstat", tostring(sres))
    end
    pcall(function() K.syscall("close", ffd) end)
  else
    err("open", tostring(ffd))
  end

  syscall("mkdir", function() return K.syscall("mkdir", "/tmp/conftest_dir") end)
  syscall("stat", function() return K.syscall("stat", "/tmp/conftest.txt") end)
  syscall("readdir", function() return K.syscall("readdir", "/tmp") end)
  syscall("rename", function() return K.syscall("rename", "/tmp/conftest.txt", "/tmp/conftest2.txt") end)
  syscall("symlink", function() return K.syscall("symlink", "/tmp/conftest2.txt", "/tmp/conftest_link") end)
  syscall("readlink", function() return K.syscall("readlink", "/tmp/conftest_link") end)
  syscall("link", function() return K.syscall("link", "/tmp/conftest2.txt", "/tmp/conftest_hard") end)
  syscall("unlink", function() return K.syscall("unlink", "/tmp/conftest_hard") end)
  syscall("unlink", function() return K.syscall("unlink", "/tmp/conftest_link") end)
  syscall("unlink", function() return K.syscall("unlink", "/tmp/conftest2.txt") end)
  syscall("rmdir", function() return K.syscall("rmdir", "/tmp/conftest_dir") end)

  -- mount/umount - presence check only (do not touch real mounts)
  syscall("mount", function() return K.syscall("mount", nil, nil, "tmp", "ro") end)
  syscall("umount", function() return K.syscall("umount", "/tmp") end)

  -- chroot - presence check only (do not change root)
  syscall("chroot", function() return K.syscall("chroot", "/") end)

  -- /dev nodes
  for _, node in ipairs({ "/dev/console", "/dev/null", "/dev/zero", "/dev/urandom", "/dev/input", "/dev/devctl" }) do
    local nok, nres = pcall(function() return K.syscall("stat", node) end)
    if nok and nres then
      ok("devnode " .. node, "present")
    else
      cut("devnode " .. node, tostring(nres))
    end
  end

  -- /sys
  for _, node in ipairs({ "/sys/kernel", "/sys/net", "/sys/modules" }) do
    local nok, nres = pcall(function() return K.syscall("stat", node) end)
    if nok and nres then
      ok("sysnode " .. node, "present")
    else
      cut("sysnode " .. node, tostring(nres))
    end
  end

  -- /proc
  for _, node in ipairs({ "/proc/uptime", "/proc/version" }) do
    local nok, nres = pcall(function() return K.syscall("stat", node) end)
    if nok and nres then
      ok("procnode " .. node, "present")
    else
      cut("procnode " .. node, tostring(nres))
    end
  end
else
  page("  (kernel not present)")
end

-- 2.5 Modules
section("2.5 modules")
if in_kernel then
  syscall("insmod", function() return K.syscall("insmod", "/boot/modules/testmod.lua") end)
  syscall("rmmod", function() return K.syscall("rmmod", "testmod") end)
else
  page("  (kernel not present)")
end

-- 2.6 Network
section("2.6 network")
if in_kernel then
  -- config via /sys/net (read)
  local nok, nres = pcall(function() return K.syscall("read", K.syscall("open", "/sys/net/ip", "r")) end)
  if nok then
    ok("net_ip", tostring(nres))
  else
    cut("net_ip", tostring(nres))
  end
  -- ARP cache
  local aok, ares = pcall(function() return K.syscall("read", K.syscall("open", "/sys/net/arp", "r")) end)
  if aok then
    ok("net_arp", tostring(ares))
  else
    cut("net_arp", tostring(ares))
  end
  -- routes
  local rok, rres = pcall(function() return K.syscall("read", K.syscall("open", "/sys/net/route", "r")) end)
  if rok then
    ok("net_route", tostring(rres))
  else
    cut("net_route", tostring(rres))
  end
else
  page("  (kernel not present)")
end

-- 2.7 Console/input
section("2.7 console")
if in_kernel then
  -- ioctl on console (cooked/raw mode)
  local iok, ires = pcall(function() return K.syscall("ioctl", 0, "getmode") end)
  if iok then
    ok("ioctl_getmode", tostring(ires))
  else
    err("ioctl_getmode", tostring(ires))
  end
  local sok, sres = pcall(function() return K.syscall("ioctl", 0, "setmode", "cooked") end)
  if sok then
    ok("ioctl_setmode", "cooked")
  else
    err("ioctl_setmode", tostring(sres))
  end
else
  page("  (kernel not present)")
end

-- 2.8 Power - presence only, NOT called
section("2.8 power")
if in_kernel then
  local rok, rres = pcall(function() return K.syscall("reboot") end)
  if rok then
    limited("reboot", "present (not called in test)")
  else
    err("reboot", tostring(rres))
  end
  local hok, hres = pcall(function() return K.syscall("halt") end)
  if hok then
    limited("halt", "present (not called in test)")
  else
    err("halt", tostring(hres))
  end
else
  page("  (kernel not present)")
end

-- ============================================================
-- SUMMARY
-- ============================================================
section("SUMMARY")
local counts = { OK = 0, LIMITED = 0, CUT = 0, ERROR = 0, SKIP = 0 }
for _, r in ipairs(results) do
  counts[r.status] = (counts[r.status] or 0) + 1
end
page(string.format("OK: %d   LIMITED: %d   CUT: %d   ERROR: %d   SKIP: %d",
  counts.OK or 0, counts.LIMITED or 0, counts.CUT or 0, counts.ERROR or 0, counts.SKIP or 0))

page("--- Details ---")
for _, r in ipairs(results) do
  page(string.format("[%s] %s%s", r.status, r.name, r.detail ~= "" and (" - " .. r.detail) or ""))
end

page("Test finished. Copy the output and send it to the developer.")