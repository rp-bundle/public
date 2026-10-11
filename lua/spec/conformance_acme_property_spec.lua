-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Conformance (J8): the property example, `lua/examples/acme_property/`, run
-- as it ships on the mock platform and on the real FiveM and Gmod adapters,
-- against a fake portal (`spec/support/conformance.lua`). Staff's property
-- is a live record the server holds, and its door a config record that
-- refers to it. A player standing on the lot buys it from the offer the
-- server opens, and one exchange pays the price and writes them onto the
-- property; the owner then locks and unlocks its doors. The cases are the
-- issue's: a purchase, the refusals that move nothing, a retry under the
-- same op id, the bank out of reach, staff assigning the property in the
-- portal, disabling and enabling the addon, an upgrade, and a restart.

local conformance = require("spec.support.conformance")
local support = require("spec.support")

---What `conformance.run` needs from busted.
local busted = { describe = describe, it = it, before_each = before_each, after_each = after_each }

local SERVER = "00000001-0000-4000-8000-000000000001"
local PLAYER = "00000002-0000-4000-8000-000000000002"
local JOE = "00000003-0000-4000-8000-000000000003"
local JANE = "00000004-0000-4000-8000-000000000004"
local BANK = "00000005-0000-4000-8000-000000000005"
local TILL = "00000007-0000-4000-8000-000000000007"
local PROPERTY = "00000020-0000-4000-8000-000000000020"
local DOOR = "00000021-0000-4000-8000-000000000021"
local LOT = { x = 100, y = 200, z = 30 }
local PRICE = 500

