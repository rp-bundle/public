---The domain-neutral facade (J3, decided in #75): how an addon reads a
---player's character, money, items and job, and moves money and items,
---whoever owns them on this server.
---
---The calls are `docs/architecture/framework-integration.md`'s, so an addon
---written against them runs unchanged on a native server, where RPF owns
---every domain, and on a companion one, where a bridge to an existing
---framework does (K2). This module is the native provider: each call goes
---to RPF's own module. K2 adds the bridge, and the routing between the two
---by the server's domain authority (K1), behind these same calls; no addon
---changes.
---
---**Players, not ids.** Every call takes the engine's handle of a player who
---has logged in, and acts on the character they have in play: the facade's
---subject is who is playing, which is what a framework knows too. Accounts
---and items are named, never addressed by id: `money.accounts()` lists the
---names (a character's starting accounts here, a framework's own there).
---
---**Results.** A read returns its value, or nil and why (`not_logged_in`,
---`no_character`, `not_found`, `unavailable`). A command returns `true`, or
---nil, a status and a reason: `refused` (nothing changed: `insufficient_funds`,
---`no_space`, `unsupported`, …), `unavailable` (nothing changed; the
---provider could not be asked), or `unknown` (it may have happened; never
---retry it, and never grant what it paid for). Nothing throws.
---
---**Authority (K1).** A domain the server's framework owns is not RPF's to
---answer: its calls are `unavailable` and `supports` is false until K2's
---bridge provides them, and nothing reaches RPF's own module.
---
---**Retries.** Every command names an `op_id` from `rpf.ops.new()`, and runs
---at most once per id (`rpf.ops`): a repeated id gets the recorded result.
---
---**Money** moves between the character's account and the server's paying
---account `economy.addon_account` names, as one ledger entry: a debit pays
---into it, a credit out of it. Without that setting, or with one naming no
---paying account, debits and credits are `unsupported`. Amounts are whole
---numbers from 1 to `protocol.MAX_AMOUNT`; direction is the verb.
---
---**Items** are the character's held containers, in name order: `give`
---puts every unit in the first that takes them all, `take` takes from each
---in turn. A unit is a plain one: a stack carrying data (a bottle with a
---note) is a thing of its own, which the facade does not count, give or
---take, as `rpf.inventory.remove` never takes it for plain units.
---@class rpf.facade
---@field CALLS table<string, table<string, true>> The calls of each domain, for `supports`.
---@field ADDON_ACCOUNT string The setting naming the paying account addons' money moves through: `economy::ADDON_ACCOUNT`.
local facade = {}

local rpf = rpf

facade.ADDON_ACCOUNT = "economy.addon_account"
facade.CALLS = {
  characters = { current = true },
  money = { accounts = true, balance = true, debit = true, credit = true },
  inventory = { count = true, give = true, take = true },
  jobs = { current = true },
}

---The most units one give or take moves: a stack's count is a `u32`.
local MAX_UNITS = 4294967295

---Whether a ledger entry this server made is on disk: carried by a report
---queued in the persisted outbox, or acknowledged and gone. A flush is
---asked for first; whether it went is the entry's own `sent`, not the
---flush's answer, since an account with a backlog reports its oldest
---entries first. Until it is, a crash would lose the payment, so the
---journal records the result only then.
---@param payer string The paying account, which carries the entry.
---@param client_id string The entry.
---@return fun(): boolean durable The check.
local function entry_on_disk(payer, client_id)
  return function()
    rpf.sync.flush()
    local entry = rpf.records.entries[rpf.records.key("account", payer)]
    for _, tx in ipairs(entry and entry.transactions or {}) do
      if tx.client_id == client_id then
        return tx.sent == true
      end
    end
    return true
  end
end

---Whether the contents changes made to containers are on disk: each
---container's change carried by a queued report (nothing left marked, no
---whole report owed), or the container let go with its final state.
---@param ids string[] The containers changed.
---@return fun(): boolean durable The check.
local function contents_on_disk(ids)
  return function()
    rpf.sync.flush()
    for _, id in ipairs(ids) do
      local entry = rpf.records.entries[rpf.records.key("container", id)]
      if entry and (entry.changed.contents or entry.resync) then
        return false
      end
    end
    return true
  end
end

