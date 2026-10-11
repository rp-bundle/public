---acme_shop on the game server: the addon's registration, the counter's
---menu, and the sale. Engine-neutral: everything goes through `rpf`, the
---public API, which the entry point hands in.
---
---A sale is one exchange (`rpf.commerce.exchange`): the money, the items and
---the stock move together or not at all. What the player picks travels as
---a menu option's value, which never leaves the server, so the client
---never names a listing, a price or an op id; it answers which option and
---how many, and both are checked here again.
acme_shop = acme_shop or {}

---How close to a counter a player must stand to buy, in the engine's units.
acme_shop.REACH = 4
---How often the server takes the stock staff added since: J6 (#83) will hold
---a `hold = "server"` type's records for the addon; until then it holds them.
acme_shop.HOLD_EVERY = 60000
---How long to wait before trying a sale again when the till could not be
---asked, and how many times to try in all.
acme_shop.AGAIN_MS = 1000
acme_shop.TRIES = 3

---What the player is told for each reason an exchange refuses a sale.
---@type table<string, string>
acme_shop.SAY = {
  insufficient_funds = "You cannot afford that.",
  no_space = "You have no room for that.",
  insufficient = "You do not have that many.",
  no_container = "You have nothing to carry it in.",
  no_account = "You have no account to pay from here.",
  unsupported = "The shops are shut: staff have not set the account sales are paid into.",
  stale = "The shelf changed while you chose. Try again.",
  unknown_item = "That is no longer sold here.",
  not_logged_in = "You are not in the game.",
  no_character = "You have no character in play.",
}

---Shortens text to at most `n` bytes without cutting a character in two.
---@param text string The text.
---@param n integer The most bytes.
---@return string text The text, whole characters only.
local function fit(text, n)
  if #text <= n then
    return text
  end
  local cut = n
  -- A byte from 0x80 to 0xBF continues a character: never start after one.
  while cut > 0 and (text:byte(cut + 1) or 0) >= 0x80 and (text:byte(cut + 1) or 0) < 0xC0 do
    cut = cut - 1
  end
  return text:sub(1, cut)
end

---Holds every stock record the server does not hold yet, a page at a time.
---One the portal will not hand over (deleted since the query) is tried on
---the next round; a round that fails is said in the console, and the timer
---runs the next.
---@param rpf rpf.Api The API.
---@param after table? Where the last page ended.
function acme_shop.hold_stock(rpf, after)
  local asked, refused = rpf.records.query(acme_shop.STOCK, { limit = 64, after = after }, function(found, next_page, err)
    if not found then
      print("[acme_shop] could not look for stock (" .. tostring(err) .. ")")
      return
    end
    local ids = {}
    for _, stock in ipairs(found) do
      if not stock.held then
        ids[#ids + 1] = stock.id
      end
    end
    ---Takes the next page, once this one is held.
    local function next_one()
      if next_page then
        acme_shop.hold_stock(rpf, next_page)
      end
    end
    if #ids == 0 then
      next_one()
      return
    end
    local holding, why = rpf.records.hold(acme_shop.STOCK, ids, function(_, hold_err)
      if hold_err then
        print("[acme_shop] could not take the stock (" .. tostring(hold_err) .. ")")
      else
        next_one()
      end
    end)
    if not holding then
      print("[acme_shop] could not take the stock (" .. tostring(why) .. ")")
    end
  end)
  if not asked then
    print("[acme_shop] could not look for stock (" .. tostring(refused) .. ")")
  end
end

---A listing's stock, if the server holds it.
---@param rpf rpf.Api The API.
---@param listing_id string The listing.
---@return rpf.Record? stock The stock record.
local function stock_of(rpf, listing_id)
  local found = rpf.records.list(acme_shop.STOCK, { where = { listing = listing_id } })
  return found and found[1] or nil
end

---Whether a player stands within reach of a counter.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The player.
---@param counter rpf.Record The counter.
---@return boolean near True if they do.
local function within_reach(rpf, player, counter)
  local at = rpf.world.position(player.handle)
  local spot = counter.fields.spot
  if not at or type(spot) ~= "table" then
    return false
  end
  local dx, dy, dz = at.x - spot.x, at.y - spot.y, at.z - spot.z
  return dx * dx + dy * dy + dz * dz <= acme_shop.REACH * acme_shop.REACH
end

---What a player asked for: a listing, which way, at the price they were
---shown, and how many.
---@class acme_shop.Order
---@field listing string The listing's id, from the server's own menu.
---@field selling boolean True to sell units back to the counter.
---@field price integer The unit price the player was shown.
---@field quantity any How many, as the player's client answered: checked here.

---Makes one sale or buy-back, once per op id, and says how it went. Every
---check is made again here, against the config and the stock as they are
---now, since the player chose from a menu shown a while ago.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The player.
---@param order acme_shop.Order What they asked for.
---@param op string The op id: minted once for this order, and sent again with it.
---@return boolean ok Whether it was made.
---@return string message For the player; `unavailable` when the till could not be asked, and the same op id may go again.
function acme_shop.trade(rpf, player, order, op)
  -- Still the same player on this handle: an order tried again a second
  -- later must not land on whoever an engine gave the handle to next.
  local now = rpf.players.get(player.handle)
  if not now or now.player_id ~= player.player_id then
    return false, "You are not in the game."
  end
  local n = order.quantity
  local listing = rpf.records.get(acme_shop.LISTING, order.listing)
  if not listing then
    return false, "That is no longer sold here."
  end
  if type(n) ~= "number" or n ~= math.floor(n) or n < 1 or n > listing.fields.most then
    return false, "You can trade 1 to " .. listing.fields.most .. " at a time."
  end
  local counter = rpf.records.get(acme_shop.COUNTER, listing.fields.counter)
  if not counter or counter.fields.shown == false then
    return false, "This counter is closed."
  end
  if not within_reach(rpf, player, counter) then
    return false, "You walked away from the counter."
  end
  local unit = order.selling and listing.fields.buyback or listing.fields.price
  if unit == 0 then
    return false, "This counter buys none back."
  end
  if unit ~= order.price then
    return false, "The price is now " .. unit .. ". Try again."
  end
  local slug = listing.fields.item
  if not rpf.config.item(slug) then
    -- A listing whose item staff removed from the catalog: visible in the
    -- console, and refused before anything moves.
    print("[acme_shop] listing " .. listing.id .. " sells " .. tostring(slug) .. ", which the catalog no longer has")
    return false, "That is no longer sold here."
  end
  local stock = listing.fields.stocked and stock_of(rpf, listing.id) or nil
  if listing.fields.stocked then
    if not stock then
      return false, "Sold out."
    end
    if not order.selling and stock.fields.left < n then
      return false, stock.fields.left == 0 and "Sold out." or ("Only " .. stock.fields.left .. " left.")
    end
    if order.selling and stock.fields.left + n > acme_shop.MAX_STOCK then
      return false, "The counter has no room for more."
    end
  end
  local line = { { item = slug, count = n } }
  local deal = {
    account = counter.fields.account,
    reason = counter.fields.name .. (order.selling and ": bought back " or ": sold ") .. n .. " " .. slug,
    records = { { type = acme_shop.LISTING, id = listing.id, revision = listing.revision } },
  }
  if order.selling then
    deal.paid, deal.take = unit * n, line
  else
    deal.pay, deal.give = unit * n, line
  end
  local apply = nil
  if stock then
    deal.records[2] = { type = acme_shop.STOCK, id = stock.id, revision = stock.revision }
    local left = stock.fields.left + (order.selling and n or -n)
    ---The stock the sale moves: checked above and named in the deal, so it
    ---cannot have moved on by the time this runs.
    ---@return table? record The stock now.
    apply = function()
      return rpf.records.update(acme_shop.STOCK, stock.id, { left = left }, { revision = stock.revision })
    end
  end
  local ok, status, why = rpf.commerce.exchange(player.handle, deal, op, apply)
  if ok then
    return true, (order.selling and "Sold " or "Bought ") .. n .. " for " .. unit * n .. "."
  end
  if status == "unavailable" then
    return false, "unavailable"
  end
  if status == "unknown" then
    return false, "Something went wrong at the till. Staff have been told; do not pay again."
  end
  return false, acme_shop.SAY[why] or ("The till refused it (" .. tostring(why) .. ").")
end

---Makes an order, trying again with the same op id while the till cannot be
---asked (the server's account is not held yet, after a restart), and tells
---the player how it went. The same op id is what makes trying again safe:
---it is made at most once however often it is sent.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The player.
---@param order acme_shop.Order What they asked for.
---@param op string The op id.
---@param tries integer? How many times it has been tried already.
function acme_shop.settle(rpf, player, order, op, tries)
  tries = (tries or 0) + 1
  local ok, message = acme_shop.trade(rpf, player, order, op)
  if not ok and message == "unavailable" then
    if tries < acme_shop.TRIES then
      rpf.time.after(acme_shop.AGAIN_MS, function()
        acme_shop.settle(rpf, player, order, op, tries)
      end)
      return
    end
    message = "The till is closed for now. Try again in a while."
  end
  local shown, why = rpf.ui.notify(player.handle, { title = "Shop", text = message, kind = ok and "success" or "error" })
  if not shown then
    print("[acme_shop] could not tell " .. tostring(player.player_id) .. " (" .. tostring(why) .. "): " .. message)
  end
end

---The counter's menu, then how many, then the sale: the shop interaction,
---which a player aims at a counter (J4). The rules found the counter, open
---and within reach, before this runs.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The player.
---@param target table The counter the rules resolved: `{ type, id, record, position, distance }`.
---@return boolean ok True once the menu is open.
---@return string? reason Why not, for the player.
function acme_shop.open(rpf, player, target)
  local counter = target.record
  local listings, err = rpf.records.list(acme_shop.LISTING, { where = { counter = target.id } })
  if not listings then
    print("[acme_shop] could not list " .. target.id .. "'s listings (" .. tostring(err) .. ")")
    return false, "The shop cannot open now."
  end
  local options = {}
  for _, listing in ipairs(listings) do
    local item = rpf.config.item(listing.fields.item)
    local name = fit(item and item.name or listing.fields.item, 64)
    local stock = listing.fields.stocked and stock_of(rpf, listing.id) or nil
    local left = listing.fields.stocked and (stock and stock.fields.left or 0) or nil
    options[#options + 1] = {
      label = "Buy " .. name .. " for " .. listing.fields.price .. (left and (" (" .. left .. " left)") or ""),
      disabled = left == 0 or nil,
      value = { listing = listing.id, selling = false, price = listing.fields.price, most = listing.fields.most },
    }
    if listing.fields.buyback > 0 then
      options[#options + 1] = {
        label = "Sell " .. name .. " for " .. listing.fields.buyback,
        value = { listing = listing.id, selling = true, price = listing.fields.buyback, most = listing.fields.most },
      }
    end
  end
  if #options == 0 then
    return false, "Nothing for sale here."
  end
  while #options > 32 do
    table.remove(options)
  end
  local shown, why = rpf.ui.menu(player.handle, { title = counter.fields.name, options = options }, function(choice)
    if not choice then
      return -- closed, or the player left
    end
    rpf.ui.input(player.handle, {
      title = counter.fields.name,
      fields = { { name = "quantity", label = "How many", kind = "number", min = 1, max = choice.most, default = 1, required = true } },
    }, function(values)
      if not values then
        return
      end
      -- One op id per order, minted when the player confirms it.
      local op = rpf.ops.new()
      if not op then
        rpf.ui.notify(player.handle, { title = "Shop", text = "The till is closed for now.", kind = "error" })
        return
      end
      acme_shop.settle(rpf, player, {
        listing = choice.listing,
        selling = choice.selling,
        price = choice.price,
        quantity = values.quantity,
      }, op)
    end)
  end)
  if not shown then
    return false, "The shop cannot open here (" .. tostring(why) .. ")."
  end
  return true
end

---Registers the addon. It runs once staff install it in the portal (or the
---server has `addons.auto_install` on), and everything `start` sets up is
---taken down when it stops.
---@param rpf rpf.Api The API.
---@return boolean? ok True once registered.
---@return table? refusal Why not.
function acme_shop.start_server(rpf)
  return rpf.addons.register(acme_shop.MANIFEST, {
    start = function()
      -- Aimed at a counter: the client names one, and the server checks it
      -- is a counter, open, near enough, before `open` runs. The menu
      -- (`rpf_interact`), and ox_target or qb-target on FiveM, offer it.
      assert(rpf.interactions.register("acme_shop.shop", function(player, _, target)
        return acme_shop.open(rpf, player, target)
      end, { target = acme_shop.COUNTER, label = "Shop", distance = 3 }))
      assert(rpf.time.every(acme_shop.HOLD_EVERY, function()
        acme_shop.hold_stock(rpf, nil)
      end))
      acme_shop.hold_stock(rpf, nil)
    end,
  })
end
