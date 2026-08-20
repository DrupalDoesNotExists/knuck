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
    local term_drv = K.loader.load("/lib/knuck/kernel/drivers/term.lua", K)
    M.register_device("console", term_drv)
    -- virtual terminals /dev/tty1..ttyN
    if K.tty then
      for i = 1, K.tty.count() do
        M.register_device("tty" .. i, K.tty.make_driver(i))
      end
    end
    -- devctl: control device. write "tty_switch <id>" switches active tty.
    M.register_device("devctl", {
      mode = 0x1B6,
      write = function(data)
        local s = tostring(data or "")
        local id = s:match("tty_switch%s+(%d+)")
        if id and K.tty then
          return K.tty.switch(tonumber(id)) and #s or 0
        end
        return #s
      end,
      read = function(n)
        local proc = K.sched.current()
        K.sched.wait(proc, "devctl", "devctl")
        return proc.pending_result
      end,
    })
    -- /dev/null: read = EOF, write = discard
    M.register_device("null", {
      mode = 0x1B6,
      read = function() return nil end,
      write = function(data) return #data end,
    })
    -- /dev/zero: read = NUL bytes
    M.register_device("zero", {
      mode = 0x1B6,
      read = function(n) return string.rep("\0", n or 0) end,
      write = function(data) return #data end,
    })
    -- /dev/urandom: read = random bytes
    M.register_device("urandom", {
      mode = 0x1B6,
      read = function(n)
        local out = {}
        for i = 1, (n or 1) do out[i] = string.char(math.random(0, 255)) end
        return table.concat(out)
      end,
      write = function(data) return #data end,
    })
    -- /dev/input: raw input events (term/char/mouse), fed by the scheduler
    M.register_device("input", {
      mode = 0x1B6,
      read = function(n)
        local proc = K.sched.current()
        K.sched.wait(proc, "input", "input")
        return proc.pending_result
      end,
      write = function(data) return #data end,
    })
  end

  -- Thin wrapper over a CC peripheral at a side. write "method arg1 arg2"
  -- calls peripheral.call(side, method, ...). read returns nil (peripherals
  -- are method-based, not streams).
  local function make_periph_driver(side)
    return {
      mode = 0x1B6,
      read = function() return nil end,
      write = function(data)
        if not peripheral then return 0 end
        local method, rest = tostring(data):match("^(%S+)%s*(.*)$")
        if not method then return 0 end
        local args = {}
        for a in (rest or ""):gmatch("%S+") do args[#args + 1] = a end
        local ok = pcall(peripheral.call, side, method, table.unpack(args))
        return ok and #data or 0
      end,
    }
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
    -- tmpfs /tmp: wipe contents at boot (spec: "чистится при старте")
    local function wipe(dir)
      for _, name in ipairs(fs_mod.list(dir) or {}) do
        local p = dir .. "/" .. name
        if fs_mod.is_dir(p) then
          wipe(p)
          fs_mod.remove(p)
        else
          fs_mod.remove(p)
        end
      end
    end
    wipe("/tmp")
  end

  -- Mount all present disk drives at /mnt/disk0..N (fstype floppy/hdd).
  -- Returns the number of drives mounted.
  function M.mount_drives()
    local idx = 0
    local names = {}
    if peripheral and peripheral.getNames then
      names = peripheral.getNames()
    end
    for _, side in ipairs(names) do
      local ok, ptype = pcall(peripheral.getType, side)
      if ok and ptype == "drive" then
        M.drive_side(side)
        idx = idx + 1
      end
    end
    return idx
  end

  -- Mount/unmount a single drive by peripheral side (hotplug).
  -- detach=true unmounts; otherwise mounts the drive at the next /mnt/diskN.
  local drive_sides = {}   -- side -> mountpoint
  local drive_next = 0
  function M.drive_side(side, detach)
    if detach then
      local mp = drive_sides[side]
      if mp then
        M.unmount_drive(mp)
        drive_sides[side] = nil
      end
      return
    end
    local ok, ptype = pcall(peripheral.getType, side)
    if not ok or ptype ~= "drive" then return end
    local ok2, mpath = pcall(disk.getMountPath, side)
    if not ok2 or not mpath then return end
    local mp = "/mnt/disk" .. drive_next
    drive_next = drive_next + 1
    mounts[mp] = { fstype = "floppy", real_root = mpath }
    fs_mod.set_drive_mount(mp, mpath)
    drive_sides[side] = mp
  end

  -- Unmount a drive by its /mnt/diskN mountpoint (on detach).
  function M.unmount_drive(mp)
    if not mounts[mp] then return false end
    mounts[mp] = nil
    fs_mod.clear_drive_mount(mp)
    return true
  end

  -- Register a device node driver
  function M.register_device(name, driver)
    devices[name] = driver
  end

  -- Register a socket inode (AF_UNIX bind)
  function M.set_socket(path, sock)
    fs_mod.set_inode(path, { type = "socket", sock = sock, mode = 0x1B6, uid = 0, gid = 0, nlink = 1 })
  end

  -- Drop a socket inode (AF_UNIX close)
  function M.drop_socket(path)
    fs_mod.drop_inode(path)
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
    -- chroot jail: absolute paths resolve inside proc.root (if set)
    if proc and proc.root and proc.root ~= "/" then
      p = M.normalize(proc.root .. p)
    end
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
      local under
      if path == mp then
        under = true
      elseif mp == "/" then
        -- root mount: every absolute path is under it
        under = path:sub(1, 1) == "/"
      else
        under = path:sub(1, #mp + 1) == mp .. "/"
      end
      if under and #mp > best_len then
        best, best_len = m, #mp
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
    elseif rest == "kmsg" then
      -- dmesg ring, drain-on-read (single consumer: syslogd)
      local ring = K.log_ring or {}
      local pos = K.kmsg_pos or 0
      local lines = {}
      if pos < #ring then
        for i = pos + 1, #ring do lines[#lines + 1] = ring[i] end
      end
      K.kmsg_pos = #ring
      return table.concat(lines, "\n") .. (#lines > 0 and "\n" or "")
    elseif rest == "dmesg" then
      -- full dmesg ring (repeatable)
      return table.concat(K.log_ring or {}, "\n") .. "\n"
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
      local lines = {}
      for fd, f in pairs(snap.fds or {}) do
        local target = f.path or f.type or "?"
        lines[#lines + 1] = fd .. "\t" .. target
      end
      table.sort(lines, function(a, b)
        return tonumber(a:match("^(%d+)")) < tonumber(b:match("^(%d+)"))
      end)
      return table.concat(lines, "\n") .. "\n"
    elseif field == "mem" then
      -- rough resident estimate: fds + env + stack
      local n = 0
      for _ in pairs(snap.fds or {}) do n = n + 1 end
      return tostring(n * 4 + 16) .. "\n"
    end
    return nil
  end

  -- /sys: kernel info
  local function sys_list(path)
    if path == "/sys" then
      return { "kernel", "net", "modules" }
    elseif path == "/sys/kernel" then
      return { "version", "scheduler", "quantum", "priority" }
    elseif path == "/sys/net" then
      return { "ip", "gateway", "netmask", "arp", "routes", "channel" }
    end
    return {}
  end

  local function sys_read(path)
    local rest = path:match("^/sys/(.+)$")
    if not rest then return nil end
    if rest == "kernel/version" then
      return "KNUCK " .. (K.selfcheck.craftos or "?") .. "\n"
    elseif rest == "kernel/scheduler" then
      return K.selfcheck.preempt and "preemptive\n" or "cooperative\n"
    elseif rest == "kernel/quantum" then
      return tostring(K.sched.QUANTUM) .. "\n"
    elseif rest == "kernel/priority" then
      return tostring(K.sched.default_priority or 0) .. "\n"
    elseif rest == "modules" then
      local parts = {}
      for name in pairs(K.modules) do parts[#parts + 1] = name end
      table.sort(parts)
      return table.concat(parts, "\n") .. "\n"
    elseif rest == "net/ip" then
      return K.net.ip_to_str(K.net.ip) .. "\n"
    elseif rest == "net/gateway" then
      return K.net.ip_to_str(K.net.gateway) .. "\n"
    elseif rest == "net/netmask" then
      return K.net.ip_to_str(K.net.netmask) .. "\n"
    elseif rest == "net/channel" then
      return tostring(K.net.channel) .. "\n"
    elseif rest == "net/arp" then
      local parts = {}
      for ip, e in pairs(K.net.arp_cache) do
        parts[#parts + 1] = ip .. " = " .. K.net.mac_to_str(e.mac)
      end
      table.sort(parts)
      return table.concat(parts, "\n") .. "\n"
    elseif rest == "net/routes" then
      local parts = {}
      for _, route in ipairs(K.net.routes) do
        parts[#parts + 1] = K.net.ip_to_str(route.dest) .. "/" .. K.net.ip_to_str(route.mask)
          .. " gw " .. K.net.ip_to_str(route.gw) .. " metric " .. (route.metric or 0)
      end
      return table.concat(parts, "\n") .. "\n"
    end
    return nil
  end

  -- /sys writes: root-only (uid 0). Currently only /sys/net/* is writable.
  local function sys_write(path, data)
    local rest = path:match("^/sys/(.+)$")
    if not rest then return nil, "read-only" end
    local value = data:gsub("%s+$", "")
    if rest == "kernel/quantum" then
      local q = tonumber(value)
      if not q or q < 1 then return nil, "invalid quantum" end
      K.sched.QUANTUM = q
      return #data
    elseif rest == "kernel/priority" then
      local p = tonumber(value)
      if not p or p < -20 or p > 19 then return nil, "invalid priority" end
      K.sched.default_priority = p
      return #data
    elseif rest == "modules" then
      local cmd, arg = value:match("^(%S+)%s+(.+)$")
      if cmd == "load" and arg then
        local ok, mod = pcall(K.loader.load, arg, K)
        if not ok then return nil, tostring(mod) end
        local name = arg:match("([^/]+)%.lua$") or arg
        K.modules[name] = mod
        K.module_paths = K.module_paths or {}
        K.module_paths[name] = arg
        return #data
      elseif cmd == "unload" and arg then
        if not K.modules[arg] then return nil, "no such module" end
        K.modules[arg] = nil
        if K.module_paths and K.module_paths[arg] then
          K.loader.unload(K.module_paths[arg])
          K.module_paths[arg] = nil
        end
        return #data
      end
      return nil, "usage: load <path> | unload <name>"
    elseif rest == "net/ip" then
      local ip = K.net.str_to_ip(value)
      if not ip then return nil, "invalid ip" end
      K.net.ip = ip
      return #data
    elseif rest == "net/gateway" then
      local gw = K.net.str_to_ip(value)
      if not gw then return nil, "invalid gateway" end
      K.net.gateway = gw
      return #data
    elseif rest == "net/netmask" then
      local nm = K.net.str_to_ip(value)
      if not nm then return nil, "invalid netmask" end
      K.net.netmask = nm
      return #data
    elseif rest == "net/channel" then
      local ch = tonumber(value)
      if not ch then return nil, "invalid channel" end
      K.net.channel = ch
      if K.net.enabled then
        K.net.modem.closeAll()
        K.net.modem.open(ch)
      end
      return #data
    elseif rest == "net/arp" then
      -- static entry: "ip = mac"
      local ip, mac = value:match("^(%d+%.%d+%.%d+%.%d+)%s*=%s*(%x+:%x+:%x+:%x+:%x+:%x+)$")
      if not ip then return nil, "invalid arp entry" end
      local ip4 = K.net.str_to_ip(ip)
      local mac6 = K.net.str_to_mac(mac)
      if not ip4 or not mac6 then return nil, "invalid arp entry" end
      K.net.arp_cache[ip] = { mac = mac6, ttl = 0, static = true }
      return #data
    elseif rest == "net/routes" then
      -- delete: "del dest/mask gw"
      local del_dest, del_mask, del_gw = value:match(
        "^del%s+(%d+%.%d+%.%d+%.%d+)%s*/%s*(%d+%.%d+%.%d+%.%d+)%s+gw%s+(%d+%.%d+%.%d+%.%d+)$")
      if del_dest then
        local d, m, g = K.net.str_to_ip(del_dest), K.net.str_to_ip(del_mask), K.net.str_to_ip(del_gw)
        for i = #K.net.routes, 1, -1 do
          local r = K.net.routes[i]
          if r.dest == d and r.mask == m and r.gw == g then
            table.remove(K.net.routes, i)
            return #data
          end
        end
        return nil, "route not found"
      end
      -- add: "dest/mask gw metric"
      local dest_s, mask_s, gw_s, metric_s = value:match(
        "^(%d+%.%d+%.%d+%.%d+)%s*/%s*(%d+%.%d+%.%d+%.%d+)%s+gw%s+(%d+%.%d+%.%d+%.%d+)%s*(.*)")
      if not dest_s then return nil, "invalid route format" end
      local dest, mask, gw = K.net.str_to_ip(dest_s), K.net.str_to_ip(mask_s), K.net.str_to_ip(gw_s)
      if not dest or not mask or not gw then return nil, "invalid ip in route" end
      K.net.routes[#K.net.routes + 1] = {
        dest = dest, mask = mask, gw = gw, metric = tonumber(metric_s) or 0,
      }
      return #data
    end
    return nil, "read-only"
  end

  -- /dev: device nodes
  local function dev_list()
    local out = { "console", "null", "zero", "urandom", "input", "devctl", "periph" }
    for name in pairs(devices) do
      if name ~= "console" then out[#out + 1] = name end
    end
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
        local drv = devices[name]
        return { type = "device", mode = drv.mode or 0x1B6, uid = 0, gid = 0, nlink = 1, device = name }
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
      if path == "/sys/net" or path == "/sys/kernel" then
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

  -- readdir a path -> list of {name, is_dir, ...} entries or nil
  function M.readdir(proc, path)
    local p = M.resolve(proc, path)
    local m = M.find_mount(p)
    if not m then return nil, "no such file" end
    local ino = M.get_inode(p)
    if not ino or ino.type ~= "dir" then return nil, "not a directory" end
    if not fs_mod.check_access(proc, ino, "r") then return nil, "permission denied" end
    local names
    if m.fstype == "proc" then names = proc_list()
    elseif m.fstype == "sys" then names = sys_list(p)
    elseif m.fstype == "dev" then names = dev_list()
    else names = fs_mod.list(p) end
    -- structured entries: {name, is_dir, type, mode, size}
    local out = {}
    for _, name in ipairs(names or {}) do
      local child = M.normalize(p .. "/" .. name)
      local cino = M.get_inode(child)
      out[#out + 1] = {
        name = name,
        is_dir = (cino and cino.type == "dir") or false,
        type = cino and cino.type or "file",
        mode = cino and cino.mode or 0,
        size = cino and cino.size or 0,
      }
    end
    return out
  end

  -- open a path -> fd table or nil,err
  function M.open(proc, path, flags, mode, on_open)
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
      if ino.device:match("^periph/") then
        local side = ino.device:match("^periph/(.+)$")
        return { type = "device", device = ino.device, driver = make_periph_driver(side), mode = flags or "r" }
      end
      local drv = devices[ino.device]
      if not drv then return nil, "no such device" end
      return { type = "device", device = ino.device, driver = drv, mode = flags or "r" }
    end

    if ino.type == "fifo" then
      local creating = flags and flags:find("w") ~= nil
      if creating then
        return K.ipc.fifo_open_write(proc, ino, on_open)
      else
        return K.ipc.fifo_open_read(proc, ino, on_open)
      end
    end

    if m.fstype == "proc" or m.fstype == "sys" then
      local data = (m.fstype == "proc") and proc_read(p) or sys_read(p)
      return { type = "memfile", data = data or "", pos = 0, path = p }
    end

    -- real file
    local handle = fs_mod.open(p, flags or "r")
    if not handle then return nil, "cannot open" end
    return { type = "file", handle = handle, path = p, mode = flags or "r", pos = 0 }
  end

  -- read from an fd
  function M.read(proc, fd, n)
    if not fd then return nil, "bad fd" end
    if fd.type == "console" then
      local drv = devices["console"]
      if drv and drv.read then return drv.read(n) end
      return nil
    elseif fd.type == "pipe_r" then
      return K.ipc.pipe_read(proc, fd, n)
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
    elseif fd.type == "socket" then
      -- POSIX: read/write on connected STREAM sockets routes to recv/send
      local s = fd.sock
      if s.socktype == "stream" and (s.conn or s.tcp_conn) then
        return K.ipc.socket_recv(proc, fd, n)
      end
      return nil, "unsupported fd"
    end
    return nil, "unsupported fd"
  end

  -- write to an fd
  function M.write(proc, fd, data)
    if not fd then return nil, "bad fd" end
    if fd.type == "console" then
      local drv = devices["console"]
      if drv and drv.write then return drv.write(data) end
      return nil, "no console driver"
    elseif fd.type == "pipe_w" then
      return K.ipc.pipe_write(proc, fd, data)
    elseif fd.type == "file" then
      fd.handle.write(data)
      return #data
    elseif fd.type == "memfile" then
      if fd.path and fd.path:match("^/sys/") then
        if proc.uid ~= 0 then return nil, "permission denied" end
        return sys_write(fd.path, data)
      end
      return #data
    elseif fd.type == "device" then
      if fd.driver.write then return fd.driver.write(data) end
      return nil
    elseif fd.type == "socket" then
      -- POSIX: write on connected STREAM sockets routes to send
      local s = fd.sock
      if s.socktype == "stream" and (s.conn or s.tcp_conn) then
        return K.ipc.socket_send(proc, fd, data)
      end
      return nil, "unsupported fd"
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

  -- mkfifo
  function M.mkfifo(proc, path, mode)
    local p = M.resolve(proc, path)
    local parent = p:match("^(.*)/[^/]+$") or "/"
    local pino = M.get_inode(parent)
    if not pino or pino.type ~= "dir" then return nil, "no such directory" end
    if not fs_mod.check_access(proc, pino, "w") then return nil, "permission denied" end
    local ino = K.ipc.fifo_create()
    ino.mode = fs_mod.apply_umask(proc, mode or 0x1A4)
    ino.uid = proc.uid
    ino.gid = proc.gid
    fs_mod.set_inode(p, ino)
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
    ino.mode = K.bit.band(mode, 0xFFF)
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
    local ro = flags and flags:find("ro") ~= nil
    mounts[t] = { fstype = fst, real_root = real, ro = ro }
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
    if mask then proc.umask = K.bit.band(mask, 0x1FF) end
    return old
  end

  -- load a Lua file from VFS with an env (for process spawn)
  function M.loadfile(path, env)
    local f, err = loadfile(path, "t", env)
    return f, err
  end

  return M
end