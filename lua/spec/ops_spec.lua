-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The operation journal (`rpf.ops`, J3): each facade command runs at most
-- once per op id, a repeat gets the recorded result, a restart turns an
-- intent it cut off into `unknown`, tombstones go only by age, and a full
-- journal refuses rather than forgets.

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
      warned = warned or (line.level == "warn" and line.message:find(id, 1, true) ~= nil)
    end
    assert.is_true(warned, "logged for staff")
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
    for _ = 1, rpf.ops.MAX_ENTRIES do
      assert.is_true(rpf.ops.run(rpf.ops.new(), "money.credit", nil, function()
        return true
      end))
    end
    local ran = false
    assert.are.same({ nil, "refused", "journal_full" }, {
      rpf.ops.run(rpf.ops.new(), "money.credit", nil, function()
        ran = true
        return true
      end),
    })
    assert.is_false(ran)
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
end)
