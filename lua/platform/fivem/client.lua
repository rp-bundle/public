---The FiveM player-client adapter (D2): the client platform table, the
---login and character screens (`ui.lua` and `nui/`), and the engine events
---wired to them.
---
---As on the server, every engine event handler at the bottom is at most two
---lines, translate and call, and everything else is a function busted runs
---against fake FiveM globals.
---@class rpf.fivem.client
local client = {}

local rpf = rpf
local core = rpf
local fivem = rpf.fivem
local shared = fivem.shared

---Locks or releases the player's input while a screen needs it: the page
---takes keyboard and mouse, and the ped is frozen where it stands.
---@param on boolean Locked or not.
function client.lock(on)
  SetNuiFocus(on, on)
  FreezeEntityPosition(PlayerPedId(), on)
end

---Shows a message from the server above the minimap.
---@param message any The text, from the server's `notify`.
function client.notify(message)
  if type(message) ~= "string" then
    return
  end
  BeginTextCommandThefeedPost("STRING")
  AddTextComponentSubstringPlayerName(message)
  EndTextCommandThefeedPostTicker(false, true)
end

---How often, in milliseconds, the client looks for the server's placed
---peds among what it has streamed in, to make each one passive.
client.PASSIVE_MS = 1000

---The network ids of the peds the server placed, as it last said
---(`shared.PLACED_PEDS`). Only the server's word counts: the state bag tag
---on an entity is written by whichever client owns it.
---@type table<integer, true>
local placed_peds = {}

---The peds made passive on this client, by handle, with the network id
---each was made passive as, so a ped streamed in again (a new handle) is
---made passive again, and none twice.
---@type table<integer, integer>
local made_passive = {}

---Takes the server's list of the peds it placed.
---@param list any The network ids, as the server sent them.
function client.placed_peds(list)
  if type(list) ~= "table" then
    return
  end
  local set = {}
  for _, net in ipairs(list) do
    if type(net) == "number" then
      set[net] = true
    end
  end
  placed_peds = set
  client.passive()
end

---Makes every placed ped this client has streamed in passive (J4): it
---neither dies, flees nor wanders, whichever client OneSync makes its
---owner. The server froze it and keeps it; these are the parts of a ped's
---behaviour only a client can set. Only a ped the server says it placed is
---touched, never one another client tagged.
function client.passive()
  local seen = {}
  for net in pairs(placed_peds) do
    if NetworkDoesEntityExistWithNetworkId(net) then
      local entity = NetworkGetEntityFromNetworkId(net)
      if entity and entity ~= 0 and IsEntityAPed(entity) then
        seen[entity] = true
        if made_passive[entity] ~= net then
          made_passive[entity] = net
          SetEntityInvincible(entity, true)
          SetBlockingOfNonTemporaryEvents(entity, true)
          FreezeEntityPosition(entity, true)
        end
      end
    end
  end
  for entity in pairs(made_passive) do
    if not seen[entity] then
      made_passive[entity] = nil
    end
  end
end

---Answers one of the server's requests (`server.ask`): `<number>\n<payload>`,
---answered once under the same number, perhaps when the player has picked.
---@param name string The request's name.
---@param text any What the server sent.
---@param handler fun(payload: string, respond: fun(reply: string)) The core's answerer.
function client.asked(name, text, handler)
  if type(text) ~= "string" then
    return
  end
  local number, body = text:match("^(%d+)\n(.*)$")
  if not number then
    return
  end
  local answered = false
  handler(body, function(reply)
    if not answered then
      answered = true
      TriggerServerEvent(name, number .. "\n" .. reply)
    end
  end)
end

