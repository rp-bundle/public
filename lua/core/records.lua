---The records this game server holds (C7): characters, accounts and
---containers the portal has handed over, and nothing else.
---
---**The core never keeps a record it does not hold.** A record enters here
---only from the portal's `held` reply, and leaves the moment it is released
---or the portal says this server no longer holds it. There is no cache of a
---released record and no way to read one the portal has not handed over,
---because every other rule in C7 assumes it: while a record is held, this
---server is the only writer of it, and while it is not, the portal writes
---Postgres directly, which is only safe if nothing here still has a copy.
---Modules keep ids, never the tables, and read through `records.get` every
---time.
---
---This module is the state and the local rules. `rpf.sync` is the wire: it
---asks for holds, reports changes, answers resyncs and releases. Every
---change made here marks the record and asks `rpf.sync` for a flush, so a
---module changes a record with one call and never builds a frame.
---
---A held record carries a **revision**, the portal's count of the changes it
---has accepted. Every change reported names the revision it was made on, and
---`rpf.sync` moves the revision here as it sends one, so the next change
---names the next revision. A report the portal finds stale is answered with
---a resync of the whole record, which this server, the holder, decides.
---
---Loading a player's session holds their records implicitly: when a player
---is registered, everything their account owns on this server is held for
---them, and released when they leave. Anything else (a stash opened by staff,
---an employer's till, a character's own accounts) is held with `hold`, and
---released with `release` when the module that held it is done.
---
---Events, each with copies: `records.held(views)` when records arrive,
---`records.released(refs)` when this server lets them go, and
---`records.lost(refs, reason)` when the portal says this server does not hold
---them (they were force-released by staff, or purged), which a module answers
---by holding them again if it still needs them.
---@class rpf.records
---@field KINDS table<rpf.RecordKind, true> The kinds of record a server can hold.
---@field MAX_DESCRIPTION_BYTES integer The longest description a transfer may carry, the portal's `limits::MAX_TRANSACTION_DESCRIPTION_BYTES`. Bounded so that a report's worth of ledger entries always fits one frame, and an account's backlog can always be reported.
---@field MAX_NAME_BYTES integer The longest first or last name, after trimming, or server-specific gender a character may have, the portal's `limits::MAX_CHARACTER_NAME_BYTES`. The portal refuses a longer one on every write of a character, so one changed here would be a report it refuses.
---@field entries table<string, rpf.records.Entry> Every held record by `records.key`. Internal: `rpf.sync` reads it to build reports, and nothing else may.
local records = {}

local rpf = rpf
local json = rpf.json
local events = rpf.events

---@alias rpf.RecordKind "character"|"account"|"container"

---A record by kind and id, as the protocol names one.
---@class rpf.RecordRef
---@field kind rpf.RecordKind The record's kind.
---@field id string The record's uuid.

---A ledger entry this server made and the portal has not yet acknowledged.
---It is reported until a reply to a frame carrying it says it landed, and a
---resync or a release sends every one still here, so none is lost to a
---refused frame. The portal appends each `client_id` once, so sending one
---twice is safe.
---@class rpf.records.Transaction
---@field client_id string Minted here, and the ledger's idempotency key.
---@field from_account string The account the money leaves.
---@field to_account string The account it arrives in.
---@field amount number How much, a positive integer up to `protocol.MAX_AMOUNT`.
---@field description string Why, for the statement and staff.
---@field sent boolean Whether a frame carrying it has been sent, so a change reports only new entries.

---One held record.
---@class rpf.records.Entry
---@field kind rpf.RecordKind The record's kind.
---@field id string The record's uuid.
---@field revision number The revision this state is at, and so the base the next change names.
---@field data table The record: a character, an account with its `balance`, or a container, as the portal's `held` gave it and changes since have left it.
---@field through string? The player whose session it is held for, released when they leave. Nil for a record held on its own.
---@field changed table<string, true> What has changed since the last report: character field names, or `contents`.
---@field transactions rpf.records.Transaction[] On an account, the entries the portal has not acknowledged, oldest first.
---@field resync boolean Whether the portal needs the whole record, because a report on it was stale, refused or lost.
---@field more boolean? Whether the last report queued for it left ledger entries for the next. Only `rpf.sync` sets it.
---@field awaiting string? The whole report in flight for it, by frame id: no other whole report on it is sent until that one is answered. Only `rpf.sync` sets it.
---@field recovering boolean? Whether its whole report recovers one the portal answered stale or refused, and has not been queued yet: holds wait for it as for the report it recovers. Only `rpf.sync` sets it.
---@field alone boolean? Whether it is reported in a frame of its own, because a frame carrying it was refused, until one is applied. Only `rpf.sync` sets it.

records.KINDS = { character = true, account = true, container = true }
records.MAX_DESCRIPTION_BYTES = 256
records.MAX_NAME_BYTES = 64

records.entries = {}

