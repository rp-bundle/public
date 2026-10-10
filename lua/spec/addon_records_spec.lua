-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Live addon records (J2): held like any record, changed, created and deleted
-- here and reported to the portal, and edited by staff through commands.

local support = require("spec.support")

local PLAYER = "00000002-0000-4000-8000-000000000002"
local FIELD = "0000000d-0000-4000-8000-00000000000d"
local FLUSH = 1000

---The farm addon: one live type held with its owner.
---@return table manifest The manifest.
local function farm()
  return {
    namespace = "acme_farm",
    version = "1.0.0",
    api = 1,
    title = "Farm",
    types = {
      field = {
        schema = 1,
        authority = "live",
        owners = { "player", "character" },
        hold = "owner",
        fields = {
          label = { type = "string" },
          water = { type = "integer", min = 0, max = 100, default = 50 },
        },
      },
    },
  }
end

---Frames of one type the core sent, answered ones included.
---@param p spec.FakePlatform The platform.
---@param tag string The type.
---@return rpf.Frame[] frames The frames, in order.
local function sent_of(p, tag)
  local out = {}
  for _, text in ipairs(p.sent) do
    local frame = assert(rpf.protocol.decode(rpf.protocol.SERVER_TO_PORTAL, text))
    if frame.type == tag then
      out[#out + 1] = frame
    end
  end
  return out
end

---The last frame of one type sent.
---@param p spec.FakePlatform The platform.
---@param tag string The type.
---@return rpf.Frame frame The frame.
local function last_of(p, tag)
  local frames = sent_of(p, tag)
  return assert(frames[#frames], "no " .. tag .. " was sent")
end

---A connected core with the farm registered and installed, and one field
---of a player's held.
---@return spec.FakePlatform p The platform.
local function farmed()
  support.load_core()
  local p = support.fake_platform()
  assert(rpf.addons.register(farm()))
  support.connected(p)
  local json = rpf.json
  local checked = assert(rpf.manifest.check(farm()))
  local snapshot = assert(json.decode(assert(json.encode({
    settings = json.object({}),
    addons = json.array({
      {
        namespace = "acme_farm",
        version = "1.0.0",
        hash = "sha256:farm",
        enabled = true,
        manifest = checked,
        types = json.object({}),
        records = json.array({}),
      },
    }),
  }))))
  assert.is_true((rpf.config.apply(p, 1, "h1", snapshot)))
  assert.are.equal("active", (rpf.addons.state("acme_farm")))
  rpf.sync.hold({ records = { { kind = "addon_record", id = FIELD } } })
  p.deliver(support.portal_frame("held", {
    re = last_of(p, "hold").id,
    records = {
      {
        kind = "addon_record",
        revision = 1,
        record = {
          id = FIELD,
          type = "acme_farm.field",
          owner = { kind = "player", id = PLAYER },
          fields = json.object({ label = "North", water = 50 }),
        },
      },
    },
  }))
  return p
end

---Answers a report.
---@param p spec.FakePlatform The platform.
---@param frame rpf.Frame The report.
---@param tag string? The answer, `state_applied` by default.
local function answer(p, frame, tag)
  if tag == "rejected" then
    p.deliver(support.portal_frame("rejected", { re = frame.id, code = "malformed", reason = "no" }))
  elseif tag == "resync_required" then
    p.deliver(support.portal_frame("resync_required", { re = frame.id, stale = {}, released = {} }))
  else
    p.deliver(support.portal_frame("state_applied", { re = frame.id, revisions = {} }))
  end
end

describe("live addon records", function()
  it("are held and read as copies", function()
    farmed()
    local record = assert(rpf.records.get("addon_record", FIELD))
    assert.are.equal("acme_farm.field", record.type)
    assert.are.equal(50, record.fields.water)
    record.fields.water = 1
    assert.are.equal(50, rpf.records.get("addon_record", FIELD).fields.water)
  end)

  it("report a change as the patch it made, on the revision it was made on", function()
    local p = farmed()
    assert(rpf.records.set_addon_fields(FIELD, { water = 70 }))
    p.advance(FLUSH)
    local change = last_of(p, "state_changed").changes[1]
    assert.are.equal("addon_record", change.kind)
    assert.are.equal(1, change.base_revision)
    assert.are.same({ water = 70 }, change.patch)
    assert.are.equal(2, rpf.records.revision("addon_record", FIELD))
  end)

  it("refuse a change the type does not take, changing nothing", function()
    farmed()
    local ok, err, refusal = rpf.records.set_addon_fields(FIELD, { water = 101 })
    assert.is_nil(ok)
    assert.are.equal("invalid", err)
    assert.are.equal("above_max", assert(refusal).error)
    assert.are.equal(50, rpf.records.get("addon_record", FIELD).fields.water)
  end)

  it("report a create whole, held from the start, and send it again as a create once refused", function()
    local p = farmed()
    local record = assert(rpf.records.create_addon_record(
      "acme_farm.field",
      { kind = "player", id = PLAYER },
      { label = "South" }
    ))
    assert.are.equal(50, record.fields.water, "the default is in place")
    assert(rpf.records.set_addon_fields(record.id, { water = 5 }))
    p.advance(FLUSH)
    local frame = last_of(p, "state_changed")
    assert.are.equal(1, #frame.changes, "one create, the change in it")
    assert.are.equal("addon_record_created", frame.changes[1].kind)
    assert.are.equal(5, frame.changes[1].fields.water)

    answer(p, frame, "rejected")
    -- A record refused alone goes with the next flush.
    rpf.sync.flush()
    local again = last_of(p, "state_changed")
    assert.are_not.equal(frame.id, again.id)
    assert.are.equal("addon_record_created", again.changes[1].kind)

    -- Landed, even in a frame answered with a resync: changes follow as
    -- patches from then on.
    answer(p, again, "resync_required")
    p.advance(FLUSH)
    local whole = last_of(p, "resync")
    assert.are.equal(5, whole.records[1].fields.water)
    answer(p, whole)
    assert(rpf.records.set_addon_fields(record.id, { water = 6 }))
    p.advance(FLUSH)
    local kinds = {}
    for _, change in ipairs(last_of(p, "state_changed").changes) do
      kinds[#kinds + 1] = change.kind
    end
    assert.are.same({ "addon_record" }, kinds)
  end)

  it("report a change made while the create is in flight once the create lands", function()
    local p = farmed()
    local record = assert(rpf.records.create_addon_record(
      "acme_farm.field",
      { kind = "player", id = PLAYER },
      { label = "East" }
    ))
    p.advance(FLUSH)
    local create = last_of(p, "state_changed")
    assert(rpf.records.set_addon_fields(record.id, { water = 3 }))
    p.advance(FLUSH)
    assert.are.equal(create.id, last_of(p, "state_changed").id, "nothing until the create lands")
    answer(p, create)
    p.advance(FLUSH)
    local change = last_of(p, "state_changed").changes[1]
    assert.are.equal("addon_record", change.kind)
    assert.are.equal(1, change.base_revision)
    assert.are.same({ water = 3 }, change.patch)
  end)

  it("keep a record until the portal has its create, and finish a refused frame's recovery once it does", function()
    local p = farmed()
    local record = assert(rpf.records.create_addon_record(
      "acme_farm.field",
      { kind = "player", id = PLAYER },
      { label = "Held on" }
    ))
    assert(rpf.records.set_addon_fields(FIELD, { water = 2 }))
    local ok, err = rpf.sync.release({ { kind = "addon_record", id = record.id } })
    assert.is_nil(ok)
    assert.are.equal("creating", err)
    assert.is_true(rpf.records.is_held("addon_record", record.id))

    -- The frame with the create and the change is refused; each goes alone,
    -- the create at the next flush, not in a loop.
    local frame = last_of(p, "state_changed")
    assert.are.equal(2, #frame.changes)
    answer(p, frame, "rejected")
    local sent = #sent_of(p, "state_changed")
    p.advance(FLUSH * 5)
    assert.is_true(#sent_of(p, "state_changed") <= sent + 2, "no retry loop")
    rpf.sync.flush()
    local create
    for _, f in ipairs(sent_of(p, "state_changed")) do
      if f.changes[1].kind == "addon_record_created" and f.id ~= frame.id then
        create = f
      end
    end
    answer(p, assert(create))
    -- Its recovery owed a whole report: it goes without another change.
    p.advance(FLUSH)
    local whole = last_of(p, "resync")
    assert.are.equal(record.id, whole.records[#whole.records].id)
  end)

  it("leave a record whose create has not gone out of the declaration after a reconnect", function()
    local p = farmed()
    local record = assert(rpf.records.create_addon_record(
      "acme_farm.field",
      { kind = "player", id = PLAYER },
      { label = "Before the flush" }
    ))
    p.drop("gone")
    p.advance(2 * 60 * 1000)
    p.open()
    local hellos = sent_of(p, "hello")
    p.deliver(support.portal_frame("welcome", {
      re = hellos[#hellos].id,
      protocol = rpf.protocol.VERSION,
      server_id = "00000001-0000-4000-8000-000000000001",
    }))
    p.advance(FLUSH)
    local declared = last_of(p, "declare_holds")
    for _, ref in ipairs(declared.records) do
      assert.are_not.equal(record.id, ref.id)
    end
    assert.is_true(rpf.records.is_held("addon_record", record.id))
  end)

  it("refuse a create of a type the server does not run, or for an owner it does not take", function()
    farmed()
    assert.are.equal(
      "invalid",
      select(2, rpf.records.create_addon_record("acme_farm.nope", { kind = "player", id = PLAYER }, {}))
    )
    assert.are.equal(
      "invalid",
      select(2, rpf.records.create_addon_record("acme_farm.field", { kind = "server", id = PLAYER }, {}))
    )
  end)

  it("report a deletion, and are forgotten once the portal has it", function()
    local p = farmed()
    assert(rpf.records.delete_addon_record(FIELD))
    p.advance(FLUSH)
    local frame = last_of(p, "state_changed")
    assert.are.same({ kind = "addon_record_deleted", id = FIELD, base_revision = 1 }, frame.changes[1])
    assert.is_true(rpf.records.is_held("addon_record", FIELD), "until it is answered")
    answer(p, frame)
    assert.is_false(rpf.records.is_held("addon_record", FIELD))
  end)

  it("forget a deleted record only once the frame carrying the deletion is applied", function()
    local p = farmed()
    assert(rpf.records.set_addon_fields(FIELD, { water = 7 }))
    p.advance(FLUSH)
    local patch = last_of(p, "state_changed")
    assert(rpf.records.delete_addon_record(FIELD))
    p.advance(FLUSH)
    local deletion = last_of(p, "state_changed")
    assert.are_not.equal(patch.id, deletion.id)
    answer(p, patch)
    assert.is_true(rpf.records.is_held("addon_record", FIELD), "the patch's answer says nothing of the deletion")
    -- Refused (another record refers to it): the deletion is undone.
    answer(p, deletion, "rejected")
    assert.is_true(rpf.records.is_held("addon_record", FIELD))
    assert.is_nil(rpf.records.entries["addon_record:" .. FIELD].deleted)
  end)

  it("send a deletion again on the portal's revision when its frame is stale", function()
    local p = farmed()
    assert(rpf.records.delete_addon_record(FIELD))
    p.advance(FLUSH)
    local deletion = last_of(p, "state_changed")
    p.deliver(support.portal_frame("resync_required", {
      re = deletion.id,
      stale = { { kind = "addon_record", id = FIELD, revision = 4 } },
      released = {},
    }))
    p.advance(FLUSH)
    local again = last_of(p, "state_changed")
    assert.are_not.equal(deletion.id, again.id)
    assert.are.same({ kind = "addon_record_deleted", id = FIELD, base_revision = 4 }, again.changes[1])
  end)

  it("report a deletion made while the create is in flight once the create lands", function()
    local p = farmed()
    local record = assert(rpf.records.create_addon_record(
      "acme_farm.field",
      { kind = "player", id = PLAYER },
      { label = "Gone" }
    ))
    p.advance(FLUSH)
    local create = last_of(p, "state_changed")
    assert(rpf.records.delete_addon_record(record.id))
    answer(p, create)
    p.advance(FLUSH)
    local change = last_of(p, "state_changed").changes[1]
    assert.are.equal("addon_record_deleted", change.kind)
    assert.are.equal(1, change.base_revision)
  end)

  it("take a staff edit by command, and let one go to be deleted", function()
    local p = farmed()
    p.deliver(support.portal_frame("apply_command", {
      command = { command = "edit_addon_record", record_id = FIELD, base_revision = 1, patch = rpf.json.object({ water = 9 }) },
    }))
    local applied = last_of(p, "command_applied")
    assert.are.equal("applied", applied.outcome.outcome)
    assert.are.equal(9, rpf.records.get("addon_record", FIELD).fields.water)
    assert.are.same({ water = 9 }, last_of(p, "state_changed").changes[1].patch)

    p.deliver(support.portal_frame("apply_command", {
      command = { command = "edit_addon_record", record_id = FIELD, base_revision = 1, patch = rpf.json.object({ water = 1 }) },
    }))
    assert.are.equal("failed", last_of(p, "command_applied").outcome.outcome, "stale")

    p.deliver(support.portal_frame("apply_command", {
      command = { command = "delete_addon_record", record_id = FIELD, base_revision = 2 },
    }))
    assert.are.equal("applied", last_of(p, "command_applied").outcome.outcome)
    assert.are.equal("addon_record", last_of(p, "release").records[1].kind)
    assert.is_false(rpf.records.is_held("addon_record", FIELD))
  end)
end)

describe("querying live addon records", function()
  it("asks the portal, and hands back the page it answers", function()
    local p = farmed()
    local got, cursor
    assert(rpf.records.query_addon_records("acme_farm.field", { limit = 10 }, function(found, next_page)
      got, cursor = found, next_page
    end))
    local frame = last_of(p, "query_records")
    assert.are.equal("acme_farm.field", frame.type_name)
    assert.are.equal(10, frame.query.limit)
    p.deliver(support.portal_frame("records_queried", {
      re = frame.id,
      records = {
        {
          id = FIELD,
          type = "acme_farm.field",
          owner = { kind = "player", id = PLAYER },
          revision = 3,
          held = false,
          fields = rpf.json.object({ label = "North" }),
        },
      },
      next = rpf.json.null,
    }))
    assert.are.equal(1, #got)
    assert.are.equal(3, got[1].revision)
    assert.is_nil(cursor)
  end)

  it("refuses a type this server cannot query", function()
    farmed()
    local ok, err = rpf.records.query_addon_records("acme_farm.nope", {}, function() end)
    assert.is_nil(ok)
    assert.are.equal("invalid", err)
  end)
end)
