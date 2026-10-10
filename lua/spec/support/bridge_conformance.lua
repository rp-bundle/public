---The shared bridge conformance suite (K2): the cases every bridge to an
---existing RP framework must pass, against a fake of its framework, on
---every platform the conformance harness boots (`spec/support/conformance.lua`:
---the mock platform, and the real FiveM and Gmod adapters on their fake
---engine globals). The mock bridge runs it (`spec/conformance_bridge_spec.lua`);
---K3's Qbox bridge and K4's DarkRP bridge run it with their own fakes.
---
---A bridge brings a **kit** (`spec.BridgeKit`): how to make a fake of its
---framework, with a driver the cases act through (`spec.FrameworkDriver`),
---and how its own code registers the bridge. The cases then prove, through
---the public API only:
---
--- - activation on a companion server, the lifecycle through the
---   framework's own selection, and RPF's login gate coming first;
--- - every facade call the bridge supports, once per op id, with the
---   framework's refusals, and the ones it does not support refused without
---   reaching it;
--- - a framework that fails part way is `unknown`, and never run again;
--- - the framework's resource stopping and starting;
--- - a restart that cut a command off inside the framework call;
--- - a composite operation (hold and validate an addon's record, one intent,
---   the debit, the grant written to the outbox), where the debit is
---   refused, where it is unknown, and where the server dies between a
---   successful debit and the outbox write, which ends `unknown` for staff
---   with nothing compensated;
--- - the framework's key never reaching the portal.
---@class spec.bridge_conformance
local suite = {}

-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

local conformance = require("spec.support.conformance")
-- A module a spec requires sees Lua's own `assert`, not busted's.
local assert = require("luassert")

local PLAYER = "00000002-0000-4000-8000-000000000002"

---The companion profile: every domain the framework's.
local COMPANION = { characters = "external", money = "external", inventory = "external", jobs = "external" }

---What a bridge under test brings.
---@class spec.BridgeKit
---@field name string The bridge, for the test names.
---@field origin string Its resource's name, where the platform names the calling code (FiveM).
---@field framework fun(): spec.FrameworkDriver A fresh fake of its framework, running, with nobody loaded.
---@field register fun(api: table, fw: spec.FrameworkDriver): boolean?, string? Registers the bridge as its own code does, through the API as its resource sees it.
---@field accounts string[] The account names the bridge lists; the cases use the first two.
---@field item string? An item the framework knows, for the inventory cases; nil when the bridge supports no item call.
---@field job boolean Whether the bridge reads jobs.

---What the cases do to the framework: the same for every bridge's fake.
---Call names are the facade's (`money.debit`), whatever the framework's own.
---@class spec.FrameworkDriver
---@field seed fun(self, key: string, money: table<string, integer>?, items: table<string, integer>?, job: table?) A character the framework has.
---@field load fun(self, player: any, key: string, name: string) The player picks that character in the framework's own selection, and it loads.
---@field unload fun(self, player: any) Their character unloads.
---@field stop fun(self) The framework's resource stops (its characters unload).
---@field start fun(self) It starts again.
---@field balance fun(self, key: string, account: string): integer? A balance, as the framework holds it.
---@field count fun(self, key: string, item: string): integer A count, as the framework holds it.
---@field changes table<string, integer> How many times each facade call changed the framework's state.
---@field fail_next fun(self, call: string, how: "throw_after"|"unknown") The next call changes the state, then throws, or answers that it cannot say.
---@field inside_next fun(self, call: string, fn: fun()) Runs `fn` inside the next call, once it changed the state: where a crash goes.
---@field forget_listeners fun(self) The bridge's resource restarted: the event handlers its old code subscribed go.
---@field shown table<any, integer> How many times the framework's character selection was shown to each player.

---An addon a composite operation grants a record of: badges a player owns.
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

---Boots RPF on a companion profile, with the badges addon installed and the
---bridge registered by its own code.
---@param world spec.ConformanceWorld The world.
---@param kit spec.BridgeKit The bridge.
---@param fw spec.FrameworkDriver Its framework.
local function companion(world, kit, fw)
  local manifest = badges()
  assert(world.api.addons.register(manifest))
  assert(kit.register(world:as(kit.origin), fw))
  world:connect(COMPANION)
  world:install({ conformance.installed(world.core, manifest) })
  world:pump()
