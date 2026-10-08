---The FiveM game-server adapter (D2): the server platform table over FiveM's
---natives and the `rpf-ws` shim, and the engine events wired to the core.
---
---An adapter translates and nothing else. Every engine event handler at the
---bottom of this file is at most two lines, translate and call the core,
---which `spec/fivem_spec.lua` holds it to: anything thicker would be logic
---that cannot be tested without a game running. Everything else is a
---function in `rpf.fivem.server`, which the busted suite and the fake game
---server run against fake FiveM globals (`lua/platform/mock/fivem.lua`).
---@class rpf.fivem.server
local server = {}

local rpf = rpf
local core = rpf
local fivem = rpf.fivem
local shared = fivem.shared

---The convars the adapter reads at start. Set them with `set`, never
---`setr` or `sets`: those publish a convar to every client or to the
---server list, and the API key is a secret.
---@class rpf.fivem.Convars
server.CONVARS = {
  url = "rpf_url",
  api_key = "rpf_api_key",
  portal_url = "rpf_portal_url",
  debug = "rpf_debug",
}

---The event a server sends to show a player a message, handled by
---`client.lua`.
server.NOTIFY = "rpf:notify"

---Builds the game-server platform (`rpf.ServerPlatform`).
---@param shim rpf.fivem.WsShim `exports["rpf-ws"]`, for the socket and randomness.
---@param transport rpf.fivem.Transport The socket's three members, over the same shim.
---@return rpf.ServerPlatform platform The platform, complete.
function server.platform(shim, transport)
  local log = shared.logger(GetConvar(server.CONVARS.debug, "false") == "true")
  local warned = false

  ---@type rpf.ServerPlatform
  local p = {
    engine = "fivem",
    connect = transport.connect,
    disconnect = transport.disconnect,
    send = transport.send,
    now = shared.clock(os.time, GetGameTimer),
    after = shared.after,
    kv_get = shared.kv_get,
    kv_set = shared.kv_set,
    log = log,
    expose = shared.expose,
  }

  -- FiveM's own HTTP client. A response that is not a success carries its
  -- body in `errorData`, and one that never arrived has status 0. The
  -- callback is held to exactly once whatever the native does.
  function p.http_request(method, url, headers, body, callback)
    local done = false
    PerformHttpRequest(url, function(status, response, response_headers, error_data)
      if done then
        return
      end
      done = true
      status = tonumber(status) or 0
      local text = response
      if type(text) ~= "string" then
        text = status ~= 0 and error_data or ""
      end
      callback(status, type(text) == "string" and text or "", type(response_headers) == "table" and response_headers or {})
    end, method, body or "", headers)
  end

  -- Node's cryptographic generator, through the shim. If the shim cannot
  -- answer, Lua's generator stands in so ids are still minted, and the
  -- console says so once; nothing connects without the shim anyway.
  function p.random_hex(n)
    local ok, hex = pcall(shim.random_hex, shim, n)
    if ok and type(hex) == "string" and #hex == n then
      return hex
    end
    if not warned then
      warned = true
      log("warn", "rpf: rpf-ws could not supply random digits; using Lua's generator")
    end
    local digits = {}
    for i = 1, n do
      local d = math.random(1, 16)
      digits[i] = ("0123456789abcdef"):sub(d, d)
    end
    return table.concat(digits)
  end

  -- Verbatim and strings only: the core drops `ip:` and the portal applies
  -- the engine's allowlist (C6).
  function p.identifiers(player)
    local out = {}
    for _, identifier in ipairs(GetPlayerIdentifiers(tostring(player)) or {}) do
      if type(identifier) == "string" then
        out[#out + 1] = identifier
      end
    end
    return out
  end

  function p.name(player)
    local name = GetPlayerName(tostring(player))
    return type(name) == "string" and name or ""
  end

  function p.kick(player, reason)
    DropPlayer(tostring(player), reason)
  end

  function p.notify(player, message)
    TriggerClientEvent(server.NOTIFY, player, message)
  end

  function p.to_client(player, name, payload)
    TriggerClientEvent(name, player, payload)
  end

  -- `RegisterNetEvent` is what lets a client trigger the name at all. The
  -- sender is FiveM's `source`, never anything the client says, and a
  -- payload that is not a string is dropped here: msgpack would hand over
  -- whatever the client chose.
  function p.on_client(name, handler)
    RegisterNetEvent(name, function(payload)
      if type(payload) == "string" then handler(tonumber(source), payload) end
    end)
  end

  return p
end

---Starts the core from the convars, then hands it every player already on
---the server, which is everyone when the resource is restarted on a live
---server. Logs and does nothing when a convar is missing, rather than
---connecting somewhere wrong.
---@param platform rpf.ServerPlatform The platform from `server.platform`.
---@return boolean started False when the convars are not set.
function server.start(platform)
  local url = GetConvar(server.CONVARS.url, "")
  local api_key = GetConvar(server.CONVARS.api_key, "")
  if url == "" or api_key == "" then
    platform.log(
      "error",
      "rpf: set "
        .. server.CONVARS.url
        .. " and "
        .. server.CONVARS.api_key
        .. " in server.cfg (with `set`, never `setr` or `sets`, which publish the key); not connecting"
    )
    return false
  end
  local portal_url = GetConvar(server.CONVARS.portal_url, "")
  core.start_server(platform, {
    url = url,
    api_key = api_key,
    portal_url = portal_url ~= "" and portal_url or nil,
  })
  -- The lock follows the core's lifecycle (`lock.lua`), from the first move.
  core.events.on("players.state_changed", function(player)
    fivem.lock.follow(player.handle, player.state)
  end)
  for _, id in ipairs(GetPlayers() or {}) do
    core.players.connected(tonumber(id))
  end
  return true
end

---Stops cleanly, because this resource is stopping and the engine and the
---shim outlive it: every socket it opened in `rpf-ws` is closed, or it would
---keep answering the portal's pings and the restarted core would be refused
---as a duplicate instance (C1), and every held player goes back to their
---own routing bucket.
---@param transport rpf.fivem.Transport The socket's transport.
function server.stop(transport)
  transport.stop()
  fivem.lock.release_all()
end

rpf.fivem.server = server

local shim = exports["rpf-ws"] --[[@as rpf.fivem.WsShim]]
local transport = fivem.ws.new(shim, shared.after, shared.logger(true))
local platform = server.platform(shim, transport)

-- The engine's events. Each handler translates and calls the core: two
-- lines at most. `source` is FiveM's, set for the duration of the event.
AddEventHandler("rpf-ws:open", function(id) transport.opened(id) end)
AddEventHandler("rpf-ws:message", function(id, text) transport.received(id, text) end)
AddEventHandler("rpf-ws:close", function(id, code, reason) transport.closed(id, code, reason) end)
AddEventHandler("onResourceStart", function(name)
  if name == GetCurrentResourceName() then server.start(platform) end
end)
AddEventHandler("onResourceStop", function(name)
  if name == GetCurrentResourceName() then server.stop(transport) end
end)
-- `playerJoining`, not `playerConnecting`: a connecting player's `source`
-- is a temporary id that changes once they join, and the core keeps the
-- handle for the whole session.
AddEventHandler("playerJoining", function() core.players.connected(tonumber(source)) end)
AddEventHandler("playerDropped", function(reason) core.players.dropped(tonumber(source), reason) end)
AddEventHandler("chatMessage", function(from) fivem.lock.silence(from) end)

return server
