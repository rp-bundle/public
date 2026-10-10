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
---@field started boolean? True once `server.start` has started the core, which the player events wait for.
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
    -- FiveM runs each event handler and timer in a coroutine of its own.
    thread = coroutine.running,
    -- The game world (J3): a player's position is their ped's, which
    -- OneSync knows on the server. Placing models, zones and entities are
    -- J4's.
    capabilities = {
      position = function(player)
        local ped = GetPlayerPed(player)
        if not ped or ped == 0 then
          return nil
        end
        local at = GetEntityCoords(ped)
        return { x = at.x, y = at.y, z = at.z }
      end,
      model = false,
      zone = false,
      entity = false,
      -- The UI addons show (J10), which the client builds on ox_lib.
      notify = true,
      menu = true,
      input = true,
      progress = true,
    },
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

  -- A client's requests ride ox_lib's `lib.callback` (`ox.lua`); the
  -- server's to a client are its own numbered events (`server.ask`).
  p.on_client_request = fivem.ox.on_client_request
  p.request_client = server.ask

  return p
end

---The natives the adapter calls that an old FXServer artifact may lack:
---the routing buckets that hold a player until they log in (`lock.lua`).
---Checked by name, so an artifact too old for them is told so at start
---rather than failing on a player's first join.
server.NATIVES = {
  "GetPlayerRoutingBucket",
  "SetPlayerRoutingBucket",
  "SetRoutingBucketEntityLockdownMode",
}

---Where an owner finds a current FXServer artifact.
server.ARTIFACTS_URL = "https://runtime.fivem.net/artifacts/fivem/"

---How long, in milliseconds, the server's request to a client waits for
---its answer before it is forgotten: past the longest the core waits (a
---progress bar of ten minutes and its grace), so an answer that never
---comes holds nothing for good.
server.ANSWER_TTL = 660000

---The server's requests to clients not answered yet, by number.
---@type table<integer, { player: integer, name: string, callback: fun(reply: string?) }>
local asking = {}

---How many requests the server has numbered.
local asked = 0

---Request names whose answers are listened for.
---@type table<string, true>
local answering = {}

---Ends a request, once, with its answer or with nothing.
---@param number integer The request's number.
---@param reply string? The answer.
local function settle(number, reply)
  local pending = asking[number]
  if pending then
    asking[number] = nil
    pending.callback(reply)
  end
end

---Asks a player's client something (`request_client`): a net event under
---the request's name, `<number>\n<payload>`, answered under the same
---number. Not over `lib.callback`, which keeps every request with no
---answer for good; these are forgotten when the player leaves
---(`server.forget`) or after `ANSWER_TTL`, and their callbacks told none
---will come.
---@param player integer The player.
---@param name string The request's name.
---@param payload string The request.
---@param callback fun(reply: string?) Called once, with the answer.
function server.ask(player, name, payload, callback)
  if not answering[name] then
    answering[name] = true
    RegisterNetEvent(name, function(text) server.answered(tonumber(source), name, text) end)
  end
  asked = asked + 1
  local number = asked
  asking[number] = { player = player, name = name, callback = callback }
  Citizen.SetTimeout(server.ANSWER_TTL, function()
    settle(number, nil)
  end)
  TriggerClientEvent(name, player, tostring(number) .. "\n" .. payload)
end

---Takes a client's answer: only one the server asked for, under its name,
---and only from the player it asked, so one player cannot answer for
---another. Anything else is dropped.
---@param player integer? Who sent it, FiveM's `source`.
---@param name string The request's name.
---@param text any What they sent.
function server.answered(player, name, text)
  if type(text) ~= "string" then
    return
  end
  local number, body = text:match("^(%d%d?%d?%d?%d?%d?%d?%d?%d?)\n(.*)$")
  local pending = number and asking[tonumber(number)]
  if pending and pending.player == player and pending.name == name then
    settle(tonumber(number) --[[@as integer]], body)
  end
end

