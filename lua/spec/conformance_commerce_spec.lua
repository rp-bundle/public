-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Conformance (J5): exchanges (`rpf.api.commerce`) on an RPF server, the
-- same cases on the mock platform and on the real FiveM and Gmod adapters,
-- against a fake portal (`spec/support/conformance.lua`). A deal moves money
-- and items together, with an addon's change to its own records, as one
-- intent: all or nothing, once per op id, complete only once every change is
-- on its way to the portal. The companion path, through a bridge, is the
-- shared bridge suite's (`spec/support/bridge_conformance.lua`).

local conformance = require("spec.support.conformance")

---What `conformance.run` needs from busted.
local busted = { describe = describe, it = it, before_each = before_each, after_each = after_each }

local SERVER = "00000001-0000-4000-8000-000000000001"
local PLAYER = "00000002-0000-4000-8000-000000000002"
local JANE = "00000004-0000-4000-8000-000000000004"
local WALLET = "00000005-0000-4000-8000-000000000005"
local TILL = "00000007-0000-4000-8000-000000000007"
local BAG = "00000008-0000-4000-8000-000000000008"
local POCKETS = "00000009-0000-4000-8000-000000000009"

---The portal's copies of Jane, her wallet and two containers, and the
---server's till. Every unit weighs one; `room` bounds both containers'
---weight, nil for no bound.
---@param world spec.ConformanceWorld The world.
---@param room { bag: integer, pockets: integer }? The containers' weight limits.
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
  ---A container of Jane's.
  ---@param id string Its id.
  ---@param name string Its name.
  ---@param stacks table[] What it holds.
  ---@param weight integer? Its weight limit.
  local function container(id, name, stacks, weight)
    owned[id] = {
      kind = "container",
      revision = 1,
      data = {
        id = id,
        server_id = SERVER,
        owner = jane,
        name = name,
        contents = json.object({ layout = "list", stacks = json.array(stacks) }),
        flags = json.array(weight and { json.object({ flag = "max_weight", value = weight }) } or {}),
      },
    }
  end
  container(BAG, "Bag", { { item = "water", count = 1 } }, room and room.bag)
  container(POCKETS, "Pockets", {
    { item = "water", count = 2 },
    { item = "water", count = 1, data = json.object({ note = "for Sam" }) },
  }, room and room.pockets)
end

---A shop's stock: a live type the server owns, which a deal is priced
---against and its change moves.
---@return table manifest The manifest.
local function shop()
  return {
    namespace = "acme_corner",
    version = "1.0.0",
    api = 1,
    title = "Corner shop",
    types = {
      stock = {
        schema = 1,
        authority = "live",
        owners = { "server" },
        fields = { left = { type = "integer", min = 0, required = true } },
      },
    },
  }
end

