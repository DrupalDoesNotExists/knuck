--[[
  KNUCK init (pid 1)
  ==================
  First milestone: minimal init. Prints a banner and exits.
  Later: reads /boot/init.rc (Android-style services/actions) and
  supervises child processes.
]]

local pid = getpid()
print("init: pid " .. pid .. " running")
print("init: uid " .. getuid() .. " gid " .. getgid())
print("init: cwd " .. getcwd())

-- Spawn a test child to exercise spawn/waitpid
local child = spawn("/knuck/sbin/hello.lua", "world")
if child then
  print("init: spawned child pid " .. child)
  local cpid, status, code = waitpid(child)
  print("init: child " .. cpid .. " " .. status .. " " .. tostring(code))
else
  print("init: spawn failed")
end

print("init: done")
exit(0)