---The Gmod adapter's game-server side: the server platform, the refusals at
---start, and the engine hooks, each two lines: translate, and call the core.
---
---It loads the server's half of the core (`load.lua`), marks the client's
---half for download, builds the platform table from Gmod's libraries, and
---starts the core once the map has loaded and `server.cfg` has set the
---convars below (`wait_for_config`). Nothing here knows the protocol,
---the config or a retry: those are the core's, and an adapter that grew them
---would have to grow them again for the next engine.
---
---**Configuration** is three server convars, set in `server.cfg`:
---
--- - `rpf_ws_url`: the portal's websocket url, `wss://<portal>/ws`.
--- - `rpf_api_key`: the server's API key from the portal. Protected, so its
---   value is never sent to a client, and never recorded or logged by the
---   engine.
--- - `rpf_portal_url` (optional): the portal's HTTP address players log in
---   to, when it is not the websocket's host (`wss://host/ws` gives
---   `https://host`).
---
---**Refusals.** The framework needs two things Gmod does not always have, and
---says which is missing in one line instead of failing later:
---
--- - The GWSockets binary module. Gmod has no websocket, and there is no
---   fallback transport (decided in #57), so a host that cannot load binary
---   modules cannot run the framework.
--- - `sql.QueryTyped`, which binds values rather than quoting them into the
---   statement, so a stored value can be the megabyte the core's outbox needs.
---   Every current Gmod has it.
---
---A refused start loads nothing and sends players nothing: the `rpf` global
---stays nil, so another addon can tell the framework is not running, and
---players' clients, which run only what the server sends, start nothing
---either (`autorun.lua`).
---
---**Hibernation.** An empty Gmod server stops running timers and `Think`,
---which would stop the portal connection (GWSockets runs its callbacks from
---`Think`) and every retry the core has queued. The adapter sets
---`sv_hibernate_think 1` as it loads, so an empty server keeps running:
---waiting for its convars, and connected once it has them.
---@class rpf.gmod.Server
---@field MODULE string The binary module the adapter needs.
---@field INSTALL_URL string Where its install instructions are.
---@field CONFIG_POLL_S number How often, in seconds, the adapter looks for its convars until they are set.
---@field CONFIG_PATIENCE integer How many looks find them unset before the adapter says so.
---@field CONVARS table<"url"|"api_key"|"portal_url", string> The convars' names, by what each holds, for the lines that name one.
local server = {}

server.CONFIG_POLL_S = 1
server.CONFIG_PATIENCE = 10
server.CONVARS = { url = "rpf_ws_url", api_key = "rpf_api_key", portal_url = "rpf_portal_url" }

server.MODULE = "gwsockets"
server.INSTALL_URL = "https://github.com/FredyH/GWSockets#usage"

local load = include("rpf/platform/gmod/load.lua") --[[@as rpf.gmod.Load]]
local shared = include("rpf/platform/gmod/shared.lua") --[[@as rpf.gmod.Shared]]
local messages = include("rpf/platform/gmod/messages.lua") --[[@as rpf.gmod.Messages]]
local transport = include("rpf/platform/gmod/transport.lua") --[[@as rpf.gmod.Transport]]
local random = include("rpf/platform/gmod/random.lua") --[[@as rpf.gmod.Random]]
local lock = include("rpf/platform/gmod/lock.lua") --[[@as rpf.gmod.Lock]]

-- Made even on a server that refuses to start, so `server.cfg` setting them
-- does not add "Unknown command" lines beside the one line that matters.
local url_var =
  CreateConVar(server.CONVARS.url, "", { FCVAR_DONTRECORD }, "The portal's websocket url, wss://<portal>/ws.")
local key_var = CreateConVar(
  server.CONVARS.api_key,
  "",
  { FCVAR_PROTECTED, FCVAR_DONTRECORD, FCVAR_UNLOGGED },
  "This server's API key from the portal. A secret."
)
local portal_var =
  CreateConVar(server.CONVARS.portal_url, "", { FCVAR_DONTRECORD }, "The portal's HTTP address, if not the websocket's host.")

---Why the framework cannot run on this server, or nil if it can.
---@return string? reason One line naming what is missing and how to fix it.
local function refusal()
  if not util.IsBinaryModuleInstalled(server.MODULE) then
    return "rpf: the GWSockets binary module (gmsv_gwsockets) is not installed, so the framework will not start."
      .. " Gmod has no websocket of its own and the framework has no fallback."
      .. " Install it into garrysmod/lua/bin: "
      .. server.INSTALL_URL
  end
  if type(sql.QueryTyped) ~= "function" then
    return "rpf: this Garry's Mod build has no sql.QueryTyped, so the framework will not start. Update the server."
  end
  return nil
end

local refused = refusal()
if not refused then
  -- Installed is not loadable: a module built for another platform or
  -- branch (a 32-bit build on a 64-bit server, say) fails here, and Gmod's
  -- own error names no fix.
  local loaded, err = pcall(require, server.MODULE)
  if not loaded then
    refused = "rpf: the GWSockets binary module is installed but would not load ("
      .. tostring(err)
      .. "), so the framework will not start. Install the build for this server's platform and branch"
      .. " (gmsv_gwsockets_win64.dll on a 64-bit Windows server, linux64 on a 64-bit Linux one): "
      .. server.INSTALL_URL
  end
end
if refused then
  shared.log("error", refused)
  return server
end

local core = load.core("server")
load.send_client_files(core)

---The player's engine account identifier, the only identifier Gmod has: the
---SteamID64, as `steam:<SteamID64>`, which is what the portal binds remember
---tokens to (C6, P1). A player with none (singleplayer) reports nothing, and
---the portal refuses the login.
---@param player Player The player.
---@return string[] identifiers The identifiers.
local function identifiers(player)
  local id = IsValid(player) and player:SteamID64() or nil
  if type(id) ~= "string" or id == "" or id == "0" then
    return {}
  end
  return { "steam:" .. id }
end

---The networked string every entity the core places carries (J4): the
---record's id, so `server.entity` can say which record an entity is, and
---`server.sweep` recognises one a previous run left.
server.PLACEMENT = "rpf_placement"

---The model a placement names for Gmod: a string is one model's path, a
---table holds one per engine and Gmod reads its `gmod` entry.
---@param model any The record's model field.
---@return string? path The model's path, or nil.
local function gmod_model(model)
  if type(model) == "table" then
    model = model.gmod
  end
  if type(model) ~= "string" or model == "" then
    return nil
  end
  return model
end

---Places a record's ped or object (`rpf.world`'s `spawn`): a
---`prop_dynamic` with the record's model, where the record says, tagged
---with its id. A ped is a prop with a character's model, standing in its
---default animation, since Gmod's NPCs have AI of their own. Gmod has one
---world, so a record in any bucket but 0 is not placed.
---@param spec rpf.world.Spawn The placement.
---@return integer? ref The entity's index.
---@return string? err `no_model` when the record names no Gmod model, `no_bucket` for a bucket Gmod does not have, `failed` when the engine made nothing.
function server.spawn(spec)
  local model = gmod_model(spec.model)
  if not model then
    return nil, "no_model"
  end
  if spec.bucket ~= 0 then
    return nil, "no_bucket"
  end
  local entity = ents.Create("prop_dynamic")
  if not IsValid(entity) then
    return nil, "failed"
  end
  local at = spec.position
  entity:SetModel(model)
  entity:SetPos(Vector(at.x, at.y, at.z))
  entity:SetAngles(Angle(0, spec.heading, 0))
  entity:Spawn()
  entity:SetNWString(server.PLACEMENT, spec.id)
  return entity:EntIndex()
