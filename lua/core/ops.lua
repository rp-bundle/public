---Operation ids and the journal that makes the facade's commands retry-safe
---(J3, `docs/architecture/framework-integration.md`, "Retries").
---
---A money or item command an addon sends through the domain-neutral facade
---(`rpf.facade`) names an `op_id` the core minted (`ops.new`). The journal,
---kept in the platform's storage so it outlives a restart, records each one:
---
--- - **Before the command runs** its intent is written `pending`. On a
---   native server the command is a local, synchronous ledger entry or
---   container change, so only a crash between the two writes leaves an
---   intent `pending`; through a bridge to a framework (K2) it is the call
---   into the framework, which may have changed something before it failed.
--- - **After it ran** the result replaces `pending`, and stays as a
---   tombstone for `WINDOW_MS`. A repeated `op_id` inside the window gets the
---   recorded result without running again, so an addon that is not sure a
---   payment went through may simply send it again. An `unavailable` result
---   is the exception: it says nothing changed because nothing could be
---   asked, so it is dropped rather than kept, and the same op id may be
---   sent again once the provider is back.
--- - **After a restart** an intent still `pending` is `unknown`: it is
---   surfaced to staff and never run again, because nobody can tell whether
---   it happened. An addon must not grant what it was paying for.
--- - **Every `unknown` is surfaced to staff**, whenever it arises: a command
---   that threw or answered `unknown`, or an intent a restart cut off. It is
---   logged at `error` with what the operation was (the call, the player,
---   the account or item, the amount and the reason, `rpf.ops.Detail`),
---   announced as `domains.op_unknown`, and listed by `ops.unknown()` while
---   it is in the journal. Staff resolve it by hand, in the framework or
---   the portal: nothing here compensates, since nothing can tell a lost
---   payment from a lost grant.
--- - **Tombstones go only by age.** The journal holds at most `MAX_ENTRIES`;
---   a new command past that is refused `journal_full` rather than evicting a
---   young tombstone, whose id could then run twice. An `op_id` older than
---   the window is refused (`expired_op`), so an old id whose tombstone has
---   gone can never become a second payment.
---
---An op id carries when it was minted: `<ms>-<16 hex digits>`, the
---milliseconds since the Unix epoch and the platform's randomness.
---
---**A lost index never lets an id run twice.** Each entry is stored under
---its own key, written before the index, so an id the journal does not
---know (its index could not be read, or a crash lost the line naming it)
---is looked up by that key before it may run: what is there is its result,
---and an entry that cannot be read is `unknown`.
---@class rpf.ops
---@field WINDOW_MS integer How long a result is kept, and how old an op id may be: a day.
---@field MAX_ENTRIES integer The most operations the journal holds at once.
---@field SKEW_MS integer How far in the future an op id may claim to be minted, for a clock that stepped back.
---@field KEY string The storage key of the journal's index: every op id it holds, so a restart finds each entry.
---@field ENTRY_PREFIX string Each entry's storage key is this and its op id, so finishing one rewrites only it.
local ops = {}

local rpf = rpf
local json = rpf.json

ops.WINDOW_MS = 24 * 60 * 60 * 1000
ops.MAX_ENTRIES = 1024
ops.SKEW_MS = 5 * 60 * 1000
ops.KEY = "rpf.ops.index"
ops.ENTRY_PREFIX = "rpf.ops.op."

---One operation in the journal.
---@class rpf.ops.Entry
---@field at number When its op id was minted, from the id.
---@field call string What it was, for staff: `money.debit`, `inventory.give`, `commerce.exchange`, …
---@field state "pending"|"done" Whether it finished.
---@field ok boolean? Whether it succeeded, once done.
---@field status string? Its refusal's status, once done and not ok: `refused`, `unavailable` or `unknown`.
---@field reason string? Why it was refused.
---@field detail rpf.ops.Detail? What it was, for staff resolving an `unknown` one.
---@field cause string? For an `unknown` one, what went wrong, for staff.

