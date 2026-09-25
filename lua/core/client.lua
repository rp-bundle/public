---The game server's connection to the portal: handshake, correlation, the
---outbox, and reconnecting.
---
---Everything the protocol promises about delivery is kept here:
---
--- - **Every frame except `Ack` waits in the outbox until a frame whose `re` is
---   its id arrives** (its reply, a `Rejected`, or an `Ack`). The outbox is
---   persisted through `kv_set`, so a restart does not lose a state report.
--- - **A resend reuses the frame's id.** After a reconnect every entry goes out
---   again byte for byte, which is what lets the portal's request log (C3)
---   recognise a retry instead of running it twice.
--- - **Near the end of the portal's retry window an entry is reissued or
---   dropped.** A reissuable one (a state report) goes out under a fresh id,
---   because its content is idempotent and losing it would lose money or
---   inventory. Anything else would be a second request, so it is dropped and
---   logged.
--- - **Reconnects back off exponentially, plus random jitter**, so a portal
---   restart does not bring every game server back in the same second.
---
---Every timer goes through the platform clock, so all of this runs instantly
---and deterministically under the mock.
---@class rpf.client
---@field OUTBOX_KEY string The storage key the outbox is persisted under.
---@field DEFAULTS rpf.ClientOptions The production timings, used for anything the caller leaves out.
local client = {}

local json = rpf.json
local protocol = rpf.protocol
local config = rpf.config

local OUT = protocol.SERVER_TO_PORTAL
local IN = protocol.PORTAL_TO_SERVER

client.OUTBOX_KEY = "rpf.outbox"

