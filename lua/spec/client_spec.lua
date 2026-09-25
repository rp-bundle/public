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

---The stored outbox, decoded.
---@param p spec.FakePlatform The platform.
---@return table[] entries The entries.
local function stored_outbox(p)
  return rpf.json.decode(p.store[rpf.client.OUTBOX_KEY] or "[]")
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
      rpf.config.save(first, 7, "sha256:sample")

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
      assert.are.equal(1, #p.logged("warn", "config version"))
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
      local good = '{"id":"a","sent_ms":1,"text":"{}","type":"player_dropped"}'
      local p = support.fake_platform({ store = { [rpf.client.OUTBOX_KEY] = "[" .. good .. ',{"id":1}]' } })
      local connection = rpf.client.new(p, { url = "ws://portal", api_key = "k", instance_id = "i" })
      assert.are.equal(1, #connection.outbox)
      assert.are.equal(1, #p.logged("warn", "unreadable"))
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

    it("applies a duplicate request once", function()
      local p = support.fake_platform()
      local connection = support.connected(p)
      local applied = 0
      connection:handle("apply_command", function(_, reply)
        applied = applied + 1
        reply("command_applied", { outcome = { outcome = "applied" } })
      end)
      local frame = command()
      p.deliver(frame)
      p.deliver(frame)
      assert.are.equal(1, applied)
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
