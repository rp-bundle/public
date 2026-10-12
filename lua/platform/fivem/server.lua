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
  map = "rpf_map",
}

---The event a server sends to show a player a message, handled by
---`client.lua`.
server.NOTIFY = "rpf:notify"

---The map this server reports (#369): the owner's `rpf_map`, so staff can
---place records for one setup of FiveM's one map, or `default` when it is
---unset or empty. Read once, as the resource starts.
---@return string map The map's name.
function server.map()
  local map = GetConvar(server.CONVARS.map, "")
  if map == "" then
    return "default"
  end
  return map
end

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
    -- FiveM has one map, so the map is a name the owner gives a setup
    -- (#369), read as the resource starts: `default` unless set.
    map = server.map(),
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
    -- Positions are in metres.
    units_per_metre = 1,
    -- The game world (J3, J4): a player's position is their ped's, which
    -- OneSync knows on the server, and entities are placed and inspected on
    -- the server, by their network id (`server.spawn`, `server.entity`).
    capabilities = {
      heading = function(player)
        local ped = GetPlayerPed(player)
        return ped and ped ~= 0 and GetEntityHeading(ped) or nil
      end,
      position = function(player)
        local ped = GetPlayerPed(player)
        if not ped or ped == 0 then
          return nil
        end
        local at = GetEntityCoords(ped)
        return { x = at.x, y = at.y, z = at.z }
      end,
      bucket = function(player)
        return tonumber(GetPlayerRoutingBucket(tostring(player)))
      end,
      model = function(name)
        return GetHashKey(name)
      end,
      entity = function(ref)
        return server.entity(ref)
      end,
      spawn = function(spec, done)
        server.spawn(spec, done)
      end,
      despawn = function(ref)
        server.despawn(ref)
      end,
      -- Weapons (L3), given and taken on the server through OneSync's
      -- RPC natives on the player's ped (`server.give_weapon`).
      weapon = function(spec)
        return server.weapon(spec)
      end,
      give_weapon = function(player, name)
        return server.give_weapon(player, name)
      end,
      strip_weapon = function(player, name)
        server.strip_weapon(player, name)
      end,
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

  -- Verbatim and strings only, like the identifiers: the core bounds them
  -- and the portal hashes them before anything is stored (I4).
  function p.hardware_tokens(player)
    local out = {}
    for _, token in ipairs(GetPlayerTokens(tostring(player)) or {}) do
      if type(token) == "string" then
        out[#out + 1] = token
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

  -- A command a player runs (`/rpflink code` in chat, or the F8 console).
  -- `restricted` is false: FiveM otherwise wants an ace permission for the
  -- command, and these are for every player (the handler checks who they
  -- are). The `chat` resource runs a registered command without broadcasting
  -- the line, and nothing here logs the words. `source` 0 is the server
  -- console or RCON, which has no player to act for.
  local commands = {}
  function p.on_command(name, handler)
    local known = commands[name] ~= nil
    commands[name] = handler
    if known then
      return
    end
    RegisterCommand(name, function(source, args)
      local player = tonumber(source)
      if not player or player <= 0 then
        return
      end
      local words = {}
      for i, word in ipairs(args or {}) do
        words[i] = tostring(word)
      end
      commands[name](player, words)
    end, false)
  end

  -- A client's requests ride ox_lib's `lib.callback` (`ox.lua`); the
  -- server's to a client are its own numbered events (`server.ask`).
  p.on_client_request = fivem.ox.on_client_request
  p.request_client = server.ask

  return p
end

---The state bag key every entity the core places carries (J4): `{ id,
---type }`, the record it is, replicated so a target resource on a client
---can offer the right options. Only for that: the client that owns an
---entity can rewrite its state, so nothing takes it as proof of anything;
---clients learn which peds to make passive from the server
---(`shared.PLACED_PEDS`).
server.PLACEMENT = shared.PLACEMENT

---FiveM's `SetEntityOrphanMode` value that keeps an entity when the
---client that owned it leaves, rather than letting the server clean it up.
server.KEEP_ENTITY = 2

---How long, in milliseconds, between looks for an entity `CreatePed` or
---`CreateObjectNoOffset` asked for: they are RPC natives, so the handle
---they return names an entity that exists on the server only once a
---client has made it.
server.SPAWN_POLL_MS = 50

---How long a spawn waits for its entity before giving up, removing it if
---it came after all, and answering `failed`.
server.SPAWN_TIMEOUT_MS = 5000

---The model a placement names for FiveM: a string is one model's name, a
---table holds one per engine and FiveM reads its `fivem` entry. A number is
---taken as a hash already.
---@param model any The record's model field.
---@return integer? hash What `CreatePed` and `CreateObjectNoOffset` take, or nil.
local function fivem_model(model)
  if type(model) == "table" then
    model = model.fivem
  end
  if type(model) == "string" and model ~= "" then
    return GetHashKey(model)
  end
  if type(model) == "number" then
    return model
  end
  return nil
end

---Which record each entity this run placed is, by the server's handle: the
---one proof of what an entity is, with the model it was made with. An
---entry goes when the entity does (`server.removed`, on the engine's
---`entityRemoved`), whoever removed it, because FiveM recycles handles and
---network ids, and `server.mine` checks the engine still says this
---resource made the entity and with that model, so a recycled handle is
---never taken for ours.
---@type table<integer, { id: string, model: integer, ped: boolean }>
local placed_here = {}

---Whether a push of the placed peds to every client is waiting to go.
local announcing = false

---The network ids of the peds this run placed, sorted.
---@return integer[] nets The ids.
local function placed_peds()
  local out = {}
  for entity, entry in pairs(placed_here) do
    if entry.ped then
      out[#out + 1] = NetworkGetNetworkIdFromEntity(entity)
    end
  end
  table.sort(out)
  return out
end

---Sends the peds this run placed to one client, or to every client (`-1`),
---which make them passive (`client.passive`).
---@param player integer The client, or -1 for all.
function server.announce(player)
  TriggerClientEvent(shared.PLACED_PEDS, player, placed_peds())
end

---Sends every client the placed peds on the next tick, once however many
---placements changed meanwhile.
local function announce_soon()
  if announcing then
    return
  end
  announcing = true
  Citizen.SetTimeout(0, function()
    announcing = false
    server.announce(-1)
  end)
end

---When each player last asked for the placed peds, by player.
---@type table<integer, number>
local asked_at = {}

---Answers a client's request for the placed peds, as it starts: at most one
---a second per player, since any client can send it.
---@param player integer? The sender, FiveM's `source`.
function server.peds_asked(player)
  if type(player) ~= "number" then
    return
  end
  local now = GetGameTimer()
  if asked_at[player] and now - asked_at[player] < 1000 then
    return
  end
  asked_at[player] = now
  server.announce(player)
end

---Entities asked for and not there yet, by handle: removed by a stop that
---comes before they are. `removed` is set when the engine says the handle's
---entity went meanwhile: the spawn then fails, and nothing done to the
---handle afterwards could reach the entity that inherits it.
---@type table<integer, { removed: boolean }>
local creating = {}

---The entity a network id names on the server, or nil.
---@param ref any The network id.
---@return integer? entity The server's handle.
local function by_ref(ref)
  if type(ref) ~= "number" then
    return nil
  end
  local entity = NetworkGetEntityFromNetworkId(ref)
  if not entity or entity == 0 or not DoesEntityExist(entity) then
    return nil
  end
  return entity
end

---Whether the engine says this resource made an entity: what no client and
---no other script can claim, and what survives this resource restarting.
---@param entity integer The server's handle.
---@return boolean ours True if it did.
local function made_here(entity)
  return GetEntityScript(entity) == GetCurrentResourceName()
end

---Sets up an entity that now exists: frozen where the record says, in its
---routing bucket, kept when its owner leaves (`KEEP_ENTITY`), tagged for
---clients, and recorded as this run's.
---@param entity integer The server's handle.
---@param spec rpf.world.Spawn The placement.
---@param model integer The model's hash.
local function set_up(entity, spec, model)
  SetEntityHeading(entity, spec.heading)
  SetEntityRoutingBucket(entity, spec.bucket)
  FreezeEntityPosition(entity, true)
  SetEntityOrphanMode(entity, server.KEEP_ENTITY)
  Entity(entity).state:set(server.PLACEMENT, { id = spec.id, type = spec.type }, true)
  placed_here[entity] = { id = spec.id, model = model, ped = spec.kind == "ped" }
  if spec.kind == "ped" then
    announce_soon()
  end
end

---Places a record's ped or object, server-authoritative under OneSync
---(`rpf.world`'s `spawn`): created by the server as a networked entity,
---then, once it exists and has a network id, set up (`set_up`). OneSync
---streams it to the players in range of it and in its bucket, and it stays
---whether or not anyone is near. The creation natives are RPC natives, so
---this waits for the entity, every `SPAWN_POLL_MS` up to
---`SPAWN_TIMEOUT_MS`, and answers `done` then.
---@param spec rpf.world.Spawn The placement.
---@param done fun(ref: integer?, err: string?) Handed its network id, or nil and why: `no_model` when the record names no FiveM model, `failed` when the engine made nothing in time.
function server.spawn(spec, done)
  local model = fivem_model(spec.model)
  if not model then
    done(nil, "no_model")
    return
  end
  local at = spec.position
  local entity
  if spec.kind == "ped" then
    entity = CreatePed(0, model, at.x, at.y, at.z, spec.heading, true, true)
  else
    entity = CreateObjectNoOffset(model, at.x, at.y, at.z, true, true, false)
  end
  if not entity or entity == 0 then
    done(nil, "failed")
    return
  end
  local pending = { removed = false }
  creating[entity] = pending
  local waited = 0
  ---Looks for the entity, and sets it up once it is there and is still the
  ---one asked for: made by this resource, with the model asked for.
  local function look()
    if creating[entity] ~= pending then
      return -- stopped meanwhile, and removed
    end
    if pending.removed then
      creating[entity] = nil
      done(nil, "failed")
      return
    end
    local ref = DoesEntityExist(entity) and NetworkGetNetworkIdFromEntity(entity) or 0
    if ref ~= 0 then
      creating[entity] = nil
      if not made_here(entity) or GetEntityModel(entity) ~= model then
        done(nil, "failed")
        return
      end
      set_up(entity, spec, model)
      done(ref)
      return
    end
    if waited >= server.SPAWN_TIMEOUT_MS then
      -- Deleted whether or not it exists yet: should the engine make it
      -- after all, the next start's sweep takes it, as this resource's.
      creating[entity] = nil
      DeleteEntity(entity)
      done(nil, "failed")
      return
    end
    waited = waited + server.SPAWN_POLL_MS
    Citizen.SetTimeout(server.SPAWN_POLL_MS, look)
  end
  look()
end

---The record an entity is, if this run placed it and it is still that
---entity: in `placed_here`, made by this resource, with its model.
---@param entity integer The server's handle.
---@return string? id The record's id.
function server.mine(entity)
  local entry = placed_here[entity]
  if not entry then
    return nil
  end
  if not made_here(entity) or GetEntityModel(entity) ~= entry.model then
    placed_here[entity] = nil
    announce_soon()
    return nil
  end
  return entry.id
end

---Removes an entity `server.spawn` placed. Any other is another script's,
---and stays, whatever its state bag says.
---@param ref any Its network id.
function server.despawn(ref)
  local entity = by_ref(ref)
  if entity and server.mine(entity) then
    placed_here[entity] = nil
    announce_soon()
    DeleteEntity(entity)
  end
end

---Forgets an entity the engine removed, whoever removed it, so its handle
---names nothing of ours when FiveM gives it to another entity.
---@param entity any The handle, as `entityRemoved` reports it.
function server.removed(entity)
  if type(entity) == "number" then
    if placed_here[entity] then
      placed_here[entity] = nil
      announce_soon()
    end
    if creating[entity] then
      creating[entity].removed = true
    end
  end
end

---An item's weapon on FiveM (L3): the catalog's `fivem` name, and whether
---it is one of the stock weapons (`weapons.lua`). Any other name is nil,
---not false: a server can stream weapons of its own, and no server native
---says whether one exists, so it is given as named.
---@param spec rpf.ConfigItemWeapon The catalog's entry.
---@return string? name The GTA weapon's name, or nil when the item is no weapon on FiveM.
---@return boolean? known True for a stock weapon, nil for any other.
function server.weapon(spec)
  local name = spec.fivem
  if type(name) ~= "string" or name == "" then
    return nil
  end
  return name, fivem.weapons.known[name:upper()] or nil
end

---Gives a player's ped a weapon, without ammo. `GiveWeaponToPed` runs on
---the client that owns the ped, so a player with no ped yet gets nothing,
---and the core gives it again when the client says the player spawned.
---@param player any The player's server id.
---@param name string The GTA weapon's name.
---@return boolean given False with no ped to give it to.
function server.give_weapon(player, name)
  local ped = GetPlayerPed(player)
  if not ped or ped == 0 then
    return false
  end
  GiveWeaponToPed(ped, GetHashKey(name), 0, false, false)
  return true
end

---Takes a weapon from a player's ped. One it does not have is left alone,
---as the native leaves it.
---@param player any The player's server id.
---@param name string The GTA weapon's name.
function server.strip_weapon(player, name)
  local ped = GetPlayerPed(player)
  if ped and ped ~= 0 then
    RemoveWeaponFromPed(ped, GetHashKey(name))
  end
end

---A networked entity, by its network id (`rpf.world`'s `entity`): where it
---is, its model's hash, its bucket, and the record it is if this run placed
---it (`server.mine`), never from its client-writable tag.
---@param ref any The network id, as a client sent it.
---@return { position: { x: number, y: number, z: number }, model: integer, bucket: integer, placement: string? }? entity It, or nil.
function server.entity(ref)
  local entity = by_ref(ref)
  if not entity then
    return nil
  end
  local at = GetEntityCoords(entity)
  return {
    position = { x = at.x, y = at.y, z = at.z },
    model = GetEntityModel(entity),
    bucket = GetEntityRoutingBucket(entity),
    placement = server.mine(entity),
  }
end

---Removes whatever this run placed or is placing, after the core's own
---`clear`: a clean stop leaves nothing behind.
function server.clear()
  for entity in pairs(placed_here) do
    if DoesEntityExist(entity) then
      DeleteEntity(entity)
    end
  end
  -- One still being made may not exist yet; its handle is deleted anyway,
  -- and if the engine makes it after all, the next start's sweep takes it.
  for entity, pending in pairs(creating) do
    if not pending.removed then
      DeleteEntity(entity)
    end
  end
  placed_here, creating = {}, {}
end

---Removes every ped and object an earlier run of this resource made and
---did not remove: what a crash, or a stop the engine cut short, left
---behind. Run as the resource starts, before the core places anything, so
---a restart never doubles what was placed. The engine says which resource
---made each entity (`GetEntityScript`), which no client can forge and no
---other script's entity shares, and this resource makes no entity but its
---placements; a state bag tag is never read.
function server.sweep()
  for _, pool in ipairs({ GetAllPeds(), GetAllObjects() }) do
    for _, entity in ipairs(pool or {}) do
      if made_here(entity) then
        DeleteEntity(entity)
      end
    end
  end
  placed_here, creating = {}, {}
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
  asked_at[player] = nil
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
  server.sweep()
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
---shim outlive it: every change to a held record not yet reported is
---flushed into the persisted outbox first (`rpf.stop_server`), so the next
---start sends it; every socket it opened in `rpf-ws` is closed, or it would
---keep answering the portal's pings and the restarted core would be refused
---as a duplicate instance (C1), and every held player goes back to their
---own routing bucket, and every entity the core placed is removed.
---@param transport rpf.fivem.Transport The socket's transport.
function server.stop(transport)
  if server.started then
    core.stop_server()
  end
  transport.stop()
  fivem.lock.release_all()
  if server.started then
    core.world.clear()
    server.clear()
  end
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
-- An entity the engine removed, whoever removed it: its handle may be reused.
AddEventHandler("entityRemoved", function(entity) server.removed(entity) end)
-- A client asking which peds the server placed, as it starts.
RegisterNetEvent(shared.PLACED_PEDS_REQUEST, function() server.peds_asked(tonumber(source)) end)
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
