--[[
  KNUCK init (pid 1)
  ==================
  Minimal Android-style userspace init. Reads /boot/init.rc and spawns
  each service line sequentially, reaping each child.

  init.rc format (one service per line):
    service <name> <path> <args...>
  Lines starting with '#' or blank lines are skipped.

  If /boot/init.rc is absent, falls back to a default demo service
  (/knuck/sbin/hello.lua world).

  NOTE: init is USERSPACE/distro code. Kernel self-diagnostics live in
  the kernel (kernel/diag.lua), not here.
]]

local pid = getpid()
print("init: pid " .. pid .. " running")
print("init: uid " .. getuid() .. " gid " .. getgid())
print("init: cwd " .. getcwd())

-- Parse /boot/init.rc into a list of { name, path, args }
local function read_services()
  local f = open("/boot/init.rc", "r")
  if not f then return nil end
  local data = read(f, 65536)
  close(f)
  if not data then return nil end

  local services = {}
  for line in data:gmatch("[^\r\n]+") do
    line = line:match("^%s*(.-)%s*$")  -- trim
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local name, path = line:match("^service%s+(%S+)%s+(%S+)")
      if name and path then
        local args = {}
        for a in line:gmatch("%S+") do
          if a ~= "service" and a ~= name and a ~= path then
            args[#args + 1] = a
          end
        end
        services[#services + 1] = { name = name, path = path, args = args }
      end
    end
  end
  return services
end

local services = read_services()
if not services or #services == 0 then
  print("init: no /boot/init.rc, using default service")
  services = { { name = "hello", path = "/knuck/sbin/hello.lua", args = { "world" } } }
end

for _, svc in ipairs(services) do
  print("init: starting service " .. svc.name .. " (" .. svc.path .. ")")
  local child = spawn(svc.path, table.unpack(svc.args))
  if child then
    print("init: spawned " .. svc.name .. " pid " .. child)
    local cpid, status, code = waitpid(child)
    print("init: " .. svc.name .. " " .. tostring(cpid) .. " " .. tostring(status) .. " " .. tostring(code))
  else
    print("init: spawn failed for " .. svc.name)
  end
end

print("init: done")
exit(0)