---Money on this game server (D5): balances, transfers and payments on the
---accounts it holds.
---
---**A balance is a fold over the ledger**, on both sides. The portal never
---stores one, and neither does this module: an account's `balance` is the
---one the portal folded when it handed the account over (`held`), moved by
---each ledger entry this server has made since. That running balance is
---only a shortcut for the fold, so `accounts.fold` is the fold itself, and
---both it and the portal's `money::checked_balance` are held to the shared
---cases in `protocol/corpus/ledger/`, never to each other.
---
---**No function sets a balance.** Money moves only as a ledger entry,
---through `rpf.records.transfer`, which mints the entry's `client_id` from
---the platform's randomness (C7's idempotency key), moves both balances,
---and marks both accounts for the next report. An account this server does
---not hold is the portal's to write, so it is refused here as `not_held`.
---
---**Money is never a float, and never needs Lua 5.4's integers.** Every
---amount is a whole number from 1 to `protocol.MAX_AMOUNT` (2^53 − 1), the
---widest integer a double holds exactly, so LuaJIT and Lua 5.4 give the same
---answer. An amount above it never reaches here: `rpf.json` refuses one on
---decode rather than rounding it, and every function below refuses one
---passed in. A fold can pass 2^53 on the way to its answer, so it keeps its
---total in two exact parts (`BASE`), never as one double.
---@class rpf.accounts
---@field BASE number 2^32: the fold keeps its running total as `high * BASE + low`, with `low` in `[0, BASE)`, so neither part ever leaves the integers a double holds exactly.
---@field ERRORS string[] Every reason `fold` refuses a ledger, as the shared ledger cases name it.
local accounts = {}

local rpf = rpf
local records = rpf.records

accounts.BASE = 4294967296
accounts.ERRORS = { "invalid_amount", "out_of_range" }

---The largest `high` part a foldable balance may have: 2^21 − 1, so the
---largest balance is `(2^21 − 1) * 2^32 + (2^32 − 1)`, which is 2^53 − 1.
local HIGH = 2097151

---Whether an account may go below zero.
---@param account table The account's data.
---@return boolean unlimited True if it has the `unlimited_balance` flag.
local function unlimited(account)
  for _, flag in ipairs(account.flags or {}) do
    if flag == "unlimited_balance" then
      return true
    end
  end
  return false
end

---Whether an amount is one the ledger takes: a whole number from 1 to
---`protocol.MAX_AMOUNT`. NaN and the infinities are not.
---@param amount any The amount.
---@return boolean valid True if it is.
local function valid_amount(amount)
  return type(amount) == "number"
    and amount == math.floor(amount)
    and amount >= 1
    and amount <= rpf.protocol.MAX_AMOUNT
end

---An account's balance as this server has it: the portal's fold when it was
---handed over, moved by every entry made here since. Always equal to
---`fold` over the account's ledger.
---@param id string The account's uuid.
---@return number? balance The balance, a whole number within ±`protocol.MAX_AMOUNT`, or nil.
---@return string? err `"not_held"` when this server does not hold it.
function accounts.balance(id)
  local account = records.get("account", id)
  if not account then
    return nil, "not_held"
  end
  return account.balance
end

---A held account, as a copy: `id`, `owner`, `name`, `flags` and `balance`.
---@param id string The account's uuid.
---@return table? account A copy, or nil if this server does not hold it.
function accounts.get(id)
  return records.get("account", id)
end

