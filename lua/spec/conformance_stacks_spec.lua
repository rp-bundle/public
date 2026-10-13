-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Conformance (#183): the facade's stack calls, what an inventory screen is
-- built on, the same cases on the mock platform and on the real FiveM and
-- Gmod adapters, against a fake portal (`spec/support/conformance.lua`).
-- Jane reads her containers with every stack numbered and named, moves a
-- stack between them, throws one away and hands one to Sam, and pays Sam
-- cash, each once per op id. Every container id and index is a client's
-- word, so Sam's container, one nobody holds and one that never existed are
-- refused alike, with nothing changed and nothing journaled.

local conformance = require("spec.support.conformance")

---What `conformance.run` needs from busted.
local busted = { describe = describe, it = it, before_each = before_each, after_each = after_each }

local SERVER = "00000001-0000-4000-8000-000000000001"
local PLAYER = "00000002-0000-4000-8000-000000000002"
local SAM_PLAYER = "00000003-0000-4000-8000-000000000003"
local JANE = "00000004-0000-4000-8000-000000000004"
local SAM = "00000005-0000-4000-8000-000000000005"
local WALLET = "00000006-0000-4000-8000-000000000006"
local SAM_WALLET = "00000007-0000-4000-8000-000000000007"
local BAG = "00000008-0000-4000-8000-000000000008"
local CASE = "00000009-0000-4000-8000-000000000009"
local SAM_BAG = "0000000a-0000-4000-8000-00000000000a"
local NOWHERE = "0000000b-0000-4000-8000-00000000000b"

---The portal's copies of Jane and Sam, their wallets and containers.
---@param world spec.ConformanceWorld The world.
---@param sam_weight integer? The weight Sam's bag takes; 100 unless given.
local function seed(world, sam_weight)
  local json = world.core.json
  local owned = world.portal.owned
  ---A character.
  ---@param id string Its id.
  ---@param player string Its player.
  ---@param first string Its first name.
  local function character(id, player, first)
    owned[id] = {
      kind = "character",
      revision = 1,
      data = {
        id = id,
        server_id = SERVER,
        owner = { kind = "player", id = player },
        first_name = first,
        last_name = "Doe",
        gender = "female",
      },
    }
  end
  character(JANE, PLAYER, "Jane")
  character(SAM, SAM_PLAYER, "Sam")
  ---A wallet.
  ---@param id string Its id.
  ---@param owner string Its character.
  ---@param balance integer Its balance.
  local function wallet(id, owner, balance)
    owned[id] = {
      kind = "account",
      revision = 1,
      balance = balance,
      data = { id = id, server_id = SERVER, owner = { kind = "character", id = owner }, name = "wallet", flags = json.array({}) },
    }
  end
  wallet(WALLET, JANE, 100)
  wallet(SAM_WALLET, SAM, 5)
  ---A container.
  ---@param id string Its id.
  ---@param owner string Its character.
  ---@param name string Its name.
  ---@param contents table What it holds.
  ---@param flags table[] Its flags.
  local function container(id, owner, name, contents, flags)
    owned[id] = {
      kind = "container",
      revision = 1,
      data = {
        id = id,
        server_id = SERVER,
        owner = { kind = "character", id = owner },
        name = name,
        contents = contents,
        flags = json.array(flags),
      },
    }
  end
  container(BAG, JANE, "Bag", json.object({
    layout = "list",
    stacks = json.array({
      json.object({ item = "water", count = 3 }),
      json.object({ item = "water", count = 1, data = json.object({ note = "for Sam" }) }),
    }),
  }), { json.object({ flag = "max_weight", value = 50 }) })
  container(CASE, JANE, "Case", json.object({
    layout = "grid",
    placements = json.array({
      json.object({
        stack = json.object({ item = "bread", count = 2 }),
        position = json.object({ x = 0, y = 0 }),
        rotated = false,
      }),
    }),
  }), { json.object({ flag = "grid", value = json.object({ x = 2, y = 2 }) }) })
  container(SAM_BAG, SAM, "Bag", json.object({
    layout = "list",
    stacks = json.array({ json.object({ item = "bread", count = 1 }) }),
  }), { json.object({ flag = "max_weight", value = sam_weight or 100 }) })
end

---The config: a wallet for every character, and two items with names.
---@param world spec.ConformanceWorld The world.
---@return table extra The snapshot's sections.
local function config(world)
  local json = world.core.json
  local size = json.object({ x = 1, y = 1 })
  return {
    new_character = json.object({ accounts = json.array({ { name = "wallet", amount = 0 } }) }),
    items = json.array({
      json.object({ slug = "water", name = "Water", weight = 1, size = size, stack_limit = 10 }),
      json.object({ slug = "bread", name = "Bread", weight = 2, size = size, stack_limit = 10 }),
    }),
    item_defaults = json.object({ weight = 1, size = size, stack_limit = 10 }),
  }
end

---A world with Jane and Sam logged in and in play.
---@param world spec.ConformanceWorld The world.
---@param sam_weight integer? As for `seed`.
---@param addons { manifest: table, start: fun() }[]? Addons to register and install, each started with its `start`.
---@return any jane Jane's engine handle.
---@return any sam Sam's.
local function playing(world, sam_weight, addons)
  seed(world, sam_weight)
  local installed = {}
  for _, addon in ipairs(addons or {}) do
    assert(world.api.addons.register(addon.manifest, { start = addon.start }))
    installed[#installed + 1] = conformance.installed(world.core, addon.manifest)
  end
  world:connect()
  world:install(installed, config(world))
  world:pump()
  local jane = world:login(1, PLAYER)
  world:select(jane, JANE)
  local sam = world:login(2, SAM_PLAYER)
  world:select(sam, SAM)
  return jane, sam
end

---What a held container holds now, item by item: `{ item, count, note }`
---for each stack, in order.
---@param world spec.ConformanceWorld The world.
---@param id string The container.
---@return table[] stacks The stacks.
local function holds(world, id)
  local out = {}
  local view = assert(world.core.inventory.view(id))
  for _, stack in ipairs(view.stacks) do
    out[#out + 1] = { stack.item, stack.count, stack.data and stack.data.note or nil }
  end
  return out
end

---A stack named as a screen names one back: where it was, its item, and
---the fingerprint of its data that `containers` gave with it.
---@param world spec.ConformanceWorld The world.
---@param container any The container's id.
---@param index any The stack's index.
---@param item string The item.
---@param data table? The stack's data, none for plain units.
---@return table ref The reference.
local function ref(world, container, index, item, data)
  local json = world.core.json
  return {
    container = container,
    index = index,
    item = item,
    key = world.core.inventory.stack_key(data and json.object(data) or nil),
  }
end

---Every container and wallet of both characters, as this server holds them.
---@param world spec.ConformanceWorld The world.
---@return table state The state.
local function everything(world)
  return {
    bag = holds(world, BAG),
    case = holds(world, CASE),
    sam_bag = holds(world, SAM_BAG),
    wallet = world.core.accounts.balance(WALLET),
    sam_wallet = world.core.accounts.balance(SAM_WALLET),
  }
end

---The ledger entries reported to the portal with a description.
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

---A manifest that declares nothing but itself: an addon whose code only
---says what using items does.
---@param namespace string Its namespace.
---@return table manifest The manifest.
local function food(namespace)
  return { namespace = namespace, version = "1.0.0", api = 1, title = "Food" }
end

conformance.run(busted, "the facade's stacks", {
  {
    name = "reads the character's containers, every stack numbered, named and weighed",
    run = function(world)
      local jane = playing(world)
      local inventory = world.api.inventory
      assert.is_true(inventory.supports("containers"))
      local containers = assert(inventory.containers(jane))
      local PLAIN = ref(world, BAG, 1, "water").key
      local noted = ref(world, BAG, 2, "water", { note = "for Sam" }).key
      assert.are_not.equal(PLAIN, noted)
      assert.are.same({
        {
          id = BAG,
          name = "Bag",
          layout = "list",
          max_weight = 50,
          weight = 4,
          stacks = {
            { index = 1, item = "water", name = "Water", count = 3, key = PLAIN, usable = false },
            { index = 2, item = "water", name = "Water", count = 1, data = { note = "for Sam" }, key = noted, usable = false },
          },
        },
        {
          id = CASE,
          name = "Case",
          layout = "grid",
          grid = { x = 2, y = 2 },
          weight = 4,
          stacks = {
            { index = 1, item = "bread", name = "Bread", count = 2, position = { x = 0, y = 0 }, rotated = false, key = PLAIN, usable = false },
          },
        },
      }, containers, "Sam's bag is not Jane's to read")
      assert.are.same({ nil, "not_logged_in" }, { inventory.containers(9) })
    end,
  },
  {
    name = "moves a stack between the character's own containers once per op id",
    run = function(world)
      local jane = playing(world)
      local inventory, ops = world.api.inventory, world.api.ops
      local op = ops.new()
      local water = ref(world, BAG, 1, "water")
      assert.is_true(inventory.move(jane, water, CASE, op, { count = 2 }))
      assert.is_true(inventory.move(jane, water, CASE, op, { count = 2 }), "the same op again answers as before")
      assert.are.same({ { "water", 1 }, { "water", 1, "for Sam" } }, holds(world, BAG), "and moves nothing more")
      assert.are.same({ { "bread", 2 }, { "water", 2 } }, holds(world, CASE))
      -- The case's free cell is taken now: the bread moves to a spot of its own.
      assert.is_true(inventory.move(jane, ref(world, CASE, 1, "bread"), CASE, ops.new(), {
        position = { x = 1, y = 1 },
      }))
      assert.are.same({ { "water", 2 }, { "bread", 2 } }, holds(world, CASE), "the bread's placement moved to the end")
      assert.are.same(
        { nil, "refused", "stale" },
        { inventory.move(jane, ref(world, CASE, 1, "bread"), BAG, ops.new()) },
        "an old index names water now, never moves it"
      )
      assert.are.same(
        { nil, "refused", "no_space" },
        { inventory.move(jane, ref(world, BAG, 1, "water"), CASE, ops.new(), {
          position = { x = 1, y = 1 },
        }) },
        "a cell the bread sits in takes nothing"
      )
      assert.are.same(
        { nil, "refused", "no_space" },
        { inventory.move(jane, ref(world, BAG, 1, "water"), CASE, ops.new(), {
          position = { x = 65536, y = 0 },
        }) },
        "a cell past the grid is the grid's to refuse"
      )
      assert.are.same(
        { nil, "refused", "invalid" },
        { inventory.move(jane, ref(world, BAG, 1, "water"), CASE, ops.new(), {
          position = { x = 2147483648, y = 0 },
        }) },
        "a position past i32 is no position"
      )
      assert.are.same(
        { nil, "refused", "invalid" },
        { inventory.move(jane, ref(world, BAG, 0, "water"), CASE, ops.new()) }
      )
      assert.are.same(
        { nil, "refused", "invalid" },
        { inventory.move(jane, ref(world, BAG, 1, "water"), CASE, ops.new(), { count = 1.5 }) }
      )
      assert.are.same(
        { nil, "refused", "invalid_op" },
        { inventory.move(jane, ref(world, BAG, 1, "water"), CASE, "my-op") }
      )
      world:settle()
      local placements = world.portal.owned[CASE].data.contents.placements
      assert.are.same({ "water", "bread" }, { placements[1].stack.item, placements[2].stack.item }, "the portal has both")
    end,
  },
  {
    name = "refuses another character's container as one that does not exist, changing nothing",
    run = function(world)
      local jane, sam = playing(world)
      local inventory, ops = world.api.inventory, world.api.ops
      local before = everything(world)
      local mine = ref(world, BAG, 1, "water")
      for name, stack in pairs({
        ["Sam's"] = ref(world, SAM_BAG, 1, "bread"),
        ["nobody's"] = ref(world, NOWHERE, 1, "bread"),
        ["a number"] = ref(world, 7, 1, "bread"),
      }) do
        local expected = name == "a number" and "invalid" or "not_found"
        local op = ops.new()
        assert.are.same({ nil, "refused", expected }, { inventory.move(jane, stack, CASE, op) }, name .. " move")
        assert.are.same({ nil, "refused", expected }, { inventory.discard(jane, stack, 1, op) }, name .. " discard")
        assert.are.same({ nil, "refused", expected }, { inventory.hand(jane, sam, stack, 1, op) }, name .. " hand")
        assert.is_nil(ops.result(op), name .. " is not journaled")
      end
      for name, to in pairs({ ["Sam's"] = SAM_BAG, ["nobody's"] = NOWHERE }) do
        local op = ops.new()
        assert.are.same({ nil, "refused", "not_found" }, { inventory.move(jane, mine, to, op) }, name .. " destination")
        assert.is_nil(ops.result(op))
      end
      assert.are.same(
        { nil, "refused", "not_found" },
        { inventory.discard(jane, ref(world, BAG, 3, "water"), 1, ops.new()) },
        "an index past the end"
      )
      assert.are.same(before, everything(world), "nothing moved")
      world:settle()
      assert.are.same(
        { "bread" },
        { world.portal.owned[SAM_BAG].data.contents.stacks[1].item },
        "and the portal's copy of Sam's bag is as it was"
      )
    end,
  },
  {
    name = "throws away units of the one stack named, data and all",
    run = function(world)
      local jane = playing(world)
      local inventory, ops = world.api.inventory, world.api.ops
      local bottle = ref(world, BAG, 2, "water", { note = "for Sam" })
      assert.are.same(
        { nil, "refused", "stale" },
        { inventory.discard(jane, ref(world, BAG, 2, "water"), 1, ops.new()) },
        "the bottle named as the plain water"
      )
      assert.are.same(
        { nil, "refused", "stale" },
        { inventory.discard(jane, ref(world, BAG, 2, "water", { note = "for Ann" }), 1, ops.new()) },
        "the bottle named with another note"
      )
      assert.are.same({ nil, "refused", "insufficient" }, { inventory.discard(jane, bottle, 2, ops.new()) })
      local op = ops.new()
      assert.is_true(inventory.discard(jane, bottle, 1, op))
      assert.is_true(inventory.discard(jane, bottle, 1, op), "once per op id")
      assert.are.same({ { "water", 3 } }, holds(world, BAG), "the bottle with the note went, the plain water stayed")
      assert.is_true(inventory.discard(jane, ref(world, BAG, 1, "water"), 2, ops.new()))
      assert.are.same({ { "water", 1 } }, holds(world, BAG))
      assert.are.same({ nil, "refused", "invalid" }, { inventory.discard(jane, bottle, 0, ops.new()) })
    end,
  },
  {
    name = "never acts on another stack of the same item that shifted into an old index",
    run = function(world)
      local jane, sam = playing(world)
      local inventory, ops = world.api.inventory, world.api.ops
      -- The screen was drawn with the plain water at 1 and the bottle at 2.
      local water = ref(world, BAG, 1, "water")
      assert.is_true(inventory.discard(jane, water, 3, ops.new()))
      assert.are.same({ { "water", 1, "for Sam" } }, holds(world, BAG), "the bottle is at 1 now")
      local before = everything(world)
      assert.are.same({ nil, "refused", "stale" }, { inventory.discard(jane, water, 1, ops.new()) })
      assert.are.same({ nil, "refused", "stale" }, { inventory.hand(jane, sam, water, 1, ops.new()) })
      assert.are.same({ nil, "refused", "stale" }, { inventory.move(jane, water, CASE, ops.new()) })
      assert.are.same(before, everything(world), "the bottle is where it was")
    end,
  },
  {
    name = "hands a stack to another player whole, or not at all",
    run = function(world)
      local jane, sam = playing(world)
      local inventory, ops = world.api.inventory, world.api.ops
      local bottle = ref(world, BAG, 2, "water", { note = "for Sam" })
      local op = ops.new()
      assert.is_true(inventory.hand(jane, sam, bottle, 1, op))
      assert.is_true(inventory.hand(jane, sam, bottle, 1, op), "once per op id")
      assert.are.same({ { "water", 3 } }, holds(world, BAG))
      assert.are.same({ { "bread", 1 }, { "water", 1, "for Sam" } }, holds(world, SAM_BAG), "the note went with it")
      local water = ref(world, BAG, 1, "water")
      assert.are.same({ nil, "refused", "no_target" }, { inventory.hand(jane, jane, water, 1, ops.new()) })
      assert.are.same({ nil, "refused", "no_target" }, { inventory.hand(jane, 9, water, 1, ops.new()) })
      assert.are.same({ nil, "refused", "no_target" }, { inventory.hand(jane, nil, water, 1, ops.new()) })
      assert.are.same({ nil, "refused", "insufficient" }, { inventory.hand(jane, sam, water, 4, ops.new()) })
      world:settle()
      local stacks = world.portal.owned[SAM_BAG].data.contents.stacks
      assert.are.same({ "water", "for Sam" }, { stacks[2].item, stacks[2].data.note }, "the portal has it in Sam's bag")
    end,
  },
  {
    name = "hands nothing over when the other player has no room",
    run = function(world)
      local jane, sam = playing(world, 3)
      local water = ref(world, BAG, 1, "water")
      assert.are.same(
        { nil, "refused", "no_space" },
        { world.api.inventory.hand(jane, sam, water, 2, world.api.ops.new()) }
      )
      assert.are.same({ { "water", 3 }, { "water", 1, "for Sam" } }, holds(world, BAG), "nothing left Jane")
      assert.are.same({ { "bread", 1 } }, holds(world, SAM_BAG))
    end,
  },
  {
    name = "hands cash to another player once per op id, as one ledger entry",
    run = function(world)
      local jane, sam = playing(world)
      local money, ops = world.api.money, world.api.ops
      assert.is_true(money.supports("transfer"))
      local op = ops.new()
      assert.is_true(money.transfer(jane, sam, "wallet", 30, "Cash from Jane", op))
      assert.is_true(money.transfer(jane, sam, "wallet", 30, "Cash from Jane", op), "the same op again answers as before")
      assert.are.same({ 70, 35 }, { money.balance(jane, "wallet"), money.balance(sam, "wallet") }, "and pays once")
      assert.are.same(
        { nil, "refused", "insufficient_funds" },
        { money.transfer(jane, sam, "wallet", 500, "Car", ops.new()) }
      )
      assert.are.same({ nil, "refused", "no_account" }, { money.transfer(jane, sam, "bank", 1, "x", ops.new()) })
      assert.are.same({ nil, "refused", "no_target" }, { money.transfer(jane, jane, "wallet", 1, "x", ops.new()) })
      assert.are.same({ nil, "refused", "no_target" }, { money.transfer(jane, 9, "wallet", 1, "x", ops.new()) })
      assert.are.same({ nil, "refused", "invalid" }, { money.transfer(jane, sam, "wallet", 0, "x", ops.new()) })
      assert.are.same({ nil, "refused", "not_logged_in" }, { money.transfer(9, sam, "wallet", 1, "x", ops.new()) })
      world:settle()
      local entries = reported(world, "Cash from Jane")
      assert.are.equal(1, #entries, "one ledger entry reached the portal")
      assert.are.same({ WALLET, SAM_WALLET, 30 }, { entries[1].from_account, entries[1].to_account, entries[1].amount })
    end,
  },
  {
    name = "keeps who received a hand-over with an unknown one, for staff",
    run = function(world)
      local jane, sam = playing(world)
      local api = world.api
      -- The move underneath throws part way: the journal cannot say whether
      -- the bottle moved, so staff must, and they need to know to whom.
      local move = world.core.inventory.move
      world.core.inventory.move = function()
        error("the disk went away")
      end
      local op = api.ops.new()
      assert.are.same({ nil, "unknown" }, { api.inventory.hand(jane, sam, ref(world, BAG, 2, "water", { note = "for Sam" }), 1, op) })
      world.core.inventory.move = move
      local unknown = api.ops.unknown()
      assert.are.equal(1, #unknown)
      assert.are.equal("inventory.hand", unknown[1].call)
      assert.are.same({ player = PLAYER, to = SAM_PLAYER, item = "water", count = 1 }, unknown[1].detail)
    end,
  },
  {
    name = "uses a stack once per op id, taking what its handler used up from that stack",
    run = function(world)
      local given = {}
      local jane = playing(world, nil, {
        {
          manifest = food("acme_food"),
          start = function()
            assert(world.api.inventory.on_use("water", function(player, stack)
              given[#given + 1] = { player.player_id, stack.index, stack.count, stack.data and stack.data.note }
              return true, 1
            end))
          end,
        },
      })
      local inventory, ops = world.api.inventory, world.api.ops
      assert.is_true(inventory.usable("water"))
      assert.is_false(inventory.usable("bread"))
      assert.is_true(inventory.supports("use"))
      local bag = assert(inventory.containers(jane))[1]
      assert.are.same({ true, true }, { bag.stacks[1].usable, bag.stacks[2].usable })
      local op = ops.new()
      local bottle = ref(world, BAG, 2, "water", { note = "for Sam" })
      assert.is_true(inventory.use(jane, bottle, op))
      assert.is_true(inventory.use(jane, bottle, op), "the same op again answers as before")
      assert.are.same({ { PLAYER, 2, 1, "for Sam" } }, given, "and runs the handler once, with the stack picked")
      assert.are.same({ { "water", 3 } }, holds(world, BAG), "the bottle was used up, the plain water untouched")
      assert.is_true(inventory.use(jane, ref(world, BAG, 1, "water"), ops.new()))
      assert.are.same({ { "water", 2 } }, holds(world, BAG))
      assert.are.same(
        { nil, "refused", "no_use" },
        { inventory.use(jane, ref(world, CASE, 1, "bread"), ops.new()) },
        "bread has no use"
      )
      world:settle()
      assert.are.equal(2, world.portal.owned[BAG].data.contents.stacks[1].count, "the portal has what is left")
    end,
  },
  {
    name = "takes nothing when the handler declines, and passes on its message",
    run = function(world)
      local jane = playing(world, nil, {
        {
          manifest = food("acme_food"),
          start = function()
            assert(world.api.inventory.on_use("water", function()
              return false, "You are not thirsty."
            end))
          end,
        },
      })
      local inventory = world.api.inventory
      local op = world.api.ops.new()
      local water = ref(world, BAG, 1, "water")
      assert.are.same({ nil, "refused", "declined", "You are not thirsty." }, { inventory.use(jane, water, op) })
      assert.are.same({ nil, "refused", "declined" }, { inventory.use(jane, water, op) }, "a repeat answers without it")
      assert.are.same({ { "water", 3 }, { "water", 1, "for Sam" } }, holds(world, BAG))
    end,
  },
  {
    name = "never runs a handler for another character's stack",
    run = function(world)
      local ran = 0
      local jane, sam = playing(world, nil, {
        {
          manifest = food("acme_food"),
          start = function()
            assert(world.api.inventory.on_use("bread", function()
              ran = ran + 1
              return true, 1
            end))
          end,
        },
      })
      local op = world.api.ops.new()
      assert.are.same(
        { nil, "refused", "not_found" },
        { world.api.inventory.use(jane, ref(world, SAM_BAG, 1, "bread"), op) }
      )
      assert.is_nil(world.api.ops.result(op), "not journaled")
      assert.are.equal(0, ran)
      assert.is_true(world.api.inventory.use(sam, ref(world, SAM_BAG, 1, "bread"), world.api.ops.new()))
      assert.are.same({}, holds(world, SAM_BAG), "Sam may eat his own")
    end,
  },
  {
    name = "is unknown, for staff, when the handler throws or answers more than the stack holds",
    run = function(world)
      local answer = nil
      local jane = playing(world, nil, {
        {
          manifest = food("acme_food"),
          start = function()
            assert(world.api.inventory.on_use("water", function()
              if not answer then
                error("no cups left")
              end
              return true, answer
            end))
          end,
        },
      })
      local inventory, ops = world.api.inventory, world.api.ops
      local bottle = ref(world, BAG, 2, "water", { note = "for Sam" })
      assert.are.same({ nil, "unknown" }, { inventory.use(jane, bottle, ops.new()) })
      answer = 2
      assert.are.same({ nil, "unknown" }, { inventory.use(jane, bottle, ops.new()) })
      assert.are.same({ { "water", 3 }, { "water", 1, "for Sam" } }, holds(world, BAG), "nothing was taken")
      local unknown = ops.unknown()
      assert.are.equal(2, #unknown)
      assert.are.same({ "inventory.use", "inventory.use" }, { unknown[1].call, unknown[2].call })
      local causes = unknown[1].cause .. "\n" .. unknown[2].cause
      assert.truthy(causes:find("no cups left", 1, true), causes)
      assert.truthy(causes:find("used 2 of 1", 1, true), causes)
    end,
  },
  {
    name = "keeps one handler per item, and drops it when its addon stops",
    run = function(world)
      local mine, theirs = food("acme_food"), food("acme_drinks")
      local jane = playing(world, nil, {
        {
          manifest = mine,
          start = function()
            assert(world.api.inventory.on_use("water", function()
              return true
            end))
          end,
        },
        { manifest = theirs, start = function() end },
      })
      local inventory, addons = world.api.inventory, world.core.addons
      assert.is_true(inventory.usable("water"))
      ---Registers a use for water as one of the addons' code would.
      ---@param namespace string The addon.
      ---@return table answer What `on_use` answered.
      local function as(namespace)
        return {
          select(2, addons.run(addons.context_of(namespace), inventory.on_use, "water", function()
            return true
          end)),
        }
      end
      assert.are.same({ nil, "taken" }, as("acme_drinks"), "another addon's item")
      assert.are.same({ true }, as("acme_food"), "its own, again, replaces it")
      assert.are.same({ nil, "invalid" }, { inventory.on_use("Water!", function() end) })
      assert.are.same({ nil, "forbidden" }, { inventory.on_use("bread", function() end) }, "not from outside an addon")
      world:install({ conformance.installed(world.core, theirs) }, config(world))
      world:pump()
      assert.are_not.equal("active", (world.api.addons.state("acme_food")))
      assert.is_false(inventory.usable("water"))
      assert.are.same({ nil, "refused", "no_use" }, { inventory.use(jane, ref(world, BAG, 1, "water"), world.api.ops.new()) })
      assert.are.same({ true }, as("acme_drinks"), "and the item is free for another")
    end,
  },
})
