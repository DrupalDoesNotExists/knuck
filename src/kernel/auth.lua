--[[
  KNUCK account database
  ======================
  Reads /etc/passwd and /etc/group. Passwords are hashed with FNV-1a 32-bit
  (8 hex chars). A password field of "x" means "no password / locked".

  /etc/passwd line:  name:password:uid:gid:gecos:home:shell
  /etc/group  line:  name:password:gid:member1,member2,...
]]

return function(K)
  local M = {}

  -- FNV-1a 32-bit hash (consistent with pine/package checksums)
  -- Try libcrypto first, then libbase; fall back to inline implementation.
  local fnv1a = nil
  do
    local ok, crypto = pcall(require, "libcrypto")
    if ok and crypto and crypto.fnv1a then
      fnv1a = crypto.fnv1a
    else
      local ok2, libbase = pcall(require, "libbase")
      if ok2 and libbase and libbase.fnv1a then
        fnv1a = libbase.fnv1a
      else
      -- Inline fallback (arithmetic bxor, no bit32 in Lua 5.2/Cobalt)
      -- Uses 16-bit-split multiply to avoid float precision loss.
      local function bxor(a, b)
        local r, bit = 0, 1
        a = a % 0x100000000; b = b % 0x100000000
        while a > 0 or b > 0 do
          if (a % 2) ~= (b % 2) then r = r + bit end
          a = math.floor(a / 2); b = math.floor(b / 2); bit = bit * 2
        end
        return r
      end
      fnv1a = function(data)
        local h = 0x811c9dc5
        for i = 1, #data do
          h = bxor(h, string.byte(data, i))
          local lo = h % 0x10000
          local hi = (h - lo) / 0x10000
          local plo = 0x01000193 % 0x10000
          local phi = (0x01000193 - plo) / 0x10000
          local r = lo * plo + ((lo * phi + hi * plo) % 0x10000) * 0x10000
          h = r % 0x100000000
        end
        return string.format("%08x", h)
        end
      end
    end
  end

  function M.hash_password(pass)
    return fnv1a(tostring(pass or ""))
  end

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
  -- Compares FNV-1a hash; falls back to plaintext for legacy entries.
  function M.check_password(entry, pass)
    if not entry then return false end
    if entry.pass == "" or entry.pass == "x" then return false end
    local stored = entry.pass
    local hashed = M.hash_password(pass)
    -- Match against hash (8 hex chars) or legacy plaintext
    return stored == hashed or stored == tostring(pass or "")
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