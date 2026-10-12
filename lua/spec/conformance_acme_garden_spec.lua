-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Conformance (J6): the timed sample, `lua/examples/acme_garden/`, run as it
-- ships on the mock platform and on the real FiveM and Gmod adapters,
-- against a fake portal (`spec/support/conformance.lua`). A plant is sown
-- where the player stands and placed in the world, grows through its stages
-- on time it keeps in its own fields, is watered, harvested and pulled up
-- through interactions aimed at it, comes back after a restart having
-- caught up no more than its bound, is on the map it was sown on (#369), and
-- keeps its records across the schema upgrades, through the public API
-- alone.

local conformance = require("spec.support.conformance")
local support = require("spec.support")

---What `conformance.run` needs from busted.
local busted = { describe = describe, it = it, before_each = before_each, after_each = after_each }

local PLAYER = "00000002-0000-4000-8000-000000000002"
local OTHER = "00000003-0000-4000-8000-000000000003"
local TYPE = "acme_garden.plant"

---How long a placement may take to arrive: FiveM makes an entity
---asynchronously.
local SETTLE_MS = 500

---Loads the example's server half as an engine entry point does, with its
---manifest as `edit` leaves it, and starts it on the world's API.
---@param world spec.ConformanceWorld The world.
---@param edit fun(garden: acme_garden)? Changes before it starts, such as an older release's manifest.
---@return acme_garden garden The example's table.
local function load_example(world, edit)
  rawset(_G, "acme_garden", nil)
  dofile(support.path("lua/examples/acme_garden/manifest.lua"))
  dofile(support.path("lua/examples/acme_garden/server.lua"))
  local garden = rawget(_G, "acme_garden")
  -- The mock engine's model, beside FiveM's and Gmod's, so a plant is
  -- placed on every platform the cases run on.
  garden.MANIFEST.types.plant.fields.model.default.mock = "mock_plant"
  if edit then
    edit(garden)
  end
  assert(garden.start_server(world.api))
  return garden
end

---Release 1.1.0: schema 2, before plants were on a map.
---@param garden acme_garden The example's table.
local function release_two(garden)
  local m = garden.MANIFEST
  m.version = "1.1.0"
  m.types.plant.schema = 2
  m.types.plant.fields.map = nil
  m.types.plant.world.map = nil
  -- 1.1.0's code knew nothing of maps either: its plants carry none.
  local sow = garden.sow
  garden.sow = function(rpf, player)
    local records = setmetatable({
      create = function(type_, fields, opts)
        fields.map = nil
        return rpf.records.create(type_, fields, opts)
      end,
    }, { __index = rpf.records })
    return sow(setmetatable({ records = records }, { __index = rpf }), player)
  end
end

---Release 1.0.0: schema 1, before plants needed water.
---@param garden acme_garden The example's table.
local function release_one(garden)
  release_two(garden)
  local m = garden.MANIFEST
  m.version = "1.0.0"
  m.types.plant.schema = 1
  m.types.plant.fields.water = nil
  m.types.plant.list = { "stage", "planted_at" }
  -- 1.0.0's code knew nothing of water either.
  local grow = garden.grow
  garden.grow = function(fields, ticks)
    local patch = grow(fields, ticks)
    if patch then
      patch.water = nil
    end
    return patch
  end
end

---Connects, starts the example, has staff install it, and logs a player in,
---in the world, at a patch of soil.
---@param world spec.ConformanceWorld The world.
---@param edit fun(garden: acme_garden)? As for `load_example`.
---@return integer player The harness's number for the player.
local function gardening(world, edit)
  local garden = load_example(world, edit)
  world:connect()
  world:install({ conformance.installed(world.core, garden.MANIFEST) })
  world:pump()
  assert.are.equal("active", (world.api.addons.state("acme_garden")))
  world:activate(world:login(1, PLAYER))
  world.place(1, { x = 10, y = 20, z = 30 })
  return 1
end

---How many requests the harness's clients have numbered.
local numbered = 0

---Sends an interaction from a player's client and gives the server's
---answer (as `conformance_acme_tags_spec.lua` does).
---@param world spec.ConformanceWorld The world.
---@param player integer The player.
---@param name string The interaction.
---@param payload table? Its payload.
---@return table? answer The decoded answer, or nil if none came.
local function interact(world, player, name, payload)
  local json = world.core.json
  local before = #world.to_clients
  local body = assert(json.encode(json.object({ name = name, payload = payload and json.object(payload) or nil })))
  numbered = numbered + 1
  world.from_client(player, "rpf:interact", numbered .. "\n" .. body)
  for i = before + 1, #world.to_clients do
    local sent = world.to_clients[i]
    if sent.name == "rpf:interact" then
      local _, reply = sent.payload:match("^(%d+)\n(.*)$")
      return json.decode(reply)
    end
  end
  return nil
end

---Sows a plant for player 1 and gives it.
---@param world spec.ConformanceWorld The world.
---@return rpf.Record plant The plant.
local function sown(world)
  local answer = assert(interact(world, 1, "acme_garden.sow"))
  assert.is_true(answer.ok, tostring(answer.reason))
  local plants = assert(world.api.records.list(TYPE))
  -- The create reaches the portal and is answered, so changes made after it
  -- are reported as they come.
  world:settle()
  return plants[#plants]
end

---A plant as this server holds it now.
---@param world spec.ConformanceWorld The world.
---@param id string The plant.
---@return rpf.Record? plant It.
local function plant_now(world, id)
  return world.api.records.get(TYPE, id)
end

---Aims an interaction at a plant.
---@param world spec.ConformanceWorld The world.
---@param player integer The player.
---@param name string The interaction.
---@param id string The plant.
---@return table answer The answer.
local function at(world, player, name, id)
  return assert(interact(world, player, name, { target = { id = id } }))
end

conformance.run(busted, "the acme_garden example", {
  {
    name = "reaches a plant from a step away on every engine, in the engine's own units",
    run = function(world)
      gardening(world)
      local garden = rawget(_G, "acme_garden")
      local plant = sown(world)
      local step = world:units(1.5)
      world.place(1, { x = 10 + step, y = 20, z = 30 })
      assert.is_true(at(world, 1, "acme_garden.water", plant.id).ok, "a metre and a half away")
      world.place(1, { x = 10 + world:units(3), y = 20, z = 30 })
      local far = at(world, 1, "acme_garden.water", plant.id)
      assert.are.same({ false, "too_far" }, { far.ok, far.reason }, "three metres away")
    end,
  },
  {
    name = "sows a seed where the player stands and places it in the world; the portal keeps it",
    run = function(world)
      gardening(world)
      local plant = sown(world)
      assert.are.same({ x = 10, y = 20, z = 30 }, plant.fields.spot)
      assert.are.equal("seed", plant.fields.stage)
      assert.are.equal(100, plant.fields.water)
      assert.are.same({ kind = "player", id = PLAYER }, plant.owner)
      world:advance(SETTLE_MS)
      local placed = world.api.world.placed(TYPE, plant.id)
      assert.is_truthy(placed, "placed as an object while held")
      assert.are.same({ type = TYPE, id = plant.id }, assert(world.api.world.entity(placed)).placement)
      world:settle()
      assert.are.equal("seed", world.portal.records[plant.id].fields.stage)
    end,
  },
  {
    name = "grows through its stages on its own clock, dries, and withers if never watered",
    run = function(world)
      gardening(world)
      local garden = rawget(_G, "acme_garden")
      local plant = sown(world)
      world:advance(garden.SPROUT_TICKS * garden.TICK_MS)
      assert.are.equal("sprout", assert(plant_now(world, plant.id)).fields.stage)
      world:advance((garden.GROWN_TICKS - garden.SPROUT_TICKS) * garden.TICK_MS)
      local grown = assert(plant_now(world, plant.id))
      assert.are.equal("grown", grown.fields.stage)
      assert.are.equal(100 - garden.GROWN_TICKS * garden.THIRST, grown.fields.water)
      world:advance(30 * garden.TICK_MS)
      assert.are.equal("withered", plant_now(world, plant.id).fields.stage)
      world:settle()
      assert.are.equal("withered", world.portal.records[plant.id].fields.stage, "reported like any change")
    end,
  },
  {
    name = "waters anyone's plant, but harvests and pulls up only the gardener's own",
    run = function(world)
      gardening(world)
      local garden = rawget(_G, "acme_garden")
      world:activate(world:login(2, OTHER))
      world.place(2, { x = 10, y = 21, z = 30 })
      local plant = sown(world)
      world:advance(10 * garden.TICK_MS)
      assert.is_true(at(world, 2, "acme_garden.water", plant.id).ok, "a neighbour may water it")
      assert.are.equal(100, plant_now(world, plant.id).fields.water)
      local early = at(world, 1, "acme_garden.harvest", plant.id)
      assert.are.same({ false, "It is not ready." }, { early.ok, early.reason })
      world:advance(20 * garden.TICK_MS)
      assert.are.equal("grown", plant_now(world, plant.id).fields.stage)
      local theirs = at(world, 2, "acme_garden.harvest", plant.id)
      assert.are.same({ false, "That is someone else's to harvest." }, { theirs.ok, theirs.reason })
      assert.is_false(at(world, 2, "acme_garden.uproot", plant.id).ok)
      assert.is_true(at(world, 1, "acme_garden.harvest", plant.id).ok)
      assert.is_nil(plant_now(world, plant.id), "harvested")
      world:settle()
      world:advance(SETTLE_MS)
      assert.is_nil(world.portal.records[plant.id], "the portal deleted it too")
      assert.is_nil(world.api.world.placed(TYPE, plant.id), "and it left the world")

      local second = sown(world)
      assert.is_true(at(world, 1, "acme_garden.uproot", second.id).ok, "pulled up as a seed")
      assert.is_nil(plant_now(world, second.id))
    end,
  },
  {
    name = "comes back after a restart, held again by the core, having caught up no more than its bound",
    run = function(world)
      gardening(world)
      local garden = rawget(_G, "acme_garden")
      local plant = sown(world)
      world:advance(6 * garden.TICK_MS)
      assert.are.equal(6, plant_now(world, plant.id).fields.grown_ticks)
      assert.is_true(world.core.stop_server())
      world:restart()
      -- Down for two hours, then back.
      world:advance(2 * 60 * 60 * 1000)
      garden = load_example(world)
      world:connect()
      world:pump()
      local back = assert(plant_now(world, plant.id), "claimed back without the addon holding anything")
      assert.are.equal(6, back.fields.grown_ticks)
      world:advance(garden.TICK_MS)
      local caught = plant_now(world, plant.id).fields
      assert.are.equal(6 + garden.MAX_CATCH_UP_MS / garden.TICK_MS, caught.grown_ticks, "two hours away count as the bound")
      assert.are.equal("sprout", caught.stage)
      world:advance(SETTLE_MS)
      assert.is_truthy(world.api.world.placed(TYPE, plant.id), "placed again")
    end,
  },
  {
    name = "sows a plant on the map the server runs, and places it only there",
    run = function(world)
      gardening(world)
      local here = assert(world.api.world.map())
      local plant = sown(world)
      assert.are.equal(here, plant.fields.map, "the map is set in game")
      local other = assert(world.api.records.create(TYPE, {
        spot = { x = 10, y = 20, z = 30 },
        map = "rp_elsewhere",
        planted_at = world.api.time.now(),
        ticked_at = world.api.time.now(),
      }, { owner = { kind = "player", id = PLAYER } }))
      world:advance(SETTLE_MS)
      assert.is_truthy(world.api.world.placed(TYPE, plant.id), "placed on its map")
      assert.is_nil(world.api.world.placed(TYPE, other.id), "not placed on another")
      local water = at(world, 1, "acme_garden.water", other.id)
      assert.are.same({ false, "not_found" }, { water.ok, water.reason }, "nor can a client tend it")
    end,
  },
  {
    name = "keeps its plants through the upgrade that added map, which an older plant is on every map for",
    run = function(world)
      gardening(world, release_two)
      local plant = sown(world)
      assert.is_nil(plant.fields.map, "release 1.1.0 has no map")
      -- Release 1.2.0 replaces the code, and staff install it.
      local garden = load_example(world)
      world:install({ conformance.installed(world.core, garden.MANIFEST) })
      world:pump()
      assert.are.equal("active", (world.api.addons.state("acme_garden")))
      local upgraded = assert(plant_now(world, plant.id), "still held across the reload")
      assert.is_nil(upgraded.fields.map, "none: it stays on every map")
      world:advance(SETTLE_MS)
      assert.is_truthy(world.api.world.placed(TYPE, plant.id), "and still placed")
      assert.is_true(at(world, 1, "acme_garden.water", plant.id).ok, "and tended")
    end,
  },
  {
    name = "keeps its plants through the upgrade that added water, which an older plant reads as full",
    run = function(world)
      gardening(world, release_one)
      local plant = sown(world)
      assert.is_nil(plant.fields.water, "release 1.0.0 has no water")
      world:advance(rawget(_G, "acme_garden").TICK_MS)
      assert.are.equal(1, plant_now(world, plant.id).fields.grown_ticks, "1.0.0 grows it")
      world:settle()
      -- Release 1.1.0 replaces the code, and staff install it.
      local garden = load_example(world)
      world:install({ conformance.installed(world.core, garden.MANIFEST) })
      world:pump()
      assert.are.equal("active", (world.api.addons.state("acme_garden")))
      local upgraded = assert(plant_now(world, plant.id), "still held across the reload")
      assert.are.equal(100, upgraded.fields.water, "the new field's default")
      world:advance(garden.TICK_MS)
      assert.are.equal(100 - garden.THIRST, plant_now(world, plant.id).fields.water, "and it drinks from then on")
    end,
  },
})

describe("acme_garden.grow", function()
  before_each(function()
    rawset(_G, "acme_garden", nil)
    dofile(support.path("lua/examples/acme_garden/manifest.lua"))
    dofile(support.path("lua/examples/acme_garden/server.lua"))
  end)

  it("moves a plant through its stages by whole ticks, and stops once withered", function()
    local garden = rawget(_G, "acme_garden")
    assert.is_nil(garden.grow({ stage = "seed", water = 100, grown_ticks = 0 }, 0))
    assert.are.same({ water = 98, grown_ticks = 1, stage = "seed" }, garden.grow({ stage = "seed", water = 100, grown_ticks = 0 }, 1))
    assert.are.equal("sprout", garden.grow({ stage = "seed", water = 100, grown_ticks = 9 }, 1).stage)
    assert.are.equal("grown", garden.grow({ stage = "sprout", water = 50, grown_ticks = 29 }, 1).stage)
    assert.are.same({ water = 0, grown_ticks = 31, stage = "withered" }, garden.grow({ stage = "grown", water = 2, grown_ticks = 30 }, 4))
    assert.is_nil(garden.grow({ stage = "withered", water = 0, grown_ticks = 31 }, 5))
    assert.are.equal(98, garden.grow({ stage = "seed", grown_ticks = 0 }, 1).water, "a schema 1 plant starts full")
  end)
end)