---Builds the client platform (`rpf.ClientPlatform`).
---@param screens rpf.fivem.Screens The screens, which carry HTTP to the page.
---@return rpf.ClientPlatform platform The platform, complete.
function client.platform(screens)
  ---@type rpf.ClientPlatform
  local p = {
    engine = "fivem",
    now = shared.clock(GetCloudTimeAsInt, GetGameTimer),
    after = shared.after,
    kv_get = shared.kv_get,
    kv_set = shared.kv_set,
    log = shared.logger(GetConvar("rpf_debug", "false") == "true"),
    expose = shared.expose,
    -- The UI addons show is built on ox_lib (`ox.lua`).
    ui = fivem.ox.ui,
  }

  function p.http_request(method, url, headers, body, callback)
    screens:http_request(method, url, headers, body, callback)
  end

  function p.to_server(name, payload)
    TriggerServerEvent(name, payload)
  end

  -- Only the server can trigger a client's net event, but the payload is
  -- still checked to be the string the core expects.
  function p.on_server(name, handler)
    RegisterNetEvent(name, function(payload)
      if type(payload) == "string" then handler(payload) end
    end)
  end

  -- Its requests ride ox_lib's `lib.callback` (`ox.lua`); the server's
  -- are its own numbered events (`server.ask`).
  p.request_server = fivem.ox.request_server

  function p.on_server_request(name, handler)
    RegisterNetEvent(name, function(text) client.asked(name, text, handler) end)
  end

  return p
end

---The convar naming the key the minimal interaction UI is bound to by
---default (J4): replicated with `setr`, read as the client starts. A player
---can rebind it in FiveM's key settings.
client.INTERACT_KEY = "rpf_interact_key"

---Starts the client half of the core and its screens, and offers the
---server's interaction rules through a target resource whenever they come
---(`target.lua`).
---@param platform rpf.ClientPlatform The platform from `client.platform`.
---@param screens rpf.fivem.Screens The screens.
function client.start(platform, screens)
  screens:start()
  core.events.on("interactions.targets", function(rules)
    fivem.target.apply(rules)
  end)
  core.start_client(platform)
  -- The peds the server placed: asked for once, then pushed on change, and
  -- looked for every `PASSIVE_MS` as they stream in and out.
  TriggerServerEvent(shared.PLACED_PEDS_REQUEST, "")
  ---Makes placed peds passive, then waits to look again.
  local function tick()
    client.passive()
    Citizen.SetTimeout(client.PASSIVE_MS, tick)
  end
  tick()
end

rpf.fivem.client = client

local screens = fivem.ui.new({
  core = core,
  send = SendNuiMessage,
  lock = client.lock,
  log = shared.logger(true),
})
local platform = client.platform(screens)

-- The engine's events, two lines at most each.
RegisterNetEvent("rpf:notify", function(message) client.notify(message) end)
RegisterNetEvent(shared.PLACED_PEDS, function(list) client.placed_peds(list) end)
for _, name in ipairs(fivem.ui.CALLBACKS) do
  RegisterNUICallback(name, function(data, respond) respond(screens:nui(name, data)) end)
end
AddEventHandler("onClientResourceStart", function(name)
  if name == GetCurrentResourceName() then client.start(platform, screens) end
end)
-- ox_target or qb-target starting or stopping takes the options with it.
AddEventHandler("onClientResourceStart", function(name) fivem.target.started(name) end)
AddEventHandler("onClientResourceStop", function(name) fivem.target.stopped(name) end)
-- The minimal interaction UI (J4): what is near, as a menu, on a key.
RegisterCommand("rpf_interact", function() core.targets.open() end, false)
RegisterKeyMapping("rpf_interact", "Interact with what is near", "keyboard", GetConvar(client.INTERACT_KEY, "E"))
-- Deleting the account (H6) from the game, for a player who is logged in and
-- so never sees the login screen. The same form, behind a command.
RegisterCommand("rpf_delete_account", function() screens:open_delete() end, false)
-- Stopping the resource takes the page away but not the frozen ped, so a
-- player stopped mid-login would be left unable to move.
AddEventHandler("onClientResourceStop", function(name)
  if name == GetCurrentResourceName() then client.lock(false) fivem.target.clear() end
end)

return client
