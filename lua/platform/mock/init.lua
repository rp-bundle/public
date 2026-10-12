---The mock platform (D3): the whole server and client platform interfaces
---(`meta/platform_server.lua`, `meta/platform_client.lua`), for running the
---real core with no game.
---
---It is not the busted suite's fake (`spec/support`), which answers the
---socket and HTTP itself. This one is half of D3's fake game server: the Rust
---harness in `crates/fake-server/` loads it into its own Lua state, hands it a host
---table, and connects what the core does to a real socket and to the real
---portal. So the mock keeps only what has to live in Lua, because it holds
---Lua callbacks (timers, the socket's handlers, HTTP callbacks, client message
---handlers), and passes everything else to the host:
---
---- **The clock is the host's.** `now` reads it, and the host moves it, so
---  one fake clock drives the game server and every player's client, and a
---  restarted game server's clock carries on where it left off. Timers are
---  kept here and run only when the harness calls `run_due`, in time order,
---  so every backoff and retry runs instantly and in a fixed order.
---- **Storage is the host's**, so it outlives the Lua state: a restart is a
---  fresh state over the same store.
---- **Randomness is deterministic**: a MINSTD generator from a seed the host
---  chooses per start, so a run repeats exactly, and a restart (a new seed)
---  still mints a new instance id.
---- **The socket and HTTP are the host's.** It sends, and tells the mock what
---  happened (`socket_open`, `socket_message`, `socket_close`, `http_done`),
---  which is where its fault injection sits.
---- **Requests are messages.** A request and its answer (`request_server`
---  and `on_client_request`, `request_client` and `on_server_request`)
---  cross the host as two messages under the request's name, each
---  `<id>\n<body>` (`mock.frame`), which is also how the Gmod adapter and
---  the FiveM fakes' `lib.callback` frame them, so a harness plays any
---  engine's client the same way.
---- **UI is recorded.** The client's `ui` keeps what it was asked to show
---  in `shown`, and the harness answers it (`answer_ui`), as a player
---  would.
---- **Item images go through the host's HTTP,** as an engine's would: the
---  portal's redirect is followed once, without the token, the bytes are
---  checked against their hash with the host's `sha256`, and what passed is
---  kept under the hash for the client's life, so a test sees exactly which
---  fetches a client made (`P3`, `item_image`).
---
---No engine is involved, so this is not a game adapter: it does not wire
---engine events, and the harness calls `rpf.players.connected` and `dropped`
---itself. It keeps to the core's Lua 5.1/5.4 common subset, because the
---harness runs it under both.
---@class rpf.mock
local mock = {}

---Frames a request or its answer for the host: the id the asking side
---numbered it with, a newline, and the body.
---@param id integer The request's number.
---@param body string The request or answer, already encoded.
---@return string text The framed text.
function mock.frame(id, body)
  return tostring(id) .. "\n" .. body
end

---Reads a framed request or answer.
---@param text any What arrived: hostile on the server.
---@return integer? id The request's number, or nil for text that is not framed.
---@return string? body The body.
function mock.unframe(text)
  if type(text) ~= "string" then
    return nil
  end
  local id, body = text:match("^(%d%d?%d?%d?%d?%d?%d?%d?%d?)\n(.*)$")
  if not id then
    return nil
  end
  return tonumber(id), body
end

