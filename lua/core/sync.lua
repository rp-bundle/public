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
--- - **Stale is answered with the whole record.** The portal applies a
---   frame's characters and containers all or nothing (ledger entries on a
---   held account it appends regardless: they have no state to be stale
---   against). If it finds a revision stale it answers
---   `resync_required`, and every record the frame named is reported whole in
---   a `resync`, at a revision no lower than the portal's: this server holds
---   it, so its state is the truth. A record the portal says is not held here
---   (force-released, purged) is dropped and announced with `records.lost`.
---   Ledger entries stay unacknowledged until a reply says they landed, so a
---   resync carries every one still in doubt, and the portal appends each
---   `client_id` once.
--- - **Release carries the final state.** A release flushes everything
---   marked first, then reports every released record whole, so nothing
---   marked is lost, and they are forgotten here at once. A departing
---   player's release that the outbox cannot take is tried again as the
---   outbox drains.
--- - **Whole reports take a revision of their own**, one past the last this
---   server used, so a late resend of an older whole report is dropped by
---   the portal rather than put over a newer one.
--- - **A hold never overtakes a report.** The portal can ask for a frame
---   again (a transient fault), and the frames behind it are then answered
---   first. So a hold is sent only once every report and release queued
---   before it has been answered, and every resync that recovers one: what
---   `held` hands over then includes
---   them, and a record released and held again comes back with the final
---   state this server gave it, payments from other accounts included.
--- - **After a restart** the records are gone from memory but the reports
---   the old process queued are still in the outbox, and go out first. One
---   the portal finds stale cannot be answered with a resync, so it is sent
---   again as it is a few times: the report before it is on its way.
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
---@field REPORT_FRAMES table<string, true> The frame types a hold waits for, when they were queued before it was asked for.
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
---@field max_transactions_per_report integer? The most ledger entries one report on an account carries. An account with more to report (a till through a long outage) goes in several consecutive reports, so its backlog can never outgrow a frame: with `records.MAX_DESCRIPTION_BYTES`, this many entries always fit in one.
---@field orphan_retries integer? How often a `state_changed` that outlived a restart is sent again when the portal finds it stale with no report queued before it left to land, before it is given up as lost. While one before it is unanswered it is kept without limit.
sync.DEFAULTS = {
  flush_interval_ms = 1000,
  offline_flush_interval_ms = 60 * 1000,
  max_records_per_frame = 64,
  max_transactions_per_report = 256,
  orphan_retries = 2,
}

sync.RECORD_FRAMES = {
  hold = true,
  release = true,
  state_changed = true,
  resync = true,
  declare_holds = true,
}

sync.REPORT_FRAMES = {
  release = true,
  state_changed = true,
  resync = true,
}

sync.options = sync.DEFAULTS

---What a report in flight carried, by its frame id, so its reply can settle
---it. In memory only: after a restart the records are gone too.
---@class rpf.sync.Inflight
---@field keys string[] The records it named, by `records.key`.
---@field transactions table<string, true> The ledger entries it carried, by `client_id`.
---@field whole boolean Whether it was a `resync`, whose records send no other whole report until it is answered.

---@type table<string, rpf.sync.Inflight>
local inflight = {}

---Where the declaration is after a `Welcome`.
---@class rpf.sync.Declaration
---@field pending boolean Whether one is owed for the current connection and not yet answered.
---@field mark integer The connection's `next_seq` at the `Welcome`: entries below it are what it waits for.
---@field frame string? The declaration in flight, by frame id.

---@type rpf.sync.Declaration
local declaration = { pending = false, mark = 0 }

---A hold waiting to be sent.
---@class rpf.sync.DeferredHold
---@field fields table The `hold` frame's fields.
---@field through string? The player whose session it is for.
---@field callback fun(views: table[]?, err: string?)? Called with copies of the records, or the refusal.
---@field mark integer The connection's `next_seq` when the hold was asked for: reports and releases below it are what it waits for.

---Holds waiting to be sent: for the declaration's answer, and for the
---answer to every report and release queued before them.
---@type rpf.sync.DeferredHold[]
local deferred = {}

---How many releases this process has queued, as a clock for `released_at`.
local releases = 0

