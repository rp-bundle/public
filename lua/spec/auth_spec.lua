-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The client side of a login, with the test playing the game server (the
-- handoff messages) and the portal (the HTTP answers). The shapes are P1's
-- endpoints in `crates/rpf-backend/src/player_auth/mod.rs`.

local support = require("spec.support")

local PLAYER = "00000002-0000-4000-8000-000000000002"
local SERVER = "00000001-0000-4000-8000-000000000001"
local PORTAL = "https://portal.example"
local REMEMBER_KEY = "rpf.auth.remember." .. SERVER

local READY = "rpf:client_ready"
local NONCE = "rpf:join_nonce"
local NONCE_REQUEST = "rpf:join_nonce_request"
local TICKET = "rpf:join_ticket"
local RESULT = "rpf:join_result"

---A successful grant, as `register`, `login` and `resume` return it.
---@param overrides table? Fields to change.
---@return table grant The grant.
local function grant(overrides)
  local body = {
    player_id = PLAYER,
    username = "sam",
    created = false,
    ticket = "rpf_jt_ticket",
    ticket_expires_at = "2026-01-01T00:01:00Z",
    remember_token = "rpf_rt_remember",
    remember_token_expires_at = "2026-01-31T00:00:00Z",
    session_token = "rpf_st_session",
    session_token_expires_at = "2026-01-01T12:00:00Z",
    api_token = rpf.json.null,
    api_token_expires_at = rpf.json.null,
  }
  for key, value in pairs(overrides or {}) do
    body[key] = value
  end
  return body
end

