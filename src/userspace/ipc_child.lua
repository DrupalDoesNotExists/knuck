--[[
  KNUCK IPC test child
  ====================
  Role from arg:
    "sock"  - connect to /tmp/sock, send "ping", recv "pong"
    "fifo"  - open /tmp/fifo for write, write "fifo-data"
]]

local role = ...
if role == "sock" then
  local s = socket("unix", "stream", 0)
  print("child: socket fd " .. tostring(s))
  local ok = connect(s, "/tmp/sock")
  print("child: connect " .. tostring(ok))
  send(s, "ping")
  print("child: sent ping")
  local data = recv(s, 100)
  print("child: recv " .. tostring(data))
  close(s)
elseif role == "fifo" then
  local f = open("/tmp/fifo", "w")
  print("child: fifo open " .. tostring(f))
  if f then
    write(f, "fifo-data")
    close(f)
  end
end
exit(0)