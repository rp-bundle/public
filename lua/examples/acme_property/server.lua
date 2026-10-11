---acme_property on the game server: the addon's registration, buying a
---property, and its doors. Engine-neutral: everything goes through `rpf`,
---the public API, which the entry point hands in.
---
---A purchase is one exchange (`rpf.commerce.exchange`) whose `apply` writes
---the buyer onto the property the server holds, so the money and the
---ownership move together or not at all. What the player is offered travels
---as a menu option's value, which never leaves the server, so the client
---never names a property, a price or an op id: it only picks the option.
acme_property = acme_property or {}

---How close to a door a player must stand to use it, in metres. Buying needs
---no distance: the player must be on the lot, inside its radius.
acme_property.DOOR_METRES = 2

---The engine's units in a metre: positions and interaction distances are in
---them. Source (Gmod) measures in inches, near enough; FiveM in metres. The
---addon's own table, since only an addon may tell engines apart.
---@type table<string, number>
acme_property.UNITS_PER_METRE = { gmod = 39.37 }

---A distance in the engine's units.
---@param rpf rpf.Api The API.
---@param metres number The distance in metres.
---@return number units The same distance in the engine's units.
function acme_property.units(rpf, metres)
  return metres * (acme_property.UNITS_PER_METRE[rpf.engine] or 1)
end

---How long to wait before trying a purchase again when the bank could not
---be asked, and how many times to try in all.
acme_property.AGAIN_MS = 1000
acme_property.TRIES = 3

---What the buyer is told for each reason an exchange refuses a purchase.
---@type table<string, string>
acme_property.SAY = {
  insufficient_funds = "You cannot afford it.",
  no_account = "You have no account to pay from here.",
  unsupported = "Nothing can be bought now: staff have not set the account sales are paid into.",
  stale = "The property changed while you chose. Try again.",
  not_logged_in = "You are not in the game.",
  no_character = "You have no character in play.",
}

---Tells a player something, and says in the console when it cannot.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The player.
---@param text string What to tell them.
---@param kind ("info"|"success"|"error")? How it looks.
local function tell(rpf, player, text, kind)
  local shown, why = rpf.ui.notify(player.handle, { title = "Property", text = text, kind = kind })
  if not shown then
    print("[acme_property] could not tell " .. tostring(player.player_id) .. " (" .. tostring(why) .. "): " .. text)
  end
end

---Whether a player stands on a property's lot: in its routing bucket, and
---inside its radius.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The player.
---@param property rpf.Record The property.
---@return boolean on True if they do.
local function on_the_lot(rpf, player, property)
  local at = rpf.world.position(player.handle)
  local fields = property.fields
  if not at or rpf.world.bucket(player.handle) ~= (fields.bucket or 0) then
    return false
  end
  local dx, dy, dz = at.x - fields.spot.x, at.y - fields.spot.y, at.z - fields.spot.z
  return dx * dx + dy * dy + dz * dz <= fields.radius * fields.radius
end

---What a player asked to buy: a property, as they were shown it.
---@class acme_property.Order
---@field property string The property's id, from the server's own menu.
---@field revision integer The property's revision when they were shown it: a property staff or another buyer changed since is refused, never sold as it has become.
---@field price integer The price they were shown.

---What the buyer is told of a purchase's result.
---@param property_name string The property's name, as they were shown it.
---@param order acme_property.Order The order.
---@param ok boolean? Whether it was made.
---@param status string? Why not: `refused`, `unavailable` or `unknown`.
---@param why string? For `refused`, the reason.
---@return boolean ok Whether it was made.
---@return string message For the buyer; `unavailable` when the bank could not be asked.
local function answer(property_name, order, ok, status, why)
  if ok then
    return true, "You bought " .. property_name .. " for " .. order.price .. "."
  end
  if status == "unavailable" then
    return false, "unavailable"
  end
  if status == "unknown" then
    return false, "Something went wrong at the bank. Staff have been told; do not pay again."
  end
  return false, acme_property.SAY[why] or ("The bank refused it (" .. tostring(why) .. ").")
end

