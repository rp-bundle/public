-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The operation journal (`rpf.ops`, J3): each facade command runs at most
-- once per op id, a repeat gets the recorded result, a restart turns an
-- intent it cut off into `unknown`, tombstones go only by age, a full
-- journal refuses rather than forgets, a lost index never lets an id run
-- twice, every `unknown` is surfaced to staff with what it was, and
-- reported to the portal until it has it (#274).

local support = require("spec.support")

describe("rpf.ops", function()
  local store, p

  ---Starts the core over the shared store, as a restart does.
  local function start()
    support.load_core()
    p = support.fake_platform({ store = store })
    rpf.start_server(p, { url = "ws://portal", api_key = "rpf_test_secret" })
  end

  before_each(function()
    store = {}
    start()
  end)

  it("mints ids that carry when they were minted", function()
    local id = assert(rpf.ops.new())
    assert.are.equal(p.now(), rpf.ops.minted_at(id))
    assert.are_not.equal(id, rpf.ops.new())
    assert.is_nil(rpf.ops.minted_at("1-xyz"))
    assert.is_nil(rpf.ops.minted_at(42))
  end)

  it("runs a command once per id, and answers a repeat from the journal, after a restart too", function()
    local runs = 0
    local id = rpf.ops.new()
    local command = function()
      runs = runs + 1
      return nil, "refused", "insufficient_funds"
    end
    assert.are.same({ nil, "refused", "insufficient_funds" }, { rpf.ops.run(id, "money.debit", nil, command) })
    assert.are.same({ nil, "refused", "insufficient_funds" }, { rpf.ops.run(id, "money.debit", nil, command) })
    start()
    assert.are.same({ nil, "refused", "insufficient_funds" }, { rpf.ops.run(id, "money.debit", nil, command) })
    assert.are.equal(1, runs)
  end)

  it("turns an intent a restart cut off into unknown, says so, and never runs it", function()
    local id = rpf.ops.new()
    local runs = 0
    -- The command never returns: the process dies inside it.
    pcall(rpf.ops.run, id, "money.debit", nil, function()
      runs = runs + 1
      error({ died = true })
    end)
    -- A throw is unknown at once; a crash leaves it pending, as here.
    local entry = rpf.json.decode(store[rpf.ops.ENTRY_PREFIX .. id])
    entry.state = "pending"
    store[rpf.ops.ENTRY_PREFIX .. id] = rpf.json.encode(entry)
    start()
    local warned = false
    for _, line in ipairs(p.logs) do
      warned = warned or (line.level == "error" and line.message:find(id, 1, true) ~= nil)
    end
    assert.is_true(warned, "logged for staff")
    local listed = rpf.ops.unknown()
    assert.are.equal(1, #listed)
    assert.are.equal(id, listed[1].op_id)
    assert.are.equal("cut off by a restart", listed[1].cause)
    assert.are.same({ nil, "unknown" }, {
      rpf.ops.run(id, "money.debit", nil, function()
        runs = runs + 1
        return true
      end),
    })
    assert.are.equal(1, runs)
  end)

  it("answers unknown for a command that throws, and keeps it", function()
    local id = rpf.ops.new()
    assert.are.same({ nil, "unknown" }, {
      rpf.ops.run(id, "inventory.give", nil, function()
        error("half done")
      end),
    })
    assert.are.same({ nil, "unknown" }, {
      rpf.ops.run(id, "inventory.give", nil, function()
        return true
      end),
    })
  end)

  it("refuses a new command when full rather than forget a young result, and makes room only by age", function()
    local first = rpf.ops.new()
    local runs = 0
    ---A credit that counts its runs.
    ---@return boolean ok True.
    local function credit()
      runs = runs + 1
      return true
    end
    assert.is_true(rpf.ops.run(first, "money.credit", nil, credit))
    for _ = 2, rpf.ops.MAX_ENTRIES do
      assert.is_true(rpf.ops.run(rpf.ops.new(), "money.credit", nil, credit))
    end
    local ran = false
    assert.are.same({ nil, "refused", "journal_full" }, {
      rpf.ops.run(rpf.ops.new(), "money.credit", nil, function()
        ran = true
        return true
      end),
    })
    assert.is_false(ran)
    -- The oldest result is still young, so it was kept: its id answers from
    -- the journal, full or not, and never runs a second time.
    assert.is_true(rpf.ops.run(first, "money.credit", nil, credit))
    assert.are.equal(rpf.ops.MAX_ENTRIES, runs)
    p.advance(rpf.ops.WINDOW_MS + 1)
    assert.is_true(rpf.ops.run(rpf.ops.new(), "money.credit", nil, function()
      return true
    end))
    assert.are.equal(1, rpf.ops.count())
    local stored = 0
    for key in pairs(store) do
      if key:sub(1, #rpf.ops.ENTRY_PREFIX) == rpf.ops.ENTRY_PREFIX then
        stored = stored + 1
      end
    end
    assert.are.equal(1, stored, "the old entries left storage too")
  end)

  it("refuses an id older than the window, or minted far in the future", function()
    local id = rpf.ops.new()
    p.advance(rpf.ops.WINDOW_MS + 1)
    assert.are.same({ nil, "refused", "expired_op" }, { rpf.ops.run(id, "money.debit", nil, function() return true end) })
    local ahead = string.format("%d-%s", p.now() + rpf.ops.SKEW_MS + 1000, string.rep("a", 16))
    assert.are.same({ nil, "refused", "invalid_op" }, { rpf.ops.run(ahead, "money.debit", nil, function() return true end) })
  end)

  it("records a success on disk only once its change is, and reads it as unknown after a crash before", function()
    local id = rpf.ops.new()
    local on_disk = false
    assert.is_true(rpf.ops.run(id, "money.debit", function()
      return on_disk
    end, function()
      return true
    end))
    assert.is_true(rpf.ops.run(id, "money.debit", nil, function() end), "known here at once")
    local stored = rpf.json.decode(store[rpf.ops.ENTRY_PREFIX .. id])
    assert.are.equal("pending", stored.state, "but pending on disk until the change is")
    on_disk = true
    p.advance(1000)
    stored = rpf.json.decode(store[rpf.ops.ENTRY_PREFIX .. id])
    assert.are.equal("done", stored.state)

    -- A second, whose change never reached the disk before the crash.
    local lost = rpf.ops.new()
    on_disk = false
    assert.is_true(rpf.ops.run(lost, "money.debit", function()
      return on_disk
    end, function()
      return true
    end))
    start()
    assert.are.same({ nil, "unknown" }, { rpf.ops.run(lost, "money.debit", nil, function() return true end) })
  end)

  it("runs nothing when the intent cannot be written", function()
    local ran = false
    p.kv_set = function()
      error("disk full")
    end
    assert.are.same({ nil, "unavailable" }, {
      rpf.ops.run(rpf.ops.new(), "money.debit", nil, function()
        ran = true
        return true
      end),
    })
    assert.is_false(ran)
  end)
  it("surfaces every unknown with what it was, as it happens", function()
    local seen = {}
    rpf.events.on("domains.op_unknown", function(unknown)
      seen[#seen + 1] = unknown
    end)
    local id = rpf.ops.new()
    local detail = { player = "00000002-0000-4000-8000-000000000002", account = "bank", amount = 250, reason = "Car" }
    assert.are.same({ nil, "unknown" }, {
      rpf.ops.run(id, "money.debit", nil, function()
        return nil, "unknown", "the framework did not answer"
      end, detail),
    })
    assert.are.equal(1, #seen)
    assert.are.same({
      op_id = id,
      call = "money.debit",
      at = rpf.ops.minted_at(id),
      detail = detail,
      cause = "the framework did not answer",
    }, seen[1])
    assert.are.same(seen, rpf.ops.unknown())
    assert.are.equal(1, #p.logged("error", "account=bank amount=250"))
    -- A repeat answers from the journal, and is not surfaced again.
    assert.are.same({ nil, "unknown" }, { rpf.ops.run(id, "money.debit", nil, function() return true end) })
    assert.are.equal(1, #seen)
    -- The detail is kept on disk, so a restart can still say what it was.
    start()
    assert.are.same(detail, rpf.ops.unknown()[1].detail)
  end)

  it("never runs an id twice when a crash lost the index, looking it up by its own key", function()
    local runs = 0
    ---A debit that counts its runs.
    ---@return boolean ok True.
    local function debit()
      runs = runs + 1
      return true
    end
    local done, cut = rpf.ops.new(), rpf.ops.new()
    assert.is_true(rpf.ops.run(done, "money.debit", nil, debit))
    pcall(rpf.ops.run, cut, "money.debit", nil, debit)
    local entry = rpf.json.decode(store[rpf.ops.ENTRY_PREFIX .. cut])
    entry.state = "pending"
    store[rpf.ops.ENTRY_PREFIX .. cut] = rpf.json.encode(entry)
    store[rpf.ops.KEY] = "{not json"
    start()
    assert.are.equal(1, #p.logged("error", "index could not be read"))
    assert.is_true(rpf.ops.run(done, "money.debit", nil, debit), "the recorded result, found by its key")
    assert.are.same({ nil, "unknown" }, { rpf.ops.run(cut, "money.debit", nil, debit) })
    assert.are.equal(2, runs, "neither ran again")
    assert.are.equal(cut, rpf.ops.unknown()[1].op_id, "the cut-off one is surfaced when found")
    -- Found, they are in the index again, so the next restart knows them.
    start()
    assert.are.equal(2, rpf.ops.count())
    -- An id minted before the restart with nothing stored never ran: it
    -- runs. (A millisecond on, since the fake platform's randomness starts
    -- over with each boot.)
    p.advance(1)
    local fresh = rpf.ops.new()
    start()
    assert.is_true(rpf.ops.run(fresh, "money.debit", nil, debit))
    assert.are.equal(3, runs)
  end)

  it("answers unavailable, and says why, when storage fails a lookup, never 'never ran'", function()
    local id = rpf.ops.new()
    assert.is_true(rpf.ops.run(id, "money.debit", nil, function()
      return true
    end))
    start()
    store[rpf.ops.KEY] = nil
    start()
    p.kv_get = function()
      error("disk gone")
    end
    assert.are.same({ true, nil, "unavailable" }, { rpf.ops.known(id) })
    assert.are.equal(1, #p.logged("error", "disk gone"))
    assert.are.same({ nil, "unavailable" }, {
      rpf.ops.run(id, "money.debit", nil, function()
        error("must not run")
      end),
    })
  end)

  it("reads an entry it cannot decode as unknown, never as a command to run", function()
    local id = rpf.ops.new()
    local runs = 0
    assert.is_true(rpf.ops.run(id, "money.debit", nil, function()
      runs = runs + 1
      return true
    end))
    store[rpf.ops.ENTRY_PREFIX .. id] = "garbage"
    start()
    assert.are.same({ nil, "unknown" }, {
      rpf.ops.run(id, "money.debit", nil, function()
        runs = runs + 1
        return true
      end),
    })
    assert.are.equal(1, runs)
  end)

  it("says when it cannot tell whether a change is on disk, once, and keeps trying", function()
    local id = rpf.ops.new()
    local checks = 0
    assert.is_true(rpf.ops.run(id, "money.debit", function()
      checks = checks + 1
      if checks < 3 then
        error("the outbox is broken")
      end
      return true
    end, function()
      return true
    end))
    p.advance(1000)
    p.advance(1000)
    assert.are.equal(3, checks)
    assert.are.equal(1, #p.logged("error", "the outbox is broken"))
    assert.are.equal("done", rpf.json.decode(store[rpf.ops.ENTRY_PREFIX .. id]).state)
  end)

  describe("reporting unknowns to the portal", function()
    local PLAYER = "00000002-0000-4000-8000-000000000002"

    ---Starts the core over the shared store, connected, as a restart that
    ---reaches the portal does, with the clock where it was.
    local function connect()
      local now = p.time
      support.load_core()
      p = support.fake_platform({ store = store, time = now })
      support.connected(p)
    end

    ---Every `report_unknown_ops` frame sent, decoded as the portal reads it.
    ---@return rpf.Frame[] reports The frames.
    local function reports()
      local out = {}
      for _, text in ipairs(p.sent) do
        local frame = assert(rpf.protocol.decode(rpf.protocol.SERVER_TO_PORTAL, text))
        if frame.type == "report_unknown_ops" then
          out[#out + 1] = frame
        end
      end
      return out
    end

    ---Runs a command that ends `unknown`, a millisecond on, running no
    ---timer: its report goes out at the test's next `advance`.
    ---@param detail rpf.ops.Detail? What it was.
    ---@return string id Its op id.
    local function unknown(detail)
      p.time = p.time + 1
      local id = assert(rpf.ops.new())
      rpf.ops.run(id, "money.debit", nil, function()
        return nil, "unknown", "the framework did not answer"
      end, detail)
      return id
    end

    it("reports one as it arises, as the portal reads it, and not again once the portal has it", function()
      connect()
      local id = unknown({ player = PLAYER, account = "bank", amount = 250, reason = "Car" })
      p.advance(0)
      local sent = reports()
      assert.are.equal(1, #sent)
      assert.are.same({
        op_id = id,
        call = "money.debit",
        cause = "the framework did not answer",
        player_id = PLAYER,
        account = "bank",
        amount = 250,
        reason = "Car",
      }, sent[1].ops[1])
      p.deliver(support.portal_frame("ack", { re = sent[1].id }))
      assert.is_true(rpf.json.decode(store[rpf.ops.ENTRY_PREFIX .. id]).reported)
      -- Still listed for an in-game tool, but never sent again.
      connect()
      assert.are.equal(id, rpf.ops.unknown()[1].op_id)
      assert.are.equal(0, #reports())
    end)

    it("reports after a Welcome what a restart cut off before the connection", function()
      local id = rpf.ops.new()
      pcall(rpf.ops.run, id, "inventory.give", nil, function()
        error({ died = true })
      end, { player = PLAYER, item = "water_bottle", count = 2 })
      local entry = rpf.json.decode(store[rpf.ops.ENTRY_PREFIX .. id])
      entry.state = "pending"
      store[rpf.ops.ENTRY_PREFIX .. id] = rpf.json.encode(entry)
      connect()
      p.advance(0)
      local sent = reports()
      assert.are.equal(1, #sent, "once, though both the restart and the Welcome asked")
      assert.are.same({
        op_id = id,
        call = "inventory.give",
        cause = "cut off by a restart",
        player_id = PLAYER,
        item = "water_bottle",
        count = 2,
      }, sent[1].ops[1])
    end)

    it("sends one dropped unanswered again on the next Welcome, and one in flight only once", function()
      connect()
      local id = unknown()
      p.advance(0)
      assert.are.equal(1, #reports())
      -- A second unknown while the first is in flight goes alone.
      local second = unknown()
      p.advance(0)
      local sent = reports()
      assert.are.equal(2, #sent)
      assert.are.same({ second }, { sent[2].ops[1].op_id })
      -- A restart loses the callbacks; the outbox resends the frames, and
      -- the Welcome reports both once more, which the portal takes as the
      -- same two.
      connect()
      local ids = {}
      for _, frame in ipairs(reports()) do
        for _, op in ipairs(frame.ops) do
          ids[op.op_id] = true
        end
      end
      assert.are.same({ [id] = true, [second] = true }, ids)
    end)

    it("logs a refusal at error, naming what it carried, and does not send it again", function()
      connect()
      local id = unknown()
      p.advance(0)
      p.deliver(support.portal_frame("rejected", {
        re = reports()[1].id,
        code = "forbidden",
        reason = "This server has as many unresolved unknown operations as it may: resolve some.",
      }))
      assert.are.equal(1, #p.logged("error", "refused unknown operations " .. id))
      connect()
      assert.are.equal(0, #reports())
    end)

    it("keeps one the portal has not answered past the window, and lets it go once answered", function()
      local id = unknown()
      p.advance(rpf.ops.WINDOW_MS + 1)
      -- A new command sweeps the journal: the unreported one stays.
      assert.is_true(rpf.ops.run(rpf.ops.new(), "money.credit", nil, function()
        return true
      end))
      assert.are.equal(id, rpf.ops.unknown()[1].op_id)
      assert.are.same({ nil, "refused", "expired_op" }, {
        rpf.ops.run(id, "money.debit", nil, function()
          error("must not run")
        end),
      })
      -- The frame queued before the restart goes out again, without its
      -- callback, and the Welcome's report with one: the portal acks both.
      connect()
      for _, frame in ipairs(reports()) do
        p.deliver(support.portal_frame("ack", { re = frame.id }))
      end
      connect()
      assert.are.same({}, rpf.ops.unknown())
    end)

    it("sends at most a frame's worth at once, and only what the portal accepts", function()
      local long = string.rep("é", 200)
      for i = 1, rpf.ops.MAX_PER_REPORT do
        unknown({ player = "not-a-uuid", reason = i == 1 and long or nil, amount = 1.5 })
      end
      unknown({ account = "ba" .. string.char(0) .. "nk" .. string.char(0) })
      connect()
      local sent = reports()
      assert.are.equal(2, #sent)
      assert.are.equal(rpf.ops.MAX_PER_REPORT, #sent[1].ops)
      assert.are.equal(1, #sent[2].ops)
      local first = sent[1].ops[1]
      assert.is_nil(first.player_id)
      assert.is_nil(first.amount)
      assert.is_true(#first.reason <= rpf.ops.MAX_TEXT_BYTES)
      assert.is_true(rpf.json.is_utf8(first.reason))
      assert.are.equal(string.rep("é", math.floor(rpf.ops.MAX_TEXT_BYTES / 2)), first.reason)
      assert.are.equal("bank", sent[2].ops[1].account)
    end)

    it("keeps its bounds equal to the portal's", function()
      local limits = support.portal_source("crates/rpf-domain/src/limits.rs", pending)
      for name, ours in pairs({
        MAX_UNKNOWN_OPS_PER_REPORT = rpf.ops.MAX_PER_REPORT,
        MAX_UNKNOWN_OP_TEXT_BYTES = rpf.ops.MAX_TEXT_BYTES,
      }) do
        local theirs = limits:match("pub const " .. name .. ": usize = (%d+);")
        assert.truthy(theirs, name .. " is no longer an integer literal")
        assert.are.equal(tonumber(theirs), ours, name)
      end
    end)
  end)
end)
