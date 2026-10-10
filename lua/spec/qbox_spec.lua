-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The Qbox bridge (K3) beyond the shared suite (`conformance_qbox_spec.lua`):
-- what qbx_core and ox_inventory do that another framework does not. Run on
-- the real FiveM adapter, through the export as the bridge's resource sees
-- it, and on the mock platform, over the fake of the two resources
-- (`spec/support/qbox_fake.lua`):
--
-- - the gate, which qbx_core's own character callbacks can reach past,
--   held by logging out at once a character loaded before `character_select`;
-- - the networked `QBCore:Server:OnPlayerLoaded`, a cue and never a fact;
-- - a client's requests, with another licence's character refused as one
--   that does not exist;
-- - qbx_core still logging a player out while `GetPlayer` answers;
-- - ox_inventory stopping on its own, its `money` item, and an item that
--   would only partly fit;
-- - money that never goes below zero, and a refusal from qbx_core's hooks;
-- - a native server, where the bridge stays inactive.

local conformance = require("spec.support.conformance")
local qbox_fake = require("spec.support.qbox_fake")

local PLAYER = "00000002-0000-4000-8000-000000000002"
local OTHER = "00000003-0000-4000-8000-000000000003"

---The companion profile: every domain Qbox's.
local COMPANION = { characters = "external", money = "external", inventory = "external", jobs = "external" }

---Boots RPF on a profile with the Qbox bridge registered by its own code.
---@param world spec.ConformanceWorld The world.
---@param fw spec.QboxFake qbx_core and ox_inventory.
---@param native boolean? True for a native server.
local function boot(world, fw, native)
  assert(qbox_fake.register(world:as("rpf-qbox"), fw))
  world:connect(not native and COMPANION or nil)
  world:pump()
end

---qbx_core and ox_inventory with Jane's character, as player 1's.
---@return spec.QboxFake fw The fake.
local function framework()
  local fw = qbox_fake.new()
  fw:seed("CIT-JANE", { cash = 500, bank = 1000 }, { water = 3 }, { name = "police", grade = 2, on_duty = true })
  return fw
end

---Player 1 logged in to RPF and playing Jane.
---@param world spec.ConformanceWorld The world.
---@param fw spec.QboxFake The fake.
---@return any handle Their server id.
local function playing(world, fw)
  local handle = world:login(1, PLAYER)
  fw:load(handle, "CIT-JANE", "Jane Doe")
  world:pump()
  assert.are.equal("active", world.api.players.get(handle).state)
  return handle
end

---Whether the bridge's log has a line containing a text.
---@param fw spec.QboxFake The fake.
---@param level string The level.
---@param text string The text.
---@return integer count How many lines.
local function bridge_logged(fw, level, text)
  local count = 0
  for _, line in ipairs(fw.logs) do
    if line.level == level and line.message:find(text, 1, true) then
      count = count + 1
    end
  end
  return count
end

