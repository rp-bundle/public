-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Conformance (L3): items that equip as the engine's weapons, through
-- `rpf.api.inventory`, on the mock platform and on the real FiveM and Gmod
-- adapters over their fake globals. The engine's own calls (`GiveWeaponToPed`,
-- `Give`) stay in the adapters; these cases read the fake engine back. An
-- addon equips an item Jane carries, and the engine has the weapon until she
-- takes it off, loses the item or is put away; a respawn and a restart give
-- it back.

local conformance = require("spec.support.conformance")

---What `conformance.run` needs from busted.
local busted = { describe = describe, it = it, before_each = before_each, after_each = after_each }

local SERVER = "00000001-0000-4000-8000-000000000001"
local PLAYER = "00000002-0000-4000-8000-000000000002"
local JANE = "00000004-0000-4000-8000-000000000004"
local POCKETS = "00000009-0000-4000-8000-000000000009"
local BACKPACK = "0000000a-0000-4000-8000-00000000000a"

---The pistol's weapon on each engine, as the catalog names it.
local PISTOL = { fivem = "WEAPON_PISTOL", gmod = "weapon_pistol" }

---The portal's copies of Jane, her pockets, which hold a pistol and a
---bottle of water, and her empty backpack.
---@param world spec.ConformanceWorld The world.
---@param weapons string[]? What Jane has equipped, as the portal has it.
local function seed(world, weapons)
  local json = world.core.json
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
      weapons = weapons and json.array(weapons) or nil,
    },
  }
  world.portal.owned[POCKETS] = {
    kind = "container",
    revision = 1,
    data = {
      id = POCKETS,
      server_id = SERVER,
      owner = { kind = "character", id = JANE },
      name = "Pockets",
      contents = json.object({
        layout = "list",
        stacks = json.array({ { item = "pistol", count = 1 }, { item = "water", count = 1 } }),
      }),
      flags = json.array({}),
    },
  }
  world.portal.owned[BACKPACK] = {
    kind = "container",
    revision = 1,
    data = {
      id = BACKPACK,
      server_id = SERVER,
      owner = { kind = "character", id = JANE },
      name = "Backpack",
      contents = json.object({ layout = "list", stacks = json.array({}) }),
      flags = json.array({}),
    },
  }
end

---The config: the pistol, a knife Jane does not carry, both weapons, and
---water, which is not one.
---@param world spec.ConformanceWorld The world.
---@return table extra The snapshot's sections.
local function config(world)
  local json = world.core.json
  ---An item as the snapshot carries it.
  ---@param slug string Its slug.
  ---@param weapon table? Its weapon.
  ---@return table item The item.
  local function item(slug, weapon)
    return { slug = slug, name = slug, weight = 1, size = { x = 1, y = 1 }, stack_limit = 10, weapon = weapon }
  end
  return {
    items = json.array({
      item("pistol", { fivem = PISTOL.fivem, gmod = PISTOL.gmod, ammo = "pistol_ammo" }),
      item("knife", { fivem = "WEAPON_KNIFE", gmod = "weapon_crowbar" }),
      item("water"),
    }),
    item_defaults = { weight = 1, size = { x = 1, y = 1 }, stack_limit = 1 },
  }
end

---A world with Jane in play, standing somewhere, so the engine has a body
---to give a weapon to.
---@param world spec.ConformanceWorld The world.
---@param weapons string[]? What she has equipped already.
---@return any handle Her engine handle.
local function playing(world, weapons)
  seed(world, weapons)
  world:connect()
  world:install({}, config(world))
  world:pump()
  local handle = world:login(1, PLAYER)
  world.place(1, { x = 0, y = 0, z = 0 })
  world:select(handle, JANE)
  return handle
end