---The character a logged-in player has in play.
---@param handle any The engine's handle.
---@return table? character A copy.
---@return string? err `not_logged_in` or `no_character`.
local function character_of(handle)
  local player = rpf.players.get(handle)
  if not player or not player.player_id or player.state == "dropping" then
    return nil, "not_logged_in"
  end
  local character = rpf.characters.selected(player.player_id)
  if not character then
    return nil, "no_character"
  end
  return character
end

---A character's held account of a name.
---@param character table The character.
---@param name any The account's name.
---@return table? account A copy, or nil.
local function account_of(character, name)
  if type(name) ~= "string" then
    return nil
  end
  for _, account in ipairs(rpf.accounts.owned_by("character", character.id)) do
    if account.name == name then
      return account
    end
  end
  return nil
end

---The paying account addons' money moves through, if staff set one.
---@return table? account Its config entry, `{ id, name }`.
local function addon_account()
  local name = rpf.config.setting(facade.ADDON_ACCOUNT)
  if type(name) ~= "string" then
    return nil
  end
  return rpf.config.paying_account(name)
end

---Whether a domain has a provider on this server: RPF's own module while
---the domain is RPF's (K1). An external one is the framework's, reached
---through its bridge (K2); until that exists it has none, and its calls are
---`unavailable`, nothing changed, rather than ever reaching RPF's module,
---which would be a second writer of the framework's records.
---@param domain string The domain.
---@return boolean provided True if a call may go ahead.
local function provided(domain)
  return not rpf.domains.is_external(domain)
end

---Whether a call works on this server, before an addon offers a player
---anything that needs it.
---@param domain string `characters`, `money`, `inventory` or `jobs`.
---@param call any The call's name.
---@return boolean supported True if it works here.
function facade.supports(domain, call)
  local calls = facade.CALLS[domain]
  if not calls or not calls[call] or not provided(domain) then
    return false
  end
  if domain == "money" and (call == "debit" or call == "credit") then
    return addon_account() ~= nil
  end
  return true
end

-- Characters ---------------------------------------------------------------

---The character a player has in play.
---@param handle any The engine's handle.
---@return { key: string, name: string }? character `key` is the character's id here, opaque to an addon; `name` its full name.
---@return string? err `unavailable` where the server's framework owns the domain (K1), `not_logged_in` or `no_character`.
function facade.current_character(handle)
  if not provided("characters") then
    return nil, "unavailable"
  end
  local character, err = character_of(handle)
  if not character then
    return nil, err
  end
  return { key = character.id, name = character.first_name .. " " .. character.last_name }
end

-- Money --------------------------------------------------------------------

