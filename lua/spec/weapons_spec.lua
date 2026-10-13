-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Items that equip as the engine's weapons (L3), with the test playing the
-- portal and the engine: what `conformance_weapons_spec` cannot say the same
-- way on every engine (a weapon the engine does not know, which FiveM's
-- server cannot tell), the bounds, the report, config changes, and the
-- lists each side keeps that must agree with the portal's.

local support = require("spec.support")

local SERVER = "00000001-0000-4000-8000-000000000001"
local PLAYER = "00000002-0000-4000-8000-000000000002"
local JANE = "00000003-0000-4000-8000-000000000003"
local POCKETS = "00000004-0000-4000-8000-000000000004"

---Config versions applied so far, so each is a new one.
local version = 0

---An item as the snapshot carries it.
---@param slug string Its slug.
---@param fivem string? Its weapon's FiveM name, which the fake platform reads.
---@return table item The item.
local function item(slug, fivem)
  return {
    slug = slug,
    name = slug,
    weight = 1,
    size = { x = 1, y = 1 },
    stack_limit = 10,
    weapon = fivem and { fivem = fivem } or nil,
  }
end

---Applies a config with these items, as the portal's `config` request would.
---@param p spec.FakePlatform The platform.
---@param items table[] The items.
local function configure(p, items)
  local json = rpf.json
  local list = json.array()
  for i, entry in ipairs(items) do
    list[i] = json.object(entry)
  end
  local snapshot = json.object({
    settings = json.object({}),
    items = list,
    item_defaults = json.object({ weight = 1, size = json.object({ x = 1, y = 1 }), stack_limit = 1 }),
  })
  version = version + 1
  local text = assert(json.encode(snapshot))
  assert.is_true((rpf.config.apply(p, version, "h" .. version, assert(json.decode(text)))))
end

---The last frame of one type sent, or nil.
---@param p spec.FakePlatform The platform.
---@param tag string The type.
---@return rpf.Frame? frame The frame.
local function last_of(p, tag)
  local found = nil
  for _, frame in ipairs(p.frames()) do
    if frame.type == tag then
      found = frame
    end
  end
  return found
end

---Answers the last hold with these records.
---@param p spec.FakePlatform The platform.
---@param records table[] The records.
local function held(p, records)
  p.deliver(support.portal_frame("held", { re = assert(last_of(p, "hold")).id, records = records }))
end

