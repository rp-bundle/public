-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Conformance (J4): world placements and the world API, the same cases on
-- the mock platform and on the real FiveM and Gmod adapters
-- (`spec/support/conformance.lua`). A world-backed `config` type's ped and
-- object records are placed by the core through each adapter, kept placed
-- once each, moved, hidden and removed as the config says, and placed again
-- when something else deletes them.

local conformance = require("spec.support.conformance")

---What `conformance.run` needs from busted.
local busted = { describe = describe, it = it, before_each = before_each, after_each = after_each }

local GREETER = "acme_npcs.greeter"
local A = "0000000a-0000-4000-8000-00000000000a"
local B = "0000000b-0000-4000-8000-00000000000b"
local PLAYER = "00000002-0000-4000-8000-000000000002"

---How long a placement may take to arrive: FiveM makes an entity
---asynchronously, and the adapter looks for it every 50 ms.
local SETTLE_MS = 500

---Each engine's model for the greeters: one record, placed on any engine.
local MODELS = { fivem = "a_m_y_business_01", gmod = "models/humans/group01/male_02.mdl", mock = "mock_greeter" }

---An addon with one world-backed config type of peds.
---@return table manifest The manifest.
local function manifest()
  return {
    namespace = "acme_npcs",
    version = "1.0.0",
    api = 1,
    title = "NPCs",
    types = {
      greeter = {
        schema = 1,
        authority = "config",
        fields = {
          spot = { type = "vector3", required = true },
          heading = { type = "number", default = 0 },
          bucket = { type = "integer", min = 0, default = 0 },
          model = { type = "json", engine = true, required = true },
          shown = { type = "boolean", default = true },
        },
        world = { kind = "ped", position = "spot", heading = "heading", bucket = "bucket", model = "model", visible = "shown" },
      },
    },
  }
end

---A greeter record as the config carries it.
---@param id string Its id.
---@param fields table? Fields over the defaults.
---@return table record The record.
local function greeter(id, fields)
  local out = {
    spot = { x = 10, y = 20, z = 30 },
    heading = 90,
    bucket = 0,
    model = MODELS,
    shown = true,
  }
  for key, value in pairs(fields or {}) do
    out[key] = value
  end
  return { id = id, type = GREETER, revision = 1, fields = out }
end

---Installs the addon with these greeters, as a portal push would.
---@param world spec.ConformanceWorld The world.
---@param records table[] The greeters.
---@param enabled boolean? False to install it disabled.
local function install(world, records, enabled)
  local json = world.core.json
  local entry = conformance.installed(world.core, manifest(), enabled)
  entry.records = assert(json.decode(assert(json.encode(json.array(records)))))
  world:install({ entry })
  world:advance(SETTLE_MS)
end

---Registers the addon, so it runs once installed.
---@param world spec.ConformanceWorld The world.
local function register(world)
  assert(world.api.addons.register(manifest(), {}))
  world:advance(SETTLE_MS)
end

