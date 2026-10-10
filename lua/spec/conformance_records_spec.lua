-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Conformance (J3): addons' records through the public API (`rpf.api.records`),
-- the same cases on the mock platform and on the real FiveM and Gmod
-- adapters, against a fake portal (`spec/support/conformance.lua`). Live
-- records are created, changed and deleted only while held, reach the
-- portal in the next report, and are found and held through it; config
-- records are read. Every refusal is a value, never a throw.

local conformance = require("spec.support.conformance")

---What `conformance.run` needs from busted.
local busted = { describe = describe, it = it, before_each = before_each, after_each = after_each }

local PLAYER = "00000002-0000-4000-8000-000000000002"
local OTHER = "00000003-0000-4000-8000-000000000003"
local TAG = "0000000a-0000-4000-8000-00000000000a"
local SEEDED = "0000000b-0000-4000-8000-00000000000b"

---The worked example's addon: a live type of tags, and a config type.
---@param limit integer? The tag type's record limit.
---@return table manifest The manifest.
local function tags(limit)
  return {
    namespace = "acme_tags",
    version = "1.0.0",
    api = 1,
    title = "Tags",
    permissions = { moderate = "Remove any tag" },
    types = {
      tag = {
        schema = 1,
        authority = "live",
        owners = { "player" },
        fields = {
          text = { type = "string", max_len = 24, required = true },
          spot = { type = "vector3", required = true },
          fades_at = { type = "timestamp", required = true, index = true },
          note = { type = "string", nullable = true },
          colour = { type = "enum", values = { "red", "blue" }, default = "red", index = true },
        },
        limit = limit,
      },
      style = {
        schema = 1,
        authority = "config",
        fields = { label = { type = "string", required = true } },
      },
      mark = {
        schema = 1,
        authority = "live",
        owners = { "player" },
        fields = { label = { type = "string" } },
      },
    },
  }
end

---Registers and installs the tags addon, with config records, connected to
---the fake portal.
---@param world spec.ConformanceWorld The world.
---@param limit integer? The tag type's limit.
---@return table api The API as the addon sees it.
local function installed(world, limit)
  local m = tags(limit)
  assert(world.api.addons.register(m))
  world:connect()
  local entry = conformance.installed(world.core, m)
  local json = world.core.json
  entry.records = json.array({
    { id = SEEDED, type = "acme_tags.style", revision = 2, fields = json.object({ label = "Neon" }) },
  })
  world:install({ entry })
  assert.are.equal("active", (world.api.addons.state("acme_tags")))
  return world.api
end

---A tag's fields.
---@param text string? Its text.
---@param fades integer? When it fades.
---@return table fields The fields.
local function tag(text, fades)
  return { text = text or "hi", spot = { x = 1, y = 2, z = 3 }, fades_at = fades or 1000 }
end

---A tag's owner.
local OWNER = { owner = { kind = "player", id = PLAYER } }

