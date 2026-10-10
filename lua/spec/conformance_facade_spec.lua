-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Conformance (J3): the domain-neutral facade (`rpf.api.characters`,
-- `money`, `inventory`, `jobs`, `ops`) on an RPF server, the same cases on
-- the mock platform and on the real FiveM and Gmod adapters, against a fake
-- portal (`spec/support/conformance.lua`). A player logs in and puts a
-- character in play; an addon reads their character, money, items and job,
-- and moves money and items, each command once per op id.

local conformance = require("spec.support.conformance")

---What `conformance.run` needs from busted.
local busted = { describe = describe, it = it, before_each = before_each, after_each = after_each }

local SERVER = "00000001-0000-4000-8000-000000000001"
local PLAYER = "00000002-0000-4000-8000-000000000002"
local JANE = "00000004-0000-4000-8000-000000000004"
local WALLET = "00000005-0000-4000-8000-000000000005"
local BANK = "00000006-0000-4000-8000-000000000006"
local TILL = "00000007-0000-4000-8000-000000000007"
local BAG = "00000008-0000-4000-8000-000000000008"
local POCKETS = "00000009-0000-4000-8000-000000000009"

---The portal's copies of Jane, her accounts and containers, and the
---server's till.
---@param world spec.ConformanceWorld The world.
---@param pockets_weight integer? The pockets' weight limit.
local function seed(world, pockets_weight)
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
      job = { employer = "lspd", job = "officer" },
    },
  }
  ---An account.
  ---@param id string Its id.
  ---@param owner table Its owner.
  ---@param name string Its name.
  ---@param balance integer Its balance.
  ---@param flags table Its flags.
  local function account(id, owner, name, balance, flags)
    owned[id] = {
      kind = "account",
      revision = 1,
      balance = balance,
      data = { id = id, server_id = SERVER, owner = owner, name = name, flags = json.array(flags) },
    }
  end
  account(WALLET, jane, "wallet", 100, {})
  account(BANK, jane, "bank", 0, {})
  account(TILL, { kind = "server", id = SERVER }, "till", 0, { "unlimited_balance" })
  ---A container.
  ---@param id string Its id.
  ---@param name string Its name.
  ---@param stacks table[] What it holds.
  ---@param flags table[] Its flags.
  local function container(id, name, stacks, flags)
    owned[id] = {
      kind = "container",
      revision = 1,
      data = {
        id = id,
        server_id = SERVER,
        owner = jane,
        name = name,
        contents = json.object({ layout = "list", stacks = json.array(stacks) }),
        flags = json.array(flags),
      },
    }
  end
  container(BAG, "Bag", { { item = "water", count = 1 } }, {})
  container(POCKETS, "Pockets", {
    { item = "water", count = 2 },
    { item = "water", count = 1, data = json.object({ note = "for Sam" }) },
  }, { json.object({ flag = "max_weight", value = pockets_weight or 50 }) })
end

---The config: Jane's starting accounts, the till as the addon account, and
---her job.
---@param world spec.ConformanceWorld The world.
---@param addon_account string|false? The setting's value; `till` unless given, `false` for none.
---@return table extra The snapshot's sections.
local function config(world, addon_account)
  local json = world.core.json
  local settings = json.object({})
  if addon_account ~= false then
    settings["economy.addon_account"] = addon_account or "till"
  end
  return {
    settings = settings,
    paying_accounts = json.array({ { id = TILL, name = "till" } }),
    new_character = json.object({
      accounts = json.array({ { name = "wallet", amount = 0 }, { name = "bank", amount = 0 } }),
    }),
    employers = json.array({ { slug = "lspd", name = "LSPD", description = "" } }),
    employer_jobs = json.array({
      { employer = "lspd", slug = "officer", name = "Officer", description = "", rank = 10 },
    }),
  }
end

---A world with Jane logged in and in play.
---@param world spec.ConformanceWorld The world.
---@param addon_account string|false? As for `config`.
---@param pockets_weight integer? As for `seed`.
---@return any handle Her engine handle.
local function playing(world, addon_account, pockets_weight)
  seed(world, pockets_weight)
  world:connect()
  world:install({}, config(world, addon_account))
  world:pump()
  local handle = world:login(1, PLAYER)
  world:select(handle, JANE)
  return handle
end

