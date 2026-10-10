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

---@alias rpf.RecordKind "character"|"account"|"container"|"addon_record"

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
---@field changed table<string, true> What has changed since the last report: character field names (`job` is reported as `employment`), or `contents`.
---@field transactions rpf.records.Transaction[] On an account, the entries the portal has not acknowledged, oldest first.
---@field resync boolean Whether the portal needs the whole record, because a report on it was stale, refused or lost.
---@field more boolean? Whether the last report queued for it left ledger entries for the next. Only `rpf.sync` sets it.
---@field awaiting string? The whole report in flight for it, by frame id: no other whole report on it is sent until that one is answered. Only `rpf.sync` sets it.
---@field recovering boolean? Whether its whole report recovers one the portal answered stale or refused, and has not been queued yet: holds wait for it as for the report it recovers. Only `rpf.sync` sets it.
---@field alone boolean? Whether it is reported in a frame of its own, because a frame carrying it was refused, until one is applied. Only `rpf.sync` sets it.
---@field patch table? On an addon record, the fields changed since the last report, each at its new value or `json.null` if cleared: what its next change carries.
---@field created "pending"|"sent"? On an addon record this server created, until the portal has it: `pending` until a frame carries the create, `sent` until that frame is answered. Such a record is only ever reported as its create, never whole.
---@field deleted boolean? On an addon record this server deleted: reported as its deletion, never whole, and forgotten once the portal has it.
---@field delete_sent boolean? On a deleted addon record, whether a frame carries its deletion. Only `rpf.sync` sets it.

records.KINDS = { character = true, account = true, container = true, addon_record = true }
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

---Whether a held record is exactly as the portal has it at `revision`: held
---here, at that revision, with no change made to it here that has not been
---reported yet. A staff edit (F5) names the revision the staff member saw,
---and is applied only then, so it never lands on a state nobody looked at.
---
---The revision moves as a report is sent, so a record whose report is still
---in flight is past the portal's revision and counts as changed, as does one
---with a change marked for the next flush or a resync owed: the portal's
---copy is behind this server's either way.
---@param kind string The record's kind.
---@param id string The record's uuid.
---@param revision number The revision the edit was made on.
---@return boolean? current True if the record is held at exactly that state.
---@return string? err `"not_held"`, or `"changed"` if it has moved on.
function records.current(kind, id, revision)
  local entry = records.entries[records.key(kind, id)]
  if not entry then
    return nil, "not_held"
  end
  if entry.revision ~= revision or entry.resync or next(entry.changed) ~= nil then
    return nil, "changed"
  end
  -- An addon record whose create or deletion the portal has not had yet.
  if entry.created or entry.deleted then
    return nil, "changed"
  end
  for _, tx in ipairs(entry.transactions) do
    if not tx.sent then
      return nil, "changed"
    end
  end
  return true
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
    elseif record.kind == "addon_record" then
      data = record.record
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

-- Trimming names ------------------------------------------------------------

---The code points the portal trims from a character's name: Rust's
---`str::trim`, the Unicode `White_Space` property. The Lua `%s` class is
---ASCII only, so a name of just U+00A0 would pass here and be refused as
---blank by the portal. A spec reads `NAME_WHITESPACE` in
---`crates/rpf-domain/src/characters.rs` to keep the two lists equal.
---@type integer[]
records.WHITESPACE = {
  0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020, 0x0085, 0x00A0, 0x1680, 0x2000, 0x2001, 0x2002,
  0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F,
  0x3000,
}

---UTF-8 for a code point below U+10000, which is all the whitespace there is.
---@param cp integer
---@return string
local function utf8_of(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  end
  return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

---The whitespace as UTF-8 strings. None is a prefix of another, so the order
---of matching does not matter.
---@type string[]
local whitespace = {}
for i, cp in ipairs(records.WHITESPACE) do
  whitespace[i] = utf8_of(cp)
end

---Trims the portal's whitespace from both ends of a string.
---@param value string
---@return string
local function trim(value)
  local first, last = 1, #value
  local moved = true
  while moved and first <= last do
    moved = false
    for _, ws in ipairs(whitespace) do
      local n = #ws
      if value:sub(first, first + n - 1) == ws then
        first = first + n
        moved = true
        break
      end
    end
  end
  moved = true
  while moved and first <= last do
    moved = false
    for _, ws in ipairs(whitespace) do
      local n = #ws
      if last - n + 1 >= first and value:sub(last - n + 1, last) == ws then
        last = last - n
        moved = true
        break
      end
    end
  end
  return value:sub(first, last)
end

-- Changing held records -----------------------------------------------------

---Asks for a flush after a change, so changes made together go out in one
---report.
local function touched()
  if rpf.sync then
    rpf.sync.schedule()
  end
end

---Trims a character's name (the portal's whitespace, `records.WHITESPACE`)
---and checks it is one, as the portal does for every write of a character. Shared with `rpf.characters`, so a name it
---creates and a name changed here follow one rule.
---@param value any The proposed name.
---@return string? name The trimmed name, or nil if it is not a non-empty string of at most `MAX_NAME_BYTES` once trimmed.
function records.check_name(value)
  if type(value) ~= "string" then
    return nil
  end
  local trimmed = trim(value)
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

