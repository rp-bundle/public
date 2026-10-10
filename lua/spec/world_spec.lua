-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The world's placements (`rpf.world`, J4), where they depend on the core
-- alone: the limit on what one server keeps placed, and an engine whose
-- adapter places nothing. The cases every engine must agree on are in
-- `conformance_world_spec.lua`.

local conformance = require("spec.support.conformance")

---A manifest with one world-backed config type of objects.
---@return table manifest The manifest.
local function manifest()
  return {
    namespace = "acme_props",
    version = "1.0.0",
    api = 1,
    title = "Props",
    types = {
      prop = {
        schema = 1,
        authority = "config",
        fields = {
          spot = { type = "vector3", required = true },
          model = { type = "string", engine = true, required = true },
        },
        world = { kind = "object", position = "spot", model = "model" },
      },
    },
  }
end

---Installs the addon with props `from` to `n`, as a portal push would.
---@param world spec.ConformanceWorld The world.
---@param n integer The last.
---@param from integer? The first; 1 unless given.
local function install(world, n, from)
  local json = world.core.json
  local records = {}
  for i = from or 1, n do
    records[#records + 1] = {
      id = string.format("%08x-0000-4000-8000-000000000000", i),
      type = "acme_props.prop",
      revision = 1,
      fields = { spot = { x = i, y = 0, z = 0 }, model = "crate" },
    }
  end
  local entry = conformance.installed(world.core, manifest())
  entry.records = assert(json.decode(assert(json.encode(json.array(records)))))
  world:install({ entry })
end

---How many lines the platform logged that contain `text`.
---@param world spec.ConformanceWorld The world.
---@param text string The text.
---@return integer count The count.
local function said(world, text)
  local count = 0
  for _, line in ipairs(world.logs) do
    if line.message:find(text, 1, true) then
      count = count + 1
    end
  end
  return count
end

describe("rpf.world's placements", function()
  local world

  before_each(function()
    world = conformance.boot("mock")
    assert(world.api.addons.register(manifest(), {}))
  end)

  after_each(function()
    world.finish()
  end)

  it("keeps at most MAX_PLACED placed, the first in id order, saying so once", function()
    local limit = world.core.world.MAX_PLACED
    world.core.world.MAX_PLACED = 2
    install(world, 3)
    install(world, 3)
    world.core.world.MAX_PLACED = limit
    local ids = {}
    for _, entity in ipairs(world.entities()) do
      ids[#ids + 1] = entity.placement
    end
    assert.are.same({ "00000001-0000-4000-8000-000000000000", "00000002-0000-4000-8000-000000000000" }, ids)
    assert.are.equal(1, said(world, "want an entity placed; the rest are left out"))
  end)

  it("keeps the first MAX_PLACED in order whatever was placed before, so the config alone decides", function()
    local limit = world.core.world.MAX_PLACED
    world.core.world.MAX_PLACED = 2
    install(world, 3, 2)
    install(world, 3)
    world.core.world.MAX_PLACED = limit
    local ids = {}
    for _, entity in ipairs(world.entities()) do
      ids[#ids + 1] = entity.placement
    end
    table.sort(ids)
    assert.are.same({ "00000001-0000-4000-8000-000000000000", "00000002-0000-4000-8000-000000000000" }, ids)
  end)

  it("places nothing on an engine whose adapter cannot, saying so once", function()
    world.server_platform.capabilities.spawn = false
    install(world, 2)
    install(world, 2)
    assert.are.same({}, world.entities())
    assert.are.equal(1, said(world, "places no entities; 2 ped and object records are left unplaced"))
    assert.is_false(world.api.capabilities().spawn)
  end)

  it("waits for a spawn that answers later, and removes an entity that arrives after its record went", function()
    local caps = world.server_platform.capabilities
    local answers, despawned = {}, {}
    caps.spawn = function(spec, done)
      answers[spec.id] = done
    end
    caps.despawn = function(ref)
      despawned[#despawned + 1] = ref
    end
    install(world, 2)
    assert.is_nil(world.api.world.placed("acme_props.prop", "00000001-0000-4000-8000-000000000000"), "not until it answers")
    answers["00000001-0000-4000-8000-000000000000"](11)
    assert.are.equal(11, world.api.world.placed("acme_props.prop", "00000001-0000-4000-8000-000000000000"))
    install(world, 1)
    answers["00000002-0000-4000-8000-000000000000"](22)
    assert.are.same({ 22 }, despawned, "its record went while it was being made")
    answers["00000002-0000-4000-8000-000000000000"](23)
    assert.are.same({ 22 }, despawned, "an answer is taken once")
  end)

  it("despawns everything and places nothing more once cleared", function()
    install(world, 2)
    assert.are.equal(2, #world.entities())
    world.core.world.clear()
    assert.are.same({}, world.entities())
    install(world, 2)
    world:advance(world.core.world.CHECK_MS)
    assert.are.same({}, world.entities())
  end)
end)
