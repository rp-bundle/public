-- The Qbox bridge's FiveM entry point on the server (K3): the engine the
-- bridge reaches (`rpf_qbox.Engine`), built from FiveM's natives, and the
-- bridge registered with RPF through the `rpf` resource's export. Every
-- rule is in `bridge.lua`; this file only connects it to the game.

---The ox_inventory items that are qbx_core money, as both resources read
---them from the `inventory:accounts` convar (`["money"]` unless the owner
---set it).
---@return string[] items The item names.
local function account_items()
  local ok, items = pcall(json.decode, GetConvar("inventory:accounts", '["money"]'))
  if not ok or type(items) ~= "table" then
    return { "money" }
  end
  local out = {}
  for _, item in ipairs(items) do
    if type(item) == "string" then
      out[#out + 1] = item
    end
  end
  return out
end

---@type rpf_qbox.Engine
local engine = {
  qbx = exports.qbx_core,
  inventory = exports.ox_inventory,
  on = function(event, fn)
    AddEventHandler(event, fn)
  end,
  on_net = function(event, fn)
    RegisterNetEvent(event, function(...)
      fn(source, ...)
    end)
  end,
  callback = function(name, fn)
    lib.callback.register(name, fn)
  end,
  to_client = function(event, player, payload)
    TriggerClientEvent(event, player, payload)
  end,
  state = function(resource)
    return GetResourceState(resource)
  end,
  version = function(resource)
    local version = GetResourceMetadata(resource, "version", 0)
    if version == nil or version == "" then
      return nil
    end
    return version
  end,
  identifiers = function(player)
    local out = {}
    for _, kind in ipairs({ "license2", "license" }) do
      local identifier = GetPlayerIdentifierByType(tostring(player), kind)
      if identifier then
        out[#out + 1] = identifier
      end
    end
    return out
  end,
  account_items = account_items,
  thread = function(fn)
    CreateThread(fn)
  end,
  log = function(level, message)
    print(("[rpf-qbox] %s: %s"):format(level, message))
  end,
}

local rpf = exports.rpf:api() ---@type rpf.Api
local ok, err, field = rpf_qbox.register(rpf, engine)
if not ok then
  engine.log("error", "RPF refused the bridge: " .. tostring(err) .. (field and (" (" .. field .. ")") or ""))
end
