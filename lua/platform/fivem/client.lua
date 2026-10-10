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

---How long, in milliseconds, between looks for a placed entity whose state
---bag arrived first.
client.PLACED_RETRY_MS = 100

---How many looks before giving up on one: five seconds' worth, past which
---it has streamed out again or never will.
client.PLACED_TRIES = 50

---Makes a ped the core placed passive on this client (J4): it neither
---dies, flees nor wanders, whichever client OneSync makes its owner. The
---server froze it and keeps it; these are the parts of a ped's behaviour
---only a client can set. A state bag change for anything else is ignored.
---
---The bag can arrive before its entity exists here, so a bag whose entity
---is not there yet is looked for again every `PLACED_RETRY_MS`, up to
---`PLACED_TRIES` times.
---@param bag string The state bag's name.
---@param value any The placement tag, `{ id, type }`.
---@param tries integer? How many looks are left; `PLACED_TRIES` on the first.
function client.placed(bag, value, tries)
  if type(value) ~= "table" then
    return
  end
  local entity = GetEntityFromStateBagName(bag)
  if not entity or entity == 0 then
    tries = tries or client.PLACED_TRIES
    if tries > 1 then
      Citizen.SetTimeout(client.PLACED_RETRY_MS, function()
        client.placed(bag, value, tries - 1)
      end)
    end
    return
  end
  if not IsEntityAPed(entity) then
    return
  end
  SetEntityInvincible(entity, true)
  SetBlockingOfNonTemporaryEvents(entity, true)
  FreezeEntityPosition(entity, true)
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

---Starts the client half of the core and its screens.
---@param platform rpf.ClientPlatform The platform from `client.platform`.
---@param screens rpf.fivem.Screens The screens.
function client.start(platform, screens)
  screens:start()
  core.start_client(platform)
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
-- A nil bag filter is every bag, which the natives' annotation does not allow for.
---@diagnostic disable-next-line: param-type-mismatch
AddStateBagChangeHandler(shared.PLACEMENT, nil, function(bag, _, value) client.placed(bag, value) end)
for _, name in ipairs(fivem.ui.CALLBACKS) do
  RegisterNUICallback(name, function(data, respond) respond(screens:nui(name, data)) end)
end
AddEventHandler("onClientResourceStart", function(name)
  if name == GetCurrentResourceName() then client.start(platform, screens) end
end)
-- Stopping the resource takes the page away but not the frozen ped, so a
-- player stopped mid-login would be left unable to move.
AddEventHandler("onClientResourceStop", function(name)
  if name == GetCurrentResourceName() then client.lock(false) end
end)

return client
