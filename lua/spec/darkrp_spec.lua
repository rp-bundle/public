-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The DarkRP bridge (K4) beyond the shared suite (`conformance_darkrp_spec.lua`):
-- what DarkRP does that a framework with characters does not. Run on the
-- real Gmod adapter, through the `rpf` global as every Gmod addon sees it,
-- and on the mock platform, over the fake of DarkRP
-- (`spec/support/darkrp_fake.lua`):
--
-- - the hold, which stands in for a character load to defer: unspawned,
--   with team changes, DarkRP's commands, salary and voice refused, and
--   other players' commands that name the player, until RPF has them
--   `active`, whatever spawns them meanwhile;
-- - DarkRP's data, loaded before the RPF login, after it, or never;
-- - a rename, the team's job, and a wallet a hook moved by another amount;
-- - leaving, and a map change, in place of a character unloading;
-- - DarkRP not the gamemode, a version it was not tested with, and a native
--   server, where players are still held until RPF's own character is in
--   play.

local conformance = require("spec.support.conformance")
local darkrp_fake = require("spec.support.darkrp_fake")

local PLAYER = "00000002-0000-4000-8000-000000000002"
local OTHER = "00000003-0000-4000-8000-000000000003"
local SERVER = "00000001-0000-4000-8000-000000000001"
local JANE = "00000010-0000-4000-8000-000000000010"

---The DarkRP bridge as Gmod loads it, for its constants.
local bridge = dofile(require("spec.support").path("lua/bridges/darkrp/bridge.lua"))

---The companion profile: every domain DarkRP's.
local COMPANION = { characters = "external", money = "external", inventory = "external", jobs = "external" }

---Boots RPF on a profile with the DarkRP bridge registered by its own code.
---@param world spec.ConformanceWorld The world.
---@param fw spec.DarkRPFake DarkRP.
---@param native boolean? True for a native server.
local function boot(world, fw, native)
  assert(darkrp_fake.register(world:as("rpf_darkrp"), fw))
  world:connect(not native and COMPANION or nil)
  world:pump()
end

---DarkRP with Jane's data, in the police team once loaded.
---@return spec.DarkRPFake fw The fake.
local function framework()
  local fw = darkrp_fake.new()
  fw:seed("CIT-JANE", { wallet = 500 }, nil, { name = "police", grade = 0, on_duty = true })
  return fw
end

---A player in the game: Gmod hands them to RPF, and DarkRP to its join.
---@param world spec.ConformanceWorld The world.
---@param fw spec.DarkRPFake The fake.
---@param n integer The harness's number for them.
---@return any handle Their handle.
local function join(world, fw, n)
  local handle = world.join(n)
  fw:connect(handle)
  return handle
end

---Logs a player in to RPF, as the join flow does.
---@param world spec.ConformanceWorld The world.
---@param handle any The player.
---@param player_id string Their account.
local function register(world, handle, player_id)
  local players = world.core.players
  if players.get(handle).state == "connecting" then
    assert(players.authenticating(handle))
  end
  assert(players.register(handle, { player_id = player_id, username = "player" }))
  world:pump()
end

---Player 1 in the game, logged in to RPF, playing Jane.
---@param world spec.ConformanceWorld The world.
---@param fw spec.DarkRPFake The fake.
---@return any handle Their handle.
local function playing(world, fw)
  local handle = join(world, fw, 1)
  fw:restore(handle, "CIT-JANE", "Jane Doe")
  register(world, handle, PLAYER)
  assert.are.equal("active", world.api.players.get(handle).state)
  return handle
end

---How many of the bridge's log lines at a level contain a text.
---@param fw spec.DarkRPFake The fake.
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