---Changes a held character's job (D7), or clears it, and marks it for the
---next report, which carries it as `employment`. Only the shape is checked
---here: whether the job is one of this server's is `rpf.jobs`'s rule, which
---is the only caller, because a job removed from config a moment ago must
---still be clearable and a report naming it must still be made.
---
---The same job again changes nothing and marks nothing, so a no-op is never
---reported.
---@param id string The character's uuid.
---@param ref { employer: string, job: string }? The job, by its employer's slug and its own, or nil for none.
---@return boolean? ok True if it is the character's job now.
---@return string? err `"not_held"`, or `"invalid"` for a ref that is not two strings. Nothing changes on an error.
function records.set_job(id, ref)
  local entry = records.entries[records.key("character", id)]
  if not entry then
    return nil, "not_held"
  end
  local new = nil
  if ref ~= nil then
    if type(ref) ~= "table" or type(ref.employer) ~= "string" or type(ref.job) ~= "string" then
      return nil, "invalid"
    end
    new = { employer = ref.employer, job = ref.job }
  end
  local old = entry.data.job
  if old == json.null then
    old = nil
  end
  if (old == nil and new == nil) or (old and new and old.employer == new.employer and old.job == new.job) then
    return true
  end
  entry.data.job = new
  entry.changed.job = true
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

---Makes a staff balance adjustment on a held account (F5): one ledger entry
---between it and the server's funds account, which the portal names and
---never hands over. Positive credits the account, negative debits it.
---
---The entry's `client_id` is the portal's, minted when the staff member
---acted, so an adjustment sent again is made once: one still waiting to be
---reported here is not made twice, and the portal appends each `client_id`
---once. The portal accepts an entry naming its funds account only as the
---adjustment it asked for, so this is the one way one is made. Balances
---move here at once, under the rules a transfer keeps: a debit may not take
---an account below zero unless it has `unlimited_balance`, and no balance
---may leave ±`protocol.MAX_AMOUNT`.
---@param account_id string The held account.
---@param funds_account string The server's funds account, from the command.
---@param amount number A non-zero integer within ±`protocol.MAX_AMOUNT`.
---@param client_id string The entry's id, from the command.
---@param description string Why, at most `MAX_DESCRIPTION_BYTES`.
---@return string? client_id The entry's id, or nil if refused.
---@return string? err `"not_held"`, `"invalid"`, `"insufficient_funds"` or `"out_of_range"`. Nothing changes on an error.
function records.adjust(account_id, funds_account, amount, client_id, description)
  local entry = records.entries[records.key("account", account_id)]
  if not entry then
    return nil, "not_held"
  end
  local max = rpf.protocol.MAX_AMOUNT
  if
    type(funds_account) ~= "string"
    or funds_account == account_id
    or type(client_id) ~= "string"
    or type(amount) ~= "number"
    or amount ~= math.floor(amount)
    or amount == 0
    or amount > max
    or amount < -max
    or type(description) ~= "string"
    or #description > records.MAX_DESCRIPTION_BYTES
  then
    return nil, "invalid"
  end
  for _, tx in ipairs(entry.transactions) do
    if tx.client_id == client_id then
      return client_id
    end
  end
  local after = entry.data.balance + amount
  if after < (unlimited(entry.data) and -max or 0) then
    return nil, unlimited(entry.data) and "out_of_range" or "insufficient_funds"
  end
  if after > max then
    return nil, "out_of_range"
  end
  entry.data.balance = after
  local from, to = funds_account, account_id
  if amount < 0 then
    from, to = account_id, funds_account
  end
  entry.transactions[#entry.transactions + 1] = {
    client_id = client_id,
    from_account = from,
    to_account = to,
    amount = math.abs(amount),
    description = description,
    sent = false,
  }
  touched()
  return client_id
end

-- Addon records (J2) ------------------------------------------------------

---A live addon record's type, from the installed config, if its addon may
---write here now.
---@param type_name any The type's full name.
---@return table? def The type's installed definition.
---@return string? err `"inactive"` when its addon is not active here, `"invalid"` for a type that is not a live type of one.
local function writable_type(type_name)
  if type(type_name) ~= "string" then
    return nil, "invalid"
  end
  local namespace = string.match(type_name, "^([^.]+)%.")
  local def = rpf.addons.definition(type_name)
  if not def or def.authority ~= "live" then
    return nil, "invalid"
  end
  if rpf.addons.state(namespace) ~= "active" then
    return nil, "inactive"
  end
  return def
end

