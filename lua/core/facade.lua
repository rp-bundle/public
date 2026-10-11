---The domain-neutral facade (J3, decided in #75): how an addon reads a
---player's character, money, items and job, and moves money and items,
---whoever owns them on this server.
---
---The calls are `docs/architecture/framework-integration.md`'s, so an addon
---written against them runs unchanged on a native server, where RPF owns
---every domain, and on a companion one, where a bridge to an existing
---framework does (K2). This module is the native provider: each call goes
---to RPF's own module, or, for a domain the server's framework owns, to
---the bridge to that framework (`rpf.bridge`, K2): the server's domain
---authority (K1) picks which, behind these same calls, so no addon changes.
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
---**Authority (K1, K2).** A domain the server's framework owns is not RPF's
---to answer, and nothing of it ever reaches RPF's own module, which would
---be a second writer of the framework's records. Its calls go to the active
---bridge: a call the bridge does not support is `unsupported` without
---reaching it, and while no bridge is active, or its framework is
---unavailable, every call is `unavailable` without reaching it, and nothing
---is journaled, so the same op id may be sent again later.
---
---**Retries.** Every command names an `op_id` from `rpf.ops.new()`, and runs
---at most once per id (`rpf.ops`): a repeated id gets the recorded result.
---
---**Composite operations** (`docs/architecture/framework-integration.md`,
---"Conflict rules"). A command may name an `apply` after its op id: the
---addon's change to its own records that the command pays for. It runs
---inside the same journaled intent, only once the command went through,
---and the intent completes only once what `apply` wrote is on disk (its
---report queued in the persisted outbox), so a crash between the payment
---and the grant reads `unknown` after the restart rather than a payment
---that answers `true` with nothing granted. An `apply` that throws or
---answers nil is `unknown` too. Nothing compensates: staff resolve it.
---So `apply` must not be able to fail: the addon holds its records and
---checks everything before it sends the command.
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
---@field MAX_UNITS integer The most units one give or take moves: a stack's count is a `u32`.
---@field character_of fun(handle: any): table?, string? The character a logged-in player has in play, or nil and `not_logged_in` or `no_character`. Shared with `rpf.commerce`, as are the fields below.
---@field account_of fun(character: table, name: any): table? A character's held account of a name.
---@field addon_account fun(): table? The paying account addons' money moves through, if staff set one.
---@field containers_of fun(character: table): table[] A character's held containers, by name then id.
---@field valid_entry fun(amount: any, reason: any): boolean Whether an amount and reason are ones a ledger entry takes.
---@field detail_of fun(handle: any, fields: table): rpf.ops.Detail What the journal keeps of a command, for staff.
---@field entry_on_disk fun(payer: string, client_id: string): fun(): boolean Whether a ledger entry this server made is on disk.
---@field contents_on_disk fun(ids: string[]): fun(): boolean Whether the contents changes made to containers are on disk.
---@field then_apply fun(apply: any, written: string[]): boolean?, string?, string? Runs an addon's `apply` once its command went through, noting what it wrote.
---@field applied_on_disk fun(written: string[]): boolean Whether the records an `apply` wrote are on disk.
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
facade.MAX_UNITS = MAX_UNITS

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

---Runs an addon's `apply` once its command went through, noting the
---records it wrote so the journal can wait for them.
---@param apply any The addon's function, or nil for none.
---@param written string[] Where the records it wrote are added.
---@return boolean? ok True if it ran and answered something other than nil or false.
---@return string? status `unknown` if not: the command happened, the grant may not have.
---@return string? cause For staff.
local function then_apply(apply, written)
  if apply == nil then
    return true
  end
  local keys, ran, result, err = rpf.records.watch(apply)
  for _, key in ipairs(keys) do
    written[#written + 1] = key
  end
  if not ran then
    return nil, "unknown", "it went through, and then its apply threw: " .. tostring(result)
  end
  if not result then
    return nil, "unknown", "it went through, and then its apply answered " .. tostring(err)
  end
  return true
end

---Whether the records an `apply` wrote are on disk.
---@param written string[] The records, as `rpf.records.key` names them.
---@return boolean durable True once each is.
local function applied_on_disk(written)
  if #written == 0 then
    return true
  end
  rpf.sync.flush()
  for _, key in ipairs(written) do
    if not rpf.sync.reported(key) then
      return false
    end
  end
  return true
end

---What the journal keeps of a command, for staff: the player's account and
---the command's arguments.
---@param handle any The engine's handle.
---@param fields table The arguments, by `rpf.ops.Detail` name.
---@return rpf.ops.Detail detail The detail.
local function detail_of(handle, fields)
  local player = rpf.players.get(handle)
  fields.player = player and player.player_id or nil
  return fields
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

---Whether a domain is the server's framework's (K1), so its calls go to
---the bridge (`rpf.bridge`) and never to RPF's own module.
---@param domain string The domain.
---@return boolean external True if they do.
local function external(domain)
  return rpf.domains.is_external(domain)
end

---Reads through the bridge: the call must be supported and reachable, and
---the player logged in with a character the bridge reported loaded. Every
---read is about a player, whatever handle the caller passed, nil included;
---`money.accounts`, the one that is not, asks the bridge itself.
---@param domain string The domain.
---@param call string The call.
---@param valid fun(value: any): any The check of what the bridge answers.
---@param handle any The engine's handle.
---@param ... any The call's arguments after the player.
---@return any value The value.
---@return string? err `unsupported`, `unavailable`, `not_logged_in`, `no_character`, `not_found`.
local function bridge_read(domain, call, valid, handle, ...)
  local fn, status = rpf.bridge.reach(domain, call)
  if not fn then
    return nil, status
  end
  local character, err = rpf.bridge.character(handle)
  if not character then
    return nil, err
  end
  return rpf.bridge.read(fn, domain .. "." .. call, valid, handle, ...)
end

---Sends a command through the bridge, once per op id. Whether it may be
---asked at all is settled before the journal, since nothing changes when
---it may not: an `unsupported` call, or no bridge or framework to ask. The
---player is checked inside, as on the native path.
---@param domain string The domain.
---@param call string The call.
---@param handle any The engine's handle.
---@param op_id string The op id, checked already.
---@param apply any The addon's change, checked already, or nil.
---@param detail rpf.ops.Detail What it is, for staff.
---@param ask fun(fn: function): boolean?, string?, string? Calls the bridge's function with the command's arguments.
---@return boolean? ok True once done.
---@return string? status `refused`, `unavailable` or `unknown`.
---@return string? why For `refused`, why.
local function bridge_command(domain, call, handle, op_id, apply, detail, ask)
  -- A command already in the journal answers as it did, outage or not: an
  -- `unavailable` now would say nothing happened when something may have.
  local known, done, recorded, why = rpf.ops.known(op_id)
  if known then
    return done, recorded, why
  end
  local fn, status = rpf.bridge.reach(domain, call)
  if not fn then
    if status == "unsupported" then
      return nil, "refused", "unsupported"
    end
    return nil, "unavailable"
  end
  local written = {}
  ---Whether what `apply` wrote is on disk: the framework's own change is
  ---the framework's to keep.
  ---@return boolean durable True once it is.
  local function durable()
    return applied_on_disk(written)
  end
  return rpf.ops.run(op_id, domain .. "." .. call, durable, function()
    local character, err = rpf.bridge.character(handle)
    if not character then
      return nil, "refused", err
    end
    local done, failure, why = ask(fn)
    if not done then
      return nil, failure, why
    end
    return then_apply(apply, written)
  end, detail)
end

---Whether a call works on this server, before an addon offers a player
---anything that needs it.
---@param domain string `characters`, `money`, `inventory` or `jobs`.
---@param call any The call's name.
---@return boolean supported True if it works here.
function facade.supports(domain, call)
  local calls = facade.CALLS[domain]
  if not calls or not calls[call] then
    return false
  end
  if external(domain) then
    return rpf.bridge.supports(domain, call)
  end
  if domain == "money" and (call == "debit" or call == "credit") then
    return addon_account() ~= nil
  end
  return true
end

-- Characters ---------------------------------------------------------------

---The character a player has in play.
---@param handle any The engine's handle.
---@return { key: string, name: string }? character `key` is the character's id here, the framework's own key through a bridge, opaque to an addon either way; `name` its full name.
---@return string? err `unavailable` where the server's framework owns the domain and no bridge is active, `not_logged_in` or `no_character`.
function facade.current_character(handle)
  if external("characters") then
    return rpf.bridge.character(handle)
  end
  local character, err = character_of(handle)
  if not character then
    return nil, err
  end
  return { key = character.id, name = character.first_name .. " " .. character.last_name }
end

-- Money --------------------------------------------------------------------

---The account names an addon may use: those every character is opened
---with, or those the bridge lists.
---@return string[] names In the config's order, or the bridge's; empty where none can be had.
function facade.accounts()
  if external("money") then
    local fn = rpf.bridge.reach("money", "accounts")
    return fn and rpf.bridge.read(fn, "money.accounts", rpf.bridge.accounts_of) or {}
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
---@return string? err `unavailable`, `unsupported` (a bridge that does not read balances), `not_logged_in`, `no_character` or `not_found`.
function facade.balance(handle, name)
  if external("money") then
    if type(name) ~= "string" then
      return nil, "not_found"
    end
    return bridge_read("money", "balance", rpf.bridge.balance_of, handle, name)
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
---@param apply any The addon's change this pays for, or nil.
---@return boolean? ok True once moved.
---@return string? status `refused`, `unavailable` or `unknown`.
---@return string? why For `refused`, why.
local function move_money(direction, handle, name, amount, reason, op_id, apply)
  if not valid_entry(amount, reason) or (apply ~= nil and not rpf.callable(apply)) then
    return nil, "refused", "invalid"
  end
  if not rpf.ops.minted_at(op_id) then
    return nil, "refused", "invalid_op"
  end
  if external("money") then
    if type(name) ~= "string" then
      return nil, "refused", "no_account"
    end
    local detail = detail_of(handle, { account = name, amount = amount, reason = reason })
    return bridge_command("money", direction, handle, op_id, apply, detail, function(fn)
      return rpf.bridge.command(fn, "money." .. direction, handle, name, amount, reason, op_id)
    end)
  end
  local on_disk = nil
  local written = {}
  ---Whether the payment, and what `apply` wrote, are on disk; known once
  ---they are made.
  ---@return boolean durable True once they are.
  local function durable()
    return (on_disk == nil or on_disk()) and applied_on_disk(written)
  end
  local detail = detail_of(handle, { account = name, amount = amount, reason = reason })
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
      return then_apply(apply, written)
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
  end, detail)
end

---Takes money from a player, into the addon account.
---@param handle any The engine's handle.
---@param name any The character's account's name.
---@param amount any A whole amount from 1.
---@param reason any Why, at most 256 bytes.
---@param op_id any From `rpf.ops.new()`.
---@param apply any? The addon's change this pays for, run once the money moved (a composite operation).
---@return boolean? ok True once moved.
---@return string? status `refused`, `unavailable` or `unknown`.
---@return string? why For `refused`: `invalid`, `invalid_op`, `expired_op`, `journal_full`, `not_logged_in`, `no_character`, `no_account`, `unsupported`, `insufficient_funds`, `out_of_range`.
function facade.debit(handle, name, amount, reason, op_id, apply)
  return move_money("debit", handle, name, amount, reason, op_id, apply)
end

---Pays money to a player, out of the addon account.
---@param handle any The engine's handle.
---@param name any The character's account's name.
---@param amount any A whole amount from 1.
---@param reason any Why, at most 256 bytes.
---@param op_id any From `rpf.ops.new()`.
---@param apply any? The addon's change this goes with, run once the money moved.
---@return boolean? ok True once moved.
---@return string? status `refused`, `unavailable` or `unknown`.
---@return string? why For `refused`, as for `debit`.
function facade.credit(handle, name, amount, reason, op_id, apply)
  return move_money("credit", handle, name, amount, reason, op_id, apply)
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
---@return string? err `unavailable`, `unsupported` (a bridge that does not count items), `not_logged_in`, `no_character` or `not_found` (an item that is not a string; an item nobody holds counts 0).
function facade.count(handle, item)
  if external("inventory") then
    if type(item) ~= "string" then
      return nil, "not_found"
    end
    return bridge_read("inventory", "count", rpf.bridge.count_of, handle, item)
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
---@param apply any The addon's change this goes with, or nil.
---@return boolean? ok True once moved.
---@return string? status `refused`, `unavailable` or `unknown`.
---@return string? why For `refused`, why.
local function move_items(direction, handle, item, count, op_id, apply)
  if
    type(item) ~= "string"
    or type(count) ~= "number"
    or count ~= math.floor(count)
    or count < 1
    or count > MAX_UNITS
    or (apply ~= nil and not rpf.callable(apply))
  then
    return nil, "refused", "invalid"
  end
  if not rpf.ops.minted_at(op_id) then
    return nil, "refused", "invalid_op"
  end
  if external("inventory") then
    local detail = detail_of(handle, { item = item, count = count })
    return bridge_command("inventory", direction, handle, op_id, apply, detail, function(fn)
      return rpf.bridge.command(fn, "inventory." .. direction, handle, item, count, op_id)
    end)
  end
  local changed = {}
  local written = {}
  ---Whether the containers changed, and what `apply` wrote, are on disk.
  ---@return boolean durable True once they are.
  local function durable()
    return contents_on_disk(changed)() and applied_on_disk(written)
  end
  local detail = detail_of(handle, { item = item, count = count })
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
          return then_apply(apply, written)
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
    return then_apply(apply, written)
  end, detail)
