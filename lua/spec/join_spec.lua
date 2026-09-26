-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The server side of a login, with the test playing both the portal (frames)
-- and the player's client (handoff messages). Every client message is
-- hostile input, and a player who never logs in is kicked with a reason that
-- blames the right party.

local support = require("spec.support")

local PLAYER = "00000002-0000-4000-8000-000000000002"
local SERVER = "00000001-0000-4000-8000-000000000001"
local MINUTE = 60 * 1000

local READY = "rpf:client_ready"
local NONCE = "rpf:join_nonce"
local NONCE_REQUEST = "rpf:join_nonce_request"
local TICKET = "rpf:join_ticket"
local RESULT = "rpf:join_result"

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

---Answers the latest BeginJoin with a challenge that lives two minutes by
---the portal's clock.
---@param p spec.FakePlatform The platform.
---@param nonce string? The nonce to hand over.
local function challenge(p, nonce)
  local begins = sent_of(p, "begin_join")
  local frame = support.portal_frame("join_challenge", {
    re = begins[#begins].id,
    nonce = nonce or "rpf_jn_secret",
  })
  frame.expires_at = rpf.protocol.timestamp(rpf.time.parse(frame.sent_at) + 2 * MINUTE)
  p.deliver(frame)
end

---Answers the latest RedeemTicket.
---@param p spec.FakePlatform The platform.
---@param tag string `player_authenticated` or `rejected`.
---@param fields table? Overrides for the answer's fields.
local function answer_redeem(p, tag, fields)
  local redeems = sent_of(p, "redeem_ticket")
  local base = tag == "player_authenticated" and { player_id = PLAYER, username = "sam", created = false }
    or { code = "not_found", reason = "That ticket is not valid." }
  base.re = redeems[#redeems].id
  for key, value in pairs(fields or {}) do
    base[key] = value
  end
  p.deliver(support.portal_frame(tag, base))
end

---Starts a server, completes its handshake, and connects player 7, whose
---client says it is ready.
---@param options rpf.JoinOptions? Login timing overrides.
---@return spec.FakePlatform p The platform.
local function joining(options)
  support.load_core()
  local p = support.fake_platform()
  p.player_identifiers[7] = { "license:abc", "ip:10.0.0.1", "steam:110000100000001" }
  local connection = rpf.start_server(p, { url = "wss://portal.example/ws", api_key = "k", join = options })
  p.open()
  p.deliver(support.portal_frame("welcome", { re = p.last().id, protocol = 1, server_id = SERVER }))
  assert(connection.state == "ready")
  rpf.players.connected(7)
  p.from_client(7, READY, "{}")
  return p
end

---Takes player 7 through a whole login.
---@param options rpf.JoinOptions? Login timing overrides.
---@return spec.FakePlatform p The platform.
local function logged_in(options)
  local p = joining(options)
  challenge(p)
  p.from_client(7, TICKET, '{"ticket":"rpf_jt_ticket"}')
  answer_redeem(p, "player_authenticated")
  assert(rpf.players.get(7).state == "registered")
  return p
end

describe("rpf.join", function()
  it("works out the portal's HTTP address from its websocket url", function()
    support.load_core()
    assert.are.equal("https://portal.example", rpf.join.http_base("wss://portal.example/ws"))
    assert.are.equal("http://localhost:3000", rpf.join.http_base("ws://localhost:3000/ws"))
  end)

  it("moves a ready client to authenticating and asks the portal for a nonce", function()
    local p = joining()
    assert.are.equal("authenticating", rpf.players.get(7).state)
    local begins = sent_of(p, "begin_join")
    assert.are.equal(1, #begins)
    -- ip: identifiers are never stored, so they never leave the server.
    assert.are.same({ "license:abc", "steam:110000100000001" }, begins[1].identifiers)
    assert.are.equal("player 7", begins[1].name)
  end)

  it("passes the nonce to that player's client with its lifetime, the portal and the server", function()
    local p = joining()
    challenge(p, "rpf_jn_abc")
    assert.are.same({
      {
        nonce = "rpf_jn_abc",
        expires_in_ms = 2 * MINUTE,
        portal_url = "https://portal.example",
        server_id = SERVER,
      },
    }, p.messages_to(7, NONCE))
  end)

  it("redeems a ticket and registers the player", function()
    local p = joining()
    challenge(p)
    local registered
    rpf.events.on("players.registered", function(player)
      registered = player
    end)
    p.from_client(7, TICKET, '{"ticket":"rpf_jt_ticket"}')
    assert.are.equal("rpf_jt_ticket", sent_of(p, "redeem_ticket")[1].ticket)
    answer_redeem(p, "player_authenticated", { created = true })
    assert.are.equal(PLAYER, registered.player_id)
    assert.are.equal("sam", registered.username)
    assert.are.same(
      { { ok = true, player_id = PLAYER, username = "sam", created = true } },
      p.messages_to(7, RESULT)
    )
  end)

  it("lets the client try again when a ticket is refused", function()
    local p = joining()
    challenge(p)
    p.from_client(7, TICKET, '{"ticket":"rpf_jt_stale"}')
    answer_redeem(p, "rejected")
    assert.are.same({ { ok = false, reason = "That ticket is not valid." } }, p.messages_to(7, RESULT))
    assert.are.equal("authenticating", rpf.players.get(7).state)
    assert.are.same({}, p.kicks)
  end)

  it("kicks a banned player at redemption", function()
    local p = joining()
    challenge(p)
    p.from_client(7, TICKET, '{"ticket":"rpf_jt_ticket"}')
    answer_redeem(p, "rejected", { code = "forbidden", reason = "Banned until Friday." })
    assert.are.equal(1, #p.kicks)
    assert.truthy(p.kicks[1].reason:find("Banned until Friday.", 1, true))
  end)

  it("kicks a second login to an account already playing here", function()
    local p = logged_in()
    rpf.players.connected(8)
    p.from_client(8, READY, "{}")
    challenge(p)
    p.from_client(8, TICKET, '{"ticket":"rpf_jt_other"}')
    answer_redeem(p, "player_authenticated")
    assert.are.equal(8, p.kicks[1].player)
    assert.are.equal(rpf.join.REASONS.already_online, p.kicks[1].reason)
    assert.are.equal(7, rpf.players.by_player_id(PLAYER).handle)
  end)

  describe("the login timeout", function()
    it("kicks a player who never logs in, saying so", function()
      local p = joining({ auth_timeout_ms = 10 * MINUTE })
      challenge(p)
      p.advance(10 * MINUTE - 1)
      assert.are.same({}, p.kicks)
      p.advance(1)
      assert.are.same({ { player = 7, reason = "You didn't log in within 10 minutes. Reconnect to try again." } }, p.kicks)
    end)

    it("defaults to something generous, because a new player may be choosing a password", function()
      support.load_core()
      assert.is_true(rpf.join.DEFAULTS.auth_timeout_ms >= 10 * MINUTE)
    end)

    it("blames the portal when the connection to it is down", function()
      local p = joining({ auth_timeout_ms = 10 * MINUTE, challenge_timeout_ms = 60 * MINUTE })
      challenge(p)
      p.drop("portal restarting")
      p.advance(10 * MINUTE)
      assert.are.equal(rpf.join.REASONS.portal_unreachable, p.kicks[1].reason)
    end)

    it("blames the portal, early, when it never answers BeginJoin", function()
      local p = joining({ challenge_timeout_ms = 2 * MINUTE })
      p.advance(2 * MINUTE)
      assert.are.equal(1, #p.kicks)
      assert.are.equal(rpf.join.REASONS.portal_unreachable, p.kicks[1].reason)
    end)

    it("blames the portal when a redemption is still unanswered", function()
      local p = joining({ auth_timeout_ms = 10 * MINUTE })
      challenge(p)
      p.from_client(7, TICKET, '{"ticket":"rpf_jt_ticket"}')
      p.advance(10 * MINUTE)
      assert.are.equal(rpf.join.REASONS.portal_unreachable, p.kicks[1].reason)
    end)

    it("blames the portal when the outbox refuses the request", function()
      support.load_core()
      local p = support.fake_platform()
      rpf.start_server(p, { url = "ws://portal", api_key = "k", client = { max_entries = 0 } })
      rpf.players.connected(7)
      p.from_client(7, READY, "{}")
      assert.are.equal(rpf.join.REASONS.portal_unreachable, p.kicks[1].reason)
    end)

    it("leaves a player who logged in alone", function()
      local p = logged_in({ auth_timeout_ms = 10 * MINUTE })
      p.advance(60 * MINUTE)
      assert.are.same({}, p.kicks)
    end)

    it("does not act for a connection that has gone, even if the engine reuses the handle", function()
      local p = joining({ auth_timeout_ms = 10 * MINUTE })
      challenge(p)
      p.advance(5 * MINUTE)
      rpf.players.dropped(7)
      rpf.players.connected(7)
      p.advance(5 * MINUTE)
      assert.are.same({}, p.kicks)
      p.advance(5 * MINUTE)
      assert.are.equal(1, #p.kicks)
    end)
  end)

  describe("client messages", function()
    it("ignores a ticket before the player is authenticating", function()
      support.load_core()
      local p = support.fake_platform()
      support.connected(p)
      rpf.players.connected(7)
      p.from_client(7, TICKET, '{"ticket":"rpf_jt_ticket"}')
      assert.are.same({}, sent_of(p, "redeem_ticket"))
    end)

    it("ignores messages from a player the server does not know", function()
      local p = joining()
      p.from_client(99, READY, "{}")
      p.from_client(99, TICKET, '{"ticket":"x"}')
      assert.are.equal(1, #sent_of(p, "begin_join"))
      assert.are.same({}, sent_of(p, "redeem_ticket"))
    end)

    for _, payload in ipairs({
      "not json",
      "[]",
      '{"ticket":5}',
      "{}",
      string.rep("x", 5000),
      false,
    }) do
      it("drops a malformed ticket: " .. tostring(payload):sub(1, 20), function()
        local p = joining()
        challenge(p)
        p.from_client(7, TICKET, payload)
        assert.are.same({}, sent_of(p, "redeem_ticket"))
        assert.are.equal("authenticating", rpf.players.get(7).state)
      end)
    end

    it("keeps one redemption in flight per player", function()
      local p = joining()
      challenge(p)
      p.from_client(7, TICKET, '{"ticket":"a"}')
      p.from_client(7, TICKET, '{"ticket":"b"}')
      assert.are.equal(1, #sent_of(p, "redeem_ticket"))
    end)

    it("fetches a fresh nonce on request, at most once per interval", function()
      local p = joining({ renew_interval_ms = 10000 })
      challenge(p)
      p.from_client(7, NONCE_REQUEST, "{}")
      assert.are.equal(1, #sent_of(p, "begin_join"))
      p.advance(10000)
      p.from_client(7, NONCE_REQUEST, "{}")
      assert.are.equal(2, #sent_of(p, "begin_join"))
      -- And never a second while one is still unanswered.
      p.advance(10000)
      p.from_client(7, NONCE_REQUEST, "{}")
      assert.are.equal(2, #sent_of(p, "begin_join"))
    end)

    it("treats a repeated ready as a nonce request", function()
      local p = joining({ renew_interval_ms = 10000 })
      challenge(p)
      p.from_client(7, READY, "{}")
      assert.are.equal(1, #sent_of(p, "begin_join"))
      p.advance(10000)
      p.from_client(7, READY, "{}")
      assert.are.equal(2, #sent_of(p, "begin_join"))
    end)

    it("still hands a logged-in player a nonce, because logging out needs one", function()
      local p = logged_in({ renew_interval_ms = 10000 })
      p.advance(10000)
      p.from_client(7, NONCE_REQUEST, "{}")
      challenge(p, "rpf_jn_logout")
      local nonces = p.messages_to(7, NONCE)
      assert.are.equal("rpf_jn_logout", nonces[#nonces].nonce)
      -- A ticket is no use to a logged-in player.
      p.from_client(7, TICKET, '{"ticket":"rpf_jt_again"}')
      assert.are.equal(1, #sent_of(p, "redeem_ticket"))
    end)

    it("never asks for a nonce for a player who is still connecting", function()
      support.load_core()
      local p = support.fake_platform()
      support.connected(p)
      rpf.players.connected(7)
      p.from_client(7, NONCE_REQUEST, "{}")
      assert.are.same({}, sent_of(p, "begin_join"))
    end)
  end)

  it("reports a logged-in player's departure to the portal, and nobody else's", function()
    local p = logged_in()
    rpf.players.connected(8)
    rpf.players.dropped(8, "left")
    rpf.players.dropped(7, "quit")
    local dropped = sent_of(p, "player_dropped")
    assert.are.equal(1, #dropped)
    assert.are.equal(PLAYER, dropped[1].player_id)
    assert.are.equal("quit", dropped[1].reason)
  end)
end)
