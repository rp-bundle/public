---Exchanges (J5, #82): money and items moved together, with an addon's own
---change to its records, as one journaled intent. The commerce tool a shop,
---a buy-back counter, a crafting bench or a licence office builds on, so
---none of them strings facade commands together and finds out half way that
---the second one is refused.
---
---A **deal** names what moves, from the player's side: what they `pay` from
---one of their accounts (or are `paid` into it), the items they hand over
---(`take`) and the items they receive (`give`), and the records the addon
---priced it against (`records`, each at the revision it read). `exchange`
---runs it once per op id, through `rpf.ops`, as the facade's commands run.
---
---**On a native server** every part is a record this server holds, so the
---deal is all or nothing. Everything is checked first, without changing
---anything: the player's character and account, the paying account, each
---item it gives in the current catalog, each named record still at its
---revision, the balance, and the items as one plan across the character's
---containers (`rpf.inventory.plan_moves`), so a take can make room for a
---give. Then, in the same synchronous step, the ledger entry, the contents,
---and the addon's `apply`. A refusal changes nothing. The intent completes
---only once the entry, the contents and what `apply` wrote are in the
---persisted outbox, so a crash before then reads `unknown` after the
---restart, never a payment that answers `true` with nothing given.
---
---**On a companion server** money and items are the framework's, reached
---through the bridge (K2), and nothing can make two framework calls
---atomic. So the deal follows conflict rule 4
---(`docs/architecture/framework-integration.md`), generalised to several
---calls: RPF's side (the named records) is checked first, then the
---framework's calls run in a fixed order (the money, each take, each give),
---and `apply` last. While nothing has happened, a refusal is a refusal and
---an outage `unavailable`, and nothing changed. Once a call went through,
---any later failure is `unknown` and surfaced to staff with what went and
---what did not: nothing compensates, since a refund is one more framework
---call that could fail the same way. Checking first (`check`) makes that
---rare.
---
---A deal moves only in-game money and items: nothing here connects to a
---payment (`AGENTS.md`, "Distribution").
---@class rpf.commerce
---@field MAX_LINES integer The most lines a deal's `take` or `give` has, and the most records it names.
---@field CALL string What the journal calls an exchange, for staff.
local commerce = {}

local rpf = rpf
local facade = rpf.facade

commerce.MAX_LINES = 16
commerce.CALL = "commerce.exchange"

---A deal, checked: what `exchange` and `check` work from.
---@class rpf.commerce.Deal
---@field account string? The player's account's name, when money moves.
---@field pay number? What the player pays, into the addon account.
---@field paid number? What the player is paid, out of the addon account.
---@field take rpf.inventory.Line[] What the player hands over.
---@field give rpf.inventory.Line[] What the player receives.
---@field reason string Why, for the statement, the journal and staff.
---@field records { type: string, id: string, revision: number }[] The records the deal was priced against.

---The keys a deal may have: anything else is a typo, refused rather than
---ignored, so a misspelt `give` cannot sell for nothing.
local DEAL_KEYS = { account = true, pay = true, paid = true, take = true, give = true, reason = true, records = true }

---Whether a value is a whole number within a range.
---@param n any The value.
---@param low number The least.
---@param high number The most.
---@return boolean ok True if it is.
local function whole(n, low, high)
  return type(n) == "number" and n == math.floor(n) and n >= low and n <= high
end

---The entries of a plain array of at most `max` tables, each with only the
---keys `keys` allows; nil is an empty one.
---@param value any The value.
---@param keys table<string, true> The keys an entry may have.
---@return table[]? entries The entries, or nil if it is not one.
local function entries_of(value, keys)
  if value == nil then
    return {}
  end
  if type(value) ~= "table" then
    return nil
  end
  local n = 0
  for key, entry in pairs(value) do
    if type(key) ~= "number" or type(entry) ~= "table" then
      return nil
    end
    for field in pairs(entry) do
      if not keys[field] then
        return nil
      end
    end
    n = n + 1
  end
  if n > commerce.MAX_LINES then
    return nil
  end
  local out = {}
  for i = 1, n do
    if value[i] == nil then
      return nil
    end
    out[i] = value[i]
  end
  return out
end

---A deal's item lines, copied: each an item's slug and a count.
---@param value any The lines.
---@return rpf.inventory.Line[]? lines The copy, or nil if they are not lines.
local function lines_of(value)
  local entries = entries_of(value, { item = true, count = true })
  if not entries then
    return nil
  end
  local out = {}
  for i, entry in ipairs(entries) do
    if type(entry.item) ~= "string" or entry.item == "" or not whole(entry.count, 1, facade.MAX_UNITS) then
      return nil
    end
    out[i] = { item = entry.item, count = entry.count }
  end
  return out
end

---A deal's records, copied: each a type, an id and the revision the addon read.
---@param value any The records.
---@return { type: string, id: string, revision: number }[]? records The copy, or nil if they are not records.
local function records_of(value)
  local entries = entries_of(value, { type = true, id = true, revision = true })
  if not entries then
    return nil
  end
  local out = {}
  for i, entry in ipairs(entries) do
    if type(entry.type) ~= "string" or type(entry.id) ~= "string" or not whole(entry.revision, 0, math.huge) then
      return nil
    end
    out[i] = { type = entry.type, id = entry.id, revision = entry.revision }
  end
  return out
end

---Checks a deal's shape, and copies it.
---@param deal any The deal an addon passed.
---@return rpf.commerce.Deal? deal The copy, or nil if it is not one.
local function read_deal(deal)
  if type(deal) ~= "table" then
    return nil
  end
  for key in pairs(deal) do
    if not DEAL_KEYS[key] then
      return nil
    end
  end
  local take, give, records = lines_of(deal.take), lines_of(deal.give), records_of(deal.records)
  if not take or not give or not records then
    return nil
  end
  local reason = deal.reason
  if type(reason) ~= "string" or reason == "" then
    return nil
  end
  if deal.pay ~= nil and deal.paid ~= nil then
    return nil
  end
  local amount = deal.pay or deal.paid
  if amount ~= nil and (not facade.valid_entry(amount, reason) or type(deal.account) ~= "string") then
    return nil
  end
  if amount == nil and #take == 0 and #give == 0 then
    return nil
  end
  if #reason > rpf.records.MAX_DESCRIPTION_BYTES then
    return nil
  end
  return {
    account = amount ~= nil and deal.account or nil,
    pay = deal.pay,
    paid = deal.paid,
    take = take,
    give = give,
    reason = reason,
    records = records,
  }
end

---Item lines as one line of text for the journal and the log:
---`water:2,bread:1`.
---@param lines rpf.inventory.Line[] The lines.
---@return string? text The text, or nil for none.
local function lines_text(lines)
  if #lines == 0 then
    return nil
  end
  local parts = {}
  for i, line in ipairs(lines) do
    parts[i] = line.item .. ":" .. string.format("%d", line.count)
  end
  return table.concat(parts, ",")
end

---Whether the deal's money and items are the framework's, through the
---bridge. A profile is native or companion whole (`rpf.domains`), so a deal
---is wholly one or the other.
---@param deal rpf.commerce.Deal The deal.
---@return boolean external True on a companion server.
local function external(deal)
  if deal.pay or deal.paid then
    return rpf.domains.is_external("money")
  end
  return rpf.domains.is_external("inventory")
end

---Checks the records a deal was priced against: each must be one the
---addon can read here (a config record, or a live one this server holds),
---still at the revision it read.
---@param deal rpf.commerce.Deal The deal.
---@return boolean? ok True if every one is as read.
---@return string? why `not_found`, `not_held`, `inactive` or `stale`.
local function check_records(deal)
  for _, named in ipairs(deal.records) do
    local record, err = rpf.data.get(named.type, named.id)
    if not record then
      return nil, err or "not_found"
    end
    if record.revision ~= named.revision then
      return nil, "stale"
    end
  end
  return true
end

---What a native deal will do, once checked: the accounts and the contents.
---@class rpf.commerce.Plan
---@field payer string? The account the money leaves.
---@field payee string? The account it goes to.
---@field credit boolean Whether the server pays the player (`accounts.pay`), not the player the server.
---@field changes { id: string, contents: table }[] Each container's contents after.

---Checks a native deal whole, changing nothing.
---@param handle any The engine's handle.
---@param deal rpf.commerce.Deal The deal.
---@return rpf.commerce.Plan? plan What to do, if it can be done.
---@return string? status `refused` or `unavailable`.
---@return string? why For `refused`, why.
local function plan_native(handle, deal)
  local character, err = facade.character_of(handle)
  if not character then
    return nil, "refused", err
  end
  local ok, why = check_records(deal)
  if not ok then
    return nil, "refused", why
  end
  for _, line in ipairs(deal.give) do
    if not rpf.config.item(line.item) then
      return nil, "refused", "unknown_item"
    end
  end
  local containers = {}
  if #deal.take + #deal.give > 0 then
    for _, container in ipairs(facade.containers_of(character)) do
      containers[#containers + 1] = container.id
    end
  end
  local changes, failure = rpf.inventory.plan_moves(containers, deal.take, deal.give)
  if not changes then
    return nil, "refused", failure
  end
  ---@type rpf.commerce.Plan
  local plan = { credit = deal.paid ~= nil, changes = changes }
  local amount = deal.pay or deal.paid
  if amount then
    local account = facade.account_of(character, deal.account)
    if not account then
      return nil, "refused", "no_account"
    end
    local server = facade.addon_account()
    if not server then
      return nil, "refused", "unsupported"
    end
    local can, refusal
    if plan.credit then
      plan.payer, plan.payee = server.id, account.id
      can, refusal = rpf.accounts.check_pay(plan.payer, plan.payee, amount, deal.reason)
    else
      plan.payer, plan.payee = account.id, server.id
      can, refusal = rpf.records.check_transfer(plan.payer, plan.payee, amount, deal.reason)
    end
    if not can then
      if refusal == "not_held" then
        -- The server's account is held after every `Welcome`; until its
        -- hold lands, nothing could be asked.
        return nil, "unavailable"
      end
      return nil, "refused", refusal == "not_a_source" and "unsupported" or refusal
    end
  end
  return plan
end

---The framework calls a companion deal makes, in the order it makes them:
---the money, then each take, then each give.
---@param deal rpf.commerce.Deal The deal.
---@return { domain: string, call: string, args: any[] }[] steps The calls, with their arguments after the player.
local function steps_of(deal)
  local steps = {}
  if deal.pay or deal.paid then
    steps[#steps + 1] = {
      domain = "money",
      call = deal.pay and "debit" or "credit",
      args = { deal.account, deal.pay or deal.paid, deal.reason },
    }
  end
  for _, line in ipairs(deal.take) do
    steps[#steps + 1] = { domain = "inventory", call = "take", args = { line.item, line.count } }
  end
  for _, line in ipairs(deal.give) do
    steps[#steps + 1] = { domain = "inventory", call = "give", args = { line.item, line.count } }
  end
  return steps
end

---Whether every framework call a companion deal makes may be asked now.
---@param steps { domain: string, call: string }[] The calls.
---@return table<string, function>? fns Each call's function, by `domain.call`.
---@return string? status `refused` (a call the bridge does not support) or `unavailable`.
---@return string? why For `refused`, `unsupported`.
local function reach(steps)
  local fns = {}
  for _, step in ipairs(steps) do
    local name = step.domain .. "." .. step.call
    if not fns[name] then
      local fn, status = rpf.bridge.reach(step.domain, step.call)
      if not fn then
        if status == "unsupported" then
          return nil, "refused", "unsupported"
        end
        return nil, "unavailable"
      end
      fns[name] = fn
    end
  end
  return fns
end

---What `check` answers when a read it asked the bridge for failed: never
---that the deal can be made, since the read was what would have said so.
---@param err string? The read's reason.
---@param not_found string What a `not_found` means for this read: `no_account` for a balance, `insufficient` for a count.
---@return nil
---@return string status `unavailable` for an outage, else `refused`.
---@return string? why For `refused`, why.
local function read_failed(err, not_found)
  if err == "unavailable" then
    return nil, "unavailable"
  end
  if err == "not_found" or err == nil then
    return nil, "refused", not_found
  end
  return nil, "refused", err
end

---What a companion deal can be checked for before it runs: the player's
---character, the named records, and, through the bridge's reads where it
---supports them, the balance and the counts. Whether a give fits is the
---framework's to say when it runs.
---@param handle any The engine's handle.
---@param deal rpf.commerce.Deal The deal.
---@return boolean? ok True if nothing it can see refuses it.
---@return string? status `refused` or `unavailable`.
---@return string? why For `refused`, why.
local function precheck_external(handle, deal)
  local character, err = rpf.bridge.character(handle)
  if not character then
    if err == "unavailable" then
      return nil, "unavailable"
    end
    return nil, "refused", err
  end
  local ok, why = check_records(deal)
  if not ok then
    return nil, "refused", why
  end
  if deal.pay and rpf.bridge.supports("money", "balance") then
    local balance, failed = facade.balance(handle, deal.account)
    if balance == nil then
      return read_failed(failed, "no_account")
    end
    if balance < deal.pay then
      return nil, "refused", "insufficient_funds"
    end
  end
  if #deal.take > 0 and rpf.bridge.supports("inventory", "count") then
    local wanted, order = {}, {}
    for _, line in ipairs(deal.take) do
      if not wanted[line.item] then
        order[#order + 1] = line.item
      end
      wanted[line.item] = (wanted[line.item] or 0) + line.count
    end
    for _, item in ipairs(order) do
      local held, failed = facade.count(handle, item)
      if held == nil then
        return read_failed(failed, "insufficient")
      end
      if held < wanted[item] then
        return nil, "refused", "insufficient"
      end
    end
  end
  return true
end

---Whether a deal can be made now, without making it: the same checks
---`exchange` makes before it changes anything, so an addon can show a
---player what they can afford and carry. On a companion server it asks the
---framework what it can (the balance, the counts); whether a give fits is
---only known when it runs.
---@param handle any The engine's handle.
---@param deal any The deal.
---@return boolean? ok True if it can.
---@return string? status `refused` or `unavailable`.
---@return string? why For `refused`: `invalid`, `not_logged_in`, `no_character`, `not_found`, `not_held`, `inactive`, `stale`, `unknown_item`, `no_container`, `insufficient`, `no_space`, `invalid_contents`, `no_account`, `unsupported`, `insufficient_funds`, `out_of_range`.
function commerce.check(handle, deal)
  local checked = read_deal(deal)
  if not checked then
    return nil, "refused", "invalid"
  end
  if external(checked) then
    local fns, status, why = reach(steps_of(checked))
    if not fns then
      return nil, status, why
    end
    return precheck_external(handle, checked)
  end
  local plan, status, why = plan_native(handle, checked)
  if not plan then
    return nil, status, why
  end
  return true
end

---Runs a native deal: checked whole, then made in one synchronous step.
---@param handle any The engine's handle.
---@param deal rpf.commerce.Deal The deal.
---@param op_id string The op id, checked already.
---@param apply any The addon's change, checked already, or nil.
---@param detail rpf.ops.Detail What it is, for staff.
---@return boolean? ok True once done.
---@return string? status `refused`, `unavailable` or `unknown`.
---@return string? why For `refused`, why.
local function exchange_native(handle, deal, op_id, apply, detail)
  local on_disk = nil
  local changed = {}
  local written = {}
  ---Whether the entry, the contents and what `apply` wrote are on disk.
  ---@return boolean durable True once they are.
  local function durable()
    return (on_disk == nil or on_disk())
      and facade.contents_on_disk(changed)()
      and facade.applied_on_disk(written)
  end
  return rpf.ops.run(op_id, commerce.CALL, durable, function()
    local plan, status, why = plan_native(handle, deal)
    if not plan then
      return nil, status, why
    end
    local amount = deal.pay or deal.paid
    if amount then
      local entry, failure
      if plan.credit then
        entry, failure = rpf.accounts.pay(plan.payer, plan.payee, amount, deal.reason)
      else
        entry, failure = rpf.records.transfer(plan.payer, plan.payee, amount, deal.reason)
      end
      if not entry then
        -- Checked in this same step, so only a bug gets here; nothing has
        -- changed yet.
        return nil, "refused", failure
      end
      on_disk = facade.entry_on_disk(plan.payer, entry)
    end
    for _, change in ipairs(plan.changes) do
      local done, failure = rpf.records.set_contents(change.id, change.contents)
      if not done then
        return nil, "unknown", "its money moved, and then a container refused its contents (" .. tostring(failure) .. ")"
      end
      changed[#changed + 1] = change.id
    end
    return facade.then_apply(apply, written)
  end, detail)
end

---Runs a companion deal: the framework's calls in order, then `apply`.
---@param handle any The engine's handle.
---@param deal rpf.commerce.Deal The deal.
---@param op_id string The op id, checked already.
---@param apply any The addon's change, checked already, or nil.
---@param detail rpf.ops.Detail What it is, for staff.
---@return boolean? ok True once done.
---@return string? status `refused`, `unavailable` or `unknown`.
---@return string? why For `refused`, why.
local function exchange_external(handle, deal, op_id, apply, detail)
  -- A deal already in the journal answers as it did, outage or not.
  local known, done, recorded, why = rpf.ops.known(op_id)
  if known then
    return done, recorded, why
  end
  local steps = steps_of(deal)
  local fns, status, reason = reach(steps)
  if not fns then
    return nil, status, reason
  end
  local written = {}
  ---Whether what `apply` wrote is on disk: the framework's own changes
  ---are the framework's to keep.
  ---@return boolean durable True once it is.
  local function durable()
    return facade.applied_on_disk(written)
  end
  return rpf.ops.run(op_id, commerce.CALL, durable, function()
    local character, err = rpf.bridge.character(handle)
    if not character then
      return nil, "refused", err
    end
    local ok, stale = check_records(deal)
    if not ok then
      return nil, "refused", stale
    end
    local went = {}
    for _, step in ipairs(steps) do
      local name = step.domain .. "." .. step.call
      local args = step.args
      local answered, failure, refusal
      if step.domain == "money" then
        answered, failure, refusal = rpf.bridge.command(
          fns[name],
          name,
          handle,
          args[1],
          args[2],
          args[3],
          rpf.ops.new()
        )
      else
        answered, failure, refusal =
          rpf.bridge.command(fns[name], name, handle, args[1], args[2], rpf.ops.new())
      end
      if not answered then
        if #went == 0 then
          return nil, failure, refusal
        end
        return nil,
          "unknown",
          table.concat(went, ", ")
            .. " went through, and then "
            .. name
            .. " answered "
            .. tostring(failure)
            .. (failure == "refused" and (" (" .. tostring(refusal) .. ")") or "")
      end
      went[#went + 1] = name .. (step.domain == "inventory" and (" " .. args[1] .. ":" .. string.format("%d", args[2])) or "")
    end
    return facade.then_apply(apply, written)
  end, detail)
end

---Makes a deal: money and items moved together, with the addon's own
---change, once per op id. See the module's comment for what is atomic where.
---@param handle any The engine's handle.
---@param deal any The deal: `{ account, pay | paid, take, give, reason, records }`.
---@param op_id any From `rpf.ops.new()`, minted once per thing the player does.
---@param apply any? The addon's change the deal pays for, run once everything moved, in the same intent.
---@return boolean? ok True once made (and applied).
---@return string? status `refused`, `unavailable` or `unknown`.
---@return string? why For `refused`: as for `check`, and `invalid_op`, `expired_op`, `journal_full`.
function commerce.exchange(handle, deal, op_id, apply)
  local checked = read_deal(deal)
  if not checked or (apply ~= nil and not rpf.callable(apply)) then
    return nil, "refused", "invalid"
  end
  if not rpf.ops.minted_at(op_id) then
    return nil, "refused", "invalid_op"
  end
  ---@cast op_id string
  local detail = facade.detail_of(handle, {
    account = checked.account,
    amount = checked.pay,
    paid = checked.paid,
    take = lines_text(checked.take),
    give = lines_text(checked.give),
    reason = checked.reason,
  })
  if external(checked) then
    return exchange_external(handle, checked, op_id, apply, detail)
  end
  return exchange_native(handle, checked, op_id, apply, detail)
end

rpf.commerce = commerce
return commerce
