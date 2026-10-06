-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Money on held accounts (D5): every movement is a ledger entry with a
-- client_id minted from the platform's randomness, reported with the next
-- flush; nothing sets a balance; and the running balance is the fold.

local support = require("spec.support")

local SERVER = "00000001-0000-4000-8000-000000000001"
local JANE = "00000003-0000-4000-8000-000000000003"
local WALLET = "00000004-0000-4000-8000-000000000004"
local BANK = "00000004-0000-4000-8000-000000000044"
local TREASURY = "00000005-0000-4000-8000-000000000005"
local OTHER = "00000004-0000-4000-8000-0000000000ff"
local PLAYER = "00000002-0000-4000-8000-000000000002"
local FLAGGED = "00000004-0000-4000-8000-000000000006"
local PAYROLL = "00000004-0000-4000-8000-000000000007"
local EMPLOYER = "00000005-0000-4000-8000-000000000008"
local UUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

---An account as the portal hands one over.
---@param id string Its id.
---@param owner table Its owner.
---@param name string Its name.
---@param balance number Its balance.
---@param flags string[]? Its flags.
---@return table record The `held` record.
local function account(id, owner, name, balance, flags)
  return {
    kind = "account",
    revision = 2,
    account = {
      id = id,
      server_id = SERVER,
      owner = owner,
      name = name,
      flags = rpf.json.array(flags or {}),
    },
    balance = balance,
  }
end

