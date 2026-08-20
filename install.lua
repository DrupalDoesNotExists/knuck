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
  "kernel/vfs.lua",
  "kernel/drivers/term.lua",
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
print("Run the kernel:")
print("  lua " .. DEST .. "/knuck.lua")
print("")
print("To auto-start on boot, add to startup:")
print("  shell.run(\"" .. DEST .. "/knuck.lua\")")