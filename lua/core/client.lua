---The game server's connection to the portal: handshake, correlation, the
---outbox, and reconnecting.
---
---Everything the protocol promises about delivery is kept here:
---
--- - **Every frame except `Ack` waits in the outbox until a frame whose `re` is
---   its id arrives** (its reply, a `Rejected`, or an `Ack`). The outbox is
---   persisted through `kv_set`, one key per entry, so a restart does not lose
---   a state report and an enqueue writes only its own entry.
--- - **A resend reuses the frame's id.** After a reconnect every entry goes out
---   again byte for byte, which is what lets the portal's request log (C3)
---   recognise a retry instead of running it twice.
--- - **Near the end of the portal's retry window an entry is reissued or
---   dropped.** A reissuable one (a state report) goes out under a fresh id,
---   because its content is idempotent and losing it would lose money or
---   inventory. Anything else would be a second request, so it is dropped and
---   logged.
--- - **A host clock that goes back expires the outbox's requests.** Entries
---   are aged by the host clock, so a clock moved back would make every queued
---   frame look young, long enough for the portal to forget a request's id and
---   run it again. A persisted high-water mark of the clock catches the step,
---   and every non-reissuable entry queued before it is dropped as expired,
---   while reissuable ones are reissued under the new clock. A connection
---   whose `Hello` predates the step is made again before they are sent.
--- - **The outbox is bounded**, in entries and in persisted bytes. A frame that
---   does not fit is refused to its caller, never dropped behind its back, and
---   state reports and replies are never crowded out by requests.
--- - **A portal request runs at most once.** It is journalled in the outbox
---   before its handler runs, and the journal entry becomes the reply, so a
---   retried request, on the same connection or after a restart, gets the
---   original reply. A request whose handler started but never recorded an
---   outcome is answered `unknown`, never run again and never guessed at.
---   An unreadable slot count halts new work until the journal can be found.
--- - **Reconnects back off exponentially, plus random jitter**, so a portal
---   that went away without warning does not get every game server back in
---   the same second.
--- - **An announced restart is waited out, not backed off from.** The portal
---   sends `restarting` with a `retry_after_ms` before it closes a socket for
---   a deploy (H1). The next reconnect waits that long plus jitter, and the
---   backoff is not advanced: the portal chose the delay from how many
---   servers it is dropping, and a core that finds nothing listening yet
---   falls back to its own backoff from there.
---
---Every timer goes through the platform clock, so all of this runs instantly
---and deterministically under the mock.
---@class rpf.client
---@field OUTBOX_PREFIX string Each outbox entry is persisted under this prefix and its slot number.
---@field SLOTS_KEY string Where the highest slot number in use is persisted, so a load knows how far to look.
---@field ENTRY_HEADER string The first line of every persisted entry, naming its format.
---@field CLOCK_KEY string Where the highest host clock reading seen is persisted, so a step back while the process was down is caught at the next load.
---@field DEFAULTS rpf.ClientOptions The production timings and bounds, used for anything the caller leaves out.
local client = {}

local rpf = rpf
local json = rpf.json
local protocol = rpf.protocol
local config = rpf.config

local OUT = protocol.SERVER_TO_PORTAL
local IN = protocol.PORTAL_TO_SERVER

---What a request from the portal gets when no module has registered for it:
---a refusal the portal can record, rather than silence it would wait on.
---Nothing ran, so `failed` is the truth, not a guess.
---@type table<string, rpf.RequestHandler>
local FALLBACKS = {
  apply_command = function(frame, reply)
    reply("command_applied", {
      outcome = { outcome = "failed", reason = "this server has no handler for " .. frame.command.command },
    })
  end,
  config = function(_, reply)
    reply("config_applied", { outcome = { outcome = "failed", reason = "this server has no config handler" } })
  end,
}

---The reply to each kind of portal request when its handler started and the
---core cannot say what happened: a restart mid-handler, a handler that threw,
---or one that never replied. The effect may or may not have taken place, so
---the answer is `unknown`, never `failed` or `applied`.
---
---A request type with no entry here is never handed to a handler, because
---the core would have no honest answer for it after a crash. A new portal
---request lands with its entry.
---@type table<string, fun(reason: string): string, table>
local UNKNOWN = {
  apply_command = function(reason)
    return "command_applied", { outcome = { outcome = "unknown", reason = reason } }
  end,
  -- A config whose apply was cut off may or may not be stored; the next
  -- `Hello` names whichever is, so `unknown` is all the portal needs.
  config = function(reason)
    return "config_applied", { outcome = { outcome = "unknown", reason = reason } }
  end,
}

---Cuts a string to at most `limit` bytes without splitting a UTF-8 sequence.
---@param text string The string.
---@param limit integer The most bytes to keep.
---@return string clipped The string, or its longest prefix that fits.
local function clip(text, limit)
  if #text <= limit then
    return text
  end
  local stop = limit
  -- Back off while the byte after the cut continues a sequence (10xxxxxx).
  while stop > 0 do
    local next_byte = text:byte(stop + 1)
    if next_byte < 128 or next_byte >= 192 then
      break
    end
    stop = stop - 1
  end
  return text:sub(1, stop)
end

client.OUTBOX_PREFIX = "rpf.outbox."
client.SLOTS_KEY = "rpf.outbox.slots"
client.ENTRY_HEADER = "rpf.outbox.v1"
client.CLOCK_KEY = "rpf.outbox.clock"

---The longest `sent_at` `protocol.timestamp` writes, `2026-01-01T00:00:00.000Z`.
local MAX_SENT_AT = 24