end

---Removes an entity `server.spawn` placed. One without the tag is another
---addon's, and stays.
---@param ref any Its index.
function server.despawn(ref)
  if type(ref) ~= "number" then
    return
  end
  local entity = Entity(ref)
  if IsValid(entity) and entity:GetNWString(server.PLACEMENT, "") ~= "" then
    entity:Remove()
  end
end

---An entity, by its index (`rpf.world`'s `entity`): where it is, its
---model's path, lowercased as `model` gives a name, and the record its tag
---names.
---@param ref any The index, as a client sent it.
---@return { position: { x: number, y: number, z: number }, model: string, bucket: integer, placement: string? }? entity It, or nil.
function server.entity(ref)
  if type(ref) ~= "number" then
    return nil
  end
  local entity = Entity(ref)
  if not IsValid(entity) then
    return nil
  end
  local at = entity:GetPos()
  local tag = entity:GetNWString(server.PLACEMENT, "")
  return {
    position = { x = at.x, y = at.y, z = at.z },
    model = string.lower(entity:GetModel() or ""),
    bucket = 0,
    placement = tag ~= "" and tag or nil,
  }
end

---Removes every entity a previous start placed and did not remove (a Lua
---refresh starts the adapter again on the same map), recognised by its tag,
---before the core places anything.
function server.sweep()
  for _, entity in ipairs(ents.GetAll()) do
    if IsValid(entity) and entity:GetNWString(server.PLACEMENT, "") ~= "" then
      entity:Remove()
    end
  end
end

---The game server's platform: every member of `rpf.ServerPlatform`.
---@type rpf.ServerPlatform
local platform = {
  engine = "gmod",
  connect = transport.connect,
  disconnect = transport.disconnect,
  send = transport.send,
  http_request = shared.http_request,
  now = shared.now,
  after = shared.after,
  kv_get = shared.kv_get,
  kv_set = shared.kv_set,
  random_hex = random.hex,
  thread = coroutine.running,
  -- The game world (J3, J4): Gmod has one world, so no buckets; entities
  -- are named by their index, and placed as `prop_dynamic`s
  -- (`server.spawn`).
  capabilities = {
    position = function(player)
      if not IsValid(player) then
        return nil
      end
      local at = player:GetPos()
      return { x = at.x, y = at.y, z = at.z }
    end,
    bucket = false,
    model = function(name)
      return string.lower(name)
    end,
    entity = function(ref)
      return server.entity(ref)
    end,
    spawn = function(spec)
      return server.spawn(spec)
    end,
    despawn = function(ref)
      server.despawn(ref)
    end,
    -- The UI addons show (J10), which the client builds in Derma
    -- (`addon_ui.lua`).
    notify = true,
    menu = true,
    input = true,
    progress = true,
  },
  identifiers = identifiers,
  name = function(player)
    return IsValid(player) and player:Nick() or ""
  end,
  kick = function(player, reason)
    if IsValid(player) then
      player:Kick(reason)
    end
  end,
  notify = function(player, message)
    if IsValid(player) then
      player:ChatPrint(message)
    end
  end,
  to_client = messages.to_client,
  on_client = messages.on_client,
  on_client_request = messages.on_client_request,
  request_client = messages.request_client,
  log = shared.log,
  expose = shared.expose,
}

core.publish(platform)

-- Every message name the core uses, pooled now: a client can only send a
-- name the server has pooled, and one pooled just before its first send may
-- reach a client before the name does.
for _, value in pairs(core.handoff) do
  if type(value) == "string" and value:sub(1, 4) == "rpf:" then
    messages.pool(value)
  end
end

-- A file only development builds carry (excluded from the release): console
-- commands that stand in for a client on a real server (docs/testing.md).
if file.Exists(load.ROOT .. "platform/gmod/dev.lua", "LUA") then
  include(load.ROOT .. "platform/gmod/dev.lua")(core, platform)
end

---The last thing said about the convars' values, so a wrong one is said
---once, not on every look, and said again only if it changes.
---@type string?
local said = nil

---Starts the core and wires the engine's events to it, once the url and the
---key are set and look right.
---@return boolean started False while either is unset or wrong.
local function start()
  local url, key, portal_url = url_var:GetString(), key_var:GetString(), portal_var:GetString()
  if url == "" or key == "" then
    return false
  end
  local which, reason = core.client.target_problem(url, key)
  if which then
    local line = "rpf: " .. server.CONVARS[which] .. " " .. reason .. "; the framework is not started."
    if line ~= said then
      said = line
      shared.log("error", line)
    end
    return false
  end
  server.sweep()
  core.start_server(platform, { url = url, api_key = key, portal_url = portal_url ~= "" and portal_url or nil })

  core.events.on("players.state_changed", function(player)
    lock.follow(player.handle, player.state)
  end)
  hook.Add("PlayerInitialSpawn", "rpf", function(player)
    core.players.connected(player)
  end)
  hook.Add("PlayerDisconnected", "rpf", function(player)
    core.players.dropped(player, "disconnected")
  end)
  hook.Add("PlayerSpawn", "rpf.lock", function(player)
    lock.respawned(player)
  end)
  for _, name in ipairs(lock.HOOKS) do
    hook.Add(name, "rpf.lock", lock.refuse)
  end
  hook.Add("PlayerSay", "rpf.lock", lock.silence)
  -- A map change ends this Lua state and starts another, with a new instance
  -- id. Closing now lets the portal see this one go before the next connects.
  hook.Add("ShutDown", "rpf", function()
    transport.disconnect()
  end)
  -- Anyone who joined before the convars were set (an admin setting them
  -- from the console) is handed over now; their client asks to log in again
  -- within `ready_retry_ms`.
  for _, ply in ipairs(player.GetAll()) do
    core.players.connected(ply)
  end
  return true
end

---Starts the core as soon as the convars are set. Gmod runs `server.cfg`
---after `InitPostEntity`, not before, so the first look usually finds them
---unset: this looks again every `CONFIG_POLL_S` seconds, and says once, after
---`CONFIG_PATIENCE` looks, that nothing will start until they are set. It
---keeps looking after that, so setting them from the console starts it.
---@param looks integer How many looks have found them unset.
function server.wait_for_config(looks)
  if start() then
    return
  end
  if looks == server.CONFIG_PATIENCE then
    shared.log("error", "rpf: set rpf_ws_url and rpf_api_key in server.cfg; the framework is not started.")
  end
  timer.Simple(server.CONFIG_POLL_S, function()
    server.wait_for_config(looks + 1)
  end)
end

-- Before anything waits on a timer: an empty server would otherwise never
-- run the first look for the convars.
RunConsoleCommand("sv_hibernate_think", "1")
hook.Add("InitPostEntity", "rpf", function()
  server.wait_for_config(0)
end)

return server