---What an operation was, kept with its intent so that staff resolving an
---`unknown` one know what to grant or refund. Plain values only: it is
---stored as JSON and logged. Never a framework's key, which stays out of
---the log as it stays out of the portal.
---@class rpf.ops.Detail
---@field player string? The player's account (`player_id`).
---@field account string? The account's name, for money.
---@field amount number? The amount, for money: what the player paid, for an exchange.
---@field item string? The item's slug, for items.
---@field count number? How many, for items.
---@field reason string? The reason the addon gave, for money and exchanges.
---@field paid number? What the player was paid, for an exchange (`rpf.commerce`).
---@field take string? The items the player handed over, for an exchange: `water:2,bread:1`.
---@field give string? The items the player received, for an exchange.

---What `ops.unknown()` lists and `domains.op_unknown` carries.
---@class rpf.ops.Unknown
---@field op_id string The op id.
---@field call string What it was: `money.debit`, `inventory.give`, `commerce.exchange`, …
---@field at number When its op id was minted, in milliseconds since the Unix epoch.
---@field detail rpf.ops.Detail What it was.
---@field cause string What went wrong.

---The fields of `rpf.ops.Detail`, in the order the log names them.
local DETAIL_KEYS = { "player", "account", "amount", "paid", "item", "count", "take", "give", "reason" }

---@type table<string, rpf.ops.Entry>
local entries = {}
---@type rpf.ServerPlatform?
local platform = nil
---The op ids whose durability check has thrown, logged once each.
---@type table<string, true>
local complained = {}

---Logs through the platform.
---@param level string The level.
---@param message string The line.
local function log(level, message)
  if platform then
    platform.log(level, "rpf.ops: " .. message)
  end
end

