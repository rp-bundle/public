-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The bridge contract (K2): what `rpf.bridge.register` accepts, when a
-- bridge becomes active, the lifecycle it reports, and the facade's calls
-- routed to it on a companion server, checked and journaled. The shared
-- conformance suite (`spec/support/bridge_conformance.lua`) proves a bridge
-- end to end on every engine; this is the core's side, case by case.

local support = require("spec.support")

local SERVER = "00000001-0000-4000-8000-000000000001"
local KEY = "CIT-4471"

---A fresh op id.
---@return string op_id The id.
local function op()
  return assert(rpf.api.ops.new())
end

---Answers the newest `Hello` with a `Welcome` naming `domains`.
---@param p spec.FakePlatform The platform, with an open socket.
---@param domains rpf.Domains The profile the portal adopted.
local function welcome(p, domains)
  local hello
  for _, frame in ipairs(p.frames()) do
    if frame.type == "hello" then
      hello = frame
    end
  end
  p.deliver(support.portal_frame("welcome", {
    re = hello.id,
    protocol = rpf.protocol.VERSION,
    server_id = SERVER,
    domains = domains,
  }))
  support.declared(p)
end

---A fake framework, and a bridge to it that records every call reaching it.
---@class spec.FakeFramework
---@field money table<any, table<string, integer>> Balances, by player handle then account.
---@field items table<any, table<string, integer>> Items, by player handle then item.
---@field jobs table<any, table> Jobs, by player handle.
---@field calls string[] Every bridge call that reached the framework, in order.
---@field running boolean Whether it runs.
---@field version string Its version.
---@field fail table<string, string> How the next call of a name fails: `throw`, `unknown`, `unavailable`, `garbage`.

