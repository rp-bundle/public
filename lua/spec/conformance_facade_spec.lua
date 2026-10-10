-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Conformance (J3): the domain-neutral facade (`rpf.api.characters`,
-- `money`, `inventory`, `jobs`, `ops`) on an RPF server, the same cases on
-- the mock platform and on the real FiveM and Gmod adapters, against a fake
-- portal (`spec/support/conformance.lua`). A player logs in and puts a
-- character in play; an addon reads their character, money, items and job,
-- and moves money and items, each command once per op id, and pays for a
-- change to its own records in one intent (a composite operation).

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

---An addon that sells badges: a live type a player owns.
---@return table manifest The manifest.
local function badges()
  return {
    namespace = "acme_badges",
    version = "1.0.0",
    api = 1,
    title = "Badges",
    types = {
      badge = {
        schema = 1,
        authority = "live",
        owners = { "player" },
        fields = { label = { type = "string", max_len = 24, required = true } },
      },
    },
  }
end

---A world with Jane in play and the badges addon active.
---@param world spec.ConformanceWorld The world.
---@return any handle Her engine handle.
local function selling(world)
  seed(world)
  local manifest = badges()
  assert(world.api.addons.register(manifest))
  world:connect()
  world:install({ conformance.installed(world.core, manifest) }, config(world))
  world:pump()
  assert.are.equal("active", (world.api.addons.state("acme_badges")))
  local handle = world:login(1, PLAYER)
  world:select(handle, JANE)
  return handle
end

---The journal's entry for an op, as storage holds it.
---@param world spec.ConformanceWorld The world.
---@param op string The op id.
---@return table entry The entry, decoded.
local function stored(world, op)
  local key = world.core.ops.ENTRY_PREFIX .. op
  return world.core.json.decode(assert(world.server_platform.kv_get(key)))
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
    name = "records a payment as done only once its ledger entry is on its way to the portal",
    run = function(world)
      local handle = playing(world)
      local op = world.api.ops.new()
      -- The outbox has no room: the entry is made here, but not queued.
      local options = world.core.connection.options
      local entries = options.max_entries
      options.max_entries = 0
      assert.is_true(world.api.money.debit(handle, "wallet", 10, "Tag", op))
      local key = world.core.ops.ENTRY_PREFIX .. op
      local stored = world.core.json.decode(assert(world.server_platform.kv_get(key)))
      assert.are.equal("pending", stored.state, "a crash now would read it as unknown")
      options.max_entries = entries
      world:advance(1000)
      stored = world.core.json.decode(assert(world.server_platform.kv_get(key)))
      assert.are.equal("done", stored.state)
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
  {
    name = "pays for an addon's change in one intent, which completes once the change is on its way",
    run = function(world)
      local handle = selling(world)
      local api = world.api
      local applied, op = 0, api.ops.new()
      ---@type { id: string }?
      local badge = nil
      ---The badge the debit pays for.
      ---@return table? record The badge.
      local function grant()
        applied = applied + 1
        -- Not on its way to the portal yet: a crash now loses the badge and
        -- has taken the money, so the intent must still be pending on disk.
        assert.are.equal("pending", stored(world, op).state)
        badge = api.records.create("acme_badges.badge", { label = "Gold" }, { owner = { kind = "player", id = PLAYER } })
        return badge
      end
      -- The outbox has no room yet, so the badge's create stays in memory.
      local options = world.core.connection.options
      local entries = options.max_entries
      options.max_entries = 0
      assert.is_true(api.money.debit(handle, "wallet", 40, "Gold badge", op, grant))
      assert.are.equal(1, applied)
      assert.are.equal(60, api.money.balance(handle, "wallet"))
      local made = assert(badge)
      assert.are.equal("Gold", assert(api.records.get("acme_badges.badge", made.id)).fields.label)
      assert.are.equal("pending", stored(world, op).state, "the badge is not on disk yet")
      options.max_entries = entries
      world:advance(1000)
      assert.are.equal("done", stored(world, op).state)
      assert.is_true(api.money.debit(handle, "wallet", 40, "Gold badge", op, grant), "a repeat answers as before")
      assert.are.equal(1, applied, "and neither pays nor grants again")
      assert.are.equal(60, api.money.balance(handle, "wallet"))
      world:settle()
      assert.are.equal("Gold", world.portal.records[made.id].fields.label)
    end,
  },
  {
    name = "never runs the change when the payment is refused",
    run = function(world)
      local handle = selling(world)
      local api = world.api
      local applied = false
      assert.are.same(
        { nil, "refused", "insufficient_funds" },
        {
          api.money.debit(handle, "wallet", 500, "Car", api.ops.new(), function()
            applied = true
            return true
          end),
        }
      )
      assert.is_false(applied)
      assert.are.same({ nil, "refused", "invalid" }, { api.money.debit(handle, "wallet", 1, "x", api.ops.new(), 42) })
      assert.are.same({}, api.ops.unknown())
    end,
  },
  {
    name = "is unknown, for staff, when the change it paid for fails, and refunds nothing",
    run = function(world)
      local handle = selling(world)
      local api = world.api
      local seen = {}
      api.events.on("domains.op_unknown", function(unknown)
        seen[#seen + 1] = unknown
      end)
      local answered, threw = api.ops.new(), api.ops.new()
      assert.are.same({ nil, "unknown" }, {
        api.money.debit(handle, "wallet", 10, "Badge", answered, function()
          return nil, "limit"
        end),
      })
      assert.are.same({ nil, "unknown" }, {
        api.inventory.take(handle, "water", 1, threw, function()
          error("no badge for you")
        end),
      })
      assert.are.equal(90, api.money.balance(handle, "wallet"), "the money moved, and stays moved")
      assert.are.equal(2, api.inventory.count(handle, "water"))
      local listed = api.ops.unknown()
      assert.are.equal(2, #listed)
      local by_op, heard = {}, {}
      for i, unknown in ipairs(listed) do
        by_op[unknown.op_id] = unknown
        heard[seen[i].op_id] = seen[i]
      end
      assert.are.same(by_op, heard, "what was announced is what is listed")
      assert.are.same(
        { player = PLAYER, account = "wallet", amount = 10, reason = "Badge" },
        by_op[answered].detail
      )
      assert.are.equal("money.debit", by_op[answered].call)
      assert.are.same({ player = PLAYER, item = "water", count = 1 }, by_op[threw].detail)
      assert.truthy(by_op[threw].cause:find("no badge for you", 1, true))
      assert.are.equal(1, world:logged("error", answered))
      assert.are.same({ nil, "unknown" }, { api.money.debit(handle, "wallet", 10, "Badge", answered) })
    end,
  },
})