---Forgets the server's requests to a player who left: they will never
---answer, and FiveM may give their id to someone else.
---@param player integer The player.
function server.forget(player)
  local numbers = {}
  for number, pending in pairs(asking) do
    if pending.player == player then
      numbers[#numbers + 1] = number
    end
  end
  for _, number in ipairs(numbers) do
    settle(number, nil)
  end
end

---Why the core must not start on this server, as the one line an owner
---reads in the console, or nil if it may. The lines are what
---`docs/installing.md`'s troubleshooting section is keyed by, so a change to
---one changes it there too.
---@param url string `rpf_url`, as set.
---@param api_key string `rpf_api_key`, as set. Never part of the answer.
---@return string? refusal What is wrong and what to do about it.
function server.refusal(url, api_key)
  if url == "" or api_key == "" then
    return "rpf: set "
      .. server.CONVARS.url
      .. " and "
      .. server.CONVARS.api_key
      .. " in server.cfg (with `set`, never `setr` or `sets`, which publish the key); not connecting"
  end
  local which, reason = core.client.target_problem(url, api_key)
  if which then
    return "rpf: " .. server.CONVARS[which] .. " " .. reason .. "; not connecting"
  end
  for _, native in ipairs(server.NATIVES) do
    if type(_G[native]) ~= "function" then
      return "rpf: this FXServer artifact has no "
        .. native
        .. ", which holding a player until they log in needs; update the server's artifact ("
        .. server.ARTIFACTS_URL
        .. "); not connecting"
    end
  end
  -- Routing buckets need OneSync `on`: under `legacy` their natives exist
  -- but do not isolate anyone.
  local onesync = GetConvar("onesync", "off")
  if onesync ~= "on" then
    return "rpf: OneSync is "
      .. onesync
      .. ", and holding a player until they log in needs its routing buckets, which only OneSync on has;"
      .. " set it on (`set onesync on` in server.cfg, or txAdmin's OneSync setting) and restart the server; not connecting"
  end
  local shim = GetResourceState("rpf-ws")
  if shim ~= "started" then
    return "rpf: the rpf-ws resource is "
      .. tostring(shim)
      .. ", and it carries the portal connection; keep both folders of the release's [rpf] folder in resources/"
      .. " and `ensure rpf-ws` before `ensure rpf`. If it is there, its own error is above; not connecting"
  end
  return fivem.ox.problem()
end

---Starts the core from the convars, then hands it every player already on
---the server, which is everyone when the resource is restarted on a live
---server. Logs one line and does nothing when it may not start
---(`server.refusal`), rather than connecting somewhere wrong or failing on
---the first join; until it starts, the engine's player events are not
---handed on, since there is no core to hand them to.
---@param platform rpf.ServerPlatform The platform from `server.platform`.
---@return boolean started False when it refused.
function server.start(platform)
  local url = GetConvar(server.CONVARS.url, "")
  local api_key = GetConvar(server.CONVARS.api_key, "")
  local refusal = server.refusal(url, api_key)
  if refusal then
    platform.log("error", refusal)
    return false
  end
  server.started = true
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
  -- A player leaving never answers what the server asked them.
  core.events.on("players.dropping", function(player)
    server.forget(player.handle)
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
-- Another resource stopping is its addons' code going: the core stops and
-- forgets every addon it registered, and takes down what its code set up
-- through the API, so nothing calls into a resource that is gone. A bridge's
-- resource stopping withdraws the bridge.
AddEventHandler("onResourceStop", function(name)
  if name == GetCurrentResourceName() then server.stop(transport) else core.unload_origin(name) end
end)
-- `playerJoining`, not `playerConnecting`: a connecting player's `source`
-- is a temporary id that changes once they join, and the core keeps the
-- handle for the whole session.
AddEventHandler("playerJoining", function() if server.started then core.players.connected(tonumber(source)) end end)
AddEventHandler("playerDropped", function(reason) if server.started then core.players.dropped(tonumber(source), reason) end end)
AddEventHandler("chatMessage", function(from) fivem.lock.silence(from) end)

return server