conformance.run(busted, "the facade", {
  {
    name = "gives the character a player has in play, and why there is none",
    run = function(world)
      seed(world)
      world:connect()
      world:install({}, config(world))
      local api = world.api
      assert.are.same({ nil, "not_logged_in" }, { api.characters.current(9) })
      local handle = world:login(1, PLAYER)
      assert.are.same({ nil, "no_character" }, { api.characters.current(handle) })
      world:select(handle, JANE)
      assert.are.same({ key = JANE, name = "Jane Doe" }, api.characters.current(handle))
      assert.is_true(api.characters.supports("current"))
      assert.is_false(api.characters.supports("create"))
    end,
  },
  {
    name = "reads money by account name",
    run = function(world)
      local handle = playing(world)
      local money = world.api.money
      assert.are.same({ "wallet", "bank" }, money.accounts())
      assert.are.equal(100, money.balance(handle, "wallet"))
      assert.are.same({ nil, "not_found" }, { money.balance(handle, "crypto") })
      assert.is_true(money.supports("debit"))
    end,
  },
  {
    name = "debits and credits once per op id, through the addon account",
    run = function(world)
      local handle = playing(world)
      local money, ops = world.api.money, world.api.ops
      local op = assert(ops.new())
      assert.is_true(money.debit(handle, "wallet", 30, "Spray can", op))
      assert.is_true(money.debit(handle, "wallet", 30, "Spray can", op), "the same op again answers as before")
      assert.are.equal(70, money.balance(handle, "wallet"), "and is not paid twice")
      assert.are.equal(30, world.core.accounts.balance(TILL))
      assert.are.same(
        { nil, "refused", "insufficient_funds" },
        { money.debit(handle, "wallet", 500, "Car", ops.new()) }
      )
      assert.is_true(money.credit(handle, "bank", 12, "Refund", ops.new()))
      assert.are.equal(12, money.balance(handle, "bank"))
      assert.are.same({ nil, "refused", "no_account" }, { money.debit(handle, "crypto", 1, "x", ops.new()) })
      assert.are.same({ nil, "refused", "invalid" }, { money.debit(handle, "wallet", 0, "x", ops.new()) })
      assert.are.same({ nil, "refused", "invalid" }, { money.debit(handle, "wallet", 1.5, "x", ops.new()) })
      assert.are.same({ nil, "refused", "invalid_op" }, { money.debit(handle, "wallet", 1, "x", "my-op") })
      assert.are.same({ nil, "refused", "not_logged_in" }, { money.debit(9, "wallet", 1, "x", ops.new()) })
      world:settle()
      assert.are.equal(70, money.balance(handle, "wallet"))
    end,
  },
  {
    name = "refuses an op id older than a day, and says debits are unsupported without an addon account",
    run = function(world)
      local handle = playing(world, false)
      local money = world.api.money
      assert.is_false(money.supports("debit"))
      assert.is_false(money.supports("credit"))
      assert.is_true(money.supports("balance"))
      local op = world.api.ops.new()
      assert.are.same({ nil, "refused", "unsupported" }, { money.debit(handle, "wallet", 1, "x", op) })
      world:advance(24 * 60 * 60 * 1000 + 1)
      assert.are.same({ nil, "refused", "expired_op" }, { money.debit(handle, "wallet", 1, "x", op) })
    end,
  },
  {
    name = "counts, gives and takes plain units across a character's containers",
    run = function(world)
      local handle = playing(world)
      local inventory, ops = world.api.inventory, world.api.ops
      assert.are.equal(3, inventory.count(handle, "water"), "the bottle with a note is not a plain one")
      assert.is_true(inventory.give(handle, "water", 2, ops.new()))
      assert.are.equal(5, inventory.count(handle, "water"))
      local op = ops.new()
      assert.is_true(inventory.take(handle, "water", 4, op))
      assert.is_true(inventory.take(handle, "water", 4, op), "once per op id")
      assert.are.equal(1, inventory.count(handle, "water"))
      assert.are.same({ nil, "refused", "insufficient" }, { inventory.take(handle, "water", 2, ops.new()) })
      assert.are.same({ nil, "refused", "invalid" }, { inventory.give(handle, "water", 0, ops.new()) })
      assert.is_true(inventory.supports("give"))
    end,
  },
  {
    name = "refuses to give what no container takes",
    run = function(world)
      local handle = playing(world, nil, 3)
      local container = assert(world.core.records.get("container", BAG))
      container.flags = world.core.json.array({ world.core.json.object({ flag = "max_weight", value = 1 }) })
      world.core.records.entries["container:" .. BAG].data.flags = container.flags
      assert.are.same(
        { nil, "refused", "no_space" },
        { world.api.inventory.give(handle, "water", 10, world.api.ops.new()) }
      )
      assert.are.equal(3, world.api.inventory.count(handle, "water"))
    end,
  },
  {
    name = "takes nothing when a container on the way no longer passes its rules",
    run = function(world)
      local handle = playing(world)
      local json = world.core.json
      -- The pockets' contents break a rule they once kept (a limit lowered
      -- under them): what a take would leave there does not pass, though
      -- the bag, taken from first, would be fine.
      world.core.records.entries["container:" .. POCKETS].data.flags =
        json.array({ json.object({ flag = "max_weight", value = 0 }) })
      local _, status, why = world.api.inventory.take(handle, "water", 3, world.api.ops.new())
      assert.are.same({ "refused", "invalid_contents" }, { status, why })
      assert.are.equal(3, world.api.inventory.count(handle, "water"), "not one unit went")
    end,
  },
  {
    name = "gives a player's job",
    run = function(world)
      local handle = playing(world)
      assert.are.same(
        { name = "officer", employer = "lspd", grade = 10, on_duty = false },
        world.api.jobs.current(handle)
      )
      assert.is_true(world.api.jobs.supports("current"))
      assert.are.same({ nil, "not_logged_in" }, { world.api.jobs.current(9) })
    end,
  },
})