end

---Gives a player's character plain units of an item.
---@param handle any The engine's handle.
---@param item any The item's slug.
---@param count any How many, a whole number from 1.
---@param op_id any From `rpf.ops.new()`.
---@param apply any? The addon's change this goes with, run once the units moved.
---@return boolean? ok True once given.
---@return string? status `refused`, `unavailable` or `unknown`.
---@return string? why For `refused`: `invalid`, `invalid_op`, `expired_op`, `journal_full`, `not_logged_in`, `no_character`, `no_container`, `no_space`.
function facade.give(handle, item, count, op_id, apply)
  return move_items("give", handle, item, count, op_id, apply)
end

---Takes plain units of an item from a player's character.
---@param handle any The engine's handle.
---@param item any The item's slug.
---@param count any How many, a whole number from 1.
---@param op_id any From `rpf.ops.new()`.
---@param apply any? The addon's change this pays for, run once the units moved (a composite operation).
---@return boolean? ok True once taken.
---@return string? status `refused`, `unavailable` or `unknown`.
---@return string? why For `refused`: as for `give`, `insufficient`, and `invalid_contents` for a container whose contents no longer pass its rules (the catalog changed under it).
function facade.take(handle, item, count, op_id, apply)
  return move_items("take", handle, item, count, op_id, apply)
end

-- Jobs ---------------------------------------------------------------------

---A player's character's job.
---@param handle any The engine's handle.
---@return { name: string, employer: string?, grade: number, on_duty: boolean }? job `name` the job's slug, `employer` its employer's (absent through a bridge whose framework has none), `grade` its rank there; nil for no job (or one the config no longer has).
---@return string? err `unavailable`, `unsupported` (a bridge that does not read jobs), `not_logged_in` or `no_character`.
function facade.current_job(handle)
  if external("jobs") then
    return bridge_read("jobs", "current", rpf.bridge.job_of, handle)
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

facade.character_of = character_of
facade.account_of = account_of
facade.addon_account = addon_account
facade.containers_of = containers_of
facade.valid_entry = valid_entry
facade.detail_of = detail_of
facade.entry_on_disk = entry_on_disk
facade.contents_on_disk = contents_on_disk
facade.then_apply = then_apply
facade.applied_on_disk = applied_on_disk

rpf.facade = facade
return facade
