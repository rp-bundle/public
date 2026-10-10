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
---   payment went through may simply send it again.
--- - **After a restart** an intent still `pending` is `unknown`: it is
---   logged for staff and never run again, because nobody can tell whether
---   it happened. An addon must not grant what it was paying for.
--- - **Tombstones go only by age.** The journal holds at most `MAX_ENTRIES`;
---   a new command past that is refused `journal_full` rather than evicting a
---   young tombstone, whose id could then run twice. An `op_id` older than
---   the window is refused (`expired_op`), so an old id whose tombstone has
---   gone can never become a second payment.
---
---An op id carries when it was minted: `<ms>-<16 hex digits>`, the
---milliseconds since the Unix epoch and the platform's randomness.
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
---@field call string What it was, for staff: `money.debit`, `inventory.give`, …
---@field state "pending"|"done" Whether it finished.
---@field ok boolean? Whether it succeeded, once done.
---@field status string? Its refusal's status, once done and not ok: `refused`, `unavailable` or `unknown`.
---@field reason string? Why it was refused.

---@type table<string, rpf.ops.Entry>
local entries = {}
---@type rpf.ServerPlatform?
local platform = nil

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
    p.kv_set(ops.ENTRY_PREFIX .. id, entry and assert(json.encode(json.object(entry))) or nil)
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

---Runs a command once per op id. A repeated id inside the window gets the
---recorded result; a new one is journaled `pending`, run, and its result
---recorded. A command that throws is `unknown`: it may have done part of
---its work. Nothing here throws.
---@param id any The op id.
---@param call string What it is, for the journal and staff.
---@param run fun(): boolean?, string?, string? The command: true, or nil, a status and a reason.
---@return boolean? ok True if it succeeded, now or before.
---@return string? status `refused`, `unavailable` or `unknown` when not.
---@return string? reason For `refused`, why: the command's own, or `invalid_op`, `expired_op`, `journal_full`.
function ops.run(id, call, run)
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
  local known = entries[id]
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
  local entry = { at = at, call = call, state = "pending" }
  entries[id] = entry
  local saved, why = pcall(save, id, true)
  if not saved then
    entries[id] = nil
    pcall(save, id, true)
    log("error", "could not journal " .. call .. " " .. id .. " (" .. tostring(why) .. "); it was not run")
    return nil, "unavailable"
  end
  local ran, ok, status, reason = pcall(run)
  if not ran then
    log("error", call .. " " .. id .. " failed part way and may have done some of its work: " .. tostring(ok))
    ok, status, reason = nil, "unknown", nil
  end
  entry.state = "done"
  entry.ok = ok == true
  if not entry.ok then
    entry.status, entry.reason = status or "unknown", reason
  end
  local stored, failure = pcall(save, id, false)
  if not stored then
    -- Run, but journaled as pending: after a restart it reads as unknown,
    -- which is the truth there; here the result is known.
    log("error", "could not record " .. call .. " " .. id .. "'s result (" .. tostring(failure) .. ")")
  end
  return recorded(entry)
end

---Loads the journal, turning every intent a restart cut off into `unknown`
---and logging each for staff. Called by `rpf.start_server`.
---@param p rpf.ServerPlatform The platform.
function ops.start(p)
  platform = p
  entries = {}
  local text = p.kv_get(ops.KEY)
  local ids = text and json.decode(text) or nil
  if text and not json.is_array(ids) then
    log("error", "the operation journal's index could not be read; starting a new one")
    ids = nil
  end
  local cut_off = {}
  for _, id in ipairs(ids or {}) do
    local raw = ops.minted_at(id) and p.kv_get(ops.ENTRY_PREFIX .. id) or nil
    local entry = raw and json.decode(raw) or nil
    if type(entry) == "table" and (entry.state == "pending" or entry.state == "done") then
      ---@cast entry rpf.ops.Entry
      entries[id] = entry
      if entry.state == "pending" then
        log(
          "warn",
          tostring(entry.call)
            .. " "
            .. id
            .. " was cut off by a restart: whether it happened is unknown, and it will not run again"
        )
        entry.state, entry.ok, entry.status = "done", false, "unknown"
        cut_off[#cut_off + 1] = id
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