describe("rpf.accounts", function()
  local p

  before_each(function()
    support.load_core()
    p = support.fake_platform()
    support.connected(p)
    local jane = { kind = "character", id = JANE }
    rpf.records.take({
      account(WALLET, jane, "Wallet", 100),
      account(BANK, jane, "Bank", 0),
      account(TREASURY, { kind = "server", id = SERVER }, "Treasury", 0, { "unlimited_balance" }),
    })
  end)

  it("reads a held account's balance, and nothing for one not held", function()
    assert.are.equal(100, rpf.accounts.balance(WALLET))
    assert.are.same({ nil, "not_held" }, { rpf.accounts.balance(OTHER) })
    assert.is_nil(rpf.accounts.get(OTHER))
  end)

  it("lists an owner's held accounts by name", function()
    local names = {}
    for _, a in ipairs(rpf.accounts.owned_by("character", JANE)) do
      names[#names + 1] = a.name
    end
    assert.are.same({ "Bank", "Wallet" }, names)
    assert.are.same({}, rpf.accounts.owned_by("character", OTHER))
  end)

  it("transfers as one ledger entry, reported with the next flush", function()
    local id = assert(rpf.accounts.transfer(WALLET, BANK, 40, "Deposit"))
    assert.is_truthy(id:find(UUID), "a uuid minted from random_hex")
    assert.are.equal(60, rpf.accounts.balance(WALLET))
    assert.are.equal(40, rpf.accounts.balance(BANK))

    p.advance(1000)
    local frame = p.last()
    assert.are.equal("state_changed", frame.type)
    local reported = {}
    for _, change in ipairs(frame.changes) do
      for _, tx in ipairs(change.transactions) do
        reported[#reported + 1] = tx
      end
    end
    assert.are.equal(1, #reported, "once, on the paying account")
    assert.are.same(
      { client_id = id, from_account = WALLET, to_account = BANK, amount = 40, description = "Deposit" },
      reported[1]
    )
  end)

  it("mints a fresh client_id for every entry", function()
    local a = rpf.accounts.transfer(WALLET, BANK, 1, "a")
    local b = rpf.accounts.transfer(WALLET, BANK, 1, "b")
    assert.are_not.equal(a, b)
  end)

  it("refuses a transfer that would overdraw, unless the account may go below zero", function()
    assert.are.same({ nil, "insufficient_funds" }, { rpf.accounts.transfer(WALLET, BANK, 101, "x") })
    assert.are.equal(100, rpf.accounts.balance(WALLET))
    assert.is_truthy(rpf.accounts.transfer(TREASURY, BANK, 500, "x"))
    assert.are.equal(-500, rpf.accounts.balance(TREASURY))
  end)

  it("refuses amounts that are not whole, positive and at most 2^53 - 1", function()
    for _, amount in ipairs({ 0, -1, 1.5, rpf.protocol.MAX_AMOUNT + 1, 2 ^ 60, 0 / 0, 1 / 0, "5" }) do
      assert.are.same({ nil, "invalid" }, { rpf.accounts.transfer(TREASURY, BANK, amount, "x") }, tostring(amount))
      assert.are.same({ nil, "invalid" }, { rpf.accounts.pay(TREASURY, BANK, amount, "x") }, tostring(amount))
    end
    assert.are.equal(0, rpf.accounts.balance(BANK))
  end)

  it("refuses an account this server does not hold", function()
    assert.are.same({ nil, "not_held" }, { rpf.accounts.transfer(WALLET, OTHER, 1, "x") })
    assert.are.same({ nil, "not_held" }, { rpf.accounts.pay(OTHER, WALLET, 1, "x") })
    assert.are.same({ nil, "not_held" }, { rpf.accounts.pay(TREASURY, OTHER, 1, "x") })
  end)

  it("pays from an unlimited account only", function()
    assert.is_truthy(rpf.accounts.pay(TREASURY, WALLET, 1000, "Wage"))
    assert.are.equal(1100, rpf.accounts.balance(WALLET))
    assert.are.equal(-1000, rpf.accounts.balance(TREASURY))
    assert.are.same({ nil, "not_a_source" }, { rpf.accounts.pay(WALLET, BANK, 1, "x") })
    assert.are.equal(1100, rpf.accounts.balance(WALLET))
  end)

  it("never pays from a player's or a character's account, whatever its flags", function()
    rpf.records.take({
      account(FLAGGED, { kind = "character", id = JANE }, "Flagged", 50, { "unlimited_balance" }),
      account(PAYROLL, { kind = "player", id = PLAYER }, "Flagged", 50, { "unlimited_balance" }),
      account(EMPLOYER, { kind = "employer", id = SERVER }, "Payroll", 0, { "unlimited_balance" }),
    })
    assert.are.same({ nil, "not_a_source" }, { rpf.accounts.pay(FLAGGED, WALLET, 1, "x") })
    assert.are.same({ nil, "not_a_source" }, { rpf.accounts.pay(PAYROLL, WALLET, 1, "x") })
    assert.are.equal(50, rpf.accounts.balance(FLAGGED))
    assert.are.equal(100, rpf.accounts.balance(WALLET))
    assert.is_truthy(rpf.accounts.pay(EMPLOYER, WALLET, 5, "Wage"), "an employer's payroll pays")
  end)

  it("keeps every balance within 2^53 - 1", function()
    local max = rpf.protocol.MAX_AMOUNT
    assert.is_truthy(rpf.accounts.pay(TREASURY, BANK, max, "x"))
    assert.are.same({ nil, "out_of_range" }, { rpf.accounts.pay(TREASURY, BANK, 1, "x") })
    assert.are.same({ nil, "out_of_range" }, { rpf.accounts.pay(TREASURY, WALLET, 1, "x") }, "the source too")
    assert.are.equal(max, rpf.accounts.balance(BANK))
  end)

  it("has no function that sets a balance", function()
    for name in pairs(rpf.accounts) do
      assert.is_nil(name:find("^set"), name)
    end
  end)

  it("keeps a running balance equal to the fold over the entries made", function()
    local ledger = {
      -- The portal's balances when it handed them over, as entries.
      { from_account = OTHER, to_account = WALLET, amount = 100 },
    }
    local moves = {
      { TREASURY, WALLET, 7000 },
      { WALLET, BANK, 2500 },
      { BANK, WALLET, 1 },
      { WALLET, TREASURY, 99 },
    }
    for _, move in ipairs(moves) do
      assert(rpf.accounts.transfer(move[1], move[2], move[3], "x"))
      ledger[#ledger + 1] = { from_account = move[1], to_account = move[2], amount = move[3] }
    end
    for _, id in ipairs({ WALLET, BANK, TREASURY }) do
      assert.are.equal(rpf.accounts.fold(id, ledger), rpf.accounts.balance(id), id)
    end
  end)
end)

-- #169: the server's paying accounts are held for it, after every `Welcome`
-- and whenever a config names one it does not hold, so `pay` has a source
-- without a script holding one.
describe("rpf.accounts holding the paying accounts", function()
  local SECOND = "00000005-0000-4000-8000-000000000009"
  local p

  ---A config snapshot naming paying accounts.
  ---@param accounts table[] Each `{ id, name }`.
  ---@return table snapshot The snapshot, decoded as off the wire.
  local function snapshot(accounts)
    local text = assert(rpf.json.encode(rpf.json.object({
      settings = rpf.json.object({}),
      paying_accounts = rpf.json.array(accounts),
    })))
    return assert(rpf.json.decode(text))
  end

  ---Every frame of one type sent so far.
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

  ---Answers a hold as the portal would, handing over the server's accounts it names.
  ---@param hold rpf.Frame The hold.
  local function answer(hold)
    local held = {}
    for _, ref in ipairs(hold.records) do
      held[#held + 1] =
        account(ref.id, { kind = "server", id = SERVER }, ref.id == TREASURY and "treasury" or "rewards", 0, { "unlimited_balance" })
    end
    p.deliver(support.portal_frame("held", { re = hold.id, records = held }))
  end

  before_each(function()
    support.load_core()
    p = support.fake_platform()
    -- The config a previous run applied, restored at start.
    rpf.config.apply(p, 4, "h4", snapshot({ { id = TREASURY, name = "treasury" } }))
  end)

  it("holds them after the Welcome, once the declaration is answered", function()
    support.connected(p)
    local holds = sent_of("hold")
    assert.are.equal(1, #holds)
    assert.are.same({ { kind = "account", id = TREASURY } }, holds[1].records)
    assert.are.same({}, holds[1].owners)
    assert.are.same({ nil, "not_held" }, { rpf.accounts.pay(TREASURY, TREASURY, 1, "x") })

    answer(holds[1])
    assert.is_true(rpf.records.is_held("account", TREASURY))
    assert.are.equal("treasury", rpf.config.paying_account("treasury").name)
    -- Held for no player: a departure never releases it.
    assert.is_nil(rpf.records.entries[rpf.records.key("account", TREASURY)].through)
  end)

  it("waits for the declaration, so the declaration can never release it", function()
    local connection = rpf.start_server(p, { url = "ws://portal", api_key = "rpf_test_secret" })
    p.open()
    p.deliver(support.portal_frame("welcome", { re = p.last().id, protocol = 1, server_id = SERVER }))
    assert.are.equal(0, #sent_of("hold"), "the declaration is owed first")
    assert.are.equal(1, #sent_of("declare_holds"))
    support.declared(p)
    assert.are.equal(1, #sent_of("hold"))
    assert.are.equal("ready", connection.state)
  end)

  it("does not ask again for one it holds or is asking for", function()
    support.connected(p)
    -- The same config again, and a change that leaves them alone: nothing new to hold.
    rpf.accounts.hold_paying()
    assert.are.equal(1, #sent_of("hold"), "already in flight")
    answer(sent_of("hold")[1])
    rpf.accounts.hold_paying()
    assert.are.equal(1, #sent_of("hold"), "already held")

    -- A reconnect declares it, and holds nothing new.
    p.drop()
    p.advance(2 * 60 * 1000)
    p.open()
    local hellos = {}
    for _, frame in ipairs(p.frames()) do
      if frame.type == "hello" then
        hellos[#hellos + 1] = frame
      end
    end
    p.deliver(support.portal_frame("welcome", { re = hellos[#hellos].id, protocol = 1, server_id = SERVER }))
    local declared = sent_of("declare_holds")
    assert.are.same({ kind = "account", id = TREASURY, revision = 2 }, declared[#declared].records[1])
    support.declared(p)
    assert.are.equal(1, #sent_of("hold"))
  end)

  -- Staff force-released this server's holds while it was away: the
  -- reconnect still holds the account here, so the Welcome asks for
  -- nothing, but the declaration's answer says it is gone, and it is asked
  -- for again once that answer has settled.
  it("holds one again that the declaration says was released", function()
    support.connected(p)
    answer(sent_of("hold")[1])
    p.drop()
    p.advance(2 * 60 * 1000)
    p.open()
    local hellos = sent_of("hello")
    p.deliver(support.portal_frame("welcome", { re = hellos[#hellos].id, protocol = 1, server_id = SERVER }))
    assert.are.equal(1, #sent_of("hold"), "still held here, so nothing asked for yet")
    local declared = sent_of("declare_holds")
    p.deliver(support.portal_frame("resync_required", {
      re = declared[#declared].id,
      stale = {},
      released = { { kind = "account", id = TREASURY } },
    }))
    local holds = sent_of("hold")
    assert.are.equal(2, #holds)
    assert.are.same({ { kind = "account", id = TREASURY } }, holds[2].records)
    answer(holds[2])
    assert.is_true(rpf.records.is_held("account", TREASURY))
  end)

  it("holds one a new config names, and only that one", function()
    support.connected(p)
    answer(sent_of("hold")[1])
    p.deliver(support.portal_frame("config", {
      version = 5,
      hash = "h5",
      snapshot = snapshot({ { id = SECOND, name = "rewards" }, { id = TREASURY, name = "treasury" } }),
    }))
    local holds = sent_of("hold")
    assert.are.equal(2, #holds)
    assert.are.same({ { kind = "account", id = SECOND } }, holds[2].records)
    answer(holds[2])
    assert.is_truthy(rpf.accounts.pay(SECOND, TREASURY, 5, "A reward"))
  end)

  it("holds nothing before the Welcome, and nothing for a config that names none", function()
    rpf.config.apply(p, 5, "h5", snapshot({}))
    support.connected(p)
    assert.are.equal(0, #sent_of("hold"))
  end)

  it("logs a refused hold, and asks again at the next config", function()
    support.connected(p)
    local hold = sent_of("hold")[1]
    p.deliver(support.portal_frame("rejected", { re = hold.id, code = "not_found", reason = "no such record" }))
    assert.are.equal(1, #p.logged("warn", "could not hold this server's paying accounts"))
    assert.is_false(rpf.records.is_held("account", TREASURY))

    p.deliver(support.portal_frame("config", {
      version = 5,
      hash = "h5",
      snapshot = snapshot({ { id = SECOND, name = "rewards" } }),
    }))
    assert.are.same({ { kind = "account", id = SECOND } }, sent_of("hold")[2].records)
  end)
end)
