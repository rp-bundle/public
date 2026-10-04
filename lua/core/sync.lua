---Keeps the portal's replica of held records current (C7): holds, releases,
---state reports, resyncs, and the declaration of what is held after every
---connect.
---
---`rpf.records` keeps the state; this module is everything that crosses the
---wire about it. Every frame goes through the connection's persisted outbox
---(D1), so a report made while the portal is unreachable waits on disk and
---survives a restart, and goes out, in order, after the next `Welcome`.
---
--- - **Reports are batched.** A change marks its record, and the next flush,
---   `flush_interval_ms` later (`offline_flush_interval_ms` while the portal
---   is unreachable, so an outage does not fill the outbox), reports every
---   marked record in one `state_changed` frame (several, if they would not
---   fit in one). Each
---   change names the revision it was made on, and the record moves to the
---   next revision as it is sent, so frames queued behind each other name
---   consecutive revisions.
--- - **Stale is answered with the whole record.** The portal applies a frame
---   all or nothing. If it finds a revision stale it answers
---   `resync_required`, and every record the frame named is reported whole in
---   a `resync`, at a revision no lower than the portal's: this server holds
---   it, so its state is the truth. A record the portal says is not held here
---   (force-released, purged) is dropped and announced with `records.lost`.
---   Ledger entries stay unacknowledged until a reply says they landed, so a
---   resync carries every one still in doubt, and the portal appends each
---   `client_id` once.
--- - **Release carries the final state.** A release flushes everything
---   marked first, then reports every released record whole, so nothing
---   marked is lost, and they are forgotten here at once.
--- - **Whole reports take a revision of their own**, one past the last this
---   server used, so a late resend of an older whole report is dropped by
---   the portal rather than put over a newer one.
--- - **The declaration.** After each `Welcome`, once every hold, release and
---   report queued before it has been answered, the server declares what it
---   holds and at which revision (`declare_holds`). The portal releases
---   anything it does not declare, which is how a restart, which loses every
---   hold from memory, gives them back. Waiting for the queue first is what
---   keeps a release or a report from before the disconnect from arriving
---   after the declaration and finding its record already let go. New holds
---   wait for the declaration's answer, so it can never release one.
---@class rpf.sync
---@field DEFAULTS rpf.SyncOptions The production timings and bounds.
---@field RECORD_FRAMES table<string, true> The frame types a declaration waits for, when they were queued before the `Welcome`.
---@field platform rpf.ServerPlatform? The platform, once started.
---@field connection rpf.Client? The connection, once started.
---@field options rpf.SyncOptions The options in force.
local sync = {}

local rpf = rpf
local events = rpf.events
local records = rpf.records

---Options for `sync.start`.
---@class rpf.SyncOptions
---@field flush_interval_ms number? How long after a change the flush that reports it runs, so changes made together go in one frame.
---@field offline_flush_interval_ms number? The same while the portal is unreachable. Longer, because every flush then waits in the outbox, which has room for `max_entries` frames: at one a minute that is more than a day of play, while each change still reaches storage within the minute.
---@field max_records_per_frame integer? The most records one report carries. A batch whose frame would still be over the portal's frame limit is split further.
sync.DEFAULTS = {
  flush_interval_ms = 1000,
  offline_flush_interval_ms = 60 * 1000,
  max_records_per_frame = 64,
}

sync.RECORD_FRAMES = {
  hold = true,
  release = true,
  state_changed = true,
  resync = true,
  declare_holds = true,
}

sync.options = sync.DEFAULTS

---What a report in flight carried, by its frame id, so its reply can settle
---it. In memory only: after a restart the records are gone too.
---@class rpf.sync.Inflight
---@field keys string[] The records it named, by `records.key`.
---@field transactions table<string, true> The ledger entries it carried, by `client_id`.

---@type table<string, rpf.sync.Inflight>
local inflight = {}

---Where the declaration is after a `Welcome`.
---@class rpf.sync.Declaration
---@field pending boolean Whether one is owed for the current connection and not yet answered.
---@field mark integer The connection's `next_seq` at the `Welcome`: entries below it are what it waits for.
---@field frame string? The declaration in flight, by frame id.

