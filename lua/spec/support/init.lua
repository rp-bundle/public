---Test support: loading the core the way an adapter does, and a fake
---platform the tests drive by hand.
---
---The fake is deliberately small, and is not D3's mock platform: it exists so
---the core's own suite can run with no game, no portal and no socket. Its
---clock only moves when a test advances it, so every retry and backoff runs
---instantly and in a fixed order.
---@class spec.support
---@field root string The repository root, with a trailing slash.
---@field core rpf The core table `load_core` last loaded. The helpers use it rather than the global, which a test may replace with the public API as the Gmod adapter does.
local support = {}

local here = debug.getinfo(1, "S").source:sub(2)
-- `lua/` is this file's grandparent's parent, however busted was pointed at it.
-- Either separator: on Windows busted names this file `./spec\support/init.lua`.
support.root = here:gsub("spec[/\\]support[/\\]init%.lua$", "") .. "../"

---A path under the repository root.
---@param relative string Relative to the root, like `lua/core/json.lua`.
---@return string path The path.
function support.path(relative)
  return support.root .. relative
end

---Reads a whole file.
---@param relative string Relative to the repository root.
---@return string contents The file's contents.
function support.read(relative)
  local file = assert(io.open(support.path(relative), "rb"))
  local contents = file:read("*a")
  file:close()
  return contents
end

---A path under the conformance corpus of the protocol version the loaded
---core speaks, `protocol/corpus/v<N>/`, which is the one the Rust tests
---regenerate. Older versions' corpora are frozen, and held to the current
---Rust types by `crates/rpf-protocol/tests/protocol.rs` alone: this core
---only ever decodes frames in the version it speaks.
---@param relative string? Relative to the corpus, like `commands.json`.
---@return string path The path, relative to the repository root.
function support.corpus(relative)
  local dir = "protocol/corpus/v" .. rpf.protocol.VERSION
  if relative then
    return dir .. "/" .. relative
  end
  return dir
end

---Loads the core from scratch, as an adapter would: `init.lua` first, then
---each file in the order it declares, with no `require`.
---@param side "server"|"client"? Which side's files; the server by default.
---@return rpf rpf The fresh global.
function support.load_core(side)
  rawset(_G, "rpf", nil)
  dofile(support.path("lua/core/init.lua"))
  for _, file in ipairs(rpf.files[side or "server"]) do
    dofile(support.path("lua/core/" .. file))
  end
  support.core = rpf
  return rpf
end

---2026-01-01T00:00:00Z, where every fake clock starts.
support.EPOCH_MS = 1767225600000

