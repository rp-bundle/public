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
    assert.is_nil(rpf.config.job("lspd", "officer"))
    assert.is_nil(rpf.config.setting("motd"))
    assert.is_nil(rpf.config.version())
  end)

  it("looks items, jobs, employers and settings up by slug or key", function()
    assert.is_true((rpf.config.apply(p, 3, "h3", snapshot(FIRST))))
    assert.are.equal(2, rpf.config.item("bread").weight)
    assert.are.equal("lspd", rpf.config.job("lspd", "officer").employer)
    assert.are.equal("LSPD", rpf.config.employer("lspd").name)
    assert.are.equal(500, rpf.config.setting("starting_cash"))
    assert.are.equal(3, rpf.config.version())
    assert.is_nil(rpf.config.item("nothing"))
    ---@diagnostic disable-next-line: param-type-mismatch
    assert.is_nil(rpf.config.item(nil))
  end)

  -- The corpus assertion for E3's sections: the snapshot the Rust types
  -- serialize is one this side applies and can look every entry up in.
  it("indexes the items, bases and defaults of the corpus snapshot", function()
    local frame = assert(rpf.json.decode(support.read("protocol/corpus/v1/portal_to_server/config.json")))
    assert.is_true((rpf.config.apply(p, frame.version, frame.hash, frame.snapshot)))

    -- Resolved by the portal: every field is there, and the base is named.
    assert.are.same(
      { slug = "pistol", name = "Pistol", base = "weapon", weight = 12, size = { x = 2, y = 1 }, stack_limit = 1 },
      rpf.config.item("pistol")
    )
    assert.is_nil(rpf.config.item("water_bottle").base)
    assert.are.equal(10, rpf.config.item("water_bottle").stack_limit)

    -- A base as staff wrote it: what it does not set is absent.
    local weapon = assert(rpf.config.item_base("weapon"))
    assert.are.equal("Weapon", weapon.name)
    assert.are.equal(30, weapon.weight)
    assert.is_nil(weapon.stack_limit)
    assert.is_nil(rpf.config.item_base("pistol"))

    assert.are.same({ weight = 1, size = { x = 1, y = 1 }, stack_limit = 1 }, rpf.config.item_defaults())
    assert.is_nil(rpf.config.item("unknown"))
  end)

  -- The corpus assertion for E4's sections: employers by slug, departments
  -- and jobs by their employer's slug and their own.
  it("indexes the employers, departments and jobs of the corpus snapshot", function()
    local frame = assert(rpf.json.decode(support.read("protocol/corpus/v1/portal_to_server/config.json")))
    assert.is_true((rpf.config.apply(p, frame.version, frame.hash, frame.snapshot)))

    assert.are.same(
      { slug = "lspd", name = "Los Santos Police", description = "Keeps the peace." },
      rpf.config.employer("lspd")
    )
    assert.are.equal("Patrol", rpf.config.department("lspd", "patrol").name)
    assert.are.same({
      employer = "lspd",
      slug = "officer",
      name = "Officer",
      department = "patrol",
      description = "Answers calls.",
    }, rpf.config.job("lspd", "officer"))
    assert.is_nil(rpf.config.job("lspd", "chief").department)

    -- Named by both slugs, never one alone.
    ---@diagnostic disable-next-line: missing-parameter
    assert.is_nil(rpf.config.job("officer"))
    assert.is_nil(rpf.config.job("patrol", "officer"))
    assert.is_nil(rpf.config.department("lspd", "officer"))
    assert.is_nil(rpf.config.employer("patrol"))
  end)

  it("keeps two employers' jobs of the same slug apart", function()
    assert.is_true((rpf.config.apply(p, 3, "h3", snapshot([[{
      "employers": [ { "slug": "bcso", "name": "BCSO" }, { "slug": "lspd", "name": "LSPD" } ],
      "jobs": [
        { "employer": "bcso", "slug": "officer", "name": "Deputy" },
        { "employer": "lspd", "slug": "officer", "name": "Officer" }
      ]
    }]]))))
    assert.are.equal("Deputy", rpf.config.job("bcso", "officer").name)
    assert.are.equal("Officer", rpf.config.job("lspd", "officer").name)
  end)

  it("answers no item defaults before a config, or from a snapshot without them", function()
    assert.is_nil(rpf.config.item_defaults())
    assert.is_nil(rpf.config.item_base("weapon"))
    rpf.config.apply(p, 3, "h3", snapshot(FIRST))
    assert.is_nil(rpf.config.item_defaults())
    assert.is_nil(rpf.config.item_base("weapon"))
  end)

  it("hands out copies of the item defaults and bases", function()
    local frame = assert(rpf.json.decode(support.read("protocol/corpus/v1/portal_to_server/config.json")))
    rpf.config.apply(p, frame.version, frame.hash, frame.snapshot)
    rpf.config.item_defaults().size.x = 9
    rpf.config.item_base("weapon").weight = 9
    assert.are.equal(1, rpf.config.item_defaults().size.x)
    assert.are.equal(30, rpf.config.item_base("weapon").weight)
  end)

  it("refuses a snapshot whose item sections are the wrong shape", function()
    for _, bad in ipairs({
      '{"item_bases":{}}',
      '{"item_bases":[{"name":"No slug"}]}',
      '{"item_bases":[{"slug":"a"},{"slug":"a"}]}',
      '{"item_defaults":[]}',
    }) do
      local applied, err = rpf.config.apply(p, 3, "h3", snapshot(bad))
      assert.is_false(applied, bad)
      assert.is_string(err, bad)
    end
    assert.is_nil(rpf.config.version())
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

  it("takes over a copy, so editing the table it was given changes nothing applied", function()
    local s = snapshot(FIRST)
    rpf.config.apply(p, 3, "h3", s)
    s.items[1].weight = 50
    assert.are.equal(1, rpf.config.item("water").weight)
    -- And the edited table, applied for real, is a change.
    rpf.config.apply(p, 4, "h4", s)
    assert.are.same({ version = 4, sections = { "items" } }, changes[2])
    assert.are.equal(50, rpf.config.item("water").weight)
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
    assert.is_nil(rpf.config.job("lspd", "officer"))
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
    { "two entries with one slug", [[{ "employers": [ { "slug": "a" }, { "slug": "a" } ] }]] },
    {
      "two jobs with one slug at one employer",
      [[{ "jobs": [ { "employer": "e", "slug": "a" }, { "employer": "e", "slug": "a" } ] }]],
    },
    { "a job without its employer", [[{ "jobs": [ { "slug": "a" } ] }]] },
    { "a department without its employer", [[{ "departments": [ { "slug": "a", "employer": 1 } ] }]] },
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

  describe("the portal's config requests", function()
    ---Delivers a `config` request and returns the reply the core sent.
    ---@param platform spec.FakePlatform The platform, connected.
    ---@param version integer The version.
    ---@param text string The snapshot's JSON.
    ---@return rpf.Frame request The request delivered.
    ---@return rpf.Frame reply The `config_applied` that answered it.
    local function push(platform, version, text)
      local request = support.portal_frame("config", {
        version = version,
        hash = "sha256:" .. version,
        snapshot = snapshot(text),
      })
      platform.deliver(request)
      return request, platform.last()
    end

    it("applies a pushed config, persists it, and answers applied", function()
      support.connected(p)
      local request, reply = push(p, 2, FIRST)

      assert.are.equal("config_applied", reply.type)
      assert.are.equal(request.id, reply.re)
      assert.are.same({ outcome = "applied" }, reply.outcome)
      assert.are.equal(2, rpf.config.version())
      assert.are.equal(500, rpf.config.setting("starting_cash"))
      assert.are.same({ 2, "sha256:2" }, { rpf.config.load(p) })
    end)

    it("refuses a snapshot it cannot index, keeps what it had, and says why", function()
      support.connected(p)
      push(p, 2, FIRST)
      local _, reply = push(p, 3, [[{ "settings": {}, "items": { "water": {} } }]])

      assert.are.equal("failed", reply.outcome.outcome)
      assert.truthy(reply.outcome.reason:find("items must be an array", 1, true), reply.outcome.reason)
      assert.are.equal(2, rpf.config.version())
      assert.are.equal(2, (rpf.config.load(p)))
    end)

    it("keeps a section it does not index, and announces it", function()
      support.connected(p)
      local _, reply = push(p, 4, [[{ "settings": {}, "vehicles": [ { "model": "adder" } ] }]])

      assert.are.same({ outcome = "applied" }, reply.outcome)
      assert.are.same({ "settings", "vehicles" }, changes[#changes].sections)
    end)

    it("applies a resent config once, and answers it with the original reply", function()
      support.connected(p)
      local request = push(p, 2, FIRST)
      local announced = #changes
      local first = p.sent[#p.sent]
      p.deliver(request)

      assert.are.equal(first, p.sent[#p.sent])
      assert.are.equal(announced, #changes)
    end)
  end)

  it("treats a stored entry that does not index as a cold start", function()
    p.store[rpf.config.KEY] = '{"version":3,"hash":"h3","snapshot":{"items":{}}}'
    assert.is_nil(rpf.config.load(p))
    rpf.config.restore(p)
    assert.is_nil(rpf.config.version())
    assert.are.equal(0, #changes)
  end)
end)
