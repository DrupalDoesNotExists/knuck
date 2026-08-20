--[[
  KNUCK account database
  ======================
  Reads /etc/passwd and /etc/group (plain-text, CraftOS 1.9 has no
  crypt). Provides name<->uid/gid resolution and password checks.

  /etc/passwd line:  name:password:uid:gid:gecos:home:shell
  /etc/group  line:  name:password:gid:member1,member2,...

  Passwords are stored in plaintext (debug kernel; no crypt available).
  A password field of "x" means "no password / locked".
]]

return function(K)
  local M = {}

  local passwd = {}   -- name -> { name, pass, uid, gid, gecos, home, shell }
  local by_uid = {}   -- uid  -> passwd entry
  local groups = {}   -- name -> { name, pass, gid, members }
  local by_gid = {}   -- gid  -> group entry

  -- Parse /etc/passwd
  local function load_passwd()
    passwd, by_uid = {}, {}
    local data = K.fs.read_all("/etc/passwd")
    if not data then return end
    for line in data:gmatch("[^\r\n]+") do
      local name, pass, uid, gid, gecos, home, shell = line:match(
        "([^:]*):([^:]*):([^:]*):([^:]*):([^:]*):([^:]*):([^:]*)")
      if name and name ~= "" then
        local e = {
          name = name, pass = pass or "", uid = tonumber(uid) or 0,
          gid = tonumber(gid) or 0, gecos = gecos or "", home = home or "/",
          shell = shell or "/bin/sh.lua",
        }
        passwd[name] = e
        by_uid[e.uid] = e
      end
    end
  end

  -- Parse /etc/group
  local function load_groups()
    groups, by_gid = {}, {}
    local data = K.fs.read_all("/etc/group")
    if not data then return end
    for line in data:gmatch("[^\r\n]+") do
      local name, pass, gid, members = line:match(
        "([^:]*):([^:]*):([^:]*):([^:]*)")
      if name and name ~= "" then
        local mem = {}
        if members and members ~= "" then
          for m in members:gmatch("[^,]+") do mem[#mem + 1] = m end
        end
        local e = { name = name, pass = pass or "", gid = tonumber(gid) or 0, members = mem }
        groups[name] = e
        by_gid[e.gid] = e
      end
    end
  end

  function M.init(K)
    load_passwd()
    load_groups()
  end

  -- Reload from disk (after useradd/groupadd)
  function M.reload()
    load_passwd()
    load_groups()
  end

  -- Lookup by name or uid
  function M.getpwnam(name) return passwd[name] end
  function M.getpwuid(uid) return by_uid[uid] end
  function M.getgrnam(name) return groups[name] end
  function M.getgrgid(gid) return by_gid[gid] end

  -- Check a password against an entry. "x" or empty = locked (no login).
  function M.check_password(entry, pass)
    if not entry then return false end
    if entry.pass == "" or entry.pass == "x" then return false end
    return entry.pass == tostring(pass or "")
  end

  -- Login: returns uid, gid on success, or nil.
  function M.login(name, pass)
    local e = passwd[name]
    if not e then return nil end
    if not M.check_password(e, pass) then return nil end
    return e.uid, e.gid
  end

  return M
end