---Builds a fake server platform.
---@param opts { store: table<string, string>?, seed: integer?, time: number? }? A shared store (for restarts), a random seed, a start time.
---@return spec.FakePlatform platform The platform.
function support.fake_platform(opts)
  opts = opts or {}
  ---A fake server platform. Everything the core does to it is recorded, and
  ---the test plays the portal's side of the socket.
  ---@class spec.FakePlatform: rpf.ServerPlatform
  ---@field time number The fake clock, in milliseconds.
  ---@field timers { at: number, seq: integer, fn: fun() }[] Pending `after` callbacks.
  ---@field seq integer Orders timers due at the same moment.
  ---@field store table<string, string> The fake key-value store. Pass one table to two platforms to simulate a restart.
  ---@field rng integer The deterministic random state.
  ---@field socket { handlers: rpf.platform.SocketHandlers, open: boolean }? The current connection attempt.
  ---@field connects number[] When each `connect` was called, by the fake clock.
  ---@field disconnects number[] When each `disconnect` was called, by the fake clock.
  ---@field sent string[] Every text frame sent on an open socket, in order.
  ---@field logs { level: string, message: string }[] Every log line.
  ---@field exposed table? What `expose` was given.
  ---@field player_identifiers table<any, string[]> What `identifiers` reports per player.
  ---@field kicks { player: any, reason: string }[] Every kick, in order.
  ---@field to_clients { player: any, name: string, payload: string }[] Every message sent to a client, in order.
  ---@field client_handlers table<string, fun(player: any, payload: string)> Handlers registered with `on_client`, by name.
  ---@field bookkeeping table<string, true> Sent texts `support.wire` leaves out: the declaration after a `Welcome` and the ack of its answer.
  local p = {
    engine = "mock",
    time = opts.time or support.EPOCH_MS,
    timers = {},
    seq = 0,
    store = opts.store or {},
    rng = opts.seed or 12345,
    connects = {},
    disconnects = {},
    sent = {},
    logs = {},
    player_identifiers = {},
    kicks = {},
    to_clients = {},
    client_handlers = {},
    bookkeeping = {},
  }

  function p.now()
    return p.time
  end

  function p.after(delay_ms, fn)
    p.seq = p.seq + 1
    p.timers[#p.timers + 1] = { at = p.time + delay_ms, seq = p.seq, fn = fn }
  end

  function p.kv_get(key)
    return p.store[key]
  end

  function p.kv_set(key, value)
    p.store[key] = value
  end

  function p.thread()
    return nil
  end

  -- MINSTD: every product stays below 2^53, so it is exact on LuaJIT too.
  function p.random_hex(n)
    local digits = {}
    for i = 1, n do
      p.rng = (p.rng * 48271) % 2147483647
      digits[i] = ("0123456789abcdef"):sub(p.rng % 16 + 1, p.rng % 16 + 1)
    end
    return table.concat(digits)
  end

  function p.connect(_, handlers)
    p.connects[#p.connects + 1] = p.time
    p.socket = { handlers = handlers, open = false }
  end

  -- Calls the socket's `close` at once, as the interface allows, so the
  -- tests see the core ignore it.
  function p.disconnect()
    p.disconnects[#p.disconnects + 1] = p.time
    local socket = p.socket
    if socket then
      p.socket = nil
      socket.open = false
      socket.handlers.close("closed by the core")
    end
  end

  function p.send(text)
    if p.socket and p.socket.open then
      p.sent[#p.sent + 1] = text
      return true
    end
    return false
  end

  function p.http_request(_, _, _, _, callback)
    p.after(0, function()
      callback(0, "", {})
    end)
  end

  function p.identifiers(player)
    return p.player_identifiers[player] or {}
  end

  function p.name(player)
    return "player " .. tostring(player)
  end

  function p.kick(player, reason)
    p.kicks[#p.kicks + 1] = { player = player, reason = reason }
  end

  function p.notify() end

  function p.to_client(player, name, payload)
    p.to_clients[#p.to_clients + 1] = { player = player, name = name, payload = payload }
  end

  function p.on_client(name, handler)
    p.client_handlers[name] = handler
  end

  function p.log(level, message)
    p.logs[#p.logs + 1] = { level = level, message = message }
  end

  function p.expose(api)
    p.exposed = api
  end

  -- Driving it ---------------------------------------------------------------

  ---Moves the clock forward, running every timer that falls due, in order,
  ---including ones those timers schedule.
  ---@param ms number How far.
  function p.advance(ms)
    local target = p.time + ms
    while true do
      local best
      for i, timer in ipairs(p.timers) do
        if timer.at <= target then
          local b = best and p.timers[best]
          if not b or timer.at < b.at or (timer.at == b.at and timer.seq < b.seq) then
            best = i
          end
        end
      end
      if not best then
        break
      end
      local timer = table.remove(p.timers, best)
      p.time = timer.at
      timer.fn()
    end
    p.time = target
  end

  ---Completes the pending connection attempt.
  function p.open()
    assert(p.socket, "nothing is connecting")
    p.socket.open = true
    p.socket.handlers.open()
  end

  ---Ends the current connection, or fails the pending attempt.
  ---@param reason string? What the platform reports.
  function p.drop(reason)
    local socket = assert(p.socket, "nothing is connected")
    p.socket = nil
    socket.open = false
    socket.handlers.close(reason or "dropped")
  end

  ---Delivers one frame from the portal: a table (encoded here) or raw text.
  ---@param frame table|string The frame.
  function p.deliver(frame)
    local text
    if type(frame) == "table" then
      text = assert(support.core.protocol.encode(support.core.protocol.PORTAL_TO_SERVER, frame))
    else
      text = frame
    end
    assert(p.socket, "nothing is connected").handlers.message(text)
  end

  ---Every sent frame, decoded as the portal would, except the declaration
  ---exchange `support.declared` answered (see `support.wire`).
  ---@return rpf.Frame[] frames The frames, in order.
  function p.frames()
    local out = {}
    for i, text in ipairs(support.wire(p)) do
      out[i] = assert(support.core.protocol.decode(support.core.protocol.SERVER_TO_PORTAL, text))
    end
    return out
  end

  ---The last frame sent, decoded.
  ---@return rpf.Frame frame The frame.
  function p.last()
    local frames = p.frames()
    return frames[#frames]
  end

  ---Delivers a message from a player's client, as the engine would: the
  ---platform names the sender, and the payload is whatever the client sent.
  ---@param player any The sender's handle.
  ---@param name string The message name.
  ---@param payload any The payload, raw.
  function p.from_client(player, name, payload)
    local handler = p.client_handlers[name]
    if handler then
      handler(player, payload)
    end
  end

  ---The decoded payloads of every message of one name sent to a player.
  ---@param player any The recipient.
  ---@param name string The message name.
  ---@return table[] payloads The payloads, decoded, in order.
  function p.messages_to(player, name)
    local out = {}
    for _, message in ipairs(p.to_clients) do
      if message.player == player and message.name == name then
        out[#out + 1] = assert(support.core.json.decode(message.payload))
      end
    end
    return out
  end

  ---Log lines at a level that contain some text.
  ---@param level string The level.
  ---@param text string Plain text to look for.
  ---@return string[] lines The matching lines.
  function p.logged(level, text)
    local out = {}
    for _, line in ipairs(p.logs) do
      if line.level == level and line.message:find(text, 1, true) then
        out[#out + 1] = line.message
      end
    end
    return out
  end

  return p
end

---Builds a fake client platform. The test plays both the game server (the
---handoff messages) and the portal (the HTTP answers).
---@param opts { store: table<string, string>?, time: number? }? A shared store (for a rejoin), a start time.
---@return spec.FakeClient platform The platform.
function support.fake_client_platform(opts)
  opts = opts or {}
  ---A fake client platform. Every request and message is recorded, and
  ---nothing is answered until the test answers it.
  ---@class spec.FakeClient: rpf.ClientPlatform
  ---@field time number The fake clock, in milliseconds.
  ---@field timers { at: number, seq: integer, fn: fun() }[] Pending `after` callbacks.
  ---@field seq integer Orders timers due at the same moment.
  ---@field store table<string, string> The fake key-value store.
  ---@field requests { method: string, url: string, headers: table, body: string?, callback: fun(status: integer, body: string, headers: table), answered: boolean }[] Every HTTP request, in order.
  ---@field to_servers { name: string, payload: string }[] Every message sent to the server, in order.
  ---@field server_handlers table<string, fun(payload: string)> Handlers registered with `on_server`, by name.
  ---@field logs { level: string, message: string }[] Every log line.
  ---@field exposed table? What `expose` was given.
  local c = {
    engine = "mock",
    time = opts.time or support.EPOCH_MS,
    timers = {},
    seq = 0,
    store = opts.store or {},
    requests = {},
    to_servers = {},
    server_handlers = {},
    logs = {},
  }

  function c.now()
    return c.time
  end

  function c.after(delay_ms, fn)
    c.seq = c.seq + 1
    c.timers[#c.timers + 1] = { at = c.time + delay_ms, seq = c.seq, fn = fn }
  end

  function c.kv_get(key)
    return c.store[key]
  end

  function c.kv_set(key, value)
    c.store[key] = value
  end

  function c.http_request(method, url, headers, body, callback)
    c.requests[#c.requests + 1] =
      { method = method, url = url, headers = headers, body = body, callback = callback, answered = false }
  end

  function c.to_server(name, payload)
    c.to_servers[#c.to_servers + 1] = { name = name, payload = payload }
  end

  function c.on_server(name, handler)
    c.server_handlers[name] = handler
  end

  function c.log(level, message)
    c.logs[#c.logs + 1] = { level = level, message = message }
  end

  function c.expose(api)
    c.exposed = api
  end

  ---Moves the clock forward, running every timer that falls due, in order.
  ---@param ms number How far.
  function c.advance(ms)
    local target = c.time + ms
    while true do
      local best
      for i, timer in ipairs(c.timers) do
        if timer.at <= target then
          local b = best and c.timers[best]
          if not b or timer.at < b.at or (timer.at == b.at and timer.seq < b.seq) then
            best = i
          end
        end
      end
      if not best then
        break
      end
      local timer = table.remove(c.timers, best)
      c.time = timer.at
      timer.fn()
    end
    c.time = target
  end

  ---Delivers a message from the game server.
  ---@param name string The message name.
  ---@param fields table|string The payload: a table, encoded here, or raw text.
  function c.from_server(name, fields)
    local payload = type(fields) == "table" and assert(support.core.json.encode(support.core.json.object(fields))) or fields
    ---@cast payload string
    local handler = assert(c.server_handlers[name], "nothing handles " .. name)
    handler(payload)
  end

  ---The oldest unanswered HTTP request, with its body decoded.
  ---@return { method: string, url: string, path: string, body: table, index: integer }? request The request, or nil if none is waiting.
  function c.pending()
    for i, request in ipairs(c.requests) do
      if not request.answered then
        return {
          method = request.method,
          url = request.url,
          path = request.url:match("/api/v1/player/(.*)$") or request.url,
          body = request.body and assert(support.core.json.decode(request.body)) or {},
          index = i,
        }
      end
    end
    return nil
  end

  ---Answers the oldest unanswered HTTP request.
  ---@param status integer The status, 0 for no response.
  ---@param body table|string? The body: a table, encoded here, or raw text.
  function c.respond(status, body)
    local waiting = assert(c.pending(), "no request is waiting")
    local request = c.requests[waiting.index]
    request.answered = true
    local text = body or ""
    if type(body) == "table" then
      text = assert(support.core.json.encode(support.core.json.object(body)))
    end
    ---@cast text string
    request.callback(status, text, {})
  end

  ---The names of every message sent to the server, in order.
  ---@return string[] names The names.
  function c.sent_names()
    local out = {}
    for i, message in ipairs(c.to_servers) do
      out[i] = message.name
    end
    return out
  end

  return c
end

---A portal frame, with a fresh id from a fixed source.
---@param tag string The message type.
---@param fields table? Its fields.
---@return rpf.Frame frame The frame, not yet encoded.
function support.portal_frame(tag, fields)
  support.portal_rng = support.portal_rng or support.fake_platform({ seed = 777 })
  return support.core.protocol.envelope(support.portal_rng, tag, fields)
end

---Answers the declaration of held records (`rpf.sync`) and acks the online
---list (`rpf.join`, F2) and the addon declaration (`rpf.addons`, J2) that
---follow every `Welcome`, if they are waiting, as
---a portal that agrees with them would, so a test that is not about records
---or presence starts from an empty outbox.
---@param p spec.FakePlatform The platform.
function support.declared(p)
  for i, text in ipairs(p.sent) do
    local frame = assert(support.core.protocol.decode(support.core.protocol.SERVER_TO_PORTAL, text))
    local connection = support.core.connection
    local waiting = connection and connection:find(frame.id)
    if waiting and frame.type == "declare_holds" then
      p.bookkeeping[p.sent[i]] = true
      local before = #p.sent
      p.deliver(support.portal_frame("state_applied", { re = frame.id, revisions = frame.records }))
      -- Only the ack of the answer: a hold that waited for the declaration
      -- (the paying accounts', #169) goes out with it, and is no bookkeeping.
      for j = before + 1, #p.sent do
        local sent = support.core.protocol.decode(support.core.protocol.SERVER_TO_PORTAL, p.sent[j])
        if sent and sent.type == "ack" then
          p.bookkeeping[p.sent[j]] = true
        end
      end
    elseif waiting and (frame.type == "online_players" or frame.type == "declare_addons") then
      p.bookkeeping[p.sent[i]] = true
      p.deliver(support.portal_frame("ack", { re = frame.id }))
    end
  end
end

---Starts a connection on a fake platform and completes the handshake.
---@param p spec.FakePlatform The platform.
---@param options rpf.ClientOptions? Timing overrides.
---@return rpf.Client connection The connection, ready.
function support.connected(p, options)
  local connection = rpf.start_server(p, { url = "ws://portal", api_key = "rpf_test_secret", client = options })
  p.open()
  local hello = p.last()
  p.deliver(support.portal_frame("welcome", {
    re = hello.id,
    protocol = rpf.protocol.VERSION,
    server_id = "00000001-0000-4000-8000-000000000001",
  }))
  support.declared(p)
  return connection
end

---Every frame sent, as text, except the declaration and the online list
---`support.declared` answered and the ack of its answer, so a test about the connection can
---read what it sent by position.
---@param p spec.FakePlatform The platform.
---@return string[] texts The frames, in order.
function support.wire(p)
  local out = {}
  for _, text in ipairs(p.sent) do
    if not p.bookkeeping[text] then
      out[#out + 1] = text
    end
  end
  return out
end

return support
