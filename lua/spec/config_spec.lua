-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The applied config: typed lookups over the snapshot, `config.changed`
-- naming exactly the sections that differ, and persistence that survives a
-- restart as one unit.

local support = require("spec.support")

---A snapshot as it would arrive off the wire: decoded, so every table is
---marked as an array or an object.
---@param text string The snapshot's JSON.
---@return table snapshot The decoded snapshot.
local function snapshot(text)
  return assert(rpf.json.decode(text))
end

local FIRST = [[{
  "settings": { "starting_cash": 500, "motd": "hi", "unset": null },
  "items": [ { "slug": "water", "weight": 1 }, { "slug": "bread", "weight": 2 } ],
  "employers": [ { "slug": "lspd", "name": "LSPD" } ],
  "jobs": [ { "slug": "officer", "employer": "lspd" } ]
}]]

describe("rpf.config", function()
  local p, changes

  before_each(function()
    support.load_core()
    p = support.fake_platform()
    changes = {}
    rpf.events.on("config.changed", function(change)
      changes[#changes + 1] = change
    end)
  end)

  it("answers nil before any config has arrived", function()
    assert.is_nil(rpf.config.item("water"))
    assert.is_nil(rpf.config.job("officer"))
    assert.is_nil(rpf.config.setting("motd"))
    assert.is_nil(rpf.config.version())
  end)

  it("looks items, jobs, employers and settings up by slug or key", function()
    assert.is_true((rpf.config.apply(p, 3, "h3", snapshot(FIRST))))
    assert.are.equal(2, rpf.config.item("bread").weight)
    assert.are.equal("lspd", rpf.config.job("officer").employer)
    assert.are.equal("LSPD", rpf.config.employer("lspd").name)
    assert.are.equal(500, rpf.config.setting("starting_cash"))
    assert.are.equal(3, rpf.config.version())
    assert.is_nil(rpf.config.item("nothing"))
    ---@diagnostic disable-next-line: param-type-mismatch
    assert.is_nil(rpf.config.item(nil))
  end)

  it("keeps a setting sent as null apart from one never sent", function()
    rpf.config.apply(p, 3, "h3", snapshot(FIRST))
    assert.are.equal(rpf.json.null, rpf.config.setting("unset"))
    assert.is_nil(rpf.config.setting("absent"))
  end)

  it("returns copies, so a script cannot change what every other module reads", function()
    rpf.config.apply(p, 3, "h3", snapshot(FIRST))
    local water = rpf.config.item("water")
    water.weight = 999
    assert.are.equal(1, rpf.config.item("water").weight)
  end)

  it("announces every section on the first snapshot", function()
    rpf.config.apply(p, 3, "h3", snapshot(FIRST))
    assert.are.same({ { version = 3, sections = { "employers", "items", "jobs", "settings" } } }, changes)
  end)

  it("announces only the sections that changed, whatever the key order", function()
    rpf.config.apply(p, 3, "h3", snapshot(FIRST))
    rpf.config.apply(
      p,
      4,
      "h4",
      snapshot([[{
        "jobs": [ { "employer": "lspd", "slug": "officer" } ],
        "employers": [ { "name": "LSPD", "slug": "lspd" } ],
        "items": [ { "slug": "water", "weight": 1 }, { "slug": "bread", "weight": 3 } ],
        "settings": { "unset": null, "motd": "hi", "starting_cash": 500 }
      }]])
    )
    assert.are.same({ version = 4, sections = { "items" } }, changes[2])
  end)

  it("announces a section that appears or disappears, including one it does not index", function()
    rpf.config.apply(p, 3, "h3", snapshot(FIRST))
    rpf.config.apply(p, 4, "h4", snapshot([[{
      "settings": { "starting_cash": 500, "motd": "hi", "unset": null },
      "items": [ { "slug": "water", "weight": 1 }, { "slug": "bread", "weight": 2 } ],
      "employers": [ { "slug": "lspd", "name": "LSPD" } ],
      "shops": [ ]
    }]]))
    assert.are.same({ "jobs", "shops" }, changes[2].sections)
    assert.is_nil(rpf.config.job("officer"))
  end)

  it("stays quiet when a new version changes nothing", function()
    rpf.config.apply(p, 3, "h3", snapshot(FIRST))
    rpf.config.apply(p, 4, "h4", snapshot(FIRST))
    assert.are.equal(1, #changes)
    assert.are.equal(4, rpf.config.version())
  end)

  for _, case in ipairs({
    { "a list section that is not an array", [[{ "items": { "slug": "water" } }]] },
    { "a map section that is not an object", [[{ "settings": [1] }]] },
    { "an entry without a slug", [[{ "items": [ { "weight": 1 } ] }]] },
    { "two entries with one slug", [[{ "jobs": [ { "slug": "a" }, { "slug": "a" } ] }]] },
  }) do
    it("refuses " .. case[1] .. " and keeps the config it had", function()
      rpf.config.apply(p, 3, "h3", snapshot(FIRST))
      local stored = p.store[rpf.config.KEY]
      local ok, err = rpf.config.apply(p, 4, "h4", snapshot(case[2]))
      assert.is_false(ok)
      assert.is_string(err)
      assert.are.equal(3, rpf.config.version())
      assert.are.equal(stored, p.store[rpf.config.KEY])
      assert.are.equal(1, #changes)
      assert.are.equal(1, #p.logged("error", "refused a config snapshot"))
    end)
  end

  it("refuses a version that is not a non-negative integer, or a missing hash", function()
    local s = snapshot(FIRST)
    assert.is_false((rpf.config.apply(p, -1, "h", s)))
    assert.is_false((rpf.config.apply(p, 1.5, "h", s)))
    ---@diagnostic disable-next-line: param-type-mismatch
    assert.is_false((rpf.config.apply(p, 1, nil, s)))
    assert.is_nil(rpf.config.version())
  end)

  it("persists the snapshot before announcing it, so a handler that reads the store sees it", function()
    local seen
    rpf.events.on("config.changed", function()
      seen = p.store[rpf.config.KEY]
    end)
    rpf.config.apply(p, 3, "h3", snapshot(FIRST))
    assert.is_string(seen)
  end)

  it("restores the snapshot at start, so lookups work before the portal answers, and Hello reports it", function()
    local store = {}
    rpf.config.apply(support.fake_platform({ store = store }), 3, "h3", snapshot(FIRST))

    support.load_core()
    local restored = {}
    rpf.events.on("config.changed", function(change)
      restored[#restored + 1] = change
    end)
    local again = support.fake_platform({ store = store })
    rpf.start_server(again, { url = "ws://portal", api_key = "k" })
    assert.are.equal(2, rpf.config.item("bread").weight)
    assert.are.equal(1, #restored)
    again.open()
    assert.are.equal(3, again.last().config_version)
    assert.are.equal("h3", again.last().config_hash)
  end)

  it("treats a stored entry that does not index as a cold start", function()
    p.store[rpf.config.KEY] = '{"version":3,"hash":"h3","snapshot":{"items":{}}}'
    assert.is_nil(rpf.config.load(p))
    rpf.config.restore(p)
    assert.is_nil(rpf.config.version())
    assert.are.equal(0, #changes)
  end)
end)
