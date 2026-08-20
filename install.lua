--[[
  KNUCK Installer
  ===============
  Downloads the KNUCK kernel from raw.githubusercontent and installs it.
  Run on a real CC computer (CraftOS 1.9).

  Usage:
    wget https://raw.githubusercontent.com/DrupalDoesNotExists/knuck/main/install.lua
    lua install.lua

  Requires http access to raw.githubusercontent.com only.
]]

local BASE = "https://raw.githubusercontent.com/DrupalDoesNotExists/knuck/main"
local DEST = "/knuck"

-- Files to install (relative to repo root, written under DEST)
local FILES = {
  "knuck.lua",
  "kernel/loader.lua",
  "kernel/diag.lua",
  "kernel/sched.lua",
  "kernel/syscall.lua",
  "kernel/proc.lua",
  "kernel/fs.lua",
  "kernel/vfs.lua",
  "kernel/ipc.lua",
  "kernel/net.lua",
  "kernel/net_transport.lua",
  "kernel/drivers/term.lua",
  "sbin/init.lua",
  "sbin/hello.lua",
  "sbin/ipc_child.lua",
  "sbin/sh.lua",
  "tests/vfs_ipc_test.lua",
}

local function ensure_dir(path)
  if fs.exists(path) then return end
  local parent = fs.getDir(path)
  if parent ~= path then ensure_dir(parent) end
  fs.makeDir(path)
end

local function download(url, dest)
  local ok, resp = pcall(http.get, url)
  if not ok or not resp then
    error("download failed: " .. url .. " (" .. tostring(resp) .. ")")
  end
  local data = resp.readAll()
  resp.close()
  if not data or #data == 0 then
    error("empty download: " .. url)
  end
  ensure_dir(fs.getDir(dest))
  local h = fs.open(dest, "w")
  if not h then error("cannot write " .. dest) end
  h.write(data)
  h.close()
  return #data
end

print("KNUCK installer")
print("Target: " .. DEST)
print("")

local total = 0
for _, f in ipairs(FILES) do
  local url = BASE .. "/" .. f
  local dest = DEST .. "/" .. f
  local n = download(url, dest)
  total = total + n
  print("  " .. f .. " (" .. n .. " bytes)")
end

print("")
print("Installed " .. #FILES .. " files, " .. total .. " bytes.")
print("")

-- Configure autostart so the kernel boots on CC startup.
-- CraftOS 1.9 runs /startup at boot. Append the kernel run line.
local STARTUP = "/startup"
local line = "shell.run(\"" .. DEST .. "/knuck.lua\")\n"
local existing = ""
if fs.exists(STARTUP) then
  local h = fs.open(STARTUP, "r")
  if h then
    existing = h.readAll() or ""
    h.close()
  end
end
if existing:find(line, 1, true) then
  print("Autostart already configured in " .. STARTUP)
else
  local h = fs.open(STARTUP, "w")
  if h then
    h.write(existing .. line)
    h.close()
    print("Autostart configured: appended to " .. STARTUP)
  else
    print("WARNING: could not write " .. STARTUP .. " - add manually:")
    print("  " .. line)
  end
end

print("")
print("Run the kernel now:")
print("  lua " .. DEST .. "/knuck.lua")
print("")
print("Debug shell (after boot):")
print("  lua " .. DEST .. "/sbin/sh.lua")