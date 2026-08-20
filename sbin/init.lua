--[[
  KNUCK init (pid 1)
  ==================
  Boots, spawns a child, then exercises the VFS (files, dirs, symlinks,
  /proc, /sys, /dev). Later: reads /boot/init.rc (Android-style).
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

-- ---- VFS tests ----
print("-- VFS tests --")

-- mkdir + write + read
local ok = mkdir("/tmp/test", 0x1ED)
print("mkdir /tmp/test: " .. tostring(ok))

local fd = open("/tmp/test/file.txt", "w", 0x1A4)
print("open w: " .. tostring(fd))
if fd then
  write(fd, "hello knuck")
  close(fd)
end

fd = open("/tmp/test/file.txt", "r")
print("open r: " .. tostring(fd))
if fd then
  local data = read(fd, 100)
  print("read: " .. tostring(data))
  close(fd)
end

-- stat
local st = stat("/tmp/test/file.txt")
print("stat: " .. tostring(st and st.type) .. " mode=" .. tostring(st and st.mode))

-- readdir
local entries = readdir("/tmp")
print("readdir /tmp: " .. table.concat(entries or {}, ","))

-- /proc
local p = readdir("/proc")
print("readdir /proc: " .. table.concat(p or {}, ","))
local up = open("/proc/uptime", "r")
if up then
  print("uptime: " .. tostring(read(up, 50)))
  close(up)
end
local sc = open("/proc/selfcheck", "r")
if sc then
  print("selfcheck: " .. tostring(read(sc, 200)))
  close(sc)
end

-- /sys
local sv = open("/sys/kernel/version", "r")
if sv then
  print("sys version: " .. tostring(read(sv, 50)))
  close(sv)
end

-- /dev
local d = readdir("/dev")
print("readdir /dev: " .. table.concat(d or {}, ","))

-- symlink + readlink
symlink("/tmp/test/file.txt", "/tmp/link")
print("readlink: " .. tostring(readlink("/tmp/link")))

-- rename
rename("/tmp/test/file.txt", "/tmp/test/renamed.txt")
local st2 = stat("/tmp/test/renamed.txt")
print("renamed exists: " .. tostring(st2 ~= nil))

-- chmod + chown
chmod("/tmp/test/renamed.txt", 0x180)  -- 0600
local st3 = stat("/tmp/test/renamed.txt")
print("chmod mode: " .. tostring(st3 and st3.mode))
chown("/tmp/test/renamed.txt", 0, 0)

-- unlink + rmdir
unlink("/tmp/test/renamed.txt")
unlink("/tmp/link")
rmdir("/tmp/test")
local st4 = stat("/tmp/test")
print("rmdir gone: " .. tostring(st4 == nil))

print("init: done")
exit(0)