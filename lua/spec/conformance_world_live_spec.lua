-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Conformance (J6): a world-backed `live` type's records are placed while
-- this server holds them, on the mock platform and on the real FiveM and
-- Gmod adapters (`spec/support/conformance.lua`): placed as one is created
-- or claimed, moved, hidden and shown as the holder changes it, and removed
-- when it is deleted or let go.

local conformance = require("spec.support.conformance")

---What `conformance.run` needs from busted.
local busted = { describe = describe, it = it, before_each = before_each, after_each = after_each }

local PLANTER = "acme_beds.planter"
local SERVER = "00000001-0000-4000-8000-000000000001"
local CLAIMED = "0000000c-0000-4000-8000-00000000000c"

---How long a placement may take to arrive: FiveM makes an entity
---asynchronously, and the adapter looks for it every 50 ms.
local SETTLE_MS = 500

---Each engine's model for a planter: one record, placed on any engine.
local MODELS = { fivem = "prop_plant_01a", gmod = "models/props/cs_office/plant01.mdl", mock = "mock_planter" }

---An addon with one world-backed live type of objects, held by the server.
---@return table manifest The manifest.
local function manifest()
  return {
    namespace = "acme_beds",
    version = "1.0.0",
    api = 1,
    title = "Beds",
    types = {
      planter = {
        schema = 1,
        authority = "live",
        owners = { "server" },
        hold = "server",
        fields = {
          spot = { type = "vector3", required = true },
          model = { type = "json", engine = true, required = true },
          shown = { type = "boolean", default = true },
        },
        world = { kind = "object", position = "spot", model = "model", visible = "shown" },
      },
    },
  }
end

---Registers the addon, connects, and installs it, enabled unless `enabled`
---is false.
---@param world spec.ConformanceWorld The world.
---@param enabled boolean? Whether it is enabled.
local function installed(world, enabled)
  assert(world.api.addons.register(manifest()))
  world:connect()
  world:install({ conformance.installed(world.core, manifest(), enabled) })
  world:pump()
  world:advance(SETTLE_MS)
end

---Which records are placed, sorted.
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

---The entity placed for a record, if any.
---@param world spec.ConformanceWorld The world.
---@param id string The record.
---@return table? entity It.
local function entity_of(world, id)
  for _, entity in ipairs(world.entities()) do
    if entity.placement == id then
      return entity
    end
  end
  return nil
end

local OWNER = { owner = { kind = "server", id = SERVER } }

conformance.run(busted, "Live world placements", {
  {
    name = "places a live record it creates, moves, hides and shows it as it changes, and removes it once deleted",
    run = function(world)
      installed(world)
      local planter = assert(world.api.records.create(PLANTER, { spot = { x = 1, y = 2, z = 3 }, model = MODELS }, OWNER))
      world:advance(SETTLE_MS)
      local first = assert(entity_of(world, planter.id), "placed as it was created")
      assert.are.same({ x = 1, y = 2, z = 3 }, first.position)
      assert.are.equal(world.api.world.model(MODELS[world.api.engine]), first.model)
      assert.are.equal(first.ref, world.api.world.placed(PLANTER, planter.id))
      assert.are.same({ type = PLANTER, id = planter.id }, assert(world.api.world.entity(first.ref)).placement)

      assert(world.api.records.update(PLANTER, planter.id, { spot = { x = 4, y = 5, z = 6 } }))
      world:advance(SETTLE_MS)
      assert.are.same({ x = 4, y = 5, z = 6 }, assert(entity_of(world, planter.id)).position, "moved")
      assert(world.api.records.update(PLANTER, planter.id, { shown = false }))
      world:advance(SETTLE_MS)
      assert.are.same({}, placed_ids(world), "hidden")
      assert(world.api.records.update(PLANTER, planter.id, { shown = true }))
      world:advance(SETTLE_MS)
      assert.are.same({ planter.id }, placed_ids(world), "shown again")

      assert(world.api.records.delete(PLANTER, planter.id))
      world:advance(SETTLE_MS)
      assert.are.same({}, placed_ids(world), "deleted")
    end,
  },
  {
    name = "places what a claim brings, and removes it when staff disable the addon and it is let go",
    run = function(world)
      world.portal.records[CLAIMED] = {
        id = CLAIMED,
        type = PLANTER,
        owner = { kind = "server", id = SERVER },
        revision = 2,
        fields = { spot = { x = 7, y = 8, z = 9 }, model = MODELS, shown = true },
        held = false,
      }
      installed(world)
      assert.are.same({ CLAIMED }, placed_ids(world), "claimed and placed")
      world:install({ conformance.installed(world.core, manifest(), false) })
      world:settle()
      world:advance(SETTLE_MS)
      assert.is_false(world.portal.records[CLAIMED].held)
      assert.are.same({}, placed_ids(world))
    end,
  },
  {
    name = "places a burst of creates, and each once",
    run = function(world)
      installed(world)
      local ids = {}
      for i = 1, 12 do
        ids[i] = assert(world.api.records.create(PLANTER, { spot = { x = i, y = 0, z = 0 }, model = MODELS }, OWNER)).id
      end
      table.sort(ids)
      world:advance(SETTLE_MS)
      assert.are.same(ids, placed_ids(world))
      world:advance(world.core.world.CHECK_MS + SETTLE_MS)
      assert.are.equal(12, #world.entities(), "no doubles")
    end,
  },
  {
    name = "logs once a type whose held records cannot be read, places nothing for it meanwhile, and places it again once they can",
    run = function(world)
      installed(world)
      local planter = assert(world.api.records.create(PLANTER, { spot = { x = 1, y = 2, z = 3 }, model = MODELS }, OWNER))
      world:advance(SETTLE_MS)
      assert.are.same({ planter.id }, placed_ids(world))
      local data = world.core.data
      local list = data.list
      data.list = function()
        return nil, "inactive"
      end
      world:advance(world.core.world.CHECK_MS + SETTLE_MS)
      world:advance(world.core.world.CHECK_MS + SETTLE_MS)
      data.list = list
      assert.are.same({}, placed_ids(world), "nothing placed for a type it cannot read")
      local count = 0
      for _, line in ipairs(world.logs) do
        if line.level == "error" and line.message:find("could not read the records of " .. PLANTER .. " (inactive)", 1, true) then
          count = count + 1
        end
      end
      assert.are.equal(1, count, "said once, however often it was reconciled")
      world:advance(world.core.world.CHECK_MS + SETTLE_MS)
      assert.are.same({ planter.id }, placed_ids(world), "placed again")
    end,
  },
})