---How many bytes a reissue could add to a frame. A reissue mints a new
---`sent_at`, and `protocol.timestamp` writes milliseconds only when there are
---any, so a frame first sent on a whole second grows by `.mmm` when reissued
---on a fractional one. Ids and the millisecond clock are fixed width. Every
---bound is checked with this added, so no reissue can take an entry past one.
---@param text string? The encoded frame, or nil for a pending request.
---@return integer growth The bytes to reserve.
local function reissue_growth(text)
  local sent_at = text and text:match('"sent_at":"([^"]*)"')
  if not sent_at then
    return 0
  end
  return math.max(0, MAX_SENT_AT - #sent_at)
end

---Timings and bounds for the connection. Every one has a production default;
---tests shrink them.
---@class rpf.ClientOptions
---@field backoff_base_ms number? The first reconnect delay, before jitter. Doubles on each failed attempt.
---@field backoff_max_ms number? The longest reconnect delay, before jitter.
---@field jitter number? The largest random extra, as a fraction of the delay: 0.5 adds up to half again. Applied to an announced restart's `retry_after_ms` too, which is what spreads the servers the portal dropped together.
---@field max_retry_after_ms number? The longest a `restarting` notice may hold the reconnect off. A longer `retry_after_ms` is clipped to it, so a portal cannot park a server for an hour by mistake.
---@field suspended_retry_ms number? How long to wait, before jitter, after the portal refuses `Hello` because this server's community is suspended (H5), before trying again. Long, because a suspension is lifted by a person, and finite, so a lifted one needs no restart.
---@field retry_window_ms number? The window the portal promises to remember a request id for (C3's `RETRY_WINDOW`; it keeps them longer), which is how old an entry may get before it is reissued or dropped.
---@field window_margin_ms number? How long before the window closes an entry is dealt with, to cover clock drift between the hosts and a frame still in flight.
---@field sweep_interval_ms number? How often the outbox is checked against the window, and running requests against their timeout.
---@field clock_step_tolerance_ms number? How far the host clock may go back, below the highest reading seen, before the outbox treats it as a step and expires its requests (`observe_clock`). Below the portal's `SENT_AT_TOLERANCE` (60 s), so a frame stamped before a step the portal would read as from the future is reissued or expired here rather than refused. It must stay far below `retry_window_ms`: a regress under it goes unnoticed, and the portal's retention margin covers only regresses under one window.
---@field seen_limit integer? How many inbound frame ids are remembered to recognise a duplicate.
---@field max_frame_bytes integer? The largest encoded frame `send` accepts. Mirrors the portal's `limits::MAX_FRAME_BYTES`, which refuses anything larger, so queueing one would only fill the outbox with a frame that can never be delivered.
---@field max_entries integer? How many frames this server originates (notices, state reports, requests) may wait in the outbox at once.
---@field max_bytes integer? How many persisted bytes those frames may take.
---@field request_share number? The fraction of `max_entries` and `max_bytes` that non-reissuable requests may use, so a pile of joins during an outage cannot crowd out state reports.
---@field max_requests integer? How many portal requests may be journalled at once: running, or answered and waiting for the portal's `Ack`. Their replies have this budget to themselves. A `config` is never refused for it, because the portal never resends one; configs still count, and stay few (one per version the portal sent and has not acked).
---@field max_reply_bytes integer? The largest encoded reply to a portal request. With `max_requests` it bounds the replies' share of storage.
---@field max_reason_bytes integer? The longest free-text `reason` a command outcome carries. Longer ones are cut, so a verbose handler cannot push its reply past `max_reply_bytes`.
---@field request_timeout_ms number? How long a portal request's handler may run before it is answered `unknown`, so a handler that never replies cannot hold a journal slot, or the portal, forever.
client.DEFAULTS = {
  backoff_base_ms = 1000,
  backoff_max_ms = 60 * 1000,
  jitter = 0.5,
  max_retry_after_ms = 5 * 60 * 1000,
  suspended_retry_ms = 5 * 60 * 1000,
  retry_window_ms = 7 * 24 * 60 * 60 * 1000,
  window_margin_ms = 12 * 60 * 60 * 1000,
  sweep_interval_ms = 60 * 1000,
  clock_step_tolerance_ms = 30 * 1000,
  seen_limit = 1024,
  max_frame_bytes = 1024 * 1024,
  max_entries = 2048,
  max_bytes = 8 * 1024 * 1024,
  request_share = 0.5,
  max_requests = 64,
  max_reply_bytes = 8 * 1024,
  max_reason_bytes = 1024,
  request_timeout_ms = 5 * 60 * 1000,
}

---One outbox entry: a frame waiting for its answer, or a portal request
---whose handler has not yet recorded an outcome. The encoded text is kept,
---not the Lua table, so a resend is the same bytes.
---@class rpf.OutboxEntry
---@field slot integer Where it is persisted: under `OUTBOX_PREFIX .. slot`.
---@field seq integer Its place in send order. Only ever grows, so a load can restore the order without an index.
---@field id string? The frame's envelope id, which its answer names in `re`. Nil while it is a pending request.
---@field type string The message type, so the entry can be classified without decoding. For a pending request, the request's type.
---@field text string? The encoded frame, sent unchanged on every resend. Nil while it is a pending request.
---@field sent_ms number When the envelope was minted, by the platform clock. Its age decides reissue or drop. For a pending request, when the request arrived.
---@field request string? The portal request this entry journals, by the request's id: pending until its handler replies, then the reply. Nil for a frame this server originated.
---@field bytes integer What it counts against the byte bounds: its persisted size plus what a reissue could add (`reissue_growth`), so a reissue never takes it past what was checked.
---@field retries integer? How many times the portal has asked for it again with a retryable code, for the backoff.

---Handles one kind of request from the portal. It must call `reply` exactly
---once, now or later; a second call is ignored.
---@alias rpf.RequestHandler fun(frame: rpf.Frame, reply: fun(tag: string, fields: table?))

---Called once with a frame's answer, or with an error if it never got one:
---`"expired"` when the retry window closed on it, `"outbox_full"` when it
---was refused at `send`.
---@alias rpf.ReplyCallback fun(reply: rpf.Frame?, err: string?)

---What to construct a connection with.
---@class rpf.ClientConfig
---@field url string The portal's websocket url.
---@field api_key string The API key (C2). A secret: never logged.
---@field instance_id string This process's instance id.
---@field options rpf.ClientOptions? Timing and bound overrides.

---A running connection to the portal.
---@class rpf.Client
---@field platform rpf.ServerPlatform The platform.
---@field url string The portal's websocket url.
---@field api_key string The API key. A secret: never logged.
---@field instance_id string Minted per process start and sent in every `Hello`, so the portal can tell a reconnect from a second host sharing the key.
---@field options rpf.ClientOptions The timings and bounds, defaults filled in.
---@field state "idle"|"connecting"|"handshaking"|"ready"|"stopped" Where the connection is. Frames are sent only when `ready`.
---@field server_id string? This server's id, as the portal named it in `Welcome`.
---@field stopped_reason string? Why the connection stopped for good, when it did.
---@field outbox rpf.OutboxEntry[] Frames awaiting an answer, in `seq` order. Pending requests are not here: they have no frame yet.
---@field requests table<string, rpf.OutboxEntry> Journalled portal requests by request id, pending or answered.
---@field request_count integer How many entries `requests` holds, against `max_requests` (which a `config` may go past).
---@field origin_count integer How many entries this server originated, against `max_entries`.
---@field origin_bytes integer Their persisted size, against `max_bytes`.
---@field slots table<integer, rpf.OutboxEntry> Every entry by the slot it is persisted in.
---@field free integer[] Slots below `high_slot` that hold nothing, to reuse.
---@field high_slot integer The highest slot number ever handed out, as persisted under `SLOTS_KEY`.
---@field next_seq integer The `seq` the next entry gets.
---@field full_logged boolean Whether a refusal has been logged since the outbox last had room, so a noisy caller does not flood the log.
---@field recovery_failed boolean An unreadable slot count makes the full journal unknowable; new work is refused until the store is repaired and the core restarts.
---@field clock_mark number? The highest host clock reading seen, carried across restarts through `CLOCK_KEY`. A reading far enough below it is a step back. Nil until the outbox is loaded, and for good while recovery has failed.
---@field clock_stored number? The mark as last persisted, so it is written only when it has moved.
---@field attempt integer Reconnect attempts since the last `Welcome`, for the backoff.
---@field retry_after_ms number? What the portal's `restarting` notice asked the next reconnect to wait, already clipped, in place of the backoff. Cleared once used, and on a `Welcome`.
---@field generation integer Bumped on every connect, so callbacks and timers from an older connection are ignored.
---@field hello_id string? The id of this connection's `Hello`, whose answer completes the handshake.
---@field callbacks table<string, rpf.ReplyCallback> Callbacks by frame id. In memory only, so they do not survive a restart; the entries do.
---@field handlers table<string, rpf.RequestHandler> Handlers for requests from the portal, by type.
---@field listeners table<string, rpf.NoticeListener[]> Listeners for the portal's notices, by type, in registration order. See `listen`.
---@field seen table<string, true> Recently received frame ids, to recognise a duplicate.
---@field seen_order string[] The same ids, oldest first, to evict from.
---@field on_ready fun(client: rpf.Client)? Called after each `Welcome`, once the outbox is flushed.
---@field on_orphan (fun(client: rpf.Client, entry: rpf.OutboxEntry, frame: rpf.Frame): boolean?)? Called with a final answer to a frame that has no callback, which after a restart is every frame the old process queued: the entry outlived whatever would have acted on its answer. Returning true keeps the entry and resends it under the same id after a backoff, as a retryable refusal does; `entry.retries` counts how often. `rpf.sync` uses it for a report the portal found stale only because the report before it has not landed yet.
---@field on_release fun(client: rpf.Client, entry: rpf.OutboxEntry)? Called after any frame this server originated leaves the outbox, answered or dropped, once its callback has run. `rpf.sync` uses it to see the outbox drain, which callbacks alone cannot show after a restart, when the entries outlived theirs.
local Client = {}
Client.__index = Client

---What is wrong with where an adapter was told to connect, in words an
---owner can act on, or nil if nothing the core can see is. Each adapter
---checks before it starts the core and names its own setting (`rpf_url`,
---`rpf_ws_url`, …) before the reason, because the core does not know what
---the engine calls it. A key that is well formed and wrong only the portal
---can refuse, as `unauthorised`.
---
---Neither value appears in what it returns: the url is the owner's own, but
---the key is a secret, and the two are reported alike.
---@param url string The portal's websocket address, as configured.
---@param api_key string The server's API key, as configured.
---@return ("url"|"api_key")? which The setting that is wrong.
---@return string? reason Why, and what it should look like.
function client.target_problem(url, api_key)
  if not url:match("^wss?://[^/%s]+") or url:match("%s") then
    return "url",
      "is not the portal's websocket address: it starts wss:// (ws:// only for a portal on this machine)"
        .. " and has no spaces, like wss://portal.example/ws"
  end
  if api_key:sub(1, 4) ~= "rpf_" or api_key:match("%s") then
    return "api_key",
      "does not look like a server API key, which starts rpf_ and has no spaces;"
        .. " copy it from the server's API keys page in the portal"
  end
  return nil
end

---Creates a connection, loading any outbox a previous process left behind.
---It does not connect until `start`.
---@param platform rpf.ServerPlatform The platform, already checked.
---@param settings rpf.ClientConfig Where to connect, as whom, and how fast.
---@return rpf.Client connection The connection, idle.
function client.new(platform, settings)
  local options = {}
  for key, value in pairs(client.DEFAULTS) do
    options[key] = value
  end
  for key, value in pairs(settings.options or {}) do
    options[key] = value
  end

  local self = setmetatable({
    platform = platform,
    url = settings.url,
    api_key = settings.api_key,
    instance_id = settings.instance_id,
    options = options,
    state = "idle",
    outbox = {},
    requests = {},
    request_count = 0,
    origin_count = 0,
    origin_bytes = 0,
    slots = {},
    free = {},
    high_slot = 0,
    next_seq = 1,
    full_logged = false,
    recovery_failed = false,
    attempt = 0,
    generation = 0,
    callbacks = {},
    handlers = {},
    listeners = {},
    seen = {},
    seen_order = {},
  }, Client)
  self:load_outbox()
  if not self.recovery_failed then
    self:load_clock()
  end
  return self
end

---Logs through the platform with the core's prefix.
---@param level "debug"|"info"|"warn"|"error" How much it matters.
---@param message string The line. Never a secret.
function Client:log(level, message)
  self.platform.log(level, "rpf: " .. message)
end

---Calls a callback or handler, so one that throws is logged rather than
---breaking the connection for every frame after it.
---@param what string What is being called, for the log.
---@param fn function The function.
---@param ... any Its arguments.
---@return boolean ok False if it threw.
function Client:call(what, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then
    self:log("error", what .. " failed: " .. tostring(err))
  end
  return ok
end

-- Outbox persistence --------------------------------------------------------
--
-- Each entry is its own key, `rpf.outbox.<slot>`, so adding, answering or
-- reissuing one entry writes that entry and nothing else, however full the
-- outbox is. A slot is reused once free, so the highest slot, persisted under
-- `rpf.outbox.slots`, never exceeds the most entries ever held at once, and a
-- load reads at most that many keys. Order comes from each entry's `seq`, so
-- there is no index to rewrite.
--
-- The persisted form is a few header lines and then the frame verbatim, not a
-- JSON wrapper around it: the frame is JSON already, and wrapping it would
-- escape every quote in it again, up to doubling its size, and make a load
-- parse every byte. The overhead is a fixed header of at most ~150 bytes.

---The persisted form of an entry: the header lines, then the frame.
---
---```
---rpf.outbox.v1
---<seq>
---<type>
---<id, or - while pending>
---<request id, or - for a frame this server originated>
---<sent_ms>
---<length of the frame in bytes>
---<the frame, verbatim>
---```
---@param entry rpf.OutboxEntry The entry.
---@return string stored What `kv_set` is given.
local function serialize(entry)
  local text = entry.text or ""
  return table.concat({
    client.ENTRY_HEADER,
    string.format("%.0f", entry.seq),
    entry.type,
    entry.id or "-",
    entry.request or "-",
    string.format("%.0f", entry.sent_ms),
    tostring(#text),
    text,
  }, "\n")
end

---Reads one persisted entry. Anything that is not exactly what `serialize`
---writes is refused: it could only have come from corruption, and sending
---bytes the core did not produce would be worse than losing them.
---@param raw string The stored value.
---@param slot integer The slot it was read from.
---@return rpf.OutboxEntry? entry The entry, or nil if it is unreadable.
local function deserialize(raw, slot)
  local header = "^" .. client.ENTRY_HEADER:gsub("%.", "%%.") .. "\n"
  local _, stop, seq, tag, id, request, sent_ms, length =
    raw:find(header .. "(%d+)\n([%w_]+)\n([^\n]+)\n([^\n]+)\n(%d+)\n(%d+)\n")
  if not stop then
    return nil
  end
  local text = raw:sub(stop + 1)
  if #text ~= tonumber(length) then
    return nil
  end
  local pending = id == "-"
  if pending and (request == "-" or #text ~= 0) or not pending and #text == 0 then
    return nil
  end
  return {
    slot = slot,
    seq = tonumber(seq) --[[@as integer]],
    type = tag,
    id = not pending and id or nil,
    request = request ~= "-" and request or nil,
    text = not pending and text or nil,
    sent_ms = tonumber(sent_ms) --[[@as number]],
    bytes = #raw + reissue_growth(text),
  }
end

---Persists an entry in its slot, replacing whatever the slot held, and keeps
---the byte count in step. One `kv_set`, so the slot holds either the old
---entry or the new one, never a mix: that is what makes a pending request
---turning into its reply a single step a crash cannot split.
---@param entry rpf.OutboxEntry The entry, with its slot.
function Client:write(entry)
  local stored = serialize(entry)
  local charge = #stored + reissue_growth(entry.text)
  if not entry.request then
    self.origin_bytes = self.origin_bytes - (entry.bytes or 0) + charge
  end
  entry.bytes = charge
  self.platform.kv_set(client.OUTBOX_PREFIX .. entry.slot, stored)
end

---Hands out a slot for a new entry, and its place in send order. A fresh slot
---is recorded under `SLOTS_KEY` before anything is written to it, so a load
---always looks far enough.
---@param entry rpf.OutboxEntry The entry, given `slot` and `seq` here.
function Client:place(entry)
  local slot = table.remove(self.free)
  if not slot then
    self.high_slot = self.high_slot + 1
    slot = self.high_slot
    self.platform.kv_set(client.SLOTS_KEY, tostring(self.high_slot))
  end
  entry.slot = slot
  entry.seq = self.next_seq
  self.next_seq = self.next_seq + 1
  self.slots[slot] = entry
end

---Deletes an entry's persisted form and frees its slot and its share of the
---bounds.
---@param entry rpf.OutboxEntry The entry.
function Client:erase(entry)
  self.platform.kv_set(client.OUTBOX_PREFIX .. entry.slot, nil)
  self.slots[entry.slot] = nil
  self.free[#self.free + 1] = entry.slot
  if entry.request then
    self.requests[entry.request] = nil
    self.request_count = self.request_count - 1
  else
    self.origin_count = self.origin_count - 1
    self.origin_bytes = self.origin_bytes - entry.bytes
  end
  self.full_logged = false
end

---The portal request type a journal entry of type `tag` belongs to: `tag`
---itself for a pending request, or the request a reply answers.
---@param tag string The stored entry's type.
---@return string? request_type The request's type, or nil if `tag` is neither.
local function request_type_for(tag)
  if UNKNOWN[tag] then
    return tag
  end
  for request_type, unknown in pairs(UNKNOWN) do
    if (unknown("")) == tag then
      return request_type
    end
  end
  return nil
end

---Deals with a slot that does not parse, failing closed for portal requests.
---
---If the header still names a portal request, that request may already have
---run, and the slot was the only durable record of it. Its id is remembered
---so a resend cannot run it again, and, when its type is known, the slot is
---taken over as a pending request, which the load answers `unknown`.
---Anything else is logged as lost and left in its slot, out of `free`, so the
---bytes stay for a human rather than being overwritten by the next send.
---@param raw string The stored value.
---@param slot integer Its slot.
---@return rpf.OutboxEntry? pending A pending request to answer `unknown`, if one could be recovered.
function Client:salvage(raw, slot)
  local header, tag, request = raw:match("^([^\n]*)\n[^\n]*\n([^\n]*)\n[^\n]*\n([^\n]*)\n")
  local recognised = header == client.ENTRY_HEADER
    and request
    and request:find("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$")
  if not recognised then
    self:log("error", "the stored outbox entry in slot " .. slot .. " is unreadable; whatever it held is lost")
    return nil
  end
  self:remember(request)
  local request_type = request_type_for(tag)
  if not request_type then
    self:log("error", "the stored outbox entry in slot " .. slot .. " is unreadable; request " .. request .. " will not be run")
    return nil
  end
  self:log("error", "the stored outbox entry in slot " .. slot .. " is unreadable; answering request " .. request .. " as unknown")
  ---@type rpf.OutboxEntry
  local entry = { slot = slot, seq = 0, type = request_type, request = request, sent_ms = self.platform.now(), bytes = 0 }
  self.slots[slot] = entry
  self.requests[request] = entry
  self.request_count = self.request_count + 1
  return entry
end

---Reads the persisted outbox. An unreadable entry is logged and handled by
---`salvage`. Every journalled request id is remembered, so a resend that
---arrives after the portal acks its reply is ignored, as it would be had the
---request first arrived in this process. A pending request, one whose handler started in an
---earlier process and never recorded an outcome, is answered `unknown` here,
---before anything is sent: the effect may or may not have happened, and
---running the handler again could do it twice.
---
---Entries are loaded even beyond the current bounds (after the bounds were
---lowered, say), because dropping them would lose state. New frames are
---refused until it drains.
function Client:load_outbox()
  local raw_high = self.platform.kv_get(client.SLOTS_KEY)
  local high = raw_high and tonumber(raw_high)
  if raw_high and not (high and high >= 0 and high % 1 == 0) then
    -- The old bounds may have admitted entries beyond the current ones. No
    -- finite scan based on today's options can prove that a command was not
    -- already journalled there. Keep the damaged key for repair and refuse
    -- new work, including writes that might reuse an unseen slot.
    self.recovery_failed = true
    self:log("error", "the stored outbox slot count is unreadable; refusing new work until storage is repaired and the core restarts")
    return
  end
  high = high or 0

  local pending = {}
  local highest = 0
  for slot = 1, high do
    local raw = self.platform.kv_get(client.OUTBOX_PREFIX .. slot)
    if raw ~= nil then
      local entry = deserialize(raw, slot)
      if entry then
        highest = slot
        self.slots[slot] = entry
        if entry.seq >= self.next_seq then
          self.next_seq = entry.seq + 1
        end
        if entry.request then
          self.requests[entry.request] = entry
          self.request_count = self.request_count + 1
          self:remember(entry.request)
        else
          self.origin_count = self.origin_count + 1
          self.origin_bytes = self.origin_bytes + entry.bytes
        end
        if entry.text then
          self.outbox[#self.outbox + 1] = entry
        else
          pending[#pending + 1] = entry
        end
      else
        highest = slot
        local salvaged = self:salvage(raw, slot)
        if salvaged then
          pending[#pending + 1] = salvaged
        end
      end
    end
  end
  for slot = 1, highest do
    if self.slots[slot] == nil and self.platform.kv_get(client.OUTBOX_PREFIX .. slot) == nil then
      self.free[#self.free + 1] = slot
    end
  end
  self.high_slot = highest
  if highest ~= high then
    self.platform.kv_set(client.SLOTS_KEY, highest > 0 and tostring(highest) or nil)
  end
  table.sort(self.outbox, function(a, b)
    return a.seq < b.seq
  end)
  table.sort(pending, function(a, b)
    return a.seq < b.seq
  end)
  for _, entry in ipairs(pending) do
    if UNKNOWN[entry.type] then
      self:log("warn", entry.type .. " " .. entry.request .. " was interrupted by a restart; answering it as unknown")
      self:settle_unknown(entry, "the game server restarted while applying it")
    else
      -- Only a request with an `unknown` reply is ever journalled, so this is
      -- storage from another version. It cannot be answered honestly here.
      self:log("error", "discarding a stored " .. entry.type .. " this core cannot answer")
      self:erase(entry)
    end
  end
end

---Finds an outbox entry by its frame id.
---@param id string The frame id.
---@return integer? index Its position, or nil if it is not waiting.
function Client:find(id)
  for i, entry in ipairs(self.outbox) do
    if entry.id == id then
      return i
    end
  end
  return nil
end

---Takes an entry out of the outbox and hands its callback the outcome.
---@param index integer The entry's position.
---@param reply rpf.Frame? The answer, if there was one.
---@param err string? Why there was none.
function Client:release(index, reply, err)
  local entry = table.remove(self.outbox, index)
  self:erase(entry)
  local callback = self.callbacks[entry.id]
  self.callbacks[entry.id] = nil
  if callback then
    self:call("the callback for " .. entry.type, callback, reply, err)
  end
  if self.on_release then
    self:call("on_release", self.on_release, self, entry)
  end
end

-- The host clock going back -------------------------------------------------
--
-- Entries are aged by the host clock, and so is `sent_at`, which the portal
-- reads against the offset it measured at the current connection's `Hello`.
-- A clock moved back (a VM restored from a snapshot whose clock ran fast, a
-- host that booted with a bad clock and synced later) makes every queued
-- frame look younger by the step. The portal keeps request ids for twice the
-- retry window, which covers a step under one window; past that, a request
-- resent under its old id could arrive after its id was forgotten and run
-- twice. Neither side can tell from timestamps alone, so the outbox keeps the
-- highest reading it has seen, persisted, and treats a reading well below it
-- as a step.

---Persists the clock's high-water mark if it has moved since it was last
---written. Called from the sweep, at load, and when a step is caught, never
---on an ordinary `send`, so an enqueue still writes only its own entry, and
---the mark costs at most one write per `sweep_interval_ms`.
---
---So the stored mark can trail the newest entry's stamp by a whole sweep
---interval, twice the tolerance. `load_clock` closes that gap by raising the
---mark to the newest stamp it loads, which costs no write. What a crash can
---still lose is the mark's movement past the newest entry, and a step missed
---that way had nothing queued before it to misdate.
---
---Never while recovery has failed: the stored mark could not be read
---(`load_clock` did not run), and overwriting it with a lower one would hide
---a step from the process that runs once storage is repaired.
function Client:store_clock()
  if self.recovery_failed then
    return
  end
  local mark = self.clock_mark
  if mark and mark ~= self.clock_stored then
    self.platform.kv_set(client.CLOCK_KEY, string.format("%.0f", mark))
    self.clock_stored = mark
  end
end

---Reads the persisted high-water mark and checks the clock against it, so a
---step back taken while the process was down is caught before anything is
---sent. A mark that does not parse is treated as a step of unknown size:
---the outbox can no longer prove its requests are younger than they look,
---and expiring them is the side that cannot run one twice.
---
---Every loaded entry's stamp is a reading the clock really gave, so the mark
---is raised to the newest of them: the stored mark only moves with the sweep
---and may trail them by `sweep_interval_ms` (see `store_clock`).
function Client:load_clock()
  local raw = self.platform.kv_get(client.CLOCK_KEY)
  if raw ~= nil then
    local mark = type(raw) == "string" and raw:find("^%d+$") and tonumber(raw)
    if not mark then
      self:log("error", "the stored clock high-water mark is unreadable; treating it as a step back")
      self:clock_stepped_back(self.platform.now(), nil)
      return
    end
    self.clock_mark = mark
    self.clock_stored = mark
  end
  for _, entry in pairs(self.slots) do
    if not self.clock_mark or entry.sent_ms > self.clock_mark then
      self.clock_mark = entry.sent_ms
    end
  end
  self:observe_clock()
  self:store_clock()
end

---Reads the host clock and checks it against the highest reading seen. A
---reading more than `clock_step_tolerance_ms` below it is a step back, and
---the outbox is dealt with by `clock_stepped_back`; otherwise the mark moves
---up to the reading. A regress under the tolerance is left alone, but the
---mark stays where it was, so several small steps add up until they cross it.
---
---Called before anything is stamped with the clock (`send`, the sweep, the
---load), so every entry in the outbox when a step is caught was queued before
---it. Does nothing while recovery has failed: the outbox is empty, and the
---stored mark was never read, so there is nothing to compare against (see
---`store_clock`).
---@return boolean stepped Whether a step back was found.
function Client:observe_clock()
  if self.recovery_failed then
    return false
  end
  local now = self.platform.now()
  local mark = self.clock_mark
  if mark and now < mark - self.options.clock_step_tolerance_ms then
    self:clock_stepped_back(now, mark - now)
    return true
  end
  if not mark or now > mark then
    self.clock_mark = now
  end
  return false
end

---Deals with every outbox entry after the host clock went back.
---
---Every entry was stamped before the step, so its true age is unknown: at
---least what it looks like, plus the step. A non-reissuable entry is
---dropped, logged, and its callback called with `nil, "expired"`, exactly as
---when the retry window closes on it: resending it under its old id is the
---one thing that could run it twice. A reissuable one is reissued under a
---fresh id and `sent_at` from the new clock, because its content is safe to
---run twice and losing it would lose state, and because its old `sent_at`
---would otherwise look to the portal as if it came from the future. A
---portal request still running has its timeout restarted from now, so the
---step does not keep its journal slot for as long as the step was.
---
---The mark is reset to now before any callback runs, so a callback that
---sends is not taken for a second step, and only the entries held when the
---step was caught are touched.
---
---A connection whose `Hello` has gone out is dropped and made again
---(`reconnect`), before anything is reissued. The portal reads `sent_at`
---against the offset it measured at that `Hello`, under the old clock, so a
---frame stamped by the new one would look older by the step there: past a
---window, `expired`, reissued, and refused again, round and round. Nothing
---is sent on the old connection; the reissued frames, and anything a
---callback sends from here, go out once, in the flush after the next
---`Welcome`, read against an offset the new clock gave.
---@param now number The clock reading that showed the step.
---@param step number? How far back it went, or nil if unknown.
function Client:clock_stepped_back(now, step)
  self.clock_mark = now
  self:store_clock()
  if self.state == "ready" or self.state == "handshaking" then
    self:reconnect("the host clock went back")
  end

  local reissued, doomed = 0, {}
  for _, entry in ipairs(self.outbox) do
    if protocol.reissuable(OUT, entry.type) then
      self:reissue(entry)
      reissued = reissued + 1
    else
      doomed[#doomed + 1] = entry.id
    end
  end
  for _, entry in pairs(self.requests) do
    if not entry.text and entry.sent_ms > now then
      entry.sent_ms = now
    end
  end

  self:log(
    "warn",
    "the host clock went back "
      .. (step and ("by " .. math.floor(step) .. " ms") or "by an unknown amount")
      .. "; expiring "
      .. #doomed
      .. " queued requests and reissuing "
      .. reissued
      .. " frames, because the portal may have forgotten their ids"
  )
  for _, id in ipairs(doomed) do
    local index = self:find(id)
    if index then
      local entry = self.outbox[index]
      self:log("warn", "dropping " .. entry.type .. " " .. id .. ": queued before the host clock went back")
      self:release(index, nil, "expired")
    end
  end
end

-- Connecting ----------------------------------------------------------------

---Starts connecting, and starts the timer that checks the outbox against the
---retry window. Calling it twice does nothing.
function Client:start()
  if self.state ~= "idle" then
    return
  end
  self:schedule_sweep()
  self:connect()
end

---Stops for good: no reconnect, no more timers acting. The outbox stays
---persisted, so a later process picks it up.
---@param reason string Why, for `stopped_reason` and the log.
function Client:stop(reason)
  self.state = "stopped"
  self.stopped_reason = reason
  self.generation = self.generation + 1
  self:log("error", "stopped: " .. reason)
end

---Opens a new connection. Callbacks from any earlier one are ignored from
---here on, which is what makes the lack of a cancel harmless.
function Client:connect()
  self.generation = self.generation + 1
  local generation = self.generation
  self.state = "connecting"
  self.hello_id = nil
  self.platform.connect(self.url, {
    open = function()
      if generation == self.generation then
        self:handshake(generation)
      end
    end,
    message = function(text)
      if generation == self.generation then
        self:receive(text)
      end
    end,
    close = function(reason)
      if generation == self.generation then
        self:closed(reason)
      end
    end,
  })
end

---A random number in [0, 1) from the platform's randomness, for jitter.
---@return number fraction The number.
function Client:random_fraction()
  local hex = self.platform.random_hex(8)
  return (tonumber(hex, 16) or 0) / 4294967296
end

---How long to wait before attempt number `attempt`: the base doubled per
---attempt, capped, plus up to `jitter` of that again at random. The jitter is
---added on top rather than replacing the delay, so even an unlucky server
---still backs off.
---@param attempt integer How many attempts have failed, from 0.
---@return number delay_ms The delay.
function Client:backoff(attempt)
  local o = self.options
  local delay = math.min(o.backoff_max_ms, o.backoff_base_ms * 2 ^ attempt)
  return delay + delay * o.jitter * self:random_fraction()
end

---The connection ended. Unless stopped, try again: after the delay an
---announced restart asked for, plus jitter, or else after a backoff.
---@param reason string What the platform said.
function Client:closed(reason)
  if self.state == "stopped" then
    return
  end
  local delay
  if self.retry_after_ms then
    -- The portal said it was going: not a failure, so the backoff stays
    -- where it is for the attempts that follow if it is not back in time.
    local asked = self.retry_after_ms
    self.retry_after_ms = nil
    delay = asked + asked * self.options.jitter * self:random_fraction()
  else
    delay = self:backoff(self.attempt)
    self.attempt = self.attempt + 1
  end
  self.state = "connecting"
  self.generation = self.generation + 1
  local generation = self.generation
  self:log("warn", "disconnected (" .. tostring(reason) .. "); reconnecting in " .. math.floor(delay) .. " ms")
  self.platform.after(delay, function()
    if generation == self.generation then
      self:connect()
    end
  end)
end

---Drops the current connection and connects again, through `closed` and its
---backoff, as if the socket had gone down. Its generation is moved on first,
---so nothing the old socket delivers afterwards, its close included, is
---acted on, and the outbox goes out only on the new one.
---@param reason string Why, for the log.
function Client:reconnect(reason)
  self.generation = self.generation + 1
  self.platform.disconnect()
  self:closed(reason)
end

---Sends this connection's `Hello`. It is minted fresh for each connection and
---never enters the outbox, because it only means anything on the connection
---it opens. If the platform refuses it, the connection is given up at once
---and retried after a backoff, rather than left to be noticed dead later.
---@param generation integer The connection it belongs to.
function Client:handshake(generation)
  if generation ~= self.generation then
    return
  end
  self.state = "handshaking"
  local version, hash = config.load(self.platform)
  local hello = protocol.envelope(self.platform, "hello", {
    protocol = protocol.VERSION,
    api_key = self.api_key,
    instance_id = self.instance_id,
    engine = self.platform.engine,
    core_version = rpf.VERSION,
    config_version = version,
    config_hash = hash,
  })
  local text, err = protocol.encode(OUT, hello)
  if not text then
    self:stop("could not encode Hello: " .. tostring(err))
    return
  end
  self.hello_id = hello.id
  if not self.platform.send(text) then
    -- A Hello that never left cannot be answered; waiting for the socket
    -- to be noticed dead would only delay the same retry.
    self:reconnect("could not send Hello")
  end
end

-- Sending -------------------------------------------------------------------

---Whether a message type is a reply, which only a request's `reply` may
---send, so that every reply is journalled against the request it answers.
---@param tag string The message type.
---@return boolean reply True if the type carries `re`.
local function is_reply(tag)
  local spec = protocol.messages[OUT][tag]
  if not spec then
    return false
  end
  for _, field in ipairs(spec.fields) do
    if field[1] == "re" then
      return true
    end
  end
  return false
end

---Whether a new frame this server originates fits in the outbox.
---
---A reissuable frame (a state report) may use the whole budget. Anything else
---may use only `request_share` of it, so requests that pile up during an
---outage leave room for the reports that must not be lost. Replies to portal
---requests are not counted here at all: they have `max_requests` to
---themselves, so no amount of either can crowd out the other.
---@param tag string The message type.
---@param bytes integer The entry's persisted size.
---@return boolean room True if it fits.
function Client:has_room(tag, bytes)
  local o = self.options
  local entries, budget = o.max_entries, o.max_bytes
  if not protocol.reissuable(OUT, tag) then
    entries = math.floor(entries * o.request_share)
    budget = math.floor(budget * o.request_share)
  end
  return self.origin_count < entries and self.origin_bytes + bytes <= budget
end

---Sends a frame to the portal, and keeps it in the outbox until it is
---answered. If the connection is not ready it waits there, and goes out after
---the next `Welcome`.
---
---When the outbox is full the frame is refused, not queued, and the caller is
---told: `send` returns nil and `"outbox_full"`, and the callback, if any, is
---called with the same. Nothing is dropped to make room, and a refused state
---report is the caller's to keep and send again (a later report supersedes
---it anyway, by its revision).
---@param tag string The message type. Not `hello`, which the connection owns, not `ack`, which is never queued, and not a reply, which goes through a request's `reply`.
---@param fields table? The message's own fields.
---@param callback rpf.ReplyCallback? Called once with the answer: the reply, a `Rejected`, or the `Ack`. Called with an error instead if the frame is refused or dropped unanswered.
---@return string? id The frame's id, which its answer will name in `re`, or nil if refused.
---@return string? err `"outbox_full"` at capacity, or `"outbox_unavailable"` if journal recovery failed.
function Client:send(tag, fields, callback)
  if tag == "hello" or tag == "ack" then
    error("rpf: " .. tag .. " is sent by the connection itself", 2)
  end
  if is_reply(tag) then
    error("rpf: " .. tag .. " is a reply, sent through the request handler's reply function", 2)
  end
  if self.recovery_failed then
    if callback then
      self:call("the callback for " .. tag, callback, nil, "outbox_unavailable")
    end
    return nil, "outbox_unavailable"
  end
  -- Before the new frame is stamped, so a step back is caught while every
  -- entry it touches predates it.
  self:observe_clock()
  local frame = protocol.envelope(self.platform, tag, fields)
  local text, err = protocol.encode(OUT, frame)
  if not text then
    error("rpf: cannot send " .. tostring(tag) .. ": " .. tostring(err), 2)
  end
  if #text + reissue_growth(text) > self.options.max_frame_bytes then
    error(
      "rpf: cannot send "
        .. tag
        .. ": "
        .. #text
        .. " bytes is over the portal's frame limit of "
        .. self.options.max_frame_bytes,
      2
    )
  end
  ---@type rpf.OutboxEntry
  local entry = {
    seq = self.next_seq,
    slot = 0,
    id = frame.id,
    type = tag,
    text = text,
    sent_ms = self.platform.now(),
    bytes = 0,
  }
  local size = #serialize(entry) + reissue_growth(text)
  if not self:has_room(tag, size) then
    if not self.full_logged then
      self.full_logged = true
      self:log(
        "warn",
        "the outbox is full ("
          .. self.origin_count
          .. " frames, "
          .. self.origin_bytes
          .. " bytes); refusing "
          .. tag
          .. " and anything else that does not fit until the portal answers some"
      )
    end
    if callback then
      self:call("the callback for " .. tag, callback, nil, "outbox_full")
    end
    return nil, "outbox_full"
  end
  self:place(entry)
  self.origin_count = self.origin_count + 1
  self:write(entry)
  self.outbox[#self.outbox + 1] = entry
  if callback then
    self.callbacks[frame.id] = callback
  end
  if self.state == "ready" then
    self.platform.send(text)
  end
  return frame.id, nil
end

---Acknowledges a portal frame. Acks never enter the outbox: a lost one is
---sent again when the portal resends the frame it answers.
---@param re string The id of the frame being acknowledged.
function Client:ack(re)
  local frame = protocol.envelope(self.platform, "ack", { re = re })
  local text = protocol.encode(OUT, frame)
  if text then
    self.platform.send(text)
  end
end

---Sends every waiting frame, oldest first, each under its original id.
function Client:flush()
  for _, entry in ipairs(self.outbox) do
    self.platform.send(entry.text)
  end
end

---Re-sends one entry under a fresh id and `sent_at`, keeping its content,
---its callback and the request it answers. Only for reissuable frames: see
---`sweep`. Persisted here, one entry.
---@param entry rpf.OutboxEntry The entry, changed in place.
function Client:reissue(entry)
  local frame, err = protocol.decode(OUT, entry.text)
  if not frame then
    self:log("error", "could not reissue " .. entry.type .. ": " .. tostring(err))
    return
  end
  local fresh = protocol.envelope(self.platform, entry.type, frame)
  local text = protocol.encode(OUT, fresh)
  if not text then
    return
  end
  self:log("info", "reissuing " .. entry.type .. " " .. tostring(entry.id) .. " as " .. fresh.id)
  self.callbacks[fresh.id] = self.callbacks[entry.id]
  self.callbacks[entry.id] = nil
  entry.id = fresh.id
  entry.text = text
  entry.sent_ms = self.platform.now()
  entry.retries = nil
  self:write(entry)
end

---Deals with every entry that is nearly as old as the portal's retry window:
---a reissuable one is reissued, anything else is dropped and logged. Then
---answers `unknown` for any portal request whose handler has run past
---`request_timeout_ms` without replying.
---
---Past the window the portal may have forgotten the id, so resending under it
---could run a request twice. A reissuable frame is safe to run twice by its
---content, so it goes out fresh; for anything else, dropping it is the only
---way to be sure it does not happen twice.
---
---The clock is checked for a step back first (`observe_clock`), and its
---high-water mark persisted at the end.
---@return boolean changed Whether any entry was reissued, dropped or settled.
function Client:sweep()
  local changed = self:observe_clock()
  local now = self.platform.now()
  local limit = self.options.retry_window_ms - self.options.window_margin_ms
  local i = 1
  while i <= #self.outbox do
    local entry = self.outbox[i]
    if now - entry.sent_ms >= limit then
      changed = true
      if protocol.reissuable(OUT, entry.type) then
        self:reissue(entry)
        if self.state == "ready" then
          self.platform.send(entry.text)
        end
        i = i + 1
      else
        self:log(
          "warn",
          "dropping "
            .. entry.type
            .. " "
            .. tostring(entry.id)
            .. ": unanswered for as long as the portal remembers requests"
        )
        self:release(i, nil, "expired")
      end
    else
      i = i + 1
    end
  end

  local overdue = {}
  for _, entry in pairs(self.requests) do
    if not entry.text and now - entry.sent_ms >= self.options.request_timeout_ms then
      overdue[#overdue + 1] = entry
    end
  end
  table.sort(overdue, function(a, b)
    return a.seq < b.seq
  end)
  for _, entry in ipairs(overdue) do
    changed = true
    self:log("warn", "the handler for " .. entry.type .. " " .. entry.request .. " has not replied; answering it as unknown")
    self:settle_unknown(entry, "the game server's handler did not report an outcome in time")
  end
  self:store_clock()
  return changed
end

---Runs `sweep` every `sweep_interval_ms` until stopped.
function Client:schedule_sweep()
  self.platform.after(self.options.sweep_interval_ms, function()
    if self.state ~= "stopped" then
      self:sweep()
      self:schedule_sweep()
    end
  end)
end

-- Receiving -----------------------------------------------------------------

---Registers the handler for one kind of request from the portal. The handler
---gets the frame and a `reply` function that sends the answer with `re` set.
---It runs at most once per request id, however often the portal retries it:
---see `request`.
---@param tag string The request's type, like `apply_command`.
---@param handler rpf.RequestHandler The handler.
function Client:handle(tag, handler)
  self.handlers[tag] = handler
end

---Hears one kind of notice from the portal: a frame that answers nothing
---this server sent and asks for no reply, only an `Ack`.
---@alias rpf.NoticeListener fun(frame: rpf.Frame)

---Registers a listener for one kind of notice from the portal, such as
---`staff_permissions` (F9), so the module that owns what the notice is about
---hears it without the connection knowing what it means.
---
---A notice is handed over once, after its `Ack` has gone out, as every
---frame the portal sends is: a duplicate is acked again and not handed over
---again. Listeners run in registration order, each under `Client:call`, so
---one that throws is logged and the connection and the listeners after it
---carry on. Unlike a request there is nothing to journal, because the
---portal's answer is the `Ack` the connection already sent.
---
---Only a type that can arrive as a notice may be listened for. A request
---goes to `handle`, and an answer to the callback of the frame it answers,
---so a listener for one of those would never run; asking for one is a bug
---and throws.
---@param tag string The notice's type, like `staff_permissions`.
---@param listener rpf.NoticeListener Called with the decoded frame.
function Client:listen(tag, listener)
  local spec = protocol.messages[IN][tag]
  if not spec or spec.answered_by == "reply" then
    error("rpf: " .. tostring(tag) .. " is not a notice the portal sends", 2)
  end
  for _, field in ipairs(spec.fields) do
    if field[1] == "re" then
      error("rpf: " .. tag .. " answers a frame; it goes to that frame's callback", 2)
    end
  end
  if type(listener) ~= "function" then
    error("rpf: Client:listen needs a function", 2)
  end
  local list = self.listeners[tag]
  if not list then
    list = {}
    self.listeners[tag] = list
  end
  list[#list + 1] = listener
end

---Remembers a received frame id, forgetting the oldest past the limit.
---@param id string The id.
---@return boolean duplicate True if it was already remembered.
function Client:remember(id)
  if self.seen[id] then
    return true
  end
  self.seen[id] = true
  self.seen_order[#self.seen_order + 1] = id
  if #self.seen_order > self.options.seen_limit then
    local oldest = table.remove(self.seen_order, 1)
    self.seen[oldest] = nil
  end
  return false
end

---Handles one frame from the portal. It is hostile input: a frame that does
---not decode is logged and dropped, and nothing is sent back, because there is
---no message for refusing a portal frame.
---
---Two kinds of duplicate are told apart. A repeated frame that an `Ack`
---answers (a reply or a notice) is acked again, since the first ack may have
---been lost, and not handled again. A repeated request needs its *result*,
---not an ack, so it goes to `request`, which answers it from the journal.
---@param text string The raw frame.
function Client:receive(text)
  local frame, err = protocol.decode(IN, text)
  if not frame then
    self:log("warn", "dropped a frame from the portal: " .. tostring(err))
    return
  end
  if self.state == "handshaking" then
    self:handshake_reply(frame)
    return
  end
  if self.state ~= "ready" then
    return
  end

  local answered_by = protocol.answered_by(IN, frame.type)
  if answered_by == "reply" then
    self:request(frame)
    return
  end
  if self:remember(frame.id) then
    if answered_by == "ack" then
      self:ack(frame.id)
    end
    return
  end
  -- Acked before it is acted on, so the ack goes out ahead of anything its
  -- callback sends. The portal reads a `player_authenticated`'s ack as the
  -- moment this server learned of the join (F2), and a drop the callback
  -- reports must not look older than it.
  if answered_by == "ack" then
    self:ack(frame.id)
  end
  if frame.re then
    self:answer(frame)
  else
    self:notice(frame)
  end
end

---Handles a frame from the portal that answers nothing. `restarting` is
---about the connection itself, so the connection acts on it here; any other
---notice (`staff_permissions`) goes to the listeners a module registered
---with `listen`, after its `Ack`. A notice nobody listens for is logged and
---otherwise ignored: it was acked, so the portal will not send it again. A
---type the core does not know is refused by `decode` long before it gets
---here.
---@param frame rpf.Frame The decoded notice.
function Client:notice(frame)
  if frame.type == "restarting" then
    local asked = math.min(frame.retry_after_ms, self.options.max_retry_after_ms)
    self.retry_after_ms = asked
    self:log("info", "the portal is restarting; reconnecting " .. math.floor(asked) .. " ms after it closes")
  end
  local list = self.listeners[frame.type]
  if not list then
    if frame.type ~= "restarting" then
      self:log("debug", "nothing listens for " .. frame.type .. "; acked and ignored")
    end
    return
  end
  -- A copy, so a listener registered while this one runs waits for the next.
  local snapshot = {}
  for i, listener in ipairs(list) do
    snapshot[i] = listener
  end
  for _, listener in ipairs(snapshot) do
    self:call("a listener for " .. frame.type, listener, frame)
  end
end

---Completes the handshake from the answer to `Hello`.
---
---`Welcome` makes the connection ready: the outbox is swept and then flushed
---under its original ids. One naming a protocol other than the one this
---core speaks stops the connection for good (`docs/compatibility.md`). A retryable refusal sends a fresh `Hello` after a
---backoff. `suspended` (H5) drops the connection and makes it again after
---`suspended_retry_ms` plus jitter, for as long as the suspension lasts, so
---a lifted one needs no restart. Any other refusal stops the connection for
---good, because the same key would be refused again, and retrying it
---forever is a loop.
---@param frame rpf.Frame A frame received before the handshake completed.
function Client:handshake_reply(frame)
  if frame.re ~= self.hello_id then
    self:log("warn", "ignored a " .. frame.type .. " before Welcome")
    return
  end
  if frame.type == "welcome" then
    self:ack(frame.id)
    if frame.protocol ~= protocol.VERSION then
      -- The portal speaks the version `Hello` named or refuses it, so any
      -- other is a portal this core cannot follow: every frame after this
      -- would be read against the wrong shapes.
      self:stop(
        "the portal answered Hello with protocol "
          .. tostring(frame.protocol)
          .. ", and this core speaks only protocol "
          .. protocol.VERSION
      )
      return
    end
    self:remember(frame.id)
    self.attempt = 0
    self.retry_after_ms = nil
    self.server_id = frame.server_id
    self:log("info", "connected as server " .. frame.server_id)
    -- Swept before the state changes, so nothing the sweep reissues is sent
    -- twice: it goes out once, with everything else, in the flush.
    local generation = self.generation
    self:sweep()
    if generation ~= self.generation then
      -- The sweep caught a clock step after this `Hello` went out, and is
      -- making the connection again: this one's offset is the old clock's.
      return
    end
    self.state = "ready"
    self:flush()
    if self.on_ready then
      self:call("on_ready", self.on_ready, self)
    end
  elseif frame.type == "rejected" then
    self:ack(frame.id)
    if frame.code == "suspended" then
      -- Not this server's fault, and not for good: an operator lifts a
      -- suspension once its cause is dealt with. The wait replaces the
      -- backoff for this one reconnect, as an announced restart's does.
      self:log("error", "the portal refused Hello (suspended): " .. frame.reason)
      self.retry_after_ms = self.options.suspended_retry_ms
      self:reconnect("suspended")
    elseif protocol.may_retry(frame.code) then
      local delay = self:backoff(self.attempt)
      self.attempt = self.attempt + 1
      local generation = self.generation
      self:log("warn", "Hello refused (" .. frame.code .. "); trying again in " .. math.floor(delay) .. " ms")
      self.platform.after(delay, function()
        if generation == self.generation and self.state == "handshaking" then
          self:handshake(generation)
        end
      end)
    else
      self:stop("the portal refused Hello (" .. frame.code .. "): " .. frame.reason)
    end
  else
    self:log("warn", "ignored a " .. frame.type .. " answering Hello")
  end
end

---Matches an answer to the frame it answers and releases it.
---
---A `Rejected` with a retryable code keeps the entry and resends it under the
---same id after a backoff, and so does any other answer to a frame with no
---callback that `on_orphan` asks to have sent again. `expired` means the portal has already forgotten
---the id: a reissuable entry is reissued, anything else dropped. Any other
---refusal is final and goes to the callback.
---@param frame rpf.Frame A frame carrying `re`.
function Client:answer(frame)
  local index = self:find(frame.re)
  if not index then
    -- Already released: this is a late duplicate of an answer.
    self:log("debug", "no waiting frame for the " .. frame.type .. " answering " .. frame.re)
    return
  end
  local entry = self.outbox[index]
  local again = frame.type == "rejected" and protocol.may_retry(frame.code) and frame.code or nil
  if not again and self.on_orphan and not self.callbacks[entry.id] then
    -- Its own pcall, not `Client:call`, because the answer is wanted.
    local ok, wanted = pcall(self.on_orphan, self, entry, frame)
    if not ok then
      self:log("error", "on_orphan failed: " .. tostring(wanted))
    elseif wanted then
      again = frame.type
    end
    -- The handler may have sent, and a send that catches the clock stepped
    -- back drops or reissues entries, this one among them. The saved index
    -- would then name some other frame, so find this one again; if it is
    -- gone, the step has released it already.
    index = self:find(entry.id)
    if not index then
      return
    end
  end
  if again then
    entry.retries = (entry.retries or 0) + 1
    local delay = self:backoff(entry.retries - 1)
    local generation = self.generation
    local id = entry.id --[[@as string]]
    self:log("info", entry.type .. " " .. id .. " refused (" .. again .. "); resending in " .. math.floor(delay) .. " ms")
    self.platform.after(delay, function()
      local at = self:find(id)
      if generation == self.generation and self.state == "ready" and at then
        self.platform.send(self.outbox[at].text)
      end
    end)
    return
  end
  if frame.type == "rejected" and frame.code == "expired" and protocol.reissuable(OUT, entry.type) then
    self:reissue(entry)
    self.platform.send(entry.text)
    return
  end
  if frame.type == "rejected" then
    self:log("warn", entry.type .. " " .. entry.id .. " refused (" .. frame.code .. "): " .. frame.reason)
  end
  self:release(index, frame, nil)
end

---Hands a request from the portal to its handler, at most once per request
---id, with a `reply` that records the answer in the request's journal entry.
---
---The journal entry is persisted *before* the handler runs, and the reply
---replaces it in the same slot with one write. So whatever the portal
---resends, and whenever:
---
--- - **A duplicate of a request that has been answered** gets the original
---   reply again, the same bytes under the same id, because the portal may
---   have lost it.
--- - **A duplicate of a request still running** starts nothing. The one reply
---   the handler eventually sends names the request in `re`, so it answers
---   every copy.
--- - **A duplicate after its reply was acked** is ignored: the portal has the
---   outcome, and this copy was already on the wire when it got it.
---
---A request that finds the journal full is not run and not remembered, so
---the portal's next resend gets another chance, rather than being answered
---with an outcome that would be a guess.
---@param frame rpf.Frame A request: a frame the portal expects a reply to.
function Client:request(frame)
  if self.recovery_failed then
    self:log("warn", "not running " .. frame.type .. " " .. frame.id .. ": the stored outbox needs repair")
    return
  end
  local held = self.requests[frame.id]
  if held then
    if held.text then
      self:log("debug", "resending the reply to a repeated " .. frame.type .. " " .. frame.id)
      self.platform.send(held.text)
    else
      self:log("debug", "a repeated " .. frame.type .. " " .. frame.id .. " is still running; its reply will answer both")
    end
    return
  end
  if self.seen[frame.id] then
    self:log("debug", "ignoring a repeated " .. frame.type .. " " .. frame.id .. " whose reply the portal has acked")
    return
  end
  local handler = self.handlers[frame.type] or FALLBACKS[frame.type]
  if not handler or not UNKNOWN[frame.type] then
    self:log("warn", "no handler for " .. frame.type)
    return
  end
  -- A config is never refused for room. The portal sends one only when this
  -- server's version moves and never resends it, so refusing it would leave
  -- the server on old config until it reconnects; and its reply is a few
  -- bytes. `max_requests` exists to bound commands.
  if frame.type ~= "config" and self.request_count >= self.options.max_requests then
    self:log(
      "warn",
      "not running "
        .. frame.type
        .. " "
        .. frame.id
        .. ": "
        .. self.request_count
        .. " requests are already waiting on the portal; it will be run when the portal resends it"
    )
    return
  end

  self:remember(frame.id)
  ---@type rpf.OutboxEntry
  local entry = { slot = 0, seq = 0, type = frame.type, request = frame.id, sent_ms = self.platform.now(), bytes = 0 }
  self:place(entry)
  self.request_count = self.request_count + 1
  self.requests[frame.id] = entry
  self:write(entry)

  ---Records the answer to this request and sends it. Only the first call
  ---counts: the request has one outcome.
  ---@param tag string The reply's type.
  ---@param fields table? Its fields, without `re`, which is set here.
  local function reply(tag, fields)
    self:settle(entry, tag, fields)
  end
  local ok = self:call("the handler for " .. frame.type, handler, frame, reply)
  if not ok and not entry.text then
    -- It may have done part of the work before it threw.
    self:settle_unknown(entry, "the game server's handler failed while applying it")
  end
end

---Encodes a reply to a journalled request, with `re` set and a command
---outcome's `reason` cut to `max_reason_bytes`.
---@param entry rpf.OutboxEntry The request's journal entry.
---@param tag string The reply's type.
---@param fields table? Its fields, without `re`.
---@return rpf.Frame? frame The reply, or nil if it is not a valid one.
---@return string? text Its encoding.
---@return string? err Why it is not valid.
function Client:encode_reply(entry, tag, fields)
  if not is_reply(tag) then
    return nil, nil, tostring(tag) .. " is not a reply"
  end
  local expected = UNKNOWN[entry.type]("")
  if tag ~= expected then
    return nil, nil, tostring(tag) .. " is not the reply to " .. entry.type
  end
  local answer = {}
  for key, value in pairs(fields or {}) do
    answer[key] = value
  end
  answer.re = entry.request
  local outcome = answer.outcome
  if type(outcome) == "table" and type(outcome.reason) == "string" then
    local clipped = clip(outcome.reason, self.options.max_reason_bytes)
    if clipped ~= outcome.reason then
      local copy = {}
      for key, value in pairs(outcome) do
        copy[key] = value
      end
      copy.reason = clipped
      answer.outcome = copy
    end
  end
  local frame = protocol.envelope(self.platform, tag, answer)
  local text, err = protocol.encode(OUT, frame)
  if not text then
    return nil, nil, err
  end
  if #text + reissue_growth(text) > self.options.max_reply_bytes then
    return nil, nil, #text .. " bytes is over the reply limit of " .. self.options.max_reply_bytes
  end
  return frame, text, nil
end

---Turns a pending request's journal entry into its reply, persists it in the
---same slot, and sends it. The reply is ordered after everything already
---queued, as it would be had it gone through `send`.
---
---Called once per request. A later call is logged and ignored, so a handler
---that replies twice, or late after a timeout, cannot give the portal two
---outcomes for one command. A reply that is not valid is logged and replaced
---by `unknown`, because the handler did run.
---@param entry rpf.OutboxEntry The request's journal entry.
---@param tag string The reply's type.
---@param fields table? Its fields, without `re`.
function Client:settle(entry, tag, fields)
  if entry.text or self.requests[entry.request] ~= entry then
    self:log("warn", "ignored a second reply to " .. entry.type .. " " .. entry.request)
    return
  end
  local frame, text, err = self:encode_reply(entry, tag, fields)
  if not frame then
    self:log("error", "the reply to " .. entry.type .. " " .. entry.request .. " is invalid: " .. tostring(err))
    frame, text, err = self:encode_reply(entry, UNKNOWN[entry.type]("the game server's handler sent an invalid reply"))
    if not frame then
      self:log("error", "could not answer " .. entry.type .. " " .. entry.request .. ": " .. tostring(err))
      return
    end
  end

  entry.id = frame.id
  entry.type = frame.type
  entry.text = text
  entry.sent_ms = self.platform.now()
  entry.seq = self.next_seq
  self.next_seq = self.next_seq + 1
  self:write(entry)
  self.outbox[#self.outbox + 1] = entry
  if self.state == "ready" then
    self.platform.send(text --[[@as string]])
  end
end

---Answers a pending request as `unknown`: its handler started, and what it
---did is not known.
---@param entry rpf.OutboxEntry The request's journal entry.
---@param reason string Why, for the staff member who issued it.
function Client:settle_unknown(entry, reason)
  local tag, fields = UNKNOWN[entry.type](reason)
  self:settle(entry, tag, fields)
end

rpf.client = client
return client