---What the harness supplies to a mock server platform. Each member is the
---host's half of the platform member it backs.
---@class rpf.mock.ServerHost
---@field now fun(): number The shared fake clock, in milliseconds since the Unix epoch.
---@field kv_get fun(key: string): string? Reads the game host's store.
---@field kv_set fun(key: string, value: string?) Writes the game host's store.
---@field http_request fun(id: integer, method: string, url: string, headers: table<string, string>, body: string?) Starts a request. The host answers it later through `http_done` with the same id.
---@field connect fun(id: integer, url: string) Opens a socket. The host reports it through `socket_open`, `socket_message` and `socket_close` with the same id.
---@field send fun(id: integer, text: string): boolean Sends a frame on that socket, or returns false if it is not open.
---@field close fun(id: integer) Closes that socket, or abandons it while it opens. The host reports the close through `socket_close`, as for any other.
---@field kick fun(player: any, reason: string) Disconnects a player, as the engine would.
---@field notify fun(player: any, message: string) Shows a player a message.
---@field to_client fun(player: any, name: string, payload: string) Carries a message to that player's client.
---@field map string? The map this process runs (#369); `default` unless given.
---@field log fun(level: string, message: string) Writes a log line.

---What the harness supplies to a mock client platform.
---@class rpf.mock.ClientHost
---@field now fun(): number The shared fake clock.
---@field kv_get fun(key: string): string? Reads the player machine's store.
---@field kv_set fun(key: string, value: string?) Writes the player machine's store.
---@field http_request fun(id: integer, method: string, url: string, headers: table<string, string>, body: string?) Starts a request, answered through `http_done`.
---@field to_server fun(name: string, payload: string) Carries a message to the game server.
---@field sha256 (fun(bytes: string): string)? SHA-256 as lowercase hex: the engine's hash, which `item_image` checks an image against. Without one, every image is refused.
---@field log fun(level: string, message: string) Writes a log line.

---Builds the members both sides share.
---@param host rpf.mock.ServerHost|rpf.mock.ClientHost The host.
---@param seed integer The random seed. Different for every start, so a restarted process mints a different instance id.
---@return rpf.mock.Common p The half-built platform.
local function common(host, seed)
  ---The timers and HTTP callbacks both sides keep in Lua, and the driving
  ---functions for them.
  ---@class rpf.mock.Common
  ---@field engine string Always `"mock"`. The portal gives it FiveM's identifier allowlist.
  ---@field timers { at: number, seq: integer, fn: fun() }[] Pending `after` callbacks.
  ---@field seq integer Orders timers due at the same moment, and numbers HTTP requests.
  ---@field rng integer The generator's state.
  ---@field http table<integer, fun(status: integer, body: string, headers: table<string, string>)> Callbacks for requests the host has not answered yet, by id.
  ---@field exposed table? What `expose` was given: the public API.
  ---@field now fun(): number Wall-clock milliseconds, from the host.
  ---@field after fun(delay_ms: number, callback: fun()) Schedules a callback.
  ---@field kv_get fun(key: string): string? Reads a stored value.
  ---@field kv_set fun(key: string, value: string?) Stores one.
  ---@field http_request fun(method: string, url: string, headers: table<string, string>, body: string?, callback: fun(status: integer, body: string, headers: table<string, string>)) Sends a request through the host.
  ---@field log fun(level: string, message: string) Logs through the host.
  ---@field expose fun(api: table) Keeps the public API for the harness's scripts.
  ---@field next_due fun(): number? When the earliest pending timer is due.
  ---@field run_due fun() Runs every timer due by the host's clock.
  ---@field http_done fun(id: integer, status: integer, body: string, headers: table<string, string>?) Answers a request, with the response's headers.
  local p = {
    engine = "mock",
    timers = {},
    seq = 0,
    -- MINSTD's state must be in [1, 2^31 - 2].
    rng = seed % 2147483646 + 1,
    http = {},
  }

  function p.now()
    return host.now()
  end

  function p.after(delay_ms, callback)
    p.seq = p.seq + 1
    p.timers[#p.timers + 1] = { at = host.now() + delay_ms, seq = p.seq, fn = callback }
  end

  function p.kv_get(key)
    return host.kv_get(key)
  end

  function p.kv_set(key, value)
    host.kv_set(key, value)
  end

  function p.http_request(method, url, headers, body, callback)
    p.seq = p.seq + 1
    p.http[p.seq] = callback
    host.http_request(p.seq, method, url, headers, body)
  end

  function p.log(level, message)
    host.log(level, message)
  end

  function p.expose(api)
    p.exposed = api
  end

  function p.next_due()
    local best
    for _, timer in ipairs(p.timers) do
      if not best or timer.at < best then
        best = timer.at
      end
    end
    return best
  end

  -- One at a time, earliest first, and re-reading the list after each,
  -- because a timer may schedule another that is already due.
  function p.run_due()
    while true do
      local now = host.now()
      local best
      for i, timer in ipairs(p.timers) do
        if timer.at <= now then
          local b = best and p.timers[best]
          if not b or timer.at < b.at or (timer.at == b.at and timer.seq < b.seq) then
            best = i
          end
        end
      end
      if not best then
        return
      end
      table.remove(p.timers, best).fn()
    end
  end

  function p.http_done(id, status, body, headers)
    local callback = p.http[id]
    if callback then
      p.http[id] = nil
      callback(status, body, headers or {})
    end
  end

  return p
end

---A mock game server platform, and the functions the harness drives it with.
---@class rpf.mock.Server: rpf.ServerPlatform, rpf.mock.Common
---@field sockets table<integer, rpf.platform.SocketHandlers> Handlers for each connection attempt, by id, until it closes.
---@field socket integer? The id of the latest connection attempt. `send` uses only this one.
---@field players table<any, { name: string, identifiers: string[] }> What the engine knows about each connected player.
---@field client_handlers table<string, fun(player: any, payload: string)> Handlers registered with `on_client`, by name.
---@field request_handlers table<string, fun(player: any, payload: string, respond: fun(reply: string))> Answerers registered with `on_client_request`, by name.
---@field command_handlers table<string, fun(player: any, args: string[])> Handlers registered with `on_command`, by name.
---@field run_command fun(player: any, name: string, args: string[]): boolean A player runs a command, as the engine would hand it over: the words after the name. False when nothing registered the name.
---@field asking table<string, table<integer, { player: any, callback: fun(reply: string?) }>> Requests sent to clients and not answered yet, by name and number.
---@field add_player fun(player: any, name: string, identifiers: string[]) Tells the mock about a player before the harness hands them to the core.
---@field remove_player fun(player: any) Forgets a player after the harness has told the core they left.
---@field positions table<any, { x: number, y: number, z: number }> Where each player is, as the harness sets it, for the `position` capability.
---@field buckets table<any, integer> Each player's routing bucket, as the harness sets it; 0 when unset.
---@field entities table<integer, rpf.mock.Entity> The world's networked entities, by ref: what the core placed, and any the harness adds.
---@field entity_seq integer The last ref handed out.
---@field socket_open fun(id: integer) The host's socket opened.
---@field socket_message fun(id: integer, text: string) A frame arrived on it.
---@field socket_close fun(id: integer, reason: string) It closed, or never opened.
---@field from_client fun(player: any, name: string, payload: string) A message arrived from a player's client.

---Builds a mock game server platform.
---@param host rpf.mock.ServerHost The harness's half.
---@param seed integer The random seed for this start.
---@return rpf.mock.Server platform The platform, complete: `rpf.platform.missing` finds nothing to refuse.
function mock.server(host, seed)
  local p = common(host, seed) --[[@as rpf.mock.Server]]
  p.sockets = {}
  p.players = {}
  p.client_handlers = {}
  p.request_handlers = {}
  p.command_handlers = {}
  p.asking = {}

  ---No coroutines here: the harness runs everything on one thread.
  ---@return nil thread Always nil.
  function p.thread()
    return nil
  end

  -- The game world (J3, J4): a player's position and bucket are whatever
  -- the harness put in `positions` and `buckets`, and the world's entities
  -- are a table it can read and change, as another script would. A model
  -- is its own name; a record's model is a name, or a table whose `mock`
  -- entry is, as each adapter reads its own engine's entry.
  p.positions = {}
  p.buckets = {}
  p.entities = {}
  p.entity_seq = 0
  -- Positions in the mock are metres, as FiveM's are.
  p.units_per_metre = 1
  -- The map the host says this process runs (#369), fixed until it stops.
  p.map = host.map or "default"

  ---A networked entity in the mock's world.
  ---@class rpf.mock.Entity
  ---@field position { x: number, y: number, z: number } Where it is.
  ---@field heading number Which way it faces.
  ---@field bucket integer Its routing bucket.
  ---@field model any Its model.
  ---@field kind string? `ped` or `object`, for one the core placed.
  ---@field placement string? The record id the core tagged it with.

  p.capabilities = {
    heading = function()
      return 0
    end,
    position = function(player)
      return p.positions[player]
    end,
    bucket = function(player)
      return p.buckets[player] or 0
    end,
    model = function(name)
      return name
    end,
    entity = function(ref)
      local found = p.entities[ref]
      if not found then
        return nil
      end
      return { position = found.position, model = found.model, bucket = found.bucket, placement = found.placement }
    end,
    spawn = function(spec, done)
      local model = spec.model
      if type(model) == "table" then
        model = model.mock
      end
      if type(model) ~= "string" or model == "" then
        done(nil, "no_model")
        return
      end
      p.entity_seq = p.entity_seq + 1
      p.entities[p.entity_seq] = {
        position = spec.position,
        heading = spec.heading,
        bucket = spec.bucket,
        model = model,
        kind = spec.kind,
        placement = spec.id,
      }
      done(p.entity_seq)
    end,
    despawn = function(ref)
      p.entities[ref] = nil
    end,
    notify = true,
    menu = true,
    input = true,
    progress = true,
  }

  -- MINSTD: every product stays below 2^53, so it is exact on LuaJIT too.
  function p.random_hex(n)
    local digits = {}
    for i = 1, n do
      p.rng = (p.rng * 48271) % 2147483647
      local d = p.rng % 16 + 1
      digits[i] = ("0123456789abcdef"):sub(d, d)
    end
    return table.concat(digits)
  end

  function p.connect(url, handlers)
    p.seq = p.seq + 1
    p.socket = p.seq
    p.sockets[p.seq] = handlers
    host.connect(p.seq, url)
  end

  -- The handlers stay in `sockets` until the host reports the close, so
  -- `close` is still called once for this connect, as the interface promises.
  function p.disconnect()
    local id = p.socket
    if id then
      p.socket = nil
      host.close(id)
    end
  end

  function p.send(text)
    if not p.socket then
      return false
    end
    return host.send(p.socket, text)
  end

  function p.identifiers(player)
    local known = p.players[player]
    local out = {}
    for i, identifier in ipairs(known and known.identifiers or {}) do
      out[i] = identifier
    end
    return out
  end

  function p.name(player)
    local known = p.players[player]
    return known and known.name or ""
  end

  function p.kick(player, reason)
    host.kick(player, reason)
  end

  function p.notify(player, message)
    host.notify(player, message)
  end

  function p.to_client(player, name, payload)
    host.to_client(player, name, payload)
  end

  function p.on_client(name, handler)
    p.client_handlers[name] = handler
  end

  function p.on_client_request(name, handler)
    p.request_handlers[name] = handler
  end

  function p.on_command(name, handler)
    p.command_handlers[name] = handler
  end

  function p.run_command(player, name, args)
    local handler = p.command_handlers[name]
    if not handler then
      return false
    end
    handler(player, args)
    return true
  end

  function p.request_client(player, name, payload, callback)
    p.seq = p.seq + 1
    p.asking[name] = p.asking[name] or {}
    p.asking[name][p.seq] = { player = player, callback = callback }
    host.to_client(player, name, mock.frame(p.seq, payload))
  end

  function p.add_player(player, name, identifiers)
    p.players[player] = { name = name, identifiers = identifiers }
  end

  function p.remove_player(player)
    p.players[player] = nil
  end

  function p.socket_open(id)
    local handlers = p.sockets[id]
    if handlers then
      handlers.open()
    end
  end

  function p.socket_message(id, text)
    local handlers = p.sockets[id]
    if handlers then
      handlers.message(text)
    end
  end

  -- `close` is called once per connect and never after it, as the interface
  -- promises, however often the host reports it.
  function p.socket_close(id, reason)
    local handlers = p.sockets[id]
    if handlers then
      p.sockets[id] = nil
      if p.socket == id then
        p.socket = nil
      end
      handlers.close(reason)
    end
  end

  -- The engine drops a message whose name nothing registered, and a
  -- request that is not framed: there is no number to answer it under.
  function p.from_client(player, name, payload)
    local handler = p.client_handlers[name]
    if handler then
      handler(player, payload)
      return
    end
    local answerer = p.request_handlers[name]
    local id, body = mock.unframe(payload)
    -- An answer to a request this server sent counts only from the player
    -- it asked.
    local asking = p.asking[name]
    local asked = id and asking and asking[id]
    if id and asking and asked then
      if asked.player == player then
        asking[id] = nil
        asked.callback(body)
      end
      return
    end
    if answerer and id then
      local answered = false
      answerer(player, body --[[@as string]], function(reply)
        if not answered then
          answered = true
          host.to_client(player, name, mock.frame(id, reply))
        end
      end)
    end
  end

  return p
end

---A mock player client platform, and the functions the harness drives it
---with.
---@class rpf.mock.Client: rpf.ClientPlatform, rpf.mock.Common
---@field server_handlers table<string, fun(payload: string)> Handlers registered with `on_server`, by name.
---@field waiting table<string, table<integer, fun(reply: string?)>> Callbacks for requests the server has not answered, by name and number.
---@field server_request_handlers table<string, fun(payload: string, respond: fun(reply: string))> Answerers registered with `on_server_request`, by name.
---@field shown { kind: string, spec: table, done: fun(raw: any), answered: boolean }[] Every UI the core asked to show, in order.
---@field closed string[] Every kind `ui.close` took away, in order.
---@field answer_ui fun(n: integer, raw: any) Answers the `n`th UI shown, as the player would: a menu option's number, the values by field number, a progress bar's `true` or `false`, or nil to close it.
---@field from_server fun(name: string, payload: string) A message arrived from the game server: a message, or the answer to a request.
---@field images table<string, true> The hashes `item_image` fetched and kept.
---@field image_fetches string[] Every URL `item_image` fetched, in order, the portal's and storage's.

---Builds a mock player client platform.
---@param host rpf.mock.ClientHost The harness's half.
---@param seed integer The random seed for this start. The client interface has no `random_hex`, so it only keeps the two sides' shapes alike.
---@return rpf.mock.Client platform The platform, complete.
function mock.client(host, seed)
  local p = common(host, seed) --[[@as rpf.mock.Client]]
  p.server_handlers = {}
  p.waiting = {}
  p.server_request_handlers = {}
  p.shown = {}
  local ui = {}
  for _, kind in ipairs({ "notify", "menu", "input", "progress" }) do
    ui[kind] = function(spec, done)
      p.shown[#p.shown + 1] = { kind = kind, spec = spec, done = done, answered = false }
    end
  end
  ---@param kind string
  ui.close = function(kind)
    p.closed[#p.closed + 1] = kind
  end
  p.closed = {}
  p.ui = ui
  p.images = {}
  p.image_fetches = {}

  ---Fetches one URL for `item_image`, recording it.
  ---@param url string The URL.
  ---@param headers table<string, string> Its headers.
  ---@param callback fun(status: integer, body: string, headers: table<string, string>) The answer.
  local function image_get(url, headers, callback)
    p.image_fetches[#p.image_fetches + 1] = url
    p.http_request("GET", url, headers, nil, callback)
  end

  function p.item_image(url, headers, hash, done)
    if p.images[hash] then
      p.after(0, function()
        done("mock:image/" .. hash)
      end)
      return
    end
    ---Takes the image's bytes, or what went wrong.
    ---@param status integer The status.
    ---@param body string The bytes.
    local function finish(status, body)
      if status == 404 then
        done(nil, "not_found")
      elseif status == 200 and host.sha256 and host.sha256(body) == hash then
        p.images[hash] = true
        done("mock:image/" .. hash)
      else
        done(nil, "unavailable")
      end
    end
    image_get(url, headers, function(status, body, response_headers)
      local location
      for name, value in pairs(response_headers or {}) do
        if type(name) == "string" and name:lower() == "location" then
          location = value
        end
      end
      if status >= 300 and status < 400 and location then
        -- The redirect is followed without the token, as the engines do.
        image_get(location, {}, function(next_status, next_body)
          finish(next_status == 404 and 410 or next_status, next_body)
        end)
        return
      end
      finish(status, body)
    end)
  end

  function p.answer_ui(n, raw)
    local shown = assert(p.shown[n], "nothing was shown as number " .. tostring(n))
    shown.answered = true
    shown.done(raw)
  end

  function p.on_server_request(name, handler)
    p.server_request_handlers[name] = handler
  end

  function p.to_server(name, payload)
    host.to_server(name, payload)
  end

  function p.on_server(name, handler)
    p.server_handlers[name] = handler
  end

  function p.request_server(name, payload, callback)
    p.seq = p.seq + 1
    p.waiting[name] = p.waiting[name] or {}
    p.waiting[name][p.seq] = callback
    host.to_server(name, mock.frame(p.seq, payload))
  end

  function p.from_server(name, payload)
    local handler = p.server_handlers[name]
    if handler then
      handler(payload)
      return
    end
    local id, body = mock.unframe(payload)
    if not id then
      return
    end
    local answerer = p.server_request_handlers[name]
    if answerer then
      local answered = false
      answerer(body --[[@as string]], function(reply)
        if not answered then
          answered = true
          host.to_server(name, mock.frame(id, reply))
        end
      end)
      return
    end
    if not p.waiting[name] then
      return
    end
    local callback = p.waiting[name][id]
    if callback then
      p.waiting[name][id] = nil
      callback(body)
    end
  end

  return p
end

return mock