---Timings for the connection. Every one has a production default; tests
---shrink them.
---@class rpf.ClientOptions
---@field backoff_base_ms number? The first reconnect delay, before jitter. Doubles on each failed attempt.
---@field backoff_max_ms number? The longest reconnect delay, before jitter.
---@field jitter number? The largest random extra, as a fraction of the delay: 0.5 adds up to half again.
---@field retry_window_ms number? How long the portal remembers a request id (C3's TTL), which is how old an entry may get before it is reissued or dropped.
---@field window_margin_ms number? How long before the window closes an entry is dealt with, to cover clock drift between the hosts and a frame still in flight.
---@field sweep_interval_ms number? How often the outbox is checked against the window while running.
---@field seen_limit integer? How many inbound frame ids are remembered to recognise a duplicate.
client.DEFAULTS = {
  backoff_base_ms = 1000,
  backoff_max_ms = 60 * 1000,
  jitter = 0.5,
  retry_window_ms = 7 * 24 * 60 * 60 * 1000,
  window_margin_ms = 12 * 60 * 60 * 1000,
  sweep_interval_ms = 60 * 1000,
  seen_limit = 1024,
}

---One frame waiting for its answer. The encoded text is kept, not the Lua
---table, so a resend is the same bytes.
---@class rpf.OutboxEntry
---@field id string The frame's envelope id, which its answer names in `re`.
---@field type string The message type, so the entry can be classified without decoding.
---@field text string The encoded frame, sent unchanged on every resend.
---@field sent_ms number When the envelope was minted, by the platform clock. Its age decides reissue or drop.
---@field retries integer? How many times the portal has asked for it again with a retryable code, for the backoff.

---Handles one kind of request from the portal.
---@alias rpf.RequestHandler fun(frame: rpf.Frame, reply: fun(tag: string, fields: table?))

---Called once with a frame's answer, or with an error if it never got one.
---@alias rpf.ReplyCallback fun(reply: rpf.Frame?, err: string?)

---What to construct a connection with.
---@class rpf.ClientConfig
---@field url string The portal's websocket url.
---@field api_key string The API key (C2). A secret: never logged.
---@field instance_id string This process's instance id.
---@field options rpf.ClientOptions? Timing overrides.

---A running connection to the portal.
---@class rpf.Client
---@field platform rpf.ServerPlatform The platform.
---@field url string The portal's websocket url.
---@field api_key string The API key. A secret: never logged.
---@field instance_id string Minted per process start and sent in every `Hello`, so the portal can tell a reconnect from a second host sharing the key.
---@field options rpf.ClientOptions The timings, defaults filled in.
---@field state "idle"|"connecting"|"handshaking"|"ready"|"stopped" Where the connection is. Frames are sent only when `ready`.
---@field server_id string? This server's id, as the portal named it in `Welcome`.
---@field stopped_reason string? Why the connection stopped for good, when it did.
---@field outbox rpf.OutboxEntry[] Frames awaiting an answer, oldest first.
---@field attempt integer Reconnect attempts since the last `Welcome`, for the backoff.
---@field generation integer Bumped on every connect, so callbacks and timers from an older connection are ignored.
---@field hello_id string? The id of this connection's `Hello`, whose answer completes the handshake.
---@field callbacks table<string, rpf.ReplyCallback> Callbacks by frame id. In memory only, so they do not survive a restart; the entries do.
---@field handlers table<string, rpf.RequestHandler> Handlers for requests from the portal, by type.
---@field seen table<string, true> Recently received frame ids, to recognise a duplicate.
---@field seen_order string[] The same ids, oldest first, to evict from.
---@field on_ready fun(client: rpf.Client)? Called after each `Welcome`, once the outbox is flushed.
local Client = {}
Client.__index = Client

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
    attempt = 0,
    generation = 0,
    callbacks = {},
    handlers = {},
    seen = {},
    seen_order = {},
  }, Client)
  self:load_outbox()
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
function Client:call(what, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then
    self:log("error", what .. " failed: " .. tostring(err))
  end
end

-- Outbox persistence --------------------------------------------------------

---Reads the persisted outbox. An entry that is not exactly what `save_outbox`
---writes is skipped and logged: it could only have come from corruption, and
---sending bytes the core did not produce would be worse than losing them.
function Client:load_outbox()
  local raw = self.platform.kv_get(client.OUTBOX_KEY)
  if raw == nil then
    return
  end
  local stored = json.decode(raw)
  if not json.is_array(stored) then
    self:log("warn", "ignoring an unreadable stored outbox")
    return
  end
  for _, entry in ipairs(stored) do
    if
      json.is_object(entry)
      and type(entry.id) == "string"
      and type(entry.type) == "string"
      and type(entry.text) == "string"
      and type(entry.sent_ms) == "number"
    then
      self.outbox[#self.outbox + 1] = {
        id = entry.id,
        type = entry.type,
        text = entry.text,
        sent_ms = entry.sent_ms,
      }
    else
      self:log("warn", "skipping an unreadable stored outbox entry")
    end
  end
end

---Writes the outbox through `kv_set`. Called after every change, so what is
---stored is never behind what was sent.
function Client:save_outbox()
  local list = json.array()
  for i, entry in ipairs(self.outbox) do
    list[i] = json.object({ id = entry.id, type = entry.type, text = entry.text, sent_ms = entry.sent_ms })
  end
  local text = json.encode(list)
  self.platform.kv_set(client.OUTBOX_KEY, text)
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
  self:save_outbox()
  local callback = self.callbacks[entry.id]
  self.callbacks[entry.id] = nil
  if callback then
    self:call("the callback for " .. entry.type, callback, reply, err)
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

---The connection ended. Unless stopped, try again after a backoff.
---@param reason string What the platform said.
function Client:closed(reason)
  if self.state == "stopped" then
    return
  end
  local delay = self:backoff(self.attempt)
  self.attempt = self.attempt + 1
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

---Sends this connection's `Hello`. It is minted fresh for each connection and
---never enters the outbox, because it only means anything on the connection
---it opens.
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
  self.platform.send(text)
end

-- Sending -------------------------------------------------------------------

---Sends a frame to the portal, and keeps it in the outbox until it is
---answered. If the connection is not ready it waits there, and goes out after
---the next `Welcome`.
---@param tag string The message type. Not `hello`, which the connection owns, and not `ack`, which is never queued.
---@param fields table? The message's own fields.
---@param callback rpf.ReplyCallback? Called once with the answer: the reply, a `Rejected`, or the `Ack`. Called with an error instead if the frame is dropped unanswered.
---@return string id The frame's id, which its answer will name in `re`.
function Client:send(tag, fields, callback)
  if tag == "hello" or tag == "ack" then
    error("rpf: " .. tag .. " is sent by the connection itself", 2)
  end
  local frame = protocol.envelope(self.platform, tag, fields)
  local text, err = protocol.encode(OUT, frame)
  if not text then
    error("rpf: cannot send " .. tostring(tag) .. ": " .. tostring(err), 2)
  end
  self.outbox[#self.outbox + 1] = { id = frame.id, type = tag, text = text, sent_ms = self.platform.now() }
  self:save_outbox()
  if callback then
    self.callbacks[frame.id] = callback
  end
  if self.state == "ready" then
    self.platform.send(text)
  end
  return frame.id
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

---Re-sends one entry under a fresh id and `sent_at`, keeping its content and
---its callback. Only for reissuable frames: see `sweep`.
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
  self:log("info", "reissuing " .. entry.type .. " " .. entry.id .. " as " .. fresh.id)
  self.callbacks[fresh.id] = self.callbacks[entry.id]
  self.callbacks[entry.id] = nil
  entry.id = fresh.id
  entry.text = text
  entry.sent_ms = self.platform.now()
  entry.retries = nil
end

---Deals with every entry that is nearly as old as the portal's retry window:
---a reissuable one is reissued, anything else is dropped and logged.
---
---Past the window the portal may have forgotten the id, so resending under it
---could run a request twice. A reissuable frame is safe to run twice by its
---content, so it goes out fresh; for anything else, dropping it is the only
---way to be sure it does not happen twice.
---@return boolean changed Whether any entry was reissued or dropped.
function Client:sweep()
  local now = self.platform.now()
  local limit = self.options.retry_window_ms - self.options.window_margin_ms
  local changed = false
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
          "dropping " .. entry.type .. " " .. entry.id .. ": unanswered for as long as the portal remembers requests"
        )
        self:release(i, nil, "expired")
      end
    else
      i = i + 1
    end
  end
  if changed then
    self:save_outbox()
  end
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
---@param tag string The request's type, like `apply_command`.
---@param handler rpf.RequestHandler The handler.
function Client:handle(tag, handler)
  self.handlers[tag] = handler
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
  if self:remember(frame.id) then
    -- A resend: whatever it asked for has already been done. Ack it again in
    -- case the first ack was lost, and do nothing else.
    if answered_by == "ack" then
      self:ack(frame.id)
    end
    return
  end

  if frame.re then
    self:answer(frame)
  else
    self:request(frame)
  end
  if answered_by == "ack" then
    self:ack(frame.id)
  end
end

---Completes the handshake from the answer to `Hello`.
---
---`Welcome` makes the connection ready: the outbox is swept and then flushed
---under its original ids. A retryable refusal sends a fresh `Hello` after a
---backoff; any other refusal stops the connection for good, because the same
---key would be refused again, and retrying it forever is a loop.
---@param frame rpf.Frame A frame received before the handshake completed.
function Client:handshake_reply(frame)
  if frame.re ~= self.hello_id then
    self:log("warn", "ignored a " .. frame.type .. " before Welcome")
    return
  end
  if frame.type == "welcome" then
    self:ack(frame.id)
    self:remember(frame.id)
    self.attempt = 0
    self.server_id = frame.server_id
    self:log("info", "connected as server " .. frame.server_id)
    -- Swept before the state changes, so nothing the sweep reissues is sent
    -- twice: it goes out once, with everything else, in the flush.
    self:sweep()
    self.state = "ready"
    self:flush()
    if self.on_ready then
      self:call("on_ready", self.on_ready, self)
    end
  elseif frame.type == "rejected" then
    self:ack(frame.id)
    if protocol.may_retry(frame.code) then
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
---same id after a backoff. `expired` means the portal has already forgotten
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
  if frame.type == "rejected" and protocol.may_retry(frame.code) then
    entry.retries = (entry.retries or 0) + 1
    local delay = self:backoff(entry.retries - 1)
    local generation = self.generation
    local id = entry.id
    self:log("info", entry.type .. " " .. id .. " refused (" .. frame.code .. "); resending in " .. math.floor(delay) .. " ms")
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
    self:save_outbox()
    self.platform.send(entry.text)
    return
  end
  if frame.type == "rejected" then
    self:log("warn", entry.type .. " " .. entry.id .. " refused (" .. frame.code .. "): " .. frame.reason)
  end
  self:release(index, frame, nil)
end

---What a request from the portal gets when no module has registered for it:
---a refusal the portal can record, rather than silence it would wait on.
---@type table<string, rpf.RequestHandler>
local FALLBACKS = {
  apply_command = function(frame, reply)
    reply("command_applied", {
      outcome = { outcome = "failed", reason = "this server has no handler for " .. frame.command.command },
    })
  end,
}

---Hands a request from the portal to its handler, with a `reply` that sends
---the answer through the outbox, `re` set to the request's id.
---@param frame rpf.Frame A frame with no `re`.
function Client:request(frame)
  local handler = self.handlers[frame.type] or FALLBACKS[frame.type]
  if not handler then
    self:log("warn", "no handler for " .. frame.type)
    return
  end
  ---Sends the answer to this request through the outbox.
  ---@param tag string The reply's type.
  ---@param fields table? Its fields, without `re`, which is set here.
  local function reply(tag, fields)
    local answer = {}
    for key, value in pairs(fields or {}) do
      answer[key] = value
    end
    answer.re = frame.id
    self:send(tag, answer)
  end
  self:call("the handler for " .. frame.type, handler, frame, reply)
end

rpf.client = client
return client