---Which records are placed, in ref order.
---@param world spec.ConformanceWorld The world.
---@return string[] ids Their ids.
local function placed_ids(world)
  local out = {}
  for _, entity in ipairs(world.entities()) do
    out[#out + 1] = entity.placement
  end
  table.sort(out)
  return out
end

conformance.run(busted, "World placements", {
  {
    name = "places each visible greeter once, with this engine's model, and no more for a config pushed again",
    run = function(world)
      register(world)
      install(world, { greeter(A), greeter(B, { shown = false }) })
      local entities = world.entities()
      assert.are.equal(1, #entities)
      local placed = entities[1]
      assert.are.equal(A, placed.placement)
      assert.are.same({ x = 10, y = 20, z = 30 }, placed.position)
      assert.are.equal(world.api.world.model(MODELS[world.api.engine]), placed.model)
      assert.are.equal(placed.ref, world.api.world.placed(GREETER, A))
      assert.is_nil(world.api.world.placed(GREETER, B), "a hidden greeter is not placed")

      install(world, { greeter(A), greeter(B, { shown = false }) })
      world:advance(world.core.world.CHECK_MS + SETTLE_MS)
      local again = world.entities()
      assert.are.equal(1, #again)
      assert.are.equal(placed.ref, again[1].ref, "the same entity, not another")
    end,
  },
  {
    name = "moves a greeter staff moved, shows one they showed, and removes one they deleted",
    run = function(world)
      register(world)
      install(world, { greeter(A), greeter(B, { shown = false }) })
      install(world, { greeter(A, { spot = { x = 1, y = 2, z = 3 } }), greeter(B) })
      assert.are.same({ A, B }, placed_ids(world))
      for _, entity in ipairs(world.entities()) do
        if entity.placement == A then
          assert.are.same({ x = 1, y = 2, z = 3 }, entity.position)
        end
      end
      install(world, { greeter(B) })
      assert.are.same({ B }, placed_ids(world))
      install(world, {})
      assert.are.same({}, world.entities())
    end,
  },
  {
    name = "places nothing for an addon that is not running, and removes what it had when it stops",
    run = function(world)
      install(world, { greeter(A) })
      assert.are.same({}, world.entities(), "installed but not loaded here")
      register(world)
      assert.are.same({ A }, placed_ids(world))
      install(world, { greeter(A) }, false)
      assert.are.same({}, world.entities(), "disabled")
    end,
  },
  {
    name = "places a greeter again when something else deleted its entity",
    run = function(world)
      register(world)
      install(world, { greeter(A) })
      local first = world.entities()[1].ref
      world.delete_entity(first)
      assert.are.same({}, world.entities())
      world:advance(world.core.world.CHECK_MS + SETTLE_MS)
      local entities = world.entities()
      assert.are.equal(1, #entities)
      assert.are.equal(A, entities[1].placement)
      assert.are.equal(entities[1].ref, world.api.world.placed(GREETER, A))
      assert.is_truthy(world:logged("info", "is gone; placing it again"))
    end,
  },
  {
    name = "turns metres into the engine's units and back by the scale its adapter declares",
    run = function(world)
      local api = world.api.world
      -- The scale is the harness's own table, not read from the adapter.
      for _, metres in ipairs({ 0, 1, 2.5, -4, 1000 }) do
        local units = assert(api.units(metres))
        assert.is_true(math.abs(units - world:units(metres)) < 1e-9, metres .. " m is " .. units)
        local back = assert(api.metres(units))
        assert.is_true(math.abs(back - metres) < 1e-9, units .. " units is " .. back)
      end
      assert.are.equal(world:units(1), (api.units(1)))
      for _, bad in ipairs({ "1", {}, true, 0 / 0, math.huge, -math.huge }) do
        for _, convert in ipairs({ api.units, api.metres }) do
          local none, err = convert(bad)
          assert.is_nil(none, tostring(bad))
          assert.are.equal("invalid", err, tostring(bad))
        end
      end
      local none, err = api.units(nil)
      assert.is_nil(none)
      assert.are.equal("invalid", err)
    end,
  },
  {
    name = "names a placed entity's record, and nothing for a ref that names nothing",
    run = function(world)
      register(world)
      install(world, { greeter(A) })
      local ref = world.entities()[1].ref
      local entity = assert(world.api.world.entity(ref))
      assert.are.same({ type = GREETER, id = A }, entity.placement)
      assert.are.same({ x = 10, y = 20, z = 30 }, entity.position)
      assert.are.equal(0, entity.bucket)
      for _, bad in ipairs({ ref + 7777, "1", 1.5, -0.5, {} }) do
        local none, err = world.api.world.entity(bad)
        assert.is_nil(none, tostring(bad))
        assert.are.equal("not_found", err, tostring(bad))
      end
    end,
  },
  {
    name = "puts a greeter in its bucket where the engine has buckets, and leaves it out where it has one world",
    run = function(world)
      register(world)
      install(world, { greeter(A, { bucket = 3 }) })
      if world.api.capabilities().bucket then
        local entities = world.entities()
        assert.are.equal(1, #entities)
        assert.are.equal(3, entities[1].bucket)
      else
        assert.are.same({}, world.entities())
        assert.is_truthy(world:logged("warn", "could not place " .. GREETER .. " " .. A))
      end
    end,
  },
  {
    name = "leaves a greeter in a bucket no engine has unplaced, never in the public world, saying so once",
    run = function(world)
      register(world)
      install(world, { greeter(A, { bucket = 2147483648 }) })
      install(world, { greeter(A, { bucket = 2147483648 }) })
      assert.are.same({}, world.entities())
      local said = 0
      for _, line in ipairs(world.logs) do
        if line.message:find("is none an engine has", 1, true) then
          said = said + 1
        end
      end
      assert.are.equal(1, said)
    end,
  },
  {
    name = "leaves a greeter with no model for this engine unplaced, saying so once",
    run = function(world)
      register(world)
      install(world, { greeter(A, { model = { elsewhere = "x" } }) })
      assert.are.same({}, world.entities())
      world:advance(world.core.world.CHECK_MS * 3)
      local said = 0
      for _, line in ipairs(world.logs) do
        if line.message:find("could not place", 1, true) then
          said = said + 1
        end
      end
      assert.are.equal(1, said)
    end,
  },
  {
    name = "says which bucket a logged-in player is in",
    run = function(world)
      world:connect()
      local handle = world:login(1, PLAYER)
      world:activate(handle)
      assert.are.equal(0, (world.api.world.bucket(handle)))
      if world.set_bucket then
        world.set_bucket(1, 2)
        assert.are.equal(2, (world.api.world.bucket(handle)))
      end
      local none, err = world.api.world.bucket(99)
      assert.is_nil(none)
      assert.are.equal("not_found", err)
    end,
  },
  {
    name = "places what the stored config holds after a restart, before the portal is reached",
    run = function(world)
      register(world)
      install(world, { greeter(A) })
      world:restart()
      assert.are.same({}, world.entities(), "the addon has not registered in the new process yet")
      register(world)
      assert.are.same({ A }, placed_ids(world), "from the stored config: no socket has opened")
    end,
  },
  {
    name = "removes every placed entity when the framework's resource stops",
    origins = true,
    run = function(world)
      register(world)
      install(world, { greeter(A), greeter(B) })
      assert.are.equal(2, #world.entities())
      world.stop()
      assert.are.same({}, world.entities())
    end,
  },
})
