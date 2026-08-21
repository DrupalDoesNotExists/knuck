--[[
  KNUCK ICMP module
  =================
  Loadable kernel module implementing ICMP (Internet Control Message Protocol,
  RFC 792). Replaces the hardcoded _icmp_handle in net.lua.

  Provides:
    - Protocol handler registered via K.net.register_proto(1, handler)
    - AF_ICMP socket domain for userland ping/traceroute
    - Per-socket receive queues with blocking recv
    - ICMP statistics (sent/received/errors)

  ICMP types handled:
    0  echo reply
    3  destination unreachable
    11 time exceeded
    8  echo request (handled by kernel, also forwarded to sockets)

  Socket model:
    socket("icmp", "dgram", 1)  -- AF_ICMP, SOCK_DGRAM, IPPROTO_ICMP
    bind(fd, "0.0.0.0")        -- optional, binds to filter
    sendto(fd, data, dest_ip)   -- sends ICMP with auto-ident/seq
    recvfrom(fd)                -- blocks until ICMP packet arrives
]]

return function(K)
  local M = {}

  local net = nil               -- set in init()

  -- ---- ICMP constants ----

  local ICMP_ECHO_REPLY    = 0
  local ICMP_DEST_UNREACH  = 3
  local ICMP_TIME_EXCEED   = 11
  local ICMP_ECHO_REQUEST  = 8

  -- ---- state ----

  local sockets = {}           -- all ICMP sockets (fd.sock references)
  local ident_counter = 1      -- auto-incrementing ICMP ident
  local stats = {
    sent = 0,
    received = 0,
    errors = 0,
    echo_requests = 0,
    echo_replies = 0,
  }

  -- ---- ICMP checksum (RFC 1071) ----

  local function icmp_checksum(data)
    local sum = 0
    for i = 1, #data, 2 do
      local hi = data:byte(i) or 0
      local lo = data:byte(i + 1) or 0
      sum = sum + hi * 256 + lo
    end
    while sum > 0xFFFF do
      sum = (sum % 0x10000) + math.floor(sum / 0x10000)
    end
    return K.net.bxor(sum, 0xFFFF)
  end

  -- Build ICMP header: type(1) + code(1) + checksum(2) + rest(4) + payload
  local function build_icmp(type, code, rest, payload)
    -- rest is 4 bytes (e.g. ident+seq for echo, or unused for error)
    payload = payload or ""
    local header = string.char(type, code, 0, 0) .. rest .. payload
    local cs = icmp_checksum(header)
    header = string.char(type, code, math.floor(cs / 256), cs % 256) .. rest .. payload
    return header
  end

  -- ---- protocol handler (called by net._demux for proto=1) ----

  function M.handle(data, src_ip)
    if #data < 8 then
      stats.errors = stats.errors + 1
      return
    end

    local typ = data:byte(1)
    stats.received = stats.received + 1

    -- Echo request: kernel responds AND forwards to sockets
    if typ == ICMP_ECHO_REQUEST then
      stats.echo_requests = stats.echo_requests + 1
      -- Kernel auto-reply: type 8 -> type 0
      local reply_payload = data:sub(9)  -- everything after 8-byte ICMP header
      local reply_rest = data:sub(5, 8)  -- ident + sequence
      local reply = build_icmp(ICMP_ECHO_REPLY, 0, reply_rest, reply_payload)
      net.send_ip(src_ip, 1, reply)
      stats.sent = stats.sent + 1
    elseif typ == ICMP_ECHO_REPLY then
      stats.echo_replies = stats.echo_replies + 1
    end

    -- Forward to all matching ICMP sockets
    for _, s in ipairs(sockets) do
      if not s.closed then
        -- Filter: if bound to a specific ident, only deliver matching
        local ident = nil
        if #data >= 5 then
          ident = data:byte(5) * 256 + data:byte(6)
        end
        local deliver = true
        if s.bound_ident and ident and s.bound_ident ~= ident then
          deliver = false
        end
        if deliver then
          s.queue[#s.queue + 1] = {
            data = data,
            src_ip = src_ip,
            typ = typ,
          }
          -- Wake a waiting recv
          if s.recv_waiters then
            for w in pairs(s.recv_waiters) do
              s.recv_waiters[w] = nil
              K.sched.wake("icmp_recv", s, true)
              break
            end
          end
          K.ipc.wake_fd_ready()
        end
      end
    end
  end

  -- ---- socket operations ----

  function M.socket_create(domain, socktype, proto)
    local s = {
      id = nil,                 -- set by ipc.socket()
      domain = domain,
      socktype = socktype,
      proto = proto,
      state = "unbound",
      closed = false,
      queue = {},               -- inbound ICMP packets
      recv_waiters = {},
      bound_ident = nil,        -- nil = accept all, number = filter by ident
    }
    sockets[#sockets + 1] = s
    return s
  end

  function M.socket_bind(proc, s, addr)
    if proc.uid ~= 0 then return nil, "permission denied" end
    -- addr can be "0.0.0.0" (any) or a specific ident to filter
    if addr and addr ~= "0.0.0.0" then
      local ident = tonumber(addr)
      if ident then
        s.bound_ident = ident
      end
    end
    s.state = "bound"
    return true
  end

  function M.socket_send(proc, s, data)
    if s.closed then return nil, "closed" end
    if s.state ~= "bound" then return nil, "not bound" end
    -- data should be a raw ICMP packet or at least 8+ bytes
    if #data < 8 then return nil, "invalid argument" end

    local dest_ip = s.dest_ip
    if not dest_ip then return nil, "no destination" end

    -- Compute checksum and send
    local cs = icmp_checksum(data)
    local packet = data:sub(1, 2)
      .. string.char(math.floor(cs / 256), cs % 256)
      .. data:sub(5)

    local ok, err = net.send_ip(dest_ip, 1, packet)
    if ok then
      stats.sent = stats.sent + 1
      return #data
    end
    return nil, err
  end

  function M.socket_sendto(proc, s, data, dest_ip, dest_port)
    if s.closed then return nil, "closed" end
    if #data < 8 then return nil, "invalid argument" end

    s.dest_ip = dest_ip
    s.state = "bound"

    local cs = icmp_checksum(data)
    local packet = data:sub(1, 2)
      .. string.char(math.floor(cs / 256), cs % 256)
      .. data:sub(5)

    local ok, err = net.send_ip(dest_ip, 1, packet)
    if ok then
      stats.sent = stats.sent + 1
      return #data
    end
    return nil, err
  end

  function M.socket_recv(proc, s, n, flags)
    if s.closed then return nil end
    local dontwait = flags and (flags % 2 == 1) or false

    if #s.queue > 0 then
      local pkt = table.remove(s.queue, 1)
      -- Return: data + src_ip as a table for recvfrom semantics
      return pkt.data, pkt.src_ip
    end

    if dontwait then return nil end

    -- Block until ICMP packet arrives
    s.recv_waiters[proc] = true
    K.sched.wait(proc, "icmp_recv", s, function()
      s.recv_waiters[proc] = nil
      if #s.queue > 0 then
        local pkt = table.remove(s.queue, 1)
        return pkt.data, pkt.src_ip
      end
      return nil
    end)
  end

  function M.socket_readable(s)
    if s.closed then return true end  -- EOF
    return #s.queue > 0
  end

  function M.socket_close(s)
    if s.closed then return true end
    s.closed = true
    -- Remove from sockets list
    for i, sock in ipairs(sockets) do
      if sock == s then
        table.remove(sockets, i)
        break
      end
    end
    return true
  end

  -- ---- stats ----

  function M.stats()
    return {
      sent = stats.sent,
      received = stats.received,
      errors = stats.errors,
      echo_requests = stats.echo_requests,
      echo_replies = stats.echo_replies,
    }
  end

  -- ---- init ----

  function M.init()
    net = K.net
    -- Register ICMP protocol handler
    net.register_proto(1, M.handle)
    K.log("net_icmp: loaded, ICMP protocol handler registered")
  end

  return M
end