---Buys a property, once per op id, and says how it went. Every check is
---made again here, against the property as it is now, since the buyer chose
---from a menu shown a while ago.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The buyer.
---@param order acme_property.Order What they asked for.
---@param op string The op id: minted once for this order, and sent again with it.
---@param name string? The property's name as they were shown it, for the answer.
---@return boolean ok Whether it is theirs.
---@return string message For the buyer; `unavailable` when the bank could not be asked, and the same op id may go again.
function acme_property.purchase(rpf, player, order, op, name)
  -- Still the same player on this handle: an order tried again a second
  -- later must not land on whoever an engine gave the handle to next.
  local now = rpf.players.get(player.handle)
  if not now or now.player_id ~= player.player_id then
    return false, "You are not in the game."
  end
  -- An order sent again gets the answer it had, whatever has changed since
  -- (the property is now theirs, so no longer for sale): only a new one is
  -- checked.
  local done, recorded, reason = rpf.ops.result(op)
  if done ~= nil then
    return answer(name or "it", order, done, recorded, reason)
  end
  local property = rpf.records.get(acme_property.PROPERTY, order.property)
  if not property then
    -- Deleted, or not held here (just after a restart, before the core
    -- claims it back): either way not for sale now.
    return false, "This property cannot be bought now."
  end
  local fields = property.fields
  name = name or fields.name
  if fields.holder == player.player_id then
    return false, "You own it already."
  end
  if fields.holder then
    return false, "Someone else owns it now."
  end
  if not fields.for_sale then
    return false, "It is no longer for sale."
  end
  if fields.price ~= order.price then
    return false, "The price is now " .. fields.price .. ". Try again."
  end
  if property.revision ~= order.revision then
    return false, acme_property.SAY.stale
  end
  if not on_the_lot(rpf, player, property) then
    return false, "You walked off the lot."
  end
  local bought_at = rpf.time.now()
  ---The ownership the price pays for: the property is held here, checked
  ---above and named in the deal at the revision read, so nothing but this
  ---server can have changed it by the time this runs.
  ---@return table? record The property now.
  local function apply()
    return rpf.records.update(acme_property.PROPERTY, property.id, {
      holder = player.player_id,
      bought_at = bought_at,
      for_sale = false,
      locked = true,
    }, { revision = property.revision })
  end
  return answer(
    name,
    order,
    rpf.commerce.exchange(player.handle, {
      account = fields.account,
      pay = fields.price,
      reason = "Property: " .. fields.name,
      records = { { type = acme_property.PROPERTY, id = property.id, revision = property.revision } },
    }, op, apply)
  )
end

