--[[
  KNUCK test child process
  ========================
  Spawned by init to exercise spawn/waitpid. Prints its args and exits.
]]

local who = ...
print("hello: pid " .. getpid() .. " ppid " .. getppid() .. " arg=" .. tostring(who))
exit(0)