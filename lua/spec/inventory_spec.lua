-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Inventory (D6): moves on held containers, driven by the config's catalog.
-- Every change is validated whole before it is applied, a refused one changes
-- nothing anywhere, only held containers change, and a change is reported to
-- the portal with the item data it does not read left exactly as it was. The
-- validator's rules themselves are the shared corpus's (containers_spec.lua).

local support = require("spec.support")

local SERVER = "00000001-0000-4000-8000-000000000001"
local CHARACTER = "00000003-0000-4000-8000-000000000003"
local BAG = "0000000a-0000-4000-8000-00000000000a"
local CRATE = "0000000b-0000-4000-8000-00000000000b"
local GRID = "0000000c-0000-4000-8000-00000000000c"
local STASH = "0000000d-0000-4000-8000-00000000000d"
local FLUSH = 1000

local json

---The config's item sections: water stacks to 4 and weighs 5, a 1x3 rifle
---never stacks, and anything else is 1x1, weighs 1 and stacks to 10.
---@return table snapshot A snapshot, marked as decoded.
local function snapshot()
  local function size(x, y)
    return json.object({ x = x, y = y })
  end
  return json.object({
    settings = json.object(),
    items = json.array({
      json.object({ slug = "rifle", name = "Rifle", weight = 40, size = size(1, 3), stack_limit = 1 }),
      json.object({ slug = "water", name = "Water", weight = 5, size = size(1, 1), stack_limit = 4 }),
    }),
    item_bases = json.array(),
    item_defaults = json.object({ weight = 1, size = size(1, 1), stack_limit = 10 }),
  })
end

---A list of stacks.
---@param ... table Each `{ item, count, data? }`.
---@return table contents Marked list contents.
local function list(...)
  local stacks = json.array()
  for i, s in ipairs({ ... }) do
    stacks[i] = json.object({ item = s[1], count = s[2], data = s[3] })
  end
  return json.object({ layout = "list", stacks = stacks })
end

---A held container record, as the portal's `held` names one.
---@param id string Its uuid.
---@param contents table Its contents.
---@param flags table[] Its flags.
---@return table record The record.
local function container(id, contents, flags)
  local marked = json.array()
  for i, flag in ipairs(flags) do
    local value = flag.value
    marked[i] = json.object({ flag = flag.flag, value = type(value) == "table" and json.object(value) or value })
  end
  return {
    kind = "container",
    revision = 1,
    container = {
      id = id,
      server_id = SERVER,
      owner = { kind = "character", id = CHARACTER },
      name = id,
      contents = contents,
      flags = marked,
    },
  }
end

