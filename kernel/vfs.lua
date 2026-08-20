--[[
  KNUCK VFS (minimal)
  ===================
  First milestone: thin VFS over the real CraftOS fs.
  - /knuck, /tmp, /boot -> real CraftOS storage
  - /dev/console -> virtual device (term driver)
  Path resolution: absolute + cwd-relative. No permissions yet.

  Full VFS (mounts, device nodes, /sys, /proc, permissions) comes later.
]]

return function(K)
  local M = {}

  local mounts = {}             -- mountpoint -> { fstype, driver }
  local devices = {}            -- /dev/name -> device driver table

  function M.init(K)
    -- register device drivers
    local term_drv = K.loader.load("/knuck/kernel/drivers/term.lua", K)
    M.register_device("console", term_drv)
  end

  function M.mount_root()
    -- real-fs mounts
    mounts["/knuck"] = { fstype = "disk" }
    mounts["/tmp"] = { fstype = "tmp" }
    mounts["/boot"] = { fstype = "disk" }
    mounts["/dev"] = { fstype = "dev" }
  end

  -- Register a device node driver
  function M.register_device(name, driver)
    devices[name] = driver
  end

  -- Resolve a path (absolute or cwd-relative) to a canonical absolute path
  function M.resolve(proc, path)
    local p = path or "/"
    if p:sub(1, 1) ~= "/" then
      p = (proc and proc.cwd or "/") .. "/" .. p
    end
    -- normalize: collapse // and /./, resolve /../
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

  -- Is this a device node?
  function M.is_device(path)
    return path:match("^/dev/(.+)$") ~= nil
  end

  -- Get the device driver for a /dev path
  function M.get_device(path)
    local name = path:match("^/dev/(.+)$")
    return name and devices[name] or nil
  end

  -- Is a path a directory?
  function M.is_dir(path)
    if path == "/" then return true end
    if M.is_device(path) then return false end
    return fs.isDir(path) == true
  end

  -- Load a Lua file from VFS with an env (for process spawn)
  function M.loadfile(path, env)
    local f, err = loadfile(path, "t", env)
    return f, err
  end

  -- Write to an fd
  function M.write(fd, data)
    if not fd then return nil, "bad fd" end
    if fd.type == "console" then
      local drv = devices["console"]
      if drv then return drv.write(data) end
      return nil, "no console driver"
    elseif fd.type == "file" then
      if not fd.handle then return nil, "closed" end
      fd.handle.write(data)
      return #data
    end
    return nil, "unsupported fd type"
  end

  -- Read from an fd (blocking for console)
  function M.read(fd, n)
    if not fd then return nil, "bad fd" end
    if fd.type == "console" then
      local drv = devices["console"]
      if drv then return drv.read(n) end
      return nil, "no console driver"
    elseif fd.type == "file" then
      if not fd.handle then return nil, "closed" end
      return fd.handle.read(n or 0)
    end
    return nil, "unsupported fd type"
  end

  return M
end