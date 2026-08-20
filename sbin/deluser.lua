--[[
  KNUCK deluser
  =============
  Remove a user from /etc/passwd. Root only.
  Usage: deluser <name>
]]

local name = ...
if not name then
  print("usage: deluser <name>")
  exit(1)
end

if getuid() ~= 0 then
  print("deluser: must be root")
  exit(1)
end

local f = open("/etc/passwd", "r")
if not f then
  print("deluser: cannot open /etc/passwd")
  exit(1)
end
local data = read(f, 65536)
close(f)
if not data then
  print("deluser: cannot read /etc/passwd")
  exit(1)
end

local found = false
local out = {}
for line in data:gmatch("[^\r\n]+") do
  local uname = line:match("^([^:]+):")
  if uname == name then
    found = true
  else
    out[#out + 1] = line
  end
end

if not found then
  print("deluser: user " .. name .. " not found")
  exit(1)
end

local f2 = open("/etc/passwd", "w")
if not f2 then
  print("deluser: cannot write /etc/passwd")
  exit(1)
end
write(f2, table.concat(out, "\n") .. "\n")
close(f2)

print("deluser: removed " .. name)
exit(0)