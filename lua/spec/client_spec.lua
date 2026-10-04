-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The connection to the portal, driven through the fake platform. The test
-- plays the portal: it opens and drops the socket, reads what the core sent,
-- and delivers answers. The fake clock only moves when advanced, so every
-- backoff and retry here runs instantly and in a fixed order.

local support = require("spec.support")

local PLAYER = "00000002-0000-4000-8000-000000000002"
local HOUR = 60 * 60 * 1000
local DAY = 24 * HOUR

---Fields for a valid CreateCharacter, the model non-reissuable request.
---@return table fields The fields.
local function character()
  return {
    owner = { kind = "player", id = PLAYER },
    first_name = "Jane",
    last_name = "Doe",
    gender = "female",
  }
end

---Fields for a valid PlayerDropped, the model reissuable notice.
---@return table fields The fields.
local function dropped()
  return { player_id = PLAYER, reason = "left" }
end

---Frames of one type among everything sent.
---@param p spec.FakePlatform The platform.
---@param tag string The type.
---@return rpf.Frame[] frames The frames, in order.
local function sent_of(p, tag)
  local out = {}
  for _, frame in ipairs(p.frames()) do
    if frame.type == tag then
      out[#out + 1] = frame
    end
  end
  return out
end

---Answers the current connection's Hello with Welcome.
---@param p spec.FakePlatform The platform, with an open socket.
local function welcome(p)
  local hellos = sent_of(p, "hello")
  p.deliver(support.portal_frame("welcome", {
    re = hellos[#hellos].id,
    protocol = 1,
    server_id = "00000001-0000-4000-8000-000000000001",
  }))
end

---Drops the socket, waits out the backoff, and completes a new handshake.
---@param p spec.FakePlatform The platform.
local function reconnect(p)
  p.drop()
  p.advance(2 * 60 * 1000)
  p.open()
  welcome(p)
end

---The stored outbox entries, each as its slot, its type and its raw form.
---@param p spec.FakePlatform The platform.
---@return { slot: integer, type: string, raw: string }[] entries The entries, by slot.
local function stored_outbox(p)
  local out = {}
  for key, raw in pairs(p.store) do
    local slot = key:match("^rpf%.outbox%.(%d+)$")
    if slot then
      local tag = raw:match("^[^\n]*\n[^\n]*\n([^\n]*)\n")
      out[#out + 1] = { slot = tonumber(slot), type = tag, raw = raw }
    end
  end
  table.sort(out, function(a, b)
    return a.slot < b.slot
  end)
  return out
end

describe("rpf.client", function()
  before_each(function()
    support.load_core()
  end)

  describe("the handshake", function()
    it("opens with a Hello carrying the instance id, engine and versions", function()
      local p = support.fake_platform()
      rpf.start_server(p, { url = "ws://portal", api_key = "rpf_test_secret" })
      p.open()

      local hello = p.last()
      assert.are.equal("hello", hello.type)
      assert.are.equal(1, hello.protocol)
      assert.are.equal("rpf_test_secret", hello.api_key)
      assert.are.equal(rpf.instance_id, hello.instance_id)
      assert.are.equal("mock", hello.engine)
      assert.are.equal(rpf.VERSION, hello.core_version)
      assert.is_nil(hello.config_version)
      assert.is_nil(hello.config_hash)
      -- Sent as null, not left out: the portal refuses a Hello without them.
      local raw = rpf.json.decode(p.sent[#p.sent])
      assert.are.equal(rpf.json.null, raw.config_version)
      assert.are.equal(rpf.json.null, raw.config_hash)
    end)

    it("reports the persisted config version and hash", function()
      local store = {}
      local first = support.fake_platform({ store = store })
      rpf.config.apply(first, 7, "sha256:sample", rpf.json.object({}))

      support.load_core()
      local p = support.fake_platform({ store = store })
      rpf.start_server(p, { url = "ws://portal", api_key = "k" })
      p.open()

      assert.are.equal(7, p.last().config_version)
      assert.are.equal("sha256:sample", p.last().config_hash)
    end)

    it("treats a corrupt stored config version as a cold start", function()
      local p = support.fake_platform({ store = { [rpf.config.KEY] = '{"version":7}' } })
      assert.is_nil(rpf.config.load(p))
      assert.are.equal(1, #p.logged("warn", "stored config"))
    end)

    it("keeps one instance id per process, and mints a new one per start", function()
      local store = {}
      local p = support.fake_platform({ store = store })
      support.connected(p)
      local first = p.frames()[1].instance_id
      reconnect(p)
      assert.are.equal(first, sent_of(p, "hello")[2].instance_id)
      assert.is_nil(store["rpf.instance_id"])

      support.load_core()
      local restarted = support.fake_platform({ store = store, seed = 999 })
      support.connected(restarted)
      assert.are_not.equal(first, restarted.frames()[1].instance_id)
    end)

    it("acks the Welcome and sends nothing else before it", function()
      local p = support.fake_platform()
      local connection = rpf.start_server(p, { url = "ws://portal", api_key = "k" })
      connection:send("player_dropped", dropped())
      p.open()
      assert.are.equal(1, #p.sent)

      welcome(p)
      assert.are.equal("ready", connection.state)
      local frames = p.frames()
      assert.are.equal("ack", frames[2].type)
      assert.are.equal("player_dropped", frames[3].type)
    end)

    for _, code in ipairs({ "unauthorised", "duplicate_instance", "forbidden", "malformed" }) do
      it("stops for good when Hello is refused with " .. code, function()
        local p = support.fake_platform()
        local connection = rpf.start_server(p, { url = "ws://portal", api_key = "k" })
        p.open()
        p.deliver(support.portal_frame("rejected", { re = p.last().id, code = code, reason = "no" }))

        assert.are.equal("stopped", connection.state)
        p.drop()
        p.advance(DAY)
        assert.are.equal(1, #p.connects)
        assert.are.equal(1, #p.logged("error", code))
      end)
    end

    it("sends a fresh Hello after a backoff when refused with retry", function()
      local p = support.fake_platform()
      local connection = rpf.start_server(p, { url = "ws://portal", api_key = "k" })
      p.open()
      local first = p.last()
      p.deliver(support.portal_frame("rejected", { re = first.id, code = "retry", reason = "busy" }))
      assert.are.equal(1, #sent_of(p, "hello"))

      p.advance(2000)
      local hellos = sent_of(p, "hello")
      assert.are.equal(2, #hellos)
      assert.are_not.equal(first.id, hellos[2].id)
      welcome(p)
      assert.are.equal("ready", connection.state)
    end)
  end)

  describe("correlation", function()
    it("hands a reply to the callback of the frame it names, and acks it", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local got
      local id = connection:send("create_character", character(), function(reply)
        got = reply
      end)
      assert.are.equal(id, p.last().id)

      p.deliver(support.portal_frame("character_created", {
        re = id,
        character = {
          id = "00000003-0000-4000-8000-000000000003",
          server_id = "00000001-0000-4000-8000-000000000001",
          owner = { kind = "player", id = PLAYER },
          first_name = "Jane",
          last_name = "Doe",
          gender = "female",
        },
      }))

      assert.are.equal("Jane", got.character.first_name)
      assert.are.equal(0, #connection.outbox)
      assert.are.equal(0, #stored_outbox(p))
      local ack = p.last()
      assert.are.equal("ack", ack.type)
    end)

    it("releases a notice on its Ack", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local id = connection:send("player_dropped", dropped())
      assert.are.equal(1, #connection.outbox)

      local before = #p.sent
      p.deliver(support.portal_frame("ack", { re = id }))
      assert.are.equal(0, #connection.outbox)
      assert.are.equal(before, #p.sent, "an ack is never acked")
    end)

    it("ignores an answer naming a frame it is not waiting for", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      connection:send("player_dropped", dropped())
      p.deliver(support.portal_frame("ack", { re = "00000009-0000-4000-8000-000000000009" }))
      assert.are.equal(1, #connection.outbox)
    end)

    it("hands a final refusal to the callback and releases the frame", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local got
      local id = connection:send("create_character", character(), function(reply)
        got = reply
      end)
      p.deliver(support.portal_frame("rejected", { re = id, code = "not_found", reason = "no such player" }))
      assert.are.equal("not_found", got.code)
      assert.are.equal(0, #connection.outbox)
    end)

    it("resends a frame refused with retry under the same id, after a backoff", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local id = connection:send("create_character", character())
      local count = #sent_of(p, "create_character")
      p.deliver(support.portal_frame("rejected", { re = id, code = "rate_limited", reason = "slow down" }))
      assert.are.equal(count, #sent_of(p, "create_character"), "not resent at once")

      p.advance(2000)
      local resent = sent_of(p, "create_character")
      assert.are.equal(count + 1, #resent)
      assert.are.equal(id, resent[#resent].id)
      assert.are.equal(1, #connection.outbox)
    end)

    it("refuses to queue a frame that does not encode, naming the field", function()
      local connection = support.connected(support.fake_platform())
      local ok, err = pcall(connection.send, connection, "create_character", { first_name = "Jane" })
      assert.is_false(ok)
      assert.truthy(tostring(err):find("owner", 1, true))
      assert.are.equal(0, #connection.outbox)
    end)

    it("does not let a caller queue a Hello or an Ack", function()
      local connection = support.connected(support.fake_platform())
      assert.is_false(pcall(connection.send, connection, "hello", {}))
      assert.is_false(pcall(connection.send, connection, "ack", { re = PLAYER }))
    end)

    it("isolates a callback that throws", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local id = connection:send("player_dropped", dropped(), function()
        error("boom")
      end)
      p.deliver(support.portal_frame("ack", { re = id }))
      assert.are.equal(0, #connection.outbox)
      assert.are.equal(1, #p.logged("error", "boom"))
    end)
  end)

  describe("reconnecting", function()
    -- C3's idempotency depends on this: the portal recognises a retry only
    -- by its id.
    it("resends every unanswered frame under its original id, in order", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local a = connection:send("create_character", character())
      local b = connection:send("player_dropped", dropped())
      local texts = { p.sent[#p.sent - 1], p.sent[#p.sent] }

      reconnect(p)

      -- After the new Hello and the ack of its Welcome, the same bytes again.
      assert.are.equal(texts[1], p.sent[#p.sent - 1])
      assert.are.equal(texts[2], p.sent[#p.sent])
      assert.are.same({ a, b }, { connection.outbox[1].id, connection.outbox[2].id })
    end)

    it("backs off exponentially, capped, with jitter on top", function()
      local p = support.fake_platform()
      rpf.start_server(p, { url = "ws://portal", api_key = "k" })
      for _ = 1, 9 do
        p.drop()
        p.advance(10 * 60 * 1000)
      end

      -- Drop k happened at (k - 1) * ten minutes, and connect k + 1 followed
      -- it by the backoff for attempt k.
      local o = rpf.client.DEFAULTS
      assert.are.equal(10, #p.connects)
      for i = 2, #p.connects do
        local delay = p.connects[i] - (p.connects[1] + (i - 2) * 10 * 60 * 1000)
        local base = math.min(o.backoff_max_ms, o.backoff_base_ms * 2 ^ (i - 2))
        assert.is_true(delay >= base, "attempt " .. (i - 1) .. " waited " .. delay .. " < " .. base)
        assert.is_true(delay < base * (1 + o.jitter), "attempt " .. (i - 1) .. " waited " .. delay)
      end
      -- Capped: by the ninth attempt the base has long passed the maximum.
      assert.is_true(p.connects[10] - (p.connects[1] + 8 * 10 * 60 * 1000) < o.backoff_max_ms * (1 + o.jitter))
    end)

    it("jitters, so servers that dropped together do not return together", function()
      local delays = {}
      for seed = 1, 5 do
        support.load_core()
        local p = support.fake_platform({ seed = seed * 7919 })
        rpf.start_server(p, { url = "ws://portal", api_key = "k" })
        p.drop()
        p.advance(10 * 60 * 1000)
        delays[#delays + 1] = p.connects[2] - p.connects[1]
      end
      local distinct = {}
      for _, d in ipairs(delays) do
        distinct[d] = true
      end
      local count = 0
      for _ in pairs(distinct) do
        count = count + 1
      end
      assert.is_true(count >= 4, "delays: " .. table.concat(delays, ", "))
    end)

    it("resets the backoff after a Welcome", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      for _ = 1, 4 do
        p.drop()
        p.advance(10 * 60 * 1000)
      end
      assert.are.equal(4, connection.attempt)
      p.open()
      welcome(p)
      assert.are.equal(0, connection.attempt)
    end)

    it("ignores events from a connection it has replaced", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local old = assert(p.socket)
      reconnect(p)
      local before = #p.sent
      old.handlers.close("late")
      old.handlers.message(p.sent[1])
      assert.are.equal("ready", connection.state)
      assert.are.equal(before, #p.sent)
    end)
  end)

  describe("the persisted outbox", function()
    it("survives a restart, and resends under the original id", function()
      local store = {}
      local p = support.fake_platform({ store = store })
      local connection = support.connected(p)
      local id = connection:send("create_character", character())
      local text = p.sent[#p.sent]

      support.load_core()
      local restarted = support.fake_platform({ store = store, seed = 4242 })
      support.connected(restarted)

      assert.are.equal(text, restarted.sent[#restarted.sent])
      assert.are.equal(id, restarted.last().id)
    end)

    it("persists before sending, so a crash right after send loses nothing", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local stored_at_send
      local send = p.send
      p.send = function(text)
        stored_at_send = #stored_outbox(p)
        return send(text)
      end
      connection:send("player_dropped", dropped())
      assert.are.equal(1, stored_at_send)
    end)

    it("skips a corrupt stored entry and keeps the rest", function()
      local store = {}
      local first = support.connected(support.fake_platform({ store = store }))
      first:send("player_dropped", dropped())
      first:send("player_dropped", dropped())
      first:send("player_dropped", dropped())
      local raw = store[rpf.client.OUTBOX_PREFIX .. 2]
      store[rpf.client.OUTBOX_PREFIX .. 2] = raw:sub(1, #raw - 1)
      store[rpf.client.OUTBOX_PREFIX .. 3] = '{"id":1}'

      support.load_core()
      local p = support.fake_platform({ store = store })
      local connection = rpf.client.new(p, { url = "ws://portal", api_key = "k", instance_id = "i" })
      assert.are.equal(1, #connection.outbox)
      assert.are.equal(2, #p.logged("error", "unreadable; whatever it held is lost"))
      -- Left for a human to look at, not overwritten by the next send.
      connection:send("player_dropped", dropped())
      assert.are.equal('{"id":1}', store[rpf.client.OUTBOX_PREFIX .. 3])
      assert.are.equal("4", store[rpf.client.SLOTS_KEY])
    end)

    it("never holds a Hello or an Ack", function()
      local p = support.fake_platform()
      support.connected(p)
      reconnect(p)
      for _, entry in ipairs(stored_outbox(p)) do
        assert.are_not.equal("hello", entry.type)
        assert.are_not.equal("ack", entry.type)
      end
      assert.are.equal(0, #stored_outbox(p))
    end)
  end)

  describe("the retry window", function()
    -- C3's suggested TTL, which is the default.
    local window = 7 * DAY

    -- A long outage must never throw away a state report, and must never
    -- replay a request the portal may have forgotten.
    it("reissues a reissuable frame under a fresh id, and drops the rest, after a long outage", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local lost
      local report = connection:send("player_dropped", dropped())
      local request = connection:send("create_character", character(), function(_, err)
        lost = err
      end)

      p.drop()
      p.advance(window)
      p.open()
      welcome(p)

      local reports = sent_of(p, "player_dropped")
      local fresh = reports[#reports]
      assert.are_not.equal(report, fresh.id)
      assert.are.equal(PLAYER, fresh.player_id)
      -- Reissued by the sweep during the outage, so stamped then, not at the
      -- original send.
      assert.are_not.equal(rpf.protocol.timestamp(support.EPOCH_MS), fresh.sent_at)
      for _, frame in ipairs(sent_of(p, "create_character")) do
        assert.are.equal(request, frame.id, "the request is never sent under another id")
      end
      assert.are.equal(1, #connection.outbox)
      assert.are.equal("expired", lost)
      assert.are.equal(1, #p.logged("warn", "dropping create_character"))
    end)

    it("acts at the window minus the margin, not before", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local id = connection:send("player_dropped", dropped())
      local o = rpf.client.DEFAULTS

      p.advance(o.retry_window_ms - o.window_margin_ms - o.sweep_interval_ms - 1)
      assert.are.equal(id, connection.outbox[1].id)
      p.advance(o.sweep_interval_ms + 1)
      assert.are_not.equal(id, connection.outbox[1].id)
      -- Sent at once, because the connection is up.
      assert.are.equal(connection.outbox[1].id, p.last().id)
    end)

    it("keeps a reissued frame's callback", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local got
      connection:send("player_dropped", dropped(), function(reply)
        got = reply
      end)
      p.advance(window)
      p.deliver(support.portal_frame("ack", { re = connection.outbox[1].id }))
      assert.are.equal("ack", got.type)
    end)

    it("reissues a reissuable frame the portal refuses as expired", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local id = connection:send("player_dropped", dropped())
      p.deliver(support.portal_frame("rejected", { re = id, code = "expired", reason = "too old" }))
      assert.are.equal(1, #connection.outbox)
      assert.are_not.equal(id, connection.outbox[1].id)
      local reports = sent_of(p, "player_dropped")
      assert.are.equal(connection.outbox[1].id, reports[#reports].id)
    end)

    it("drops a non-reissuable frame the portal refuses as expired", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local got
      local id = connection:send("create_character", character(), function(reply)
        got = reply
      end)
      p.deliver(support.portal_frame("rejected", { re = id, code = "expired", reason = "too old" }))
      assert.are.equal(0, #connection.outbox)
      assert.are.equal("expired", got.code)
    end)

    it("survives a restart with an old outbox: reissued or dropped before anything is sent", function()
      local store = {}
      local p = support.fake_platform({ store = store })
      local connection = support.connected(p)
      local report = connection:send("player_dropped", dropped())
      local request = connection:send("create_character", character())

      support.load_core()
      local restarted = support.fake_platform({ store = store, seed = 31337, time = p.time + window })
      support.connected(restarted)

      for _, frame in ipairs(restarted.frames()) do
        assert.are_not.equal(report, frame.id)
        assert.are_not.equal(request, frame.id)
      end
      assert.are.equal(1, #sent_of(restarted, "player_dropped"))
      assert.are.equal(0, #sent_of(restarted, "create_character"))
    end)
  end)

  -- #116: entries are aged by the host clock, so a clock moved back by a
  -- window or more would make a request look young after the portal forgot
  -- its id. The fake's timers are keyed by its clock, so after a step back
  -- these tests drive the sweep by hand rather than waiting for its timer.
  describe("when the host clock goes back", function()
    local window = 7 * DAY

    ---Checks that a step caught while connected closed the connection, then
    ---completes the reconnect it scheduled, so the next `Hello` measures the
    ---portal's offset under the new clock.
    ---@param p spec.FakePlatform The platform, just after the step was caught.
    local function reconnect_after_step(p)
      assert.is_nil(p.socket, "the connection made under the old clock is closed")
      local connects = #p.connects
      p.advance(2 * 60 * 1000)
      assert.are.equal(connects + 1, #p.connects, "and made again")
      p.open()
      welcome(p)
    end

    it("changes nothing for a step under the tolerance", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local report = connection:send("player_dropped", dropped())
      local request = connection:send("create_character", character())
      local sent = #p.sent

      p.time = p.time - rpf.client.DEFAULTS.clock_step_tolerance_ms + 1000
      connection:sweep()

      assert.are.equal(2, #connection.outbox)
      assert.are.equal(report, connection.outbox[1].id)
      assert.are.equal(request, connection.outbox[2].id)
      assert.are.equal(sent, #p.sent, "nothing is resent")
      assert.are.equal(0, #p.logged("warn", "host clock went back"))
    end)

    it("expires every queued request, and reissues the rest, after a step of more than a window", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local lost
      local report = connection:send("player_dropped", dropped())
      local request = connection:send("create_character", character(), function(reply, err)
        lost = { reply = reply, err = err }
      end)

      p.time = p.time - window - DAY
      local stepped = p.time
      connection:sweep()

      assert.are.same({ err = "expired" }, lost)
      assert.are.equal(1, #connection.outbox)
      reconnect_after_step(p)
      local fresh = p.last()
      assert.are.equal("player_dropped", fresh.type)
      assert.are_not.equal(report, fresh.id)
      assert.are.equal(connection.outbox[1].id, fresh.id)
      assert.are.equal(rpf.protocol.timestamp(stepped), fresh.sent_at, "stamped by the new clock")
      for _, frame in ipairs(sent_of(p, "create_character")) do
        assert.are.equal(request, frame.id, "the request is never sent under another id")
      end
      assert.are.equal(1, #p.logged("warn", "host clock went back by " .. (window + DAY) .. " ms"))
      assert.are.equal(1, #p.logged("warn", "dropping create_character"))
      assert.are.equal(string.format("%.0f", p.time), p.store[rpf.client.CLOCK_KEY])
    end)

    it("catches the step at send, before the new frame is stamped", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local old = connection:send("create_character", character())

      p.time = p.time - window - DAY
      local new = connection:send("create_character", character())

      assert.are.equal(1, #connection.outbox)
      assert.are.equal(new, connection.outbox[1].id)
      assert.are_not.equal(old, new)
      assert.are.equal(p.time, connection.outbox[1].sent_ms)
    end)

    it("adds up small steps until they cross the tolerance", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local request = connection:send("create_character", character())
      local step = rpf.client.DEFAULTS.clock_step_tolerance_ms * 2 / 3

      p.time = p.time - step
      connection:sweep()
      assert.are.equal(request, connection.outbox[1].id, "one step is under the tolerance")
      p.time = p.time - step
      connection:sweep()
      assert.are.equal(0, #connection.outbox, "two are not")
    end)

    it("catches a step taken while the process was down, before anything is sent", function()
      local store = {}
      local p = support.fake_platform({ store = store })
      local connection = support.connected(p)
      local report = connection:send("player_dropped", dropped())
      local request = connection:send("create_character", character())
      p.advance(2 * rpf.client.DEFAULTS.sweep_interval_ms)

      support.load_core()
      local restarted = support.fake_platform({ store = store, seed = 31337, time = p.time - window - DAY })
      support.connected(restarted)

      for _, frame in ipairs(restarted.frames()) do
        assert.are_not.equal(report, frame.id)
        assert.are_not.equal(request, frame.id)
      end
      assert.are.equal(1, #sent_of(restarted, "player_dropped"))
      assert.are.equal(0, #sent_of(restarted, "create_character"))
      assert.are.equal(1, #restarted.logged("warn", "the host clock went back by"))
    end)

    -- The stored mark moves only with the sweep, so it can trail the newest
    -- entry by a whole sweep interval: here 59 s, which with a step of 80 s
    -- leaves the clock only 21 s under it, inside the tolerance. The entry's
    -- own stamp is what shows the step.
    it("catches a step after a restart that the last sweep's mark alone would miss", function()
      local store = {}
      local p = support.fake_platform({ store = store })
      local connection = support.connected(p)
      local swept = store[rpf.client.CLOCK_KEY]
      p.advance(rpf.client.DEFAULTS.sweep_interval_ms - 1000)
      local id = connection:send("player_dropped", dropped())
      assert.are.equal(swept, store[rpf.client.CLOCK_KEY], "no sweep has run since")

      support.load_core()
      local restarted = support.fake_platform({ store = store, seed = 31337, time = p.time - 80 * 1000 })
      support.connected(restarted)

      local reports = sent_of(restarted, "player_dropped")
      assert.are.equal(1, #reports)
      assert.are_not.equal(id, reports[1].id, "reissued, not resent under the old id")
      assert.are.equal(rpf.protocol.timestamp(restarted.time), reports[1].sent_at, "stamped by the new clock")
      assert.are.equal(1, #restarted.logged("warn", "the host clock went back by " .. (80 * 1000) .. " ms"))
    end)

    it("treats an unreadable stored mark as a step", function()
      local store = {}
      local p = support.fake_platform({ store = store })
      support.connected(p):send("create_character", character())
      store[rpf.client.CLOCK_KEY] = "not a time"

      support.load_core()
      local restarted = support.fake_platform({ store = store, seed = 31337, time = p.time })
      local connection = support.connected(restarted)

      assert.are.equal(0, #connection.outbox)
      assert.are.equal(0, #sent_of(restarted, "create_character"))
      assert.are.equal(1, #restarted.logged("error", "clock high-water mark is unreadable"))
      assert.are.equal(string.format("%.0f", restarted.time), store[rpf.client.CLOCK_KEY])
    end)

    it("persists the mark from the sweep, not from each send", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local stored = p.store[rpf.client.CLOCK_KEY]
      assert.are.equal(string.format("%.0f", p.time), stored)

      p.time = p.time + 1000
      connection:send("player_dropped", dropped())
      assert.are.equal(stored, p.store[rpf.client.CLOCK_KEY])
      connection:sweep()
      assert.are.equal(string.format("%.0f", p.time), p.store[rpf.client.CLOCK_KEY])
    end)

    it("restarts a running portal request's timeout from the step", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      connection:handle("apply_command", function() end)
      p.deliver(support.portal_frame("apply_command", {
        command = {
          command = "adjust_balance",
          client_id = "00000008-0000-4000-8000-000000000008",
          account_id = "00000004-0000-4000-8000-000000000004",
          amount = -250,
          description = "Admin correction.",
        },
      }))
      assert.are.equal(1, connection.request_count, "the handler is running")
      local o = rpf.client.DEFAULTS

      p.time = p.time - window
      local stepped = p.time
      connection:sweep()
      reconnect_after_step(p)
      p.time = stepped + o.request_timeout_ms - 1
      connection:sweep()
      assert.are.equal(0, #sent_of(p, "command_applied"), "not before its timeout")
      p.time = p.time + 1
      connection:sweep()
      local replies = sent_of(p, "command_applied")
      assert.are.equal(1, #replies)
      assert.are.equal("unknown", replies[1].outcome.outcome)
    end)

    -- The portal reads `sent_at` against the offset it measured at this
    -- connection's `Hello`, under the old clock. A frame reissued under the
    -- new one would look older by the step there, be refused `expired`, be
    -- reissued, and be refused again, for as long as the connection lasted.
    it("makes the connection again before sending anything under the new clock", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local report = connection:send("player_dropped", dropped())
      local sent = #p.sent

      p.time = p.time - window - DAY
      connection:sweep()

      assert.are.equal(sent, #p.sent, "nothing goes out on the connection whose offset is the old clock's")
      assert.are.equal(1, #p.disconnects)
      assert.are.equal("connecting", connection.state)
      reconnect_after_step(p)

      local after = {}
      for i, frame in ipairs(p.frames()) do
        if i > sent then
          after[#after + 1] = frame
        end
      end
      assert.are.equal("hello", after[1].type, "a fresh Hello measures the offset first")
      local reports = {}
      for _, frame in ipairs(after) do
        if frame.type == "player_dropped" then
          reports[#reports + 1] = frame
        end
      end
      assert.are.equal(1, #reports, "the reissued report goes out once")
      assert.are_not.equal(report, reports[1].id)
      assert.are.equal(connection.outbox[1].id, reports[1].id)
    end)

    it("sends what a callback sends during the step once, after the new Welcome", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local retried
      connection:send("create_character", character(), function(_, err)
        assert.are.equal("expired", err)
        retried = connection:send("player_dropped", dropped())
      end)
      local sent = #p.sent

      p.time = p.time - window - DAY
      connection:sweep()

      assert.is_string(retried)
      assert.are.equal(sent, #p.sent, "not on the old connection")
      assert.are.equal(1, #p.disconnects, "the callback's send is not taken for a second step")
      assert.are.equal(1, #p.logged("warn", "the host clock went back by"))
      reconnect_after_step(p)
      local reports = sent_of(p, "player_dropped")
      assert.are.equal(1, #reports)
      assert.are.equal(retried, reports[1].id)
    end)

    it("makes the connection again when the step comes between Hello and Welcome", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      connection:send("player_dropped", dropped())
      p.drop()
      p.advance(2 * 60 * 1000)
      p.open()
      local sent = #p.sent
      local reports = #sent_of(p, "player_dropped")

      p.time = p.time - window - DAY
      welcome(p)

      assert.are.equal(sent + 1, #p.sent, "only the Welcome's ack goes out on it")
      assert.are.equal("ack", p.last().type)
      assert.are.equal("connecting", connection.state)
      reconnect_after_step(p)
      assert.are.equal("ready", connection.state)
      assert.are.equal(reports + 1, #sent_of(p, "player_dropped"), "the reissued report, once")
    end)

    it("never overwrites a stored mark it could not read when recovery failed", function()
      local store = {}
      local p = support.fake_platform({ store = store })
      support.connected(p):send("create_character", character())
      local mark = store[rpf.client.CLOCK_KEY]
      store[rpf.client.SLOTS_KEY] = "unreadable"

      support.load_core()
      local restarted = support.fake_platform({ store = store, seed = 4242, time = p.time - window - DAY })
      local broken = support.connected(restarted)
      restarted.advance(2 * rpf.client.DEFAULTS.sweep_interval_ms)
      broken:sweep()

      assert.are.equal(mark, store[rpf.client.CLOCK_KEY], "the higher mark is left for the repaired process")
      assert.are.equal(0, #restarted.logged("warn", "the host clock went back"))
    end)
  end)

  describe("requests from the portal", function()
    ---An ApplyCommand frame.
    ---@return rpf.Frame frame The frame.
    local function command()
      return support.portal_frame("apply_command", {
        command = {
          command = "adjust_balance",
          client_id = "00000008-0000-4000-8000-000000000008",
          account_id = "00000004-0000-4000-8000-000000000004",
          amount = -250,
          description = "Admin correction.",
        },
      })
    end

    it("hands a request to its handler, whose reply names it and waits for an Ack", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local seen
      connection:handle("apply_command", function(frame, reply)
        seen = frame.command.amount
        reply("command_applied", { outcome = { outcome = "applied" } })
      end)
      local frame = command()
      p.deliver(frame)

      assert.are.equal(-250, seen)
      local reply = p.last()
      assert.are.equal("command_applied", reply.type)
      assert.are.equal(frame.id, reply.re)
      assert.are.equal(1, #connection.outbox)
    end)

    ---Registers a handler that counts its runs and applies at once.
    ---@param connection rpf.Client The connection.
    ---@return { runs: integer } counter How often it ran.
    local function applying(connection)
      local counter = { runs = 0 }
      connection:handle("apply_command", function(_, reply)
        counter.runs = counter.runs + 1
        reply("command_applied", { outcome = { outcome = "applied" } })
      end)
      return counter
    end

    ---Every CommandApplied sent, raw.
    ---@param p spec.FakePlatform The platform.
    ---@return string[] texts The frames, in order.
    local function replies(p)
      local out = {}
      for i, frame in ipairs(p.frames()) do
        if frame.type == "command_applied" then
          out[#out + 1] = p.sent[i]
        end
      end
      return out
    end

    -- A lost reply: the portal never got it, so it resends the command. The
    -- outcome already exists, and the portal must get that one, not a second
    -- run.
    it("answers a duplicate request with the original reply, and runs it once", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local counter = applying(connection)
      local frame = command()
      p.deliver(frame)
      p.deliver(frame)

      assert.are.equal(1, counter.runs)
      local sent = replies(p)
      assert.are.equal(2, #sent)
      assert.are.equal(sent[1], sent[2], "the same bytes, under the same id")
      assert.are.equal(1, #connection.outbox)
    end)

    it("starts nothing for a duplicate while the first is running, and answers both with one reply", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local runs, pending = 0, nil
      connection:handle("apply_command", function(_, reply)
        runs = runs + 1
        pending = reply
      end)
      local frame = command()
      p.deliver(frame)
      local before = #p.sent
      p.deliver(frame)
      assert.are.equal(1, runs)
      assert.are.equal(before, #p.sent, "nothing to say until the handler finishes")

      assert(pending)("command_applied", { outcome = { outcome = "applied" } })
      local sent = replies(p)
      assert.are.equal(1, #sent)
      assert.are.equal(frame.id, p.last().re)
      p.deliver(frame)
      assert.are.equal(1, runs)
      assert.are.equal(sent[1], replies(p)[2])
    end)

    it("resends the reply after a reconnect, and forgets the request once the reply is acked", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local counter = applying(connection)
      local frame = command()
      p.deliver(frame)
      local original = replies(p)[1]

      reconnect(p)
      assert.are.equal(original, p.sent[#p.sent], "flushed under its original id")
      p.deliver(frame)
      assert.are.equal(1, counter.runs)
      assert.are.equal(original, p.sent[#p.sent])

      p.deliver(support.portal_frame("ack", { re = p.last().id }))
      assert.are.equal(0, #connection.outbox)
      assert.are.equal(0, #stored_outbox(p))
      -- A copy already on the wire when the portal acked is not run again.
      p.deliver(frame)
      assert.are.equal(1, counter.runs)
      assert.are.equal(3, #replies(p))
    end)

    it("journals a request before its handler runs", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local stored
      connection:handle("apply_command", function(_, reply)
        stored = stored_outbox(p)
        reply("command_applied", { outcome = { outcome = "applied" } })
      end)
      p.deliver(command())
      assert.are.equal(1, #stored)
      assert.are.equal("apply_command", stored[1].type)
      -- The reply took the journal entry's slot, in one write.
      assert.are.equal(1, #stored_outbox(p))
      assert.are.equal("command_applied", stored_outbox(p)[1].type)
    end)

    -- The window a KV write and a game effect cannot close: the handler
    -- changed the game, and the process died before the outcome was stored.
    it("answers unknown, and never runs again, when a restart interrupted the handler", function()
      local store = {}
      local p = support.fake_platform({ store = store })
      local connection = support.connected(p)
      local balance = 0
      connection:handle("apply_command", function(frame)
        balance = balance + frame.command.amount
        -- Dies here: no reply.
      end)
      local frame = command()
      p.deliver(frame)
      assert.are.equal(-250, balance)

      support.load_core()
      local restarted = support.fake_platform({ store = store, seed = 4242 })
      local again = rpf.start_server(restarted, { url = "ws://portal", api_key = "k" })
      again:handle("apply_command", function(f, reply)
        balance = balance + f.command.amount
        reply("command_applied", { outcome = { outcome = "applied" } })
      end)
      restarted.open()
      welcome(restarted)

      local reply = restarted.last()
      assert.are.equal("command_applied", reply.type)
      assert.are.equal(frame.id, reply.re)
      assert.are.equal("unknown", reply.outcome.outcome)
      assert.are.equal(1, #restarted.logged("warn", "interrupted by a restart"))
      local text = restarted.sent[#restarted.sent]

      restarted.deliver(frame)
      assert.are.equal(-250, balance, "never applied twice")
      assert.are.equal(text, restarted.sent[#restarted.sent])
    end)

    it("resends the stored reply, and does not run again, after a restart before the Ack", function()
      local store = {}
      local p = support.fake_platform({ store = store })
      local counter = applying(support.connected(p))
      local frame = command()
      p.deliver(frame)
      local original = replies(p)[1]

      support.load_core()
      local restarted = support.fake_platform({ store = store, seed = 4242 })
      local again = support.connected(restarted)
      local after = applying(again)
      assert.are.equal(original, restarted.sent[#restarted.sent])
      restarted.deliver(frame)
      assert.are.equal(1, counter.runs)
      assert.are.equal(0, after.runs)
      assert.are.equal(original, restarted.sent[#restarted.sent])
      assert.are.equal("applied", restarted.last().outcome.outcome)

      -- A copy on the wire when the portal acks is ignored after a restart
      -- too, not only in the process that first ran it.
      restarted.deliver(support.portal_frame("ack", { re = restarted.last().id }))
      assert.are.equal(0, #again.outbox)
      local before = #restarted.sent
      restarted.deliver(frame)
      assert.are.equal(0, after.runs)
      assert.are.equal(before, #restarted.sent)
    end)

    for _, case in ipairs({
      { name = "a pending request", reply = false },
      { name = "a reply", reply = true },
    }) do
      it("fails closed when the stored journal entry for " .. case.name .. " is corrupt", function()
        local store = {}
        local p = support.fake_platform({ store = store })
        local connection = support.connected(p)
        if case.reply then
          applying(connection)
        else
          connection:handle("apply_command", function() end)
        end
        local frame = command()
        p.deliver(frame)
        local raw = store[rpf.client.OUTBOX_PREFIX .. 1]
        store[rpf.client.OUTBOX_PREFIX .. 1] = raw:sub(1, #raw - 1)

        support.load_core()
        local restarted = support.fake_platform({ store = store, seed = 4242 })
        local again = support.connected(restarted)
        local after = applying(again)
        assert.are.equal(1, #restarted.logged("error", "answering request " .. frame.id .. " as unknown"))
        assert.are.equal("unknown", restarted.last().outcome.outcome)
        assert.are.equal(frame.id, restarted.last().re)
        restarted.deliver(frame)
        assert.are.equal(0, after.runs, "never run again")
      end)
    end

    it("never runs a request whose corrupt entry names it but not its type", function()
      local store = {}
      local p = support.fake_platform({ store = store })
      support.connected(p):handle("apply_command", function() end)
      local frame = command()
      p.deliver(frame)
      local raw = store[rpf.client.OUTBOX_PREFIX .. 1]
      store[rpf.client.OUTBOX_PREFIX .. 1] = raw:gsub("\napply_command\n", "\nsomething_else\n"):sub(1, -2)

      support.load_core()
      local restarted = support.fake_platform({ store = store, seed = 4242 })
      local after = applying(support.connected(restarted))
      assert.are.equal(1, #restarted.logged("error", "request " .. frame.id .. " will not be run"))
      restarted.deliver(frame)
      assert.are.equal(0, after.runs)
    end)

    it("refuses new work when the slot count is unreadable, even after bounds shrink", function()
      local store = {}
      local p = support.fake_platform({ store = store })
      local first = support.connected(p, { max_entries = 4, max_requests = 1 })
      for _ = 1, 4 do
        first:send("player_dropped", dropped())
      end
      first:handle("apply_command", function() end)
      local frame = command()
      p.deliver(frame)
      assert.are.equal("5", store[rpf.client.SLOTS_KEY])
      local journal = store[rpf.client.OUTBOX_PREFIX .. 5]
      store[rpf.client.SLOTS_KEY] = "unreadable"

      support.load_core()
      local restarted = support.fake_platform({ store = store, seed = 4242 })
      local again = support.connected(restarted, { max_entries = 1, max_requests = 1 })
      local after = applying(again)
      restarted.deliver(frame)
      assert.are.equal(0, after.runs)
      assert.are.equal("unreadable", store[rpf.client.SLOTS_KEY])
      assert.are.equal(journal, store[rpf.client.OUTBOX_PREFIX .. 5])
      local callback_error
      local id, err = again:send("player_dropped", dropped(), function(_, why)
        callback_error = why
      end)
      assert.is_nil(id)
      assert.are.equal("outbox_unavailable", err)
      assert.are.equal(err, callback_error)

      -- Restoring the high-water mark lets the next process find the journal.
      store[rpf.client.SLOTS_KEY] = "5"
      support.load_core()
      local repaired = support.fake_platform({ store = store, seed = 31337 })
      local recovered = support.connected(repaired, { max_entries = 1, max_requests = 1 })
      local recovered_runs = applying(recovered)
      assert.are.equal("unknown", repaired.last().outcome.outcome)
      repaired.deliver(frame)
      assert.are.equal(0, recovered_runs.runs)
    end)

    it("answers unknown when the handler throws, since it may have done part of the work", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      connection:handle("apply_command", function()
        error("boom")
      end)
      p.deliver(command())
      assert.are.equal("unknown", p.last().outcome.outcome)
      assert.are.equal(1, #p.logged("error", "boom"))
    end)

    it("answers unknown when the handler never replies, and ignores a late reply", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local late
      connection:handle("apply_command", function(_, reply)
        late = reply
      end)
      local frame = command()
      p.deliver(frame)
      local o = rpf.client.DEFAULTS
      p.advance(o.request_timeout_ms + o.sweep_interval_ms)
      assert.are.equal("unknown", p.last().outcome.outcome)
      assert.are.equal(frame.id, p.last().re)

      assert(late)("command_applied", { outcome = { outcome = "applied" } })
      assert.are.equal(1, #replies(p), "one outcome per command")
      assert.are.equal(1, #p.logged("warn", "ignored a second reply"))
    end)

    it("ignores a second reply from the handler", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      connection:handle("apply_command", function(_, reply)
        reply("command_applied", { outcome = { outcome = "applied" } })
        reply("command_applied", { outcome = { outcome = "failed", reason = "changed my mind" } })
      end)
      p.deliver(command())
      assert.are.equal(1, #replies(p))
      assert.are.equal("applied", p.last().outcome.outcome)
    end)

    it("answers unknown for a reply that does not encode, because the handler did run", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      connection:handle("apply_command", function(_, reply)
        reply("command_applied", { outcome = { outcome = "sort_of" } })
      end)
      p.deliver(command())
      assert.are.equal("unknown", p.last().outcome.outcome)
    end)

    it("answers unknown when a handler tries to send an Ack as its result", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      connection:handle("apply_command", function(_, reply)
        reply("ack")
      end)
      local frame = command()
      p.deliver(frame)
      assert.are.equal("command_applied", p.last().type)
      assert.are.equal("unknown", p.last().outcome.outcome)
      assert.are.equal(frame.id, p.last().re)
      assert.are.equal(1, #sent_of(p, "ack"), "only the handshake Ack was sent")
      assert.are.equal(1, #p.logged("error", "is not the reply to apply_command"))
    end)

    it("cuts a long failure reason at a character boundary", function()
      local p = support.fake_platform()
      local connection = support.connected(p, { max_reason_bytes = 10 })
      connection:handle("apply_command", function(_, reply)
        -- "é" is two bytes, straddling the limit at bytes 10 and 11.
        reply("command_applied", { outcome = { outcome = "failed", reason = "123456789é and more" } })
      end)
      p.deliver(command())
      assert.are.equal("123456789", p.last().outcome.reason)
    end)

    it("leaves a request unrun and unremembered while the journal is full, so a resend runs it", function()
      local p = support.fake_platform()
      local connection = support.connected(p, { max_requests = 1 })
      local counter = applying(connection)
      local first, second = command(), command()
      p.deliver(first)
      p.deliver(second)
      assert.are.equal(1, counter.runs)
      assert.are.equal(1, #p.logged("warn", "already waiting on the portal"))

      p.deliver(support.portal_frame("ack", { re = p.last().id }))
      p.deliver(second)
      assert.are.equal(2, counter.runs)
      assert.are.equal(second.id, p.last().re)
    end)

    ---A `config` request, as the portal sends one.
    ---@return rpf.Frame frame The frame.
    local function config_request()
      return support.portal_frame("config", {
        version = 2,
        hash = "sha256:2",
        snapshot = assert(rpf.json.decode('{"settings":{"server.welcome_message":"hi"}}')),
      })
    end

    -- The portal never resends a config, so a full journal must not turn
    -- one away: the server would run old config until it reconnects.
    it("runs a config even while the journal is full of commands", function()
      local p = support.fake_platform()
      local connection = support.connected(p, { max_requests = 1 })
      applying(connection)
      p.deliver(command())
      local config = config_request()
      p.deliver(config)

      local reply = p.last()
      assert.are.equal("config_applied", reply.type)
      assert.are.equal(config.id, reply.re)
      assert.are.equal("applied", reply.outcome.outcome)
      assert.are.equal("hi", rpf.config.setting("server.welcome_message"))
    end)

    -- Whether it was stored or not, the next Hello names whichever config
    -- is, so `unknown` is the whole answer the portal needs.
    it("answers a config interrupted by a restart as unknown, and never applies it again", function()
      local store = {}
      local p = support.fake_platform({ store = store })
      local connection = support.connected(p)
      connection:handle("config", function()
        -- Dies here: no reply.
      end)
      local config = config_request()
      p.deliver(config)

      support.load_core()
      local restarted = support.fake_platform({ store = store, seed = 4242 })
      rpf.start_server(restarted, { url = "ws://portal", api_key = "k" })
      restarted.open()
      welcome(restarted)

      local reply = restarted.last()
      assert.are.equal("config_applied", reply.type)
      assert.are.equal(config.id, reply.re)
      assert.are.equal("unknown", reply.outcome.outcome)
      -- The same frame, rebuilt with the restarted core's codec.
      local resent = config_request()
      resent.id, resent.sent_at = config.id, config.sent_at
      restarted.deliver(resent)
      assert.is_nil(rpf.config.version(), "the resend is answered from the journal, not applied")
    end)

    it("refuses a config it has no handler for, rather than leave the portal waiting", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      connection.handlers.config = nil
      p.deliver(config_request())
      local reply = p.last()
      assert.are.equal("config_applied", reply.type)
      assert.are.equal("failed", reply.outcome.outcome)
    end)

    it("does not let a caller send a reply outside a handler", function()
      local connection = support.connected(support.fake_platform())
      local ok, err = pcall(connection.send, connection, "command_applied", {
        re = PLAYER,
        outcome = { outcome = "applied" },
      })
      assert.is_false(ok)
      assert.truthy(tostring(err):find("reply", 1, true))
    end)

    it("acks a duplicate notice again, in case the first ack was lost", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local id = connection:send("create_character", character())
      local created = support.portal_frame("character_created", {
        re = id,
        character = {
          id = "00000003-0000-4000-8000-000000000003",
          server_id = "00000001-0000-4000-8000-000000000001",
          owner = { kind = "player", id = PLAYER },
          first_name = "Jane",
          last_name = "Doe",
          gender = "female",
        },
      })
      p.deliver(created)
      p.deliver(created)
      local acks = sent_of(p, "ack")
      assert.are.equal(created.id, acks[#acks].re)
      assert.are.equal(created.id, acks[#acks - 1].re)
    end)

    it("reports an unhandled command as failed rather than staying silent", function()
      local p = support.fake_platform()
      support.connected(p)
      p.deliver(command())
      local reply = p.last()
      assert.are.equal("command_applied", reply.type)
      assert.are.equal("failed", reply.outcome.outcome)
    end)

    it("drops a frame that does not decode, and sends nothing", function()
      local p = support.fake_platform()
      support.connected(p)
      local before = #p.sent
      p.deliver('{"type":"teleport_everyone"}')
      p.deliver("not json")
      assert.are.equal(before, #p.sent)
      assert.are.equal(2, #p.logged("warn", "dropped a frame"))
    end)
  end)

  describe("the bounded outbox", function()
    ---Every kv_set the core makes from here on, with the size written.
    ---@param p spec.FakePlatform The platform.
    ---@return { key: string, bytes: integer }[] writes The writes, in order.
    local function record_writes(p)
      local writes = {}
      local kv_set = p.kv_set
      p.kv_set = function(key, value)
        writes[#writes + 1] = { key = key, bytes = value and #value or 0 }
        kv_set(key, value)
      end
      return writes
    end

    it("writes only the new entry on each enqueue, however full the outbox is", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      p.drop()
      local writes = record_writes(p)
      local first
      for i = 1, 500 do
        local before = #writes
        connection:send("player_dropped", dropped())
        local bytes = 0
        for j = before + 1, #writes do
          bytes = bytes + writes[j].bytes
        end
        first = first or bytes
        -- One entry, plus the slot count when a new slot is opened.
        assert.is_true(bytes <= first + 8, "enqueue " .. i .. " wrote " .. bytes .. " bytes")
      end
    end)

    -- Several days down: reports keep being produced, and none may vanish.
    it("refuses what does not fit during a long outage, tells the caller, and delivers the rest", function()
      local p = support.fake_platform()
      local connection = support.connected(p, { max_entries = 8 })
      p.drop()
      local accepted, refused, told = {}, 0, 0
      for _ = 1, 20 do
        p.advance(HOUR)
        local id, err = connection:send("player_dropped", dropped(), function(_, e)
          if e == "outbox_full" then
            told = told + 1
          end
        end)
        if id then
          accepted[#accepted + 1] = id
        else
          assert.are.equal("outbox_full", err)
          refused = refused + 1
        end
      end
      assert.are.equal(8, #accepted)
      assert.are.equal(12, refused)
      assert.are.equal(12, told, "every refusal reaches its callback")
      assert.are.equal(8, #stored_outbox(p))
      assert.are.equal(1, #p.logged("warn", "the outbox is full"), "logged once, not per refusal")

      p.advance(2 * 60 * 1000)
      p.open()
      welcome(p)
      local reports = sent_of(p, "player_dropped")
      local flushed = {}
      for i = #reports - 7, #reports do
        flushed[#flushed + 1] = reports[i].id
      end
      assert.are.same(accepted, flushed)
    end)

    it("bounds persisted bytes as well as entries", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      assert(connection:send("player_dropped", dropped()))
      -- Each entry counts its stored size plus room for a reissue's `.mmm`.
      local charge = #stored_outbox(p)[1].raw + 4
      assert.are.equal(charge, connection.outbox[1].bytes)
      support.load_core()
      local q = support.fake_platform()
      local bounded = support.connected(q, { max_bytes = charge * 3 })
      assert.truthy(bounded:send("player_dropped", dropped()))
      assert.truthy(bounded:send("player_dropped", dropped()))
      assert.truthy(bounded:send("player_dropped", dropped()))
      assert.is_nil(bounded:send("player_dropped", dropped()))
    end)

    -- Sent on a whole second, reissued on a fractional one: `sent_at` gains
    -- `.mmm`, and the bound that admitted the entry must still hold.
    it("keeps a reissued entry within the bounds it was admitted under", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      assert(connection:send("player_dropped", dropped()))
      local charge = connection.outbox[1].bytes
      support.load_core()
      local q = support.fake_platform()
      local bounded = support.connected(q, { max_bytes = charge })
      local id = assert(bounded:send("player_dropped", dropped()))
      q.advance(123)
      q.deliver(support.portal_frame("rejected", { re = id, code = "expired", reason = "too old" }))
      local reissued = bounded.outbox[1]
      assert.truthy(rpf.json.decode(reissued.text).sent_at:find("%.%d%d%dZ$"), "reissued on a fractional second")
      assert.is_true(bounded.origin_bytes <= charge)
      assert.are.equal(#stored_outbox(q)[1].raw, charge, "the growth was already counted")

      local limit = #p.sent[#p.sent] + 4
      local exact = support.connected(support.fake_platform(), { max_frame_bytes = limit - 1 })
      assert.is_false(pcall(exact.send, exact, "player_dropped", dropped()), "no room for the reissue's growth")
    end)

    it("keeps room for state reports when requests pile up", function()
      local p = support.fake_platform()
      local connection = support.connected(p, { max_entries = 4 })
      p.drop()
      assert.truthy(connection:send("create_character", character()))
      assert.truthy(connection:send("create_character", character()))
      local id, err = connection:send("create_character", character())
      assert.is_nil(id)
      assert.are.equal("outbox_full", err)
      assert.truthy(connection:send("player_dropped", dropped()))
      assert.truthy(connection:send("player_dropped", dropped()))
      assert.is_nil(connection:send("player_dropped", dropped()))
    end)

    it("still answers a portal command when its own frames fill the outbox", function()
      local p = support.fake_platform()
      local connection = support.connected(p, { max_entries = 2 })
      assert.truthy(connection:send("player_dropped", dropped()))
      assert.truthy(connection:send("player_dropped", dropped()))
      assert.is_nil(connection:send("player_dropped", dropped()))
      connection:handle("apply_command", function(_, reply)
        reply("command_applied", { outcome = { outcome = "applied" } })
      end)
      p.deliver(support.portal_frame("apply_command", {
        command = {
          command = "adjust_balance",
          client_id = "00000008-0000-4000-8000-000000000008",
          account_id = "00000004-0000-4000-8000-000000000004",
          amount = 5,
          description = "x",
        },
      }))
      assert.are.equal("command_applied", p.last().type)
      assert.are.equal(3, #stored_outbox(p))
    end)

    it("takes its frame limit from the portal's", function()
      local limits = support.read("src/portal/limits.rs")
      local expression = limits:match("pub const MAX_FRAME_BYTES: usize = ([%d %*]+);")
      assert.truthy(expression, "MAX_FRAME_BYTES is no longer a product of integer literals")
      local bytes = 1
      for factor in expression:gmatch("%d+") do
        bytes = bytes * tonumber(factor)
      end
      assert.are.equal(bytes, rpf.client.DEFAULTS.max_frame_bytes)
    end)

    it("refuses a frame over the portal's frame limit", function()
      local connection = support.connected(support.fake_platform(), { max_frame_bytes = 100 })
      local ok, err = pcall(connection.send, connection, "player_dropped", {
        player_id = PLAYER,
        reason = string.rep("x", 200),
      })
      assert.is_false(ok)
      assert.truthy(tostring(err):find("frame limit", 1, true))
    end)

    it("restarts with a full queue: keeps every entry, refuses more, and recovers as acks arrive", function()
      local store = {}
      local p = support.fake_platform({ store = store })
      local connection = support.connected(p, { max_entries = 3 })
      p.drop()
      local ids = {}
      for i = 1, 3 do
        ids[i] = connection:send("player_dropped", dropped())
      end

      -- Restarted with a smaller bound than it left behind.
      support.load_core()
      local restarted = support.fake_platform({ store = store, seed = 4242 })
      local again = support.connected(restarted, { max_entries = 2 })
      assert.are.equal(3, #again.outbox)
      assert.are.same(ids, { again.outbox[1].id, again.outbox[2].id, again.outbox[3].id })
      assert.is_nil(again:send("player_dropped", dropped()))

      restarted.deliver(support.portal_frame("ack", { re = ids[1] }))
      assert.is_nil(again:send("player_dropped", dropped()), "still at the bound")
      restarted.deliver(support.portal_frame("ack", { re = ids[2] }))
      local fresh = again:send("player_dropped", dropped())
      assert.truthy(fresh)
      -- The freed slot is reused, so the slots stay within what was ever held.
      assert.are.equal("3", store[rpf.client.SLOTS_KEY])
      assert.are.equal(2, #stored_outbox(restarted))
    end)

    it("shrinks the stored slot count on load when the top slots are empty", function()
      local store = {}
      local connection = support.connected(support.fake_platform({ store = store }))
      for _ = 1, 4 do
        connection:send("player_dropped", dropped())
      end
      -- Answered after the last save of the slot count, as by an older core.
      for i = 2, 4 do
        store[rpf.client.OUTBOX_PREFIX .. i] = nil
      end
      support.load_core()
      rpf.client.new(support.fake_platform({ store = store }), { url = "ws://portal", api_key = "k", instance_id = "i" })
      assert.are.equal("1", store[rpf.client.SLOTS_KEY])
    end)
  end)

  it("never logs the API key", function()
    local p = support.fake_platform()
    local connection = support.connected(p)
    connection:send("create_character", character())
    reconnect(p)
    p.deliver(support.portal_frame("rejected", { re = p.frames()[1].id, code = "forbidden", reason = "x" }))
    for _, line in ipairs(p.logs) do
      assert.is_nil(line.message:find("rpf_test_secret", 1, true), line.message)
    end
  end)
end)