---@type rpf.sync.Declaration
local declaration = { pending = false, mark = 0 }

---Holds waiting for the declaration's answer.
---@type { fields: table, through: string?, callback: fun(views: table[]?, err: string?)? }[]
local deferred = {}

---Whether a flush is already scheduled.
local scheduled = false

---Logs through the platform with the module's prefix.
---@param level "debug"|"info"|"warn"|"error" How much it matters.
---@param message string The line.
local function log(level, message)
  if sync.platform then
    sync.platform.log(level, "rpf.sync: " .. message)
  end
end

-- Building frames -----------------------------------------------------------

---A ledger entry as the protocol carries it.
---@param tx rpf.records.Transaction The entry.
---@return table wire The entry's fields.
local function wire_transaction(tx)
  return {
    client_id = tx.client_id,
    from_account = tx.from_account,
    to_account = tx.to_account,
    amount = tx.amount,
    description = tx.description,
  }
end

---A record whole, as a `resync` or `release` reports it, at a revision of
---its own: one past the last this server used, so no two different whole
---states share a revision, and the portal can drop an older one that
---arrives late (a resend after a lost reply) instead of putting it over a
---newer one. The record moves to that revision once the report is queued.
---@param entry rpf.records.Entry The record.
---@return table report The `RecordReport`.
local function full_report(entry)
  local report = { kind = entry.kind, id = entry.id, revision = entry.revision + 1 }
  if entry.kind == "character" then
    report.first_name = entry.data.first_name
    report.last_name = entry.data.last_name
    report.gender = entry.data.gender
  elseif entry.kind == "account" then
    report.transactions = {}
    for i, tx in ipairs(entry.transactions) do
      report.transactions[i] = wire_transaction(tx)
    end
  else
    report.contents = entry.data.contents
  end
  return report
end

