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

    it("answers a stale report with every record it named, whole, at no lower than the portal's revision", function()
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
        revision = 1,
        transactions = {
          { client_id = client_id, from_account = WALLET, to_account = BANK, amount = 25, description = "Fine" },
        },
      }, whole.records[1], "the unacknowledged entry goes again")
      assert.are.same({
        kind = "character",
        id = CHARACTER,
        revision = 9,
        first_name = "Janet",
        last_name = "Doe",
        gender = "female",
      }, whole.records[2], "at the portal's revision, which is ahead")
      assert.are.equal(9, rpf.records.revision("character", CHARACTER))

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

    it("reports the final state whole and forgets the records at once", function()
      rpf.records.set_character(CHARACTER, { first_name = "Janet" })
      local client_id = rpf.records.transfer(WALLET, BANK, 5, "Tip")

      assert.is_true(rpf.sync.release({ { kind = "character", id = CHARACTER }, { kind = "account", id = WALLET } }))

      local release = last_of(p, "release")
      assert.are.equal("Janet", release.records[1].first_name)
      assert.are.equal(client_id, release.records[2].transactions[1].client_id)
      assert.is_false(rpf.records.is_held("character", CHARACTER))
      flush(p)
      assert.are.equal(0, #sent_of(p, "state_changed"), "nothing marked is left to report")
    end)

    it("releases nothing when the outbox cannot take the final state", function()
      connection.options.max_entries = #connection.outbox
      local ok, err = rpf.sync.release({ { kind = "character", id = CHARACTER } })
      assert.are.same({ nil, "outbox_full" }, { ok, err })
      assert.is_true(rpf.records.is_held("character", CHARACTER))
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
      assert.are.same({ { kind = "account", id = BANK, revision = 8, transactions = {} } }, whole.records)
    end)
  end)
end)