end

---A player logged in to RPF and playing their framework character.
---@param world spec.ConformanceWorld The world.
---@param fw spec.FrameworkDriver The framework.
---@param key string The character's key.
---@return any handle The engine's handle.
local function playing(world, fw, key)
  local handle = world:login(1, PLAYER)
  fw:load(handle, key, "Jane Doe")
  world:pump()
  return handle
end

---Restarts the game server over what storage held at one moment, and
---registers the bridge again, as its resource does when RPF's restarts.
---@param world spec.ConformanceWorld The world.
---@param kit spec.BridgeKit The bridge.
---@param fw spec.FrameworkDriver The framework.
---@param storage table<string, string>? Storage as it was; what it is now if nil.
local function restart(world, kit, fw, storage)
  fw:forget_listeners()
  world:restart(storage)
  local manifest = badges()
  assert(world.api.addons.register(manifest))
  assert(kit.register(world:as(kit.origin), fw))
  world:connect(COMPANION)
  world:install({ conformance.installed(world.core, manifest) })
  world:pump()
end

---Every case, for one bridge.
---@param kit spec.BridgeKit The bridge.
---@return { name: string, origins: boolean?, run: fun(world: spec.ConformanceWorld) }[] cases The cases.
function suite.cases(kit)
  local cash, bank = kit.accounts[1], kit.accounts[2] or kit.accounts[1]

  ---A fresh world's framework, with Jane in it.
  ---@return spec.FrameworkDriver fw The framework.
  local function framework()
    local fw = kit.framework()
    local money = {}
    money[cash] = 500
    money[bank] = 1000
    fw:seed("CIT-JANE", money, kit.item and { [kit.item] = 3 } or nil, kit.job and { name = "police", grade = 2, on_duty = true } or nil)
    return fw
  end

  return {
    {
      name = "is active on a companion server, and moves a player through the framework's own selection",
      run = function(world)
        local fw = framework()
        companion(world, kit, fw)
        local api = world.api
        local handle = world:login(1, PLAYER)
        assert.are.equal("character_select", api.players.get(handle).state, "the bridge's cue")
        assert.are.equal(1, fw.shown[handle], "and the framework's selection shown, once")
        assert.are.same({ nil, "no_character" }, { api.characters.current(handle) })
        fw:load(handle, "CIT-JANE", "Jane Doe")
        world:pump()
        assert.are.equal("active", api.players.get(handle).state)
        assert.are.same({ key = "CIT-JANE", name = "Jane Doe" }, api.characters.current(handle))
        assert.is_true(api.characters.supports("current"))
        fw:unload(handle)
        assert.are.equal("character_select", api.players.get(handle).state)
        assert.are.same({ nil, "no_character" }, { api.characters.current(handle) })
      end,
    },
    {
      name = "lets no framework character in before the player logged in to RPF",
      run = function(world)
        local fw = framework()
        companion(world, kit, fw)
        local handle = world.join(1)
        assert(world.core.players.authenticating(handle))
        assert.is_nil(fw.shown[handle], "no selection before the RPF login")
        fw:load(handle, "CIT-JANE", "Jane Doe")
        assert.are.equal("authenticating", world.api.players.get(handle).state)
        assert.are.same({ nil, "not_logged_in" }, { world.api.characters.current(handle) })
        assert.are.equal(1, world:logged("warn", "its login gate is not holding"))
      end,
    },
    {
      name = "reads money, items and the job through the framework",
      run = function(world)
        local fw = framework()
        companion(world, kit, fw)
        local api = world.api
        local handle = playing(world, fw, "CIT-JANE")
        assert.are.same(kit.accounts, api.money.accounts())
        assert.are.equal(500, api.money.balance(handle, cash))
        assert.are.same({ nil, "not_found" }, { api.money.balance(handle, "no_such_account") })
        if kit.item then
          assert.are.equal(3, api.inventory.count(handle, kit.item))
        end
        if kit.job then
          local job = api.jobs.current(handle)
          assert.are.equal("police", job.name)
          assert.are.equal(2, job.grade)
        end
        assert.are.same({ nil, "not_logged_in" }, { api.money.balance(9, cash) })
      end,
    },
    {
      name = "moves money and items once per op id, with the framework's own refusals",
      run = function(world)
        local fw = framework()
        companion(world, kit, fw)
        local api = world.api
        local handle = playing(world, fw, "CIT-JANE")
        local op = api.ops.new()
        assert.is_true(api.money.debit(handle, cash, 200, "Spray can", op))
        assert.is_true(api.money.debit(handle, cash, 200, "Spray can", op), "the same op again")
        assert.are.equal(300, fw:balance("CIT-JANE", cash))
        assert.are.equal(1, fw.changes["money.debit"])
        assert.are.same({ nil, "refused", "insufficient_funds" }, { api.money.debit(handle, cash, 5000, "Car", api.ops.new()) })
        assert.are.equal(300, fw:balance("CIT-JANE", cash))
        assert.is_true(api.money.credit(handle, bank, 50, "Refund", api.ops.new()))
        assert.are.equal(1050, fw:balance("CIT-JANE", bank))
        -- Arguments are RPF's rules on both paths: never reach the framework.
        local max = world.core.protocol.MAX_AMOUNT
        for _, amount in ipairs({ 0, -5, 1.5, max + 1 }) do
          assert.are.same({ nil, "refused", "invalid" }, { api.money.debit(handle, cash, amount, "x", api.ops.new()) })
        end
        assert.are.equal(1, fw.changes["money.debit"])
        if kit.item then
          assert.is_true(api.inventory.give(handle, kit.item, 2, api.ops.new()))
          assert.are.equal(5, fw:count("CIT-JANE", kit.item))
          assert.is_true(api.inventory.take(handle, kit.item, 4, api.ops.new()))
          assert.are.same({ nil, "refused", "insufficient" }, { api.inventory.take(handle, kit.item, 9, api.ops.new()) })
          assert.are.equal(1, fw:count("CIT-JANE", kit.item))
        else
          assert.are.same({ nil, "refused", "unsupported" }, { api.inventory.give(handle, "water", 1, api.ops.new()) })
        end
      end,
    },
    {
      name = "is unknown when the framework fails part way, for staff, and never runs it again",
      run = function(world)
        local fw = framework()
        companion(world, kit, fw)
        local api = world.api
        local handle = playing(world, fw, "CIT-JANE")
        local threw, unsure = api.ops.new(), api.ops.new()
        fw:fail_next("money.debit", "throw_after")
        assert.are.same({ nil, "unknown" }, { api.money.debit(handle, cash, 100, "Car", threw) })
        fw:fail_next("money.debit", "unknown")
        assert.are.same({ nil, "unknown" }, { api.money.debit(handle, cash, 100, "Car", unsure) })
        assert.are.equal(2, fw.changes["money.debit"])
        assert.are.same({ nil, "unknown" }, { api.money.debit(handle, cash, 100, "Car", threw) })
        assert.are.same({ nil, "unknown" }, { api.money.debit(handle, cash, 100, "Car", unsure) })
        assert.are.equal(2, fw.changes["money.debit"], "never again")
        assert.are.equal(300, fw:balance("CIT-JANE", cash), "and nothing compensated")
        local listed = api.ops.unknown()
        assert.are.equal(2, #listed)
        for _, unknown in ipairs(listed) do
          assert.are.equal(PLAYER, unknown.detail.player)
          assert.are.equal(100, unknown.detail.amount)
        end
      end,
    },
    {
      name = "answers unavailable while the framework is stopped, and takes players back when it starts",
      run = function(world)
        local fw = framework()
        companion(world, kit, fw)
        local api = world.api
        local handle = playing(world, fw, "CIT-JANE")
        fw:stop()
        assert.are.equal("character_select", api.players.get(handle).state, "the framework unloaded them")
        local op = api.ops.new()
        assert.are.same({ nil, "unavailable" }, { api.money.debit(handle, cash, 10, "x", op) })
        assert.are.same({ nil, "unavailable" }, { api.money.balance(handle, cash) })
        assert.is_true(api.money.supports("debit"), "what it can do has not changed")
        assert.is_nil(fw.changes["money.debit"])
        fw:start()
        fw:load(handle, "CIT-JANE", "Jane Doe")
        assert.are.equal("active", api.players.get(handle).state)
        assert.is_true(api.money.debit(handle, cash, 10, "x", op), "the same op id goes once it is back")
        assert.are.equal(490, fw:balance("CIT-JANE", cash))
      end,
    },
    {
      name = "turns a command a restart cut off inside the framework into unknown, and never runs it again",
      run = function(world)
        local fw = framework()
        companion(world, kit, fw)
        local api = world.api
        local handle = playing(world, fw, "CIT-JANE")
        local op = api.ops.new()
        local disk
        fw:inside_next("money.debit", function()
          disk = world:snapshot()
        end)
        assert.is_true(api.money.debit(handle, cash, 120, "Car", op))
        restart(world, kit, fw, disk)
        assert.are.equal(1, world:logged("error", "cut off by a restart"))
        api = world.api
        assert.are.same({ nil, "unknown" }, { api.money.debit(handle, cash, 120, "Car", op) })
        assert.are.equal(1, fw.changes["money.debit"], "charged once")
        assert.are.equal(380, fw:balance("CIT-JANE", cash))
        local listed = api.ops.unknown()
        assert.are.equal(1, #listed)
        assert.are.equal(op, listed[1].op_id)
        assert.are.equal("Car", listed[1].detail.reason)
      end,
    },
    {
      name = "pays for an addon's record in one intent, which completes once the grant is in the outbox",
      run = function(world)
        local fw = framework()
        companion(world, kit, fw)
        local api = world.api
        local handle = playing(world, fw, "CIT-JANE")
        local owner = { owner = { kind = "player", id = PLAYER } }
        local badge = assert(api.records.create("acme_badges.badge", { label = "Bronze" }, owner))
        world:settle()
        -- Hold and validate first: the record is this server's, at a
        -- revision known, and the change passes its type's rules.
        local held = assert(api.records.get("acme_badges.badge", badge.id))
        local op = api.ops.new()
        local granted = 0
        assert.is_true(api.money.debit(handle, bank, 100, "Silver badge", op, function()
          granted = granted + 1
          return api.records.update("acme_badges.badge", held.id, { label = "Silver" }, { revision = held.revision })
        end))
        world:settle()
        assert.are.equal("Silver", world.portal.records[badge.id].fields.label)
        assert.are.equal(900, fw:balance("CIT-JANE", bank))
        assert.is_true(api.money.debit(handle, bank, 100, "Silver badge", op, function()
          granted = granted + 1
          return true
        end))
        assert.are.equal(1, granted)
        assert.are.equal(1, fw.changes["money.debit"])
      end,
    },
    {
      name = "grants nothing when the debit is refused, and nothing when it is unknown, refunding nothing",
      run = function(world)
        local fw = framework()
        companion(world, kit, fw)
        local api = world.api
        local handle = playing(world, fw, "CIT-JANE")
        local badge = assert(api.records.create("acme_badges.badge", { label = "Bronze" }, { owner = { kind = "player", id = PLAYER } }))
        world:settle()
        local granted = 0
        ---The grant: never reached here.
        ---@return table? record The record.
        local function grant()
          granted = granted + 1
          return api.records.update("acme_badges.badge", badge.id, { label = "Gold" })
        end
        assert.are.same({ nil, "refused", "insufficient_funds" }, { api.money.debit(handle, bank, 99999, "Gold badge", api.ops.new(), grant) })
        fw:fail_next("money.debit", "throw_after")
        assert.are.same({ nil, "unknown" }, { api.money.debit(handle, bank, 300, "Gold badge", api.ops.new(), grant) })
        world:settle()
        assert.are.equal(0, granted)
        assert.are.equal("Bronze", world.portal.records[badge.id].fields.label)
        assert.are.equal(700, fw:balance("CIT-JANE", bank), "charged, and not refunded: staff resolve it")
        assert.is_nil(fw.changes["money.credit"])
        assert.are.equal(1, #api.ops.unknown())
      end,
    },
    {
      name = "ends unknown for staff when the server dies between the debit and the grant's outbox write",
      run = function(world)
        local fw = framework()
        companion(world, kit, fw)
        local api = world.api
        local handle = playing(world, fw, "CIT-JANE")
        local badge = assert(api.records.create("acme_badges.badge", { label = "Bronze" }, { owner = { kind = "player", id = PLAYER } }))
        world:settle()
        local op = api.ops.new()
        local disk
        assert.is_true(api.money.debit(handle, bank, 100, "Silver badge", op, function()
          local record = api.records.update("acme_badges.badge", badge.id, { label = "Silver" })
          -- The grant is made in memory, not yet in the outbox: the server
          -- dies here.
          disk = world:snapshot()
          return record
        end))
        restart(world, kit, fw, disk)
        world:settle()
        api = world.api
        assert.are.equal(1, world:logged("error", "cut off by a restart"))
        assert.are.equal("Bronze", world.portal.records[badge.id].fields.label, "the grant was lost")
        assert.are.equal(900, fw:balance("CIT-JANE", bank), "the debit was not: nothing compensates")
        assert.is_nil(fw.changes["money.credit"])
        local listed = api.ops.unknown()
        assert.are.equal(1, #listed)
        assert.are.same({ op, "Silver badge" }, { listed[1].op_id, listed[1].detail.reason })
        assert.are.same({ nil, "unknown" }, {
          api.money.debit(handle, bank, 100, "Silver badge", op, function()
            return true
          end),
        })
        assert.are.equal(1, fw.changes["money.debit"])
      end,
    },
    {
      name = "keeps the framework's key on the game server",
      run = function(world)
        local fw = framework()
        companion(world, kit, fw)
        local api = world.api
        local handle = playing(world, fw, "CIT-JANE")
        api.money.debit(handle, cash, 10, "x", api.ops.new())
        fw:fail_next("money.debit", "unknown")
        api.money.debit(handle, cash, 10, "x", api.ops.new())
        api.records.create("acme_badges.badge", { label = "Bronze" }, { owner = { kind = "player", id = PLAYER } })
        world:settle()
        for _, sent in ipairs(world.sent) do
          assert.is_nil(sent.text:find("CIT-JANE", 1, true), "a frame carries the key")
        end
        for _, line in ipairs(world.logs) do
          assert.is_nil(line.message:find("CIT-JANE", 1, true), "a log line carries the key")
        end
      end,
    },
    {
      name = "withdraws the bridge when its resource stops, and takes it back when it starts",
      origins = true,
      run = function(world)
        local fw = framework()
        companion(world, kit, fw)
        local api = world.api
        local handle = playing(world, fw, "CIT-JANE")
        fw:forget_listeners()
        world:unload(kit.origin)
        assert.are.equal("character_select", api.players.get(handle).state)
        assert.are.same({ nil, "unavailable" }, { api.money.balance(handle, cash) })
        -- The character unloads with the bridge gone, as when the
        -- framework's own resource restarts with it.
        fw:unload(handle)
        local before = fw.shown[handle] or 0
        assert.is_true(kit.register(world:as(kit.origin), fw))
        assert.are.equal(before + 1, fw.shown[handle], "the player still choosing is shown the selection again")
        fw:load(handle, "CIT-JANE", "Jane Doe")
        assert.are.equal("active", api.players.get(handle).state)
        assert.are.equal(500, api.money.balance(handle, cash))
      end,
    },
  }
end

---Runs every case for a bridge on every platform.
---@param busted spec.Busted The spec file's busted functions.
---@param kit spec.BridgeKit The bridge.
function suite.run(busted, kit)
  conformance.run(busted, "the " .. kit.name .. " bridge", suite.cases(kit))
end

return suite