---The account names an addon may use: those every character is opened with.
---@return string[] names In the config's order.
function facade.accounts()
  if not provided("money") then
    return {}
  end
  local out = {}
  for _, account in ipairs(rpf.config.starting_accounts() or {}) do
    out[#out + 1] = account.name
  end
  return out
end

---A player's balance in one of their character's accounts.
---@param handle any The engine's handle.
---@param name any The account's name.
---@return number? balance The balance.
---@return string? err `unavailable` where the server's framework owns the domain (K1), `not_logged_in`, `no_character` or `not_found`.
function facade.balance(handle, name)
  if not provided("money") then
    return nil, "unavailable"
  end
  local character, err = character_of(handle)
  if not character then
    return nil, err
  end
  local account = account_of(character, name)
  if not account then
    return nil, "not_found"
  end
  return account.balance
end

---Whether an amount and reason are ones a ledger entry takes.
---@param amount any The amount.
---@param reason any The reason.
---@return boolean ok True if they are.
local function valid_entry(amount, reason)
  return type(amount) == "number"
    and amount == math.floor(amount)
    and amount >= 1
    and amount <= rpf.protocol.MAX_AMOUNT
    and type(reason) == "string"
    and #reason <= rpf.records.MAX_DESCRIPTION_BYTES
end

---Moves money between a player's account and the addon account, once per
---op id.
---@param direction "debit"|"credit" Which way.
---@param handle any The engine's handle.
---@param name any The character's account's name.
---@param amount any The amount.
---@param reason any Why, for the statement and staff.
---@param op_id any The operation's id.
---@return boolean? ok True once moved.
---@return string? status `refused`, `unavailable` or `unknown`.
---@return string? why For `refused`, why.
local function move_money(direction, handle, name, amount, reason, op_id)
  if not provided("money") then
    return nil, "unavailable"
  end
  if not valid_entry(amount, reason) then
    return nil, "refused", "invalid"
  end
  if not rpf.ops.minted_at(op_id) then
    return nil, "refused", "invalid_op"
  end
  local on_disk = nil
  ---Whether the payment is on disk; known once it is made.
  ---@return boolean durable True once it is.
  local function durable()
    return on_disk == nil or on_disk()
  end
  return rpf.ops.run(op_id, "money." .. direction, durable, function()
    local character, err = character_of(handle)
    if not character then
      return nil, "refused", err
    end
    local account = account_of(character, name)
    if not account then
      return nil, "refused", "no_account"
    end
    local server = addon_account()
    if not server then
      return nil, "refused", "unsupported"
    end
    local done, failure
    local payer = direction == "debit" and account.id or server.id
    if direction == "debit" then
      done, failure = rpf.records.transfer(account.id, server.id, amount, reason)
    else
      done, failure = rpf.accounts.pay(server.id, account.id, amount, reason)
    end
    if done then
      on_disk = entry_on_disk(payer, done)
      return true
    end
    if failure == "not_held" then
      -- The server's account is held after every `Welcome`; until its hold
      -- lands, nothing could be asked.
      return nil, "unavailable"
    end
    if failure == "not_a_source" then
      return nil, "refused", "unsupported"
    end
    return nil, "refused", failure
  end)
end

---Takes money from a player, into the addon account.
---@param handle any The engine's handle.
---@param name any The character's account's name.
---@param amount any A whole amount from 1.
---@param reason any Why, at most 256 bytes.
---@param op_id any From `rpf.ops.new()`.
---@return boolean? ok True once moved.
---@return string? status `refused`, `unavailable` or `unknown`.
---@return string? why For `refused`: `invalid`, `invalid_op`, `expired_op`, `journal_full`, `not_logged_in`, `no_character`, `no_account`, `unsupported`, `insufficient_funds`, `out_of_range`.
function facade.debit(handle, name, amount, reason, op_id)
  return move_money("debit", handle, name, amount, reason, op_id)
end

---Pays money to a player, out of the addon account.
---@param handle any The engine's handle.
---@param name any The character's account's name.
---@param amount any A whole amount from 1.
---@param reason any Why, at most 256 bytes.
---@param op_id any From `rpf.ops.new()`.
---@return boolean? ok True once moved.
---@return string? status `refused`, `unavailable` or `unknown`.
---@return string? why For `refused`, as for `debit`.
function facade.credit(handle, name, amount, reason, op_id)
  return move_money("credit", handle, name, amount, reason, op_id)
end

-- Items --------------------------------------------------------------------

---A character's held containers, by name then id.
---@param character table The character.
---@return table[] containers Copies.
local function containers_of(character)
  local out = {}
  for _, ref in ipairs(rpf.records.held()) do
    if ref.kind == "container" then
      local container = rpf.records.get("container", ref.id)
      if
        container
        and type(container.owner) == "table"
        and container.owner.kind == "character"
        and container.owner.id == character.id
      then
        out[#out + 1] = container
      end
    end
  end
  table.sort(out, function(a, b)
    if a.name ~= b.name then
      return tostring(a.name) < tostring(b.name)
    end
    return a.id < b.id
  end)
  return out
end

---How many plain units of an item a player's character holds, across its
---containers.
---@param handle any The engine's handle.
---@param item any The item's slug.
---@return number? count The count.
---@return string? err `unavailable` where the server's framework owns the domain (K1), `not_logged_in`, `no_character` or `not_found` (not an item slug).
function facade.count(handle, item)
  if not provided("inventory") then
    return nil, "unavailable"
  end
  local character, err = character_of(handle)
  if not character then
    return nil, err
  end
  if type(item) ~= "string" then
    return nil, "not_found"
  end
  local total = 0
  for _, container in ipairs(containers_of(character)) do
    total = total + (rpf.inventory.count(container.id, item, { plain = true }) or 0)
  end
  return total
end

---Moves plain units of an item into or out of a player's character's
---containers, once per op id.
---@param direction "give"|"take" Which way.
---@param handle any The engine's handle.
---@param item any The item's slug.
---@param count any How many.
---@param op_id any The operation's id.
---@return boolean? ok True once moved.
---@return string? status `refused`, `unavailable` or `unknown`.
---@return string? why For `refused`, why.
local function move_items(direction, handle, item, count, op_id)
  if not provided("inventory") then
    return nil, "unavailable"
  end
  if type(item) ~= "string" or type(count) ~= "number" or count ~= math.floor(count) or count < 1 or count > MAX_UNITS then
    return nil, "refused", "invalid"
  end
  if not rpf.ops.minted_at(op_id) then
    return nil, "refused", "invalid_op"
  end
  local changed = {}
  ---Whether the containers changed are on disk.
  ---@return boolean durable True once they are.
  local function durable()
    return contents_on_disk(changed)()
  end
  return rpf.ops.run(op_id, "inventory." .. direction, durable, function()
    local character, err = character_of(handle)
    if not character then
      return nil, "refused", err
    end
    local containers = containers_of(character)
    if #containers == 0 then
      return nil, "refused", "no_container"
    end
    if direction == "give" then
      for _, container in ipairs(containers) do
        if rpf.inventory.add(container.id, item, count) then
          changed[#changed + 1] = container.id
          return true
        end
      end
      return nil, "refused", "no_space"
    end
    local plain = {}
    local total = 0
    for i, container in ipairs(containers) do
      plain[i] = rpf.inventory.count(container.id, item, { plain = true }) or 0
      total = total + plain[i]
    end
    if total < count then
      return nil, "refused", "insufficient"
    end
    -- Every container's contents after are worked out and validated
    -- first, so a container whose contents no longer pass (the catalog
    -- changed under it) refuses the whole take before any unit goes.
    local left, after = count, {}
    for i, container in ipairs(containers) do
      local take = math.min(left, plain[i])
      if take > 0 then
        local contents = rpf.inventory.plan_remove(container.id, item, take)
        if not contents then
          return nil, "refused", "invalid_contents"
        end
        after[#after + 1] = { id = container.id, contents = contents }
        left = left - take
      end
    end
    for _, change in ipairs(after) do
      assert(rpf.records.set_contents(change.id, change.contents))
      changed[#changed + 1] = change.id
    end
    return true
  end)
end

---Gives a player's character plain units of an item.
---@param handle any The engine's handle.
---@param item any The item's slug.
---@param count any How many, a whole number from 1.
---@param op_id any From `rpf.ops.new()`.
---@return boolean? ok True once given.
---@return string? status `refused`, `unavailable` or `unknown`.
---@return string? why For `refused`: `invalid`, `invalid_op`, `expired_op`, `journal_full`, `not_logged_in`, `no_character`, `no_container`, `no_space`.
function facade.give(handle, item, count, op_id)
  return move_items("give", handle, item, count, op_id)
end

---Takes plain units of an item from a player's character.
---@param handle any The engine's handle.
---@param item any The item's slug.
---@param count any How many, a whole number from 1.
---@param op_id any From `rpf.ops.new()`.
---@return boolean? ok True once taken.
---@return string? status `refused`, `unavailable` or `unknown`.
---@return string? why For `refused`: as for `give`, `insufficient`, and `invalid_contents` for a container whose contents no longer pass its rules (the catalog changed under it).
function facade.take(handle, item, count, op_id)
  return move_items("take", handle, item, count, op_id)
end

-- Jobs ---------------------------------------------------------------------

---A player's character's job.
---@param handle any The engine's handle.
---@return { name: string, employer: string, grade: number, on_duty: boolean }? job `name` the job's slug, `employer` its employer's, `grade` its rank there; nil for no job (or one the config no longer has).
---@return string? err `unavailable` where the server's framework owns the domain (K1), `not_logged_in` or `no_character`.
function facade.current_job(handle)
  if not provided("jobs") then
    return nil, "unavailable"
  end
  local character, err = character_of(handle)
  if not character then
    return nil, err
  end
  local ref, def = rpf.jobs.job_of(character.id)
  if not ref or not def then
    return nil
  end
  return {
    name = ref.job,
    employer = ref.employer,
    grade = rpf.jobs.rank_of(character.id) or 0,
    on_duty = rpf.jobs.is_on_duty(character.id),
  }
end

rpf.facade = facade
return facade