---The `state_changed` frames the portal read.
---@param world spec.ConformanceWorld The world.
---@return table[] frames The frames.
local function reports(world)
  local out = {}
  for _, frame in ipairs(world.portal.frames) do
    if frame.type == "state_changed" then
      out[#out + 1] = frame
    end
  end
  return out
end

conformance.run(busted, "addon records", {
  {
    name = "creates a live record held from the start, which reaches the portal in the next report",
    run = function(world)
      local api = installed(world)
      local seen = {}
      api.events.on("records.created", function(change)
        seen[#seen + 1] = change
      end)
      local record, err = api.records.create("acme_tags.tag", tag("hello"), OWNER)
      assert.is_nil(err)
      assert.are.equal("acme_tags.tag", record.type)
      assert.are.equal(1, record.revision)
      assert.are.same({ kind = "player", id = PLAYER }, record.owner)
      assert.are.equal("hello", record.fields.text)
      assert.are.equal("red", record.fields.colour, "defaults are filled in")
      assert.is_nil(record.fields.note, "a field with no value is absent")
      assert.are.same(record, api.records.get("acme_tags.tag", record.id))
      assert.are.equal(1, #seen)
      assert.are.equal("addon", seen[1].by)
      assert.are.equal(record.id, seen[1].id)
      world:settle()
      local stored = world.portal.records[record.id]
      assert.are.equal("hello", stored.fields.text)
    end,
  },
  {
    name = "refuses a create it cannot make, with the rule, and makes nothing",
    run = function(world)
      local api = installed(world, 1)
      local records = api.records
      local _, err, rule = records.create("acme_tags.tag", tag(string.rep("x", 25)), OWNER)
      assert.are.equal("invalid", err)
      assert.are.equal("text", rule.field)
      _, err, rule = records.create("acme_tags.tag", tag(), {})
      assert.are.same({ "invalid", "owner" }, { err, rule.error })
      _, err, rule = records.create("acme_tags.tag", tag(), { owner = { kind = "character", id = PLAYER } })
      assert.are.same({ "invalid", "owner" }, { err, rule.error }, "a kind the type does not allow")
      _, err, rule = records.create("acme_tags.style", { label = "x" }, OWNER)
      assert.are.same({ "invalid", "authority" }, { err, rule.error }, "config records are staff's")
      assert.are.same({ nil, "not_found" }, { records.create("acme_none.tag", tag(), OWNER) })
      assert.are.same({ nil, "not_found" }, { records.create(42, tag(), OWNER) })
      assert(records.create("acme_tags.tag", tag(), { owner = OWNER.owner, id = TAG }))
      assert.are.same({ nil, "conflict" }, { records.create("acme_tags.tag", tag(), { owner = OWNER.owner, id = TAG }) })
      assert.are.same({ nil, "limit" }, { records.create("acme_tags.tag", tag(), OWNER) }, "one tag is the limit")
      assert.are.equal(1, #records.list("acme_tags.tag"))
    end,
  },
  {
    name = "changes a held record by patch, with its revision, and refuses a stale write",
    run = function(world)
      local api = installed(world)
      local record = assert(api.records.create("acme_tags.tag", tag(), OWNER))
      local changed = {}
      api.events.on("records.changed", function(change)
        changed[#changed + 1] = change.record.fields.text
      end)
      local after, err = api.records.update("acme_tags.tag", record.id, { text = "bye", note = "n" }, { revision = 1 })
      assert.is_nil(err)
      assert.are.equal(2, after.revision)
      assert.are.equal("bye", after.fields.text)
      assert.are.equal(3, after.fields.spot.z, "fields the patch leaves out stay")
      assert.are.same({ nil, "stale" }, { api.records.update("acme_tags.tag", record.id, { text = "x" }, { revision = 1 }) })
      local cleared = assert(api.records.update("acme_tags.tag", record.id, nil, { clear = { "note" } }))
      assert.is_nil(cleared.fields.note)
      assert.are.equal(3, cleared.revision)
      local _, why, rule = api.records.update("acme_tags.tag", record.id, nil, { clear = { "text" } })
      assert.are.equal("invalid", why, "a required field cannot be cleared")
      assert.are.equal("text", rule.field)
      assert.are.same({ nil, "not_held" }, { api.records.update("acme_tags.tag", SEEDED, { text = "x" }) })
      assert.are.same({ "bye", "bye" }, changed)
      world:settle()
      assert.are.equal("bye", world.portal.records[record.id].fields.text)
      assert.is_nil(world.portal.records[record.id].fields.note)
    end,
  },
  {
    name = "deletes a held record here at once, and at the portal with the next report",
    run = function(world)
      local api = installed(world)
      local record = assert(api.records.create("acme_tags.tag", tag(), OWNER))
      world:settle()
      local deleted = 0
      api.events.on("records.deleted", function()
        deleted = deleted + 1
      end)
      assert.are.same({ nil, "stale" }, { api.records.delete("acme_tags.tag", record.id, { revision = 7 }) })
      assert.is_true(api.records.delete("acme_tags.tag", record.id))
      assert.are.same({ nil, "not_held" }, { api.records.get("acme_tags.tag", record.id) })
      assert.are.same({ nil, "not_held" }, { api.records.delete("acme_tags.tag", record.id) })
      assert.are.equal(1, deleted)
      world:settle()
      assert.is_nil(world.portal.records[record.id])
    end,
  },
  {
    name = "lists held and config records locally, filtered and ordered",
    run = function(world)
      local api = installed(world)
      for i, text in ipairs({ "c", "a", "b" }) do
        assert(api.records.create("acme_tags.tag", tag(text, i * 100), OWNER))
      end
      local texts = function(list)
        local out = {}
        for i, record in ipairs(list) do
          out[i] = record.fields.text
        end
        return out
      end
      local records = api.records
      assert.are.same({ "a", "b" }, texts(records.list("acme_tags.tag", { where = { fades_at = { gt = 100 } }, order = "text" })))
      assert.are.same(
        { "c", "a" },
        texts(records.list("acme_tags.tag", { where = { fades_at = { lte = 200 } }, order = "text", descending = true }))
      )
      assert.are.same({ "a", "b", "c" }, texts(records.list("acme_tags.tag", { order = "text" })))
      assert.are.same({ "b" }, texts(records.list("acme_tags.tag", { where = { text = "b" } })))
      assert.are.same({ "a" }, texts(records.list("acme_tags.tag", { order = "text", limit = 1 })))
      assert.are.same({}, records.list("acme_tags.tag", { owner = { kind = "player", id = OTHER } }))
      local _, err, rule = records.list("acme_tags.tag", { where = { nope = 1 } })
      assert.are.same({ "invalid", "query", "nope" }, { err, rule.error, rule.field })
      assert.are.same({}, records.list("acme_tags.tag", { where = { text = { near = "x" } } }), "a table that is no comparison is a value")
      assert.are.equal("invalid", select(2, records.list("acme_tags.tag", { order = "nope" })))
      local styles = assert(records.list("acme_tags.style"))
      assert.are.equal(1, #styles)
      assert.are.equal("Neon", styles[1].fields.label)
      assert.are.equal("Neon", records.get("acme_tags.style", SEEDED).fields.label)
      assert.are.same({ nil, "not_found" }, { records.get("acme_tags.style", TAG) })
    end,
  },
  {
    name = "finds an unheld record through the portal, holds it, changes it and lets it go",
    run = function(world)
      local api = installed(world)
      world.portal.records[TAG] = {
        id = TAG,
        type = "acme_tags.tag",
        owner = { kind = "player", id = PLAYER },
        revision = 4,
        fields = { text = "old", spot = { x = 0, y = 0, z = 0 }, fades_at = 50, colour = "blue" },
        held = false,
      }
      assert.are.same({ nil, "not_held" }, { api.records.get("acme_tags.tag", TAG) })
      local page
      assert.is_true(api.records.query("acme_tags.tag", { where = { colour = "blue" } }, function(found, next_page, err)
        page = { found = found, next = next_page, err = err }
      end))
      world:pump()
      assert.is_nil(page.err)
      assert.is_nil(page.next)
      assert.are.equal(1, #page.found)
      assert.are.equal(TAG, page.found[1].id)
      assert.is_false(page.found[1].held)
      assert.are.equal(4, page.found[1].revision)
      local got
      assert.is_true(api.records.hold("acme_tags.tag", { TAG }, function(held, err)
        got = { held = held, err = err }
      end))
      world:pump()
      assert.is_nil(got.err)
      assert.are.equal("old", got.held[1].fields.text)
      assert.are.equal(4, api.records.get("acme_tags.tag", TAG).revision)
      assert(api.records.update("acme_tags.tag", TAG, { text = "new" }, { revision = 4 }))
      assert.is_true(api.records.release("acme_tags.tag", { TAG }))
      world:pump()
      assert.are.same({ nil, "not_held" }, { api.records.get("acme_tags.tag", TAG) })
      assert.are.equal("new", world.portal.records[TAG].fields.text)
      assert.is_false(world.portal.records[TAG].held)
      assert.are.same({ nil, "invalid" }, { api.records.hold("acme_tags.tag", { "not-an-id" }) })
      assert.are.equal("invalid", select(2, api.records.query("acme_tags.style", {}, function() end)))
    end,
  },
  {
    name = "writes a batch all or nothing, and reports it in one frame",
    run = function(world)
      local api = installed(world)
      local a = assert(api.records.create("acme_tags.tag", tag("a"), OWNER))
      local b = assert(api.records.create("acme_tags.tag", tag("b"), OWNER))
      world:settle()
      local _, err, detail = api.records.batch({
        { op = "update", type = "acme_tags.tag", id = a.id, patch = { text = "A" } },
        { op = "update", type = "acme_tags.tag", id = b.id, patch = { text = string.rep("x", 30) } },
      })
      assert.are.equal("invalid", err)
      assert.are.equal(2, detail.index)
      assert.are.equal("a", api.records.get("acme_tags.tag", a.id).fields.text, "the first write was not made")
      local before = #reports(world)
      local results = assert(api.records.batch({
        { op = "update", type = "acme_tags.tag", id = a.id, patch = { text = "A" } },
        { op = "delete", type = "acme_tags.tag", id = b.id },
        { op = "create", type = "acme_tags.tag", fields = tag("c"), owner = OWNER.owner },
      }))
      assert.are.equal("A", results[1].fields.text)
      assert.is_true(results[2])
      assert.are.equal("c", results[3].fields.text)
      world:pump()
      local now = reports(world)
      assert.are.equal(before + 1, #now, "one report")
      assert.are.equal(3, #now[#now].changes)
      assert.are.equal("invalid", select(2, api.records.batch({})))
      local _, why, dup = api.records.batch({
        { op = "update", type = "acme_tags.tag", id = a.id, patch = { text = "x" } },
        { op = "delete", type = "acme_tags.tag", id = a.id },
      })
      assert.are.same({ "invalid", "duplicate", 2 }, { why, dup.error, dup.index })
    end,
  },
  {
    name = "closes an addon's calls when it stops, and lets the records it held go",
    run = function(world)
      local api = installed(world)
      local record = assert(api.records.create("acme_tags.tag", tag(), OWNER))
      world:settle()
      world:install({ conformance.installed(world.core, tags(), false) })
      world:pump()
      assert.are.same({ nil, "inactive" }, { api.records.update("acme_tags.tag", record.id, { text = "x" }) })
      assert.are.same({ nil, "inactive" }, { api.records.get("acme_tags.tag", record.id) })
      assert.are.same({ nil, "inactive" }, { api.records.create("acme_tags.tag", tag(), OWNER) })
      assert.is_false(world.portal.records[record.id].held, "released with its final state")
    end,
  },
  {
    name = "gives code that outlived its addon's activation nothing to read or write",
    run = function(world)
      local m = tags()
      local saved
      world.api.addons.register(m, {
        start = function()
          -- The harness's step: what a callback that waited across a
          -- disable runs in.
          saved = saved or world.core.addons.context()
        end,
      })
      world:connect()
      world:install({ conformance.installed(world.core, m) })
      world:install({ conformance.installed(world.core, m, false) })
      world:install({ conformance.installed(world.core, m) })
      local _, got = world.core.addons.run(saved, function()
        return { world.api.records.create("acme_tags.tag", tag("late"), OWNER) }
      end)
      assert.are.same({ nil, "inactive" }, got)
      assert.are.equal(0, #world.api.records.list("acme_tags.tag"))
    end,
  },
  {
    name = "lets the records an addon held go once their creates land, if it stopped before",
    run = function(world)
      local api = installed(world)
      local record = assert(api.records.create("acme_tags.tag", tag(), OWNER))
      world:advance(1000) -- the create is on its way, not yet answered
      world:install({ conformance.installed(world.core, tags(), false) })
      world:pump()
      world:advance(2000)
      world:pump()
      assert.is_false(world.portal.records[record.id].held, "released once the portal had the create")
    end,
  },
  {
    name = "counts a batch's own creates against the type's limit",
    run = function(world)
      local api = installed(world, 1)
      local _, err, detail = api.records.batch({
        { op = "create", type = "acme_tags.tag", fields = tag("a"), owner = OWNER.owner },
        { op = "create", type = "acme_tags.tag", fields = tag("b"), owner = OWNER.owner },
      })
      assert.are.same({ "limit", 2 }, { err, detail.index })
      assert.are.equal(0, #api.records.list("acme_tags.tag"))
    end,
  },
  {
    name = "refuses a query whose parts are not their shape, without throwing",
    run = function(world)
      local api = installed(world)
      local queries = {
        { owner = 42 },
        { after = 5 },
        { order = 1 },
        { limit = "ten" },
        { limit = math.huge },
        { limit = 1.5 },
        { where = { text = {} } },
      }
      for _, query in ipairs(queries) do
        local ok, err = api.records.query("acme_tags.tag", query, function() end)
        assert.is_nil(ok)
        assert.are.equal("invalid", err)
      end
    end,
  },
  {
    name = "holds only records of the type named, and gives back one of another",
    run = function(world)
      local api = installed(world)
      world.portal.records[TAG] = {
        id = TAG,
        type = "acme_tags.mark",
        owner = { kind = "player", id = PLAYER },
        revision = 1,
        fields = { label = "x" },
        held = false,
      }
      local got
      assert.is_true(api.records.hold("acme_tags.tag", { TAG }, function(held, err)
        got = { held = held, err = err }
      end))
      world:pump()
      assert.are.same({ err = "not_found" }, got)
      assert.is_false(world.portal.records[TAG].held, "given back")
      assert(api.records.hold("acme_tags.mark", { TAG }))
      world:pump()
      assert.are.same({ nil, "not_found" }, { api.records.hold("acme_tags.tag", { TAG }) }, "held as a mark already")
    end,
  },
  {
    name = "keeps a batch to one report: one naming a record whose create is unanswered waits",
    run = function(world)
      local api = installed(world)
      local fresh = assert(api.records.create("acme_tags.tag", tag("fresh"), OWNER))
      world:advance(1000) -- its create is sent, not answered
      local _, err, detail = api.records.batch({
        { op = "update", type = "acme_tags.tag", id = fresh.id, patch = { text = "x" } },
      })
      assert.are.same({ "busy", 1 }, { err, detail.index })
      world:pump()
      assert(api.records.batch({ { op = "update", type = "acme_tags.tag", id = fresh.id, patch = { text = "x" } } }))
    end,
  },
  {
    name = "gives back what a hold brings once its addon has stopped",
    run = function(world)
      local api = installed(world)
      world.portal.records[TAG] = {
        id = TAG,
        type = "acme_tags.tag",
        owner = { kind = "player", id = PLAYER },
        revision = 1,
        fields = { text = "old", spot = { x = 0, y = 0, z = 0 }, fades_at = 1 },
        held = false,
      }
      local got
      assert(api.records.hold("acme_tags.tag", { TAG }, function(held, err)
        got = { held = held, err = err }
      end))
      world:install({ conformance.installed(world.core, tags(), false) })
      world:pump()
      world:advance(1000)
      world:pump()
      assert.are.same({ err = "inactive" }, got)
      assert.is_false(world.portal.records[TAG].held)
    end,
  },
  {
    name = "refuses options that are not a table, without throwing",
    run = function(world)
      local api = installed(world)
      local record = assert(api.records.create("acme_tags.tag", tag(), OWNER))
      assert.are.equal("invalid", select(2, api.records.update("acme_tags.tag", record.id, { text = "x" }, 42)))
      assert.are.equal("invalid", select(2, api.records.update("acme_tags.tag", record.id, nil, { revision = "1" })))
      assert.are.same({ nil, "invalid" }, { api.records.delete("acme_tags.tag", record.id, false) })
    end,
  },
  {
    name = "makes no batch whose report the outbox has no room for",
    run = function(world)
      local api = installed(world)
      local record = assert(api.records.create("acme_tags.tag", tag("a"), OWNER))
      world:settle()
      local options = world.core.connection.options
      local budget = options.max_bytes
      options.max_bytes = 0
      local _, err = api.records.batch({ { op = "update", type = "acme_tags.tag", id = record.id, patch = { text = "b" } } })
      options.max_bytes = budget
      assert.are.equal("outbox_full", err)
      assert.are.equal("a", api.records.get("acme_tags.tag", record.id).fields.text, "nothing was made")
    end,
  },
  {
    name = "lets a start handler write the records of its own addon",
    run = function(world)
      local m = tags()
      local made
      world.api.addons.register(m, {
        start = function()
          made = { world.api.records.create("acme_tags.tag", tag("start"), OWNER) }
        end,
      })
      world:connect()
      world:install({ conformance.installed(world.core, m) })
      assert.are.equal("start", made[1].fields.text)
    end,
  },
})
