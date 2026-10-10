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

  -- Requests ride ox_lib's `lib.callback` (`ox.lua`).
  p.request_server = fivem.ox.request_server

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