---Starts the client and records every auth event.
---@param opts { store: table<string, string>?, time: number? }? A store with a saved login in it.
---@return spec.FakeClient c The platform.
---@return { name: string, value: any }[] seen Events, appended as they arrive.
local function start(opts)
  support.load_core("client")
  local c = support.fake_client_platform(opts)
  local seen = {}
  for _, name in ipairs({ "required", "succeeded", "failed", "password_change_required", "account_deleted" }) do
    rpf.events.on("auth." .. name, function(value)
      seen[#seen + 1] = { name = "auth." .. name, value = value }
    end)
  end
  rpf.start_client(c)
  return c, seen
end

---The server hands the client a nonce.
---@param c spec.FakeClient The platform.
---@param nonce_value string? The nonce.
local function nonce(c, nonce_value)
  c.from_server(NONCE, {
    nonce = nonce_value or "rpf_jn_one",
    expires_in_ms = 120000,
    portal_url = PORTAL,
    server_id = SERVER,
  })
end

---Event names, in order.
---@param seen { name: string }[] The events.
---@return string[] names The names.
local function names(seen)
  local out = {}
  for i, event in ipairs(seen) do
    out[i] = event.name
  end
  return out
end

---Every value in the client's store, concatenated, to look for a secret in.
---@param c spec.FakeClient The platform.
---@return string everything The values.
local function stored(c)
  local out = {}
  for key, value in pairs(c.store) do
    out[#out + 1] = key .. "=" .. value
  end
  return table.concat(out, "\n")
end

---Whether the client logged a warning containing some text.
---@param c spec.FakeClient The platform.
---@param text string The text, matched plainly.
---@return boolean warned True if it did.
local function warned(c, text)
  for _, line in ipairs(c.logs) do
    if line.level == "warn" and line.message:find(text, 1, true) then
      return true
    end
  end
  return false
end

---Logs in with a grant carrying an API token, and lets its refresh fall due.
---@param c spec.FakeClient The platform.
---@param overrides table? Fields of the grant to change.
local function log_in_until_refresh(c, overrides)
  nonce(c)
  rpf.auth.login("sam", "pw")
  local fields = { api_token = "rpf_at_one", api_token_expires_at = "2026-01-01T00:05:00Z" }
  for key, value in pairs(overrides or {}) do
    fields[key] = value
  end
  c.respond(200, grant(fields))
  c.from_server(RESULT, { ok = true, player_id = PLAYER, username = "sam", created = false })
  c.advance(4 * 60 * 1000)
end

---Logs in with a password and completes the redemption.
---@param c spec.FakeClient The platform.
local function log_in(c)
  nonce(c)
  assert(rpf.auth.login("sam", "correct horse"))
  c.respond(200, grant())
  c.from_server(RESULT, { ok = true, player_id = PLAYER, username = "sam", created = false })
end

describe("rpf.auth", function()
  it("tells the server it is ready at start, and again until a nonce arrives", function()
    local c = start()
    assert.are.same({ READY }, c.sent_names())
    c.advance(15000)
    assert.are.same({ READY, READY }, c.sent_names())
    nonce(c)
    c.advance(60000)
    assert.are.same({ READY, READY }, c.sent_names())
  end)

  it("asks for a login when there is no saved one", function()
    local c, seen = start()
    assert.are.equal("waiting", rpf.auth.state())
    nonce(c)
    assert.are.equal("required", rpf.auth.state())
    assert.are.same({ "auth.required" }, names(seen))
    assert.are.equal(rpf.auth.PASSWORD_REUSE_WARNING, seen[1].value.warning)
    assert.is_nil(c.pending())
  end)

  it("carries P1's password-reuse warning word for word", function()
    support.load_core("client")
    local rust = support.read("crates/rpf-backend/src/player_auth/mod.rs")
    local warning = rust:match('pub const PASSWORD_REUSE_WARNING: &str = "(.-)";')
    warning = warning:gsub("\\\n%s*", "")
    assert.are.equal(warning, rpf.auth.PASSWORD_REUSE_WARNING)
  end)

  it("refuses to start before the server has handed over a nonce", function()
    start()
    local ok, err = rpf.auth.login("sam", "pw")
    assert.is_false(ok)
    assert.truthy(tostring(err):find("not started", 1, true))
  end)

  describe("a password login", function()
    it("posts the nonce and credentials straight to the portal", function()
      local c = start()
      nonce(c, "rpf_jn_abc")
      assert.is_true((rpf.auth.login("sam", "correct horse")))
      local request = assert(c.pending())
      assert.are.equal("POST", request.method)
      assert.are.equal(PORTAL .. "/api/v1/player/login", request.url)
      assert.are.same({ nonce = "rpf_jn_abc", username = "sam", password = "correct horse" }, request.body)
      assert.are.equal("working", rpf.auth.state())
    end)

    it("saves the remember token, keeps the session token in memory only, and hands the ticket over", function()
      local c = start()
      nonce(c)
      rpf.auth.login("sam", "correct horse")
      c.respond(200, grant())
      local saved = assert(rpf.json.decode(c.store[REMEMBER_KEY]))
      assert.are.equal("rpf_rt_remember", saved.token)
      assert.is_nil(stored(c):find("rpf_st_session", 1, true))
      assert.is_nil(stored(c):find("correct horse", 1, true))
      assert.are.same({ READY, TICKET }, c.sent_names())
      assert.are.equal('{"ticket":"rpf_jt_ticket"}', c.to_servers[2].payload)
      assert.are.equal("redeeming", rpf.auth.state())
    end)

    it("succeeds once the server has redeemed the ticket", function()
      local c, seen = start()
      log_in(c)
      assert.are.equal("authenticated", rpf.auth.state())
      assert.are.same({ "auth.required", "auth.succeeded" }, names(seen))
      assert.are.same({ player_id = PLAYER, username = "sam", created = false }, seen[2].value)
      assert.are.same({ player_id = PLAYER, username = "sam", created = false }, rpf.auth.account())
      local ok, err = rpf.auth.login("sam", "again")
      assert.is_false(ok)
      assert.truthy(tostring(err):find("already logged in", 1, true))
    end)

    it("does not save a login the player asked not to keep", function()
      local c = start()
      nonce(c)
      rpf.auth.login("sam", "pw", { remember = false })
      c.respond(200, grant())
      assert.is_nil(c.store[REMEMBER_KEY])
      assert.are.equal(TICKET, c.sent_names()[2])
    end)

    it("fails with the portal's code and message", function()
      local c, seen = start()
      nonce(c)
      rpf.auth.login("sam", "wrong")
      c.respond(401, { error = "invalid_credentials", message = "That username and password do not match." })
      assert.are.equal("required", rpf.auth.state())
      assert.are.same({
        code = "invalid_credentials",
        message = "That username and password do not match.",
        during = "login",
      }, seen[2].value)
    end)

    it("passes the wait on when rate limited", function()
      local c, seen = start()
      nonce(c)
      rpf.auth.login("sam", "wrong")
      c.respond(429, { error = "too_many_attempts", message = "Too many attempts.", retry_after = 30 })
      assert.are.equal(30, seen[2].value.retry_after)
    end)

    it("says an unreachable portal is not the player's fault", function()
      local c, seen = start()
      nonce(c)
      rpf.auth.login("sam", "pw")
      c.respond(0, "")
      assert.are.equal("portal_unreachable", seen[2].value.code)
      assert.truthy(seen[2].value.message:find("isn't a problem with your account", 1, true))
      -- And tells the server, so its timeout kick does not blame the player.
      assert.are.same({ READY, "rpf:join_portal_trouble" }, c.sent_names())
    end)

    it("reports a portal error to the server, but not the player's own mistake", function()
      local c = start()
      nonce(c)
      rpf.auth.login("sam", "wrong")
      c.respond(401, { error = "invalid_credentials", message = "That username and password do not match." })
      assert.are.same({ READY }, c.sent_names())
      rpf.auth.login("sam", "pw")
      c.respond(500, { error = "internal", message = "Something went wrong." })
      assert.are.same({ READY, "rpf:join_portal_trouble" }, c.sent_names())
    end)

    it("treats a garbled success as a portal error, and hands no ticket to the server", function()
      local c, seen = start()
      nonce(c)
      rpf.auth.login("sam", "pw")
      c.respond(200, { player_id = PLAYER })
      assert.are.equal("portal_error", seen[2].value.code)
      assert.are.same({ READY, "rpf:join_portal_trouble" }, c.sent_names())
    end)

    it("fetches a fresh nonce and tries once more when the portal says the nonce ran out", function()
      local c = start()
      nonce(c, "rpf_jn_old")
      rpf.auth.login("sam", "pw")
      c.respond(401, { error = "invalid_nonce", message = "This login has expired." })
      assert.are.same({ READY, NONCE_REQUEST }, c.sent_names())
      nonce(c, "rpf_jn_new")
      assert.are.equal("rpf_jn_new", c.pending().body.nonce)
    end)

    it("asks for a fresh nonce itself when the one it holds is about to run out", function()
      local c = start()
      nonce(c, "rpf_jn_old")
      c.advance(110000)
      rpf.auth.login("sam", "pw")
      assert.is_nil(c.pending())
      assert.are.same({ READY, NONCE_REQUEST }, c.sent_names())
      nonce(c, "rpf_jn_new")
      assert.are.equal("rpf_jn_new", c.pending().body.nonce)
    end)

    it("fails the attempt if the server never sends a fresh nonce", function()
      local c, seen = start()
      nonce(c)
      c.advance(110000)
      rpf.auth.login("sam", "pw")
      c.advance(30000)
      assert.are.equal("invalid_nonce", seen[#seen].value.code)
      assert.are.equal("required", rpf.auth.state())
    end)

    it("refuses a second attempt while one is in flight", function()
      local c = start()
      nonce(c)
      rpf.auth.login("sam", "pw")
      local ok, err = rpf.auth.register("sam", "pw")
      assert.is_false(ok)
      assert.truthy(tostring(err):find("in progress", 1, true))
      assert.are.equal(1, #c.requests)
    end)

    it("starts over when the server refuses the ticket", function()
      local c, seen = start()
      nonce(c)
      rpf.auth.login("sam", "pw")
      c.respond(200, grant())
      c.from_server(RESULT, { ok = false, reason = "That ticket is not valid." })
      assert.are.equal("required", rpf.auth.state())
      assert.are.same({ "auth.required", "auth.failed", "auth.required" }, names(seen))
      assert.are.equal("ticket_refused", seen[2].value.code)
      assert.is_nil(rpf.auth.api_token())
    end)

    it("refuses arguments that are not strings", function()
      local c = start()
      nonce(c)
      assert.has_error(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        rpf.auth.login("sam", nil)
      end)
    end)
  end)

  it("registers through the register endpoint", function()
    local c, seen = start()
    nonce(c)
    rpf.auth.register("newbie", "a long password")
    local request = assert(c.pending())
    assert.are.equal(PORTAL .. "/api/v1/player/register", request.url)
    assert.are.same({ nonce = "rpf_jn_one", username = "newbie", password = "a long password" }, request.body)
    c.respond(200, grant({ username = "newbie", created = true }))
    c.from_server(RESULT, { ok = true, player_id = PLAYER, username = "newbie", created = true })
    assert.is_true(seen[#seen].value.created)
  end)

  it("reports username_taken from registration", function()
    local c, seen = start()
    nonce(c)
    rpf.auth.register("sam", "a long password")
    c.respond(409, { error = "username_taken", message = "That username is taken." })
    assert.are.equal("username_taken", seen[#seen].value.code)
    assert.are.equal("register", seen[#seen].value.during)
  end)

  describe("a password change", function()
    it("is required after a staff reset, and nothing is issued until it happens", function()
      local c, seen = start()
      nonce(c)
      rpf.auth.login("sam", "temporary")
      c.respond(403, { error = "password_change_required", message = "Choose a new password to continue." })
      assert.are.equal("auth.password_change_required", seen[2].name)
      assert.are.same({ username = "sam", message = "Choose a new password to continue." }, seen[2].value)
      assert.are.equal("required", rpf.auth.state())
      assert.is_nil(c.store[REMEMBER_KEY])
    end)

    it("changes the password, then logs in with the new one on the same nonce", function()
      local c, seen = start({ store = { [REMEMBER_KEY] = '{"token":"rpf_rt_old"}' } })
      nonce(c, "rpf_jn_abc")
      c.respond(401, { error = "invalid_token", message = "Your saved login is no longer valid." })
      rpf.auth.change_password("sam", "temporary", "a new password")
      local change = assert(c.pending())
      assert.are.equal(PORTAL .. "/api/v1/player/change_password", change.url)
      assert.are.same(
        { nonce = "rpf_jn_abc", username = "sam", password = "temporary", new_password = "a new password" },
        change.body
      )
      c.respond(204, "")
      local login = assert(c.pending())
      assert.are.equal(PORTAL .. "/api/v1/player/login", login.url)
      assert.are.same({ nonce = "rpf_jn_abc", username = "sam", password = "a new password" }, login.body)
      c.respond(200, grant())
      c.from_server(RESULT, { ok = true, player_id = PLAYER, username = "sam", created = false })
      assert.are.equal("auth.succeeded", seen[#seen].name)
    end)

    it("reports a refused change", function()
      local c, seen = start()
      nonce(c)
      rpf.auth.change_password("sam", "temporary", "short")
      c.respond(400, { error = "invalid_input", message = "Passwords must be at least 10 characters." })
      assert.are.equal("change_password", seen[#seen].value.during)
      assert.are.equal("required", rpf.auth.state())
    end)
  end)

  describe("silent login", function()
    it("resumes from the saved token without asking, and saves its successor", function()
      local c, seen = start({ store = { [REMEMBER_KEY] = '{"token":"rpf_rt_old"}' } })
      nonce(c, "rpf_jn_abc")
      assert.are.equal("resuming", rpf.auth.state())
      local request = assert(c.pending())
      assert.are.equal(PORTAL .. "/api/v1/player/resume", request.url)
      assert.are.same({ nonce = "rpf_jn_abc", remember_token = "rpf_rt_old" }, request.body)
      c.respond(200, grant({ remember_token = "rpf_rt_new" }))
      assert.are.equal("rpf_rt_new", rpf.json.decode(c.store[REMEMBER_KEY]).token)
      c.from_server(RESULT, { ok = true, player_id = PLAYER, username = "sam", created = false })
      assert.are.same({ "auth.succeeded" }, names(seen))
    end)

    it("forgets a token the portal no longer accepts, and asks for a login", function()
      local c, seen = start({ store = { [REMEMBER_KEY] = '{"token":"rpf_rt_old"}' } })
      nonce(c)
      c.respond(401, { error = "invalid_token", message = "Your saved login is no longer valid." })
      assert.is_nil(c.store[REMEMBER_KEY])
      assert.are.same({ "auth.failed", "auth.required" }, names(seen))
      assert.are.equal("required", rpf.auth.state())
    end)

    it("keeps the token through an outage, which says nothing about it", function()
      local c, seen = start({ store = { [REMEMBER_KEY] = '{"token":"rpf_rt_old"}' } })
      nonce(c)
      c.respond(0, "")
      assert.are.equal('{"token":"rpf_rt_old"}', c.store[REMEMBER_KEY])
      assert.are.equal("portal_unreachable", seen[1].value.code)
    end)

    it("keeps the token when the nonce, not the token, was refused", function()
      local c = start({ store = { [REMEMBER_KEY] = '{"token":"rpf_rt_old"}' } })
      nonce(c)
      c.respond(401, { error = "invalid_nonce", message = "This login has expired." })
      nonce(c, "rpf_jn_two")
      c.respond(401, { error = "invalid_nonce", message = "This login has expired." })
      assert.are.equal('{"token":"rpf_rt_old"}', c.store[REMEMBER_KEY])
    end)

    it("keys the saved login by server, so one server's token is not sent to another", function()
      local c = start({ store = { ["rpf.auth.remember.00000009-0000-4000-8000-000000000009"] = '{"token":"rpf_rt_x"}' } })
      nonce(c)
      assert.are.equal("required", rpf.auth.state())
      assert.is_nil(c.pending())
    end)
  end)

  describe("the API token", function()
    it("is refreshed with the session token, never the remember token, before it expires", function()
      local c = start()
      nonce(c)
      rpf.auth.login("sam", "pw")
      c.respond(200, grant({ api_token = "rpf_at_one", api_token_expires_at = "2026-01-01T00:05:00Z" }))
      c.from_server(RESULT, { ok = true, player_id = PLAYER, username = "sam", created = false })
      assert.are.equal("rpf_at_one", rpf.auth.api_token())
      local remembered = c.store[REMEMBER_KEY]

      c.advance(4 * 60 * 1000)
      local refresh = assert(c.pending())
      assert.are.equal(PORTAL .. "/api/v1/player/token", refresh.url)
      assert.are.same({ session_token = "rpf_st_session" }, refresh.body)
      c.respond(200, { api_token = "rpf_at_two", api_token_expires_at = "2026-01-01T00:10:00Z" })
      assert.are.equal("rpf_at_two", rpf.auth.api_token())
      assert.are.equal(remembered, c.store[REMEMBER_KEY])
      assert.is_nil(stored(c):find("rpf_st_session", 1, true))
      assert.is_nil(stored(c):find("rpf_at_", 1, true))
    end)

    it("retries a refresh the portal did not answer, and says so", function()
      local c, seen = start()
      log_in_until_refresh(c)
      c.respond(0, "")
      assert.is_true(warned(c, "the portal did not answer"))
      assert.are.equal("rpf_at_one", rpf.auth.api_token())
      c.advance(30000)
      assert.are.equal(PORTAL .. "/api/v1/player/token", c.pending().url)
      c.respond(503, "Service Unavailable")
      assert.is_true(warned(c, "HTTP 503"))
      c.advance(30000)
      assert.are.equal(PORTAL .. "/api/v1/player/token", c.pending().url)
      assert.are.same({ "auth.required", "auth.succeeded" }, names(seen))
    end)

    it("keeps refreshing, with a warning, when a success cannot be read", function()
      -- A proxy's page, or a portal answering something unexpected, says
      -- nothing about the session: the token in hand is kept, and the
      -- refresh is tried again rather than given up on.
      local answers = {
        { "not json", "not a JSON object" },
        { "[1, 2]", "not a JSON object" },
        { { api_token_expires_at = "2026-01-01T00:10:00Z" }, "had no API token" },
        { { api_token = 5, api_token_expires_at = "2026-01-01T00:10:00Z" }, "had no API token" },
        { '{"api_token":null}', "had no API token" },
        { { api_token = "", api_token_expires_at = "2026-01-01T00:10:00Z" }, "had no API token" },
      }
      for _, case in ipairs(answers) do
        local c, seen = start()
        log_in_until_refresh(c)
        c.respond(200, case[1])
        local label = type(case[1]) == "string" and case[1] or tostring(case[1].api_token)
        assert.is_true(warned(c, case[2]), label)
        assert.are.equal("rpf_at_one", rpf.auth.api_token(), label)
        assert.are.same({ "auth.required", "auth.succeeded" }, names(seen), label)
        c.advance(30000)
        local retry = assert(c.pending(), label)
        assert.are.equal(PORTAL .. "/api/v1/player/token", retry.url, label)
        assert.are.same({ session_token = "rpf_st_session" }, retry.body, label)
        c.respond(200, { api_token = "rpf_at_two", api_token_expires_at = "2026-01-01T00:15:00Z" })
        assert.are.equal("rpf_at_two", rpf.auth.api_token(), label)
      end
    end)

    it("takes a refreshed token whose expiry cannot be read, and refreshes it again soon", function()
      -- Raw JSON, because each case starts a fresh core with its own null.
      for _, expiry in ipairs({ "null", '"soon"', "5" }) do
        local c = start()
        log_in_until_refresh(c)
        c.respond(200, '{"api_token":"rpf_at_two","api_token_expires_at":' .. expiry .. "}")
        assert.are.equal("rpf_at_two", rpf.auth.api_token(), expiry)
        assert.is_true(warned(c, "expiry is missing or unreadable"), expiry)
        c.advance(29999)
        assert.is_nil(c.pending(), expiry)
        c.advance(1)
        assert.are.equal(PORTAL .. "/api/v1/player/token", assert(c.pending()).url, expiry)
      end
    end)

    it("refreshes a granted token whose expiry cannot be read, after a warning", function()
      local c = start()
      nonce(c)
      rpf.auth.login("sam", "pw")
      c.respond(200, grant({ api_token = "rpf_at_one", api_token_expires_at = "whenever" }))
      assert.are.equal("rpf_at_one", rpf.auth.api_token())
      assert.is_true(warned(c, "expiry is missing or unreadable"))
      c.advance(30000)
      assert.are.equal(PORTAL .. "/api/v1/player/token", assert(c.pending()).url)
    end)

    it("stops when the session has ended", function()
      local c, seen = start()
      nonce(c)
      rpf.auth.login("sam", "pw")
      c.respond(200, grant({ api_token = "rpf_at_one", api_token_expires_at = "2026-01-01T00:05:00Z" }))
      c.advance(4 * 60 * 1000)
      c.respond(401, { error = "invalid_token", message = "Your saved login is no longer valid." })
      assert.is_nil(rpf.auth.api_token())
      assert.are.equal("refresh", seen[#seen].value.during)
      c.advance(60 * 60 * 1000)
      assert.is_nil(c.pending())
    end)

    it("is not scheduled while the portal issues none, which is logged", function()
      local c = start()
      log_in(c)
      assert.is_nil(rpf.auth.api_token())
      assert.is_true(warned(c, "issued no API token"))
      c.advance(60 * 60 * 1000)
      assert.is_nil(c.pending())
    end)
  end)

  describe("deleting the account", function()
    it("sends the password with a fresh nonce, then forgets the login and starts nothing more", function()
      local c, seen = start()
      log_in(c)
      assert.is_truthy(c.store[REMEMBER_KEY])
      assert(rpf.auth.delete_account("sam", "correct horse"))
      -- The login spent its nonce, so the client asks the server for one.
      assert.are.equal(NONCE_REQUEST, c.sent_names()[#c.sent_names()])
      nonce(c, "rpf_jn_delete")
      local request = assert(c.pending())
      assert.are.equal(PORTAL .. "/api/v1/player/delete_account", request.url)
      assert.are.same({ nonce = "rpf_jn_delete", username = "sam", password = "correct horse" }, request.body)
      c.respond(204, "")

      assert.are.equal("auth.account_deleted", seen[#seen].name)
      assert.are.same({ username = "sam" }, seen[#seen].value)
      assert.are.equal("deleted", rpf.auth.state())
      assert.is_nil(c.store[REMEMBER_KEY])
      assert.is_nil(rpf.auth.account())
      assert.is_nil(rpf.auth.api_token())
      -- Nothing is left to log in to on this connection.
      local ok, err = rpf.auth.login("sam", "correct horse")
      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("deleted"))
      assert.is_false((rpf.auth.delete_account("sam", "correct horse")))
      assert.is_nil(c.pending())
    end)

    it("reports a refusal and keeps the login, saved login included", function()
      local c, seen = start()
      log_in(c)
      rpf.auth.delete_account("sam", "correct horse")
      nonce(c, "rpf_jn_delete")
      c.respond(401, { error = "invalid_credentials", message = "That username and password do not match." })
      assert.are.equal("auth.failed", seen[#seen].name)
      assert.are.equal("invalid_credentials", seen[#seen].value.code)
      assert.are.equal("delete_account", seen[#seen].value.during)
      assert.are.equal("authenticated", rpf.auth.state())
      assert.is_truthy(c.store[REMEMBER_KEY])
    end)

    it("completes even when a refresh the deletion ended is refused first", function()
      local c, seen = start()
      nonce(c)
      rpf.auth.login("sam", "correct horse")
      c.respond(200, grant({ api_token = "rpf_at_one", api_token_expires_at = "2026-01-01T00:05:00Z" }))
      c.from_server(RESULT, { ok = true, player_id = PLAYER, username = "sam", created = false })
      -- A refresh is on its way when the deletion starts, and is answered
      -- first: refused, because the deletion ended the session.
      c.advance(4 * 60 * 1000)
      assert.are.equal(PORTAL .. "/api/v1/player/token", assert(c.pending()).url)
      assert(rpf.auth.delete_account("sam", "correct horse"))
      nonce(c, "rpf_jn_delete")
      c.respond(401, { error = "invalid_token", message = "Your saved login is no longer valid." })
      assert.are.equal(PORTAL .. "/api/v1/player/delete_account", assert(c.pending()).url)
      c.respond(204, "")
      assert.are.equal("auth.account_deleted", seen[#seen].name)
      assert.are.equal("deleted", rpf.auth.state())
      assert.is_nil(c.store[REMEMBER_KEY])
    end)

    it("is reported even when a logout runs while it is on its way", function()
      local c, seen = start()
      log_in(c)
      assert(rpf.auth.delete_account("sam", "correct horse"))
      nonce(c, "rpf_jn_delete")
      assert.are.equal(PORTAL .. "/api/v1/player/delete_account", assert(c.pending()).url)
      rpf.auth.logout()
      c.respond(204, "")
      assert.are.equal("auth.account_deleted", seen[#seen].name)
      assert.are.equal("deleted", rpf.auth.state())
      assert.is_nil(rpf.auth.account())
    end)

    it("leaves a newer login alone when an abandoned deletion is refused", function()
      local c, seen = start()
      nonce(c, "rpf_jn_delete")
      assert.are.equal("required", rpf.auth.state())
      assert(rpf.auth.delete_account("sam", "correct horse"))
      local deletion = assert(c.pending()).index
      -- The player gives up on it and logs in instead, on a fresh nonce.
      rpf.auth.logout()
      assert(rpf.auth.login("sam", "correct horse"))
      nonce(c, "rpf_jn_login")
      -- The login is answered first, then the old deletion's refusal.
      local login = c.requests[#c.requests]
      assert.is_truthy(login.url:find("/login", 1, true))
      login.answered = true
      login.callback(200, assert(rpf.json.encode(rpf.json.object(grant()))), {})
      local old = c.requests[deletion]
      old.answered = true
      old.callback(401, '{"error":"invalid_credentials","message":"That username and password do not match."}', {})
      assert.are.equal("redeeming", rpf.auth.state())
      c.from_server(RESULT, { ok = true, player_id = PLAYER, username = "sam", created = false })
      assert.are.equal("auth.succeeded", seen[#seen].name)
      assert.are.equal("authenticated", rpf.auth.state())
    end)

    it("retries once with a fresh nonce when the portal says the nonce ran out", function()
      local c = start()
      log_in(c)
      rpf.auth.delete_account("sam", "correct horse")
      nonce(c, "rpf_jn_stale")
      c.respond(401, { error = "invalid_nonce", message = "This login has expired." })
      nonce(c, "rpf_jn_fresh")
      local retry = assert(c.pending())
      assert.are.equal("rpf_jn_fresh", retry.body.nonce)
      c.respond(204, "")
      assert.are.equal("deleted", rpf.auth.state())
    end)

    it("is refused before the server has started the login, and while one is in flight", function()
      local c = start()
      assert.is_false((rpf.auth.delete_account("sam", "pw")))
      nonce(c)
      assert(rpf.auth.login("sam", "pw"))
      assert.is_false((rpf.auth.delete_account("sam", "pw")))
    end)
  end)

  describe("logout", function()
    it("forgets the saved login and revokes it with a fresh nonce for this connection", function()
      local c = start()
      log_in(c)
      rpf.auth.logout()
      assert.is_nil(c.store[REMEMBER_KEY])
      assert.is_nil(rpf.auth.api_token())
      assert.are.equal(NONCE_REQUEST, c.sent_names()[#c.to_servers])
      nonce(c, "rpf_jn_logout")
      local request = assert(c.pending())
      assert.are.equal(PORTAL .. "/api/v1/player/logout", request.url)
      assert.are.same({ nonce = "rpf_jn_logout", remember_token = "rpf_rt_remember" }, request.body)
      c.respond(204, "")
    end)

    it("cancels a login in flight: its late answer is ignored and a new login may start", function()
      local c, seen = start()
      nonce(c)
      rpf.auth.login("sam", "pw", { remember = false })
      rpf.auth.logout()
      assert.are.equal("required", rpf.auth.state())
      c.respond(200, grant())
      assert.are.same({ READY }, c.sent_names())
      assert.is_true((rpf.auth.login("sam", "pw")))
      assert.are.same({ "auth.required" }, names(seen))
    end)

    it("does not pretend to cancel a ticket the server may already have redeemed", function()
      local c, seen = start()
      nonce(c)
      rpf.auth.login("sam", "pw")
      c.respond(200, grant({ api_token = "rpf_at_one", api_token_expires_at = "2026-01-01T00:05:00Z" }))
      rpf.auth.logout()
      assert.are.equal("redeeming", rpf.auth.state())
      nonce(c, "rpf_jn_logout")
      local request = assert(c.pending())
      assert.are.equal(PORTAL .. "/api/v1/player/logout", request.url)
      assert.are.equal("rpf_rt_remember", request.body.remember_token)
      c.respond(204, "")
      c.from_server(RESULT, { ok = true, player_id = PLAYER, username = "sam", created = false })
      -- Logged in for this session, as the server says, with nothing kept.
      assert.are.equal("authenticated", rpf.auth.state())
      assert.are.same({ "auth.required", "auth.succeeded" }, names(seen))
      assert.is_nil(c.store[REMEMBER_KEY])
      assert.is_nil(rpf.auth.api_token())
      c.advance(60 * 60 * 1000)
      assert.is_nil(c.pending())
    end)

    it("never reuses the nonce a silent resume in flight may be consuming", function()
      local c = start({ store = { [REMEMBER_KEY] = '{"token":"rpf_rt_old"}' } })
      nonce(c, "rpf_jn_resume")
      assert.are.equal("rpf_jn_resume", c.pending().body.nonce)
      rpf.auth.logout()
      -- The portal commits the resume first; its late answer is ignored.
      c.respond(200, grant({ remember_token = "rpf_rt_new" }))
      assert.is_nil(c.pending())
      assert.are.equal(NONCE_REQUEST, c.sent_names()[#c.to_servers])
      nonce(c, "rpf_jn_logout")
      local request = assert(c.pending())
      assert.are.equal(PORTAL .. "/api/v1/player/logout", request.url)
      -- The old token still logs out inside the portal's 60 s rotation grace.
      assert.are.same({ nonce = "rpf_jn_logout", remember_token = "rpf_rt_old" }, request.body)
      assert.is_nil(c.store[REMEMBER_KEY])
    end)

    it("still revokes a login the player chose not to keep, from memory", function()
      local c = start()
      nonce(c)
      rpf.auth.login("sam", "pw", { remember = false })
      c.respond(200, grant())
      c.from_server(RESULT, { ok = true, player_id = PLAYER, username = "sam", created = false })
      assert.is_nil(stored(c):find("rpf_rt_remember", 1, true))
      rpf.auth.logout()
      nonce(c, "rpf_jn_logout")
      local request = assert(c.pending())
      assert.are.equal(PORTAL .. "/api/v1/player/logout", request.url)
      assert.are.same({ nonce = "rpf_jn_logout", remember_token = "rpf_rt_remember" }, request.body)
      assert.is_nil(stored(c):find("rpf_rt_remember", 1, true))
    end)

    it("reports a logout the portal did not confirm, which may still hold the login", function()
      for _, case in ipairs({ { 0, "portal_unreachable" }, { 502, "portal_error" }, { 200, "portal_error" } }) do
        local status, code = case[1], case[2]
        local c, seen = start()
        log_in(c)
        rpf.auth.logout()
        nonce(c, "rpf_jn_logout")
        c.respond(status, "")
        assert.is_true(warned(c, "the portal did not confirm the logout (HTTP " .. status .. ")"), tostring(status))
        local failed = seen[#seen]
        assert.are.equal("auth.failed", failed.name, tostring(status))
        assert.are.equal(code, failed.value.code, tostring(status))
        assert.are.equal("logout", failed.value.during, tostring(status))
        -- Forgotten here all the same, and the player stays logged in.
        assert.is_nil(c.store[REMEMBER_KEY], tostring(status))
        assert.are.equal("authenticated", rpf.auth.state(), tostring(status))
      end
    end)

    it("reports nothing once the portal has answered", function()
      local c, seen = start()
      log_in(c)
      rpf.auth.logout()
      nonce(c, "rpf_jn_logout")
      c.respond(204, "")
      assert.are.same({ "auth.required", "auth.succeeded" }, names(seen))
      assert.is_false(warned(c, "logout"))
    end)

    it("does nothing at the portal when nothing is saved", function()
      local c = start()
      nonce(c)
      rpf.auth.logout()
      assert.is_nil(c.pending())
      assert.are.same({ READY }, c.sent_names())
    end)
  end)

  it("ignores a malformed message from the server", function()
    local c = start()
    c.from_server(NONCE, "not json")
    c.from_server(NONCE, { nonce = 5 })
    assert.are.equal("waiting", rpf.auth.state())
    c.from_server(RESULT, { ok = true })
    assert.are.equal("waiting", rpf.auth.state())
  end)
end)