---Loads the example's server half as an engine entry point does, and
---starts it on the world's API.
---@param world spec.ConformanceWorld The world.
---@param edit fun(property: acme_property)? Changes the loaded example before it starts (an upgrade's manifest).
---@return acme_property property The example's table.
local function load_example(world, edit)
  rawset(_G, "acme_property", nil)
  dofile(support.path("lua/examples/acme_property/manifest.lua"))
  dofile(support.path("lua/examples/acme_property/server.lua"))
  local property = rawget(_G, "acme_property")
  if edit then
    edit(property)
  end
  assert(property.start_server(world.api))
  return property
end

---Where the door is: five metres east of the middle of the lot, on it.
---@param world spec.ConformanceWorld The world.
---@return { x: number, y: number, z: number } spot The door.
local function door_spot(world)
  return { x = LOT.x + world:units(5), y = LOT.y, z = LOT.z }
end

---The portal's copies of Jane, her bank account and the server's till.
---@param world spec.ConformanceWorld The world.
local function seed_owned(world)
  local json = world.core.json
  local owned = world.portal.owned
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
  owned[BANK] = {
    kind = "account",
    revision = 1,
    balance = 1000,
    data = { id = BANK, server_id = SERVER, owner = { kind = "character", id = JANE }, name = "bank", flags = json.array({}) },
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
end

---The portal's copies of what Jane and the till are, and the property staff
---created on its data page, for sale and held by nobody.
---@param world spec.ConformanceWorld The world.
---@param fields table? Fields of the property's that differ.
local function seed(world, fields)
  seed_owned(world)
  -- Every field, defaults filled in, as the portal hands a record over.
  local property = {
    name = "Ivy Cottage",
    spot = LOT,
    -- Metres, as staff set it in the portal, on every engine.
    radius = 10,
    bucket = 0,
    price = PRICE,
    account = "bank",
    for_sale = true,
    locked = true,
  }
  for name, value in pairs(fields or {}) do
    property[name] = value
  end
  world.portal.records[PROPERTY] = {
    id = PROPERTY,
    type = "acme_property.property",
    owner = { kind = "server", id = SERVER },
    revision = 1,
    fields = property,
    held = false,
  }
end

---Installs the addon with staff's door, as the portal pushes a config, and
---answers the claim of the property that follows.
---@param world spec.ConformanceWorld The world.
---@param example acme_property The example.
---@param enabled boolean? Whether the installation is enabled; true unless false.
local function install(world, example, enabled)
  local json = world.core.json
  local installed = conformance.installed(world.core, example.MANIFEST, enabled)
  if enabled ~= false then
    installed.records = json.array({
      {
        id = DOOR,
        type = "acme_property.door",
        revision = 1,
        fields = json.object({ property = PROPERTY, label = "Front door", spot = json.object(door_spot(world)), bucket = 0 }),
      },
    })
  end
  world:install({ installed }, {
    settings = json.object({ ["economy.addon_account"] = "till" }),
    paying_accounts = json.array({ { id = TILL, name = "till" } }),
    new_character = json.object({ accounts = json.array({ { name = "bank", amount = 0 } }) }),
  })
  world:pump()
  world:advance(100)
  world:pump()
end

---A world with the addon running, the property held, and Jane in play in
---the middle of the lot.
---@param world spec.ConformanceWorld The world.
---@param fields table? As for `seed`.
---@return acme_property example The example.
---@return any handle Jane's engine handle.
local function on_the_lot(world, fields)
  seed(world, fields)
  local example = load_example(world)
  world:connect()
  install(world, example)
  assert.are.equal("active", (world.api.addons.state("acme_property")))
  assert.is_truthy(world.api.records.get("acme_property.property", PROPERTY), "the server holds the property")
  local handle = world:login(1, PLAYER)
  world:select(handle, JANE)
  world.place(1, LOT)
  return example, handle
end

---How many requests the harness's clients have numbered.
local numbered = 0

---Sends an interaction from Jane's client, aimed at a record, as the client
---core frames it, and gives the server's answer.
---@param world spec.ConformanceWorld The world.
---@param name string The interaction.
---@param id string The record it is aimed at.
---@return table? answer The decoded answer.
local function aim(world, name, id)
  local json = world.core.json
  local before = #world.to_clients
  numbered = numbered + 1
  local body = json.encode(json.object({ name = name, payload = json.object({ target = json.object({ id = id }) }) }))
  world.from_client(1, "rpf:interact", numbered .. "\n" .. assert(body))
  for i = before + 1, #world.to_clients do
    local sent = world.to_clients[i]
    if sent.name == "rpf:interact" then
      return json.decode((sent.payload:match("^%d+\n(.*)$")))
    end
  end
  return nil
end

---What the interaction menu offers Jane where she stands: each option's
---interaction name, as the server answers `rpf:targets`.
---@param world spec.ConformanceWorld The world.
---@return table<string, true> offers The names offered.
local function menu_offers(world)
  local json = world.core.json
  local before = #world.to_clients
  numbered = numbered + 1
  world.from_client(1, "rpf:targets", numbered .. "\n{}")
  local out = {}
  for i = before + 1, #world.to_clients do
    local sent = world.to_clients[i]
    if sent.name == "rpf:targets" then
      for _, option in ipairs(json.decode((sent.payload:match("^%d+\n(.*)$"))).options) do
        out[option.name] = true
      end
    end
  end
  return out
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

---The last notification Jane was shown.
---@param world spec.ConformanceWorld The world.
---@return string? text Its text.
local function told(world)
  for i = #world.to_clients, 1, -1 do
    local sent = world.to_clients[i]
    if sent.name == "rpf:ui_notify" then
      local notice = world.core.json.decode(sent.payload)
      return notice.text or (notice.spec and notice.spec.text)
    end
  end
  return nil
end

---Opens the offer on the lot.
---@param world spec.ConformanceWorld The world.
---@return string number The menu request's number, to answer.
---@return table options The options as Jane's client was shown them.
local function offered(world)
  local opened = assert(aim(world, "acme_property.buy", PROPERTY))
  assert.is_true(opened.ok, tostring(opened.reason))
  local number, request = asked(world)
  assert.are.equal("menu", request.kind)
  return number, request.spec.options
end

---Jane's client picks the first option of a menu.
---@param world spec.ConformanceWorld The world.
---@param number string The menu request's number.
local function pick(world, number)
  local json = world.core.json
  world.from_client(1, "rpf:ui", number .. "\n" .. assert(json.encode(json.object({ ok = true, index = 1 }))))
end

---Staff edit the held property from the portal: the command the portal
---sends its holder, as the portal frames it.
---@param world spec.ConformanceWorld The world.
---@param patch table The fields staff changed.
---@return string outcome How the server answered: `applied`, or `failed`.
local function staff_edit(world, patch)
  local json, protocol = world.core.json, world.core.protocol
  support.core = world.core
  local revision = assert(world.api.records.get("acme_property.property", PROPERTY)).revision
  local text = assert(protocol.encode(
    protocol.PORTAL_TO_SERVER,
    support.portal_frame("apply_command", {
      command = { command = "edit_addon_record", record_id = PROPERTY, base_revision = revision, patch = json.object(patch) },
    })
  ))
  world.socket_message(world.connects[#world.connects], text)
  for i = #world.sent, 1, -1 do
    local frame = assert(protocol.decode(protocol.SERVER_TO_PORTAL, world.sent[i].text))
    if frame.type == "command_applied" then
      world:pump()
      return frame.outcome.outcome
    end
  end
  error("the server did not answer the command")
end

---What Jane, the till and the property hold now.
---@param world spec.ConformanceWorld The world.
---@param handle any Jane's handle.
---@return table holdings `{ bank, till, holder, for_sale, locked }`.
local function holdings(world, handle)
  local api = world.api
  local property = api.records.get("acme_property.property", PROPERTY)
  local fields = property and property.fields or {}
  return {
    bank = api.money.balance(handle, "bank"),
    till = world.core.accounts.balance(TILL),
    holder = fields.holder or false,
    for_sale = fields.for_sale,
    locked = fields.locked,
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

---Buys the property from the offer, as Jane would.
---@param world spec.ConformanceWorld The world.
local function buy(world)
  local number = offered(world)
  pick(world, number)
  assert.are.equal("You bought Ivy Cottage for 500.", told(world))
end

---Jane's order, as the offer keeps it, for a case that calls the purchase
---itself.
---@param fields table? What differs.
---@return acme_property.Order order The order.
local function order(fields)
  local out = { property = PROPERTY, revision = 1, price = PRICE }
  for name, value in pairs(fields or {}) do
    out[name] = value
  end
  return out
end

conformance.run(busted, "the acme_property example", {
  {
    name = "sells the lot from the offer: one exchange pays the price and writes the buyer onto the property",
    run = function(world)
      local _, handle = on_the_lot(world)
      local _, options = offered(world)
      assert.are.equal(1, #options)
      assert.are.equal("Buy it for 500", options[1].label)
      assert.is_nil(options[1].value, "a value never leaves the server")
      pick(world, (asked(world)))
      assert.are.equal("You bought Ivy Cottage for 500.", told(world))
      assert.are.same({ bank = 500, till = 500, holder = PLAYER, for_sale = false, locked = true }, holdings(world, handle))
      world:settle()
      world:settle()
      local portal = world.portal.records[PROPERTY]
      assert.are.same({ PLAYER, false, true }, { portal.fields.holder, portal.fields.for_sale, portal.held }, "the portal has the owner")
      assert.are.equal("number", type(portal.fields.bought_at))
      local entries = reported(world, "Property: Ivy Cottage")
      assert.are.equal(1, #entries, "and one ledger entry, on the statement staff read")
      assert.are.same({ BANK, TILL, PRICE }, { entries[1].from_account, entries[1].to_account, entries[1].amount })
    end,
  },
  {
    name = "refuses too little money, a lot not for sale or already owned, a changed price or revision, and a buyer off the lot, moving nothing",
    run = function(world)
      local example, handle = on_the_lot(world)
      local api = world.api
      local jane = assert(api.players.get(handle))
      local before = holdings(world, handle)
      assert.is_true(menu_offers(world)["acme_property.buy"], "the menu offers the lot while it is for sale")
      local cases = {
        { order({ price = 400 }), "The price is now 500. Try again." },
        { order({ revision = 7 }), "The property changed while you chose. Try again." },
        { order({ property = "00000099-0000-4000-8000-000000000099" }), "This property cannot be bought now." },
      }
      for i, case in ipairs(cases) do
        assert.are.same({ false, case[2] }, { example.purchase(api, jane, case[1], api.ops.new()) }, tostring(i))
      end
      -- Off the lot, wherever the offer was opened.
      world.place(1, { x = LOT.x + world:units(11), y = LOT.y, z = LOT.z })
      assert.are.same({ false, "You walked off the lot." }, { example.purchase(api, jane, order(), api.ops.new()) })
      world.place(1, LOT)
      -- An order kept for a player who has gone lands on nobody else.
      local stranger = { handle = jane.handle, player_id = JOE }
      assert.are.same({ false, "You are not in the game." }, { example.purchase(api, stranger, order(), api.ops.new()) })
      -- Dearer than her bank account holds.
      assert.are.equal("applied", staff_edit(world, { price = 5000 }))
      local revision = api.records.get("acme_property.property", PROPERTY).revision
      assert.are.same(
        { false, "You cannot afford it." },
        { example.purchase(api, jane, order({ price = 5000, revision = revision }), api.ops.new()) }
      )
      -- Taken off the market, then sold to Joe, by staff.
      assert.are.equal("applied", staff_edit(world, { price = PRICE, for_sale = false }))
      revision = api.records.get("acme_property.property", PROPERTY).revision
      assert.are.same({ false, "It is no longer for sale." }, { example.purchase(api, jane, order({ revision = revision }), api.ops.new()) })
      assert.are.equal("applied", staff_edit(world, { holder = JOE }))
      assert.are.same({ false, "Someone else owns it now." }, { example.purchase(api, jane, order(), api.ops.new()) })
      local opened = assert(aim(world, "acme_property.buy", PROPERTY))
      assert.are.same({ false, "Ivy Cottage is not for sale." }, { opened.ok, opened.reason }, "and the offer says so")
      assert.is_nil(menu_offers(world)["acme_property.buy"], "and the menu no longer offers it")
      before.holder = JOE
      before.for_sale = false
      assert.are.same(before, holdings(world, handle), "no money moved")
      assert.are.same({}, api.ops.unknown())
    end,
  },
  {
    name = "refuses a price staff changed while the offer was open, charging nothing",
    run = function(world)
      local _, handle = on_the_lot(world)
      local number = offered(world)
      assert.are.equal("applied", staff_edit(world, { price = 700 }))
      pick(world, number)
      assert.are.equal("The price is now 700. Try again.", told(world))
      assert.are.same({ bank = 1000, till = 0, holder = false, for_sale = true, locked = true }, holdings(world, handle))
      number = offered(world)
      pick(world, number)
      assert.are.equal("You bought Ivy Cottage for 700.", told(world))
    end,
  },
  {
    name = "is bought once however often the same order is sent, and answers it as it was",
    run = function(world)
      local example, handle = on_the_lot(world)
      local api = world.api
      local jane = assert(api.players.get(handle))
      local op = api.ops.new()
      assert.are.same({ true, "You bought Ivy Cottage for 500." }, { example.purchase(api, jane, order(), op, "Ivy Cottage") })
      assert.are.same(
        { true, "You bought Ivy Cottage for 500." },
        { example.purchase(api, jane, order(), op, "Ivy Cottage") },
        "the same op id answers as before, though the lot is hers now"
      )
      assert.are.same({ false, "You own it already." }, { example.purchase(api, jane, order(), api.ops.new()) }, "a new order is a new one")
      assert.are.same({ bank = 500, till = 500, holder = PLAYER, for_sale = false, locked = true }, holdings(world, handle), "paid once")
    end,
  },
  {
    name = "waits for a bank it cannot reach yet, and sends the order again under the same op id",
    run = function(world)
      local example, handle = on_the_lot(world)
      local api = world.api
      local jane = assert(api.players.get(handle))
      -- The till is not held (as after a restart, before its hold lands).
      world.core.records.forget({ { kind = "account", id = TILL } })
      example.settle(api, jane, order(), api.ops.new(), "Ivy Cottage")
      assert.are.equal(1000, api.money.balance(handle, "bank"), "nothing yet")
      world.core.accounts.hold_paying()
      world:pump()
      world:advance(1000)
      assert.are.equal("You bought Ivy Cottage for 500.", told(world))
      assert.are.same({ bank = 500, till = 500, holder = PLAYER, for_sale = false, locked = true }, holdings(world, handle))
    end,
  },
  {
    name = "lets the owner lock and unlock the doors, tells anyone else whether they are locked, and answers a door script",
    run = function(world)
      local _, handle = on_the_lot(world)
      local api = world.api
      local spot = door_spot(world)
      world.place(1, { x = spot.x, y = spot.y + world:units(1), z = spot.z })
      local used = assert(aim(world, "acme_property.door", DOOR))
      assert.are.same({ true, true }, { used.ok, used.data and used.data.locked }, "not hers: she only finds it locked")
      assert.are.equal("It is locked.", told(world))
      assert.are.same({ true, true }, { api.addons.call("acme_property.locked", DOOR) })
      world.place(1, LOT)
      buy(world)
      world.place(1, { x = spot.x, y = spot.y + world:units(1), z = spot.z })
      used = assert(aim(world, "acme_property.door", DOOR))
      assert.are.same({ true, false }, { used.ok, used.data.locked })
      assert.are.equal("You unlock the doors.", told(world))
      assert.are.same({ true, false }, { api.addons.call("acme_property.locked", DOOR) })
      used = assert(aim(world, "acme_property.door", DOOR))
      assert.are.equal("You lock the doors.", told(world))
      assert.are.same({ true, true }, { api.addons.call("acme_property.locked", DOOR) })
      assert.are.same({ true }, { api.addons.call("acme_property.locked", "00000099-0000-4000-8000-000000000099") }, "a door that is not there")
      -- Out of reach of the door, the server refuses before the addon hears of it.
      world.place(1, LOT)
      used = assert(aim(world, "acme_property.door", DOOR))
      assert.are.same({ false, "too_far" }, { used.ok, used.reason })
      world:settle()
      assert.is_true(world.portal.records[PROPERTY].fields.locked, "the portal has the lock as it was left")
    end,
  },
  {
    name = "hands the doors to whoever staff assign the property to in the portal",
    run = function(world)
      local _, handle = on_the_lot(world)
      buy(world)
      assert.are.equal("applied", staff_edit(world, { holder = JOE }))
      local spot = door_spot(world)
      world.place(1, { x = spot.x, y = spot.y + world:units(1), z = spot.z })
      local used = assert(aim(world, "acme_property.door", DOOR))
      assert.are.same({ true, true }, { used.ok, used.data.locked })
      assert.are.equal("It is locked.", told(world), "no longer hers to unlock")
      assert.are.equal(JOE, holdings(world, handle).holder)
      world:settle()
      assert.are.equal(JOE, world.portal.records[PROPERTY].fields.holder)
    end,
  },
  {
    name = "keeps every record while disabled, offering nothing, and is usable again once enabled",
    run = function(world)
      local example = on_the_lot(world)
      buy(world)
      world:settle()
      install(world, example, false)
      assert.are.equal("disabled", (world.api.addons.state("acme_property")))
      local portal = world.portal.records[PROPERTY]
      assert.are.same({ false, PLAYER }, { portal.held, portal.fields.holder }, "let go with its final state, and kept")
      local spot = door_spot(world)
      world.place(1, { x = spot.x, y = spot.y + world:units(1), z = spot.z })
      local used = assert(aim(world, "acme_property.door", DOOR))
      assert.is_false(used.ok, "no door to use")
      assert.is_false((world.api.addons.call("acme_property.locked", DOOR)), "nor one to ask about")
      install(world, example)
      assert.are.equal("active", (world.api.addons.state("acme_property")))
      assert.is_true(world.portal.records[PROPERTY].held, "claimed again")
      used = assert(aim(world, "acme_property.door", DOOR))
      assert.are.same({ true, false }, { used.ok, used.data and used.data.locked }, "still hers to unlock")
    end,
  },
  {
    name = "keeps every property and its owner across an upgrade that adds a field",
    run = function(world)
      on_the_lot(world)
      buy(world)
      world:settle()
      local example = load_example(world, function(loaded)
        local manifest = loaded.MANIFEST
        manifest.version = "1.1.0"
        manifest.types.property.schema = 2
        manifest.types.property.fields.garden = { type = "boolean", default = false, title = "Has a garden" }
      end)
      install(world, example)
      assert.are.equal("active", (world.api.addons.state("acme_property")))
      local property = assert(world.api.records.get("acme_property.property", PROPERTY))
      assert.are.same({ PLAYER, false }, { property.fields.holder, property.fields.garden }, "an older property reads with the default")
      local spot = door_spot(world)
      world.place(1, { x = spot.x, y = spot.y + world:units(1), z = spot.z })
      assert.is_true(assert(aim(world, "acme_property.door", DOOR)).ok, "and its doors are hers")
    end,
  },
  {
    name = "keeps the owner and the lock across a restart",
    run = function(world)
      on_the_lot(world)
      buy(world)
      local spot = door_spot(world)
      world.place(1, { x = spot.x, y = spot.y + world:units(1), z = spot.z })
      assert.are.equal(false, assert(aim(world, "acme_property.door", DOOR)).data.locked)
      world:settle()
      world:settle()
      world:restart(world:snapshot())
      -- The portal's copies of Jane and the till again, as the new process's
      -- codec marks them; the property is as the old process left it.
      seed_owned(world)
      local kept = world.portal.records[PROPERTY]
      local example = load_example(world)
      world:connect()
      install(world, example)
      assert.are.same({ PLAYER, false }, { kept.fields.holder, kept.fields.locked })
      local property = assert(world.api.records.get("acme_property.property", PROPERTY), "claimed back")
      assert.are.same({ PLAYER, false }, { property.fields.holder, property.fields.locked })
      local handle = world:login(1, PLAYER)
      world:select(handle, JANE)
      world.place(1, { x = spot.x, y = spot.y + world:units(1), z = spot.z })
      local used = assert(aim(world, "acme_property.door", DOOR))
      assert.are.same({ true, true }, { used.ok, used.data.locked })
      assert.are.equal("You lock the doors.", told(world))
    end,
  },
})