local cases = {
  {
    name = "logs out at once a character qbx_core's own callbacks load before the RPF login",
    run = function(world)
      local fw = framework()
      boot(world, fw)
      local api = world.api
      local handle = world.join(1)
      assert(world.core.players.authenticating(handle))
      assert.is_true(fw:hostile_load(handle, "CIT-JANE"), "qbx_core logs anyone in")
      assert.is_nil(fw:loaded(handle), "and the bridge logged them out")
      assert.are.equal(1, fw.logouts[handle])
      assert.are.equal("authenticating", api.players.get(handle).state)
      assert.are.same({ nil, "not_logged_in" }, { api.characters.current(handle) })
      assert.are.same({ nil, "refused", "not_logged_in" }, { api.money.debit(handle, "cash", 1, "x", api.ops.new()) })
      assert.is_nil(fw.changes["money.debit"])
      assert.are.equal(1, bridge_logged(fw, "error", "before they logged in to RPF"))
      for _, line in ipairs(fw.logs) do
        assert.is_nil(line.message:find("CIT-JANE", 1, true), "the bridge logged the key")
      end
      -- Once logged in, the same character is theirs to choose.
      assert(world.core.players.register(handle, { player_id = PLAYER, username = "player1" }))
      world:pump()
      fw:load(handle, "CIT-JANE", "Jane Doe")
      assert.are.equal("active", api.players.get(handle).state)
    end,
  },
  {
    name = "catches a load it was not told of with its sweep",
    run = function(world)
      local fw = framework()
      boot(world, fw)
      local handle = world.join(1)
      -- A load whose `QBCore:Server:PlayerLoaded` the bridge did not hear,
      -- as if a later qbx_core renamed it.
      fw.db["CIT-JANE"].license = "license2:" .. tostring(handle)
      fw.players[handle] = "CIT-JANE"
      world:advance(1000)
      assert.is_nil(fw:loaded(handle))
      assert.are.equal(1, fw.logouts[handle])
    end,
  },
  {
    name = "accepts a character qbx_core's own creation loads while the player is choosing",
    run = function(world)
      local fw = framework()
      boot(world, fw)
      local api = world.api
      local handle = world:login(1, PLAYER)
      local key = assert(fw:create(handle, "John", "Smith"))
      assert.are.equal("active", api.players.get(handle).state)
      assert.are.same({ key = key, name = "John Smith" }, api.characters.current(handle))
      assert.are.equal(5000, api.money.balance(handle, "bank"))
      assert.is_nil(fw.logouts[handle])
    end,
  },
  {
    name = "takes a networked OnPlayerLoaded as a cue to look, never as a load",
    run = function(world)
      local fw = framework()
      boot(world, fw)
      local api = world.api
      local early = world.join(2)
      local before = api.players.get(early).state
      fw:client_event(early, "QBCore:Server:OnPlayerLoaded", { citizenid = "CIT-JANE" })
      assert.are.equal(before, api.players.get(early).state)
      local handle = world:login(1, PLAYER)
      fw:client_event(handle, "QBCore:Server:OnPlayerLoaded", { citizenid = "CIT-JANE" })
      assert.are.equal("character_select", api.players.get(handle).state, "nothing is loaded")
      assert.are.same({ nil, "no_character" }, { api.characters.current(handle) })
      assert.is_nil(fw:loaded(handle))
      assert.are.same({}, fw.logouts)
      assert.are.same({}, fw.dropped)
    end,
  },
  {
    name = "loads only a character of the player's own, for a player who is choosing",
    run = function(world)
      local fw = framework()
      fw:seed("CIT-JOHN", { cash = 10 })
      fw.db["CIT-JOHN"].license = "license2:9"
      boot(world, fw)
      local early = world.join(2)
      assert.are.same({ error = "not_selecting" }, fw:request(early, "rpf-qbox:load", "CIT-JANE"))
      local handle = world:login(1, PLAYER)
      fw.db["CIT-JANE"].license = "license2:" .. tostring(handle)
      for _, hostile in ipairs({ "CIT-JOHN", "CIT-NOBODY", 42, string.rep("A", 65), "" }) do
        assert.are.same({ error = "not_found" }, fw:request(handle, "rpf-qbox:load", hostile), tostring(hostile))
      end
      assert.are.same({}, fw.dropped, "qbx_core never saw another licence's character asked for")
      assert.is_nil(fw:loaded(handle))
      assert.are.same({ ok = true }, fw:request(handle, "rpf-qbox:load", "CIT-JANE"))
      assert.are.same({ error = "not_selecting" }, fw:request(handle, "rpf-qbox:load", "CIT-JANE"), "playing already")
      assert.are.same({}, fw.dropped)
    end,
  },
  {
    name = "lists the player's own characters, and never searches without a licence",
    run = function(world)
      local fw = framework()
      fw:seed("CIT-JOHN", { cash = 10 })
      fw.db["CIT-JOHN"].license = "license2:9"
      boot(world, fw)
      local early = world.join(2)
      assert.are.same({ error = "not_selecting" }, fw:request(early, "rpf-qbox:characters"))
      local handle = world:login(1, PLAYER)
      fw.db["CIT-JANE"].license = "license2:" .. tostring(handle)
      fw.db["CIT-JANE"].charinfo = { firstname = "Jane", lastname = "Doe", cid = 1 }
      assert.are.same(
        { characters = { { citizenid = "CIT-JANE", name = "Jane Doe" } } },
        fw:request(handle, "rpf-qbox:characters")
      )
      for _, filters in ipairs(fw.searches) do
        assert.are.equal("string", type(filters.license))
      end
    end,
  },
  {
    name = "does not report again a character qbx_core is still logging out",
    run = function(world)
      local fw = framework()
      boot(world, fw)
      local api = world.api
      local handle = playing(world, fw)
      fw:delay_logouts()
      fw:unload(handle)
      assert.are.equal("character_select", api.players.get(handle).state)
      world:advance(1000)
      assert.are.equal("character_select", api.players.get(handle).state, "GetPlayer still answers, and it is not taken")
      assert.are.same({ error = "busy" }, fw:request(handle, "rpf-qbox:load", "CIT-JANE"), "qbx_core would drop a second login")
      local shown = fw.shown[handle] or 0
      fw:finish_logouts()
      world:advance(1000)
      assert.are.equal(shown + 1, fw.shown[handle], "the selection, once qbx_core has finished")
      assert.are.same({ ok = true }, fw:request(handle, "rpf-qbox:load", "CIT-JANE"))
      assert.are.equal("active", api.players.get(handle).state)
      assert.are.same({}, fw.dropped)
    end,
  },
  {
    name = "shows the selection again once qbx_core has logged a player out",
    run = function(world)
      local fw = framework()
      boot(world, fw)
      local api = world.api
      local handle = playing(world, fw)
      local shown = fw.shown[handle] or 0
      -- qbx_core's `Logout` fires `OnPlayerUnload` while `GetPlayer` still
      -- answers, so RPF's cue comes before the player is gone.
      fw:unload(handle)
      assert.are.equal("character_select", api.players.get(handle).state)
      world:advance(1000)
      assert.are.equal(shown + 1, fw.shown[handle])
      world:advance(5000)
      assert.are.equal(shown + 1, fw.shown[handle], "once")
    end,
  },
  {
    name = "takes one load at a time for a player, so qbx_core never sees a second Login",
    run = function(world)
      local fw = framework()
      boot(world, fw)
      local handle = world:login(1, PLAYER)
      fw.db["CIT-JANE"].license = "license2:" .. tostring(handle)
      local overlapping
      fw.searching = function()
        overlapping = fw:request(handle, "rpf-qbox:load", "CIT-JANE")
      end
      assert.are.same({ ok = true }, fw:request(handle, "rpf-qbox:load", "CIT-JANE"))
      assert.are.same({ error = "busy" }, overlapping)
      assert.are.same({}, fw.dropped)
      assert.are.equal("active", world.api.players.get(handle).state)
    end,
  },
  {
    name = "answers item calls unavailable while ox_inventory alone is stopped",
    run = function(world)
      local fw = framework()
      boot(world, fw)
      local api = world.api
      local handle = playing(world, fw)
      fw:stop_inventory()
      assert.are.same({ nil, "unavailable" }, { api.inventory.count(handle, "water") })
      assert.are.same({ nil, "unavailable" }, { api.inventory.give(handle, "water", 1, api.ops.new()) })
      assert.are.equal(500, api.money.balance(handle, "cash"), "money is qbx_core's, which runs")
      assert.is_true(api.money.debit(handle, "cash", 5, "x", api.ops.new()))
      fw:start_inventory()
      assert.is_true(api.inventory.give(handle, "water", 1, api.ops.new()))
      assert.are.equal(4, api.inventory.count(handle, "water"))
    end,
  },
  {
    name = "refuses the money item and an unknown one, and a give that would only partly fit",
    run = function(world)
      local fw = framework()
      boot(world, fw)
      local api = world.api
      local handle = playing(world, fw)
      assert.are.same({ nil, "refused", "money_item" }, { api.inventory.give(handle, "money", 5, api.ops.new()) })
      assert.are.same({ nil, "refused", "money_item" }, { api.inventory.take(handle, "money", 5, api.ops.new()) })
      assert.are.same({ nil, "not_found" }, { api.inventory.count(handle, "money") })
      assert.are.same({ nil, "refused", "unknown_item" }, { api.inventory.give(handle, "nope", 1, api.ops.new()) })
      assert.are.same({ nil, "not_found" }, { api.inventory.count(handle, "nope") })
      fw.slots = 2
      assert.are.same({ nil, "refused", "no_space" }, { api.inventory.give(handle, "phone", 3, api.ops.new()) })
      assert.are.equal(0, fw:count("CIT-JANE", "phone"))
      assert.is_true(api.inventory.give(handle, "phone", 2, api.ops.new()))
      assert.are.equal(1, fw.changes["inventory.give"])
    end,
  },
  {
    name = "never takes an account below zero, and refuses what qbx_core's hooks veto",
    run = function(world)
      local fw = framework()
      boot(world, fw)
      local api = world.api
      local handle = playing(world, fw)
      assert.are.same({ nil, "refused", "insufficient_funds" }, { api.money.debit(handle, "bank", 1500, "x", api.ops.new()) })
      assert.are.equal(1000, fw:balance("CIT-JANE", "bank"), "qbx_core would have let bank go negative")
      assert.are.same({ nil, "not_found" }, { api.money.balance(handle, "gold") })
      assert.are.same({ nil, "refused", "no_account" }, { api.money.credit(handle, "gold", 5, "x", api.ops.new()) })
      fw.veto = true
      assert.are.same({ nil, "refused", "framework" }, { api.money.debit(handle, "cash", 5, "x", api.ops.new()) })
      assert.are.same({ nil, "refused", "framework" }, { api.money.credit(handle, "cash", 5, "x", api.ops.new()) })
      assert.are.equal(500, fw:balance("CIT-JANE", "cash"))
      assert.are.same({}, api.ops.unknown())
    end,
  },
  {
    name = "acts only on the character RPF has in play",
    run = function(world)
      local fw = framework()
      fw:seed("CIT-JOHN", { cash = 10 })
      boot(world, fw)
      local api = world.api
      local handle = playing(world, fw)
      -- qbx_core has another character for them now, and nothing said so.
      fw.players[handle] = "CIT-JOHN"
      assert.are.same({ nil, "no_character" }, { api.money.balance(handle, "cash") })
      assert.are.same({ nil, "refused", "no_character" }, { api.money.debit(handle, "cash", 5, "x", api.ops.new()) })
      assert.are.equal(10, fw:balance("CIT-JOHN", "cash"))
      assert.are.equal(500, fw:balance("CIT-JANE", "cash"))
    end,
  },
  {
    name = "reads Jane's job from qbx_core, and warns of a qbx_core it was not tested with",
    run = function(world)
      local fw = framework()
      fw.version = "1.30.2"
      boot(world, fw)
      local api = world.api
      local handle = playing(world, fw)
      assert.are.same({ name = "police", grade = 2, on_duty = true }, api.jobs.current(handle))
      assert.are.equal(1, world:logged("warn", "was tested against 1.24, and its framework is 1.30.2"))
    end,
  },
  {
    name = "stays inactive on a native server, where qbx_core running is an error in the log",
    run = function(world)
      local fw = framework()
      boot(world, fw, true)
      local handle = world:login(1, PLAYER)
      assert.is_nil(fw.shown[handle], "no Qbox selection")
      assert.is_true(fw:hostile_load(handle, "CIT-JANE"))
      assert.are.equal("CIT-JANE", fw:loaded(handle), "nothing of RPF's is the bridge's to hold here")
      assert.are.equal(1, world:logged("error", "Set the server's profile to companion"))
      assert.are.same({ error = "not_selecting" }, fw:request(world.join(2), "rpf-qbox:characters"))
    end,
  },
  {
    name = "takes players who were choosing back to the selection when qbx_core starts again",
    run = function(world)
      local fw = framework()
      boot(world, fw)
      local api = world.api
      local handle = playing(world, fw)
      local other = world:login(2, OTHER)
      fw:stop()
      assert.are.same({ error = "unavailable" }, fw:request(other, "rpf-qbox:load", "CIT-JANE"))
      local shown = fw.shown[handle] or 0
      fw:start()
      assert.are.equal(shown + 1, fw.shown[handle])
      assert.is_true(fw.shown[other] >= 2)
      fw:load(handle, "CIT-JANE", "Jane Doe")
      assert.are.equal("active", api.players.get(handle).state)
    end,
  },
}

conformance.run(
  { describe = describe, it = it, before_each = before_each, after_each = after_each },
  "the qbox bridge",
  cases,
  { "mock", "fivem" }
)