---What changed in a record since its last report, as `state_changed` names
---it, or nil if nothing has.
---@param entry rpf.records.Entry The record.
---@return table? change The `StateChange`.
local function change_of(entry)
  local change = { kind = entry.kind, id = entry.id, base_revision = entry.revision }
  if entry.kind == "character" then
    if not next(entry.changed) then
      return nil
    end
    for field in pairs(entry.changed) do
      change[field] = entry.data[field]
    end
  elseif entry.kind == "account" then
    change.transactions = {}
    for _, tx in ipairs(entry.transactions) do
      if not tx.sent then
        change.transactions[#change.transactions + 1] = wire_transaction(tx)
      end
    end
    if #change.transactions == 0 then
      return nil
    end
  else
    if not entry.changed.contents then
      return nil
    end
    change.contents = entry.data.contents
  end
  return change
end

---Every held record matching a test, sorted by key, so frames are built in
---the same order every time.
---@param test fun(entry: rpf.records.Entry): boolean The test.
---@return rpf.records.Entry[] entries The matching records.
local function select_entries(test)
  local out = {}
  for _, entry in pairs(records.entries) do
    if test(entry) then
      out[#out + 1] = entry
    end
  end
  table.sort(out, function(a, b)
    return records.key(a.kind, a.id) < records.key(b.kind, b.id)
  end)
  return out
end

-- Replies -------------------------------------------------------------------

---Asks for the whole of every named record still held, at no lower than the
---revision the portal has, and flushes.
---@param keys string[] The records, by key.
---@param stale table<string, number> The portal's revisions, for the ones it called stale.
local function resync(keys, stale)
  for _, key in ipairs(keys) do
    local entry = records.entries[key]
    if entry then
      entry.revision = math.max(entry.revision, stale[key] or 0)
      entry.resync = true
    end
  end
  sync.flush()
end

---The portal's revisions in a `resync_required`, by key.
---@param reply table The reply.
---@return table<string, number> stale The revisions.
local function stale_map(reply)
  local stale = {}
  for _, rev in ipairs(reply.stale) do
    stale[records.key(rev.kind, rev.id)] = rev.revision
  end
  return stale
end

---Settles a `state_changed` or `resync` from its answer.
---@param id string? The frame's id; nil when the outbox refused it before it had one.
---@param reply table? The answer.
---@param err string? Why there was none.
local function settle_report(id, reply, err)
  if not id or not inflight[id] then
    return
  end
  local sent = inflight[id]
  inflight[id] = nil
  if not reply then
    -- Never reached the portal: report the whole records again.
    log("warn", "a state report was not delivered (" .. tostring(err) .. "); resyncing its records")
    resync(sent.keys, {})
    return
  end
  if reply.type == "state_applied" then
    for _, key in ipairs(sent.keys) do
      local entry = records.entries[key]
      if entry and entry.kind == "account" then
        local kept = {}
        for _, tx in ipairs(entry.transactions) do
          if not sent.transactions[tx.client_id] then
            kept[#kept + 1] = tx
          end
        end
        entry.transactions = kept
      end
    end
  elseif reply.type == "resync_required" then
    records.lose(reply.released, "the portal says this server does not hold them")
    resync(sent.keys, stale_map(reply))
  else
    -- A final refusal. The records keep their state and their unacknowledged
    -- entries; the next report on them is stale and resyncs them.
    log("error", "the portal refused a state report (" .. tostring(reply.code) .. "): " .. tostring(reply.reason))
  end
end

-- Sending -------------------------------------------------------------------

---Sends one report frame, splitting the batch when the frame would be over
---the portal's frame limit. A single record too large to send is logged and
---left marked: it cannot be reported until it shrinks.
---@param tag "state_changed"|"resync" The frame type.
---@param entries rpf.records.Entry[] The records.
---@param build fun(entry: rpf.records.Entry): table The change or report for one.
---@param sent fun(entry: rpf.records.Entry) Marks one as reported, once the frame is queued.
---@return boolean ok False if the outbox refused it, so the flush stops and tries later.
local function send_batch(tag, entries, build, sent)
  if #entries == 0 then
    return true
  end
  local items, transactions, keys = {}, {}, {}
  for i, entry in ipairs(entries) do
    items[i] = build(entry)
    keys[i] = records.key(entry.kind, entry.id)
    for _, tx in ipairs(items[i].transactions or {}) do
      transactions[tx.client_id] = true
    end
  end
  local field = tag == "resync" and "records" or "changes"
  local id
  local ok, result, err = pcall(sync.connection.send, sync.connection, tag, { [field] = items }, function(reply, why)
    settle_report(id, reply, why)
  end)
  if not ok then
    if #entries == 1 then
      log("error", "cannot report " .. keys[1] .. ": " .. tostring(result))
      return true
    end
    local half = math.floor(#entries / 2)
    local first, second = {}, {}
    for i, entry in ipairs(entries) do
      if i <= half then
        first[#first + 1] = entry
      else
        second[#second + 1] = entry
      end
    end
    return send_batch(tag, first, build, sent) and send_batch(tag, second, build, sent)
  end
  if not result then
    log("warn", tag .. " could not be queued (" .. tostring(err) .. "); trying again later")
    return false
  end
  id = result
  inflight[id] = { keys = keys, transactions = transactions }
  for _, entry in ipairs(entries) do
    sent(entry)
  end
  return true
end

---Sends a list in batches of at most `max_records_per_frame`.
---@param tag "state_changed"|"resync" The frame type.
---@param entries rpf.records.Entry[] The records.
---@param build fun(entry: rpf.records.Entry): table The change or report for one.
---@param sent fun(entry: rpf.records.Entry) Marks one as reported.
---@return boolean ok False if the outbox refused one.
local function send_all(tag, entries, build, sent)
  local size = sync.options.max_records_per_frame
  for start = 1, #entries, size do
    local batch = {}
    for i = start, math.min(start + size - 1, #entries) do
      batch[#batch + 1] = entries[i]
    end
    if not send_batch(tag, batch, build, sent) then
      return false
    end
  end
  return true
end

---Marks every ledger entry on a record as sent.
---@param entry rpf.records.Entry The record.
local function mark_sent(entry)
  for _, tx in ipairs(entry.transactions) do
    tx.sent = true
  end
end

---Reports everything marked: first the records the portal needs whole, then
---every changed one. Runs `flush_interval_ms` after a change, and at once
---when a reply asks for a resync. Whatever the outbox refuses stays marked,
---and another flush is scheduled.
function sync.flush()
  scheduled = false
  if not sync.connection then
    return
  end
  local wholes = select_entries(function(entry)
    return entry.resync
  end)
  local ok = send_all("resync", wholes, full_report, function(entry)
    entry.revision = entry.revision + 1
    entry.resync = false
    entry.changed = {}
    mark_sent(entry)
  end)
  if ok then
    local changed = select_entries(function(entry)
      return not entry.resync and change_of(entry) ~= nil
    end)
    ok = send_all("state_changed", changed, function(entry)
      return change_of(entry) --[[@as table]]
    end, function(entry)
      entry.revision = entry.revision + 1
      entry.changed = {}
      mark_sent(entry)
    end)
  end
  if not ok then
    sync.schedule()
  end
end

---Schedules a flush `flush_interval_ms` from now, or
---`offline_flush_interval_ms` while the portal is unreachable, unless one is
---already scheduled.
function sync.schedule()
  if scheduled or not sync.platform or not sync.connection then
    return
  end
  scheduled = true
  local delay = sync.options.offline_flush_interval_ms
  if sync.connection.state == "ready" then
    delay = sync.options.flush_interval_ms
  end
  sync.platform.after(delay --[[@as number]], function()
    if scheduled then
      sync.flush()
    end
  end)
end

-- Holding and releasing -----------------------------------------------------

---Sends a hold now.
---@param fields table The `hold` frame's fields.
---@param through string? The player it is for.
---@param callback fun(views: table[]?, err: string?)? Called with copies of the records, or the refusal.
local function send_hold(fields, through, callback)
  sync.connection:send("hold", fields, function(reply, err)
    local views, why
    if reply and reply.type == "held" then
      views = records.take(reply.records, through)
      events.emit("records.held", views)
      if through and not rpf.players.by_player_id(through) then
        -- They left while the hold was in flight: give it straight back.
        sync.release_through(through)
      end
    else
      why = reply and reply.code or err
      log("warn", "a hold was refused (" .. tostring(why) .. ")")
    end
    if callback then
      callback(views, why)
    end
  end)
end

---Asks the portal to hand records over. `owners` holds every live record
---each owner has on this server (not transitively: a character's own
---accounts are held through the character); `records` holds those named.
---
---Waits while a declaration is owed on the current connection, so the
---declaration can never release it. The portal refuses the whole hold if any
---named record is not this server's to hold, exactly as if it did not exist.
---@param request { owners: table[]?, records: rpf.RecordRef[]? } What to hold.
---@param through string? The player whose session it is for, released when they leave.
---@param callback fun(views: table[]?, err: string?)? Called with copies of the records now held, or the refusal's code.
function sync.hold(request, through, callback)
  local fields = { owners = request.owners or {}, records = request.records or {} }
  if declaration.pending and sync.connection.state == "ready" then
    deferred[#deferred + 1] = { fields = fields, through = through, callback = callback }
    return
  end
  send_hold(fields, through, callback)
end

---Lets records go, reporting each whole as its final state. They are
---forgotten at once and announced with `records.released`; a record this
---server does not hold is ignored. Refused when the outbox is full, in which
---case nothing is released, because the final state would be lost.
---
---Everything marked is flushed first, so a report naming a released record
---(another account's payment to it) reaches the portal ahead of the release,
---in order.
---@param refs rpf.RecordRef[] The records.
---@param callback fun(reply: table?, err: string?)? Called with the portal's answer.
---@return boolean? ok True if the release was queued.
---@return string? err Why not.
function sync.release(refs, callback)
  sync.flush()
  local reports, held = {}, {}
  for _, ref in ipairs(refs) do
    local entry = records.entries[records.key(ref.kind, ref.id)]
    if entry then
      reports[#reports + 1] = full_report(entry)
      held[#held + 1] = ref
    end
  end
  if #reports == 0 then
    return true
  end
  local id, err = sync.connection:send("release", { records = reports }, callback)
  if not id then
    return nil, err
  end
  local released = records.forget(held)
  events.emit("records.released", released)
  return true
end

---Releases everything held for one player's session.
---@param player_id string The player.
function sync.release_through(player_id)
  local refs = {}
  for _, entry in ipairs(select_entries(function(entry)
    return entry.through == player_id
  end)) do
    refs[#refs + 1] = { kind = entry.kind, id = entry.id }
  end
  local ok, err = sync.release(refs)
  if not ok then
    log("error", "could not release a departing player's records: " .. tostring(err))
  end
end

-- The declaration -----------------------------------------------------------

---Settles the declaration from its answer, then sends the holds that waited
---for it.
---@param id string? The declaration's frame id; nil when the outbox refused it before it had one.
---@param reply table? The answer.
---@param err string? Why there was none.
local function settle_declaration(id, reply, err)
  if reply and reply.type == "resync_required" then
    records.lose(reply.released, "the portal no longer holds them for this server")
    local keys = {}
    for _, rev in ipairs(reply.stale) do
      keys[#keys + 1] = records.key(rev.kind, rev.id)
    end
    resync(keys, stale_map(reply))
  elseif reply and reply.type == "rejected" then
    log("error", "the portal refused the declaration (" .. tostring(reply.code) .. "): " .. tostring(reply.reason))
  elseif not reply then
    log("warn", "the declaration was not delivered (" .. tostring(err) .. ")")
  end
  if declaration.frame ~= id then
    return
  end
  declaration.frame = nil
  if not reply and err ~= "expired" then
    -- Nothing answered it on this connection: declare again.
    return
  end
  declaration.pending = false
  local waiting = deferred
  deferred = {}
  for _, hold in ipairs(waiting) do
    send_hold(hold.fields, hold.through, hold.callback)
  end
end

---Sends the declaration once every record frame queued before the `Welcome`
---has been answered. Called at the `Welcome` and whenever an entry leaves
---the outbox.
function sync.check_declaration()
  local connection = sync.connection
  if not connection or not declaration.pending or declaration.frame or connection.state ~= "ready" then
    return
  end
  for _, entry in ipairs(connection.outbox) do
    if entry.seq < declaration.mark and sync.RECORD_FRAMES[entry.type] then
      return
    end
  end
  local held = {}
  for _, ref in ipairs(records.held()) do
    held[#held + 1] = { kind = ref.kind, id = ref.id, revision = records.revision(ref.kind, ref.id) }
  end
  local id
  id = connection:send("declare_holds", { records = held }, function(reply, err)
    settle_declaration(id, reply, err)
  end)
  declaration.frame = id
end

---Starts a declaration for a new connection.
function sync.connected()
  declaration.pending = true
  declaration.mark = sync.connection.next_seq
  declaration.frame = nil
  sync.check_declaration()
end

-- Starting ------------------------------------------------------------------

---Starts the module on a connection: declares after every `Welcome`, holds
---each player's records when they register, and releases them when they
---leave.
---@param platform rpf.ServerPlatform The platform.
---@param connection rpf.Client The connection to the portal.
---@param options rpf.SyncOptions? Overrides for the timings.
function sync.start(platform, connection, options)
  sync.platform = platform
  sync.connection = connection
  sync.options = {}
  for key, value in pairs(sync.DEFAULTS) do
    sync.options[key] = value
  end
  for key, value in pairs(options or {}) do
    sync.options[key] = value
  end
  inflight = {}
  deferred = {}
  scheduled = false
  declaration = { pending = false, mark = 0 }
  records.reset()
  connection.on_ready = sync.connected
  connection.on_release = sync.check_declaration
  events.on("players.registered", function(player)
    sync.hold({ owners = { { kind = "player", id = player.player_id } } }, player.player_id)
  end)
  events.on("players.dropping", function(player)
    if player.player_id then
      sync.release_through(player.player_id)
    end
  end)
end

rpf.sync = sync
return sync