---The config: the catalog, Jane's starting account, and the till as the
---addon account.
---@param world spec.ConformanceWorld The world.
---@return table extra The snapshot's sections.
local function config(world)
  local json = world.core.json
  local size = json.object({ x = 1, y = 1 })
  return {
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

---A world with Jane logged in and in play, and the shop's addon active.
---@param world spec.ConformanceWorld The world.
---@param room { bag: integer, pockets: integer }? As for `seed`.
---@return any handle Her engine handle.
local function trading(world, room)
  seed(world, room)
  local manifest = shop()
  assert(world.api.addons.register(manifest))
  world:connect()
  world:install({ conformance.installed(world.core, manifest) }, config(world))
  world:pump()
  assert.are.equal("active", (world.api.addons.state("acme_corner")))
  local handle = world:login(1, PLAYER)
  world:select(handle, JANE)
  return handle
end

---The shop's stock record, made by the server.
---@param world spec.ConformanceWorld The world.
---@param left integer How many.
---@return table stock The record.
local function stock(world, left)
  return assert(world.api.records.create("acme_corner.stock", { left = left }, { owner = { kind = "server", id = SERVER } }))
end

---The journal's entry for an op, as storage holds it.
---@param world spec.ConformanceWorld The world.
---@param op string The op id.
---@return table entry The entry, decoded.
local function stored(world, op)
  local key = world.core.ops.ENTRY_PREFIX .. op
  return world.core.json.decode(assert(world.server_platform.kv_get(key)))
end

---The ledger entries the portal was sent with a description, in the order
---they went: a resend of one is counted again.
---@param world spec.ConformanceWorld The world.
---@param description string The description.
---@return table[] entries The entries, as the frames carried them.
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

---What Jane holds now: her wallet's balance, the till's, and her plain
---water and bread.
---@param world spec.ConformanceWorld The world.
---@param handle any Her handle.
---@return table holdings `{ wallet, till, water, bread }`.
local function holdings(world, handle)
  local api = world.api
  return {
    wallet = api.money.balance(handle, "wallet"),
    till = world.core.accounts.balance(TILL),
    water = api.inventory.count(handle, "water"),
    bread = api.inventory.count(handle, "bread"),
  }
end

conformance.run(busted, "exchanges", {
  {
    name = "sells items for money in one intent, once per op id",
    run = function(world)
      local handle = trading(world)
      local api = world.api
      local op = api.ops.new()
      local deal = { account = "wallet", pay = 10, give = { { item = "bread", count = 2 } }, reason = "Corner shop: 2 bread" }
      assert.is_true(api.commerce.exchange(handle, deal, op))
      assert.is_true(api.commerce.exchange(handle, deal, op), "the same op again answers as before")
      assert.are.same({ wallet = 90, till = 10, water = 3, bread = 2 }, holdings(world, handle), "and is made once")
      world:settle()
      local stacks = world.portal.owned[BAG].data.contents.stacks
      assert.are.same({ "water", "bread" }, { stacks[1].item, stacks[2].item }, "the portal has the bread")
      local entries = reported(world, "Corner shop: 2 bread")
      assert.are.equal(1, #entries, "and one ledger entry")
      assert.are.same({ WALLET, TILL, 10 }, { entries[1].from_account, entries[1].to_account, entries[1].amount })
      assert.are.equal("done", stored(world, op).state)
    end,
  },
  {
    name = "buys back: takes the player's items and pays them",
    run = function(world)
      local handle = trading(world)
      local api = world.api
      assert.is_true(api.commerce.exchange(handle, {
        account = "wallet",
        paid = 3,
        take = { { item = "water", count = 2 } },
        reason = "Corner shop: bought back 2 water",
      }, api.ops.new()))
      assert.are.same({ wallet = 103, till = -3, water = 1, bread = 0 }, holdings(world, handle))
    end,
  },
  {
    name = "lets what the player hands over make the room for what they get",
    run = function(world)
      -- Both containers are full: the bag holds one unit, the pockets three.
      local handle = trading(world, { bag = 1, pockets = 3 })
      local api = world.api
      local swap = {
        take = { { item = "water", count = 1 } },
        give = { { item = "bread", count = 1 } },
        reason = "Corner shop: swap",
      }
      assert.are.same(
        { nil, "refused", "no_space" },
        { api.commerce.exchange(handle, { give = swap.give, reason = swap.reason }, api.ops.new()) }
      )
      assert.is_true(api.commerce.exchange(handle, swap, api.ops.new()))
      assert.are.same({ wallet = 100, till = 0, water = 2, bread = 1 }, holdings(world, handle))
    end,
  },
  {
    name = "refuses what cannot be made whole, and changes nothing",
    run = function(world)
      local handle = trading(world, { bag = 1, pockets = 3 })
      local api = world.api
      local before = holdings(world, handle)
      local bread = { { item = "bread", count = 1 } }
      local cases = {
        { "insufficient_funds", { account = "wallet", pay = 500, take = { { item = "water", count = 1 } }, give = bread, reason = "x" } },
        { "no_space", { account = "wallet", pay = 10, give = { { item = "bread", count = 5 } }, reason = "x" } },
        { "insufficient", { account = "wallet", paid = 5, take = { { item = "water", count = 4 } }, reason = "x" } },
        { "unknown_item", { account = "wallet", pay = 1, give = { { item = "unobtainium", count = 1 } }, reason = "x" } },
        { "no_account", { account = "crypto", pay = 1, reason = "x" } },
        -- Not deals: a misspelt key, both directions, nothing to move, a
        -- bad line or amount, no reason, no account for money, too many lines.
        { "invalid", { account = "wallet", pay = 1, gve = bread, reason = "x" } },
        { "invalid", { account = "wallet", pay = 1, paid = 1, reason = "x" } },
        { "invalid", { reason = "x" } },
        { "invalid", { give = { { item = "bread", count = 0 } }, reason = "x" } },
        { "invalid", { give = { { item = "bread", count = 1, data = {} } }, reason = "x" } },
        { "invalid", { give = { { item = "bread" } }, reason = "x" } },
        { "invalid", { account = "wallet", pay = 1.5, reason = "x" } },
        { "invalid", { account = "wallet", pay = false, give = bread, reason = "x" } },
        { "invalid", { account = "wallet", paid = false, take = { { item = "water", count = 1 } }, reason = "x" } },
        { "invalid", { account = "wallet", pay = 1 } },
        { "invalid", { pay = 1, reason = "x" } },
        { "invalid", "a deal" },
      }
      local many = {}
      for i = 1, 17 do
        many[i] = { item = "water", count = 1 }
      end
      cases[#cases + 1] = { "invalid", { take = many, reason = "x" } }
      for i, case in ipairs(cases) do
        assert.are.same({ nil, "refused", case[1] }, { api.commerce.exchange(handle, case[2], api.ops.new()) }, tostring(i))
      end
      local deal = { account = "wallet", pay = 1, reason = "x" }
      assert.are.same({ nil, "refused", "invalid_op" }, { api.commerce.exchange(handle, deal, "my-op") })
      assert.are.same({ nil, "refused", "invalid" }, { api.commerce.exchange(handle, deal, api.ops.new(), 42) })
      assert.are.same({ nil, "refused", "not_logged_in" }, { api.commerce.exchange(9, deal, api.ops.new()) })
      assert.are.same(before, holdings(world, handle), "nothing moved")
      assert.are.same({}, api.ops.unknown())
    end,
  },
  {
    name = "refuses a deal priced against a record that moved on since",
    run = function(world)
      local handle = trading(world)
      local api = world.api
      local shelf = stock(world, 5)
      assert(api.records.update("acme_corner.stock", shelf.id, { left = 4 }))
      local deal = {
        account = "wallet",
        pay = 10,
        give = { { item = "bread", count = 1 } },
        reason = "Corner shop: bread",
        records = { { type = "acme_corner.stock", id = shelf.id, revision = shelf.revision } },
      }
      assert.are.same({ nil, "refused", "stale" }, { api.commerce.exchange(handle, deal, api.ops.new()) })
      deal.records[1].id = "0000000f-0000-4000-8000-00000000000f"
      assert.are.same({ nil, "refused", "not_held" }, { api.commerce.exchange(handle, deal, api.ops.new()) })
      assert.are.same({ wallet = 100, till = 0, water = 3, bread = 0 }, holdings(world, handle))
    end,
  },
  {
    name = "makes the addon's change with the deal, completing once all of it is on its way",
    run = function(world)
      local handle = trading(world)
      local api = world.api
      local shelf = stock(world, 5)
      world:settle()
      local op, applied = api.ops.new(), 0
      local deal = {
        account = "wallet",
        pay = 20,
        give = { { item = "bread", count = 2 } },
        reason = "Corner shop: 2 bread",
        records = { { type = "acme_corner.stock", id = shelf.id, revision = shelf.revision } },
      }
      ---The stock the deal pays for: two fewer on the shelf.
      ---@return table? record The stock.
      local function sell()
        applied = applied + 1
        return api.records.update("acme_corner.stock", shelf.id, { left = shelf.fields.left - 2 }, { revision = shelf.revision })
      end
      -- The outbox has no room: everything is made here, nothing queued.
      local options = world.core.connection.options
      local entries = options.max_entries
      options.max_entries = 0
      assert.is_true(api.commerce.exchange(handle, deal, op, sell))
      assert.are.equal(3, assert(api.records.get("acme_corner.stock", shelf.id)).fields.left)
      assert.are.same({ wallet = 80, till = 20, water = 3, bread = 2 }, holdings(world, handle))
      assert.are.equal("pending", stored(world, op).state, "a crash now would read it as unknown")
      options.max_entries = entries
      world:settle()
      world:settle()
      assert.are.equal("done", stored(world, op).state)
      assert.are.equal(3, world.portal.records[shelf.id].fields.left)
      assert.is_true(api.commerce.exchange(handle, deal, op, sell), "a repeat answers as before")
      assert.are.equal(1, applied, "and neither charges nor sells again")
    end,
  },
  {
    name = "is unknown for staff when the change it paid for fails, with what the deal moved",
    run = function(world)
      local handle = trading(world)
      local api = world.api
      local op = api.ops.new()
      assert.are.same({ nil, "unknown" }, {
        api.commerce.exchange(handle, {
          account = "wallet",
          pay = 10,
          take = { { item = "water", count = 1 } },
          give = { { item = "bread", count = 2 } },
          reason = "Corner shop: swap",
        }, op, function()
          return nil, "limit"
        end),
      })
      assert.are.same({ wallet = 90, till = 10, water = 2, bread = 2 }, holdings(world, handle), "it moved, and stays moved")
      local listed = api.ops.unknown()
      assert.are.equal(1, #listed)
      assert.are.same({ op, "commerce.exchange" }, { listed[1].op_id, listed[1].call })
      assert.are.same({
        player = PLAYER,
        account = "wallet",
        amount = 10,
        take = "water:1",
        give = "bread:2",
        reason = "Corner shop: swap",
      }, listed[1].detail)
      assert.are.equal(1, world:logged("error", "give=bread:2"))
    end,
  },
  {
    name = "checks a deal as it would make it, and moves nothing",
    run = function(world)
      local handle = trading(world, { bag = 1, pockets = 3 })
      local api = world.api
      local before = holdings(world, handle)
      local count = world.core.ops.count()
      local swap = {
        account = "wallet",
        pay = 5,
        take = { { item = "water", count = 1 } },
        give = { { item = "bread", count = 1 } },
        reason = "Corner shop: swap",
      }
      assert.is_true(api.commerce.check(handle, swap))
      swap.pay = 500
      assert.are.same({ nil, "refused", "insufficient_funds" }, { api.commerce.check(handle, swap) })
      swap.pay, swap.take = 5, nil
      assert.are.same({ nil, "refused", "no_space" }, { api.commerce.check(handle, swap) })
      assert.are.same({ nil, "refused", "invalid" }, { api.commerce.check(handle, { reason = "x" }) })
      assert.are.same(before, holdings(world, handle))
      assert.are.equal(count, world.core.ops.count(), "nothing journaled")
    end,
  },
  {
    name = "reads a deal a restart cut off as unknown, and never makes it again",
    run = function(world)
      local handle = trading(world)
      local api = world.api
      local op = api.ops.new()
      local deal = { account = "wallet", pay = 10, give = { { item = "bread", count = 1 } }, reason = "Corner shop: bread" }
      -- Made in memory, not yet in the outbox: the server dies here.
      world.core.connection.options.max_entries = 0
      assert.is_true(api.commerce.exchange(handle, deal, op))
      world:restart(world:snapshot())
      world:connect()
      api = world.api
      assert.are.equal(1, world:logged("error", "cut off by a restart"))
      local listed = api.ops.unknown()
      assert.are.equal(1, #listed)
      assert.are.same({ op, "bread:1" }, { listed[1].op_id, listed[1].detail.give })
      assert.are.same({ nil, "unknown" }, { api.commerce.exchange(handle, deal, op) })
      world:settle()
      assert.are.same({}, reported(world, "Corner shop: bread"), "the payment was lost with the process")
    end,
  },
})
