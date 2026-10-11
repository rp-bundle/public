-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Conformance (J6): when live addon records are held, by their type's `hold`
-- policy (`rpf.holding`), on the mock platform and on the real FiveM and Gmod
-- adapters, against a fake portal (`spec/support/conformance.lua`). A
-- `server` type's records are claimed after connecting and every minute, an
-- `owner` type's come and go with their owner's session, and what a stop
-- or a disable releases follows the installation, not the code.

local conformance = require("spec.support.conformance")

---What `conformance.run` needs from busted.
local busted = { describe = describe, it = it, before_each = before_each, after_each = after_each }

local PLAYER = "00000002-0000-4000-8000-000000000002"
local SERVER = "00000001-0000-4000-8000-000000000001"

---A grove: trees held by the server, huts held with their owner, rocks held
---on demand.
---@param version string? The release.
---@param hut_hold string|false? The huts' `hold`: `owner` unless given, false for none.
---@return table manifest The manifest.
local function grove(version, hut_hold)
  local label = { label = { type = "string" } }
  if hut_hold == nil then
    hut_hold = "owner"
  end
  return {
    namespace = "acme_grove",
    version = version or "1.0.0",
    api = 1,
    title = "Grove",
    types = {
      tree = { schema = 1, authority = "live", owners = { "player", "character", "server" }, hold = "server", fields = label },
      hut = { schema = 1, authority = "live", owners = { "player", "character", "server" }, hold = hut_hold or nil, fields = label },
      rock = { schema = 1, authority = "live", owners = { "server" }, fields = label },
    },
  }
end

---A record id, numbered.
---@param n integer The number.
---@return string id The id.
local function id(n)
  return string.format("%08x-0000-4000-8000-%012x", 0x100 + n, n)
end

---Puts a record nobody holds in the fake portal.
---@param world spec.ConformanceWorld The world.
---@param n integer Its number.
---@param type_name string Its type.
---@param owner table Its owner.
---@return string id Its id.
local function stored(world, n, type_name, owner)
  local record_id = id(n)
  world.portal.records[record_id] = {
    id = record_id,
    type = "acme_grove." .. type_name,
    owner = owner,
    revision = 2,
    fields = { label = "#" .. n },
    held = false,
  }
  return record_id
end

---Registers the grove, connects, and installs it, enabled unless `enabled`
---is false.
---@param world spec.ConformanceWorld The world.
---@param enabled boolean? Whether it is enabled.
local function installed(world, enabled)
  assert(world.api.addons.register(grove()))
  world:connect()
  world:install({ conformance.installed(world.core, grove(), enabled) })
  world:pump()
end

---Whether this server holds a record.
---@param world spec.ConformanceWorld The world.
---@param record_id string The record.
---@return boolean held True if held here.
local function held(world, record_id)
  return world.core.records.is_held("addon_record", record_id)
end