---Writes one entry to storage, and the index when the set of ids changed.
---Storage raises on a failed write, which the caller turns into a refusal
---before, or `unknown` after, the command ran.
---@param id string? The entry to write, if one changed.
---@param index boolean Whether the set of ids changed.
local function save(id, index)
  local p = assert(platform, "rpf.ops is not started")
  if id then
    local entry = entries[id]
    local stored = nil
    if entry then
      stored = json.object({})
      for key, value in pairs(entry) do
        stored[key] = value
      end
      if type(entry.detail) == "table" then
        -- Its own copy, marked, so an empty one still encodes as an object.
        local detail = json.object({})
        for key, value in pairs(entry.detail) do
          detail[key] = value
        end
        stored.detail = detail
      end
    end
    p.kv_set(ops.ENTRY_PREFIX .. id, stored and assert(json.encode(stored)) or nil)
  end
  if index then
    local ids = {}
    for known in pairs(entries) do
      ids[#ids + 1] = known
    end
    table.sort(ids)
    p.kv_set(ops.KEY, assert(json.encode(json.array(ids))))
  end
end

---When an op id was minted, if it is one.
---@param id any The value.
---@return number? at Milliseconds since the Unix epoch, or nil if it is not an op id.
function ops.minted_at(id)
  if type(id) ~= "string" then
    return nil
  end
  local at = id:match("^(%d+)%-%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$")
  return at and tonumber(at) or nil
end

---Mints an op id, for one command an addon may send more than once.
---@return string? id The id, or nil before the core has started.
function ops.new()
  if not platform then
    return nil
  end
  return string.format("%d-%s", platform.now(), platform.random_hex(16))
end

---Drops tombstones older than the window, the only way one goes, from
---memory and storage.
---@return boolean dropped Whether any went.
local function sweep()
  local p = assert(platform)
  local now = p.now()
  local dropped = false
  for id, entry in pairs(entries) do
    if entry.state == "done" and now - entry.at > ops.WINDOW_MS then
      entries[id] = nil
      p.kv_set(ops.ENTRY_PREFIX .. id, nil)
      dropped = true
    end
  end
  if dropped then
    save(nil, true)
  end
  return dropped
end

---The result recorded for an entry, as the facade returns one.
---@param entry rpf.ops.Entry The entry.
---@return boolean? ok True if it succeeded.
---@return string? status `refused`, `unavailable` or `unknown`.
---@return string? reason Why it was refused.
local function recorded(entry)
  if entry.state == "pending" then
    return nil, "unknown"
  end
  if entry.ok then
    return true
  end
  return nil, entry.status, entry.reason
end

---A copy of an entry's detail, holding only plain values.
---@param detail any The detail.
---@return rpf.ops.Detail copy The copy.
local function detail_of(detail)
  local out = {}
  if type(detail) == "table" then
    for _, key in ipairs(DETAIL_KEYS) do
      local value = detail[key]
      if type(value) == "string" or type(value) == "number" then
        out[key] = value
      end
    end
  end
  return out
end

---What staff are told of an unknown entry.
---@param id string The op id.
---@param entry rpf.ops.Entry The entry.
---@return rpf.ops.Unknown unknown A copy.
local function unknown_of(id, entry)
  return {
    op_id = id,
    call = tostring(entry.call),
    at = entry.at,
    detail = detail_of(entry.detail),
    cause = entry.cause or "unknown",
  }
end

---Surfaces an entry that ended `unknown` to staff: one line at `error`
---naming what it was, and `domains.op_unknown`.
---@param id string The op id.
---@param entry rpf.ops.Entry The entry.
local function surface(id, entry)
  local unknown = unknown_of(id, entry)
  local parts = {}
  for _, key in ipairs(DETAIL_KEYS) do
    if unknown.detail[key] ~= nil then
      parts[#parts + 1] = key .. "=" .. tostring(unknown.detail[key])
    end
  end
  log(
    "error",
    unknown.call
      .. " "
      .. id
      .. " may or may not have happened ("
      .. unknown.cause
      .. "); it will not run again, and staff must resolve it by hand"
      .. (#parts > 0 and (": " .. table.concat(parts, " ")) or "")
  )
  rpf.events.emit("domains.op_unknown", unknown)
end

---Reads an entry from storage, as a restart does: one still `pending` is
---`unknown` from now on, and surfaced; one that cannot be read is too.
---@param id string The op id.
---@param raw string? What storage holds under its key.
---@return rpf.ops.Entry? entry The entry, or nil if storage holds none.
---@return boolean cut_off Whether it changed to `unknown` here, and so must be written back.
local function read_entry(id, raw)
  if raw == nil then
    return nil, false
  end
  local entry = json.decode(raw)
  if type(entry) ~= "table" or (entry.state ~= "pending" and entry.state ~= "done") then
    ---@type rpf.ops.Entry
    local lost = {
      at = assert(ops.minted_at(id)),
      call = "unreadable",
      state = "done",
      ok = false,
      status = "unknown",
      cause = "its journal entry could not be read",
    }
    surface(id, lost)
    return lost, true
  end
  ---@cast entry rpf.ops.Entry
  if entry.state == "pending" then
    entry.state, entry.ok, entry.status = "done", false, "unknown"
    entry.cause = "cut off by a restart"
    surface(id, entry)
    return entry, true
  end
  return entry, false
end

---Finds an entry the index did not name, under its own key, which is
---written before the index. One found joins the journal, so the index
---names it again. Nothing there means the id never ran here.
---@param id string The op id.
---@return rpf.ops.Entry? entry The entry, or nil if it never ran.
local function recover(id)
  local p = assert(platform)
  local entry, cut_off = read_entry(id, p.kv_get(ops.ENTRY_PREFIX .. id))
  if not entry then
    return nil
  end
  entries[id] = entry
  log("warn", "found " .. tostring(entry.call) .. " " .. id .. " outside the journal's index; it joins the journal again")
  local ok, why = pcall(save, cut_off and id or nil, true)
  if not ok then
    log("error", "could not write the operation journal (" .. tostring(why) .. ")")
  end
  return entry
end

---Whether an op id has a result in the journal, and what it is: what
---`run` would answer at once, without running anything. The facade asks
---this before it asks whether a provider can be reached, so a command that
---already happened, or may have, answers so even while its provider is
---down, rather than `unavailable`, which would say nothing happened.
---@param id any The op id.
---A lookup that fails (storage threw) is not "never ran": it answers as
---`run` does then, `unavailable`, logged, so nothing runs and the same op
---id may be tried again.
---@return boolean known True if the journal has it, inside the window, or could not say.
---@return boolean? ok For a known one, true if it succeeded.
---@return string? status For a known one that did not, `refused`, `unknown`, or `unavailable` when it could not be looked up.
---@return string? reason For `refused`, why.
function ops.known(id)
  local at = ops.minted_at(id)
  if not platform or not at or platform.now() - at > ops.WINDOW_MS then
    return false
  end
  ---@cast id string
  ---@type rpf.ops.Entry?
  local entry = entries[id]
  if not entry then
    local found, lookup = pcall(recover, id)
    if not found then
      log("error", "could not look " .. id .. " up in storage (" .. tostring(lookup) .. "); it was not run")
      return true, nil, "unavailable"
    end
    entry = lookup
  end
  if not entry then
    return false
  end
  return true, recorded(entry)
end

---Runs a command once per op id. A repeated id inside the window gets the
---recorded result; a new one is journaled `pending`, run, and its result
---recorded. A command that throws is `unknown`: it may have done part of
---its work. Nothing here throws.
---
---A success is recorded on disk only once `durable` says the change itself
---is (a native change's report queued in the persisted outbox): recorded
---earlier, a crash in between would lose the change while the journal
---answered a retry `true`. Until then the entry stays `pending` on disk,
---which a restart reads as `unknown`, and it is tried again each second.
---Here the result is known at once either way.
---@param id any The op id.
---@param call string What it is, for the journal and staff.
---@param durable (fun(): boolean)? Whether the change is on disk yet; nil when the command's own result is the whole of it.
---@param run fun(): boolean?, string?, string? The command: true, or nil, a status and a reason. For `unknown`, the reason is what went wrong, for staff, and is not returned.
---@param detail rpf.ops.Detail? What it is, kept with the intent for staff.
---@return boolean? ok True if it succeeded, now or before.
---@return string? status `refused`, `unavailable` or `unknown` when not.
---@return string? reason For `refused`, why: the command's own, or `invalid_op`, `expired_op`, `journal_full`.
function ops.run(id, call, durable, run, detail)
  if not platform then
    return nil, "unavailable"
  end
  local at = ops.minted_at(id)
  if not at then
    return nil, "refused", "invalid_op"
  end
  local now = platform.now()
  if now - at > ops.WINDOW_MS then
    return nil, "refused", "expired_op"
  end
  if at - now > ops.SKEW_MS then
    return nil, "refused", "invalid_op"
  end
  ---@cast id string
  ---@type rpf.ops.Entry?
  local known = entries[id]
  if not known then
    local found, lookup = pcall(recover, id)
    if not found then
      log("error", "could not look " .. id .. " up in storage (" .. tostring(lookup) .. "); it was not run")
      return nil, "unavailable"
    end
    known = lookup
  end
  if known then
    return recorded(known)
  end
  local swept = pcall(sweep)
  if not swept then
    log("error", "could not drop old operations from the journal")
  end
  local count = 0
  for _ in pairs(entries) do
    count = count + 1
  end
  if count >= ops.MAX_ENTRIES then
    return nil, "refused", "journal_full"
  end
  ---@type rpf.ops.Entry
  local entry = { at = at, call = call, state = "pending", detail = detail_of(detail) }
  entries[id] = entry
  local saved, why = pcall(save, id, true)
  if not saved then
    entries[id] = nil
    local cleaned, failure = pcall(save, id, true)
    if not cleaned then
      log("error", "could not take " .. id .. " back out of the journal either (" .. tostring(failure) .. ")")
    end
    log("error", "could not journal " .. call .. " " .. id .. " (" .. tostring(why) .. "); it was not run")
    return nil, "unavailable"
  end
  local ran, ok, status, reason = pcall(run)
  if not ran then
    ok, status, reason = nil, "unknown", "it threw part way: " .. tostring(ok)
  end
  if ok ~= true and status == "unavailable" then
    -- Nothing changed: forget the intent, so the same id may run later.
    entries[id] = nil
    local forgot, failure = pcall(save, id, true)
    if not forgot then
      log("error", "could not take " .. id .. " back out of the journal (" .. tostring(failure) .. ")")
    end
    return nil, "unavailable"
  end
  entry.state = "done"
  entry.ok = ok == true
  if not entry.ok then
    entry.status = status or "unknown"
    if entry.status == "unknown" then
      entry.cause = type(reason) == "string" and reason or "its provider could not say whether it happened"
    else
      entry.reason = reason
    end
  end
  ops.settle(id, call, entry.ok and durable or nil)
  if entry.status == "unknown" then
    surface(id, entry)
  end
  return recorded(entry)
end

---Records a finished entry's result on disk once its change is durable,
---trying again each second until it is. Run, but journaled as pending
---meanwhile: after a restart that reads as unknown, which is the truth
---there, since the change may not have reached the disk.
---@param id string The op id.
---@param call string What it was.
---@param durable (fun(): boolean)? Whether the change is on disk yet.
function ops.settle(id, call, durable)
  if entries[id] == nil or not platform then
    return
  end
  local ready = durable == nil
  if not ready then
    local ok, answer = pcall(durable --[[@as fun(): boolean]])
    ready = ok and answer == true
    if not ok and not complained[id] then
      complained[id] = true
      log("error", "could not tell whether " .. call .. " " .. id .. "'s change is on disk (" .. tostring(answer) .. "); trying again")
    end
  end
  if ready then
    local stored, failure = pcall(save, id, false)
    if stored then
      complained[id] = nil
      return
    end
    log("error", "could not record " .. call .. " " .. id .. "'s result (" .. tostring(failure) .. "); trying again")
  end
  platform.after(1000, function()
    ops.settle(id, call, durable)
  end)
end

---Loads the journal, turning every intent a restart cut off into `unknown`
---and logging each for staff. Called by `rpf.start_server`.
---@param p rpf.ServerPlatform The platform.
function ops.start(p)
  platform = p
  entries = {}
  complained = {}
  local text = p.kv_get(ops.KEY)
  local ids = text and json.decode(text) or nil
  if text and not json.is_array(ids) then
    log("error", "the operation journal's index could not be read; starting a new one")
    ids = nil
  end
  local cut_off = {}
  for _, id in ipairs(ids or {}) do
    if ops.minted_at(id) then
      local read, entry, changed = pcall(read_entry, id, p.kv_get(ops.ENTRY_PREFIX .. id))
      if not read then
        log("error", "could not read " .. tostring(id) .. " from the journal (" .. tostring(entry) .. ")")
      elseif entry then
        entries[id] = entry
        if changed then
          cut_off[#cut_off + 1] = id
        end
      end
    end
  end
  local ok, why = pcall(function()
    for _, id in ipairs(cut_off) do
      save(id, false)
    end
    if not sweep() then
      save(nil, true)
    end
  end)
  if not ok then
    log("error", "could not write the operation journal (" .. tostring(why) .. ")")
  end
end

---The operations in the journal whose result is `unknown`, oldest first:
---what staff must resolve by hand, for a script that shows them in game.
---Each stays listed until its tombstone ages out.
---@return rpf.ops.Unknown[] unknown Copies.
function ops.unknown()
  local out = {}
  for id, entry in pairs(entries) do
    if entry.state == "done" and entry.status == "unknown" then
      out[#out + 1] = unknown_of(id, entry)
    end
  end
  table.sort(out, function(a, b)
    if a.at ~= b.at then
      return a.at < b.at
    end
    return a.op_id < b.op_id
  end)
  return out
end

---How many operations the journal holds, for tests and diagnostics.
---@return integer count The count.
function ops.count()
  local count = 0
  for _ in pairs(entries) do
    count = count + 1
  end
  return count
end

rpf.ops = ops
return ops