describe("rpf.weapons", function()
  local p

  before_each(function()
    support.load_core()
    p = support.fake_platform()
    version = 0
    configure(p, { item("pistol", "WEAPON_PISTOL"), item("raygun", "WEAPON_NOPE"), item("water") })
    support.connected(p)
  end)

  ---Puts Jane in play for player 7, with what she has equipped and her
  ---pockets' stacks.
  ---@param weapons string[]? Equipped already, as the portal hands her over.
  ---@param stacks table[]? What her pockets hold: a pistol and a raygun unless given.
  local function playing(weapons, stacks)
    local json = rpf.json
    rpf.players.connected(7)
    rpf.players.authenticating(7)
    assert(rpf.players.register(7, { player_id = PLAYER, username = "sam" }))
    held(p, {
      {
        kind = "character",
        revision = 1,
        character = {
          id = JANE,
          server_id = SERVER,
          owner = { kind = "player", id = PLAYER },
          first_name = "Jane",
          last_name = "Doe",
          gender = "female",
          weapons = weapons and json.array(weapons) or nil,
        },
      },
    })
    assert.is_true(rpf.characters.select(7, JANE))
    held(p, {
      {
        kind = "container",
        revision = 1,
        container = {
          id = POCKETS,
          server_id = SERVER,
          owner = { kind = "character", id = JANE },
          name = "Pockets",
          flags = json.array({}),
          contents = json.object({
            layout = "list",
            stacks = json.array(stacks or { { item = "pistol", count = 1 }, { item = "raygun", count = 1 } }),
          }),
        },
      },
    })
    assert.are.equal("active", rpf.players.get(7).state)
  end

  it("refuses a weapon the engine does not know, and says once that one equipped is not given", function()
    p.unknown_weapons.WEAPON_NOPE = true
    playing({ "raygun" })
    assert.is_nil((p.weapons[7] or {}).WEAPON_NOPE, "not given")
    local warned = 0
    for _, line in ipairs(p.logs) do
      if line.message:find("raygun equips WEAPON_NOPE, which this engine does not know", 1, true) then
        warned = warned + 1
      end
    end
    assert.are.equal(1, warned)
    assert.are.same({ "raygun" }, rpf.weapons.equipped(7), "it stays equipped, as a job deleted from config does")

    assert.are.same({ nil, "refused", "unknown_weapon" }, { rpf.weapons.equip(7, "raygun") })
    assert.are.same({ true }, { rpf.weapons.equip(7, "pistol") })
    assert.is_true(p.weapons[7].WEAPON_PISTOL)
  end)

  it("gives a weapon the engine cannot vouch for as named", function()
    -- FiveM's answer for a weapon outside its stock list: nil, not false.
    local declared = p.capabilities.weapon
    p.capabilities.weapon = function(spec)
      return spec.fivem, nil
    end
    playing()
    assert.are.same({ true }, { rpf.weapons.equip(7, "raygun") })
    assert.is_true(p.weapons[7].WEAPON_NOPE)
    p.capabilities.weapon = declared
  end)

  it("reports what is equipped with the character, and nothing for a change that changes nothing", function()
    playing()
    p.advance(1000)
    local before = last_of(p, "state_changed")
    assert.is_true((rpf.weapons.equip(7, "pistol")))
    p.advance(1000)
    local report = assert(last_of(p, "state_changed"))
    assert.are_not.equal(before and before.id, report.id)
    local change = report.changes[1]
    assert.are.same({ "character", JANE, { "pistol" } }, { change.kind, change.id, change.weapons })

    assert.is_true((rpf.weapons.equip(7, "pistol")))
    p.advance(1000)
    assert.are.equal(report.id, assert(last_of(p, "state_changed")).id, "nothing new to report")

    assert.is_true((rpf.weapons.unequip(7, "pistol")))
    p.advance(1000)
    assert.are.same({}, assert(last_of(p, "state_changed")).changes[1].weapons, "none is [], never null")
  end)

  it("equips at most MAX_EQUIPPED, which is the portal's bound", function()
    local items, stacks = {}, {}
    for i = 1, rpf.weapons.MAX_EQUIPPED + 1 do
      items[i] = item("gun" .. i, "WEAPON_" .. i)
      stacks[i] = { item = "gun" .. i, count = 1 }
    end
    configure(p, items)
    playing(nil, stacks)
    for i = 1, rpf.weapons.MAX_EQUIPPED do
      assert.are.same({ true }, { rpf.weapons.equip(7, "gun" .. i) }, i)
    end
    assert.are.same(
      { nil, "refused", "too_many" },
      { rpf.weapons.equip(7, "gun" .. (rpf.weapons.MAX_EQUIPPED + 1)) }
    )

    local limits = support.portal_source("crates/rpf-domain/src/limits.rs", pending)
    local max = limits:match("pub const MAX_EQUIPPED_WEAPONS: usize = (%d+);")
    assert.truthy(max, "MAX_EQUIPPED_WEAPONS is no longer an integer literal")
    assert.are.equal(tonumber(max), rpf.weapons.MAX_EQUIPPED)
    assert.are.equal(rpf.weapons.MAX_EQUIPPED, rpf.records.MAX_EQUIPPED)
  end)

  it("takes a weapon back while config makes its item no weapon, and gives it again when it is one", function()
    playing()
    assert.is_true((rpf.weapons.equip(7, "pistol")))
    configure(p, { item("pistol"), item("raygun", "WEAPON_NOPE") })
    assert.is_nil(p.weapons[7].WEAPON_PISTOL, "taken back")
    assert.are.same({ "pistol" }, rpf.weapons.equipped(7), "still equipped")
    configure(p, { item("pistol", "WEAPON_PISTOL") })
    assert.is_true(p.weapons[7].WEAPON_PISTOL, "given again")
  end)

  it("keeps what is equipped while the pockets are lost to the portal", function()
    playing()
    assert.is_true((rpf.weapons.equip(7, "pistol")))
    rpf.records.lose({ { kind = "container", id = POCKETS } }, "taken back by staff")
    assert.is_nil(p.weapons[7].WEAPON_PISTOL, "nothing carries it now")
    assert.are.same({ "pistol" }, rpf.weapons.equipped(7), "but it is still equipped")
  end)

  it("takes an item off once it has left the character, before she can be put away", function()
    playing({ "pistol" })
    assert.is_true((rpf.inventory.remove(POCKETS, "raygun", 1)))
    assert.are.same({ "pistol" }, rpf.weapons.equipped(7), "another item leaving changes nothing")
    assert.is_true((rpf.inventory.remove(POCKETS, "pistol", 1)))
    assert.is_nil(p.weapons[7].WEAPON_PISTOL, "taken back")
    assert.is_true(rpf.characters.deselect(7))
    assert.are.same({}, rpf.records.weapons_of(assert(rpf.records.get("character", JANE))), "and off the list")
  end)

  it("emits a batch's contents changes once, after all its writes", function()
    playing()
    local seen = {}
    rpf.events.on("records.contents", function(id, before)
      seen[#seen + 1] = { id = id, items = rpf.inventory.items_in(before) }
    end)
    rpf.records.batch(function()
      assert.is_true((rpf.inventory.remove(POCKETS, "pistol", 1)))
      assert.are.equal(0, #seen, "not yet")
      assert.is_true((rpf.inventory.remove(POCKETS, "raygun", 1)))
    end)
    assert.are.same({ { id = POCKETS, items = { pistol = true, raygun = true } } }, seen, "once, with what it held first")
  end)

  it("tries again to take back a weapon the engine failed to strip", function()
    playing()
    assert.is_true((rpf.weapons.equip(7, "pistol")))
    local declared = p.capabilities.strip_weapon
    p.capabilities.strip_weapon = function()
      error("the engine said no")
    end
    assert.are.same({ true }, { rpf.weapons.unequip(7, "pistol") })
    assert.is_true(p.weapons[7].WEAPON_PISTOL, "the engine still has it")
    -- A client claiming a respawn it never had does not make it forgotten.
    rpf.weapons.spawned(7)
    assert.is_true(p.weapons[7].WEAPON_PISTOL)
    p.capabilities.strip_weapon = declared
    configure(p, { item("pistol", "WEAPON_PISTOL") })
    assert.is_nil(p.weapons[7].WEAPON_PISTOL, "taken back on the next sync")
  end)

  it("takes back what it gave as the server stops", function()
    playing()
    assert.is_true((rpf.weapons.equip(7, "pistol")))
    rpf.stop_server()
    assert.is_nil(p.weapons[7].WEAPON_PISTOL)
  end)

  it("ignores a client's respawn from a player not in play", function()
    rpf.players.connected(8)
    rpf.players.authenticating(8)
    assert(rpf.players.register(8, { player_id = "00000002-0000-4000-8000-0000000000bb", username = "jo" }))
    rpf.weapons.spawned(8)
    rpf.weapons.spawned(99)
    assert.is_nil(p.weapons[8])
    assert.are.same({ nil, "refused", "no_character" }, { rpf.weapons.equip(8, "pistol") })
  end)

  it("reads each engine's own name, and what that engine can say of it", function()
    local conformance = require("spec.support.conformance")
    local cases = {
      -- FiveM's server knows its stock weapons, in any case, names each in
      -- capitals as `GetHashKey` ignores case, and cannot tell of any other.
      fivem = {
        { { fivem = "weapon_pistol", gmod = "weapon_pistol" }, "WEAPON_PISTOL", true },
        { { fivem = "WEAPON_STREAMED_CUSTOM" }, "WEAPON_STREAMED_CUSTOM", nil },
        { { gmod = "weapon_pistol" }, nil, nil },
      },
      -- Gmod knows every class it lists or has stored, and nothing else.
      gmod = {
        { { fivem = "WEAPON_PISTOL", gmod = "weapon_pistol" }, "weapon_pistol", true },
        { { gmod = "weapon_nope" }, "weapon_nope", false },
        { { fivem = "WEAPON_PISTOL" }, nil, nil },
      },
    }
    for engine, list in pairs(cases) do
      local world = conformance.boot(engine)
      local weapon = assert(world.server_platform.capabilities.weapon)
      for _, case in ipairs(list) do
        local name, known = assert(weapon)(case[1])
        assert.are.same({ case[2], case[3] }, { name, known }, engine .. " " .. tostring(case[2]))
      end
      world.finish()
    end
    support.load_core()
  end)

  it("keeps FiveM's stock list equal to the portal's", function()
    rpf.fivem = rpf.fivem or {}
    local fivem = dofile(support.path("lua/platform/fivem/weapons.lua"))
    local corpus = assert(rpf.json.decode(support.read("protocol/corpus/weapons.json")))
    local listed = {}
    for i, name in ipairs(corpus.fivem) do
      listed[i] = name
    end
    assert.are.same(listed, fivem.STOCK)
    assert.is_true(fivem.known.WEAPON_PISTOL)
  end)
end)
