--[[
  KNUCK VFS
  =========
  Mount table + path resolution + virtual filesystems (/proc, /sys, /dev)
  + device nodes + top-level file operations used by syscalls.

  Mounts:
    /        disk   (real CraftOS storage)
    /boot    disk
    /tmp     tmp    (real CraftOS storage)
    /rom     rom    (real CraftOS storage)
    /dev     dev    (virtual device nodes)
    /sys     sys    (virtual kernel info)
    /proc    proc   (virtual process info)

  Real-fs mounts map VFS path directly onto the CraftOS fs (real_root="/").
  Virtual mounts generate content on demand from kernel state.
]]

return function(K)
  local M = {}
  local fs_mod = nil

  local mounts = {}             -- mountpoint -> { fstype, real_root }
  local devices = {}            -- /dev/name -> device driver table

  function M.init(K)
    fs_mod = K.fs
    -- register device drivers
    local term_drv = K.loader.load("/knuck/kernel/drivers/term.lua", K)
    M.register_device("console", term_drv)
  end

  function M.mount_root()
    mounts["/"] = { fstype = "disk", real_root = "/" }
    mounts["/boot"] = { fstype = "disk", real_root = "/boot" }
    mounts["/tmp"] = { fstype = "tmp", real_root = "/tmp" }
    mounts["/rom"] = { fstype = "rom", real_root = "/rom" }
    mounts["/dev"] = { fstype = "dev" }
    mounts["/sys"] = { fstype = "sys" }
    mounts["/proc"] = { fstype = "proc" }
    -- ensure real-fs base dirs exist
    for _, d in ipairs({ "/tmp", "/boot", "/rom" }) do
      if not fs_mod.exists(d) then fs_mod.make_dir(d) end
    end
  end

  -- Register a device node driver
  function M.register_device(name, driver)
    devices[name] = driver
  end

  -- ---- path resolution ----

  -- Normalize a path to canonical absolute form
  function M.normalize(path)
    local p = path or "/"
    if p:sub(1, 1) ~= "/" then p = "/" .. p end
    local parts = {}
    for part in p:gmatch("[^/]+") do
      if part == "." then
        -- skip
      elseif part == ".." then
        if #parts > 0 then table.remove(parts) end
      else
        parts[#parts + 1] = part
      end
    end
    return "/" .. table.concat(parts, "/")
  end

  -- Resolve a path relative to a process cwd, following symlinks.
  -- Returns canonical path (symlinks resolved) or nil.
  function M.resolve(proc, path)
    local p = path or "/"
    if p:sub(1, 1) ~= "/" then
      p = (proc and proc.cwd or "/") .. "/" .. p
    end
    p = M.normalize(p)
    -- follow symlinks (limit 40)
    for _ = 1, 40 do
      local ino = fs_mod.get_inode(p)
      if ino and ino.type == "symlink" then
        local tgt = ino.target
        if tgt:sub(1, 1) ~= "/" then
          -- relative target: resolve against parent dir
          local parent = p:match("^(.*)/[^/]+$") or "/"
          tgt = parent .. "/" .. tgt
        end
        p = M.normalize(tgt)
      else
        break
      end
    end
    return p
  end

  -- Find the mount for a canonical path
  function M.find_mount(path)
    local best, best_len = nil, -1
    for mp, m in pairs(mounts) do
      if path == mp or path:sub(1, #mp + 1) == mp .. "/" then
        if #mp > best_len then
          best, best_len = m, #mp
        end
      end
    end
    return best
  end

  -- ---- virtual filesystem generators ----

  -- /proc: process info
  local function proc_list()
    local out = { "uptime", "version", "selfcheck" }
    for pid in pairs(K.proc.snapshot()) do
      out[#out + 1] = tostring(pid)
    end
    return out
  end

  local function proc_read(path)
    local rest = path:match("^/proc/(.+)$")
    if not rest then return nil end
    if rest == "uptime" then
      return tostring(K.env.os.clock()) .. "\n"
    elseif rest == "version" then
      return "KNUCK " .. (K.selfcheck.craftos or "?") .. "\n"
    elseif rest == "selfcheck" then
      local parts = {}
      for k, v in pairs(K.selfcheck) do
        parts[#parts + 1] = k .. "=" .. tostring(v)
      end
      table.sort(parts)
      return table.concat(parts, "\n") .. "\n"
    end
    local pid = tonumber(rest:match("^(%d+)"))
    if not pid then return nil end
    local snap = K.proc.snapshot()[pid]
    if not snap then return nil end
    local field = rest:match("^%d+/(.+)$")
    if field == "status" then
      return "Name:\t" .. snap.name .. "\nState:\t" .. snap.state ..
        "\nPid:\t" .. pid .. "\nPPid:\t" .. snap.ppid ..
        "\nUid:\t" .. snap.uid .. "\nPriority:\t" .. snap.priority .. "\n"
    elseif field == "cmdline" then
      return snap.name .. "\n"
    elseif field == "fd" then
      return "0\tconsole\n1\tconsole\n2\tconsole\n"
    elseif field == "mem" then
      return "0\n"
    end
    return nil
  end

  -- /sys: kernel info
  local function sys_list()
    return { "kernel", "net", "modules" }
  end

  local function sys_read(path)
    local rest = path:match("^/sys/(.+)$")
    if not rest then return nil end
    if rest == "kernel/version" then
      return "KNUCK " .. (K.selfcheck.craftos or "?") .. "\n"
    elseif rest == "kernel/scheduler" then
      return K.selfcheck.preempt and "preemptive\n" or "cooperative\n"
    elseif rest == "modules" then
      local parts = {}
      for name in pairs(K.modules) do parts[#parts + 1] = name end
      table.sort(parts)
      return table.concat(parts, "\n") .. "\n"
    end
    return nil
  end

  -- /dev: device nodes
  local function dev_list()
    local out = { "console", "null", "zero", "urandom", "input", "devctl", "periph" }
    return out
  end

  -- ---- inode lookup for a canonical path ----

  -- Get the inode for a canonical path (real or virtual)
  function M.get_inode(path)
    local m = M.find_mount(path)
    if not m then return nil end
    if m.fstype == "dev" then
      if path == "/dev" then
        return { type = "dir", mode = 0x1ED, uid = 0, gid = 0, nlink = 1 }
      end
      local name = path:match("^/dev/(.+)$")
      if not name then return nil end
      if name == "periph" then
        return { type = "dir", mode = 0x1ED, uid = 0, gid = 0, nlink = 1 }
      end
      if name:match("^periph/") then
        return { type = "device", mode = 0x1B6, uid = 0, gid = 0, nlink = 1, device = name }
      end
      if devices[name] then
        return { type = "device", mode = 0x1B6, uid = 0, gid = 0, nlink = 1, device = name }
      end
      return nil
    elseif m.fstype == "proc" then
      if path == "/proc" then
        return { type = "dir", mode = 0x1ED, uid = 0, gid = 0, nlink = 1 }
      end
      local rest = path:match("^/proc/(.+)$")
      if not rest then return nil end
      if rest:match("^%d+$") then
        return { type = "dir", mode = 0x1ED, uid = 0, gid = 0, nlink = 1 }
      end
      if proc_read(path) then
        return { type = "file", mode = 0x1A4, uid = 0, gid = 0, nlink = 1 }
      end
      return nil
    elseif m.fstype == "sys" then
      if path == "/sys" then
        return { type = "dir", mode = 0x1ED, uid = 0, gid = 0, nlink = 1 }
      end
      if sys_read(path) then
        return { type = "file", mode = 0x1A4, uid = 0, gid = 0, nlink = 1 }
      end
      return nil
    else
      -- real-fs backed
      return fs_mod.inode(path)
    end
  end

  -- ---- top-level operations (called by syscalls) ----

  -- stat a path -> table or nil
  function M.stat(proc, path)
    local p = M.resolve(proc, path)
    local ino = M.get_inode(p)
    if not ino then return nil, "no such file" end
    return {
      type = ino.type,
      mode = ino.mode,
      uid = ino.uid,
      gid = ino.gid,
      nlink = ino.nlink,
      size = ino.size or 0,
      path = p,
    }
  end

  -- readdir a path -> list of names or nil
  function M.readdir(proc, path)
    local p = M.resolve(proc, path)
    local m = M.find_mount(p)
    if not m then return nil, "no such file" end
    local ino = M.get_inode(p)
    if not ino or ino.type ~= "dir" then return nil, "not a directory" end
    if not fs_mod.check_access(proc, ino, "r") then return nil, "permission denied" end
    if m.fstype == "proc" then return proc_list() end
    if m.fstype == "sys" then return sys_list() end
    if m.fstype == "dev" then return dev_list() end
    return fs_mod.list(p)
  end

  -- open a path -> fd table or nil,err
  function M.open(proc, path, flags, mode)
    local p = M.resolve(proc, path)
    local m = M.find_mount(p)
    if not m then return nil, "no such file" end
    local ino = M.get_inode(p)
    local creating = flags and flags:find("w") ~= nil

    if not ino then
      if not creating then return nil, "no such file" end
      -- create: check parent dir + permission
      local parent = p:match("^(.*)/[^/]+$") or "/"
      local pino = M.get_inode(parent)
      if not pino or pino.type ~= "dir" then return nil, "no such directory" end
      if not fs_mod.check_access(proc, pino, "w") then return nil, "permission denied" end
      local h = fs_mod.open(p, "w")
      if not h then return nil, "cannot create" end
      h.close()
      fs_mod.set_inode(p, { type = "file", mode = fs_mod.apply_umask(proc, mode or 0x1A4), uid = proc.uid, gid = proc.gid, nlink = 1, size = 0 })
      ino = M.get_inode(p)
    end

    -- permission: read/write based on flags
    local want = creating and "w" or "r"
    if not fs_mod.check_access(proc, ino, want) then
      return nil, "permission denied"
    end

    if ino.type == "device" then
      local drv = devices[ino.device]
      if not drv then return nil, "no such device" end
      return { type = "device", device = ino.device, driver = drv, mode = flags or "r" }
    end

    if m.fstype == "proc" or m.fstype == "sys" then
      local data = (m.fstype == "proc") and proc_read(p) or sys_read(p)
      return { type = "memfile", data = data or "", pos = 0 }
    end

    -- real file
    local handle = fs_mod.open(p, flags or "r")
    if not handle then return nil, "cannot open" end
    return { type = "file", handle = handle, path = p, mode = flags or "r", pos = 0 }
  end

  -- read from an fd
  function M.read(fd, n)
    if not fd then return nil, "bad fd" end
    if fd.type == "console" then
      local drv = devices["console"]
      if drv and drv.read then return drv.read(n) end
      return nil
    elseif fd.type == "file" then
      local data = fd.handle.read(n or 0)
      return data
    elseif fd.type == "memfile" then
      local data = fd.data:sub(fd.pos + 1, fd.pos + (n or #fd.data))
      fd.pos = fd.pos + #data
      return data
    elseif fd.type == "device" then
      if fd.driver.read then return fd.driver.read(n) end
      return nil
    end
    return nil, "unsupported fd"
  end

  -- write to an fd
  function M.write(fd, data)
    if not fd then return nil, "bad fd" end
    if fd.type == "console" then
      local drv = devices["console"]
      if drv and drv.write then return drv.write(data) end
      return nil, "no console driver"
    elseif fd.type == "file" then
      fd.handle.write(data)
      return #data
    elseif fd.type == "memfile" then
      return #data
    elseif fd.type == "device" then
      if fd.driver.write then return fd.driver.write(data) end
      return nil
    end
    return nil, "unsupported fd"
  end

  -- close an fd
  function M.close(fd)
    if not fd then return nil, "bad fd" end
    if fd.type == "file" and fd.handle then
      fd.handle.close()
    end
    return true
  end

  -- lseek
  function M.lseek(fd, offset, whence)
    if fd.type ~= "file" and fd.type ~= "memfile" then return nil, "not seekable" end
    local base = 0
    if whence == "cur" then base = fd.pos
    elseif whence == "end" then base = #(fd.data or "") end
    fd.pos = base + offset
    return fd.pos
  end

  -- mkdir
  function M.mkdir(proc, path, mode)
    local p = M.resolve(proc, path)
    local m = M.find_mount(p)
    if not m or m.fstype ~= "disk" and m.fstype ~= "tmp" and m.fstype ~= "rom" then
      return nil, "read-only or virtual"
    end
    if fs_mod.exists(p) then return nil, "exists" end
    local parent = p:match("^(.*)/[^/]+$") or "/"
    local pino = M.get_inode(parent)
    if not pino or pino.type ~= "dir" then return nil, "no such directory" end
    if not fs_mod.check_access(proc, pino, "w") then return nil, "permission denied" end
    fs_mod.make_dir(p)
    fs_mod.set_inode(p, { type = "dir", mode = fs_mod.apply_umask(proc, mode or 0x1ED), uid = proc.uid, gid = proc.gid, nlink = 1 })
    return true
  end

  -- rmdir
  function M.rmdir(proc, path)
    local p = M.resolve(proc, path)
    local ino = M.get_inode(p)
    if not ino then return nil, "no such file" end
    if ino.type ~= "dir" then return nil, "not a directory" end
    if not fs_mod.check_access(proc, ino, "w") then return nil, "permission denied" end
    local entries = M.readdir(proc, p)
    if entries and #entries > 0 then return nil, "directory not empty" end
    fs_mod.remove(p)
    fs_mod.drop_inode(p)
    return true
  end

  -- unlink
  function M.unlink(proc, path)
    local p = M.resolve(proc, path)
    local ino = M.get_inode(p)
    if not ino then return nil, "no such file" end
    if ino.type == "dir" then return nil, "is a directory" end
    if not fs_mod.check_access(proc, ino, "w") then return nil, "permission denied" end
    fs_mod.remove(p)
    fs_mod.drop_inode(p)
    return true
  end

  -- rename
  function M.rename(proc, old, new)
    local o = M.resolve(proc, old)
    local n = M.resolve(proc, new)
    local ino = M.get_inode(o)
    if not ino then return nil, "no such file" end
    if not fs_mod.check_access(proc, ino, "w") then return nil, "permission denied" end
    if not fs_mod.rename(o, n) then return nil, "rename failed" end
    fs_mod.drop_inode(o)
    fs_mod.set_inode(n, ino)
    return true
  end

  -- chmod
  function M.chmod(proc, path, mode)
    local p = M.resolve(proc, path)
    local ino = M.get_inode(p)
    if not ino then return nil, "no such file" end
    if proc.uid ~= 0 and proc.uid ~= ino.uid then return nil, "permission denied" end
    ino.mode = mode & 0xFFF
    return true
  end

  -- chown
  function M.chown(proc, path, uid, gid)
    local p = M.resolve(proc, path)
    local ino = M.get_inode(p)
    if not ino then return nil, "no such file" end
    if proc.uid ~= 0 then return nil, "permission denied" end
    if uid then ino.uid = uid end
    if gid then ino.gid = gid end
    return true
  end

  -- symlink
  function M.symlink(proc, target, path)
    local p = M.resolve(proc, path)
    local parent = p:match("^(.*)/[^/]+$") or "/"
    local pino = M.get_inode(parent)
    if not pino or pino.type ~= "dir" then return nil, "no such directory" end
    if not fs_mod.check_access(proc, pino, "w") then return nil, "permission denied" end
    fs_mod.set_inode(p, { type = "symlink", target = target, mode = 0x1FF, uid = proc.uid, gid = proc.gid, nlink = 1 })
    return true
  end

  -- readlink (must NOT follow the symlink itself)
  function M.readlink(proc, path)
    local p = path or ""
    if p:sub(1, 1) ~= "/" then
      p = (proc and proc.cwd or "/") .. "/" .. p
    end
    p = M.normalize(p)
    local ino = fs_mod.get_inode(p)
    if not ino or ino.type ~= "symlink" then return nil, "not a symlink" end
    return ino.target
  end

  -- hardlink (fallback: copy content, share inode metadata)
  function M.link(proc, old, new)
    local o = M.resolve(proc, old)
    local n = M.resolve(proc, new)
    local ino = M.get_inode(o)
    if not ino then return nil, "no such file" end
    if ino.type == "dir" then return nil, "cannot hardlink directory" end
    if not fs_mod.check_access(proc, ino, "r") then return nil, "permission denied" end
    if not fs_mod.copy(o, n) then return nil, "link failed" end
    fs_mod.set_inode(n, ino)
    ino.nlink = (ino.nlink or 1) + 1
    return true
  end

  -- chroot
  function M.chroot(proc, path)
    local p = M.resolve(proc, path)
    local ino = M.get_inode(p)
    if not ino or ino.type ~= "dir" then return nil, "not a directory" end
    if proc.uid ~= 0 then return nil, "permission denied" end
    proc.root = p
    proc.cwd = p
    return true
  end

  -- mount
  function M.mount(proc, source, target, fstype, flags)
    if proc.uid ~= 0 then return nil, "permission denied" end
    local t = M.normalize(target)
    local fst = fstype or "disk"
    local real = source or t
    mounts[t] = { fstype = fst, real_root = real }
    return true
  end

  -- umount
  function M.umount(proc, target)
    if proc.uid ~= 0 then return nil, "permission denied" end
    local t = M.normalize(target)
    if t == "/" then return nil, "cannot unmount root" end
    if not mounts[t] then return nil, "not mounted" end
    mounts[t] = nil
    return true
  end

  -- umask
  function M.umask(proc, mask)
    local old = proc.umask or 0x1B2
    if mask then proc.umask = mask & 0x1FF end
    return old
  end

  -- load a Lua file from VFS with an env (for process spawn)
  function M.loadfile(path, env)
    local f, err = loadfile(path, "t", env)
    return f, err
  end

  return M
end