---Every frame of one type sent so far.
---@param p spec.FakePlatform The platform.
---@param tag string The type.
---@return rpf.Frame[] frames The frames.
local function sent_of(p, tag)
  local out = {}
  for _, frame in ipairs(p.frames()) do
    if frame.type == tag then
      out[#out + 1] = frame
    end
  end
  return out
end

---The contents of a held container.
---@param id string Its uuid.
---@return table contents A copy.
local function contents_of(id)
  return rpf.records.get("container", id).contents
end

---A container's stacks as `{ item, count }` pairs, for comparing.
---@param id string Its uuid.
---@return table[] stacks The pairs, in order.
local function pairs_of(id)
  local out = {}
  local contents = contents_of(id)
  local stacks = contents.stacks
  if contents.layout == "grid" then
    stacks = {}
    for i, placement in ipairs(contents.placements) do
      stacks[i] = placement.stack
    end
  end
  for i, stack in ipairs(stacks) do
    out[i] = { stack.item, stack.count }
  end
  return out
end

---Where each placement of a grid container sits, as `"item@x,y"` strings.
---@param id string Its uuid.
---@return string[] spots The spots, in order.
local function spots_of(id)
  local out = {}
  for i, placement in ipairs(contents_of(id).placements) do
    local p = placement.position
    out[i] = placement.stack.item .. "@" .. p.x .. "," .. p.y .. (placement.rotated and "r" or "")
  end
  return out
end

describe("rpf.inventory", function()
  local p, inventory

  before_each(function()
    support.load_core()
    json = rpf.json
    inventory = rpf.inventory
    p = support.fake_platform()
    support.connected(p)
    assert.is_true((rpf.config.apply(p, 1, "h1", snapshot())))
    rpf.sync.hold({
      records = {
        { kind = "container", id = BAG },
        { kind = "container", id = CRATE },
        { kind = "container", id = GRID },
      },
    })
    local hold = sent_of(p, "hold")[1]
    p.deliver(support.portal_frame("held", {
      re = hold.id,
      records = {
        container(BAG, list({ "water", 3 }, { "rifle", 1, json.object({ serial = "A1", ammo = json.array({ 30 }) }) }), {
          { flag = "max_weight", value = 100 },
        }),
        container(CRATE, list(), { { flag = "max_weight", value = 20 } }),
        container(GRID, json.object({ layout = "grid", placements = json.array() }), {
          { flag = "grid", value = { x = 3, y = 3 } },
        }),
      },
    }))
  end)

  it("mirrors the portal's default catalog bounds and fallbacks", function()
    local source = support.portal_source("crates/rpf-domain/src/inventory.rs", pending)
    local default = assert(source:match("impl Default for ItemCatalog {(.-)\n}"))
    assert.is_truthy(default:find("default_weight: " .. inventory.DEFAULTS.weight .. ",", 1, true))
    assert.is_truthy(default:find(
      "default_size: IVector2::new(" .. inventory.DEFAULTS.size.x .. ", " .. inventory.DEFAULTS.size.y .. "),",
      1,
      true
    ))
    assert.is_truthy(default:find("default_stack_limit: " .. inventory.DEFAULTS.stack_limit .. ",", 1, true))
    assert.is_truthy(default:find("max_data_bytes: 4 * 1024,", 1, true))
    assert.are.equal(4 * 1024, inventory.MAX_DATA_BYTES)
    assert.is_truthy(default:find("max_stacks: " .. inventory.MAX_STACKS .. ",", 1, true))
  end)

  describe("the catalog", function()
    it("is the applied config's items and defaults", function()
      local catalog = inventory.catalog()
      assert.are.equal(4, catalog.lookup("water").stack_limit)
      assert.are.equal(10, catalog.defaults.stack_limit)
      assert.is_true(inventory.validate(list({ "anything", 10 }), {}, catalog))
      assert.is_nil(inventory.validate(list({ "water", 5 }), {}, catalog))
    end)

    it("falls back to the portal's defaults before any config", function()
      support.load_core()
      json = rpf.json
      local catalog = rpf.inventory.catalog()
      assert.are.same(rpf.inventory.DEFAULTS, catalog.defaults)
      assert.are.equal(rpf.inventory.MAX_STACKS, catalog.max_stacks)
      local _, refusal = rpf.inventory.validate(list({ "water", 2 }), {}, catalog)
      assert.are.same({ error = "stack_too_large", item = "water", count = 2, limit = 1 }, refusal)
    end)

    it("follows a config change at once", function()
      local changed = snapshot()
      changed.items[2].stack_limit = 2
      assert.is_true((rpf.config.apply(p, 2, "h2", changed)))
      local _, refusal = inventory.validate(list({ "water", 3 }), {}, inventory.catalog())
      assert.are.same({ error = "stack_too_large", item = "water", count = 3, limit = 2 }, refusal)
    end)
  end)

  it("refuses a flag it does not know rather than guess at its rule", function()
    local _, refusal = inventory.validate(list(), { { flag = "fragile", value = true } }, inventory.catalog())
    assert.are.same({ error = "unknown_flag", flag = "fragile" }, refusal)
  end)

  it("refuses text the portal could not decode as malformed", function()
    for _, bad in ipairs({ "\255", "\192\128", "\237\160\128", "\244\144\128\128", "caf\195" }) do
      local _, refusal = inventory.validate(list({ bad, 1 }), {}, inventory.catalog())
      assert.are.same({ error = "malformed" }, refusal)
      _, refusal = inventory.validate(list({ "water", 1, json.object({ note = bad }) }), {}, inventory.catalog())
      assert.are.same({ error = "malformed" }, refusal)
    end
    assert.is_true(inventory.validate(list({ "water", 1, json.object({ note = "caf\195\169 \240\159\141\186" }) }), {}, inventory.catalog()))
  end)

  describe("add", function()
    it("tops up stacks of the same item, then starts new ones within the limit", function()
      assert.is_true(inventory.add(BAG, "water", 6))
      assert.are.same({ { "water", 4 }, { "rifle", 1 }, { "water", 4 }, { "water", 1 } }, pairs_of(BAG))
      assert.are.equal(9, inventory.count(BAG, "water"))
    end)

    it("keeps units with different data in stacks of their own", function()
      assert.is_true(inventory.add(CRATE, "water", 1, { data = json.object({ note = "hi" }) }))
      assert.is_true(inventory.add(CRATE, "water", 1))
      assert.is_true(inventory.add(CRATE, "water", 1, { data = json.object({ note = "hi" }) }))
      assert.are.same({ { "water", 2 }, { "water", 1 } }, pairs_of(CRATE))
      assert.are.same({ note = "hi" }, contents_of(CRATE).stacks[1].data)
      assert.is_nil(contents_of(CRATE).stacks[2].data)
    end)

    it("refuses what breaks a rule, naming it, and changes nothing", function()
      local before = json.encode(contents_of(CRATE))
      local ok, err, refusal = inventory.add(CRATE, "water", 5)
      assert.is_nil(ok)
      assert.are.equal("invalid", err)
      assert.are.same({ error = "too_heavy", limit = 20, actual = 25 }, refusal)
      assert.are.equal(before, json.encode(contents_of(CRATE)))
      assert.is_nil(next(rpf.records.entries["container:" .. CRATE].changed), "nothing marked")
    end)

    it("refuses too many new stacks up front", function()
      local _, err, refusal = inventory.add(GRID, "rifle", 600)
      assert.are.equal("invalid", err)
      assert.are.same({ error = "too_many_stacks", count = 600, limit = 500 }, refusal)
    end)

    it("refuses arguments that are not a count, an item or data", function()
      for _, args in ipairs({
        { "water", 0 },
        { "water", 1.5 },
        { "water", -1 },
        { 7, 1 },
        { "water", 1, { data = { 1, 2 } } },
        { "water", 1, { position = { x = 0.5, y = 0 } } },
      }) do
        assert.are.same({ nil, "invalid_argument" }, { inventory.add(CRATE, args[1], args[2], args[3]) })
      end
    end)

    it("takes the first free spots in a grid, row by row, turning an item only if it must", function()
      assert.is_true(inventory.add(GRID, "rifle", 2))
      assert.is_true(inventory.add(GRID, "water", 4))
      assert.are.same({ "rifle@0,0", "rifle@1,0", "water@2,0" }, spots_of(GRID))
      assert.is_true(inventory.add(GRID, "water", 5))
      assert.are.same({ "rifle@0,0", "rifle@1,0", "water@2,0", "water@2,1", "water@2,2" }, spots_of(GRID))
      assert.are.same({ nil, "no_space" }, { inventory.add(GRID, "rifle", 1) })
      assert.are.equal(5, #contents_of(GRID).placements, "unchanged")
    end)

    it("lies an item down where it only fits turned", function()
      for x = 0, 2 do
        assert.is_true(inventory.add(GRID, "water", 1, { position = { x = x, y = 0 } }))
      end
      assert.is_true(inventory.add(GRID, "rifle", 1))
      assert.are.same("rifle@0,1r", spots_of(GRID)[4])
      assert.are.same({ nil, "no_space" }, { inventory.add(GRID, "rifle", 1, { rotated = false }) })
    end)

    it("puts units at a position, onto a matching placement already there", function()
      assert.is_true(inventory.add(GRID, "water", 2, { position = { x = 1, y = 1 } }))
      assert.is_true(inventory.add(GRID, "water", 1, { position = { x = 1, y = 1 } }))
      assert.are.same({ { "water", 3 } }, pairs_of(GRID))
      local _, err, refusal = inventory.add(GRID, "rifle", 1, { position = { x = 1, y = 0 } })
      assert.are.equal("invalid", err)
      assert.are.same({ error = "overlap", position = { x = 1, y = 1 } }, refusal)
      _, err, refusal = inventory.add(GRID, "rifle", 1, { position = { x = 2, y = 1 } })
      assert.are.equal("out_of_bounds", refusal.error)
      assert.are.same({ nil, "invalid_argument" }, { inventory.add(BAG, "water", 1, { position = { x = 0, y = 0 } }) })
    end)
  end)

  describe("remove", function()
    it("takes from the last matching stacks first, leaving no empty stack", function()
      assert.is_true(inventory.add(BAG, "water", 3))
      assert.are.same({ { "water", 4 }, { "rifle", 1 }, { "water", 2 } }, pairs_of(BAG))
      assert.is_true(inventory.remove(BAG, "water", 3))
      assert.are.same({ { "water", 3 }, { "rifle", 1 } }, pairs_of(BAG))
    end)

    it("takes only stacks with the data asked for", function()
      assert.are.same({ nil, "insufficient" }, { inventory.remove(BAG, "rifle", 1) })
      assert.is_true(inventory.remove(BAG, "rifle", 1, { data = json.object({ serial = "A1", ammo = json.array({ 30 }) }) }))
      assert.are.equal(0, inventory.count(BAG, "rifle"))
    end)

    it("refuses more than is there, and changes nothing", function()
      assert.are.same({ nil, "insufficient" }, { inventory.remove(BAG, "water", 4) })
      assert.are.same({ { "water", 3 }, { "rifle", 1 } }, pairs_of(BAG))
    end)
  end)

  -- The items half of an exchange (J5): a plan across containers, made
  -- whole before anything moves.
  describe("plan_moves", function()
    it("takes from each in turn and gives whole into the first that takes it, changing nothing", function()
      local changes = assert(inventory.plan_moves({ BAG, CRATE }, { { item = "water", count = 2 } }, { { item = "water", count = 4 } }))
      -- The bag weighs 3 water (15) and a rifle (40) of 100: taking two
      -- leaves 45, and four more (20) fit there.
      assert.are.equal(1, #changes)
      assert.are.equal(BAG, changes[1].id)
      assert.are.same({ { "water", 3 }, { "rifle", 1 } }, pairs_of(BAG), "nothing changed yet")
      assert.is_true(rpf.records.set_contents(changes[1].id, changes[1].contents))
      assert.are.same({ { "water", 4 }, { "rifle", 1 }, { "water", 1 } }, pairs_of(BAG))
    end)

    it("lets a take free the spot a give needs in a grid", function()
      for x = 0, 2 do
        for y = 0, 2 do
          assert.is_true(inventory.add(GRID, "water", 1, { position = { x = x, y = y } }))
        end
      end
      local gives = { { item = "rifle", count = 1 } }
      assert.are.same({ nil, "no_space", "rifle" }, { inventory.plan_moves({ GRID }, {}, gives) })
      local changes = assert(inventory.plan_moves({ GRID }, { { item = "water", count = 3 } }, gives))
      assert.is_true(rpf.records.set_contents(GRID, changes[1].contents))
      assert.are.equal(1, inventory.count(GRID, "rifle"))
    end)

    it("refuses too few units, no room, and no container, naming the item", function()
      assert.are.same({ nil, "insufficient", "water" }, { inventory.plan_moves({ BAG, CRATE }, { { item = "water", count = 4 } }, {}) })
      assert.are.same({ nil, "no_space", "rifle" }, { inventory.plan_moves({ CRATE }, {}, { { item = "rifle", count = 1 } }) })
      assert.are.same({ nil, "no_container" }, { inventory.plan_moves({}, {}, { { item = "water", count = 1 } }) })
      assert.are.same({ nil, "not_held" }, { inventory.plan_moves({ STASH }, {}, {}) })
    end)
  end)

  describe("move", function()
    it("moves part of a stack to another container", function()
      assert.is_true(inventory.move(BAG, 1, CRATE, { count = 2 }))
      assert.are.same({ { "water", 1 }, { "rifle", 1 } }, pairs_of(BAG))
      assert.are.same({ { "water", 2 } }, pairs_of(CRATE))
    end)

    it("moves a whole stack with its data", function()
      assert.is_true(inventory.move(BAG, 2, GRID, { position = { x = 2, y = 0 } }))
      assert.are.same({ { "water", 3 } }, pairs_of(BAG))
      assert.are.same({ "rifle@2,0" }, spots_of(GRID))
      assert.are.same({ serial = "A1", ammo = { 30 } }, contents_of(GRID).placements[1].stack.data)
    end)

    it("refuses a move either side would not take, and changes neither", function()
      local bag, crate = json.encode(contents_of(BAG)), json.encode(contents_of(CRATE))
      local ok, err, refusal, which = inventory.move(BAG, 2, CRATE)
      assert.is_nil(ok)
      assert.are.equal("invalid", err)
      assert.are.same({ error = "too_heavy", limit = 20, actual = 40 }, refusal)
      assert.are.equal(CRATE, which)
      assert.are.equal(bag, json.encode(contents_of(BAG)))
      assert.are.equal(crate, json.encode(contents_of(CRATE)))
      assert.is_nil(next(rpf.records.entries["container:" .. BAG].changed), "the source was not marked either")
    end)

    it("moves a placement within a grid", function()
      assert.is_true(inventory.add(GRID, "rifle", 1))
      assert.is_true(inventory.move(GRID, 1, GRID, { position = { x = 0, y = 2 }, rotated = true }))
      assert.are.same({ "rifle@0,2r" }, spots_of(GRID))
    end)

    it("refuses what it cannot find or count", function()
      assert.are.same({ nil, "no_stack" }, { inventory.move(BAG, 3, CRATE) })
      assert.are.same({ nil, "no_stack" }, { inventory.move(BAG, 0, CRATE) })
      assert.are.same({ nil, "invalid_argument" }, { inventory.move(BAG, 1, CRATE, { count = 4 }) })
      assert.are.same({ nil, "invalid_argument" }, { inventory.move(BAG, 1, CRATE, { count = 0 }) })
    end)
  end)

  describe("split", function()
    it("splits units into a stack of their own, beside the first in a list", function()
      assert.is_true(inventory.split(BAG, 1, 1))
      assert.are.same({ { "water", 2 }, { "water", 1 }, { "rifle", 1 } }, pairs_of(BAG))
    end)

    it("splits onto a free spot, or a given one, in a grid", function()
      assert.is_true(inventory.add(GRID, "water", 4))
      assert.is_true(inventory.split(GRID, 1, 1))
      assert.is_true(inventory.split(GRID, 1, 1, { position = { x = 2, y = 2 } }))
      assert.are.same({ "water@0,0", "water@1,0", "water@2,2" }, spots_of(GRID))
      assert.are.same({ { "water", 2 }, { "water", 1 }, { "water", 1 } }, pairs_of(GRID))
    end)

    it("refuses a split that leaves nothing behind", function()
      assert.are.same({ nil, "invalid_argument" }, { inventory.split(BAG, 1, 3) })
      assert.are.same({ nil, "invalid_argument" }, { inventory.split(BAG, 2, 1) })
      assert.are.same({ nil, "no_stack" }, { inventory.split(BAG, 9, 1) })
    end)
  end)

  describe("holding", function()
    it("changes only containers this server holds", function()
      assert.are.same({ nil, "not_held" }, { inventory.add(STASH, "water", 1) })
      assert.are.same({ nil, "not_held" }, { inventory.remove(STASH, "water", 1) })
      assert.are.same({ nil, "not_held" }, { inventory.move(BAG, 1, STASH) })
      assert.are.same({ nil, "not_held" }, { inventory.move(STASH, 1, BAG) })
      assert.are.same({ nil, "not_held" }, { inventory.split(STASH, 1, 1) })
      assert.are.same({ nil, "not_held" }, { inventory.count(STASH, "water") })
      assert.are.same({ { "water", 3 }, { "rifle", 1 } }, pairs_of(BAG), "nothing left the bag")

      assert.is_true(rpf.sync.release({ { kind = "container", id = CRATE } }))
      assert.are.same({ nil, "not_held" }, { inventory.add(CRATE, "water", 1) })
    end)

    it("reports a change, leaving the data it does not read exactly as it was", function()
      local data = json.encode(contents_of(BAG).stacks[2].data)
      assert.is_true(inventory.move(BAG, 1, CRATE, { count = 1 }))
      p.advance(FLUSH)

      local report = sent_of(p, "state_changed")[1]
      assert.are.equal(2, #report.changes)
      local by_id = {}
      for _, change in ipairs(report.changes) do
        by_id[change.id] = change
      end
      assert.are.equal(1, by_id[BAG].base_revision)
      assert.are.same({ { "water", 2 }, { "rifle", 1 } }, pairs_of(BAG))
      assert.are.equal(data, json.encode(by_id[BAG].contents.stacks[2].data), "byte for byte")
      assert.are.equal(1, by_id[CRATE].contents.stacks[1].count)
    end)
  end)
end)
