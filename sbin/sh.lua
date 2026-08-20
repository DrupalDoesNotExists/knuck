--[[
  KNUCK debug shell (busybox-like)
  ================================
  Minimal interactive shell for poking around a running KNUCK system.
  Shipped with the installer as a debug tool.

  Modes:
    lua /knuck/sbin/sh.lua <script>   - run script file, then exit
    lua /knuck/sbin/sh.lua            - interactive console loop

  Builtins: ls, cat, echo, cd, pwd, mkdir, rm, ps, stat, help, exit.
  Unknown commands are tried as /knuck/sbin/<cmd>.lua.
]]

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function tokenize(line)
  local t = {}
  for w in line:gmatch("%S+") do t[#t + 1] = w end
  return t
end

-- Read one line from an open fd (console or file)
-- Extract a character from a console read result.
-- Console reads return an EVENT TABLE (e.g. {"char","x"} or {"key",28});
-- file reads return a plain string. Handle both.
local ENTER_KEY_CC = 28        -- CC 1.9
local ENTER_KEY_TW = 257       -- CC:Tweaked
local BS_KEY_CC = 14           -- CC 1.9
local BS_KEY_TW = 259          -- CC:Tweaked

local function evchar(v)
  if type(v) == "string" then return v end
  if type(v) ~= "table" then return nil end
  if v[1] == "char" then
    return v[2]
  elseif v[1] == "key" then
    local code = v[2]
    if code == ENTER_KEY_CC or code == ENTER_KEY_TW then return "\n" end
    if code == BS_KEY_CC or code == BS_KEY_TW then return "\b" end
    return nil  -- ignore other keys
  end
  return nil
end

local function readline(fd)
  local buf = ""
  while true do
    local v = read(fd, 1)
    if v == nil then
      if buf == "" then return nil end
      return buf
    end
    local c = evchar(v)
    if c == nil then
      -- key event we ignore; keep reading
    elseif c == "" then
      -- EOF (file read returns empty string at end)
      if buf == "" then return nil end
      return buf
    elseif c == "\n" then
      return buf
    elseif c == "\b" then
      buf = buf:sub(1, -2)
    elseif c ~= "\r" then
      buf = buf .. c
    end
  end
end

local builtins = {}

function builtins.ls(args)
  local path = args[1] or getcwd()
  local entries = readdir(path)
  if not entries then
    print("ls: cannot open " .. path)
    return
  end
  table.sort(entries)
  print(table.concat(entries, "  "))
end

function builtins.cat(args)
  if not args[1] then print("usage: cat <path>") return end
  local f = open(args[1], "r")
  if not f then print("cat: cannot open " .. args[1]) return end
  local data = read(f, 65536)
  close(f)
  if data then print(data) end
end

function builtins.echo(args)
  print(table.concat(args, " "))
end

function builtins.cd(args)
  if not args[1] then print("usage: cd <path>") return end
  local ok = chdir(args[1])
  if not ok then print("cd: no such dir " .. args[1]) end
end

function builtins.pwd()
  print(getcwd())
end

function builtins.mkdir(args)
  if not args[1] then print("usage: mkdir <path>") return end
  local ok = mkdir(args[1], 0x1ED)
  if not ok then print("mkdir: failed " .. args[1]) end
end

function builtins.rm(args)
  if not args[1] then print("usage: rm <path>") return end
  local ok = unlink(args[1])
  if not ok then print("rm: failed " .. args[1]) end
end

function builtins.ps()
  local entries = readdir("/proc")
  if not entries then print("ps: cannot read /proc") return end
  table.sort(entries)
  print(table.concat(entries, " "))
end

function builtins.stat(args)
  if not args[1] then print("usage: stat <path>") return end
  local st = stat(args[1])
  if not st then print("stat: no such file " .. args[1]) return end
  print("type=" .. tostring(st.type) .. " mode=" .. tostring(st.mode))
end

function builtins.help()
  print("builtins: ls cat echo cd pwd mkdir rm ps stat help exit")
  print("unknown cmd -> /knuck/sbin/<cmd>.lua")
end

function builtins.exit()
  exit(0)
end

-- Execute one command line
local function run_line(line)
  line = trim(line)
  if line == "" or line:sub(1, 1) == "#" then return end
  local t = tokenize(line)
  local cmd = t[1]
  local args = {}
  for i = 2, #t do args[#args + 1] = t[i] end

  if builtins[cmd] then
    builtins[cmd](args)
    return
  end

  -- Try external program
  local child = spawn("/knuck/sbin/" .. cmd .. ".lua", table.unpack(args))
  if child then
    waitpid(child)
  else
    print("sh: command not found: " .. cmd)
  end
end

-- Script mode: read lines from a file
local script = ...
if script then
  local f = open(script, "r")
  if not f then
    print("sh: cannot open script " .. script)
    exit(1)
  end
  while true do
    local line = readline(f)
    if not line then break end
    local ok, err = pcall(run_line, line)
    if not ok then print("sh: " .. tostring(err)) end
  end
  close(f)
  exit(0)
end

-- Interactive mode: read from /dev/console
local console = open("/dev/console", "r")
if not console then
  print("sh: cannot open /dev/console")
  exit(1)
end

print("KNUCK sh - type 'help' for builtins, 'exit' to quit")
while true do
  print("sh# ")
  local line = readline(console)
  if not line then break end
  local ok, err = pcall(run_line, line)
  if not ok then print("sh: " .. tostring(err)) end
end
close(console)
exit(0)