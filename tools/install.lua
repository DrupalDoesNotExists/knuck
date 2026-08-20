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

-- Files to install: { repo_path, rootfs_path } (written under DEST).
-- Repo is source-organized; rootfs keeps kernel//sbin/ layout.
local FILES = {
  { "boot.lua", "knuck.lua" },
  { "src/kernel/loader.lua", "kernel/loader.lua" },
  { "src/kernel/diag.lua", "kernel/diag.lua" },
  { "src/kernel/sched.lua", "kernel/sched.lua" },
  { "src/kernel/syscall.lua", "kernel/syscall.lua" },
  { "src/kernel/proc.lua", "kernel/proc.lua" },
  { "src/kernel/fs.lua", "kernel/fs.lua" },
  { "src/kernel/vfs.lua", "kernel/vfs.lua" },
  { "src/kernel/ipc.lua", "kernel/ipc.lua" },
  { "src/kernel/net.lua", "kernel/net.lua" },
  { "src/kernel/net_transport.lua", "kernel/net_transport.lua" },
  { "src/kernel/auth.lua", "kernel/auth.lua" },
  { "src/kernel/tty.lua", "kernel/tty.lua" },
  { "src/kernel/drivers/term.lua", "kernel/drivers/term.lua" },
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
for _, pair in ipairs(FILES) do
  local src, dst = pair[1], pair[2]
  local url = BASE .. "/" .. src
  local dest = DEST .. "/" .. dst
  local n = download(url, dest)
  total = total + n
  print("  " .. dst .. " (" .. n .. " bytes)")
end

print("")
print("Installed " .. #FILES .. " files, " .. total .. " bytes.")

-- Install man pages (share/man/man2/*.2 -> usr/share/man/man2/*.2)
local MAN_SRC = "share/man/man2"
local MAN_DST = DEST .. "/usr/share/man/man2"
local MAN_NAMES = {
  "accept","alarm","bind","chdir","chgrp","chmod","chown","chroot","clear",
  "clock","clock_gettime","close","connect","diag","exec","exit","fstat",
  "getcwd","getegid","geteuid","getgid","getgrgid","getgrnam","getpeername",
  "getpgrp","getpid","getppid","getpriority","getpwnam","getpwuid",
  "getsockname","getsockopt","getuid","halt","insmod","ioctl","kill","link",
  "listen","login","lseek","mkdir","mkfifo","mount","open","pipe","poll",
  "print","read","readdir","readlink","reboot","recv","recvfrom","rename",
  "rmdir","rmmod","sched_setscheduler","sched_yield","select","send","sendto",
  "setgid","setpgid","setpriority","setsockopt","setuid","shutdown","signal",
  "sigprocmask","sleep","socket","spawn","stat","symlink","time","umask",
  "umount","unlink","waitpid","write",
}
local man_total = 0
for _, name in ipairs(MAN_NAMES) do
  local url = BASE .. "/" .. MAN_SRC .. "/" .. name .. ".2"
  local dest = MAN_DST .. "/" .. name .. ".2"
  local n = download(url, dest)
  man_total = man_total + n
end
print("Installed " .. #MAN_NAMES .. " man pages, " .. man_total .. " bytes.")
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