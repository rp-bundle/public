-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Conformance (J5): the commerce example, `lua/examples/acme_shop/`, run as
-- it ships on the mock platform and on the real FiveM and Gmod adapters,
-- against a fake portal (`spec/support/conformance.lua`). Staff's counter,
-- listings and stock are its own types; a player aims the shop at the
-- counter, picks from the menu the server opens and says how many, and one
-- exchange moves the money, the items and the stock together. The cases are
-- the issue's: a purchase, too little money or room, the bought units being
-- ordinary items, a buy-back, a price changed in config, a deleted item or a
-- closed counter, a retry with the same op id, the portal going away and
-- coming back, and a restart in the middle of a sale.

local conformance = require("spec.support.conformance")
local support = require("spec.support")

---What `conformance.run` needs from busted.
local busted = { describe = describe, it = it, before_each = before_each, after_each = after_each }

local SERVER = "00000001-0000-4000-8000-000000000001"
local PLAYER = "00000002-0000-4000-8000-000000000002"
local JANE = "00000004-0000-4000-8000-000000000004"
local WALLET = "00000005-0000-4000-8000-000000000005"
local TILL = "00000007-0000-4000-8000-000000000007"
local BAG = "00000008-0000-4000-8000-000000000008"
local COUNTER = "00000010-0000-4000-8000-000000000010"
local WATER = "00000011-0000-4000-8000-000000000011"
local BREAD = "00000012-0000-4000-8000-000000000012"
local DEAR = "00000013-0000-4000-8000-000000000013"
local GONE = "00000014-0000-4000-8000-000000000014"
local STOCK = "00000020-0000-4000-8000-000000000020"
local SPOT = { x = 10, y = 20, z = 30 }

---Loads the example's server half as an engine entry point does, and
---starts it on the world's API.
---@param world spec.ConformanceWorld The world.
---@return acme_shop shop The example's table.
local function load_example(world)
  rawset(_G, "acme_shop", nil)
  dofile(support.path("lua/examples/acme_shop/manifest.lua"))
  dofile(support.path("lua/examples/acme_shop/server.lua"))
  local shop = rawget(_G, "acme_shop")
  assert(shop.start_server(world.api))
  return shop
end

---The portal's copies of Jane, her wallet and her bag, the server's till,
---and the water listing's stock.
---@param world spec.ConformanceWorld The world.
---@param room integer? The bag's weight limit; none when nil.
local function seed(world, room)
  local json = world.core.json
  local owned = world.portal.owned
  local jane = { kind = "character", id = JANE }
  owned[JANE] = {
    kind = "character",
    revision = 1,
    data = {
      id = JANE,
      server_id = SERVER,
      owner = { kind = "player", id = PLAYER },
      first_name = "Jane",
      last_name = "Doe",
      gender = "female",
    },
  }
  owned[WALLET] = {
    kind = "account",
    revision = 1,
    balance = 100,
    data = { id = WALLET, server_id = SERVER, owner = jane, name = "wallet", flags = json.array({}) },
  }
  owned[TILL] = {
    kind = "account",
    revision = 1,
    balance = 0,
    data = {
      id = TILL,
      server_id = SERVER,
      owner = { kind = "server", id = SERVER },
      name = "till",
      flags = json.array({ "unlimited_balance" }),
    },
  }
  owned[BAG] = {
    kind = "container",
    revision = 1,
    data = {
      id = BAG,
      server_id = SERVER,
      owner = jane,
      name = "Bag",
      contents = json.object({ layout = "list", stacks = json.array({ { item = "water", count = 3 } }) }),
      flags = json.array(room and { json.object({ flag = "max_weight", value = room }) } or {}),
    },
  }
  world.portal.records[STOCK] = {
    id = STOCK,
    type = "acme_shop.stock",
    owner = { kind = "server", id = SERVER },
    revision = 1,
    fields = { listing = WATER, left = 5 },
    held = false,
  }
end

---What staff set up: the counter, its listings, the catalog and the till.
---@class spec.ShopSetup
---@field price integer? The water's price; 5 unless given.
---@field shown boolean? Whether the counter is open; true unless given.
---@field revision integer? The records' revision; 1 unless given.
---@field water_item string? What the water listing sells; `water` unless given.