---Creates a live addon record of an active addon (J2), held here from the
---start: the portal has it once the next report carries its create. Its
---fields are checked whole against the type's installed definition
---(`rpf.manifest.check_fields`) and its owner against the kinds the type
---allows; the portal checks both again, and its references, and refuses
---the report otherwise.
---@param type_name string The type's full name, `<namespace>.<name>`.
---@param owner { kind: string, id: string } Who it belongs to.
---@param fields table Its fields.
---@param id string? Its id, minted here if not given: a uuid unique on this server.
---@return table? record A copy: `{ id, type, owner, fields }`.
---@return string? err `"invalid"`, `"inactive"`, or `"conflict"` for an id this server already holds.
---@return table? refusal For `"invalid"`, the rule its fields break.
function records.create_addon_record(type_name, owner, fields, id)
  local def, err = writable_type(type_name)
  if not def then
    return nil, err
  end
  if type(owner) ~= "table" or type(owner.kind) ~= "string" or type(owner.id) ~= "string" then
    return nil, "invalid"
  end
  local allowed = false
  for _, kind in ipairs(def.owners or {}) do
    allowed = allowed or kind == owner.kind
  end
  if not allowed then
    return nil, "invalid"
  end
  local checked, refusal = rpf.manifest.check_fields(def, fields)
  if not checked then
    return nil, "invalid", refusal
  end
  id = id or rpf.protocol.new_id(rpf.sync.platform)
  local key = records.key("addon_record", id)
  if records.entries[key] then
    return nil, "conflict"
  end
  local entry = {
    kind = "addon_record",
    id = id,
    revision = 0,
    data = {
      id = id,
      type = type_name,
      owner = json.object({ kind = owner.kind, id = owner.id }),
      fields = checked,
    },
    changed = {},
    transactions = {},
    resync = false,
    created = "pending",
  }
  records.entries[key] = entry
  touched()
  return view(entry)
end

---Changes fields of a held addon record (J2): the patch names only what it
---changes, `json.null` clearing a field, and the result is checked whole
---against the type's installed definition (`rpf.manifest.apply_patch`). A
---disabled addon's records may still be changed while held: the holder's
---final state must land.
---@param id string The record's uuid.
---@param patch table The fields to set.
---@return table? record A copy of the record as it is now.
---@return string? err `"not_held"` or `"invalid"`.
---@return table? refusal For `"invalid"`, the rule the result breaks.
function records.set_addon_fields(id, patch)
  local entry = records.entries[records.key("addon_record", id)]
  if not entry or entry.deleted then
    return nil, "not_held"
  end
  local def = rpf.addons.definition(entry.data.type)
  if not def then
    return nil, "invalid"
  end
  local fields, refusal = rpf.manifest.apply_patch(def, entry.data.fields, patch)
  if not fields then
    return nil, "invalid", refusal
  end
  entry.data.fields = fields
  if not entry.created then
    entry.patch = entry.patch or json.object({})
    for name in pairs(patch) do
      local value = fields[name]
      if value == nil then
        value = json.null
      end
      entry.patch[name] = value
    end
    entry.changed.fields = true
  end
  touched()
  return view(entry)
end

---Deletes a held addon record (J2). The portal deletes it with the next
---report, and refuses one another live record refers to; this server
---stops holding it either way once that report is answered. One whose
---create has not left yet is simply dropped: the portal never had it.
---@param id string The record's uuid.
---@return boolean? ok True once it is marked deleted.
---@return string? err `"not_held"`.
function records.delete_addon_record(id)
  local key = records.key("addon_record", id)
  local entry = records.entries[key]
  if not entry or entry.deleted then
    return nil, "not_held"
  end
  if entry.created == "pending" then
    records.entries[key] = nil
    return true
  end
  entry.deleted = true
  entry.patch = nil
  entry.changed = {}
  touched()
  return true
end

---Asks the portal for live addon records of a type that match a query
---(J2): how a server finds records it does not hold, to hold them. The
---answer is a page of replicas, each with the revision the portal has and
---whether this server holds it; to change one, hold it first. The query is
---`rpf_domain::addons::query::RecordQuery` as JSON: `filters` (`field`,
---`op` of `eq`, `lt`, `lte`, `gt`, `gte` or `prefix`, `value`) on indexed
---fields, `owner`, `schema`, `order`, `descending`, `after` (a page's
---`next`) and `limit`.
---@param type_name string The type's full name.
---@param query table The query.
---@param callback fun(records: table[]?, next: table?, err: string?) Called once: the records and the next page's cursor, or nil and why.
---@return boolean? ok True once the query is queued.
---@return string? err `"inactive"` or `"invalid"` for a type this server cannot query, or the outbox's refusal.
function records.query_addon_records(type_name, query, callback)
  local _, err = writable_type(type_name)
  if err then
    return nil, err
  end
  if type(query) ~= "table" then
    return nil, "invalid"
  end
  local copy = json.copy(query)
  if not json.is_object(copy) then
    copy = json.object(copy)
  end
  local _, sent = rpf.connection:send("query_records", { type_name = type_name, query = copy }, function(reply, why)
    if reply and reply.type == "records_queried" then
      local next_page = reply.next
      if next_page == json.null then
        next_page = nil
      end
      callback(reply.records, next_page, nil)
    elseif reply then
      callback(nil, nil, reply.code or reply.type)
    else
      callback(nil, nil, why)
    end
  end)
  if sent then
    return nil, sent
  end
  return true
end

rpf.records = records
return records
