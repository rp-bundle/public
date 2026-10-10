---The game world, as far as the core reaches it (J3): through capabilities
---the adapter declares (`platform.capabilities`), never through an engine
---branch here.
---
---A capability is a function the adapter supplies, or `false` where it does
---not support it, so an addon asks `capabilities()` before it offers a
---player something that needs one, and a call to one that is missing is
---refused `unsupported` rather than failing. Positions are plain
---`{ x, y, z }` tables, which is how an addon stores one (a `vector3`
---field); a model or an entity is engine data the core passes through and
---never reads. Placing models, zones and entities are J4's (#81): every
---adapter declares them unsupported until then.
---@class rpf.world
---@field CAPABILITIES string[] Every capability an adapter declares, in order.
local world = {}

local rpf = rpf

world.CAPABILITIES = { "position", "model", "zone", "entity" }

---@type rpf.Capabilities?
local declared = nil
---@type rpf.ServerPlatform?
local platform = nil

---Reads the adapter's capabilities. One that is neither a function nor
---`false` is logged and counts as unsupported, so a typo is one line at
---start rather than a nil call later. Called by `rpf.start_server`.
---@param p rpf.ServerPlatform The platform.
function world.start(p)
  platform = p
  declared = p.capabilities
  for _, name in ipairs(world.CAPABILITIES) do
    local value = declared[name]
    if value ~= false and type(value) ~= "function" then
      p.log("warn", "rpf: the platform declares capability " .. name .. " as neither a function nor false; it is unsupported")
    end
  end
end

---A capability's function, if the adapter supports it.
---@param name string The capability.
---@return function? fn The function.
local function capability(name)
  local fn = declared and declared[name]
  if type(fn) ~= "function" then
    return nil
  end
  return fn
end

---Which capabilities this engine supports.
---@return table<string, boolean> supported By name: true where the adapter supports it.
function world.capabilities()
  local out = {}
  for _, name in ipairs(world.CAPABILITIES) do
    out[name] = capability(name) ~= nil
  end
  return out
end

---Whether a value is a finite number.
---@param n any The value.
---@return boolean finite True if it is.
local function finite(n)
  return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

---A logged-in player's position.
---@param handle any The engine's handle.
---@return { x: number, y: number, z: number }? position A plain copy.
---@return string? err `unsupported` where the adapter has no `position`, `not_found` for a player not logged in here or with no position (not spawned).
function world.position(handle)
  local fn = capability("position")
  if not fn then
    return nil, "unsupported"
  end
  local player = rpf.players.get(handle)
  if not player or not player.player_id or player.state == "dropping" then
    return nil, "not_found"
  end
  local ok, at = pcall(fn, handle)
  if not ok then
    if platform then
      platform.log("error", "rpf: the platform's position failed: " .. tostring(at))
    end
    return nil, "not_found"
  end
  if type(at) ~= "table" or not finite(at.x) or not finite(at.y) or not finite(at.z) then
    return nil, "not_found"
  end
  return { x = at.x, y = at.y, z = at.z }
end

rpf.world = world
return world
