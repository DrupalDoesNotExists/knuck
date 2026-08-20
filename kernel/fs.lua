--[[
  KNUCK inode layer + real-fs backend
  ===================================
  Represents filesystem objects (inodes) and enforces the permission model.

  CraftOS 1.9 stores no permissions/timestamps and has no fs.rename. So:
  - File CONTENT lives in the real CraftOS fs (path = VFS path).
  - METADATA (type, mode, uid, gid, nlink, symlink target) lives in an
    in-memory inode table keyed by canonical VFS path. In-memory only for
    now (permissions reset on reboot; persistence is a later concern).

  Permission model: rwxrwxrwx (octal 0777) + setuid(4000)/setgid(2000)/
  sticky(1000). Access: owner bits if uid matches, else group bits if gid
  matches, else other bits. Root (uid 0) bypasses r/w/x checks.
]]

return function(K)
  local M = {}

  local inodes = {}             -- canonical path -> inode table
  local real_root = "/"         -- CraftOS fs root that VFS maps onto

  -- Default modes
  local DMODE = 0x1ED           -- 0755 dir
  local FMODE = 0x1A4           -- 0644 file

  -- ---- inode helpers ----

  -- Get or create the inode for a path (real-fs backed)
  function M.inode(path)
    local ino = inodes[path]
    if ino then return ino end
    -- Create from real fs state
    local t
    if fs.isDir(path) then
      t = "dir"
    elseif fs.exists(path) then
      t = "file"
    else
      return nil
    end
    ino = {
      type = t,
      mode = (t == "dir") and DMODE or FMODE,
      uid = 0,
      gid = 0,
      nlink = 1,
      size = fs.exists(path) and (fs.getSize and fs.getSize(path) or 0) or 0,
    }
    inodes[path] = ino
    return ino
  end

  -- Register an explicit inode (for virtual fs, devices, symlinks)
  function M.set_inode(path, ino)
    inodes[path] = ino
  end

  -- Get an inode without creating (for virtual fs)
  function M.get_inode(path)
    return inodes[path]
  end

  -- Remove an inode (on unlink/rmdir)
  function M.drop_inode(path)
    inodes[path] = nil
  end

  -- ---- permission model ----

  -- Check access: want = "r" | "w" | "x". Returns true/false.
  function M.check_access(proc, ino, want)
    if not ino then return false end
    if proc.uid == 0 then
      -- root bypasses r/w; execute needs at least one x bit
      if want == "x" then
        return (ino.mode & 0x49) ~= 0  -- any execute bit (0111 octal)
      end
      return true
    end
    local shift
    if proc.uid == ino.uid then
      shift = 6
    elseif proc.gid == ino.gid then
      shift = 3
    else
      shift = 0
    end
    local bit = (want == "r") and 4 or (want == "w") and 2 or 1
    return (ino.mode & (bit << shift)) ~= 0
  end

  -- Apply umask to a requested mode
  function M.apply_umask(proc, mode)
    local um = proc.umask or 0x12  -- 0022 octal
    return K.bit.band(K.bit.band(mode, K.bit.bnot(um)), 0x1FF)
  end

  -- ---- real-fs operations ----

  function M.is_dir(path)
    return fs.isDir(path) == true
  end

  function M.exists(path)
    return fs.exists(path) == true
  end

  function M.list(path)
    local out = {}
    if fs.list then
      for _, name in ipairs(fs.list(path)) do
        out[#out + 1] = name
      end
    end
    return out
  end

  function M.make_dir(path)
    if fs.makeDir then fs.makeDir(path) end
  end

  function M.remove(path)
    if fs.delete then fs.delete(path) end
  end

  function M.open(path, mode)
    return fs.open(path, mode)
  end

  -- Read a whole file as string
  function M.read_all(path)
    local f = fs.open(path, "r")
    if not f then return nil end
    local data = f.readAll and f.readAll() or ""
    f.close()
    return data
  end

  -- Write a whole file
  function M.write_all(path, data)
    local f = fs.open(path, "w")
    if not f then return nil end
    f.write(data)
    f.close()
    return true
  end

  -- Rename: CraftOS 1.9 has no fs.rename -> copy + delete
  function M.rename(old, new)
    if fs.rename then
      fs.rename(old, new)
      return true
    end
    -- fallback: copy + delete
    local data = M.read_all(old)
    if data == nil then return nil end
    if not M.write_all(new, data) then return nil end
    M.remove(old)
    return true
  end

  -- Copy a file (for hardlink fallback)
  function M.copy(src, dst)
    local data = M.read_all(src)
    if data == nil then return nil end
    return M.write_all(dst, data)
  end

  return M
end