---The installed addon with staff's records, and the snapshot's sections.
---@param world spec.ConformanceWorld The world.
---@param shop acme_shop The example.
---@param setup spec.ShopSetup? What differs.
---@return table installed The installation.
---@return table extra The snapshot's sections.
local function config(world, shop, setup)
  setup = setup or {}
  local json = world.core.json
  local revision = setup.revision or 1
  local installed = conformance.installed(world.core, shop.MANIFEST)
  ---A config record of the addon's.
  ---@param id string Its id.
  ---@param kind string Its type's short name.
  ---@param fields table Its fields.
  ---@return table record The record.
  local function record(id, kind, fields)
    return { id = id, type = "acme_shop." .. kind, revision = revision, fields = json.object(fields) }
  end
  installed.records = json.array({
    record(COUNTER, "counter", {
      name = "Corner shop",
      spot = json.object(SPOT),
      model = json.object({ fivem = "mp_m_shopkeep_01", gmod = "models/humans/group01/male_02.mdl", mock = "mock_shopkeeper" }),
      shown = setup.shown ~= false,
    }),
    record(WATER, "listing", {
      counter = COUNTER,
      item = setup.water_item or "water",
      price = setup.price or 5,
      buyback = 2,
      stocked = true,
    }),
    record(BREAD, "listing", { counter = COUNTER, item = "bread", price = 3 }),
    record(DEAR, "listing", { counter = COUNTER, item = "bread", price = 500 }),
    record(GONE, "listing", { counter = COUNTER, item = "unobtainium", price = 1 }),
  })
  local size = json.object({ x = 1, y = 1 })
  return installed,
    {
      settings = json.object({ ["economy.addon_account"] = "till" }),
      paying_accounts = json.array({ { id = TILL, name = "till" } }),
      new_character = json.object({ accounts = json.array({ { name = "wallet", amount = 0 } }) }),
      items = json.array({
        json.object({ slug = "water", name = "Water", weight = 1, size = size, stack_limit = 10 }),
        json.object({ slug = "bread", name = "Bread", weight = 1, size = size, stack_limit = 10 }),
      }),
      item_defaults = json.object({ weight = 1, size = size, stack_limit = 10 }),
    }
end

---Installs staff's setup, as the portal pushes a config.
---@param world spec.ConformanceWorld The world.
---@param shop acme_shop The example.
---@param setup spec.ShopSetup? What differs.
local function install(world, shop, setup)
  local installed, extra = config(world, shop, setup)
  world:install({ installed }, extra)
  world:pump()
  -- Placing is the engine's, which may take a tick (FiveM's).
  world:advance(100)
end

---A world with the shop running and Jane in play at its counter.
---@param world spec.ConformanceWorld The world.
---@param room integer? As for `seed`.
---@return acme_shop shop The example.
---@return any handle Jane's engine handle.
local function at_the_counter(world, room)
  seed(world, room)
  local shop = load_example(world)
  world:connect()
  install(world, shop)
  assert.are.equal("active", (world.api.addons.state("acme_shop")))
  local handle = world:login(1, PLAYER)
  world:select(handle, JANE)
  world.place(1, { x = SPOT.x, y = SPOT.y + 1, z = SPOT.z })
  return shop, handle
end

---How many requests the harness's clients have numbered.
local numbered = 0

---Sends the shop interaction from Jane's client, aimed at the counter, as
---the client core frames it, and gives the server's answer.
---@param world spec.ConformanceWorld The world.
---@return table? answer The decoded answer.
local function aim(world)
  local json = world.core.json
  local before = #world.to_clients
  numbered = numbered + 1
  local body = json.encode(json.object({ name = "acme_shop.shop", payload = json.object({ target = json.object({ id = COUNTER }) }) }))
  world.from_client(1, "rpf:interact", numbered .. "\n" .. assert(body))
  for i = before + 1, #world.to_clients do
    local sent = world.to_clients[i]
    if sent.name == "rpf:interact" then
      return json.decode((sent.payload:match("^%d+\n(.*)$")))
    end
  end
  return nil
end

---The last UI request the server sent Jane's client: its number and what
---it asked.
---@param world spec.ConformanceWorld The world.
---@return string number Its number.
---@return table request The request.
local function asked(world)
  for i = #world.to_clients, 1, -1 do
    local sent = world.to_clients[i]
    if sent.name == "rpf:ui" then
      local number, body = sent.payload:match("^(%d+)\n(.*)$")
      return number, assert(world.core.json.decode(body))
    end
  end
  error("Jane was asked nothing")
end

---Jane's client answers a UI request.
---@param world spec.ConformanceWorld The world.
---@param number string The request's number.
---@param fields table The answer.
local function answer(world, number, fields)
  local json = world.core.json
  world.from_client(1, "rpf:ui", number .. "\n" .. assert(json.encode(json.object(fields))))