---A bridge table over a fake framework.
---@param fw spec.FakeFramework The framework.
---@param overrides table? Fields to replace.
---@return table bridge The bridge, to register.
local function bridge_of(fw, overrides)
  ---Runs one call against the framework, failing as the test asked.
  ---@param name string The call.
  ---@param fn function What it does.
  ---@return any value What it answers first.
  ---@return any status Second.
  ---@return any reason Third.
  local function call(name, fn)
    fw.calls[#fw.calls + 1] = name
    local how = fw.fail[name]
    fw.fail[name] = nil
    if how == "throw" then
      error("the framework blew up in " .. name)
    elseif how == "unknown" then
      return nil, "unknown"
    elseif how == "unavailable" then
      return nil, "unavailable"
    elseif how == "garbage" then
      return "yes"
    end
    return fn()
  end
  local bridge = {
    name = "fakefw",
    version = "1.0.0",
    contract = { major = 1, minor = 0 },
    provides = { "characters", "money", "inventory", "jobs" },
    supports = {
      "money.accounts",
      "money.balance",
      "money.debit",
      "money.credit",
      "inventory.count",
      "inventory.give",
      "jobs.current",
    },
    tested_with = { "2.1" },
    running = function()
      return fw.running, fw.version
    end,
    start = function()
      fw.calls[#fw.calls + 1] = "start"
    end,
    stop = function()
      fw.calls[#fw.calls + 1] = "stop"
    end,
    money = {
      accounts = function()
        return call("money.accounts", function()
          return { "cash", "bank" }
        end)
      end,
      balance = function(player, account)
        return call("money.balance", function()
          local balance = (fw.money[player] or {})[account]
          if balance == nil then
            return nil, "not_found"
          end
          return balance
        end)
      end,
      debit = function(player, account, amount)
        return call("money.debit", function()
          local held = fw.money[player][account]
          if held < amount then
            return nil, "refused", "insufficient_funds"
          end
          fw.money[player][account] = held - amount
          return true
        end)
      end,
      credit = function(player, account, amount)
        return call("money.credit", function()
          fw.money[player][account] = fw.money[player][account] + amount
          return true
        end)
      end,
    },
    inventory = {
      count = function(player, item)
        return call("inventory.count", function()
          return (fw.items[player] or {})[item] or 0
        end)
      end,
      give = function(player, item, count)
        return call("inventory.give", function()
          fw.items[player][item] = (fw.items[player][item] or 0) + count
          return true
        end)
      end,
    },
    jobs = {
      current = function(player)
        return call("jobs.current", function()
          return fw.jobs[player]
        end)
      end,
    },
  }
  for key, value in pairs(overrides or {}) do
    bridge[key] = value
  end
  return bridge
end

describe("rpf.bridge", function()
  local p, fw

  ---Loads and starts the core, connected but not welcomed.
  local function boot()
    support.load_core()
    p = support.fake_platform()
    rpf.start_server(p, { url = "ws://portal", api_key = "rpf_test_secret" })
    p.open()
  end

  ---A player at `registered`.
  ---@param handle integer The engine's handle.
  local function registered(handle)
    assert(rpf.players.connected(handle))
    assert(rpf.players.authenticating(handle))
    assert(rpf.players.register(handle, {
      player_id = string.format("00000002-0000-4000-8000-%012d", handle),
      username = "sam" .. handle,
    }))
  end

  ---A companion server with the fake bridge active and player 7 in play.
  local function playing()
    boot()
    assert.is_true(rpf.api.bridge.register(bridge_of(fw)))
    welcome(p, support.COMPANION)
    registered(7)
    assert.is_true(rpf.api.bridge.character_loaded(7, { key = KEY, name = "Jane Doe" }))
    fw.calls = {}
  end

  before_each(function()
    fw = {
      money = { [7] = { cash = 100, bank = 0 } },
      items = { [7] = { water = 2 } },
      jobs = { [7] = { name = "police", grade = 2, on_duty = true } },
      calls = {},
      running = true,
      version = "2.1.4",
      fail = {},
    }
  end)

  describe("registering", function()
    it("refuses a table the contract does not allow, saying which field, once each", function()
      boot()
      for field, overrides in pairs({
        name = { name = "Fake FW" },
        version = { version = "" },
        contract = { contract = { major = "1" } },
        provides = { provides = { "money", "money" } },
        ["provides "] = { provides = { "money", "cars" } },
        ["provides  "] = { provides = {} },
        running = { running = 42 },
        start = { start = "go" },
      }) do
        local ok, err, which = rpf.api.bridge.register(bridge_of(fw, overrides))
        assert.is_nil(ok, field)
        assert.are.equal("invalid", err, field)
        assert.are.equal(field:gsub(" ", ""), which, field)
      end
      local ok, err, which = rpf.api.bridge.register(bridge_of(fw, { supports = { "money.debit", "money.fly" } }))
      assert.are.same({ nil, "invalid", "supports.money.fly" }, { ok, err, which })
      -- A call it lists needs its function, in a domain it provides.
      ok, err, which = rpf.api.bridge.register(bridge_of(fw, { supports = { "inventory.take" } }))
      assert.are.same({ nil, "invalid", "supports.inventory.take" }, { ok, err, which })
      ok, err, which = rpf.api.bridge.register(bridge_of(fw, { provides = { "money" }, supports = { "jobs.current" } }))
      assert.are.same({ nil, "invalid", "supports.jobs.current" }, { ok, err, which })
      assert.are.equal(11, #p.logged("error", "bridge was refused"))
      assert.is_nil(rpf.domains.bridge())
    end)

    it("refuses another contract major, and leaves out a later minor's calls", function()
      boot()
      assert.are.same(
        { nil, "contract", "contract" },
        { rpf.api.bridge.register(bridge_of(fw, { contract = { major = 2, minor = 0 } })) }
      )
      assert.are.equal(1, #p.logged("error", "written for contract 2, and this core speaks contract 1.0"))
      local later = bridge_of(fw, { contract = { major = 1, minor = 3 } })
      later.supports[#later.supports + 1] = "money.transfer"
      assert.is_true(rpf.api.bridge.register(later))
    end)

    it("registers one bridge at most", function()
      boot()
      assert.is_true(rpf.api.bridge.register(bridge_of(fw)))
      assert.are.same({ nil, "registered" }, { rpf.api.bridge.register(bridge_of(fw, { name = "other" })) })
      assert.are.equal(1, #p.logged("error", "the other bridge was refused: the fakefw bridge is registered already"))
    end)
  end)

  describe("activation", function()
    it("activates once a companion profile is fixed, runs start, and moves logged-in players on", function()
      boot()
      local seen = {}
      rpf.api.events.on("domains.bridge", function(change)
        seen[#seen + 1] = change.state
      end)
      assert.is_true(rpf.api.bridge.register(bridge_of(fw)))
      assert.is_nil(rpf.bridge.active(), "not before the profile is fixed")
      welcome(p, support.COMPANION)
      assert.are.equal("fakefw", rpf.bridge.active())
      assert.are.same({ "start" }, fw.calls)
      assert.are.same({ "active" }, seen)
      registered(7)
      assert.are.equal("character_select", rpf.players.get(7).state, "the bridge's cue to show its selection")
      assert.are.equal(0, #p.logged("warn", "was tested against"))
    end)

    it("activates a bridge that registers after the profile is fixed, moving players held at registered", function()
      boot()
      welcome(p, support.COMPANION)
      registered(7)
      assert.are.equal("registered", rpf.players.get(7).state)
      assert.is_true(rpf.api.bridge.register(bridge_of(fw)))
      assert.are.equal("character_select", rpf.players.get(7).state)
    end)

    it("stays inactive, holding players, when it provides other domains than the profile leaves", function()
      boot()
      assert.is_true(rpf.api.bridge.register(bridge_of(fw, { provides = { "money" }, supports = { "money.debit" } })))
      welcome(p, support.COMPANION)
      registered(7)
      assert.is_nil(rpf.bridge.active())
      assert.are.equal("registered", rpf.players.get(7).state)
      assert.are.equal(1, #p.logged("error", "the fakefw bridge provides money, and this server's profile leaves"))
      assert.are.same({}, fw.calls, "start never ran")
    end)

    it("on a native profile, stays inactive and says at error when its framework runs anyway", function()
      boot()
      assert.is_true(rpf.api.bridge.register(bridge_of(fw)))
      welcome(p, support.NATIVE)
      registered(7)
      assert.is_nil(rpf.bridge.active())
      assert.are.equal(1, #p.logged("error", "this server's `domains` setting is native"))
      assert.is_true((rpf.players.advance(7, "character_select")), "a native server holds nobody back")
      -- Without the framework running, there is nothing to say.
      fw.running = false
      boot()
      assert.is_true(rpf.api.bridge.register(bridge_of(fw)))
      welcome(p, support.NATIVE)
      assert.are.equal(0, #p.logged("error", "`domains` setting is native"))
    end)

    it("warns, and still activates, outside the framework versions it was tested against", function()
      fw.version = "3.0.0"
      boot()
      assert.is_true(rpf.api.bridge.register(bridge_of(fw)))
      welcome(p, support.COMPANION)
      assert.are.equal("fakefw", rpf.bridge.active())
      assert.are.equal(1, #p.logged("warn", "was tested against 2.1, and its framework is 3.0.0"))
    end)

    it("withdraws a bridge whose start throws, and holds players", function()
      boot()
      local b = bridge_of(fw, {
        start = function()
          error("no framework")
        end,
      })
      assert.is_true(rpf.api.bridge.register(b))
      welcome(p, support.COMPANION)
      registered(7)
      assert.is_nil(rpf.bridge.active())
      assert.are.equal("registered", rpf.players.get(7).state)
      assert.are.same({ "stop" }, fw.calls)
      assert.are.equal(1, #p.logged("error", "start threw"))
    end)
  end)

  describe("the lifecycle", function()
    it("moves a player to active on a loaded character, and back on an unloaded one", function()
      playing()
      assert.are.equal("active", rpf.players.get(7).state)
      assert.are.same({ key = KEY, name = "Jane Doe" }, rpf.api.characters.current(7))
      assert.is_true(rpf.api.bridge.character_unloaded(7))
      assert.are.equal("character_select", rpf.players.get(7).state)
      assert.are.same({ nil, "no_character" }, { rpf.api.characters.current(7) })
      assert.are.same({ nil, "no_character" }, { rpf.api.bridge.character_unloaded(7) })
    end)

    it("renames on the same key, and switches through character_select on another", function()
      playing()
      local moves = {}
      rpf.api.events.on("players.state_changed", function(player)
        moves[#moves + 1] = player.state
      end)
      assert.is_true(rpf.api.bridge.character_loaded(7, { key = KEY, name = "Jane Smith" }))
      assert.are.same({}, moves)
      assert.are.equal("Jane Smith", rpf.api.characters.current(7).name)
      assert.is_true(rpf.api.bridge.character_loaded(7, { key = "CIT-9", name = "Joe" }))
      assert.are.same({ "character_select", "active" }, moves)
      assert.are.equal("CIT-9", rpf.api.characters.current(7).key)
    end)

    it("refuses a character for a player who has not logged in, and says the gate is not holding", function()
      playing()
      assert(rpf.players.connected(8))
      assert(rpf.players.authenticating(8))
      assert.are.same(
        { nil, "not_registered" },
        { rpf.api.bridge.character_loaded(8, { key = "CIT-8", name = "Al" }) }
      )
      assert.are.equal("authenticating", rpf.players.get(8).state)
      assert.are.equal(1, #p.logged("warn", "its login gate is not holding"))
      assert.are.same({ nil, "not_found" }, { rpf.api.bridge.character_loaded(99, { key = "x", name = "y" }) })
      assert.are.same({ nil, "invalid" }, { rpf.api.bridge.character_loaded(7, { key = "", name = "y" }) })
      assert.are.same({ nil, "invalid" }, { rpf.api.bridge.character_loaded(7, { key = string.rep("k", 129), name = "y" }) })
    end)

    it("takes reports only from the bridge's own code, where the engine names it", function()
      boot()
      assert.is_true(rpf.addons.from("fakefw_bridge", rpf.api.bridge.register, bridge_of(fw)))
      welcome(p, support.COMPANION)
      registered(7)
      local character = { key = KEY, name = "Jane Doe" }
      assert.are.same({ nil, "forbidden" }, { rpf.addons.from("griefer", rpf.api.bridge.character_loaded, 7, character) })
      assert.are.same({ nil, "forbidden" }, { rpf.addons.from("griefer", rpf.api.bridge.unavailable, "x") })
      assert.is_true(rpf.addons.from("fakefw_bridge", rpf.api.bridge.character_loaded, 7, character))
    end)

    it("withdraws the bridge when its resource stops: players back to choosing, new ones held", function()
      boot()
      assert.is_true(rpf.addons.from("fakefw_bridge", rpf.api.bridge.register, bridge_of(fw)))
      welcome(p, support.COMPANION)
      registered(7)
      assert.is_true(rpf.addons.from("fakefw_bridge", rpf.api.bridge.character_loaded, 7, { key = KEY, name = "J" }))
      rpf.unload_origin("someone_else")
      assert.are.equal("fakefw", rpf.bridge.active())
      rpf.unload_origin("fakefw_bridge")
      assert.is_nil(rpf.bridge.active())
      assert.are.equal("character_select", rpf.players.get(7).state)
      assert.are.same({ nil, "unavailable" }, { rpf.api.money.balance(7, "cash") })
      assert.are.same({ "start" }, fw.calls, "stop never runs: its code is gone")
      registered(8)
      assert.are.equal("registered", rpf.players.get(8).state)
      -- It registers again when its resource starts again.
      assert.is_true(rpf.addons.from("fakefw_bridge", rpf.api.bridge.register, bridge_of(fw)))
      assert.are.equal("character_select", rpf.players.get(8).state)
    end)

    it("keeps the framework's key on this server: in no frame and no log line", function()
      playing()
      rpf.api.money.debit(7, "cash", 5, "Tag", op())
      fw.fail["money.debit"] = "unknown"
      rpf.api.money.debit(7, "cash", 5, "Tag", op())
      p.advance(5000)
      for _, sent in ipairs(p.sent) do
        assert.is_nil(sent:find(KEY, 1, true), "a frame carries the key")
      end
      for _, line in ipairs(p.logs) do
        assert.is_nil(line.message:find(KEY, 1, true), "a log line carries the key")
      end
    end)

    it("forgets a player's character when they leave", function()
      playing()
      rpf.players.dropped(7, "left")
      registered(7)
      assert.are.same({ nil, "no_character" }, { rpf.api.characters.current(7) })
    end)
  end)

  describe("routing the facade", function()
    it("supports what the bridge lists, and refuses the rest without reaching it", function()
      playing()
      assert.is_true(rpf.api.characters.supports("current"))
      assert.is_true(rpf.api.money.supports("debit"))
      assert.is_true(rpf.api.inventory.supports("give"))
      assert.is_false(rpf.api.inventory.supports("take"))
      assert.are.same(
        { nil, "refused", "unsupported" },
        { rpf.api.inventory.take(7, "water", 1, op()) }
      )
      assert.are.same({}, fw.calls)
    end)

    it("reads through the bridge, checking what it answers", function()
      playing()
      assert.are.same({ "cash", "bank" }, rpf.api.money.accounts())
      assert.are.equal(100, rpf.api.money.balance(7, "cash"))
      assert.are.same({ nil, "not_found" }, { rpf.api.money.balance(7, "crypto") })
      assert.are.equal(2, rpf.api.inventory.count(7, "water"))
      assert.are.same({ name = "police", grade = 2, on_duty = true }, rpf.api.jobs.current(7))
      fw.jobs[7] = nil
      assert.is_nil((rpf.api.jobs.current(7)), "no job")
      fw.fail["money.balance"] = "throw"
      assert.are.same({ nil, "unavailable" }, { rpf.api.money.balance(7, "cash") })
      fw.fail["inventory.count"] = "garbage"
      assert.are.same({ nil, "unavailable" }, { rpf.api.inventory.count(7, "water") })
      assert.are.equal(1, #p.logged("error", "money.balance threw"))
      assert.are.equal(1, #p.logged("error", "inventory.count answered a value the contract does not allow"))
      assert.are.same({ nil, "not_logged_in" }, { rpf.api.money.balance(99, "cash") })
      -- No player is no logged-in player, never a call without one.
      fw.calls = {}
      assert.are.same({ nil, "not_logged_in" }, { rpf.api.money.balance(nil, "cash") })
      assert.are.same({ nil, "not_logged_in" }, { rpf.api.inventory.count(nil, "water") })
      assert.are.same({ nil, "not_logged_in" }, { rpf.api.jobs.current(nil) })
      assert.are.same({}, fw.calls)
      rpf.api.bridge.character_unloaded(7)
      assert.are.same({ nil, "no_character" }, { rpf.api.money.balance(7, "cash") })
    end)

    it("runs a command once per op id, and never through RPF's own modules", function()
      playing()
      local id = op()
      assert.is_true(rpf.api.money.debit(7, "cash", 30, "Spray can", id))
      assert.is_true(rpf.api.money.debit(7, "cash", 30, "Spray can", id))
      assert.are.equal(70, fw.money[7].cash)
      assert.are.same({ "money.debit" }, fw.calls)
      assert.are.same(
        { nil, "refused", "insufficient_funds" },
        { rpf.api.money.debit(7, "cash", 500, "Car", op()) }
      )
      assert.are.same({ nil, "refused", "invalid" }, { rpf.api.money.debit(7, "cash", 0, "x", op()) })
      local max = rpf.protocol.MAX_AMOUNT
      assert.are.same({ nil, "refused", "invalid" }, { rpf.api.money.credit(7, "cash", max + 1, "x", op()) })
      assert.are.same({ nil, "refused", "invalid_op" }, { rpf.api.money.debit(7, "cash", 1, "x", "mine") })
      assert.are.same({ nil, "refused", "not_logged_in" }, { rpf.api.money.debit(99, "cash", 1, "x", op()) })
      assert.is_true(rpf.api.inventory.give(7, "water", 3, op()))
      assert.are.equal(5, fw.items[7].water)
    end)

    it("is unknown when the bridge throws or answers outside the contract, and unavailable only when it says so", function()
      playing()
      local threw, garbage, unknown, unavailable = op(), op(), op(), op()
      fw.fail["money.debit"] = "throw"
      assert.are.same({ nil, "unknown" }, { rpf.api.money.debit(7, "cash", 1, "x", threw) })
      fw.fail["money.debit"] = "garbage"
      assert.are.same({ nil, "unknown" }, { rpf.api.money.debit(7, "cash", 1, "x", garbage) })
      fw.fail["money.debit"] = "unknown"
      assert.are.same({ nil, "unknown" }, { rpf.api.money.debit(7, "cash", 1, "x", unknown) })
      assert.are.equal(3, #rpf.api.ops.unknown())
      -- Never again, whatever the bridge would answer now.
      assert.are.same({ nil, "unknown" }, { rpf.api.money.debit(7, "cash", 1, "x", threw) })
      fw.fail["money.debit"] = "unavailable"
      assert.are.same({ nil, "unavailable" }, { rpf.api.money.debit(7, "cash", 1, "x", unavailable) })
      -- Nothing changed, so the same op id may go again, and does.
      assert.is_true(rpf.api.money.debit(7, "cash", 1, "x", unavailable))
      assert.are.same({ "money.debit", "money.debit", "money.debit", "money.debit", "money.debit" }, fw.calls)
    end)

    it("pays for an addon's change in the same intent through the bridge", function()
      playing()
      local applied = 0
      local id = op()
      assert.is_true(rpf.api.money.debit(7, "cash", 10, "Badge", id, function()
        applied = applied + 1
        return true
      end))
      assert.is_true(rpf.api.money.debit(7, "cash", 10, "Badge", id, function()
        applied = applied + 1
        return true
      end))
      assert.are.equal(1, applied)
      assert.are.same({ nil, "unknown" }, {
        rpf.api.money.debit(7, "cash", 10, "Badge", op(), function()
          return nil
        end),
      })
      assert.are.equal(80, fw.money[7].cash, "no refund")
      assert.are.same({ nil, "refused", "insufficient_funds" }, {
        rpf.api.money.debit(7, "cash", 1000, "Badge", op(), function()
          applied = applied + 1
          return true
        end),
      })
      assert.are.equal(1, applied, "a refused debit grants nothing")
    end)

    it("answers unavailable without reaching the bridge while its framework is down", function()
      playing()
      local seen = {}
      rpf.api.events.on("domains.bridge", function(change)
        seen[#seen + 1] = change.state .. ":" .. tostring(change.reason)
      end)
      assert.is_true(rpf.api.bridge.unavailable("its resource stopped"))
      local id = op()
      assert.are.same({ nil, "unavailable" }, { rpf.api.money.debit(7, "cash", 1, "x", id) })
      assert.are.same({ nil, "unavailable" }, { rpf.api.money.balance(7, "cash") })
      assert.are.same({ nil, "unavailable" }, { rpf.api.characters.current(7) })
      assert.are.same({}, rpf.api.money.accounts())
      assert.is_true(rpf.api.money.supports("debit"), "what it can do has not changed")
      assert.are.same({}, fw.calls)
      assert.are.equal(0, rpf.ops.count(), "nothing journaled")
      assert.is_true(rpf.api.bridge.available())
      assert.is_true(rpf.api.money.debit(7, "cash", 1, "x", id), "the same op id goes once it is back")
      assert.are.same({ key = KEY, name = "Jane Doe" }, rpf.api.characters.current(7), "kept through the outage")
      assert.are.same({ "unavailable:its resource stopped", "available:nil" }, seen)
    end)
  end)
end)