conformance.run(busted, "weapons", {
  {
    name = "equips a carried weapon, which the engine gives, and takes it back off",
    run = function(world)
      local handle = playing(world)
      local inventory = world.api.inventory
      assert.is_true(inventory.supports("equip"))
      assert.is_false(world.holds(1, PISTOL))

      assert.are.same({ true }, { inventory.equip(handle, "pistol") })
      assert.is_true(world.holds(1, PISTOL), "the engine has it")
      assert.are.same({ "pistol" }, inventory.equipped(handle))
      assert.are.same({ true }, { inventory.equip(handle, "pistol") }, "again, nothing changes")
      assert.are.same({ "pistol" }, inventory.equipped(handle))

      assert.are.same({ true }, { inventory.unequip(handle, "pistol") })
      assert.is_false(world.holds(1, PISTOL), "taken back")
      assert.are.same({}, inventory.equipped(handle))
      assert.are.same({ true }, { inventory.unequip(handle, "pistol") }, "not equipped is fine")
    end,
  },
  {
    name = "refuses what is no weapon, what the character does not carry, and a player with no character",
    run = function(world)
      local handle = playing(world)
      local inventory = world.api.inventory
      assert.are.same({ nil, "refused", "not_a_weapon" }, { inventory.equip(handle, "water") })
      assert.are.same({ nil, "refused", "not_a_weapon" }, { inventory.equip(handle, "nothing") }, "no such item")
      assert.are.same({ nil, "refused", "no_item" }, { inventory.equip(handle, "knife") })
      assert.are.same({ nil, "refused", "not_a_weapon" }, { inventory.equip(handle, 42) }, "not a slug")
      assert.are.same({}, inventory.equipped(handle))

      local other = world:login(2, "00000002-0000-4000-8000-0000000000aa")
      assert.are.same({ nil, "refused", "no_character" }, { inventory.equip(other, "pistol") })
      assert.are.same({ nil, "no_character" }, { inventory.equipped(other) })
    end,
  },
  {
    name = "gives an equipped weapon again after a respawn, and once there is a body",
    run = function(world)
      local handle = playing(world)
      local inventory = world.api.inventory
      world.unspawn(1)
      assert.are.same({ true }, { inventory.equip(handle, "pistol") }, "equipped with no body to give it to")
      assert.is_false(world.holds(1, PISTOL))
      world.respawn(1)
      assert.is_true(world.holds(1, PISTOL), "given as they spawn")

      world.respawn(1)
      assert.is_true(world.holds(1, PISTOL), "and every time")
    end,
  },
  {
    name = "takes the weapon back when the character stops carrying the item",
    run = function(world)
      local handle = playing(world)
      local api = world.api
      assert.is_true((api.inventory.equip(handle, "pistol")))
      assert.are.same({ true }, { api.inventory.take(handle, "pistol", 1, api.ops.new()) })
      assert.is_false(world.holds(1, PISTOL), "taken back with the item")
      world:advance(0)
      assert.are.same({}, api.inventory.equipped(handle), "and taken off")
    end,
  },
  {
    name = "keeps the weapon equipped while the item moves between the character's containers",
    run = function(world)
      local handle = playing(world)
      local inventory = world.core.inventory
      assert.is_true((world.api.inventory.equip(handle, "pistol")))
      -- The pockets are written first, without the pistol, then the backpack.
      assert.are.same({ true }, { inventory.move(POCKETS, 1, BACKPACK) })
      world:advance(0)
      assert.are.same({ "pistol" }, world.api.inventory.equipped(handle), "still equipped")
      assert.is_true(world.holds(1, PISTOL), "and still held")

      -- Out of the backpack and away: now it is gone.
      assert.are.same({ true }, { inventory.remove(BACKPACK, "pistol", 1) })
      world:advance(0)
      assert.are.same({}, world.api.inventory.equipped(handle))
      assert.is_false(world.holds(1, PISTOL))
    end,
  },
  {
    name = "takes back what it gave when the character is put away, and gives it again when she is back",
    run = function(world)
      local handle = playing(world)
      assert.is_true((world.api.inventory.equip(handle, "pistol")))
      assert.is_true(world.core.characters.deselect(handle))
      world:pump()
      world:advance(0)
      assert.is_false(world.holds(1, PISTOL))

      world:select(handle, JANE)
      world:advance(0)
      assert.are.same({ "pistol" }, world.api.inventory.equipped(handle), "still equipped")
      assert.is_true(world.holds(1, PISTOL), "and given again")
    end,
  },
  {
    name = "reports what is equipped, and gives it back after a restart",
    run = function(world)
      local handle = playing(world)
      assert.is_true((world.api.inventory.equip(handle, "pistol")))
      world:settle()
      local reported = world.portal.owned[JANE].data.weapons
      assert.are.same({ "pistol" }, reported, "the portal has it")
      world:restart(world:snapshot())
      -- The portal hands Jane over as it stored her, weapons and all.
      handle = playing(world, { "pistol" })
      assert.is_true(world.holds(1, PISTOL), "given as she goes into play")
      assert.are.same({ "pistol" }, world.api.inventory.equipped(handle))
    end,
  },
})