---When each record was last released, on the `releases` clock, so a hold's
---reply can tell a release that came after the hold was sent. Kept only
---while a hold is in flight.
---@type table<string, integer>
local released_at = {}

---How many holds are queued and unanswered.
local holds_in_flight = 0

---Whether a flush is already scheduled.
local scheduled = false

---How often a report that outlived a restart has been found stale with
---nothing queued before it, by frame id (`sync.orphaned`).
---@type table<string, integer>
local orphan_tries = {}

---Players who left while their records could not be released, by player id.
---@type table<string, true>
local departed = {}

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
---
---An account's whole state is its unacknowledged ledger entries, oldest
---first, at most `max_transactions_per_report` of them. With more than
---that, the record stays marked and the next whole report follows once this
---one is answered and its entries are acknowledged, so a whole report always
---carries every entry in doubt up to its last: whichever of an account's
---frames the portal takes last, nothing before it is missing.
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
    for _, tx in ipairs(entry.transactions) do
      if #report.transactions == sync.options.max_transactions_per_report then
        break
      end
      report.transactions[#report.transactions + 1] = wire_transaction(tx)
    end
  else
    report.contents = entry.data.contents
  end
  return report
end

---What changed in a record since its last report, as `state_changed` names
---it, or nil if nothing has. At most `max_transactions_per_report` ledger
---entries; the rest go in the next report.
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
      if #change.transactions == sync.options.max_transactions_per_report then
        break
      end
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
      entry.recovering = true
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
  if sent.whole then
    for _, key in ipairs(sent.keys) do
      local entry = records.entries[key]
      if entry and entry.awaiting == id then
        entry.awaiting = nil
      end
    end
  end
  if not reply then
    -- Never reached the portal: report the whole records again.
    log("warn", "a state report was not delivered (" .. tostring(err) .. "); resyncing its records")
    resync(sent.keys, {})
    return
  end
  if reply.type == "state_applied" then
    for _, key in ipairs(sent.keys) do
      local entry = records.entries[key]
      if entry then
        entry.alone = nil
      end
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
    if sent.whole then
      -- The next whole report of an account whose backlog took several.
      sync.flush()
    end
  elseif reply.type == "resync_required" then
    records.lose(reply.released, "the portal says this server does not hold them")
    resync(sent.keys, stale_map(reply))
  else
    -- A final refusal: the portal took nothing, and the frame, the only
    -- durable copy of what it carried, has left the outbox. So every record
    -- it named goes again whole: a character's or container's state as it
    -- is now, an account's every unacknowledged ledger entry. Its changes
    -- were cleared as the frame was queued, and an account's report is
    -- never stale, so nothing else would send them again. One change the
    -- portal will not take refuses every change beside it, so each record
    -- of a refused frame is then reported alone until one of its frames is
    -- applied, and that goes at once: it is the recovery of a report a hold
    -- may be waiting behind. A record refused alone is not hurried back: it
    -- goes with the next flush, so a state the portal keeps refusing is not
    -- resent in a loop.
    log("error", "the portal refused a state report (" .. tostring(reply.code) .. "): " .. tostring(reply.reason))
    for _, key in ipairs(sent.keys) do
      local entry = records.entries[key]
      if entry then
        entry.alone = true
        entry.resync = true
        entry.recovering = #sent.keys > 1 or nil
      end
    end
    if #sent.keys > 1 then
      sync.flush()
    end
  end
end

-- Sending -------------------------------------------------------------------

---Sends one report frame, splitting the batch when the frame would be over
---the portal's frame limit. A single record too large to send is logged and
---left marked: it cannot be reported until it shrinks.
---@param tag "state_changed"|"resync" The frame type.
---@param entries rpf.records.Entry[] The records.
---@param build fun(entry: rpf.records.Entry): table The change or report for one.
---@param sent fun(entry: rpf.records.Entry, item: table) Marks one as reported, once the frame carrying `item` for it is queued.
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
      -- Nothing can carry it, so no hold waits for it.
      entries[1].recovering = nil
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
  inflight[id] = { keys = keys, transactions = transactions, whole = tag == "resync" }
  for i, entry in ipairs(entries) do
    sent(entry, items[i])
    if tag == "resync" then
      entry.awaiting = id
    end
  end
  return true
end

---Sends a list in batches of at most `max_records_per_frame`, and each
---record marked `alone` in a frame of its own.
---@param tag "state_changed"|"resync" The frame type.
---@param entries rpf.records.Entry[] The records.
---@param build fun(entry: rpf.records.Entry): table The change or report for one.
---@param sent fun(entry: rpf.records.Entry, item: table) Marks one as reported.
---@return boolean ok False if the outbox refused one.
local function send_all(tag, entries, build, sent)
  local size = sync.options.max_records_per_frame
  local batch = {}
  for _, entry in ipairs(entries) do
    if entry.alone then
      if not send_batch(tag, { entry }, build, sent) then
        return false
      end
    else
      batch[#batch + 1] = entry
      if #batch == size then
        if not send_batch(tag, batch, build, sent) then
          return false
        end
        batch = {}
      end
    end
  end
  return send_batch(tag, batch, build, sent)
end

---Marks the ledger entries a queued report carried as sent.
---@param entry rpf.records.Entry The record.
---@param item table The change or report queued for it.
local function mark_carried(entry, item)
  local carried = {}
  for _, tx in ipairs(item.transactions or {}) do
    carried[tx.client_id] = true
  end
  for _, tx in ipairs(entry.transactions) do
    if carried[tx.client_id] then
      tx.sent = true
    end
  end
end

---Settles a record whose whole report was queued. An account with more
---unacknowledged entries than the report carried stays marked: its next
---whole report goes once this one is answered.
---@param entry rpf.records.Entry The record.
---@param report table The report queued.
local function whole_sent(entry, report)
  entry.recovering = nil
  entry.revision = entry.revision + 1
  entry.changed = {}
  mark_carried(entry, report)
  entry.resync = #entry.transactions > #(report.transactions or {})
end

---Settles a record whose change was queued.
---@param entry rpf.records.Entry The record.
---@param change table The change queued.
local function change_sent(entry, change)
  entry.revision = entry.revision + 1
  entry.changed = {}
  mark_carried(entry, change)
  entry.more = false
  for _, tx in ipairs(entry.transactions) do
    if not tx.sent then
      entry.more = true
    end
  end
end

---Sends changes for every record matching a test, and then again for the
---accounts whose backlog one report did not empty, until none is left. Only a record the last pass moved on is tried again, so a record
---that cannot be sent at all is tried once per flush.
---@param test fun(entry: rpf.records.Entry): boolean Which records.
---@param build fun(entry: rpf.records.Entry): table The change for one.
---@param sent fun(entry: rpf.records.Entry, item: table) Settles one once queued, and sets `more` on it.
---@return boolean ok False if the outbox refused a frame.
local function send_changes(test, build, sent)
  local tag = "state_changed"
  local entries = select_entries(test)
  while #entries > 0 do
    for _, entry in ipairs(entries) do
      entry.more = nil
    end
    if not send_all(tag, entries, build, sent) then
      return false
    end
    entries = select_entries(function(entry)
      return entry.more == true and test(entry)
    end)
  end
  return true
end

---Reports everything marked: first the records the portal needs whole, then
---every changed one. Runs `flush_interval_ms` after a change, and at once
---when a reply asks for a resync. Whatever the outbox refuses stays marked,
---and another flush is scheduled.
---@return boolean ok False if the outbox refused a report, so something marked is still unreported.
function sync.flush()
  scheduled = false
  if not sync.connection then
    return false
  end
  -- One whole report per record at a time: see `full_report`.
  local ok = send_all(
    "resync",
    select_entries(function(entry)
      return entry.resync and not entry.awaiting
    end),
    full_report,
    whole_sent
  )
  if ok then
    ok = send_changes(function(entry)
      return not entry.resync and change_of(entry) ~= nil
    end, function(entry)
      return change_of(entry) --[[@as table]]
    end, change_sent)
  end
  if not ok then
    sync.schedule()
  end
  return ok
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

---The id a record is known by in a `held` reply.
---@param record table One of the reply's records.
---@return string key Its `records.key`.
local function held_key(record)
  local data = record.character or record.account or record.container
  return records.key(record.kind, data.id)
end

---Sends a hold now.
---
---A record released after the hold was sent, and not held again since, is
---not kept when the reply hands it over: the reply is from before that
---release, and the portal, which answers in order, has ended the hold. It
---is taken and released again at once instead, so that even if the portal
---answered the two out of order the record ends up held by neither side,
---never by this one alone.
---
---A hold for a player's session that the outbox refuses is kept, and sent
---again as the outbox drains, for as long as the player is here.
---@param hold rpf.sync.DeferredHold The hold.
local function send_hold(hold)
  local through, callback = hold.through, hold.callback
  local sent_at = releases
  local queued
  queued = sync.connection:send("hold", hold.fields, function(reply, err)
    if queued then
      holds_in_flight = holds_in_flight - 1
    end
    local views, why
    if reply and reply.type == "held" then
      local superseded = {}
      for _, record in ipairs(reply.records) do
        local key = held_key(record)
        if not records.entries[key] and (released_at[key] or 0) > sent_at then
          local data = record.character or record.account or record.container
          superseded[#superseded + 1] = { kind = record.kind, id = data.id }
        end
      end
      records.take(reply.records, through)
      if #superseded > 0 then
        local ok, why_not = sync.release(superseded)
        if not ok then
          log("error", "could not give back records released while their hold was in flight: " .. tostring(why_not))
        end
      end
      views = {}
      for _, record in ipairs(reply.records) do
        local data = record.character or record.account or record.container
        views[#views + 1] = records.get(record.kind, data.id)
      end
      events.emit("records.held", views)
      if through and not rpf.players.by_player_id(through) then
        -- They left while the hold was in flight: give it straight back.
        sync.release_through(through)
      end
    else
      why = reply and reply.code or err
      if why == "outbox_full" and through and rpf.players.by_player_id(through) then
        log("warn", "a player's hold could not be queued; trying again as the outbox drains")
        hold.mark = sync.connection.next_seq
        deferred[#deferred + 1] = hold
        return
      end
      log("warn", "a hold was refused (" .. tostring(why) .. ")")
    end
    if holds_in_flight == 0 then
      released_at = {}
    end
    if callback then
      callback(views, why)
    end
  end)
  if queued then
    holds_in_flight = holds_in_flight + 1
  end
end

---Sends every waiting hold that no longer has to wait: not while a
---declaration is owed on the current connection, not while a report or
---release queued before the hold was asked for is unanswered, and not while
---any `resync` is, which is such a report being recovered, or is still to
---be queued.
local function send_deferred()
  local connection = sync.connection
  if not connection or (declaration.pending and connection.state == "ready") then
    return
  end
  -- A `resync` counts whenever it was queued: it is the recovery of a report
  -- from before the hold, queued by that report's answer, and it carries
  -- what that report failed to land.
  local oldest, recovering
  for _, entry in ipairs(connection.outbox) do
    if sync.REPORT_FRAMES[entry.type] and (not oldest or entry.seq < oldest) then
      oldest = entry.seq
    end
    recovering = recovering or entry.type == "resync"
  end
  for _, entry in pairs(records.entries) do
    recovering = recovering or entry.recovering == true
  end
  local waiting = deferred
  deferred = {}
  for _, hold in ipairs(waiting) do
    if recovering or (oldest and oldest < hold.mark) then
      deferred[#deferred + 1] = hold
    else
      send_hold(hold)
    end
  end
end

---Asks the portal to hand records over. `owners` holds every live record
---each owner has on this server (not transitively: a character's own
---accounts are held through the character); `records` holds those named.
---
---Sent once every report and release already queued has been answered, so
---the records come back with everything this server has reported, and not
---while a declaration is owed on the current connection, so the
---declaration can never release it. The portal refuses the whole hold if any
---named record is not this server's to hold, exactly as if it did not exist.
---@param request { owners: table[]?, records: rpf.RecordRef[]? } What to hold.
---@param through string? The player whose session it is for, released when they leave.
---@param callback fun(views: table[]?, err: string?)? Called with copies of the records now held, or the refusal's code.
function sync.hold(request, through, callback)
  deferred[#deferred + 1] = {
    fields = { owners = request.owners or {}, records = request.records or {} },
    through = through,
    callback = callback,
    mark = sync.connection.next_seq,
  }
  send_deferred()
end

---Queues the release of some records, in one frame if it fits. A frame over
---the portal's frame limit is split in two and each half tried, so one
---large container cannot keep a whole session's records held; a single
---record too large to send at all stays held, and is logged. Records are
---forgotten only once the frame carrying their final state is queued.
---@param entries rpf.records.Entry[] The records, all held.
---@param callback fun(reply: table?, err: string?)? Called with the portal's answer to each frame.
---@param released rpf.RecordRef[] Collects the records let go.
---@return boolean? ok True if every one was queued.
---@return string? err Why not: the outbox's refusal, or `"too_large"`.
local function release_batch(entries, callback, released)
  local reports, refs = {}, {}
  for i, entry in ipairs(entries) do
    reports[i] = full_report(entry)
    refs[i] = { kind = entry.kind, id = entry.id }
  end
  local ok, id, err = pcall(sync.connection.send, sync.connection, "release", { records = reports }, callback)
  if not ok then
    if #entries == 1 then
      log("error", "cannot release " .. records.key(refs[1].kind, refs[1].id) .. ": " .. tostring(id))
      return nil, "too_large"
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
    -- Both halves are tried whatever the first does, so everything that can
    -- go does.
    local first_ok, first_err = release_batch(first, callback, released)
    local second_ok, second_err = release_batch(second, callback, released)
    if first_ok and second_ok then
      return true
    end
    return nil, first_err or second_err
  end
  if not id then
    return nil, err
  end
  releases = releases + 1
  for _, ref in ipairs(records.forget(refs)) do
    released[#released + 1] = ref
    if holds_in_flight > 0 then
      released_at[records.key(ref.kind, ref.id)] = releases
    end
  end
  return true
end

---Lets records go, reporting each whole as its final state. They are
---forgotten at once and announced with `records.released`; a record this
---server does not hold is ignored. A record whose final state cannot be
---queued whole (the outbox is full, it is too large for any frame, or it is
---an account with a backlog of unacknowledged ledger entries) is not
---released, because some of its final state would be lost: it stays held,
---and the call says so.
---
---Everything marked is flushed first, so a report naming a released record
---(another account's payment to it) reaches the portal ahead of the release,
---in order. If the outbox cannot take those reports, nothing is released.
---@param refs rpf.RecordRef[] The records.
---@param callback fun(reply: table?, err: string?)? Called with the portal's answer: once, unless the final states were over the frame limit together and went in several frames, when it is called for each.
---@return boolean? ok True if every held record named was released.
---@return string? err Why not: `"outbox_full"`, `"too_large"` for a record no frame can carry, or `"backlog"` for an account with more unacknowledged ledger entries than one report carries, which can be released once the portal has acknowledged enough of them. Records that could be queued were released all the same.
function sync.release(refs, callback)
  if not sync.flush() then
    -- A report that could not be queued may be a payment to one of these
    -- records. Released now, it could be held again before that payment
    -- lands, and handed back without it.
    return nil, "outbox_full"
  end
  local entries, seen, backlog = {}, {}, false
  for _, ref in ipairs(refs) do
    local key = records.key(ref.kind, ref.id)
    local entry = records.entries[key]
    if entry and not seen[key] then
      seen[key] = true
      if #entry.transactions > sync.options.max_transactions_per_report then
        -- Its final state would not carry every entry in doubt. The flush
        -- above sent them; it can go once enough are acknowledged.
        backlog = true
      else
        entries[#entries + 1] = entry
      end
    end
  end
  local released = {}
  if #entries > 0 then
    local ok, err = release_batch(entries, callback, released)
    if #released > 0 then
      events.emit("records.released", released)
    end
    if not ok then
      return nil, err
    end
  end
  if backlog then
    return nil, "backlog"
  end
  return true
end

---Releases everything held for one player's session. If some of it cannot
---be released now (the outbox is full, an account has a backlog), the player is remembered and the
---release tried again whenever a frame leaves the outbox, so a departed
---player's records are not left held for as long as the process runs.
---@param player_id string The player.
function sync.release_through(player_id)
  local refs = {}
  for _, entry in ipairs(select_entries(function(entry)
    return entry.through == player_id
  end)) do
    refs[#refs + 1] = { kind = entry.kind, id = entry.id }
  end
  local ok, err = sync.release(refs)
  if ok then
    departed[player_id] = nil
    return
  end
  if not departed[player_id] then
    log("error", "could not release a departing player's records (" .. tostring(err) .. "); trying again as the outbox drains")
  end
  departed[player_id] = true
end

---Holds a player's session records: everything their account owns on this
---server (their characters, and anything else they own), held for their
---session and released when they leave. Sent when they register, and again
---by `rpf.characters` when the portal says this server no longer holds some
---of them. Records already held keep the state they have here.
---
---Its answer is announced with `records.session(player_id, err)`: `err` is
---nil once the records are held, or the portal's refusal. A hold the
---outbox cannot take yet is tried again as it drains, and announced then.
---@param player_id string The player.
function sync.hold_session(player_id)
  sync.hold({ owners = { { kind = "player", id = player_id } } }, player_id, function(_, err)
    events.emit("records.session", player_id, err)
  end)
end

---Tries again to release the records of players who left while the outbox
---could not take their final state. A player who has come back keeps them:
---they are their session's records again.
function sync.retry_departures()
  local ids = {}
  for player_id in pairs(departed) do
    ids[#ids + 1] = player_id
  end
  table.sort(ids)
  for _, player_id in ipairs(ids) do
    if rpf.players.by_player_id(player_id) then
      departed[player_id] = nil
    else
      sync.release_through(player_id)
    end
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
  send_deferred()
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

---Whether a report that outlived a restart should be sent again rather than
---dropped. The records it was about are gone from memory with the old
---process, so it cannot be answered with a resync: the frame itself is all
---that is left of the change. The portal finds it stale when a report
---queued before it has not landed yet (that one was asked for again, and
---this one was answered first), and once that one lands this one applies as
---it is.
---
--- - While any report or release queued before it is still unanswered, it is
---   kept, however long that takes: what it waits for is still coming.
--- - With nothing before it left, it is sent again `orphan_retries` times
---   and then dropped: it is not waiting on anything, and a restart drops
---   everything unreported.
--- - One naming a record the portal says is not held here can never apply,
---   and is dropped at once.
---
---While it waits it stays in the outbox, so the declaration, which would
---release its record, waits for it too.
---@param client rpf.Client The connection.
---@param entry rpf.OutboxEntry The frame, which has no callback.
---@param frame rpf.Frame Its answer.
---@return boolean again True to keep it and send it again.
function sync.orphaned(client, entry, frame)
  if entry.type ~= "state_changed" or frame.type ~= "resync_required" then
    return false
  end
  local id = entry.id --[[@as string]]
  if #frame.released > 0 then
    orphan_tries[id] = nil
    log("warn", "a report from before the restart names a record no longer held here and is dropped")
    return false
  end
  for _, other in ipairs(client.outbox) do
    if other.seq < entry.seq and sync.REPORT_FRAMES[other.type] then
      return true
    end
  end
  orphan_tries[id] = (orphan_tries[id] or 0) + 1
  if orphan_tries[id] > sync.options.orphan_retries then
    orphan_tries[id] = nil
    log("warn", "a report from before the restart is stale with nothing before it left to land, and is dropped")
    return false
  end
  return true
end

---Called whenever a frame this server originated leaves the outbox: the
---declaration may be due, a hold may have nothing left to wait for, and a
---release that could not be queued may now go.
function sync.drained()
  sync.check_declaration()
  send_deferred()
  sync.retry_departures()
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
  departed = {}
  orphan_tries = {}
  releases = 0
  released_at = {}
  holds_in_flight = 0
  scheduled = false
  declaration = { pending = false, mark = 0 }
  records.reset()
  connection.on_ready = sync.connected
  connection.on_release = sync.drained
  connection.on_orphan = sync.orphaned
  events.on("players.registered", function(player)
    sync.hold_session(player.player_id)
  end)
  events.on("players.dropping", function(player)
    if player.player_id then
      sync.release_through(player.player_id)
    end
  end)
end

rpf.sync = sync
return sync