---The claims the portal read, by the types each named.
---@param world spec.ConformanceWorld The world.
---@return table[] claims Each claim's `types`.
local function claims(world)
  local out = {}
  for _, frame in ipairs(world.portal.frames) do
    if frame.type == "hold" and frame.types then
      out[#out + 1] = frame.types
    end
  end
  return out
end

local server = { kind = "server", id = SERVER }
local player = { kind = "player", id = PLAYER }

conformance.run(busted, "live record holds", {
  {
    name = "claims its server's records once installed, a page at a time, and nobody's session's",
    run = function(world)
      local trees = {}
      for n = 1, 40 do
        trees[n] = stored(world, n, "tree", n % 2 == 0 and server or player)
      end
      local servers_hut = stored(world, 41, "hut", server)
      local players_hut = stored(world, 42, "hut", player)
      local rock = stored(world, 43, "rock", server)
      installed(world)
      for _, tree in ipairs(trees) do
        assert.is_true(held(world, tree), tree)
      end
      assert.is_true(held(world, servers_hut), "a server's record of an owner type has no session to wait for")
      assert.is_false(held(world, players_hut), "a player's comes with their session")
      assert.is_false(held(world, rock), "held on demand")
      local seen = claims(world)
      assert.are.equal(2, #seen, "a full page, then the rest")
      assert.are.same({ "acme_grove.hut", "acme_grove.tree" }, seen[1])
    end,
  },
  {
    name = "picks up a record created in the portal within a minute",
    run = function(world)
      installed(world)
      local tree = stored(world, 1, "tree", server)
      assert.is_false(held(world, tree))
      world:advance(world.core.holding.CLAIM_MS)
      world:pump()
      assert.is_true(held(world, tree))
    end,
  },
  {
    name = "claims nothing while its installation is disabled",
    run = function(world)
      local tree = stored(world, 1, "tree", server)
      installed(world, false)
      assert.are.equal(0, #claims(world))
      assert.is_false(held(world, tree))
    end,
  },
  {
    name = "keeps its policy records when its code stops, and lets what it held on demand go",
    run = function(world)
      local tree = stored(world, 1, "tree", server)
      local rock = stored(world, 2, "rock", server)
      installed(world)
      local got = nil
      assert(world.api.records.hold("acme_grove.rock", { rock }, function(records, err)
        got = err or #records
      end))
      world:pump()
      assert.are.equal(1, got)
      -- The files and the portal now disagree: the code stops, the
      -- installation stays enabled.
      world:install({ conformance.installed(world.core, grove("1.0.1")) })
      world:pump()
      assert.are.equal("mismatch", (world.api.addons.state("acme_grove")))
      world:settle()
      assert.is_true(held(world, tree), "the server's to keep, code or not")
      assert.is_true(world.portal.records[tree].held)
      assert.is_false(held(world, rock))
      assert.is_false(world.portal.records[rock].held, "released with its final state")
    end,
  },
  {
    name = "lets everything go when staff disable it, a session's records too, and takes them back when enabled",
    run = function(world)
      local tree = stored(world, 1, "tree", server)
      local hut = stored(world, 2, "hut", player)
      installed(world)
      world:login(1, PLAYER)
      assert.is_true(held(world, hut), "held with the player's session")
      assert.is_true(held(world, tree))
      world:install({ conformance.installed(world.core, grove(), false) })
      world:settle()
      assert.is_false(held(world, tree))
      assert.is_false(held(world, hut), "the drain takes a session's too")
      assert.is_false(world.portal.records[tree].held)
      assert.is_false(world.portal.records[hut].held)
      world:install({ conformance.installed(world.core, grove()) })
      world:pump()
      assert.is_true(held(world, tree), "claimed again")
      assert.is_true(held(world, hut), "held again for the player who is still here")
      local key = world.core.records.key("addon_record", hut)
      assert.are.equal(PLAYER, world.core.records.entries[key].through)
    end,
  },
  {
    name = "a record an addon creates for a player who is here goes when they leave",
    run = function(world)
      installed(world)
      local handle = world:login(1, PLAYER)
      local hut = assert(world.api.records.create("acme_grove.hut", { label = "home" }, { owner = player }))
      local tree = assert(world.api.records.create("acme_grove.tree", { label = "oak" }, { owner = player }))
      world:settle()
      world.core.players.dropped(handle, "left")
      world:settle()
      assert.is_false(held(world, hut.id), "released with the session")
      assert.is_false(world.portal.records[hut.id].held)
      assert.are.equal("home", world.portal.records[hut.id].fields.label)
      assert.is_true(held(world, tree.id), "a server type's stays")
    end,
  },
  {
    name = "a session hold takes over an owner type's record held for the server",
    run = function(world)
      installed(world)
      local hut = assert(world.api.records.create("acme_grove.hut", { label = "home" }, { owner = player }))
      world:settle()
      local key = world.core.records.key("addon_record", hut.id)
      assert.is_nil(world.core.records.entries[key].through, "nobody's session yet")
      -- The portal hands it over as its owner's: as it would after the
      -- create landed.
      world.portal.records[hut.id].held = false
      world:login(1, PLAYER)
      assert.are.equal(PLAYER, world.core.records.entries[key].through)
    end,
  },
  {
    name = "a clean stop keeps what changed since the last report, and the next start claims the records back",
    run = function(world)
      local tree = stored(world, 1, "tree", server)
      installed(world)
      assert(world.api.records.update("acme_grove.tree", tree, { label = "felled" }))
      -- No flush yet: a crash here would lose it.
      assert.is_true(world.core.stop_server())
      world:restart()
      assert(world.api.addons.register(grove()))
      world:connect()
      world:pump()
      assert.are.equal("felled", world.portal.records[tree].fields.label, "sent from the outbox")
      assert.is_true(held(world, tree), "claimed after the declaration")
    end,
  },
  {
    name = "a clean stop keeps a change made behind a create the portal has not answered",
    run = function(world)
      installed(world)
      local tree = assert(world.api.records.create("acme_grove.tree", { label = "seedling" }, { owner = server }))
      -- The create goes out, and nothing answers it yet.
      world:advance(1000)
      assert(world.api.records.update("acme_grove.tree", tree.id, { label = "sapling" }))
      assert.is_true(world.core.stop_server(), "every change is on disk")
      world:restart()
      world:connect()
      world:pump()
      assert.are.equal("sapling", world.portal.records[tree.id].fields.label, "queued behind its create")
    end,
  },
  {
    name = "drains a claim the portal answered before staff disabled the addon, landing after",
    run = function(world)
      local tree = stored(world, 1, "tree", server)
      assert(world.api.addons.register(grove()))
      world:connect()
      -- Enabled, so the core claims; the claim is on its way, unanswered,
      -- when the disable arrives.
      world:install({ conformance.installed(world.core, grove()) })
      world:install({ conformance.installed(world.core, grove(), false) })
      world:pump()
      world:settle()
      assert.is_false(held(world, tree), "drained as it landed")
      assert.is_false(world.portal.records[tree].held)
    end,
  },
  {
    name = "putting a character away releases its own records, never one the server holds",
    run = function(world)
      local jane = "0000000f-0000-4000-8000-00000000000f"
      world.portal.owned[jane] = {
        kind = "character",
        revision = 1,
        data = {
          id = jane,
          server_id = SERVER,
          owner = player,
          first_name = "Jane",
          last_name = "Doe",
          gender = "female",
        },
      }
      local character = { kind = "character", id = jane }
      local tree = stored(world, 1, "tree", character)
      local hut = stored(world, 2, "hut", character)
      installed(world)
      local handle = world:login(1, PLAYER)
      world:select(handle, jane)
      assert.is_true(held(world, tree))
      assert.is_true(held(world, hut), "brought by the selection")
      assert(world.core.characters.deselect(handle))
      world:settle()
      assert.is_false(held(world, hut), "put away with her")
      assert.is_true(held(world, tree), "the server's to keep")
      assert.is_true(world.portal.records[tree].held)
    end,
  },
  {
    name = "holds the records of players already here when an upgrade gives a type its owner's hold",
    run = function(world)
      local hut = stored(world, 1, "hut", player)
      assert(world.api.addons.register(grove("1.0.0", false)))
      world:connect()
      world:install({ conformance.installed(world.core, grove("1.0.0", false)) })
      world:pump()
      world:login(1, PLAYER)
      assert.is_false(held(world, hut), "held on demand, so nobody took it")
      world:install({ conformance.installed(world.core, grove("1.1.0")) })
      world:pump()
      assert.is_true(held(world, hut), "held for her session")
      assert.are.equal(PLAYER, world.core.records.entries[world.core.records.key("addon_record", hut)].through)
    end,
  },
  {
    name = "gives back what a late session hold brought of a character put away meanwhile",
    run = function(world)
      local jane = "0000000f-0000-4000-8000-00000000000f"
      world.portal.owned[jane] = {
        kind = "character",
        revision = 1,
        data = { id = jane, server_id = SERVER, owner = player, first_name = "Jane", last_name = "Doe", gender = "female" },
      }
      local hut = stored(world, 1, "hut", { kind = "character", id = jane })
      assert(world.api.addons.register(grove("1.0.0", false)))
      world:connect()
      world:install({ conformance.installed(world.core, grove("1.0.0", false)) })
      world:pump()
      local handle = world:login(1, PLAYER)
      world:select(handle, jane)
      -- The upgrade's session hold goes out, and she is put away before it
      -- is answered.
      world:install({ conformance.installed(world.core, grove("1.1.0")) })
      assert(world.core.characters.deselect(handle))
      world:pump()
      world:settle()
      assert.is_false(held(world, hut), "not left held with nothing in play")
      assert.is_false(world.portal.records[hut].held)
    end,
  },
  {
    name = "keeps a record held when its type moves from its owner's hold to the server's and the owner leaves",
    run = function(world)
      local hut = stored(world, 1, "hut", player)
      installed(world)
      local handle = world:login(1, PLAYER)
      assert.is_true(held(world, hut))
      world:install({ conformance.installed(world.core, grove("1.1.0", "server")) })
      world:pump()
      world.core.players.dropped(handle, "left")
      world:settle()
      assert.is_true(held(world, hut), "the server's now")
      assert.is_true(world.portal.records[hut].held)
    end,
  },
  {
    name = "holds for the server a record a session hold brings after its type became the server's",
    run = function(world)
      installed(world)
      world:install({ conformance.installed(world.core, grove("1.1.0", "server")) })
      world:pump()
      -- A session hold the portal answered while huts were still held with
      -- their owner, arriving now.
      local hut = id(1)
      local json = world.core.json
      world.core.records.take({
        {
          kind = "addon_record",
          revision = 2,
          record = { id = hut, type = "acme_grove.hut", owner = player, fields = json.object({ label = "late" }) },
        },
      }, PLAYER)
      assert.is_true(held(world, hut))
      assert.is_nil(world.core.records.entries[world.core.records.key("addon_record", hut)].through, "the server's")
    end,
  },
  {
    name = "keeps a server record an addon's own hold brought after its code stopped",
    run = function(world)
      local tree = stored(world, 1, "tree", server)
      local rock = stored(world, 2, "rock", server)
      -- Claimed by nothing yet: the portal refuses claims for now.
      world.portal.refuse = { hold = "retry" }
      installed(world)
      world.portal.refuse = nil
      assert.is_false(held(world, tree))
      assert(world.api.records.hold("acme_grove.tree", { tree }))
      assert(world.api.records.hold("acme_grove.rock", { rock }))
      -- The code stops (the files and the portal disagree) before either
      -- hold is answered.
      world:install({ conformance.installed(world.core, grove("1.0.1")) })
      world:pump()
      world:settle()
      assert.is_true(held(world, tree), "the server's, code or not")
      assert.is_false(held(world, rock), "held on demand, so it goes back")
    end,
  },
  {
    name = "a record an addon creates for a character not in play is held for the server, not the session",
    run = function(world)
      local jane = "0000000f-0000-4000-8000-00000000000f"
      world.portal.owned[jane] = {
        kind = "character",
        revision = 1,
        data = { id = jane, server_id = SERVER, owner = player, first_name = "Jane", last_name = "Doe", gender = "female" },
      }
      installed(world)
      local handle = world:login(1, PLAYER)
      local character = { owner = { kind = "character", id = jane } }
      local away = assert(world.api.records.create("acme_grove.hut", { label = "shed" }, character))
      local key = world.core.records.key("addon_record", away.id)
      assert.is_nil(world.core.records.entries[key].through, "she is not in play")
      world:select(handle, jane)
      local home = assert(world.api.records.create("acme_grove.hut", { label = "home" }, character))
      assert.are.equal(PLAYER, world.core.records.entries[world.core.records.key("addon_record", home.id)].through)
    end,
  },
})

describe("rpf.holding", function()
  it("claims no bigger a page than the portal hands over, `limits::MAX_CLAIMED_PER_HOLD`", function()
    local support = require("spec.support")
    local core = support.load_core()
    local limits = support.read("crates/rpf-domain/src/limits.rs")
    local value = assert(limits:match("pub const MAX_CLAIMED_PER_HOLD: usize = (%d+);"))
    assert.are.equal(tonumber(value), core.holding.MAX_CLAIMED)
  end)
end)
