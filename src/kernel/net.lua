--[[
  KNUCK network core
  ==================
  Link + IP + ARP layer over a CC modem (shared broadcast medium).

  All nodes open a common channel (default 0) and transmit Ethernet frames
  on it. Every node receives every frame and filters by destination MAC
  (own or broadcast FF:FF:FF:FF:FF:FF).

  MAC derivation: locally-administered 02:00:00:00:xx:xx where xx:xx is the
  computer ID as 16-bit big-endian (byte5 = hi, byte6 = lo). No numeric
  modem id exists in the CC modem API, so the computer ID is the node id.

  Frame format: dest(6) + src(6) + ethertype(2, BE) + payload + FCS(4).
  FCS is CRC32 (poly 0xEDB88320, reflected), appended little-endian.
  Min frame 64 bytes (payload padded), max 1518 bytes.

  Ethertypes: 0x0800 = IPv4, 0x0806 = ARP.
  IP protocols: 1 = ICMP, 6 = TCP, 17 = UDP (TCP/UDP live in net_transport).

  Lua 5.2/Cobalt has no bit32 library: bit ops are done with arithmetic.
]]

return function(K)
  local M = {}

  local BROADCAST_MAC = string.char(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF)
  local MTU = 1500
  local MAX_FRAME = 1518
  local MIN_FRAME = 64
  local ARP_TTL = 120          -- seconds
  local RX_QUEUE_MAX = 64

  -- ---- bit helpers (no bit32 in Cobalt) ----

  local function band(a, b)
    local r, bit = 0, 1
    while a > 0 and b > 0 do
      if a % 2 == 1 and b % 2 == 1 then r = r + bit end
      a = math.floor(a / 2)
      b = math.floor(b / 2)
      bit = bit * 2
    end
    return r
  end

  local function bxor(a, b)
    local r, bit = 0, 1
    while a > 0 or b > 0 do
      local abit, bbit = a % 2, b % 2
      if abit ~= bbit then r = r + bit end
      a = math.floor(a / 2)
      b = math.floor(b / 2)
      bit = bit * 2
    end
    return r
  end

  local function bshl(a, n) return a * (2 ^ n) end
  local function bshr(a, n) return math.floor(a / (2 ^ n)) end
  M.bxor = bxor

  -- ---- state ----

  M.enabled = false
  M.modem = nil
  M.side = nil
  M.mac = nil
  M.channel = 0
  M.ip = string.char(0, 0, 0, 0)          -- 4-byte string
  M.netmask = string.char(255, 255, 255, 0)
  M.gateway = string.char(0, 0, 0, 0)
  M.arp_cache = {}                        -- ip_str -> { mac, ttl, static }
  M.arp_pending = {}                      -- ip_str -> { callback, ... }
  M.protos = {}                           -- proto_num -> handler(payload, src_ip)
  M.frag_buf = {}                         -- key -> reassembly state
  M.timers = {}                           -- timer_id -> action
  M.rx_queue = {}                         -- raw frames for /dev/modemN
  M.ip_id = 1
  M.routes = {}                           -- { dest=ip4, mask=ip4, gw=ip4, metric=int }

  -- ---- helpers ----

  function M.ip_to_str(ip)
    return string.format("%d.%d.%d.%d", ip:byte(1), ip:byte(2), ip:byte(3), ip:byte(4))
  end

  function M.str_to_ip(s)
    local a, b, c, d = s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if not (a and b and c and d) then return nil end
    if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
    return string.char(a, b, c, d)
  end

  function M.mac_to_str(mac)
    local parts = {}
    for i = 1, 6 do parts[i] = string.format("%02x", mac:byte(i)) end
    return table.concat(parts, ":")
  end

  function M.str_to_mac(s)
    local parts = {}
    for p in s:gmatch("%x+") do
      local v = tonumber(p, 16)
      if not v or v > 255 then return nil end
      parts[#parts + 1] = v
    end
    if #parts ~= 6 then return nil end
    return string.char(table.unpack(parts))
  end

  -- ---- CRC32 (Ethernet FCS) ----

  local crc_table
  local function crc32(s)
    if not crc_table then
      crc_table = {}
      for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
          if band(c, 1) == 1 then
            c = bxor(bshr(c, 1), 0xEDB88320)
          else
            c = bshr(c, 1)
          end
        end
        crc_table[i] = c
      end
    end
    local crc = 0xFFFFFFFF
    for i = 1, #s do
      crc = bxor(bshr(crc, 8), crc_table[band(bxor(crc, s:byte(i)), 0xFF)])
    end
    crc = bxor(crc, 0xFFFFFFFF)
    return string.char(band(crc, 0xFF), band(bshr(crc, 8), 0xFF),
      band(bshr(crc, 16), 0xFF), band(bshr(crc, 24), 0xFF))
  end
  M.crc32 = crc32

  -- ---- Ethernet framing ----

  function M.eth_build(dest_mac, ethertype, payload)
    local body = dest_mac .. M.mac
      .. string.char(math.floor(ethertype / 256), ethertype % 256)
      .. payload
    if #body < MIN_FRAME - 4 then
      body = body .. string.rep("\0", MIN_FRAME - 4 - #body)
    end
    return body .. crc32(body)
  end

  function M.eth_parse(frame)
    if type(frame) ~= "string" then return nil end
    if #frame < MIN_FRAME or #frame > MAX_FRAME then return nil end
    local body = frame:sub(1, -5)
    if crc32(body) ~= frame:sub(-4) then return nil end
    local dest = body:sub(1, 6)
    local src = body:sub(7, 12)
    local ethertype = body:byte(13) * 256 + body:byte(14)
    return dest, src, ethertype, body:sub(15)
  end

  -- ---- transmit / receive ----

  function M.transmit(frame)
    if not M.enabled then return end
    M.modem.transmit(M.channel, M.channel, frame)
  end

  function M.on_modem_message(side, channel, replyChannel, message, distance)
    if not M.enabled then return end
    if type(message) ~= "string" then return end
    -- queue raw frame for /dev/modemN readers (bounded)
    if #M.rx_queue < RX_QUEUE_MAX then
      M.rx_queue[#M.rx_queue + 1] = message
    end
    local dest, src, ethertype, payload = M.eth_parse(message)
    if not dest then return end
    if dest ~= M.mac and dest ~= BROADCAST_MAC then return end
    if ethertype == 0x0806 then
      M.arp_handle(payload)
    elseif ethertype == 0x0800 then
      M.ip_handle(payload)
    end
  end

  -- ---- ARP (RFC 826) ----

  local function arp_packet(op, sha, spa, tha, tpa)
    return string.char(0, 1, 8, 0, 6, 4, 0, op) .. sha .. spa .. tha .. tpa
  end

  function M._arp_cache(ip_str, mac, is_static)
    M.arp_cache[ip_str] = { mac = mac, ttl = os.clock() + ARP_TTL, static = is_static }
    -- schedule a sweep timer (one at a time)
    if not M.arp_sweep_timer then
      M.arp_sweep_timer = os.startTimer(ARP_TTL)
      M.timers[M.arp_sweep_timer] = function()
        M.arp_sweep_timer = nil
        local now = os.clock()
        for k, v in pairs(M.arp_cache) do
          if not v.static and v.ttl < now then M.arp_cache[k] = nil end
        end
      end
    end
  end

  function M.arp_request(ip)
    M.transmit(M.eth_build(BROADCAST_MAC, 0x0806,
      arp_packet(1, M.mac, M.ip, string.rep("\0", 6), ip)))
  end

  function M.arp_reply(ip, mac)
    M.transmit(M.eth_build(mac, 0x0806,
      arp_packet(2, M.mac, M.ip, mac, ip)))
  end

  function M.arp_resolve(ip, callback)
    local dstr = M.ip_to_str(ip)
    local entry = M.arp_cache[dstr]
    if entry then
      callback(entry.mac)
      return
    end
    M.arp_pending[dstr] = M.arp_pending[dstr] or {}
    table.insert(M.arp_pending[dstr], callback)
    M.arp_request(ip)
  end

  function M.arp_handle(payload)
    if #payload < 28 then return end
    local htype = payload:byte(1) * 256 + payload:byte(2)
    local ptype = payload:byte(3) * 256 + payload:byte(4)
    local hlen, plen = payload:byte(5), payload:byte(6)
    local op = payload:byte(7) * 256 + payload:byte(8)
    if htype ~= 1 or ptype ~= 0x0800 or hlen ~= 6 or plen ~= 4 then return end
    local sha = payload:sub(9, 14)
    local spa = payload:sub(15, 18)
    local tha = payload:sub(19, 24)
    local tpa = payload:sub(25, 28)
    local spa_str = M.ip_to_str(spa)
    if op == 1 then
      -- request: cache sender, reply if it is for us
      M._arp_cache(spa_str, sha, false)
      if tpa == M.ip then
        M.arp_reply(spa, sha)
      end
    elseif op == 2 then
      -- reply: cache sender, resolve queued callbacks
      M._arp_cache(spa_str, sha, false)
      local q = M.arp_pending[spa_str]
      if q then
        M.arp_pending[spa_str] = nil
        for _, cb in ipairs(q) do cb(sha) end
      end
    end
  end

  -- ---- IP (RFC 791) ----

  function M.ip_checksum(header)
    local sum = 0
    for i = 1, #header, 2 do
      local hi = header:byte(i) or 0
      local lo = header:byte(i + 1) or 0
      sum = sum + hi * 256 + lo
    end
    while sum > 0xFFFF do
      sum = (sum % 0x10000) + math.floor(sum / 0x10000)
    end
    return bxor(sum, 0xFFFF)
  end

  function M._same_subnet(ip)
    for i = 1, 4 do
      if band(M.ip:byte(i), M.netmask:byte(i)) ~= band(ip:byte(i), M.netmask:byte(i)) then
        return false
      end
    end
    return true
  end

  -- Count set bits in a 4-byte netmask (prefix length).
  local function count_prefix_bits(mask)
    local n = 0
    for i = 1, 4 do
      local b = mask:byte(i)
      while b > 0 do
        if b % 2 == 1 then n = n + 1 end
        b = math.floor(b / 2)
      end
    end
    return n
  end

  -- Bitwise AND of two 4-byte IP strings.
  local function ip_band(a, b)
    return string.char(band(a:byte(1), b:byte(1)), band(a:byte(2), b:byte(2)),
      band(a:byte(3), b:byte(3)), band(a:byte(4), b:byte(4)))
  end

  -- Longest-prefix-match route lookup. Returns the next-hop IP (gateway, or
  -- dest_ip for a directly-connected route), or nil if no route matches.
  function M.route_lookup(dest_ip)
    local best_match = -1
    local best_gw = nil
    for _, route in ipairs(M.routes) do
      local match = true
      for i = 1, 4 do
        if band(dest_ip:byte(i), route.mask:byte(i)) ~= band(route.dest:byte(i), route.mask:byte(i)) then
          match = false
          break
        end
      end
      if match then
        local prefix = count_prefix_bits(route.mask)
        if prefix > best_match then
          best_match = prefix
          if route.gw == string.char(0, 0, 0, 0) then
            best_gw = dest_ip
          else
            best_gw = route.gw
          end
        end
      end
    end
    return best_gw
  end

  -- Build a full IP packet (header + payload). flags_frag is the 16-bit
  -- flags/fragment-offset field (offset in 8-byte units).
  function M._build_ip(dest_ip, proto, id, flags_frag, payload)
    local total_len = 20 + #payload
    local header = string.char(0x45, 0,
      math.floor(total_len / 256), total_len % 256,
      math.floor(id / 256), id % 256,
      math.floor(flags_frag / 256), flags_frag % 256,
      64, proto, 0, 0)
      .. M.ip .. dest_ip
    local cs = M.ip_checksum(header)
    header = header:sub(1, 10) .. string.char(math.floor(cs / 256), cs % 256) .. header:sub(13)
    return header .. payload
  end

  function M._send_ip_frame(mac, dest_ip, proto, payload)
    local id = M.ip_id
    M.ip_id = (M.ip_id + 1) % 65536
    if #payload > MTU - 20 then
      -- fragment (offset in 8-byte units)
      local offset = 0
      while offset < #payload do
        local chunk = payload:sub(offset + 1, offset + MTU - 20)
        local mf = (offset + #chunk < #payload) and 1 or 0
        local ff = mf * 8192 + math.floor(offset / 8)
        M.transmit(M.eth_build(mac, 0x0800, M._build_ip(dest_ip, proto, id, ff, chunk)))
        offset = offset + #chunk
      end
    else
      M.transmit(M.eth_build(mac, 0x0800, M._build_ip(dest_ip, proto, id, 0, payload)))
    end
  end

  -- Send an IP payload to dest_ip (4-byte string). Resolves the next-hop MAC
  -- via ARP (queues the send until resolution completes if needed).
  function M.send_ip(dest_ip, proto, payload)
    if not M.enabled then return nil, "network disabled" end
    if dest_ip == string.char(255, 255, 255, 255) then
      M._send_ip_frame(BROADCAST_MAC, dest_ip, proto, payload)
      return #payload
    end
    local target = M.route_lookup(dest_ip)
    if not target then
      if M._same_subnet(dest_ip) then target = dest_ip else target = M.gateway end
    end
    local entry = M.arp_cache[M.ip_to_str(target)]
    if entry then
      M._send_ip_frame(entry.mac, dest_ip, proto, payload)
      return #payload
    end
    -- ARP pending: queue the send until resolution completes
    M.arp_resolve(target, function(mac)
      M._send_ip_frame(mac, dest_ip, proto, payload)
    end)
    return nil, "arp pending"
  end

  function M.register_proto(proto_num, handler)
    M.protos[proto_num] = handler
  end

  function M._demux(proto, data, src)
    if proto == 1 then
      M._icmp_handle(data, src)
    else
      local h = M.protos[proto]
      if h then h(data, src) end
    end
  end

  function M.ip_handle(payload)
    if #payload < 20 then return end
    local ver_ihl = payload:byte(1)
    if math.floor(ver_ihl / 16) ~= 4 then return end
    local ihl = ver_ihl % 16
    if ihl < 5 then return end
    local total_len = payload:byte(3) * 256 + payload:byte(4)
    local id = payload:byte(5) * 256 + payload:byte(6)
    local flags_frag = payload:byte(7) * 256 + payload:byte(8)
    local proto = payload:byte(10)
    local src = payload:sub(13, 16)
    local dest = payload:sub(17, 20)
    -- verify header checksum (a valid header verifies to 0)
    if M.ip_checksum(payload:sub(1, ihl * 4)) ~= 0 then return end
    -- destination check
    if dest ~= M.ip and dest ~= string.char(255, 255, 255, 255) then return end
    local frag_offset = flags_frag % 8192
    local mf = flags_frag >= 8192
    local data = payload:sub(ihl * 4 + 1, total_len)
    if mf or frag_offset > 0 then
      -- reassembly: collect fragments, sort by offset, check contiguity
      local key = M.ip_to_str(src) .. ":" .. id .. ":" .. proto
      local frag = M.frag_buf[key]
      if not frag then
        frag = { parts = {}, last = false, created = os.clock() }
        M.frag_buf[key] = frag
      end
      frag.parts[frag_offset] = data
      if not mf then frag.last = true end
      if frag.last then
        local offsets = {}
        for off in pairs(frag.parts) do offsets[#offsets + 1] = off end
        table.sort(offsets)
        local buf, expected, complete = {}, 0, true
        for _, off in ipairs(offsets) do
          if off * 8 ~= expected then complete = false break end
          buf[#buf + 1] = frag.parts[off]
          expected = expected + #frag.parts[off]
        end
        if complete then
          M.frag_buf[key] = nil
          M._demux(proto, table.concat(buf), src)
        end
      end
      return
    end
    M._demux(proto, data, src)
  end

  -- ---- ICMP (echo only) ----

  function M._icmp_handle(data, src)
    if #data < 8 then return end
    local typ = data:byte(1)
    if typ == 8 then
      -- echo request -> echo reply (type 0)
      local body = data:sub(9)
      local reply = string.char(0, 0, 0, 0) .. data:sub(5, 8) .. body
      local cs = M.ip_checksum(reply)
      reply = string.char(0, 0, math.floor(cs / 256), cs % 256) .. data:sub(5, 8) .. body
      M.send_ip(src, 1, reply)
    end
  end

  -- ---- timers ----

  -- Pre-dispatch hook: returns true if timer_id was a network timer.
  function M.timer_fired(timer_id)
    local action = M.timers[timer_id]
    if not action then return false end
    M.timers[timer_id] = nil
    action()
    return true
  end

  -- ---- init ----

  function M.init()
    M.enabled = false
    if not peripheral then
      K.log("net: no peripheral API, network disabled")
      return
    end
    local modem = peripheral.find("modem")
    if not modem then
      K.log("net: no modem found, network disabled")
      return
    end
    M.modem = modem
    M.side = peripheral.getName(modem)
    local cid = os.getComputerID() or 0
    M.mac = string.char(2, 0, 0, 0, math.floor(cid / 256) % 256, cid % 256)
    M.channel = 0
    modem.open(M.channel)
    M.enabled = true
    K.log("net: enabled on " .. tostring(M.side) .. " mac " .. M.mac_to_str(M.mac))
    -- Seed routing table: default route via gateway + directly-connected subnet
    if M.gateway ~= string.char(0, 0, 0, 0) then
      M.routes[1] = { dest = string.char(0, 0, 0, 0), mask = string.char(0, 0, 0, 0), gw = M.gateway, metric = 0 }
    end
    M.routes[#M.routes + 1] = { dest = ip_band(M.ip, M.netmask), mask = M.netmask, gw = string.char(0, 0, 0, 0), metric = 0 }
    -- /dev/modemN: thin wrapper over the same link layer (root-only, 0600)
    K.vfs.register_device("modem0", {
      mode = 0x180,
      read = function(n)
        if #M.rx_queue > 0 then return table.remove(M.rx_queue, 1) end
        return nil
      end,
      write = function(data)
        M.transmit(data)
        return #data
      end,
    })
  end

  return M
end