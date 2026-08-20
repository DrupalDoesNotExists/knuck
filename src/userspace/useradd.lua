--[[
  KNUCK useradd
  =============
  Add a user to /etc/passwd. Root only.
  Usage: useradd <name> [uid] [gid] [home]
]]

local name = ...
if not name then
  print("usage: useradd <name> [uid] [gid] [home]")
  exit(1)
end

if getuid() ~= 0 then
  print("useradd: must be root")
  exit(1)
end

-- Find next free uid/gid
local uid = tonumber(select(1, ...)) or 1000
local gid = tonumber(select(2, ...)) or uid
local home = select(3, ...) or ("/home/" .. name)

if getpwnam(name) then
  print("useradd: user " .. name .. " already exists")
  exit(1)
end

local f = open("/etc/passwd", "a")
if not f then
  print("useradd: cannot open /etc/passwd")
  exit(1)
end
write(f, name .. ":x:" .. uid .. ":" .. gid .. "::" .. home .. ":/knuck/sbin/sh.lua\n")
close(f)

-- Create home dir
mkdir(home, 0x1ED)
chown(home, uid, gid)

print("useradd: added " .. name .. " (uid " .. uid .. ", gid " .. gid .. ")")
exit(0)