---Every account this server holds for an owner, as copies, by name and
---then id, so a character's wallet and bank always list in the same order.
---Only held accounts: a character's are held once it is selected
---(`rpf.characters`).
---@param kind string The owner's kind: `"player"`, `"character"`, `"server"`, `"employer"`.
---@param id string The owner's uuid.
---@return table[] accounts Copies.
function accounts.owned_by(kind, id)
  local out = {}
  for _, ref in ipairs(records.held()) do
    if ref.kind == "account" then
      local account = records.get("account", ref.id)
      if account and account.owner and account.owner.kind == kind and account.owner.id == id then
        out[#out + 1] = account
      end
    end
  end
  table.sort(out, function(a, b)
    if a.name ~= b.name then
      return a.name < b.name
    end
    return a.id < b.id
  end)
  return out
end

---Moves money from one held account to another, as one ledger entry: a
---player paying another, a character moving cash into their bank.
---
---Refused if it would overdraw the paying account, unless that account has
---`unlimited_balance`, the one account type allowed below zero; and refused
---if either balance would leave ±`protocol.MAX_AMOUNT`. The entry's
---`client_id` is minted here and the change reported with the next flush.
---@param from string The paying account's uuid.
---@param to string The receiving account's uuid.
---@param amount number A whole number from 1 to `protocol.MAX_AMOUNT`.
---@param description string Why, for the statement and staff. At most `records.MAX_DESCRIPTION_BYTES`.
---@return string? client_id The ledger entry's id, or nil if refused.
---@return string? err `"not_held"`, `"invalid"`, `"insufficient_funds"` or `"out_of_range"`. Nothing changes on an error.
function accounts.transfer(from, to, amount, description)
  return records.transfer(from, to, amount, description)
end

---Pays money out of the server's own funds: a wage, a reward, a sale to
---the server. It is a transfer whose paying account has
---`unlimited_balance` (a treasury or payroll account the server holds), so
---it never fails for want of funds, and its source can never be a player's
---own account: a script that means "the server pays" cannot drain a
---character by passing the wrong id.
---
---The money still comes from an account, as one ledger entry, so the
---source's derived balance shows exactly how much the server has paid out.
---The server's starting funds (E5) are the portal's alone and never held,
---so they cannot be the source.
---@param from string The paying account's uuid: held here, with `unlimited_balance`.
---@param to string The receiving account's uuid.
---@param amount number A whole number from 1 to `protocol.MAX_AMOUNT`.
---@param description string Why, for the statement and staff.
---@return string? client_id The ledger entry's id, or nil if refused.
---@return string? err `"not_held"`, `"not_a_source"` for a paying account without `unlimited_balance`, `"invalid"` or `"out_of_range"`. Nothing changes on an error.
function accounts.pay(from, to, amount, description)
  local source = records.get("account", from)
  if not source then
    return nil, "not_held"
  end
  if not unlimited(source) then
    return nil, "not_a_source"
  end
  return records.transfer(from, to, amount, description)
end

---An account's balance, folded from a ledger: the money every entry brings
---in less the money every entry takes out. An entry with the account on
---both sides, or on neither, moves nothing.
---
---The Lua half of the shared ledger cases (`protocol/corpus/ledger/`), held
---to the same verdicts as the portal's `money::checked_balance`:
---
--- - `invalid_amount` if any entry's amount is not a whole number from 1 to
---   `protocol.MAX_AMOUNT`, whichever account it names. Direction is carried
---   by the two accounts, never by the sign.
--- - `out_of_range` if the balance is beyond ±`protocol.MAX_AMOUNT`, which
---   no game server can hold exactly. Only the final balance counts: a total
---   that passes the bound on the way and comes back is a balance, so the
---   order of the ledger never changes the answer.
---
---The running total is kept in two exact parts, so the answer is exact
---however far past 2^53 the total goes on the way; a plain sum of doubles
---would round there and give a different balance on the way back.
---@param account_id string The account.
---@param ledger table[] The entries, each with `from_account`, `to_account` and `amount`.
---@return number? balance The balance, or nil if refused.
---@return string? err `"invalid_amount"` or `"out_of_range"`.
function accounts.fold(account_id, ledger)
  local base = accounts.BASE
  local high, low = 0, 0
  for _, entry in ipairs(ledger) do
    local amount = entry.amount
    if not valid_amount(amount) then
      return nil, "invalid_amount"
    end
    local out, into = entry.from_account == account_id, entry.to_account == account_id
    if out ~= into then
      -- Both parts are exact: dividing by a power of two and flooring is.
      local amount_high = math.floor(amount / base)
      local amount_low = amount - amount_high * base
      if into then
        high, low = high + amount_high, low + amount_low
        if low >= base then
          high, low = high + 1, low - base
        end
      else
        high, low = high - amount_high, low - amount_low
        if low < 0 then
          high, low = high - 1, low + base
        end
      end
    end
  end
  if high > HIGH or high < -HIGH - 1 or (high == -HIGH - 1 and low == 0) then
    return nil, "out_of_range"
  end
  return high * base + low, nil
end

rpf.accounts = accounts
return accounts
