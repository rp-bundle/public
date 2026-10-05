-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Holds, reports, resyncs, releases and the declaration (C7), with the test
-- playing the portal over the fake platform.

local support = require("spec.support")

local SERVER = "00000001-0000-4000-8000-000000000001"
local PLAYER = "00000002-0000-4000-8000-000000000002"
local CHARACTER = "00000003-0000-4000-8000-000000000003"
local WALLET = "00000004-0000-4000-8000-000000000004"
local BANK = "00000005-0000-4000-8000-000000000005"
local POCKETS = "00000006-0000-4000-8000-000000000006"
local FLUSH = 1000

---The portal's `held` records for a character, its wallet, a treasury and
---a container.
---@return table[] records The records.
local function records_held()
  local owner = { kind = "player", id = PLAYER }
  return {
    {
      kind = "character",
      revision = 3,
      character = {
        id = CHARACTER,
        server_id = SERVER,
        owner = owner,
        first_name = "Jane",
        last_name = "Doe",
        gender = "female",
      },
    },
    {
      kind = "account",
      revision = 0,
      account = { id = WALLET, server_id = SERVER, owner = owner, name = "Wallet", flags = {} },
      balance = 100,
    },
    {
      kind = "account",
      revision = 7,
      account = {
        id = BANK,
        server_id = SERVER,
        owner = { kind = "server", id = SERVER },
        name = "Treasury",
        flags = { "unlimited_balance" },
      },
      balance = 0,
    },
    {
      kind = "container",
      revision = 1,
      container = {
        id = POCKETS,
        server_id = SERVER,
        owner = owner,
        name = "Pockets",
        contents = rpf.json.object({ layout = "list", stacks = rpf.json.array() }),
        flags = {},
      },
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

---The last frame of one type sent.
---@param p spec.FakePlatform The platform.
---@param tag string The type.
---@return rpf.Frame frame The frame.
local function last_of(p, tag)
  local frames = sent_of(p, tag)
  return assert(frames[#frames], "no " .. tag .. " was sent")
end

---Holds the records above, answering the hold as the portal would.
---@param p spec.FakePlatform The platform.
---@param through string? The player they are held for.
local function hold_all(p, through)
  rpf.sync.hold({ records = { { kind = "character", id = CHARACTER } } }, through)
  p.deliver(support.portal_frame("held", { re = last_of(p, "hold").id, records = records_held() }))
end

---Runs the scheduled flush.
---@param p spec.FakePlatform The platform.
local function flush(p)
  p.advance(FLUSH)
end

---Answers a report as applied.
---@param p spec.FakePlatform The platform.
---@param frame rpf.Frame The report.
local function apply(p, frame)
  p.deliver(support.portal_frame("state_applied", { re = frame.id, revisions = {} }))
end

---Drops the socket and completes a new handshake, without answering the
---declaration that follows.
---@param p spec.FakePlatform The platform.
local function reconnect(p)
  if p.socket then
    p.drop()
  end
  p.advance(2 * 60 * 1000)
  p.open()
  local hellos = sent_of(p, "hello")
  p.deliver(support.portal_frame("welcome", { re = hellos[#hellos].id, protocol = 1, server_id = SERVER }))
end

describe("rpf.sync", function()
  local p, connection

  before_each(function()
    support.load_core()
    p = support.fake_platform()
    connection = support.connected(p)
  end)

  describe("holding", function()
    it("holds a registered player's records for their session, and releases them when they leave", function()
      rpf.players.connected(1)
      rpf.players.authenticating(1)
      rpf.players.register(1, { player_id = PLAYER, username = "jane" })

      local hold = last_of(p, "hold")
      assert.are.same({ { kind = "player", id = PLAYER } }, hold.owners)
      local announced
      rpf.events.on("records.held", function(views)
        announced = views
      end)
      p.deliver(support.portal_frame("held", { re = hold.id, records = records_held() }))
      assert.are.equal(4, #announced)
      assert.is_true(rpf.records.is_held("container", POCKETS))

      rpf.players.dropped(1, "left")

      local release = last_of(p, "release")
      assert.are.equal(4, #release.records)
      assert.are.same({}, rpf.records.held())
    end)

    it("tries a departed player's release again once the outbox has room", function()
      rpf.players.connected(1)
      rpf.players.authenticating(1)
      rpf.players.register(1, { player_id = PLAYER, username = "jane" })
      p.deliver(support.portal_frame("held", { re = last_of(p, "hold").id, records = records_held() }))
      local waiting = assert(connection:send("player_dropped", { player_id = BANK, reason = "probe" }))

      connection.options.max_entries = #connection.outbox
      rpf.players.dropped(1, "left")
      assert.are.equal(0, #sent_of(p, "release"))
      assert.are.equal(4, #rpf.records.held(), "kept, because their final state would be lost")

      connection.options.max_entries = 2048
      p.deliver(support.portal_frame("ack", { re = waiting }))

      assert.are.equal(4, #last_of(p, "release").records)
      assert.are.same({}, rpf.records.held())
    end)

    it("leaves a returned player their records when a release was still owed", function()
      rpf.players.connected(1)
      rpf.players.authenticating(1)
      rpf.players.register(1, { player_id = PLAYER, username = "jane" })
      p.deliver(support.portal_frame("held", { re = last_of(p, "hold").id, records = records_held() }))
      local waiting = assert(connection:send("player_dropped", { player_id = BANK, reason = "probe" }))
      connection.options.max_entries = #connection.outbox
      rpf.players.dropped(1, "left")

      connection.options.max_entries = 2048
      rpf.players.connected(2)
      rpf.players.authenticating(2)
      rpf.players.register(2, { player_id = PLAYER, username = "jane" })
      p.deliver(support.portal_frame("ack", { re = waiting }))

      assert.are.equal(0, #sent_of(p, "release"))
      assert.are.equal(4, #rpf.records.held())
    end)

    it("gives a hold straight back when its player left while it was in flight", function()
      rpf.players.connected(1)
      rpf.players.authenticating(1)
      rpf.players.register(1, { player_id = PLAYER, username = "jane" })
      local hold = last_of(p, "hold")
      rpf.players.dropped(1, "left")

      p.deliver(support.portal_frame("held", { re = hold.id, records = records_held() }))

      assert.are.equal(4, #last_of(p, "release").records)
      assert.are.same({}, rpf.records.held())
    end)

    it("sends a hold only once the reports queued before it are answered", function()
      hold_all(p)
      rpf.records.set_character(CHARACTER, { first_name = "Janet" })
      flush(p)

      -- The portal may ask for the report again and answer what follows it
      -- first, and a hold answered before it would hand over state without it.
      rpf.sync.hold({ records = { { kind = "container", id = POCKETS } } })
      assert.are.equal(1, #sent_of(p, "hold"))

      apply(p, last_of(p, "state_changed"))
      assert.are.equal(2, #sent_of(p, "hold"))
    end)

    it("keeps a hold behind the resync that recovers an earlier report", function()
      hold_all(p)
      rpf.records.set_character(CHARACTER, { first_name = "Janet" })
      flush(p)
      rpf.sync.hold({ records = { { kind = "container", id = POCKETS } } })

      p.deliver(support.portal_frame("resync_required", {
        re = last_of(p, "state_changed").id,
        stale = { { kind = "character", id = CHARACTER, revision = 3 } },
        released = {},
      }))
      assert.are.equal(1, #sent_of(p, "resync"))
      assert.are.equal(1, #sent_of(p, "hold"), "the report it waited for has not landed yet")

      apply(p, last_of(p, "resync"))
      assert.are.equal(2, #sent_of(p, "hold"))
    end)

    it("hands a refusal to the caller and holds nothing", function()
      local result
      rpf.sync.hold({ records = { { kind = "account", id = WALLET } } }, nil, function(views, err)
        result = { views = views, err = err }
      end)
      p.deliver(support.portal_frame("rejected", { re = last_of(p, "hold").id, code = "not_found", reason = "no" }))

      assert.are.same({ err = "not_found" }, result)
      assert.are.same({}, rpf.records.held())
    end)
  end)

  describe("reporting", function()
    before_each(function()
      hold_all(p)
    end)

    it("batches changes into one report after the flush interval, each naming its base revision", function()
      rpf.records.set_character(CHARACTER, { first_name = "Janet" })
      rpf.records.set_contents(POCKETS, rpf.json.object({ layout = "list", stacks = rpf.json.array() }))
      assert.are.equal(0, #sent_of(p, "state_changed"), "nothing until the flush")

      flush(p)

      local report = last_of(p, "state_changed")
      assert.are.equal(2, #report.changes)
      local character, container = report.changes[1], report.changes[2]
      assert.are.same(
        { kind = "character", id = CHARACTER, base_revision = 3, first_name = "Janet" },
        character,
        "only the changed field"
      )
      assert.are.equal(1, container.base_revision)
      assert.are.equal(4, rpf.records.revision("character", CHARACTER))
    end)

    it("names consecutive revisions in reports queued behind each other", function()
      rpf.records.set_character(CHARACTER, { first_name = "A" })
      flush(p)
      rpf.records.set_character(CHARACTER, { first_name = "B" })
      flush(p)

      local reports = sent_of(p, "state_changed")
      assert.are.equal(3, reports[1].changes[1].base_revision)
      assert.are.equal(4, reports[2].changes[1].base_revision)
    end)

    it("reports a ledger entry with the paying account until a reply says it landed", function()
      local client_id = rpf.records.transfer(WALLET, BANK, 25, "Fine")
      flush(p)
      local report = last_of(p, "state_changed")
      assert.are.same({
        kind = "account",
        id = WALLET,
        base_revision = 0,
        transactions = {
          { client_id = client_id, from_account = WALLET, to_account = BANK, amount = 25, description = "Fine" },
        },
      }, report.changes[1])

      -- Unacknowledged: a resync now would carry it again.
      assert.are.equal(1, #rpf.records.entries["account:" .. WALLET].transactions)
      apply(p, report)
      assert.are.equal(0, #rpf.records.entries["account:" .. WALLET].transactions)
    end)

    it("answers a stale report with every record it named, whole, at a revision past the portal's", function()
      rpf.records.set_character(CHARACTER, { first_name = "Janet" })
      local client_id = rpf.records.transfer(WALLET, BANK, 25, "Fine")
      flush(p)
      local report = last_of(p, "state_changed")

      p.deliver(support.portal_frame("resync_required", {
        re = report.id,
        stale = { { kind = "character", id = CHARACTER, revision = 9 } },
        released = {},
      }))

      local whole = last_of(p, "resync")
      assert.are.equal(2, #whole.records)
      assert.are.same({
        kind = "account",
        id = WALLET,
        revision = 2,
        transactions = {
          { client_id = client_id, from_account = WALLET, to_account = BANK, amount = 25, description = "Fine" },
        },
      }, whole.records[1], "the unacknowledged entry goes again, at a revision of its own")
      assert.are.same({
        kind = "character",
        id = CHARACTER,
        revision = 10,
        first_name = "Janet",
        last_name = "Doe",
        gender = "female",
      }, whole.records[2], "one past the portal's revision, which is ahead")
      assert.are.equal(10, rpf.records.revision("character", CHARACTER))

      apply(p, whole)
      assert.are.equal(0, #rpf.records.entries["account:" .. WALLET].transactions)
    end)

    it("drops a record the portal says is not held here, and announces it", function()
      rpf.records.set_contents(POCKETS, rpf.json.object({ layout = "list", stacks = rpf.json.array() }))
      rpf.records.set_character(CHARACTER, { first_name = "Janet" })
      flush(p)
      local lost
      rpf.events.on("records.lost", function(refs)
        lost = refs
      end)

      p.deliver(support.portal_frame("resync_required", {
        re = last_of(p, "state_changed").id,
        stale = {},
        released = { { kind = "container", id = POCKETS } },
      }))

      assert.are.same({ { kind = "container", id = POCKETS } }, lost)
      assert.is_nil(rpf.records.get("container", POCKETS))
      local whole = last_of(p, "resync")
      assert.are.equal(1, #whole.records, "the rest of the frame, which was not applied, goes whole")
      assert.are.equal("character", whole.records[1].kind)
    end)

    it("keeps a change marked when the outbox refuses it, and reports it later", function()
      connection.options.max_entries = #connection.outbox
      rpf.records.set_character(CHARACTER, { first_name = "Janet" })
      flush(p)
      assert.are.equal(0, #sent_of(p, "state_changed"))
      assert.are.equal(3, rpf.records.revision("character", CHARACTER), "not moved until sent")

      connection.options.max_entries = 2048
      flush(p)
      assert.are.equal(3, last_of(p, "state_changed").changes[1].base_revision)
    end)

    ---The ledger entries each frame carried for the treasury, and the
    ---revisions the frames named.
    ---@param frames rpf.Frame[] The reports.
    ---@param field string `changes` or `records`.
    ---@param revision string `base_revision` or `revision`.
    ---@return integer[] counts How many entries each carried.
    ---@return number[] revisions The revision each named.
    local function carried(frames, field, revision)
      local counts, revisions = {}, {}
      for i, frame in ipairs(frames) do
        local item = frame[field][1]
        assert.are.equal(BANK, item.id)
        counts[i] = #item.transactions
        revisions[i] = item[revision]
      end
      return counts, revisions
    end

    it("reports an account's backlog in consecutive bounded reports", function()
      rpf.sync.options.max_transactions_per_report = 2
      local ids = {}
      for i = 1, 5 do
        ids[i] = rpf.records.transfer(BANK, WALLET, 1, "Tip " .. i)
      end
      flush(p)

      local reports = sent_of(p, "state_changed")
      local counts, bases = carried(reports, "changes", "base_revision")
      assert.are.same({ 2, 2, 1 }, counts)
      assert.are.same({ 7, 8, 9 }, bases)
      assert.are.equal(ids[5], reports[3].changes[1].transactions[1].client_id)
      flush(p)
      assert.are.equal(3, #sent_of(p, "state_changed"), "each entry reported once")
    end)

    it("answers a resync of an account with a backlog one whole report at a time", function()
      rpf.sync.options.max_transactions_per_report = 2
      for i = 1, 5 do
        rpf.records.transfer(BANK, WALLET, 1, "Tip " .. i)
      end
      flush(p)
      p.deliver(support.portal_frame("resync_required", {
        re = sent_of(p, "state_changed")[1].id,
        stale = { { kind = "account", id = BANK, revision = 7 } },
        released = {},
      }))

      -- Each whole report carries the oldest entries still in doubt, and the
      -- next waits for its answer, so none can overtake another.
      assert.are.equal(1, #sent_of(p, "resync"))
      apply(p, last_of(p, "resync"))
      assert.are.equal(2, #sent_of(p, "resync"))
      apply(p, last_of(p, "resync"))
      local counts, revisions = carried(sent_of(p, "resync"), "records", "revision")
      assert.are.same({ 2, 2, 1 }, counts, "every entry still in doubt, none twice")
      assert.are.same({ 11, 12, 13 }, revisions)
      apply(p, last_of(p, "resync"))
      flush(p)
      assert.are.equal(3, #sent_of(p, "resync"), "the sequence ended")
    end)

    it("keeps an account with a backlog until enough of it is acknowledged to release it whole", function()
      rpf.sync.options.max_transactions_per_report = 2
      for i = 1, 5 do
        rpf.records.transfer(BANK, WALLET, 1, "Tip " .. i)
      end

      assert.are.same({ nil, "backlog" }, { rpf.sync.release({ { kind = "account", id = BANK } }) })
      assert.is_true(rpf.records.is_held("account", BANK))
      local reports = sent_of(p, "state_changed")
      assert.are.equal(3, #reports, "flushed, so the backlog can drain")

      apply(p, reports[1])
      apply(p, reports[2])
      assert.is_true(rpf.sync.release({ { kind = "account", id = BANK } }))
      local release = last_of(p, "release")
      assert.are.equal(1, #release.records[1].transactions, "every entry still in doubt")
      assert.is_false(rpf.records.is_held("account", BANK))
    end)

    it("splits a report that would be over the frame limit", function()
      connection.options.max_frame_bytes = 300
      rpf.records.set_character(CHARACTER, { first_name = "Janet" })
      rpf.records.set_contents(POCKETS, rpf.json.object({ layout = "list", stacks = rpf.json.array() }))
      flush(p)

      local reports = sent_of(p, "state_changed")
      assert.are.equal(2, #reports)
      assert.are.equal(1, #reports[1].changes)
      assert.are.equal(1, #reports[2].changes)
    end)
  end)

  describe("releasing", function()
    before_each(function()
      hold_all(p)
    end)

    it("flushes first, then reports the final state whole and forgets the records at once", function()
      rpf.records.set_character(CHARACTER, { first_name = "Janet" })
      local client_id = rpf.records.transfer(BANK, WALLET, 5, "Tip")

      assert.is_true(rpf.sync.release({ { kind = "character", id = CHARACTER }, { kind = "account", id = WALLET } }))

      local frames = p.frames()
      assert.are.equal("release", frames[#frames].type)
      local flushed = frames[#frames - 1]
      assert.are.equal("state_changed", flushed.type, "the marked changes went first")
      assert.are.equal(2, #flushed.changes, "the payment to the released wallet among them")
      assert.are.equal(client_id, flushed.changes[1].transactions[1].client_id)
      local release = last_of(p, "release")
      assert.are.equal("Janet", release.records[1].first_name)
      assert.are.equal(5, release.records[1].revision, "one past the flushed change's 4")
      assert.is_false(rpf.records.is_held("character", CHARACTER))
      flush(p)
      assert.are.equal(1, #sent_of(p, "state_changed"), "nothing marked is left to report")
    end)

    it("releases nothing when the outbox cannot take the final state", function()
      connection.options.max_entries = #connection.outbox
      local ok, err = rpf.sync.release({ { kind = "character", id = CHARACTER } })
      assert.are.same({ nil, "outbox_full" }, { ok, err })
      assert.is_true(rpf.records.is_held("character", CHARACTER))
    end)

    it("splits a release that would be over the frame limit", function()
      connection.options.max_frame_bytes = 300
      local released = {}
      rpf.events.on("records.released", function(refs)
        released = refs
      end)

      assert.is_true(rpf.sync.release({ { kind = "character", id = CHARACTER }, { kind = "container", id = POCKETS } }))

      local releases = sent_of(p, "release")
      assert.are.equal(2, #releases)
      assert.are.equal(1, #releases[1].records)
      assert.are.equal(1, #releases[2].records)
      assert.are.equal(2, #released, "announced together")
      assert.is_false(rpf.records.is_held("container", POCKETS))
    end)

    it("keeps a record no frame can carry, says so, and releases the rest", function()
      connection.options.max_frame_bytes = 300
      local stacks = rpf.json.array()
      for i = 1, 20 do
        stacks[i] = rpf.json.object({ item = "water_bottle", count = 1 })
      end
      rpf.records.set_contents(POCKETS, rpf.json.object({ layout = "list", stacks = stacks }))

      local ok, err = rpf.sync.release({ { kind = "character", id = CHARACTER }, { kind = "container", id = POCKETS } })

      assert.are.same({ nil, "too_large" }, { ok, err })
      assert.is_true(rpf.records.is_held("container", POCKETS), "its final state would be lost")
      assert.is_false(rpf.records.is_held("character", CHARACTER))
      assert.are.equal(1, #sent_of(p, "release"))
    end)
  end)

  describe("the declaration", function()
    it("follows every Welcome, naming what is held and at which revision", function()
      hold_all(p)
      rpf.records.set_character(CHARACTER, { first_name = "Janet" })
      flush(p)
      apply(p, last_of(p, "state_changed"))

      reconnect(p)

      local declaration = last_of(p, "declare_holds")
      assert.are.same({
        { kind = "account", id = WALLET, revision = 0 },
        { kind = "account", id = BANK, revision = 7 },
        { kind = "character", id = CHARACTER, revision = 4 },
        { kind = "container", id = POCKETS, revision = 1 },
      }, declaration.records)
    end)

    it("waits for every record frame queued before the Welcome to be answered", function()
      hold_all(p)
      rpf.records.set_character(CHARACTER, { first_name = "Janet" })
      p.drop()
      flush(p)
      local declarations = #sent_of(p, "declare_holds")

      reconnect(p)
      assert.are.equal(declarations, #sent_of(p, "declare_holds"), "the report goes first")
      local report = last_of(p, "state_changed")
      apply(p, report)

      assert.are.equal(declarations + 1, #sent_of(p, "declare_holds"))
    end)

    it("declares nothing after a restart, so the portal releases what the old process held", function()
      local store = p.store
      hold_all(p)
      support.load_core()
      local restarted = support.fake_platform({ store = store, seed = 99 })
      rpf.start_server(restarted, { url = "ws://portal", api_key = "rpf_test_secret" })
      restarted.open()
      restarted.deliver(support.portal_frame("welcome", { re = restarted.last().id, protocol = 1, server_id = SERVER }))

      assert.are.same({}, last_of(restarted, "declare_holds").records)
    end)

    it("sends a stale report from before a restart again, and declares only once it has landed", function()
      local store = p.store
      hold_all(p)
      rpf.records.set_character(CHARACTER, { first_name = "Janet" })
      flush(p)
      rpf.records.set_character(CHARACTER, { last_name = "Roe" })
      flush(p)
      support.load_core()
      local restarted = support.fake_platform({ store = store, seed = 99 })
      rpf.start_server(restarted, { url = "ws://portal", api_key = "rpf_test_secret" })
      restarted.open()
      restarted.deliver(support.portal_frame("welcome", { re = restarted.last().id, protocol = 1, server_id = SERVER }))
      local reports = sent_of(restarted, "state_changed")
      assert.are.equal(2, #reports, "both replayed")

      -- The portal asks for the first again, so the second finds its base
      -- revision not reached yet.
      restarted.deliver(support.portal_frame("rejected", { re = reports[1].id, code = "retry", reason = "busy" }))
      restarted.deliver(support.portal_frame("resync_required", {
        re = reports[2].id,
        stale = { { kind = "character", id = CHARACTER, revision = 3 } },
        released = {},
      }))
      restarted.advance(3000)
      local again = sent_of(restarted, "state_changed")
      assert.are.equal(4, #again, "each sent again, under its own id")
      assert.are.equal(reports[2].id, again[4].id)
      assert.are.equal(0, #sent_of(restarted, "declare_holds"), "which would release the record")

      apply(restarted, reports[1])
      apply(restarted, reports[2])
      assert.are.same({}, last_of(restarted, "declare_holds").records)
    end)

    it("keeps a stale report from before a restart for as long as the one before it is unanswered", function()
      local store = p.store
      hold_all(p)
      rpf.records.set_character(CHARACTER, { first_name = "Janet" })
      flush(p)
      rpf.records.set_character(CHARACTER, { last_name = "Roe" })
      flush(p)
      support.load_core()
      local restarted = support.fake_platform({ store = store, seed = 99 })
      rpf.start_server(restarted, { url = "ws://portal", api_key = "rpf_test_secret" })
      restarted.open()
      restarted.deliver(support.portal_frame("welcome", { re = restarted.last().id, protocol = 1, server_id = SERVER }))
      local reports = sent_of(restarted, "state_changed")
      local stale = {
        re = reports[2].id,
        stale = { { kind = "character", id = CHARACTER, revision = 3 } },
        released = {},
      }

      -- A long transient fault: far more refusals than a report with
      -- nothing before it would be given.
      for _ = 1, 12 do
        restarted.deliver(support.portal_frame("rejected", { re = reports[1].id, code = "retry", reason = "busy" }))
        restarted.deliver(support.portal_frame("resync_required", stale))
        restarted.advance(2 * 60 * 1000)
      end
      assert.are.equal(0, #sent_of(restarted, "declare_holds"))
      local sent = #sent_of(restarted, "state_changed")

      apply(restarted, reports[1])
      restarted.deliver(support.portal_frame("resync_required", stale))
      restarted.advance(2 * 60 * 1000)
      assert.are.equal(sent + 1, #sent_of(restarted, "state_changed"), "still kept, and sent again")
      apply(restarted, reports[2])
      assert.are.same({}, last_of(restarted, "declare_holds").records)
    end)

    it("gives up a stale report from before a restart that has nothing before it to wait for", function()
      local store = p.store
      hold_all(p)
      rpf.records.set_character(CHARACTER, { first_name = "Janet" })
      flush(p)
      support.load_core()
      local restarted = support.fake_platform({ store = store, seed = 99 })
      rpf.start_server(restarted, { url = "ws://portal", api_key = "rpf_test_secret" })
      restarted.open()
      restarted.deliver(support.portal_frame("welcome", { re = restarted.last().id, protocol = 1, server_id = SERVER }))
      local report = last_of(restarted, "state_changed")

      for _ = 1, rpf.sync.options.orphan_retries + 1 do
        assert.are.equal(0, #sent_of(restarted, "declare_holds"))
        restarted.deliver(support.portal_frame("resync_required", {
          re = report.id,
          stale = { { kind = "character", id = CHARACTER, revision = 9 } },
          released = {},
        }))
        restarted.advance(2 * 60 * 1000)
      end

      assert.are.equal(1 + rpf.sync.options.orphan_retries, #sent_of(restarted, "state_changed"))
      assert.are.equal(1, #sent_of(restarted, "declare_holds"))
    end)

    it("drops a report from before a restart that names a record no longer held here", function()
      local store = p.store
      hold_all(p)
      rpf.records.set_character(CHARACTER, { first_name = "Janet" })
      flush(p)
      support.load_core()
      local restarted = support.fake_platform({ store = store, seed = 99 })
      rpf.start_server(restarted, { url = "ws://portal", api_key = "rpf_test_secret" })
      restarted.open()
      restarted.deliver(support.portal_frame("welcome", { re = restarted.last().id, protocol = 1, server_id = SERVER }))

      restarted.deliver(support.portal_frame("resync_required", {
        re = last_of(restarted, "state_changed").id,
        stale = {},
        released = { { kind = "character", id = CHARACTER } },
      }))

      assert.are.equal(1, #sent_of(restarted, "declare_holds"))
    end)

    it("makes new holds wait for its answer", function()
      reconnect(p)
      local declaration = last_of(p, "declare_holds")
      rpf.sync.hold({ records = { { kind = "character", id = CHARACTER } } })
      assert.are.equal(0, #sent_of(p, "hold"), "not before the declaration is answered")

      p.deliver(support.portal_frame("state_applied", { re = declaration.id, revisions = {} }))

      assert.are.equal(1, #sent_of(p, "hold"))
    end)

    it("drops what the portal released and resyncs what it calls stale", function()
      hold_all(p)
      reconnect(p)
      local declaration = last_of(p, "declare_holds")

      p.deliver(support.portal_frame("resync_required", {
        re = declaration.id,
        stale = { { kind = "account", id = BANK, revision = 8 } },
        released = { { kind = "container", id = POCKETS } },
      }))

      assert.is_false(rpf.records.is_held("container", POCKETS))
      local whole = last_of(p, "resync")
      assert.are.same({ { kind = "account", id = BANK, revision = 9, transactions = {} } }, whole.records)
    end)
  end)
end)
