--[[
  KNUCK transport layer
  =====================
  UDP + TCP (RFC 793) over the net.lua link/IP layer.

  Registers protocol handlers with K.net:
    K.net.register_proto(6,  tcp_handle)   -- TCP
    K.net.register_proto(17, udp_handle)   -- UDP

  UDP: port table with per-port receive queues. sendto/recvfrom semantics.
  TCP: full state machine (CLOSED/LISTEN/SYN_SENT/SYN_RECEIVED/ESTABLISHED/
  FIN_WAIT_1/FIN_WAIT_2/CLOSE_WAIT/LAST_ACK/TIME_WAIT), sequence/ACK tracking,
  retransmit with exponential backoff (RTO 1s, double, give up after 5).

  Blocking model: processes block via K.sched.wait(reason, key); transport
  activity wakes them via K.sched.wake. Timers (retransmit, TIME_WAIT) use
  os.startTimer and are serviced through K.net.timer_fired.
]]

return function(K)
  local M = {}

  local net = nil               -- set in init()

  -- ---- TCP constants ----
  local TCP_HEADER = 20
  local FLAG_FIN, FLAG_SYN, FLAG_RST, FLAG_ACK = 0x01, 0x02, 0x04, 0x10
  local RTO_INIT = 1            -- seconds
  local RTO_MAX_RETRIES = 5
  local TIME_WAIT_SECS = 30

  -- ---- UDP ----

  local udp_ports = {}          -- port -> { queue = {}, waiters = {} }

  function M.udp_bind(port)
    if udp_ports[port] then return nil, "address in use" end
    udp_ports[port] = { queue = {}, waiters = {} }
    return true
  end

  function M.udp_unbind(port)
    udp_ports[port] = nil
  end

  -- Is a bound UDP port readable (has queued datagrams)?
  function M.udp_readable(port)
    local p = udp_ports[port]
    return p ~= nil and #p.queue > 0
  end

  -- Send a UDP datagram from src_port to dest_ip:dest_port.
  function M.udp_send(src_port, dest_ip, dest_port, data)
    local len = 8 + #data
    local header = string.char(
      math.floor(src_port / 256), src_port % 256,
      math.floor(dest_port / 256), dest_port % 256,
      math.floor(len / 256), len % 256, 0, 0)  -- checksum 0 (optional)
    return K.net.send_ip(dest_ip, 17, header .. data)
  end

  -- Blocking receive from a bound UDP port. Returns data, src_ip, src_port.
  function M.udp_recv(proc, port)
    local p = udp_ports[port]
    if not p then return nil, "not bound" end
    if #p.queue > 0 then
      local d = table.remove(p.queue, 1)
      return d.data, d.src_ip, d.src_port
    end
    p.waiters[proc] = true
    return K.sched.wait(proc, "udp_recv", port, function()
      p.waiters[proc] = nil
      if #p.queue > 0 then
        local d = table.remove(p.queue, 1)
        return { d.data, d.src_ip, d.src_port }
      end
      return nil
    end)
  end

  function M.udp_handle(payload, src_ip)
    if #payload < 8 then return end
    local src_port = payload:byte(1) * 256 + payload:byte(2)
    local dest_port = payload:byte(3) * 256 + payload:byte(4)
    local len = payload:byte(5) * 256 + payload:byte(6)
    local p = udp_ports[dest_port]
    if not p then return end  -- no listener: drop
    local data = payload:sub(9, len)
    p.queue[#p.queue + 1] = { data = data, src_ip = src_ip, src_port = src_port }
    -- wake a waiting receiver
    for w in pairs(p.waiters) do
      p.waiters[w] = nil
      K.sched.wake("udp_recv", dest_port, true)
      break
    end
  end

  -- ---- TCP ----

  local tcp_ports = {}          -- port -> { state="listen", backlog={}, waiters={} }
  local tcp_conns = {}          -- conn objects (active + established)
  M.tcp_conns = tcp_conns       -- exposed for diagnostics/tests

  -- Allocate an ephemeral local port (49152+ range, avoids listeners).
  local next_tcp_ephemeral = 49152
  function M.alloc_port()
    local start = next_tcp_ephemeral
    for i = 0, 16383 do
      local port = start + (i % 16384)
      local used = false
      for conn in pairs(tcp_conns) do
        if conn.local_port == port then used = true; break end
      end
      if not used and not tcp_ports[port] then
        next_tcp_ephemeral = (port + 1) % 16384 + 49152
        return port
      end
    end
    return nil, "no free ports"
  end

  local function new_conn()
    return {
      local_port = 0,
      remote_ip = nil,
      remote_port = 0,
      state = "CLOSED",
      snd_nxt = 0, snd_una = 0, snd_wnd = 0,
      rcv_nxt = 0,
      iss = 0, irs = 0,
      send_queue = {},          -- outbound data awaiting ACK
      recv_queue = {},          -- inbound data awaiting read
      recv_waiters = {},
      send_waiters = {},
      rto = RTO_INIT,
      retries = 0,
      timer_id = nil,
      timer_kind = nil,         -- "retransmit" | "timewait"
      closed = false,
    }
  end

  local function tcp_checksum(src_ip, dest_ip, payload)
    -- pseudo-header + TCP segment
    local len = #payload
    local pseudo = src_ip .. dest_ip .. string.char(0, 6,
      math.floor(len / 256), len % 256)
    local seg = pseudo .. payload
    local sum = 0
    for i = 1, #seg, 2 do
      local hi = seg:byte(i) or 0
      local lo = seg:byte(i + 1) or 0
      sum = sum + hi * 256 + lo
    end
    while sum > 0xFFFF do
      sum = (sum % 0x10000) + math.floor(sum / 0x10000)
    end
    return K.net.bxor(sum, 0xFFFF)
  end

  local function build_tcp(conn, flags, seq, ack, data)
    local data_offset_flags = 5 * 256 + flags
    local header = string.char(
      math.floor(conn.local_port / 256), conn.local_port % 256,
      math.floor(conn.remote_port / 256), conn.remote_port % 256,
      math.floor(seq / 16777216) % 256, math.floor(seq / 65536) % 256,
      math.floor(seq / 256) % 256, seq % 256,
      math.floor(ack / 16777216) % 256, math.floor(ack / 65536) % 256,
      math.floor(ack / 256) % 256, ack % 256,
      math.floor(data_offset_flags / 256), data_offset_flags % 256,
      0, 0,  -- window
      0, 0,  -- checksum
      0, 0)  -- urgent
    local seg = header .. (data or "")
    local cs = tcp_checksum(conn.remote_ip, conn.local_ip, seg)
    seg = seg:sub(1, 16) .. string.char(math.floor(cs / 256), cs % 256) .. seg:sub(19)
    return seg
  end

  -- Send a TCP segment via the IP layer.
  local function send_segment(conn, flags, seq, ack, data)
    local seg = build_tcp(conn, flags, seq, ack, data)
    K.net.send_ip(conn.remote_ip, 6, seg)
  end

  -- Schedule a retransmit timer for a connection.
  local function schedule_retransmit(conn)
    if conn.timer_id then
      K.net.timers[conn.timer_id] = nil
      conn.timer_id = nil
    end
    conn.timer_id = os.startTimer(conn.rto)
    conn.timer_kind = "retransmit"
    K.net.timers[conn.timer_id] = function()
      conn.timer_id = nil
      conn.timer_kind = nil
      M._tcp_retransmit(conn)
    end
  end

  function M._tcp_retransmit(conn)
    if conn.state == "CLOSED" or conn.closed then return end
    conn.retries = conn.retries + 1
    if conn.retries > RTO_MAX_RETRIES then
      -- give up: reset the connection
      conn.state = "CLOSED"
      conn.closed = true
      M._wake_conn(conn)
      return
    end
    -- resend unacked data (or SYN/FIN)
    if conn.state == "SYN_SENT" then
      send_segment(conn, FLAG_SYN, conn.iss, 0, nil)
    elseif conn.state == "SYN_RECEIVED" then
      send_segment(conn, FLAG_SYN + FLAG_ACK, conn.iss, conn.rcv_nxt, nil)
    elseif #conn.send_queue > 0 then
      local data = table.concat(conn.send_queue)
      send_segment(conn, FLAG_ACK, conn.snd_una, conn.rcv_nxt, data)
    elseif conn.state == "FIN_WAIT_1" then
      send_segment(conn, FLAG_FIN + FLAG_ACK, conn.snd_nxt, conn.rcv_nxt, nil)
    end
    conn.rto = conn.rto * 2
    schedule_retransmit(conn)
  end

  -- Wake all waiters on a connection.
  function M._wake_conn(conn)
    for w in pairs(conn.recv_waiters) do
      conn.recv_waiters[w] = nil
      K.sched.wake("tcp_recv", conn, true)
    end
    for w in pairs(conn.send_waiters) do
      conn.send_waiters[w] = nil
      K.sched.wake("tcp_send", conn, true)
    end
  end

  -- ---- TCP public API ----

  -- Open a TCP connection to remote_ip:remote_port. Blocks until established.
  function M.tcp_connect(proc, remote_ip, remote_port, local_port)
    local conn = new_conn()
    if local_port and local_port > 0 then
      conn.local_port = local_port
    else
      local p, err = M.alloc_port()
      if not p then return nil, err end
      conn.local_port = p
    end
    conn.remote_ip = remote_ip
    conn.remote_port = remote_port
    conn.local_ip = K.net.ip
    conn.iss = math.floor(os.clock() * 1000) % 65536
    conn.snd_nxt = conn.iss + 1
    conn.state = "SYN_SENT"
    tcp_conns[conn] = true
    send_segment(conn, FLAG_SYN, conn.iss, 0, nil)
    schedule_retransmit(conn)
    -- block until established or failed
    conn.connect_waiters = conn.connect_waiters or {}
    conn.connect_waiters[proc] = true
    return K.sched.wait(proc, "tcp_connect", conn, function()
      conn.connect_waiters[proc] = nil
      if conn.state == "ESTABLISHED" then
        return { true }
      end
      return { nil, "connection failed" }
    end)
  end

  -- Listen on a port.
  function M.tcp_listen(port)
    if tcp_ports[port] then return nil, "address in use" end
    tcp_ports[port] = { state = "listen", backlog = {}, waiters = {} }
    return true
  end

  -- Accept a connection from a listening port. Blocks until one arrives.
  function M.tcp_accept(proc, port, on_conn)
    local lp = tcp_ports[port]
    if not lp or lp.state ~= "listen" then return nil, "not listening" end
    if #lp.backlog > 0 then
      local conn = table.remove(lp.backlog, 1)
      return on_conn(conn)
    end
    lp.waiters[proc] = true
    return K.sched.wait(proc, "tcp_accept", port, function()
      lp.waiters[proc] = nil
      if #lp.backlog > 0 then
        local conn = table.remove(lp.backlog, 1)
        return { on_conn(conn) }
      end
      return nil
    end)
  end

  -- Send data on an established connection. Blocks until ACKed.
  function M.tcp_send(proc, conn, data)
    if conn.state ~= "ESTABLISHED" then return nil, "not connected" end
    conn.send_queue[#conn.send_queue + 1] = data
    send_segment(conn, FLAG_ACK, conn.snd_nxt, conn.rcv_nxt, data)
    conn.snd_nxt = conn.snd_nxt + #data
    schedule_retransmit(conn)
    -- block until the data is ACKed
    conn.send_waiters[proc] = true
    return K.sched.wait(proc, "tcp_send", conn, function()
      conn.send_waiters[proc] = nil
      if conn.closed then return { nil, "closed" } end
      return { #data }
    end)
  end

  -- Receive data on an established connection. Blocks until data or close.
  function M.tcp_recv(proc, conn)
    if #conn.recv_queue > 0 then
      return table.remove(conn.recv_queue, 1)
    end
    if conn.state == "CLOSE_WAIT" or conn.state == "CLOSED" then
      return nil  -- EOF
    end
    conn.recv_waiters[proc] = true
    return K.sched.wait(proc, "tcp_recv", conn, function()
      conn.recv_waiters[proc] = nil
      if #conn.recv_queue > 0 then return table.remove(conn.recv_queue, 1) end
      return nil
    end)
  end

  -- Close a connection (FIN handshake).
  function M.tcp_close(conn)
    if conn.state == "ESTABLISHED" then
      conn.state = "FIN_WAIT_1"
      send_segment(conn, FLAG_FIN + FLAG_ACK, conn.snd_nxt, conn.rcv_nxt, nil)
      conn.snd_nxt = conn.snd_nxt + 1
      schedule_retransmit(conn)
    elseif conn.state == "CLOSE_WAIT" then
      conn.state = "LAST_ACK"
      send_segment(conn, FLAG_FIN + FLAG_ACK, conn.snd_nxt, conn.rcv_nxt, nil)
      conn.snd_nxt = conn.snd_nxt + 1
      schedule_retransmit(conn)
    else
      conn.state = "CLOSED"
      conn.closed = true
    end
    return true
  end

  -- ---- TCP receive path ----

  function M.tcp_handle(payload, src_ip)
    if #payload < TCP_HEADER then return end
    local src_port = payload:byte(1) * 256 + payload:byte(2)
    local dest_port = payload:byte(3) * 256 + payload:byte(4)
    local seq = payload:byte(5) * 16777216 + payload:byte(6) * 65536
      + payload:byte(7) * 256 + payload:byte(8)
    local ack = payload:byte(9) * 16777216 + payload:byte(10) * 65536
      + payload:byte(11) * 256 + payload:byte(12)
    local data_offset = math.floor(payload:byte(13) / 16)
    local flags = payload:byte(14)
    local data = payload:sub(data_offset * 4 + 1)

    -- find or create the connection
    local conn = M._find_conn(dest_port, src_ip, src_port)
    if not conn then
      -- no matching connection: if listening, create a passive open
      local lp = tcp_ports[dest_port]
      if lp and lp.state == "listen" and flags % 2 == 0 and (flags % 4) / 2 >= 1 then
        -- SYN received
        conn = new_conn()
        conn.local_port = dest_port
        conn.remote_ip = src_ip
        conn.remote_port = src_port
        conn.local_ip = K.net.ip
        conn.irs = seq
        conn.rcv_nxt = seq + 1
        conn.iss = math.floor(os.clock() * 1000) % 65536
        conn.snd_nxt = conn.iss + 1
        conn.state = "SYN_RECEIVED"
        tcp_conns[conn] = true
        send_segment(conn, FLAG_SYN + FLAG_ACK, conn.iss, conn.rcv_nxt, nil)
        schedule_retransmit(conn)
      else
        -- unknown: send RST
        local rst = new_conn()
        rst.local_port = dest_port
        rst.remote_ip = src_ip
        rst.remote_port = src_port
        rst.local_ip = K.net.ip
        send_segment(rst, FLAG_RST + FLAG_ACK, 0, seq + #data, nil)
        return
      end
    end

    -- process flags
    local syn = (flags % 4) / 2 >= 1
    local fin = flags % 2 == 1
    local rst = (flags % 8) / 4 >= 1
    local ackf = (flags % 32) / 16 >= 1

    if rst then
      conn.state = "CLOSED"
      conn.closed = true
      M._wake_conn(conn)
      return
    end

    if syn then
      if conn.state == "SYN_SENT" then
        -- SYN-ACK received: connection established
        conn.irs = seq
        conn.rcv_nxt = seq + 1
        conn.snd_una = ack
        conn.state = "ESTABLISHED"
        if conn.timer_id then K.net.timers[conn.timer_id] = nil; conn.timer_id = nil end
        send_segment(conn, FLAG_ACK, conn.snd_nxt, conn.rcv_nxt, nil)
        -- wake connect waiter
        for w in pairs(conn.connect_waiters or {}) do
          conn.connect_waiters[w] = nil
          K.sched.wake("tcp_connect", conn, true)
        end
      end
    end

    -- ACK of our SYN-ACK: passive open complete (SYN_RECEIVED -> ESTABLISHED)
    if ackf and conn.state == "SYN_RECEIVED" then
      conn.snd_una = ack
      conn.state = "ESTABLISHED"
      if conn.timer_id then K.net.timers[conn.timer_id] = nil; conn.timer_id = nil end
      -- move to listening backlog
      local lp = tcp_ports[conn.local_port]
      if lp then
        lp.backlog[#lp.backlog + 1] = conn
        for w in pairs(lp.waiters) do
          lp.waiters[w] = nil
          K.sched.wake("tcp_accept", conn.local_port, true)
          break
        end
      end
    end

    -- ACK processing: clear unacked data
    if ackf and conn.state == "ESTABLISHED" then
      conn.snd_una = ack
      -- clear acked data from send_queue
      local acked = ack - (conn.snd_nxt - #table.concat(conn.send_queue))
      while acked > 0 and #conn.send_queue > 0 do
        local d = conn.send_queue[1]
        if #d <= acked then
          table.remove(conn.send_queue, 1)
          acked = acked - #d
        else
          break
        end
      end
      if #conn.send_queue == 0 and conn.timer_id and conn.timer_kind == "retransmit" then
        K.net.timers[conn.timer_id] = nil
        conn.timer_id = nil
        conn.timer_kind = nil
        conn.rto = RTO_INIT
        conn.retries = 0
        -- wake send waiters
        for w in pairs(conn.send_waiters) do
          conn.send_waiters[w] = nil
          K.sched.wake("tcp_send", conn, true)
        end
      end
    end

    -- data delivery
    if #data > 0 and conn.state == "ESTABLISHED" then
      conn.recv_queue[#conn.recv_queue + 1] = data
      conn.rcv_nxt = conn.rcv_nxt + #data
      send_segment(conn, FLAG_ACK, conn.snd_nxt, conn.rcv_nxt, nil)
      for w in pairs(conn.recv_waiters) do
        conn.recv_waiters[w] = nil
        K.sched.wake("tcp_recv", conn, true)
      end
    end

    -- FIN processing
    if fin then
      if conn.state == "ESTABLISHED" then
        conn.state = "CLOSE_WAIT"
        conn.rcv_nxt = conn.rcv_nxt + 1
        send_segment(conn, FLAG_ACK, conn.snd_nxt, conn.rcv_nxt, nil)
        -- wake recv waiters (EOF)
        for w in pairs(conn.recv_waiters) do
          conn.recv_waiters[w] = nil
          K.sched.wake("tcp_recv", conn, true)
        end
      elseif conn.state == "FIN_WAIT_1" then
        conn.state = "FIN_WAIT_2"
        conn.rcv_nxt = conn.rcv_nxt + 1
        send_segment(conn, FLAG_ACK, conn.snd_nxt, conn.rcv_nxt, nil)
      elseif conn.state == "FIN_WAIT_2" then
        conn.state = "TIME_WAIT"
        conn.rcv_nxt = conn.rcv_nxt + 1
        send_segment(conn, FLAG_ACK, conn.snd_nxt, conn.rcv_nxt, nil)
        -- schedule TIME_WAIT expiry
        conn.timer_id = os.startTimer(TIME_WAIT_SECS)
        conn.timer_kind = "timewait"
        K.net.timers[conn.timer_id] = function()
          conn.state = "CLOSED"
          conn.closed = true
          conn.timer_id = nil
          conn.timer_kind = nil
        end
      elseif conn.state == "LAST_ACK" then
        conn.state = "CLOSED"
        conn.closed = true
        if conn.timer_id then K.net.timers[conn.timer_id] = nil; conn.timer_id = nil end
      end
    end
  end

  -- Find an existing connection matching (local_port, remote_ip, remote_port).
  function M._find_conn(local_port, remote_ip, remote_port)
    for conn in pairs(tcp_conns) do
      if conn.local_port == local_port and conn.remote_ip == remote_ip
        and conn.remote_port == remote_port and not conn.closed then
        return conn
      end
    end
    return nil
  end

  -- ---- init ----

  function M.init()
    net = K.net
    net.register_proto(6, M.tcp_handle)
    net.register_proto(17, M.udp_handle)
  end

  return M
end