end

---The last notification Jane was shown.
---@param world spec.ConformanceWorld The world.
---@return string? text Its text.
local function told(world)
  for i = #world.to_clients, 1, -1 do
    local sent = world.to_clients[i]
    if sent.name == "rpf:ui_notify" then
      -- The notification's spec, as the platform carries it: whole, or
      -- under `spec`.
      local notice = world.core.json.decode(sent.payload)
      return notice.text or (notice.spec and notice.spec.text)
    end
  end
  return nil
end

---Opens the counter's menu and picks the option whose label starts so.
---@param world spec.ConformanceWorld The world.
---@param label string The start of the option's label.
---@return table options The options as Jane's client was shown them.
local function pick(world, label)
  local opened = assert(aim(world))
  assert.is_true(opened.ok, tostring(opened.reason))
  local number, request = asked(world)
  assert.are.equal("menu", request.kind)
  for i, option in ipairs(request.spec.options) do
    if option.label:sub(1, #label) == label then
      answer(world, number, { ok = true, index = i })
      return request.spec.options
    end
  end
  error("no option " .. label)
end

---Says how many in the quantity dialog.
---@param world spec.ConformanceWorld The world.
---@param quantity number How many.
local function how_many(world, quantity)
  local number, request = asked(world)
  assert.are.equal("input", request.kind)
  answer(world, number, { ok = true, values = world.core.json.array({ quantity }) })
end

---What Jane and the shop hold now.
---@param world spec.ConformanceWorld The world.
---@param handle any Jane's handle.
---@return table holdings `{ wallet, till, water, bread, left }`.
local function holdings(world, handle)
  local api = world.api
  local stock = api.records.get("acme_shop.stock", STOCK)
  return {
    wallet = api.money.balance(handle, "wallet"),
    till = world.core.accounts.balance(TILL),
    water = api.inventory.count(handle, "water"),
    bread = api.inventory.count(handle, "bread"),
    left = stock and stock.fields.left,
  }
end

---The ledger entries the portal was sent with a description.
---@param world spec.ConformanceWorld The world.
---@param description string The description.
---@return table[] entries The entries.
local function reported(world, description)
  local out = {}
  for _, frame in ipairs(world.portal.frames) do
    for _, change in ipairs(frame.changes or frame.records or {}) do
      for _, tx in ipairs(type(change) == "table" and change.transactions or {}) do
        if tx.description == description then
          out[#out + 1] = tx
        end
      end
    end
  end
  return out
end

---Runs a function with `print` captured, as the console a server owner
---reads.
---@param fn fun() The function.
---@return string[] lines What was printed.
local function console(fn)
  local lines = {}
  local print_was = rawget(_G, "print")
  rawset(_G, "print", function(...)
    local parts = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring((select(i, ...)))
    end
    lines[#lines + 1] = table.concat(parts, "\t")
  end)
  local ok, err = pcall(fn)
  rawset(_G, "print", print_was)
  assert(ok, err)
  return lines
end

conformance.run(busted, "the acme_shop example", {
  {
    name = "sells through the counter's menu: one exchange moves the money, the water and the stock",
    run = function(world)
      local _, handle = at_the_counter(world)
      local options = pick(world, "Buy Water")
      assert.are.equal("Buy Water for 5 (5 left)", options[1].label)
      for _, option in ipairs(options) do
        assert.is_nil(option.value, "a value never leaves the server")
      end
      how_many(world, 2)
      assert.are.equal("Bought 2 for 10.", told(world))
      assert.are.same({ wallet = 90, till = 10, water = 5, bread = 0, left = 3 }, holdings(world, handle))
      world:settle()
      world:settle()
      assert.are.equal(3, world.portal.records[STOCK].fields.left, "the portal has the stock")
      local entries = reported(world, "Corner shop: sold 2 water")
      assert.are.equal(1, #entries, "and one ledger entry, on the statement staff read")
      assert.are.same({ WALLET, TILL, 10 }, { entries[1].from_account, entries[1].to_account, entries[1].amount })
      -- What was bought is an ordinary item: another addon uses it up
      -- through the facade like any other.
      assert.is_true(world.api.inventory.take(handle, "water", 1, world.api.ops.new()))
      assert.are.equal(4, world.api.inventory.count(handle, "water"))
    end,
  },
  {
    name = "refuses too little money, too little room, more than is left or a quantity no menu offers, moving nothing",
    run = function(world)
      local shop, handle = at_the_counter(world, 5)
      local jane = assert(world.api.players.get(handle))
      local before = holdings(world, handle)
      local cases = {
        { { listing = DEAR, revision = 1, price = 500, quantity = 1 }, "You cannot afford that." },
        { { listing = BREAD, revision = 1, price = 3, quantity = 3 }, "You have no room for that." },
        { { listing = WATER, revision = 1, price = 5, quantity = 6 }, "Only 5 left." },
        { { listing = BREAD, revision = 1, price = 3, quantity = 1.5 }, "You can trade 1 to 10 at a time." },
        { { listing = BREAD, revision = 1, price = 3, quantity = 11 }, "You can trade 1 to 10 at a time." },
        { { listing = "00000099-0000-4000-8000-000000000099", revision = 1, price = 3, quantity = 1 }, "That is no longer sold here." },
      }
      for i, case in ipairs(cases) do
        local order = case[1]
        order.selling = false
        local ok, message = shop.trade(world.api, jane, order, world.api.ops.new())
        assert.are.same({ false, case[2] }, { ok, message }, tostring(i))
      end
      -- An order kept for a player who has gone lands on nobody else.
      local stranger = { handle = jane.handle, player_id = "00000003-0000-4000-8000-000000000003" }
      assert.are.same(
        { false, "You are not in the game." },
        { shop.trade(world.api, stranger, { listing = BREAD, revision = 1, price = 3, quantity = 1, selling = false }, world.api.ops.new()) }
      )
      assert.are.same(before, holdings(world, handle), "nothing moved")
      assert.are.same({}, world.api.ops.unknown())
    end,
  },
  {
    name = "refuses a price staff changed while the menu was open, charging nothing",
    run = function(world)
      local shop, handle = at_the_counter(world)
      pick(world, "Buy Water")
      install(world, shop, { price = 7, revision = 2 })
      how_many(world, 1)
      assert.are.equal("The price is now 7. Try again.", told(world))
      assert.are.same({ wallet = 100, till = 0, water = 3, bread = 0, left = 5 }, holdings(world, handle))
      pick(world, "Buy Water")
      how_many(world, 1)
      assert.are.equal("Bought 1 for 7.", told(world))
    end,
  },
  {
    name = "refuses an order for a listing staff changed while the dialog was open, though its price did not",
    run = function(world)
      local shop, handle = at_the_counter(world)
      pick(world, "Buy Water")
      install(world, shop, { water_item = "bread", revision = 2 })
      how_many(world, 1)
      assert.are.equal("The shelf changed while you chose. Try again.", told(world))
      assert.are.same({ wallet = 100, till = 0, water = 3, bread = 0, left = 5 }, holdings(world, handle), "no bread for water")
    end,
  },
  {
    name = "buys back: pays the player and puts the units back on the shelf",
    run = function(world)
      local _, handle = at_the_counter(world)
      pick(world, "Sell Water")
      how_many(world, 2)
      assert.are.equal("Sold 2 for 4.", told(world))
      assert.are.same({ wallet = 104, till = -4, water = 1, bread = 0, left = 7 }, holdings(world, handle))
    end,
  },
  {
    name = "refuses an item that left the catalog, visibly, and a counter staff closed",
    run = function(world)
      local shop, handle = at_the_counter(world)
      local jane = assert(world.api.players.get(handle))
      local results
      local lines = console(function()
        results = { shop.trade(world.api, jane, { listing = GONE, revision = 1, price = 1, quantity = 1, selling = false }, world.api.ops.new()) }
      end)
      assert.are.same({ false, "That is no longer sold here." }, results)
      assert.are.equal(1, #lines)
      assert.truthy(lines[1]:find("which the catalog no longer has", 1, true), lines[1])
      assert.are.equal(1, #world.entities(), "the shopkeeper stands at the counter")
      install(world, shop, { shown = false, revision = 2 })
      assert.are.equal(0, #world.entities(), "and is gone once it closes")
      assert.are.same(
        { false, "This counter is closed." },
        { shop.trade(world.api, jane, { listing = BREAD, revision = 1, price = 3, quantity = 1, selling = false }, world.api.ops.new()) }
      )
      assert.are.same({ wallet = 100, till = 0, water = 3, bread = 0, left = 5 }, holdings(world, handle))
    end,
  },
  {
    name = "is made once however often the same order is sent, and answers it as it was whatever changed since",
    run = function(world)
      local shop, handle = at_the_counter(world)
      local api = world.api
      local jane = assert(api.players.get(handle))
      local order = { listing = WATER, revision = 1, price = 5, quantity = 2, selling = false }
      local op = api.ops.new()
      assert.are.same({ true, "Bought 2 for 10." }, { shop.trade(api, jane, order, op) })
      assert.are.same({ true, "Bought 2 for 10." }, { shop.trade(api, jane, order, op) }, "the same op id answers as before")
      assert.are.same({ wallet = 90, till = 10, water = 5, bread = 0, left = 3 }, holdings(world, handle), "and moves once")
      -- The last three sell, and staff close the counter: the first order,
      -- sent again, is still the sale it was, not "sold out" or "closed".
      assert.are.same(
        { true, "Bought 3 for 15." },
        { shop.trade(api, jane, { listing = WATER, revision = 1, price = 5, quantity = 3, selling = false }, api.ops.new()) }
      )
      install(world, shop, { shown = false, revision = 2 })
      assert.are.same({ true, "Bought 2 for 10." }, { shop.trade(api, jane, order, op) }, "neither sold out nor closed")
      assert.are.same({ wallet = 75, till = 25, water = 8, bread = 0, left = 0 }, holdings(world, handle), "and nothing moved")
    end,
  },
  {
    name = "waits for a till it cannot reach yet, and sends the order again under the same op id",
    run = function(world)
      local shop, handle = at_the_counter(world)
      local api = world.api
      local jane = assert(api.players.get(handle))
      -- The till is not held (as after a restart, before its hold lands).
      world.core.records.forget({ { kind = "account", id = TILL } })
      shop.settle(api, jane, { listing = WATER, revision = 1, price = 5, quantity = 2, selling = false }, api.ops.new())
      assert.are.equal(100, api.money.balance(handle, "wallet"), "nothing yet")
      world.core.accounts.hold_paying()
      world:pump()
      world:advance(1000)
      assert.are.equal("Bought 2 for 10.", told(world))
      assert.are.same({ wallet = 90, till = 10, water = 5, bread = 0, left = 3 }, holdings(world, handle))
    end,
  },
  {
    name = "keeps selling while the portal is away, and reports every sale when it is back",
    run = function(world)
      local _, handle = at_the_counter(world)
      world:settle()
      world:disconnect()
      pick(world, "Buy Water")
      how_many(world, 1)
      assert.are.equal("Bought 1 for 5.", told(world))
      assert.are.same({ wallet = 95, till = 5, water = 4, bread = 0, left = 4 }, holdings(world, handle))
      assert.are.same({}, reported(world, "Corner shop: sold 1 water"), "nothing reaches a portal that is away")
      local asked_for = #world.connects
      for _ = 1, 120 do
        if #world.connects > asked_for then
          break
        end
        world:advance(1000)
      end
      assert.is_true(#world.connects > asked_for, "the core connects again")
      world:connect()
      world:settle()
      world:settle()
      assert.are.equal(1, #reported(world, "Corner shop: sold 1 water"))
      assert.are.equal(4, world.portal.records[STOCK].fields.left)
    end,
  },
  {
    name = "reads a sale a restart cut off as unknown, for staff, and never makes it again",
    run = function(world)
      local shop, handle = at_the_counter(world)
      local api = world.api
      local jane = assert(api.players.get(handle))
      local order = { listing = BREAD, revision = 1, price = 3, quantity = 2, selling = false }
      local op = api.ops.new()
      -- Made in memory, not yet in the outbox: the server dies here.
      world.core.connection.options.max_entries = 0
      assert.are.same({ true, "Bought 2 for 6." }, { shop.trade(api, jane, order, op) })
      world:restart(world:snapshot())
      -- The portal's copies again, as the new process's codec marks them:
      -- none of the sale reached the portal.
      seed(world)
      shop = load_example(world)
      world:connect()
      install(world, shop)
      api = world.api
      local listed = api.ops.unknown()
      assert.are.equal(1, #listed)
      assert.are.same(
        { op, "Corner shop: sold 2 bread", "bread:2", 6 },
        { listed[1].op_id, listed[1].detail.reason, listed[1].detail.give, listed[1].detail.amount }
      )
      handle = world:login(1, PLAYER)
      world:select(handle, JANE)
      world.place(1, { x = SPOT.x, y = SPOT.y + 1, z = SPOT.z })
      jane = assert(api.players.get(handle))
      assert.are.same(
        { false, "Something went wrong at the till. Staff have been told; do not pay again." },
        { shop.trade(api, jane, order, op) }
      )
      assert.are.equal(100, api.money.balance(handle, "wallet"), "the lost sale is staff's to settle, not charged again")
    end,
  },
})
