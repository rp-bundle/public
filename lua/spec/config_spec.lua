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
  "employer_jobs": [ { "slug": "officer", "employer": "lspd" } ]
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
    local frame = assert(rpf.json.decode(support.read(support.corpus("portal_to_server/config.json"))))
    assert.is_true((rpf.config.apply(p, frame.version, frame.hash, frame.snapshot)))

    -- Resolved by the portal: every field is there, and the base is named.
    -- The image travels as its content hash (P3), and an item without one
    -- has no `image` at all.
    assert.are.same({
      slug = "pistol",
      name = "Pistol",
      base = "weapon",
      weight = 12,
      size = { x = 2, y = 1 },
      stack_limit = 1,
      image = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
    }, rpf.config.item("pistol"))
    assert.is_nil(rpf.config.item("water_bottle").base)
    assert.is_nil(rpf.config.item("water_bottle").image)
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
    local frame = assert(rpf.json.decode(support.read(support.corpus("portal_to_server/config.json"))))
    assert.is_true((rpf.config.apply(p, frame.version, frame.hash, frame.snapshot)))

    assert.are.same(
      { slug = "lspd", name = "Los Santos Police", description = "Keeps the peace.", payroll = "treasury" },
      rpf.config.employer("lspd")
    )
    assert.are.equal("Patrol", rpf.config.department("lspd", "patrol").name)
    assert.are.same({
      employer = "lspd",
      slug = "officer",
      name = "Officer",
      department = "patrol",
      description = "Answers calls.",
      rank = 1,
      salary = 250,
    }, rpf.config.job("lspd", "officer"))
    assert.is_nil(rpf.config.job("lspd", "chief").department)
    -- D7: a rank on every job, a salary only on a paid one.
    assert.are.equal(10, rpf.config.job("lspd", "chief").rank)
    assert.is_nil(rpf.config.job("lspd", "chief").salary)

    -- Named by both slugs, never one alone.
    ---@diagnostic disable-next-line: missing-parameter
    assert.is_nil(rpf.config.job("officer"))
    assert.is_nil(rpf.config.job("patrol", "officer"))
    assert.is_nil(rpf.config.department("lspd", "officer"))
    assert.is_nil(rpf.config.employer("patrol"))
  end)

  -- The corpus assertion for E5's section: the starting accounts and the
  -- default job, which is always one `job` finds.
  it("reads what a new character gets from the corpus snapshot", function()
    local frame = assert(rpf.json.decode(support.read(support.corpus("portal_to_server/config.json"))))
    assert.is_true((rpf.config.apply(p, frame.version, frame.hash, frame.snapshot)))

    assert.are.same(
      { { name = "wallet", amount = 500 }, { name = "bank", amount = 5000 } },
      rpf.config.starting_accounts()
    )
    local job = assert(rpf.config.default_job())
    assert.are.same({ employer = "lspd", job = "officer" }, job)
    assert.are.equal("Officer", rpf.config.job(job.employer, job.job).name)
    assert.are.equal(0, #p.logged("warn", "default job"))

    -- Copies: editing one changes nothing.
    rpf.config.starting_accounts()[1].amount = 1
    rpf.config.default_job().job = "chief"
    assert.are.equal(500, rpf.config.starting_accounts()[1].amount)
    assert.are.equal("officer", rpf.config.default_job().job)
  end)

  -- The corpus assertion for #169's section: the accounts this server pays
  -- out of, by name, each with the id `rpf.accounts.pay` takes.
  it("reads the paying accounts of the corpus snapshot", function()
    local frame = assert(rpf.json.decode(support.read(support.corpus("portal_to_server/config.json"))))
    assert.is_true((rpf.config.apply(p, frame.version, frame.hash, frame.snapshot)))

    assert.are.same(
      { id = "0000000c-0000-4000-8000-00000000000c", name = "treasury" },
      rpf.config.paying_account("treasury")
    )
    assert.are.same({ rpf.config.paying_account("treasury") }, rpf.config.paying_accounts())
    assert.is_nil(rpf.config.paying_account("wallet"))

    -- Copies: editing one changes nothing.
    rpf.config.paying_account("treasury").id = "x"
    rpf.config.paying_accounts()[1].id = "x"
    assert.are.equal("0000000c-0000-4000-8000-00000000000c", rpf.config.paying_account("treasury").id)
  end)

  -- The corpus assertion for L1's section: a server's dialog trees, by
  -- slug, whole, with every kind of choice and condition.
  it("reads the dialogs of the corpus snapshot", function()
    local frame = assert(rpf.json.decode(support.read(support.corpus("portal_to_server/config.json"))))
    assert.is_true((rpf.config.apply(p, frame.version, frame.hash, frame.snapshot)))

    local dialog = assert(rpf.config.dialog("gardener"))
    assert.are.same({ "Old Tom", "hello", 2 }, { dialog.title, dialog.start, #dialog.nodes })
    local choices = dialog.nodes[1].choices
    assert.are.same({ "goto", "action", "end" }, { choices[1].does.kind, choices[2].does.kind, choices[3].does.kind })
    assert.are.same({ "acme_garden.plant", "fern" }, { choices[2].does.action, choices[2].does.params.species })
    assert.are.same({ "job", "item", "permission" }, {
      choices[2].conditions[1].kind,
      choices[2].conditions[2].kind,
      choices[2].conditions[3].kind,
    })
    assert.is_true(choices[2].conditions[3].negate)
    assert.is_nil(rpf.config.dialog("nobody"))

    -- A copy: editing one changes nothing.
    rpf.config.dialog("gardener").title = "x"
    assert.are.equal("Old Tom", rpf.config.dialog("gardener").title)
  end)

  it("has no paying accounts from a portal older than #169", function()
    assert.is_true((rpf.config.apply(p, 3, "h3", snapshot(FIRST))))
    assert.are.same({}, rpf.config.paying_accounts())
    assert.is_nil(rpf.config.paying_account("treasury"))
  end)

  -- A default job the server does not have is sent as null, and the setting
  -- still names it: applying says so, and the server gets no default job.
  it("logs a default job the portal could not send, and gives none", function()
    local frame = assert(rpf.json.decode(support.read(support.corpus("portal_to_server/config.json"))))
    frame.snapshot.new_character.job = rpf.json.null
    assert.is_true((rpf.config.apply(p, frame.version, frame.hash, frame.snapshot)))

    assert.is_nil(rpf.config.default_job())
    assert.are.equal(1, #p.logged("warn", "default job lspd/officer is not a job on this server"))

    -- Restored at start, it says so again.
    local restarted = support.fake_platform({ store = p.store })
    rpf.config.restore(restarted)
    assert.is_nil(rpf.config.default_job())
    assert.are.equal(1, #restarted.logged("warn", "default job lspd/officer"))
  end)

  it("has no starting accounts or default job from a portal older than E5", function()
    assert.is_true((rpf.config.apply(p, 3, "h3", snapshot(FIRST))))
    assert.is_nil(rpf.config.starting_accounts())
    assert.is_nil(rpf.config.default_job())
  end)

  -- Cores from before E4 reserved a `jobs` section indexed by `slug` alone,
  -- and refuse a whole snapshot with two entries of one slug. The portal
  -- sends jobs under another name, so such a core still applies a snapshot
  -- in which two employers share a job slug.
  it("is applied by a core that indexes jobs by slug alone, as before E4", function()
    local sections = rpf.config.SECTIONS
    local saved = { jobs = sections.jobs, employer_jobs = sections.employer_jobs }
    sections.jobs = { kind = "list", key = "slug" }
    sections.employer_jobs = nil
    local frame = assert(rpf.json.decode(support.read(support.corpus("portal_to_server/config.json"))))
    local extra = rpf.json.copy(frame.snapshot.employer_jobs[2])
    extra.employer = "bcso"
    table.insert(frame.snapshot.employer_jobs, extra)
    local applied, err = rpf.config.apply(p, frame.version, frame.hash, frame.snapshot)
    sections.jobs, sections.employer_jobs = saved.jobs, saved.employer_jobs
    assert.is_true(applied, err)
    assert.is_nil(frame.snapshot.jobs)
  end)

  it("keeps two employers' jobs of the same slug apart", function()
    assert.is_true((rpf.config.apply(p, 3, "h3", snapshot([[{
      "employers": [ { "slug": "bcso", "name": "BCSO" }, { "slug": "lspd", "name": "LSPD" } ],
      "employer_jobs": [
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
    local frame = assert(rpf.json.decode(support.read(support.corpus("portal_to_server/config.json"))))
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
    assert.are.same({ { version = 3, sections = { "employer_jobs", "employers", "items", "settings" } } }, changes)
  end)

  it("announces only the sections that changed, whatever the key order", function()
    rpf.config.apply(p, 3, "h3", snapshot(FIRST))
    rpf.config.apply(
      p,
      4,
      "h4",
      snapshot([[{
        "employer_jobs": [ { "employer": "lspd", "slug": "officer" } ],
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
    assert.are.same({ "employer_jobs", "shops" }, changes[2].sections)
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
      [[{ "employer_jobs": [ { "employer": "e", "slug": "a" }, { "employer": "e", "slug": "a" } ] }]],
    },
    { "a job without its employer", [[{ "employer_jobs": [ { "slug": "a" } ] }]] },
    { "a department without its employer", [[{ "employer_departments": [ { "slug": "a", "employer": 1 } ] }]] },
    { "a new_character that is not an object", [[{ "new_character": [] }]] },
    { "starting accounts that are not an array", [[{ "new_character": { "accounts": {} } }]] },
    { "a starting account without a name", [[{ "new_character": { "accounts": [ { "amount": 5 } ] } }]] },
    {
      "a starting account with a fractional amount",
      [[{ "new_character": { "accounts": [ { "name": "w", "amount": 0.5 } ] } }]],
    },
    { "a default job without its employer", [[{ "new_character": { "job": { "job": "officer" } } }]] },
    { "paying accounts that are not an array", [[{ "paying_accounts": {} }]] },
    { "a paying account without a name", [[{ "paying_accounts": [ { "id": "a" } ] }]] },
    { "a paying account without an id", [[{ "paying_accounts": [ { "name": "treasury" } ] }]] },
    {
      "two paying accounts of one name",
      [[{ "paying_accounts": [ { "id": "a", "name": "t" }, { "id": "b", "name": "t" } ] }]],
    },
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

-- In-game config edits (E6): sent to the portal against the version the
-- staff member saw, never applied here, and the staff member told how each
-- went.
describe("rpf.config.edit", function()
  local PLAYER = "00000002-0000-4000-8000-000000000002"
  local MAX = {
    change = "setting",
    key = "characters.max_per_player",
    value = { state = "set", value = 4 },
  }
  local p, notified, heard

  ---Frames of one type among everything sent.
  ---@param tag string The type.
  ---@return rpf.Frame[] frames The frames.
  local function sent_of(tag)
    local out = {}
    for _, frame in ipairs(p.frames()) do
      if frame.type == tag then
        out[#out + 1] = frame
      end
    end
    return out
  end

  ---A logged-in player holding `permissions` here, logged in on first use.
  ---@param handle any The engine's handle.
  ---@param permissions string[] What the portal's last push gave them.
  local function staff(handle, permissions)
    if not rpf.players.get(handle) then
      rpf.players.connected(handle)
      assert(rpf.players.authenticating(handle))
      assert(rpf.players.register(handle, { player_id = PLAYER, username = "sam" }))
    end
    p.deliver(support.portal_frame("staff_permissions", {
      staff = { { player_id = PLAYER, permissions = permissions } },
    }))
  end

  before_each(function()
    support.load_core()
    p = support.fake_platform()
    notified = {}
    p.notify = function(player, message)
      notified[#notified + 1] = { player = player, message = message }
    end
    support.connected(p)
    heard = { ["config.edit_applied"] = {}, ["config.edit_discarded"] = {}, ["config.edit_refused"] = {} }
    for name, list in pairs(heard) do
      rpf.events.on(name, function(payload)
        list[#list + 1] = payload
      end)
    end
  end)

  it("refuses a player not logged in or without the permission, and a malformed edit, sending nothing", function()
    assert.are.same({ false, "not_logged_in" }, { rpf.config.edit(7, 3, { MAX }) })
    staff(7, { "config.items.edit" })
    assert.are.same({ false, "forbidden" }, { rpf.config.edit(7, 3, { MAX }) }, "a setting needs a settings flag")
    staff(7, { "config.settings.edit" })
    assert.are.same({ false, "invalid_version" }, { rpf.config.edit(7, -1, { MAX }) })
    assert.are.same({ false, "invalid_version" }, { rpf.config.edit(7, 1.5, { MAX }) })
    assert.are.same({ false, "invalid_version" }, { rpf.config.edit(7, "3", { MAX }) })
    assert.are.same({ false, "invalid_changes" }, { rpf.config.edit(7, 3, {}) })
    assert.are.same({ false, "invalid_changes" }, { rpf.config.edit(7, 3, "x") })
    assert.are.same({ false, "invalid_changes" }, { rpf.config.edit(7, 3, { { change = "delete_guild" } }) })
    assert.are.same(
      { false, "invalid_changes" },
      { rpf.config.edit(7, 3, { { change = "setting", key = "motd", value = { state = "set" } } }) },
      "a set value, missing"
    )
    local many = {}
    for i = 1, rpf.config.MAX_CHANGES + 1 do
      many[i] = MAX
    end
    assert.are.same({ false, "invalid_changes" }, { rpf.config.edit(7, 3, many) })
    assert.are.same({ false, "invalid_changes" }, { rpf.config.edit(7, 3, { MAX, nil, MAX }) }, "a list with a hole")
    assert.are.same(
      { false, "forbidden" },
      { rpf.config.edit(7, 3, { MAX, { change = "delete_job", employer = "lspd", slug = "officer" } }) },
      "every change needs its own flag"
    )
    assert.are.equal(0, #sent_of("config_changed"))
  end)

  it("sends the edit against the version named, applies nothing itself, and tells the staff member it was applied", function()
    staff(7, { "config.settings.edit" })
    assert.are.same({ true }, { rpf.config.edit(7, 3, { MAX }) })
    local sent = p.last()
    assert.are.equal("config_changed", sent.type)
    assert.are.equal(PLAYER, sent.player_id)
    assert.are.equal(3, sent.base_version)
    assert.are.same({ MAX }, sent.changes)
    assert.is_nil(rpf.config.setting("characters.max_per_player"), "nothing changes until the portal pushes it")

    p.deliver(support.portal_frame("config_change_applied", { re = sent.id, version = 4 }))
    assert.are.same({ { player = 7, message = string.format(rpf.config.EDIT_APPLIED, 4) } }, notified)
    assert.are.same({ { player_id = PLAYER, version = 4 } }, heard["config.edit_applied"])
    assert.is_nil(rpf.config.setting("characters.max_per_player"))
  end)

  it("takes either settings flag for a setting, which the portal narrows to the setting's own", function()
    staff(7, { "config.accounts.edit" })
    assert.is_true((rpf.config.edit(7, 3, { MAX })))
  end)

  it("tells the staff member to redo an edit the portal discarded, and logs it", function()
    staff(7, { "config.settings.edit" })
    rpf.config.edit(7, 3, { MAX })
    p.deliver(support.portal_frame("config_change_discarded", { re = p.last().id, version = 5 }))

    assert.are.same({ { player = 7, message = rpf.config.EDIT_DISCARDED } }, notified)
    assert.are.same({ { player_id = PLAYER, version = 5 } }, heard["config.edit_discarded"])
    assert.are.equal(0, #heard["config.edit_applied"])
    local logged = false
    for _, line in ipairs(p.logs) do
      logged = logged or (line.level == "warn" and line.message:find("discarded a config edit", 1, true) ~= nil)
    end
    assert.is_true(logged)
  end)

  it("tells the staff member the portal's reason when it refuses the edit", function()
    staff(7, { "config.settings.edit" })
    rpf.config.edit(7, 3, { MAX })
    local reason = "That number is not allowed for this setting."
    p.deliver(support.portal_frame("rejected", { re = p.last().id, code = "malformed", reason = reason }))

    assert.are.same({ { player = 7, message = reason } }, notified)
    assert.are.same({ { player_id = PLAYER, code = "malformed", reason = reason } }, heard["config.edit_refused"])
  end)

  it("tells nobody when the staff member has left, and still announces the answer", function()
    staff(7, { "config.settings.edit" })
    rpf.config.edit(7, 3, { MAX })
    local id = p.last().id
    rpf.players.dropped(7, "quit")
    p.deliver(support.portal_frame("config_change_discarded", { re = id, version = 5 }))

    assert.are.same({}, notified)
    assert.are.same({ { player_id = PLAYER, version = 5 } }, heard["config.edit_discarded"])
  end)

  it("keeps an edit made while the portal is out of reach, and sends it on reconnect", function()
    staff(7, { "config.settings.edit" })
    p.drop()
    assert.is_true((rpf.config.edit(7, 3, { MAX })))
    assert.are.equal(0, #sent_of("config_changed"), "nothing goes out while disconnected")
    -- Reconnects after the backoff, and sends it after `Welcome`.
    p.advance(60 * 1000)
    p.open()
    local hello = p.last()
    p.deliver(support.portal_frame("welcome", {
      re = hello.id,
      protocol = rpf.protocol.VERSION,
      server_id = "00000001-0000-4000-8000-000000000001",
    }))
    support.declared(p)
    local sent = sent_of("config_changed")
    assert.are.equal(1, #sent)
    assert.are.equal(3, sent[1].base_version)
  end)
end)