---Makes a purchase, trying again with the same op id while the bank cannot
---be asked (the server's account is not held yet, after a restart), and
---tells the buyer how it went. The same op id is what makes trying again
---safe: it is made at most once however often it is sent.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The buyer.
---@param order acme_property.Order What they asked for.
---@param op string The op id.
---@param name string The property's name as they were shown it.
---@param tries integer? How many times it has been tried already.
function acme_property.settle(rpf, player, order, op, name, tries)
  tries = (tries or 0) + 1
  local ok, message = acme_property.purchase(rpf, player, order, op, name)
  if not ok and message == "unavailable" then
    if tries < acme_property.TRIES then
      local timer, why = rpf.time.after(acme_property.AGAIN_MS, function()
        acme_property.settle(rpf, player, order, op, name, tries)
      end)
      if timer then
        return
      end
      -- The addon is stopping (`inactive`): the order was not made, and the
      -- player hears so rather than nothing.
      print("[acme_property] could not try " .. op .. " again (" .. tostring(why) .. ")")
    end
    message = "The bank cannot be reached now. Try again in a while."
  end
  tell(rpf, player, message, ok and "success" or "error")
end

---Offers a property to the player standing on it: the buy interaction, which
---a player aims at the lot (J4). The rules found the property, held here,
---with the player in its bucket and inside its radius, before this runs.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The player.
---@param target table The property the rules resolved: `{ type, id, record, position, distance }`.
---@return boolean ok True once the offer is open.
---@return string? reason Why not, for the player.
function acme_property.offer(rpf, player, target)
  local property = target.record
  local fields = property.fields
  if fields.holder == player.player_id then
    return false, "You own it already."
  end
  if fields.holder or not fields.for_sale then
    return false, fields.name .. " is not for sale."
  end
  local order = { property = property.id, revision = property.revision, price = fields.price }
  local shown, why = rpf.ui.menu(player.handle, {
    title = fields.name,
    options = { { label = "Buy it for " .. fields.price, description = "Paid from your " .. fields.account, value = order } },
  }, function(picked)
    if not picked then
      return -- closed, or the player left
    end
    -- One op id per order, minted when the player confirms it.
    local op, refused = rpf.ops.new()
    if not op then
      print("[acme_property] no op id for " .. tostring(player.player_id) .. " (" .. tostring(refused) .. ")")
      tell(rpf, player, "Nothing can be bought now.", "error")
      return
    end
    acme_property.settle(rpf, player, picked, op, fields.name)
  end)
  if not shown then
    return false, "Close your other window first, then try again (" .. tostring(why) .. ")."
  end
  return true
end

---Uses a door. Its property's owner locks or unlocks it, which locks or
---unlocks every door of the property; anyone else is told whether it is
---locked. The write names the revision it read, so it never applies over a
---change made since (staff assigning the property to someone else): then it
---reads the property again, checks again, and tries once more.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The player.
---@param target table The door the rules resolved: `{ type, id, record, position, distance }`.
---@return boolean ok Whether the door was used.
---@return table|string result `{ locked }` as the door is now; for a refusal, why, for the player.
function acme_property.use_door(rpf, player, target)
  local door = target.record
  local id = door.fields.property
  for _ = 1, 2 do
    local property = rpf.records.get(acme_property.PROPERTY, id)
    if not property then
      return false, "This door is stuck."
    end
    local locked = property.fields.locked
    if property.fields.holder ~= player.player_id then
      tell(rpf, player, locked and "It is locked." or "It is open.")
      return true, { locked = locked }
    end
    local now, why = rpf.records.update(acme_property.PROPERTY, id, { locked = not locked }, { revision = property.revision })
    if now then
      tell(rpf, player, now.fields.locked and "You lock the doors." or "You unlock the doors.", "success")
      return true, { locked = now.fields.locked }
    end
    if why ~= "stale" then
      return false, "The lock will not turn (" .. tostring(why) .. ")."
    end
  end
  return false, "Someone is changing it; try again."
end

---Whether a door is locked, for a server's own door script (ox_doorlock on
---FiveM, a map door on Gmod), which RPF does not move: it asks with
---`rpf.addons.call("acme_property.locked", door_id)`.
---@param rpf rpf.Api The API.
---@param door_id any The door's id, as the caller sent it.
---@return boolean? locked Whether it is locked; nil for a door that is not there, or whose property is not held here.
function acme_property.locked(rpf, door_id)
  if type(door_id) ~= "string" then
    return nil
  end
  local door = rpf.records.get(acme_property.DOOR, door_id)
  local property = door and rpf.records.get(acme_property.PROPERTY, door.fields.property)
  if not property then
    return nil
  end
  return property.fields.locked
end

---Registers the addon. It runs once staff install it in the portal, and
---everything `start` sets up is taken down when it stops. It holds nothing
---itself: the property type's `hold = "server"` has RPF hold every property,
---whoever owns it, and take them back after a restart.
---@param rpf rpf.Api The API.
---@return boolean? ok True once registered.
---@return table? refusal Why not.
function acme_property.start_server(rpf)
  return rpf.addons.register(acme_property.MANIFEST, {
    start = function()
      -- A refusal here is a bug in this file; throwing leaves the addon
      -- `failed`, with the reason in the console.
      assert(rpf.interactions.register("acme_property.buy", function(player, _, target)
        return acme_property.offer(rpf, player, target)
      end, { target = acme_property.PROPERTY, label = "Buy this property" }))
      assert(rpf.interactions.register("acme_property.door", function(player, _, target)
        return acme_property.use_door(rpf, player, target)
      end, { target = acme_property.DOOR, label = "Use the door", distance = acme_property.units(rpf, acme_property.DOOR_METRES) }))
      assert(rpf.addons.provide("acme_property.locked", function(door_id)
        return acme_property.locked(rpf, door_id)
      end))
    end,
  })
end
