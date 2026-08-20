--[[
  KNUCK groupadd
  ==============
  Add a group to /etc/group. Root only.
  Usage: groupadd <name> [gid]
]]

local name = ...
if not name then
  print("usage: groupadd <name> [gid]")
  exit(1)
end

if getuid() ~= 0 then
  print("groupadd: must be root")
  exit(1)
end

local gid = tonumber(select(1, ...)) or 1000

if getgrnam(name) then
  print("groupadd: group " .. name .. " already exists")
  exit(1)
end

local f = open("/etc/group", "a")
if not f then
  print("groupadd: cannot open /etc/group")
  exit(1)
end
write(f, name .. ":x:" .. gid .. ":\n")
close(f)

print("groupadd: added " .. name .. " (gid " .. gid .. ")")
exit(0)