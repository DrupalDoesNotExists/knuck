--[[
  KNUCK IPC layer
  ===============
  Pipes, FIFOs, and sockets (AF_UNIX, AF_MODEM, AF_HTTP) with a unified
  socket(domain, type, proto) API.

  Blocking model: processes block via K.sched.wait(reason, key). Pipe and
  socket activity wakes them via K.sched.wake. Readiness checks drive
  select/poll.
]]

return function(K)
  local M = {}

  local pipes = {}              -- pipe objects
  local unix_sockets = {}       -- path -> listening socket
  local next_sock = 1
  local fd_ready_waiters = {}   -- processes blocked in select (no timeout)
  local http_pending = {}       -- http.request obj -> { proc, socket }

  -- Block a process until some fd becomes ready (select, no timeout)
  function M.wait_fd_ready(proc, resume_fn)
    fd_ready_waiters[proc] = true
    K.sched.wait(proc, "fd_ready", proc.pid, resume_fn)
  end

  -- Wake all fd_ready waiters (broadcast; select re-checks)
  function M.wake_fd_ready()
    for p in pairs(fd_ready_waiters) do
      fd_ready_waiters[p] = nil
      K.sched.wake("fd_ready", p.pid, true)
    end
  end

  -- ---- pipes ----

  local function new_pipe()
    return {
      buffer = {},
      closed_r = false,
      closed_w = false,
      readers = {},             -- waiting reader processes
      writers = {},             -- waiting writer processes
    }
  end

  -- Create a pipe. Returns read_fd, write_fd.
  function M.pipe()
    local p = new_pipe()
    pipes[p] = true
    return { type = "pipe_r", pipe = p }, { type = "pipe_w", pipe = p }
  end

  -- Is a pipe readable (has data or EOF)?
  function M.pipe_readable(p)
    return #p.buffer > 0 or p.closed_w
  end

  -- Is a pipe writable?
  function M.pipe_writable(p)
    return not p.closed_r
  end

  -- Read from a pipe. Returns data or nil (EOF) or blocks.
  function M.pipe_read(proc, fd, n)
    local p = fd.pipe
    if #p.buffer > 0 then
      local data = table.remove(p.buffer, 1)
      -- wake a waiting writer (space freed)
      for w in pairs(p.writers) do
        p.writers[w] = nil
        K.sched.wake("pipe_write", p, true)
        break
      end
      return data
    end
    if p.closed_w then return nil end  -- EOF
    -- block until data or EOF; on wake, re-read the buffer
    p.readers[proc] = true
    K.sched.wait(proc, "pipe_read", p, function()
      p.readers[proc] = nil
      if #p.buffer > 0 then
        local data = table.remove(p.buffer, 1)
        for w in pairs(p.writers) do
          p.writers[w] = nil
          K.sched.wake("pipe_write", p, true)
          break
        end
        return data
      end
      return nil
    end)
  end

  -- Write to a pipe. Returns bytes or nil (EPIPE).
  function M.pipe_write(proc, fd, data)
    local p = fd.pipe
    if p.closed_r then
      -- SIGPIPE: write to a pipe with no reader
      if K.proc and K.proc.send_signal then K.proc.send_signal(proc, 13) end
      return nil, "EPIPE"
    end
    p.buffer[#p.buffer + 1] = data
    -- wake a waiting reader
    for r in pairs(p.readers) do
      p.readers[r] = nil
      K.sched.wake("pipe_read", p, true)
      break
    end
    M.wake_fd_ready()
    return #data
  end

  -- Close a pipe end
  function M.pipe_close(fd)
    local p = fd.pipe
    if fd.type == "pipe_r" then
      p.closed_r = true
      -- wake writers (EPIPE)
      for w in pairs(p.writers) do
        p.writers[w] = nil
        K.sched.wake("pipe_write", p, nil)
      end
    else
      p.closed_w = true
      -- wake readers (EOF)
      for r in pairs(p.readers) do
        p.readers[r] = nil
        K.sched.wake("pipe_read", p, nil)
      end
    end
    return true
  end

  -- ---- FIFOs ----

  -- Create a FIFO inode (called by mkfifo syscall via vfs)
  function M.fifo_create()
    return { type = "fifo", pipe = new_pipe() }
  end

  -- Open a FIFO for read: signal a reader exists, then block until a writer
  function M.fifo_open_read(proc, ino, on_open)
    local p = ino.pipe
    p.has_reader = true
    -- wake a waiting writer
    for w in pairs(p.writers) do
      p.writers[w] = nil
      K.sched.wake("fifo_write", p, true)
      break
    end
    if not p.has_writer then
      p.readers[proc] = true
      K.sched.wait(proc, "fifo_read", p, function()
        p.readers[proc] = nil
        return { on_open({ type = "pipe_r", pipe = p }) }
      end)
    end
    return { type = "pipe_r", pipe = p }
  end

  -- Open a FIFO for write: signal a writer exists, then block until a reader
  function M.fifo_open_write(proc, ino, on_open)
    local p = ino.pipe
    p.has_writer = true
    -- wake a waiting reader
    for r in pairs(p.readers) do
      p.readers[r] = nil
      K.sched.wake("fifo_read", p, true)
      break
    end
    if not p.has_reader then
      p.writers[proc] = true
      K.sched.wait(proc, "fifo_write", p, function()
        p.writers[proc] = nil
        return { on_open({ type = "pipe_w", pipe = p }) }
      end)
    end
    return { type = "pipe_w", pipe = p }
  end

  -- Called when a FIFO end opens: wake the opposite waiter
  function M.fifo_joined(p, side)
    if side == "r" then
      p.has_reader = true
      for w in pairs(p.writers) do
        p.writers[w] = nil
        K.sched.wake("fifo_write", p, true)
        break
      end
    else
      p.has_writer = true
      for r in pairs(p.readers) do
        p.readers[r] = nil
        K.sched.wake("fifo_read", p, true)
        break
      end
    end
  end

  -- ---- sockets ----

  -- Create a socket fd
  function M.socket(domain, socktype, proto)
    local s = {
      id = next_sock,
      domain = domain or "unix",
      socktype = socktype or "stream",
      proto = proto or 0,
      state = "unbound",        -- unbound | bound | listening | connected
      path = nil,
      backlog = {},
      conn = nil,               -- for connected stream sockets
      queue = {},               -- for datagram sockets (incoming messages)
      peer = nil,
      closed = false,
      -- network sockets
      port = nil,               -- AF_MODEM bound UDP port
      broadcast = false,        -- SO_BROADCAST
      url = nil,                -- AF_HTTP target URL
      response = nil,           -- AF_HTTP canned response
      -- AF_MODEM STREAM/TCP
      tcp_conn = nil,           -- TCP connection object (connect/accept)
      tcp_listener = false,     -- this socket is a TCP listener
      -- AF_HTTP real
      http_request = nil,       -- pending http.request object
      http_response = nil,      -- completed response { body, code, headers }
      http_error = nil,         -- failure message
      http_method = "GET",      -- GET | POST
      http_headers = {},        -- request headers
      http_body = nil,          -- POST body
    }
    next_sock = next_sock + 1
    return { type = "socket", sock = s }
  end

  -- Bind a socket to a path (AF_UNIX) or port (AF_MODEM)
  function M.socket_bind(proc, fd, path)
    local s = fd.sock
    if s.domain == "modem" then
      -- AF_MODEM: bind to a UDP port (root-only)
      if proc.uid ~= 0 then return nil, "permission denied" end
      local port = tonumber(path)
      if not port then return nil, "invalid port" end
      local ok, err = K.net_transport.udp_bind(port)
      if not ok then return nil, err end
      s.state = "bound"
      s.port = port
      return true
    end
    if s.domain == "modem" and s.socktype == "stream" then
      -- AF_MODEM STREAM: bind = listen on a TCP port (root-only)
      if proc.uid ~= 0 then return nil, "permission denied" end
      local port = tonumber(path)
      if not port then return nil, "invalid port" end
      local ok, err = K.net_transport.tcp_listen(port)
      if not ok then return nil, err end
      s.state = "listening"
      s.port = port
      s.tcp_listener = true
      return true
    end
    if s.domain ~= "unix" then return nil, "invalid argument" end
    if unix_sockets[path] then return nil, "address in use" end
    s.state = "bound"
    s.path = path
    unix_sockets[path] = s
    -- register in VFS as a socket inode
    K.vfs.set_socket(path, s)
    return true
  end

  -- Listen on a bound socket
  function M.socket_listen(proc, fd, backlog)
    local s = fd.sock
    if s.tcp_listener then return true end  -- TCP already listening from bind
    if s.state ~= "bound" then return nil, "not bound" end
    s.state = "listening"
    s.backlog_max = backlog or 8
    return true
  end

  -- Accept a connection (blocks until one arrives). on_conn(connfd) converts
  -- the accepted fd into the value the syscall should return (e.g. allocates
  -- an fd number). The resume_fn must return an ARRAY table so the process
  -- wrapper's table.unpack yields the value.
  function M.socket_accept(proc, fd, on_conn)
    local s = fd.sock
    if s.tcp_listener then
      -- AF_MODEM STREAM: accept from a TCP listener (blocks until a conn)
      local on_conn_fn = function(conn)
        local cs = {
          id = next_sock,
          domain = "modem",
          socktype = "stream",
          state = "connected",
          tcp_conn = conn,
          peer = K.net.ip_to_str(conn.remote_ip) .. ":" .. conn.remote_port,
          queue = {},
          closed = false,
        }
        next_sock = next_sock + 1
        return { type = "socket", sock = cs }
      end
      return K.net_transport.tcp_accept(proc, s.port, on_conn_fn)
    end
    if s.state ~= "listening" then return nil, "not listening" end
    if #s.backlog > 0 then
      local conn = table.remove(s.backlog, 1)
      return M._make_conn(conn)
    end
    -- block until a connection arrives; on wake, re-check the backlog
    s.accept_waiters = s.accept_waiters or {}
    s.accept_waiters[proc] = true
    K.sched.wait(proc, "accept", s, function()
      s.accept_waiters[proc] = nil
      if #s.backlog > 0 then
        local conn = table.remove(s.backlog, 1)
        return { on_conn(M._make_conn(conn)) }
      end
      return nil
    end)
  end

  -- Connect to a listening socket (blocks until accepted)
  function M.socket_connect(proc, fd, path)
    local s = fd.sock
    if s.domain == "http" then
      -- AF_HTTP: connect sets the target URL (STREAM only)
      if s.socktype ~= "stream" then return nil, "invalid argument" end
      if not path:match("^https?://") then return nil, "invalid url" end
      if not http then return nil, "http not available" end
      if not http.checkURL(path) then return nil, "url not allowed" end
      s.state = "connected"
      s.url = path
      s.peer = path
      return true
    end
    if s.domain == "modem" and s.socktype == "stream" then
      -- AF_MODEM STREAM: TCP connect to ip:port
      local ip_str, port_str = path:match("^(%d+%.%d+%.%d+%.%d+):(%d+)$")
      if not ip_str then return nil, "invalid address" end
      local dest_ip = K.net.str_to_ip(ip_str)
      local dest_port = tonumber(port_str)
      if not dest_ip or not dest_port then return nil, "invalid address" end
      local ok, err = K.net_transport.tcp_connect(proc, dest_ip, dest_port, s.port or 0)
      if not ok then return nil, err end
      for conn in pairs(K.net_transport.tcp_conns) do
        if conn.remote_ip == dest_ip and conn.remote_port == dest_port
          and conn.state == "ESTABLISHED" then
          s.tcp_conn = conn
          break
        end
      end
      if not s.tcp_conn then return nil, "connection failed" end
      s.state = "connected"
      s.peer = path
      return true
    end
    local server = unix_sockets[path]
    if not server or server.state ~= "listening" then
      return nil, "connection refused"
    end
    -- create the connection pair
    local conn = {
      server = server,
      client = s,
      to_server = new_pipe(),   -- client -> server
      to_client = new_pipe(),   -- server -> client
    }
    s.state = "connected"
    s.conn = conn
    s.peer = path
    server.backlog[#server.backlog + 1] = conn
    -- wake an accept waiter
    if server.accept_waiters then
      for w in pairs(server.accept_waiters) do
        server.accept_waiters[w] = nil
        K.sched.wake("accept", server, true)
        break
      end
    end
    return true
  end

  -- Build the server-side fd for an accepted connection
  function M._make_conn(conn)
    local s = {
      id = next_sock,
      domain = "unix",
      socktype = "stream",
      state = "connected",
      conn = conn,
      peer = conn.client.path or "unix",
      queue = {},
      closed = false,
    }
    next_sock = next_sock + 1
    return { type = "socket", sock = s }
  end

  -- Send on a socket
  function M.socket_send(proc, fd, data)
    local s = fd.sock
    if s.closed then return nil, "closed" end
    if s.domain == "http" then
      -- AF_HTTP: send fires an async http.request and blocks for the response
      if s.state ~= "connected" then return nil, "not connected" end
      if not http then return nil, "http not available" end
      if s.http_request then return nil, "request in progress" end
      local url = s.url
      local ok, req
      if s.http_method == "POST" then
        ok, req = http.request(url, s.http_body or data, s.http_headers or {})
      else
        local full_url = url
        if data and #data > 0 then
          full_url = full_url .. (url:find("?") and "&" or "?") .. data
        end
        ok, req = http.request(full_url)
      end
      if not ok then return nil, "request failed" end
      s.http_request = req
      http_pending[req] = { proc = proc, socket = s }
      K.sched.wait(proc, "http_response", proc.pid)
      return true
    end
    if s.domain == "modem" and s.tcp_conn then
      -- AF_MODEM STREAM: TCP send
      if s.closed then return nil, "closed" end
      if s.tcp_conn.state ~= "ESTABLISHED" then return nil, "not connected" end
      return K.net_transport.tcp_send(proc, s.tcp_conn, data)
    end
    if s.socktype == "datagram" then
      -- datagram: send to peer's queue
      local target = s.peer_sock
      if not target then return nil, "not connected" end
      target.queue[#target.queue + 1] = data
      M._wake_recv(target)
      M.wake_fd_ready()
      return #data
    end
    -- stream: write to the connection pipe
    local conn = s.conn
    if not conn then return nil, "not connected" end
    local out = (conn.client == s) and conn.to_server or conn.to_client
    return M.pipe_write(proc, { type = "pipe_w", pipe = out }, data)
  end

  -- Receive on a socket (blocks)
  function M.socket_recv(proc, fd, n)
    local s = fd.sock
    if s.closed then return nil end
    if s.domain == "http" then
      -- AF_HTTP: recv returns the response body (or error)
      if s.http_response then
        local r = s.http_response
        s.http_response = nil
        return "HTTP/1.1 " .. r.code .. " OK\r\nContent-Length: " .. #(r.body or "")
          .. "\r\n\r\n" .. (r.body or "")
      end
      if s.http_error then
        local e = s.http_error
        s.http_error = nil
        return nil, e
      end
      return nil
    end
    if s.domain == "modem" and s.tcp_conn then
      -- AF_MODEM STREAM: TCP recv
      if s.closed then return nil end
      return K.net_transport.tcp_recv(proc, s.tcp_conn)
    end
    if s.socktype == "datagram" then
      if #s.queue > 0 then
        return table.remove(s.queue, 1)
      end
      -- block until a datagram arrives; on wake, re-read the queue
      s.recv_waiters = s.recv_waiters or {}
      s.recv_waiters[proc] = true
      K.sched.wait(proc, "recv", s, function()
        s.recv_waiters[proc] = nil
        if #s.queue > 0 then return table.remove(s.queue, 1) end
        return nil
      end)
    end
    -- stream: read from the connection pipe
    local conn = s.conn
    if not conn then return nil, "not connected" end
    local inp = (conn.client == s) and conn.to_client or conn.to_server
    return M.pipe_read(proc, { type = "pipe_r", pipe = inp }, n)
  end

  -- Send a datagram to a specific address (AF_MODEM)
  function M.socket_sendto(proc, fd, data, dest_ip, dest_port)
    local s = fd.sock
    if s.closed then return nil, "closed" end
    if s.domain ~= "modem" then return nil, "invalid argument" end
    if s.state ~= "bound" then return nil, "not bound" end
    if dest_ip == string.char(255, 255, 255, 255) and not s.broadcast then
      return nil, "permission denied"  -- SO_BROADCAST required
    end
    return K.net_transport.udp_send(s.port, dest_ip, dest_port, data)
  end

  -- Receive a datagram with sender address (AF_MODEM). Blocks.
  function M.socket_recvfrom(proc, fd)
    local s = fd.sock
    if s.closed then return nil end
    if s.domain ~= "modem" then return nil, "invalid argument" end
    if s.state ~= "bound" then return nil, "not bound" end
    return K.net_transport.udp_recv(proc, s.port)
  end

  -- Wake a socket's recv waiters
  function M._wake_recv(s)
    if s.recv_waiters then
      for w in pairs(s.recv_waiters) do
        s.recv_waiters[w] = nil
        K.sched.wake("recv", s, true)
        break
      end
    end
  end

  -- Shutdown a socket honoring how: "read" | "write" | "both"
  function M.socket_shutdown(fd, how)
    local s = fd.sock
    if s.closed then return true end
    how = how or "both"
    if s.tcp_conn then
      -- TCP: write = FIN (close conn), read = stop reading
      if how == "write" or how == "both" then
        if not s.tcp_conn.closed then K.net_transport.tcp_close(s.tcp_conn) end
      end
      if how == "read" or how == "both" then
        s.closed = true
      end
      return true
    end
    if s.conn then
      -- UNIX stream: write closes the out pipe (EOF to peer), read closes the in pipe
      if how == "write" or how == "both" then
        local out = (s.conn.client == s) and s.conn.to_server or s.conn.to_client
        M.pipe_close({ type = "pipe_w", pipe = out })
      end
      if how == "read" or how == "both" then
        local inp = (s.conn.client == s) and s.conn.to_client or s.conn.to_server
        M.pipe_close({ type = "pipe_r", pipe = inp })
      end
      if how == "both" then s.closed = true end
      return true
    end
    return M.socket_close(fd)
  end

  -- Close a socket
  function M.socket_close(fd)
    local s = fd.sock
    if s.closed then return true end
    s.closed = true
    if s.tcp_conn and not s.tcp_conn.closed then
      K.net_transport.tcp_close(s.tcp_conn)
    end
    if s.path and unix_sockets[s.path] == s then
      unix_sockets[s.path] = nil
      K.vfs.drop_socket(s.path)
    end
    -- close connection pipes
    if s.conn then
      M.pipe_close({ type = "pipe_r", pipe = s.conn.to_server })
      M.pipe_close({ type = "pipe_w", pipe = s.conn.to_server })
      M.pipe_close({ type = "pipe_r", pipe = s.conn.to_client })
      M.pipe_close({ type = "pipe_w", pipe = s.conn.to_client })
    end
    return true
  end

  -- Socket readiness (for select)
  function M.socket_readable(s)
    if s.closed then return true end
    if s.domain == "modem" then
      if s.tcp_conn then
        return #s.tcp_conn.recv_queue > 0
          or s.tcp_conn.state == "CLOSE_WAIT"
          or s.tcp_conn.state == "CLOSED"
      end
      return s.port ~= nil and K.net_transport.udp_readable(s.port)
    end
    if s.domain == "http" then
      return s.http_response ~= nil or s.http_error ~= nil
    end
    if s.socktype == "datagram" then return #s.queue > 0 end
    if s.state == "listening" then return #s.backlog > 0 end
    if s.conn then
      local inp = (s.conn.client == s) and s.conn.to_client or s.conn.to_server
      return M.pipe_readable(inp)
    end
    return false
  end

  function M.socket_writable(s)
    if s.closed then return false end
    if s.domain == "modem" then
      if s.tcp_conn then
        return s.tcp_conn.state == "ESTABLISHED" and #s.tcp_conn.send_queue == 0
      end
      return s.state == "bound"
    end
    if s.domain == "http" then return s.state == "connected" end
    if s.socktype == "datagram" then return s.peer_sock ~= nil end
    if s.state == "connected" and s.conn then
      local out = (s.conn.client == s) and s.conn.to_server or s.conn.to_client
      return M.pipe_writable(out)
    end
    return false
  end

  -- ---- fd readiness (for select) ----

  function M.fd_readable(fd)
    if fd.type == "pipe_r" then return M.pipe_readable(fd.pipe) end
    if fd.type == "socket" then return M.socket_readable(fd.sock) end
    if fd.type == "console" then return false end
    if fd.type == "file" or fd.type == "memfile" then return true end
    return false
  end

  function M.fd_writable(fd)
    if fd.type == "pipe_w" then return M.pipe_writable(fd.pipe) end
    if fd.type == "socket" then return M.socket_writable(fd.sock) end
    if fd.type == "console" then return true end
    if fd.type == "file" or fd.type == "memfile" then return true end
    return false
  end

  -- Handle an http_success/http_failure event from the scheduler: match the
  -- completed request to its waiting process and wake it.
  function M.http_event(kind, req, err_msg)
    local entry = http_pending[req]
    if not entry then return end
    http_pending[req] = nil
    local s = entry.socket
    s.http_request = nil
    if kind == "success" and req.readAll then
      local body = req.readAll()
      local code = req.getResponseCode and req.getResponseCode() or 0
      local headers = req.getResponseHeaders and req.getResponseHeaders() or {}
      req.close()
      s.http_response = { body = body, code = code, headers = headers }
    else
      s.http_error = err_msg or "request failed"
    end
    K.sched.wake("http_response", entry.proc.pid, true)
  end

  return M
end