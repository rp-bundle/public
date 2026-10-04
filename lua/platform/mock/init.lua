---The mock platform (D3): the whole server and client platform interfaces
---(`meta/platform_server.lua`, `meta/platform_client.lua`), for running the
---real core with no game.
---
---It is not the busted suite's fake (`spec/support`), which answers the
---socket and HTTP itself. This one is half of D3's fake game server: the Rust
---harness in `fake-server/` loads it into its own Lua state, hands it a host
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
---
---No engine is involved, so this is not a game adapter: it does not wire
---engine events, and the harness calls `rpf.players.connected` and `dropped`
---itself. It keeps to the core's Lua 5.1/5.4 common subset, because the
---harness runs it under both.
---@class rpf.mock
local mock = {}

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
---@field log fun(level: string, message: string) Writes a log line.

---What the harness supplies to a mock client platform.
---@class rpf.mock.ClientHost
---@field now fun(): number The shared fake clock.
---@field kv_get fun(key: string): string? Reads the player machine's store.
---@field kv_set fun(key: string, value: string?) Writes the player machine's store.
---@field http_request fun(id: integer, method: string, url: string, headers: table<string, string>, body: string?) Starts a request, answered through `http_done`.
---@field to_server fun(name: string, payload: string) Carries a message to the game server.
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
---@field add_player fun(player: any, name: string, identifiers: string[]) Tells the mock about a player before the harness hands them to the core.
---@field remove_player fun(player: any) Forgets a player after the harness has told the core they left.
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

  -- The engine drops a message whose name nothing registered.
  function p.from_client(player, name, payload)
    local handler = p.client_handlers[name]
    if handler then
      handler(player, payload)
    end
  end

  return p
end

---A mock player client platform, and the functions the harness drives it
---with.
---@class rpf.mock.Client: rpf.ClientPlatform, rpf.mock.Common
---@field server_handlers table<string, fun(payload: string)> Handlers registered with `on_server`, by name.
---@field from_server fun(name: string, payload: string) A message arrived from the game server.

---Builds a mock player client platform.
---@param host rpf.mock.ClientHost The harness's half.
---@param seed integer The random seed for this start. The client interface has no `random_hex`, so it only keeps the two sides' shapes alike.
---@return rpf.mock.Client platform The platform, complete.
function mock.client(host, seed)
  local p = common(host, seed) --[[@as rpf.mock.Client]]
  p.server_handlers = {}

  function p.to_server(name, payload)
    host.to_server(name, payload)
  end

  function p.on_server(name, handler)
    p.server_handlers[name] = handler
  end

  function p.from_server(name, payload)
    local handler = p.server_handlers[name]
    if handler then
      handler(payload)
    end
  end

  return p
end

return mock