---Everything the hold refuses, asked of one player while another asks
---about them: what DarkRP lets each do.
---@param fw spec.DarkRPFake The fake.
---@param handle any The player.
---@param other any Another player, playing.
---@return table<string, any> answers What each answered.
local function asked(fw, handle, other)
  local before = fw.players[handle].vars.money
  local paid = fw:payday(handle, 45)
  if paid ~= 0 then
    fw.players[handle].vars.money = before
  end
  return {
    team = { fw:change_team(handle, "medic") },
    forced = { fw:change_team(handle, "citizen", true) },
    command = fw:command(handle, "job"),
    paid = paid,
    heard = fw:hears(other, handle),
    demote = { fw:ask("canDemote", other, handle, "rdm") },
    wanted = { fw:ask("canWanted", handle, other, "theft") },
    warrant = { fw:ask("canRequestWarrant", handle, other, "theft") },
    hit = { fw:ask("canRequestHit", other, other, handle, 100) },
  }
end

local cases = {
  {
    name = "holds a player out of DarkRP's play from their join until RPF has them active",
    run = function(world)
      local fw = framework()
      boot(world, fw)
      local api = world.api
      local other = playing(world, fw)
      fw:seed("CIT-JOHN", { wallet = 80 })
      local handle = join(world, fw, 2)
      assert.is_false(fw.players[handle].alive, "taken out of the world after DarkRP's spawn")
      assert.are.equal(1, fw.kills[handle])
      fw:think(handle)
      assert.is_false(fw.players[handle].alive, "and not respawned")
      -- DarkRP's data arrives before the RPF login, as it usually does.
      fw:restore(handle, "CIT-JOHN", "John Roe")
      assert.are.equal("connecting", api.players.get(handle).state)
      assert.is_nil(fw:loaded(handle), "nothing of DarkRP's in play")
      assert.are.same({
        team = { false, bridge.REFUSED },
        forced = { false, bridge.REFUSED },
        command = false,
        paid = 0,
        heard = false,
        demote = { false, bridge.ABSENT },
        wanted = { false, bridge.ABSENT },
        warrant = { false, bridge.ABSENT },
        hit = { false, bridge.ABSENT },
      }, asked(fw, handle, other))
      assert.are.equal(80, fw:balance("CIT-JOHN", "wallet"), "no salary")
      assert.are.same({ nil, "not_logged_in" }, { api.money.balance(handle, "wallet") })
      assert.are.same({ nil, "refused", "not_logged_in" }, { api.money.debit(handle, "wallet", 1, "x", api.ops.new()) })
      assert.is_nil(fw.changes["money.debit"])
      -- Logged in, with the data loaded already: in play at once, through
      -- DarkRP's own spawn.
      register(world, handle, OTHER)
      assert.are.equal("active", api.players.get(handle).state)
      assert.are.same({ key = "CIT-JOHN", name = "John Roe" }, api.characters.current(handle))
      assert.is_true(fw.players[handle].alive)
      assert.are.equal(2, fw.spawns[handle])
      assert.are.same({
        team = { true },
        forced = { true },
        command = true,
        paid = 45,
        heard = true,
        demote = { true },
        wanted = { true },
        warrant = { true },
        hit = { true },
      }, asked(fw, handle, other))
      assert.are.equal(0, world:logged("warn", "its login gate is not holding"))
      for _, line in ipairs(fw.logs) do
        assert.is_nil(line.message:find("CIT-", 1, true), "the bridge logged a key")
      end
    end,
  },
  {
    name = "takes a held player out again whatever spawns them, a hook answered first included",
    run = function(world)
      local fw = framework()
      boot(world, fw)
      local handle = join(world, fw, 1)
      fw:respawn(handle)
      assert.is_false(fw.players[handle].alive, "an admin mod's respawn")
      assert.are.equal(2, fw.kills[handle])
      -- Another addon's `PlayerSpawn` hook answers first, so the bridge's
      -- never runs: the sweep finds them within a second.
      fw.preempt.PlayerSpawn = { true }
      fw:respawn(handle)
      assert.is_true(fw.players[handle].alive)
      world:advance(bridge.SWEEP_MS)
      assert.is_false(fw.players[handle].alive)
      assert.are.equal(3, fw.kills[handle])
      -- And one whose `PlayerDeathThink` another addon answered.
      fw.preempt.PlayerSpawn = nil
      fw.preempt.PlayerDeathThink = { nil }
      fw:think(handle)
      world:advance(bridge.SWEEP_MS)
      assert.is_false(fw.players[handle].alive)
    end,
  },
  {
    name = "waits at character_select while DarkRP is slow to load the player's data",
    run = function(world)
      local fw = framework()
      boot(world, fw)
      local api = world.api
      local handle = join(world, fw, 1)
      register(world, handle, PLAYER)
      assert.are.equal("character_select", api.players.get(handle).state)
      assert.is_false(fw:command(handle, "job"))
      world:advance(5000)
      assert.are.equal("character_select", api.players.get(handle).state)
      assert.is_false(fw.players[handle].alive)
      -- Data with no rpname of its own: the wallet is the cue, and the name
      -- is the one DarkRP shows, its `Nick`.
      fw:restore(handle, "CIT-JANE")
      assert.are.equal("active", api.players.get(handle).state)
      assert.are.same({ key = "CIT-JANE", name = "SteamName" }, api.characters.current(handle))
      assert.is_true(fw.players[handle].alive)
    end,
  },
  {
    name = "keeps a player whose data DarkRP could not load out of play, and says so once",
    run = function(world)
      local fw = framework()
      boot(world, fw)
      local api = world.api
      local handle = join(world, fw, 1)
      fw:fail(handle)
      register(world, handle, PLAYER)
      world:advance(5 * bridge.SWEEP_MS)
      assert.are.equal("character_select", api.players.get(handle).state)
      assert.is_false(fw.players[handle].alive)
      assert.are.same({ nil, "no_character" }, { api.money.balance(handle, "wallet") })
      assert.are.equal(1, bridge_logged(fw, "error", "DarkRP could not load"))
    end,
  },
  {
    name = "renames the character when the player's rpname changes, on the same key",
    run = function(world)
      local fw = framework()
      boot(world, fw)
      local api = world.api
      local handle = playing(world, fw)
      fw:rename(handle, "Jane Smith")
      assert.are.equal("active", api.players.get(handle).state)
      assert.are.same({ key = "CIT-JANE", name = "Jane Smith" }, api.characters.current(handle))
      fw:rename(handle, "   ")
      assert.are.same({ key = "CIT-JANE", name = "Unnamed" }, api.characters.current(handle))
    end,
  },
  {
    name = "reads the job as the team's command, with no grade, and follows a team change",
    run = function(world)
      local fw = framework()
      boot(world, fw)
      local api = world.api
      local handle = playing(world, fw)
      assert.are.same({ name = "police", grade = 0, on_duty = true }, api.jobs.current(handle))
      assert.is_true(fw:change_team(handle, "medic"))
      assert.are.same({ name = "medic", grade = 0, on_duty = true }, api.jobs.current(handle))
      fw.players[handle].team = 99
      assert.is_nil(api.jobs.current(handle), "a team that is no job")
      assert.is_false(api.jobs.supports("set"))
    end,
  },
  {
    name = "moves the wallet by exactly the amount, or answers unknown, and never below zero",
    run = function(world)
      local fw = framework()
      boot(world, fw)
      local api = world.api
      local handle = playing(world, fw)
      assert.are.same({ "wallet" }, api.money.accounts())
      assert.are.same({ nil, "not_found" }, { api.money.balance(handle, "bank") })
      assert.are.same({ nil, "refused", "no_account" }, { api.money.debit(handle, "bank", 1, "x", api.ops.new()) })
      assert.are.same({ nil, "refused", "no_account" }, { api.money.credit(handle, "bank", 1, "x", api.ops.new()) })
      assert.are.same({ nil, "refused", "insufficient_funds" }, { api.money.debit(handle, "wallet", 501, "x", api.ops.new()) })
      assert.is_true(api.money.debit(handle, "wallet", 500, "x", api.ops.new()))
      assert.are.equal(0, api.money.balance(handle, "wallet"))
      assert.are.same({ nil, "refused", "insufficient_funds" }, { api.money.debit(handle, "wallet", 1, "x", api.ops.new()) })
      -- An owner's `playerWalletChanged` hook replaced the total: the
      -- money moved, by an amount the bridge cannot vouch for.
      fw.preempt.playerWalletChanged = { 1000 }
      assert.are.same({ nil, "unknown" }, { api.money.credit(handle, "wallet", 10, "Refund", api.ops.new()) })
      assert.are.equal(1000, fw:balance("CIT-JANE", "wallet"))
      assert.are.equal(1, #api.ops.unknown())
      fw.preempt.playerWalletChanged = nil
      assert.is_true(api.money.credit(handle, "wallet", 10, "Refund", api.ops.new()))
      assert.are.equal(1010, fw:balance("CIT-JANE", "wallet"))
    end,
  },
  {
    name = "forgets a player who leaves, and finds their data again after a map change",
    run = function(world)
      local fw = framework()
      boot(world, fw)
      local api = world.api
      local handle = playing(world, fw)
      assert.is_true(api.money.debit(handle, "wallet", 100, "x", api.ops.new()))
      world.core.players.dropped(handle, "disconnected")
      fw:disconnect(handle)
      assert.are.same({ nil, "not_logged_in" }, { api.characters.current(handle) })
      -- A map change: a new Lua state over the same storage, where Gmod
      -- hands everyone over again and DarkRP loads their data again.
      fw:forget_listeners()
      world:restart()
      assert(darkrp_fake.register(world:as("rpf_darkrp"), fw))
      world:connect(COMPANION)
      api = world.api
      local again = join(world, fw, 1)
      assert.is_false(fw.players[again].alive)
      fw:restore(again, "CIT-JANE", "Jane Doe")
      register(world, again, PLAYER)
      assert.are.equal("active", api.players.get(again).state)
      assert.are.equal(400, api.money.balance(again, "wallet"))
    end,
  },
  {
    name = "answers unavailable when DarkRP is not the gamemode",
    run = function(world)
      local fw = framework()
      fw.running = false
      boot(world, fw)
      local api = world.api
      local handle = join(world, fw, 1)
      register(world, handle, PLAYER)
      assert.are.equal(1, world:logged("warn", "framework is unavailable (DarkRP is not the gamemode)"))
      assert.are.equal("character_select", api.players.get(handle).state)
      assert.are.same({ nil, "unavailable" }, { api.money.debit(handle, "wallet", 1, "x", api.ops.new()) })
    end,
  },
  {
    name = "warns of a DarkRP it was not tested with",
    run = function(world)
      local fw = framework()
      fw.version = "2.8.1"
      boot(world, fw)
      playing(world, fw)
      assert.are.equal(1, world:logged("warn", "was tested against 2.7, and its framework is 2.8.1"))
    end,
  },
  {
    name = "stays inactive on a native server, where DarkRP running is an error, and holds players until RPF's character is in play",
    run = function(world)
      local fw = framework()
      boot(world, fw, true)
      local api = world.api
      assert.are.equal(1, world:logged("error", "Set the server's profile to companion"))
      -- Jane, RPF's own character, which the portal hands over at the login.
      world.portal.owned[JANE] = {
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
      local handle = join(world, fw, 1)
      fw:restore(handle, "CIT-JANE", "Jane Doe")
      register(world, handle, PLAYER)
      assert.are.equal("character_select", api.players.get(handle).state, "RPF's own character screen")
      assert.is_false(fw.players[handle].alive, "still held")
      assert.is_false(fw:command(handle, "job"))
      world:select(handle, JANE)
      assert.are.equal("active", api.players.get(handle).state)
      assert.is_true(fw.players[handle].alive, "in play once RPF's character is")
      assert.is_true(fw:command(handle, "job"))
      assert.are.equal(JANE, api.characters.current(handle).key, "RPF's own, not DarkRP's")
    end,
  },
}

conformance.run(
  { describe = describe, it = it, before_each = before_each, after_each = after_each },
  "the darkrp bridge",
  cases,
  { "mock", "gmod" }
)
