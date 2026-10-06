-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The Lua half of the shared ledger cases. These read the same cases under
-- protocol/corpus/ledger/ that crates/rpf-domain/tests/ledger.rs does, so
-- `rpf.accounts.fold` and the portal's `money::checked_balance` are each
-- held to the cases, never to each other. A case is an account, a ledger and
-- the verdict: a balance, or the error expected. The running balance a held
-- account keeps is held to the same cases by replaying each ledger as
-- transfers.

local lfs = require("lfs")
local support = require("spec.support")

local DIR = "protocol/corpus/ledger/cases"
local SERVER = "00000001-0000-4000-8000-000000000001"

---Every case, by name, as raw text: one the codec refuses is a verdict too.
---@return table<string, string> cases The cases.
local function cases()
  local out = {}
  for name in lfs.dir(support.path(DIR)) do
    local stem = name:match("^(.+)%.json$")
    if stem then
      out[stem] = support.read(DIR .. "/" .. name)
    end
  end
  return out
end

---The verdict a case expects, as `fold` returns it.
---@param name string The case.
---@param case table The decoded case.
---@return number? balance The balance.
---@return string? err The error.
local function expected(name, case)
  local balance, err = case.balance, case.error
  if balance == rpf.json.null then
    balance = nil
  end
  if err == rpf.json.null then
    err = nil
  end
  assert((balance == nil) ~= (err == nil), name .. ": a case names exactly one of balance and error")
  return balance, err
end

---A copy of a ledger in reverse.
---@param ledger table[] The entries.
---@return table[] reversed The entries, last first.
local function reversed(ledger)
  local out = {}
  for i = #ledger, 1, -1 do
    out[#out + 1] = ledger[i]
  end
  return out
end

describe("rpf.accounts.fold against protocol/corpus/ledger", function()
  before_each(function()
    support.load_core()
  end)

  it("gives every case its verdict, in either order", function()
    local count = 0
    for name, text in pairs(cases()) do
      count = count + 1
      local case, decode_err = rpf.json.decode(text)
      if not case then
        -- Refused before any fold: only an amount the codec will not round.
        assert.is_truthy(tostring(decode_err):find("beyond 2^53 - 1", 1, true), name .. ": " .. tostring(decode_err))
        assert.is_truthy(text:find('"error": "invalid_amount"', 1, true), name .. " expects another verdict")
      else
        local balance, err = expected(name, case)
        local got, got_err = rpf.accounts.fold(case.account, case.ledger)
        assert.are.equal(balance, got, name)
        assert.are.equal(err, got_err, name)
        local back, back_err = rpf.accounts.fold(case.account, reversed(case.ledger))
        assert.are.equal(balance, back, name .. " reversed")
        assert.are.equal(err, back_err, name .. " reversed")
      end
    end
    assert.is_true(count > 0, "no cases found")
  end)

  it("has a case for every refusal, and refuses only those", function()
    local covered = {}
    for name, text in pairs(cases()) do
      local case = rpf.json.decode(text)
      if case and case.error ~= rpf.json.null then
        covered[case.error] = true
      elseif not case then
        covered.invalid_amount = true
      end
      assert.is_not_nil(name)
    end
    local known = {}
    for _, err in ipairs(rpf.accounts.ERRORS) do
      known[err] = true
      assert.is_true(covered[err], err .. " has no case")
    end
    for err in pairs(covered) do
      assert.is_true(known[err], err .. " is not a refusal the fold makes")
    end
  end)

  it("returns whole numbers, never floats", function()
    for name, text in pairs(cases()) do
      local case = rpf.json.decode(text)
      if case then
        local got = rpf.accounts.fold(case.account, case.ledger)
        if got then
          assert.are.equal(math.floor(got), got, name)
        end
      end
    end
  end)
end)

describe("a held account's running balance against protocol/corpus/ledger", function()
  local p

  before_each(function()
    support.load_core()
    p = support.fake_platform()
    support.connected(p)
  end)

  ---Holds the case's account and every account its ledger names, each at
  ---zero and unlimited, so the replay is refused only for what the transfer
  ---itself refuses.
  ---@param case table The case.
  local function hold_accounts(case)
    local seen, held = {}, {}
    for _, entry in ipairs(case.ledger) do
      for _, id in ipairs({ case.account, entry.from_account, entry.to_account }) do
        if not seen[id] then
          seen[id] = true
          held[#held + 1] = {
            kind = "account",
            revision = 0,
            account = {
              id = id,
              server_id = SERVER,
              owner = { kind = "server", id = SERVER },
              name = id,
              flags = rpf.json.array({ "unlimited_balance" }),
            },
            balance = 0,
          }
        end
      end
    end
    rpf.records.take(held)
  end

  it("ends where the fold does, and refuses a step past what the fold refuses", function()
    local replayed = 0
    for name, text in pairs(cases()) do
      local case = rpf.json.decode(text)
      local self_transfer = false
      for _, entry in ipairs(case and case.ledger or {}) do
        self_transfer = self_transfer or entry.from_account == entry.to_account
      end
      -- A self-transfer is refused as a transfer: it is the shape a bug takes.
      if case and not self_transfer then
        rpf.records.reset()
        hold_accounts(case)
        local balance, err = expected(name, case)
        local refused
        for _, entry in ipairs(case.ledger) do
          local id, why = rpf.accounts.transfer(entry.from_account, entry.to_account, entry.amount, "replay")
          if not id then
            refused = why
            break
          end
        end
        if err == "invalid_amount" then
          -- Some step is refused: the bad amount, or a balance it never reaches.
          assert.is_not_nil(refused, name)
        elseif err == "out_of_range" then
          -- The running balance never leaves the range, so it refuses the
          -- step that would take it out.
          assert.are.equal("out_of_range", refused, name)
        elseif not refused then
          replayed = replayed + 1
          if #case.ledger > 0 then
            assert.are.equal(balance, rpf.accounts.balance(case.account), name)
            assert.are.equal(balance, rpf.accounts.fold(case.account, case.ledger), name)
          end
        end
      end
    end
    assert.is_true(replayed >= 8, "too few cases replayed whole: " .. replayed)
  end)
end)