---The key a record is held under.
---@param kind string The record's kind.
---@param id string The record's uuid.
---@return string key `kind:id`.
function records.key(kind, id)
  return kind .. ":" .. id
end

---Forgets every held record, for a fresh start (`rpf.start_server`) and the
---tests. A restarted process holds nothing: the portal releases whatever it
---still thinks is held at the next declaration.
function records.reset()
  records.entries = {}
end

---A copy of a held record's state, safe to hand to a caller.
---@param entry rpf.records.Entry The record.
---@return table view A deep copy of `entry.data`.
local function view(entry)
  return json.copy(entry.data)
end

---A held record, as a copy: a character, an account with its `balance`, or a
---container. Nil when this server does not hold it, which is the answer for
---a record it never had, one it released, and one the portal took back.
---@param kind string The record's kind.
---@param id string The record's uuid.
---@return table? record A copy, or nil if it is not held.
function records.get(kind, id)
  local entry = records.entries[records.key(kind, id)]
  return entry and view(entry) or nil
end

---Whether this server holds a record, and so is the one allowed to change it.
---@param kind string The record's kind.
---@param id string The record's uuid.
---@return boolean held True if it is held here.
function records.is_held(kind, id)
  return records.entries[records.key(kind, id)] ~= nil
end

---Every held record, by kind and id, sorted, so a declaration lists them in
---the same order every time.
---@return rpf.RecordRef[] refs The records.
function records.held()
  local out = {}
  for _, entry in pairs(records.entries) do
    out[#out + 1] = { kind = entry.kind, id = entry.id }
  end
  table.sort(out, function(a, b)
    return records.key(a.kind, a.id) < records.key(b.kind, b.id)
  end)
  return out
end

---The revision a held record is at.
---@param kind string The record's kind.
---@param id string The record's uuid.
---@return number? revision The revision, or nil if it is not held.
function records.revision(kind, id)
  local entry = records.entries[records.key(kind, id)]
  return entry and entry.revision
end

-- Taking records over -------------------------------------------------------

---Takes over the records the portal handed over in a `held` reply. A record
---already held here keeps the state it has, which is newer than any the
---portal could send: nothing but this server has changed it since it was
---held.
---@param held table[] The `held` reply's records, decoded.
---@param through string? The player whose session they are for.
---@return table[] views Copies of every record now held that this reply named.
function records.take(held, through)
  local views = {}
  for _, record in ipairs(held) do
    local data, id
    if record.kind == "character" then
      data = record.character
    elseif record.kind == "account" then
      data = json.copy(record.account)
      data.balance = record.balance
    else
      data = record.container
    end
    id = data.id
    local key = records.key(record.kind, id)
    local entry = records.entries[key]
    if not entry then
      entry = {
        kind = record.kind,
        id = id,
        revision = record.revision,
        data = json.copy(data),
        through = through,
        changed = {},
        transactions = {},
        resync = false,
      }
      records.entries[key] = entry
    end
    views[#views + 1] = view(entry)
  end
  return views
end

---Forgets records, which is all releasing is on this side. Returns the refs
---it forgot, in the order given.
---@param refs rpf.RecordRef[] The records.
---@return rpf.RecordRef[] forgotten The ones that were held.
function records.forget(refs)
  local out = {}
  for _, ref in ipairs(refs) do
    local key = records.key(ref.kind, ref.id)
    if records.entries[key] then
      records.entries[key] = nil
      out[#out + 1] = { kind = ref.kind, id = ref.id }
    end
  end
  return out
end

---Forgets records the portal says this server does not hold, and announces
---it with `records.lost`, so whatever module used them can hold them again.
---@param refs rpf.RecordRef[] The records the portal named.
---@param reason string Why, for the log and the event.
function records.lose(refs, reason)
  local lost = records.forget(refs)
  if #lost > 0 then
    events.emit("records.lost", lost, reason)
  end
end

-- Changing held records -----------------------------------------------------

---Asks for a flush after a change, so changes made together go out in one
---report.
local function touched()
  if rpf.sync then
    rpf.sync.schedule()
  end
end

---Trims a character's name and checks it is one, as the portal does for
---every write of a character. Shared with `rpf.characters`, so a name it
---creates and a name changed here follow one rule.
---@param value any The proposed name.
---@return string? name The trimmed name, or nil if it is not a non-empty string of at most `MAX_NAME_BYTES` once trimmed.
function records.check_name(value)
  if type(value) ~= "string" then
    return nil
  end
  local trimmed = value:match("^%s*(.-)%s*$")
  if trimmed == "" or #trimmed > records.MAX_NAME_BYTES then
    return nil
  end
  return trimmed
end

---Checks a gender as the protocol carries one. Shared with
---`rpf.characters`.
---@param value any The proposed gender.
---@return any? gender `"male"`, `"female"`, or a marked `{ server_specific = … }` of at most `MAX_NAME_BYTES`; nil if it is none of them.
function records.check_gender(value)
  if value == "male" or value == "female" then
    return value
  end
  if
    type(value) == "table"
    and type(value.server_specific) == "string"
    and #value.server_specific <= records.MAX_NAME_BYTES
  then
    local count = 0
    for _ in pairs(value) do
      count = count + 1
    end
    if count == 1 then
      return json.object({ server_specific = value.server_specific })
    end
  end
  return nil
end

---Changes a held character's names or gender. Only the fields given change.
---@param id string The character's uuid.
---@param fields { first_name: string?, last_name: string?, gender: any? } The new values.
---@return boolean? ok True if changed.
---@return string? err `"not_held"`, or `"invalid"` for an empty or overlong name or an unknown or overlong gender. Nothing changes on an error.
function records.set_character(id, fields)
  local entry = records.entries[records.key("character", id)]
  if not entry then
    return nil, "not_held"
  end
  local new = {}
  for _, field in ipairs({ "first_name", "last_name" }) do
    if fields[field] ~= nil then
      new[field] = records.check_name(fields[field])
      if not new[field] then
        return nil, "invalid"
      end
    end
  end
  if fields.gender ~= nil then
    new.gender = records.check_gender(fields.gender)
    if not new.gender then
      return nil, "invalid"
    end
  end
  for field, value in pairs(new) do
    entry.data[field] = value
    entry.changed[field] = true
  end
  touched()
  return true
end

---Replaces what a held container holds. Whole contents, never a diff, which
---is also what is reported. They are validated first, against the
---container's flags and the config's item catalog, by `rpf.inventory`'s port
---of the portal's own `ContainerContents::validate` (D6), so nothing the
---portal would refuse is ever reported: a refused report lands nothing, and
---contents the portal could not even decode would fail every later frame
---carrying them, so a release would end nothing there while this server
---forgot the container. `rpf.inventory`'s moves are built on this.
---@param id string The container's uuid.
---@param contents table The new contents, `{ layout = "list", stacks = … }` or `{ layout = "grid", placements = … }`, every array and object JSON-marked.
---@return boolean? ok True if changed.
---@return string? err `"not_held"`, or `"invalid"` for contents that break a rule. Nothing changes on an error.
---@return rpf.inventory.Refusal? refusal For `"invalid"`, the first rule broken, as the portal's `ContentsError` names it.
function records.set_contents(id, contents)
  local entry = records.entries[records.key("container", id)]
  if not entry then
    return nil, "not_held"
  end
  local ok, refusal = rpf.inventory.check(entry.data, contents)
  if not ok then
    return nil, "invalid", refusal
  end
  entry.data.contents = json.copy(contents)
  entry.changed.contents = true
  touched()
  return true
end

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

---Moves money between two held accounts, as one ledger entry. Both must be
---held here: an account this server does not hold is the portal's to write,
---and a report naming one is refused.
---
---The entry gets a `client_id` minted here, which the portal appends at most
---once, so it can be reported as often as it takes. It is reported with the
---paying account. Balances move here at once, and the paying account must
---cover the amount unless it has `unlimited_balance`. No balance may leave
---±`protocol.MAX_AMOUNT`, the widest integer both sides hold exactly.
---@param from string The paying account's uuid.
---@param to string The receiving account's uuid.
---@param amount number A positive integer, at most `protocol.MAX_AMOUNT`.
---@param description string Why, for the statement and staff.
---@return string? client_id The entry's id, or nil if refused.
---@return string? err `"not_held"`, `"invalid"` (a bad amount, the same account twice, or a description that is not a string of at most `MAX_DESCRIPTION_BYTES`), `"insufficient_funds"` or `"out_of_range"`. Nothing changes on an error.
function records.transfer(from, to, amount, description)
  local payer = records.entries[records.key("account", from)]
  local payee = records.entries[records.key("account", to)]
  if not payer or not payee then
    return nil, "not_held"
  end
  local max = rpf.protocol.MAX_AMOUNT
  if
    from == to
    or type(amount) ~= "number"
    or amount ~= math.floor(amount)
    or amount < 1
    or amount > max
    or type(description) ~= "string"
    or #description > records.MAX_DESCRIPTION_BYTES
  then
    return nil, "invalid"
  end
  if payer.data.balance - amount < (unlimited(payer.data) and -max or 0) then
    return nil, unlimited(payer.data) and "out_of_range" or "insufficient_funds"
  end
  if payee.data.balance + amount > max then
    return nil, "out_of_range"
  end
  local client_id = rpf.protocol.new_id(rpf.sync.platform)
  payer.data.balance = payer.data.balance - amount
  payee.data.balance = payee.data.balance + amount
  payer.transactions[#payer.transactions + 1] = {
    client_id = client_id,
    from_account = from,
    to_account = to,
    amount = amount,
    description = description,
    sent = false,
  }
  touched()
  return client_id
end

rpf.records = records
return records
