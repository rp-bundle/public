---The player's login, on the player's own client: register, log in, change
---a password, and log back in silently from a saved remember token (P1).
---
---The client talks to the portal directly, over the client platform's
---`http_request`, so no server-side code handles the password. That is a
---mitigation, not a guarantee: the community running the server ships this
---client code, and a modified copy can capture what a player types. So
---wherever a player chooses a password, the UI must show
---`auth.PASSWORD_REUSE_WARNING`, and nothing may claim the server "never
---sees" the password.
---
---Every request carries the join nonce the game server handed this client
---for this connection (`rpf.handoff`, C6), which is what ties a login to a
---real connection. The portal answers with a join ticket, which goes back to
---the game server to redeem; only when the server confirms is the player
---logged in and `auth.succeeded` emitted.
---
---Three tokens come back, and each is kept differently:
---
--- - The **remember token** is written through `kv_set`, keyed by the server's
---   id, because it has to outlive the game. It rotates on every silent login,
---   and the successor is saved before anything else happens. Client storage
---   is readable by other servers on both engines, which is why the portal
---   binds each token to the engine account that started it.
--- - The **session token** is kept in memory only, never in `kv`. It refreshes
---   the API token and nothing else, so refreshing never rotates (and so never
---   risks) the remember token.
--- - The **API token** (P2) is for scripts calling the portal directly. It is
---   refreshed before it expires, and again after `retry_ms` when a refresh
---   gets no usable answer or the expiry cannot be read, each time with a
---   warning. A grant without one (a portal older than P2) is accepted with a
---   warning, and simply has nothing to refresh.
---
---This module is the flow. The login form is the adapter's (Milestone 2): it
---calls these functions and listens for `auth.required`, `auth.succeeded`,
---`auth.failed`, `auth.password_change_required` and `auth.account_deleted`.
---@class rpf.auth
---@field PASSWORD_REUSE_WARNING string P1's warning, which every UI shows at the password field wherever a player chooses one.
---@field REMEMBER_PREFIX string The storage key prefix for remember tokens. The server's id follows it.
---@field DEFAULTS rpf.AuthOptions The production timings.
local auth = {}

local rpf = rpf
local json = rpf.json
local events = rpf.events
local handoff = rpf.handoff
local time = rpf.time

auth.PASSWORD_REUSE_WARNING =
  "The community running this server controls this login screen. Use a password you use nowhere else."
auth.REMEMBER_PREFIX = "rpf.auth.remember."

---Timings for the client's login. Every one has a production default; tests
---shrink them.
---@class rpf.AuthOptions
---@field nonce_margin_ms number? How long before a nonce runs out it is treated as spent, to cover the request's own travel time.
---@field nonce_wait_ms number? How long to wait for a fresh nonce from the server before failing the attempt.
---@field refresh_margin_ms number? How long before the API token expires it is refreshed.
---@field min_refresh_ms number? The shortest wait before a refresh, so a token that looks already expired is not refreshed in a tight loop.
---@field max_refresh_ms number? The longest wait before a refresh. The expiry is read against this client's clock, which may be wrong, so the refresh never waits longer than this whatever the clock says.
---@field retry_ms number? How long to wait before retrying a refresh that got no usable answer, or refreshing a token whose expiry could not be read.
---@field ready_retry_ms number? How often the client tells the server again that it is ready while no nonce has arrived, in case the first message beat the server's own record of the player.
auth.DEFAULTS = {
  nonce_margin_ms = 15 * 1000,
  nonce_wait_ms = 30 * 1000,
  refresh_margin_ms = 60 * 1000,
  min_refresh_ms = 30 * 1000,
  max_refresh_ms = 10 * 60 * 1000,
  retry_ms = 30 * 1000,
  ready_retry_ms = 15 * 1000,
}

---The nonce the server handed over, and where to use it.
---@class rpf.auth.Nonce
---@field value string The nonce. A secret: never logged.
---@field received number When it arrived, by this client's clock.
---@field expires_in_ms number Its lifetime, as the portal measured it.
---@field portal_url string The portal's HTTP address.
---@field server_id string The game server's id, which keys the remember token.
---@field in_use boolean? A request that may consume it is in flight, or was abandoned in flight, so it must not be sent again.

---A request waiting for a nonce.
---@alias rpf.auth.WithNonce fun(nonce: rpf.auth.Nonce)

---@type rpf.ClientPlatform
local platform

---The timings in force: `auth.DEFAULTS` with the caller's overrides.
---@type { nonce_margin_ms: number, nonce_wait_ms: number, refresh_margin_ms: number, min_refresh_ms: number, max_refresh_ms: number, retry_ms: number, ready_retry_ms: number }
local options

---Where the login is. See `rpf.AuthState`.
---@type rpf.AuthState
local state = "waiting"

---The latest nonce, nil once spent or before one arrives.
---@type rpf.auth.Nonce?
local nonce = nil

---The portal address and server id from the last nonce, kept after it is
---spent for refreshes and logout.
---@type { portal_url: string, server_id: string }?
local where = nil

---A request waiting for a fresh nonce, and the generation it was queued in.
---@type { fn: rpf.auth.WithNonce, generation: integer }?
local waiting = nil

---The session token. In memory only: never written through `kv_set`.
---@type string?
local session_token = nil

---The remember token of a login the player chose not to keep. Never saved,
---but held in memory so `logout` can still revoke its family, and with it
---the session and API tokens issued alongside.
---@type string?
local unsaved_token = nil

---The API token (P2), or nil. Handed to scripts through the public API.
---@type string?
local api_token = nil

---The account the pending ticket is for, until the server confirms it.
---@type rpf.AuthResult?
local pending = nil

---The account, once the server has confirmed the login.
---@type rpf.AuthResult?
local account = nil

---Bumped whenever a request or timer should stop mattering.
local generation = 0

---Logs with the core's prefix. Never passed a secret.
---@param level "debug"|"info"|"warn"|"error" How much it matters.
---@param message string The line.
local function log(level, message)
  platform.log(level, "rpf: " .. message)
end

---The storage key for this server's remember token, or nil if the server's
---id is not a uuid (and so not safe to build a key from).
---@return string? key The key.
local function remember_key()
  if not where or not where.server_id:find("^%x+%-%x+%-%x+%-%x+%-%x+$") then
    return nil
  end
  return auth.REMEMBER_PREFIX .. where.server_id:lower()
end

---The saved remember token for this server, if any.
---@return string? token The token. A secret: never logged.
local function saved_token()
  local key = remember_key()
  local raw = key and platform.kv_get(key)
  if not raw then
    return nil
  end
  local stored = json.decode(raw)
  if json.is_object(stored) and type(stored.token) == "string" then
    return stored.token
  end
  log("warn", "ignoring an unreadable saved login")
  return nil
end

---Saves, or with nil forgets, this server's remember token.
---@param token string? The token.
---@param expires_at string? When it expires, for the record.
local function save_token(token, expires_at)
  local key = remember_key()
  if not key then
    if token then
      log("warn", "not saving the login: the server's id is not a uuid")
    end
    return
  end
  if token == nil then
    platform.kv_set(key, nil)
    return
  end
  local text = json.encode(json.object({ token = token, expires_at = expires_at or json.null }))
  platform.kv_set(key, text)
end

---Forgets the session and API tokens, and stops any refresh.
local function drop_session()
  session_token = nil
  api_token = nil
  generation = generation + 1
end

---Ends an attempt with a refusal the UI can show.
---@param failure rpf.AuthFailure What went wrong.
local function fail(failure)
  state = account and "authenticated" or "required"
  pending = nil
  if not account and (failure.code == "portal_unreachable" or failure.code == "portal_error") then
    -- The server cannot see this client's HTTP calls. Telling it keeps a
    -- later timeout kick from blaming the player for the portal's outage.
    platform.to_server(handoff.PORTAL_TROUBLE, handoff.encode(handoff.PORTAL_TROUBLE))
  end
  events.emit("auth.failed", failure)
end

---Posts JSON to one of the portal's player endpoints and calls back with the
---status and the decoded body. A response that is not JSON is passed on as
---nil, which the caller treats as a portal error.
---@param path string The endpoint under `/api/v1/player/`, like `login`.
---@param body table The request body.
---@param callback fun(status: integer, body: table?) Called once.
local function post(path, body, callback)
  if not where then
    callback(0, nil)
    return
  end
  local text = assert(json.encode(json.object(body)))
  platform.http_request(
    "POST",
    where.portal_url .. "/api/v1/player/" .. path,
    { ["Content-Type"] = "application/json" },
    text,
    function(status, response)
      local decoded = nil
      if type(response) == "string" and response ~= "" then
        local value = json.decode(response)
        if json.is_object(value) then
          decoded = value
        end
      end
      callback(status, decoded)
    end
  )
end

---Turns a response that is not a success into a failure: the portal's own
---code and message when it sent them, or an unreachable or broken portal,
---said in a way that does not blame the player.
---@param status integer The HTTP status, 0 when no response arrived.
---@param body table? The decoded body.
---@param during rpf.AuthStep What was being attempted.
---@return rpf.AuthFailure failure The failure.
local function failure_from(status, body, during)
  if status == 0 then
    return {
      code = "portal_unreachable",
      message = "The login service can't be reached. This isn't a problem with your account; try again in a few minutes.",
      during = during,
    }
  end
  if body and type(body.error) == "string" and type(body.message) == "string" and status < 500 then
    return {
      code = body.error,
      message = body.message,
      retry_after = type(body.retry_after) == "number" and body.retry_after or nil,
      during = during,
    }
  end
  return { code = "portal_error", message = "Something went wrong. Please try again.", during = during }
end

---Whether a nonce is still worth sending: the portal's lifetime for it, less
---a margin, measured on this client's clock from when it arrived.
---@param n rpf.auth.Nonce? The nonce.
---@return boolean fresh True if it can be used.
local function fresh(n)
  return n ~= nil and not n.in_use and platform.now() - n.received < n.expires_in_ms - options.nonce_margin_ms
end

---Runs a request with a usable nonce: at once if the current one is fresh,
---or after asking the server for another.
---@param fn rpf.auth.WithNonce The request.
---@param during rpf.AuthStep What it is, for the failure if no nonce comes.
local function with_nonce(fn, during)
  if fresh(nonce) then
    ---@cast nonce rpf.auth.Nonce
    fn(nonce)
    return
  end
  nonce = nil
  local mine = generation
  waiting = { fn = fn, generation = mine }
  platform.to_server(handoff.NONCE_REQUEST, handoff.encode(handoff.NONCE_REQUEST))
  platform.after(options.nonce_wait_ms, function()
    if waiting and waiting.generation == mine and waiting.fn == fn then
      waiting = nil
      if during == "logout" then
        -- Revocation has not reached the portal. A ticket handed to the
        -- server may still succeed, so this must not clear its pending
        -- account or change the login state as `fail` would.
        log("warn", "could not obtain a nonce for logout; the saved login was forgotten here, but may not be revoked")
        ---@type rpf.AuthFailure
        local failure = {
          code = "invalid_nonce",
          message = "Your saved login was forgotten on this device, but the server didn't provide a nonce to cancel it. Change your password to be sure nobody can use it.",
          during = "logout",
        }
        events.emit("auth.failed", failure)
        return
      end
      fail({
        code = "invalid_nonce",
        message = "This login has expired. Reconnect to the server and try again.",
        during = during,
      })
    end
  end)
end

---Checks a grant's shape. The portal is trusted, but a proxy or an old
---portal may answer something else, and a half-read grant is worse than a
---refusal.
---@param body table? The decoded body.
---@return boolean ok True if every field is the type P1 documents.
local function valid_grant(body)
  if not body then
    return false
  end
  for _, field in ipairs({ "player_id", "username", "ticket", "remember_token", "session_token" }) do
    if type(body[field]) ~= "string" then
      return false
    end
  end
  local api = body.api_token
  return type(body.created) == "boolean" and (api == nil or api == json.null or type(api) == "string")
end

---The API token in a grant or refresh, if it is one a script can use.
---@param value any The `api_token` field as the portal wrote it.
---@return string? token The token, or nil for anything else, an empty string included.
local function usable_token(value)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

---Says in a log line why a refresh got no usable answer. Never includes
---the body, which may hold a token.
---@param status integer The HTTP status, 0 when no response arrived.
---@param body table? The decoded body.
---@return string reason The reason.
local function refresh_trouble(status, body)
  if status == 0 then
    return "the portal did not answer"
  end
  if status ~= 200 then
    return "the portal answered HTTP " .. status
  end
  if not body then
    return "the portal's answer was not a JSON object"
  end
  return "the portal's answer had no API token"
end

---Schedules the next API-token refresh, if there is an API token. An expiry
---that cannot be read is logged and refreshed again after `retry_ms`, rather
---than never: a client that stops refreshing finds every call to the portal
---refused a few minutes later, with nothing saying why.
---@param expires_at any When it expires, as the portal wrote it.
local function schedule_refresh(expires_at)
  if not api_token or not session_token then
    return
  end
  local expires = time.parse(expires_at)
  local delay
  if expires then
    delay = expires - platform.now() - options.refresh_margin_ms
    delay = math.max(options.min_refresh_ms, math.min(options.max_refresh_ms, delay))
  else
    log("warn", "the API token's expiry is missing or unreadable; refreshing it again in " .. options.retry_ms .. " ms")
    delay = options.retry_ms
  end
  local mine = generation
  ---Refreshes the API token with the session token, and reschedules.
  local function refresh()
    if mine ~= generation or not session_token then
      return
    end
    post("token", { session_token = session_token }, function(status, body)
      if mine ~= generation then
        return
      end
      if status == 200 and body and usable_token(body.api_token) then
        api_token = usable_token(body.api_token)
        schedule_refresh(body.api_token_expires_at)
      elseif status == 0 or status >= 500 or status < 400 then
        -- An outage, or an answer that is not the portal's (a proxy's
        -- page, a success without a token). Neither says the session
        -- ended, so the token in hand is kept, still good until it
        -- expires, and the refresh is tried again.
        log(
          "warn",
          "could not refresh the API token: "
            .. refresh_trouble(status, body)
            .. "; trying again in "
            .. options.retry_ms
            .. " ms"
        )
        platform.after(options.retry_ms, refresh)
      else
        log("warn", "the session ended; the API token can no longer be refreshed")
        -- Only the tokens, not `drop_session`: without a session token no
        -- refresh runs again, and bumping the generation would also discard
        -- the answer of a request in flight (a deletion, whose portal call
        -- is what ended the session).
        session_token = nil
        api_token = nil
        events.emit("auth.failed", failure_from(status, body, "refresh"))
      end
    end)
  end
  platform.after(delay, refresh)
end

---Takes a grant from `register`, `login` or `resume`: saves the remember
---token first, keeps the rest in memory, and hands the ticket to the server.
---@param body table The grant, already checked.
---@param remember boolean Whether to save the remember token.
local function granted(body, remember)
  nonce = nil
  if remember then
    save_token(body.remember_token, body.remember_token_expires_at)
    unsaved_token = nil
  else
    save_token(nil)
    unsaved_token = body.remember_token
  end
  drop_session()
  session_token = body.session_token
  api_token = usable_token(body.api_token)
  if not api_token then
    -- Only a portal older than P2 issues none, so this is worth a line:
    -- every script's call to the portal will be refused.
    log("warn", "the portal issued no API token; calls to the portal's player API will be refused")
  end
  schedule_refresh(body.api_token_expires_at)
  pending = { player_id = body.player_id, username = body.username, created = body.created }
  state = "redeeming"
  platform.to_server(handoff.TICKET, handoff.encode(handoff.TICKET, { ticket = body.ticket }))
end

---Sends a request that takes the nonce, retrying once with a fresh nonce if
---the portal says the one sent had run out.
---@param step rpf.AuthStep Which request.
---@param body_for fun(n: string): table Builds the body around a nonce.
---@param done fun(status: integer, body: table?) Called with the final response.
local function send_with_nonce(step, body_for, done)
  local retried = false
  ---One attempt, with whatever nonce `with_nonce` found.
  ---@param n rpf.auth.Nonce The nonce.
  local function attempt(n)
    local mine = generation
    -- Until the answer says otherwise, the portal may be consuming this
    -- nonce, so nothing else (a logout, say) may send it meanwhile.
    n.in_use = true
    post(step, body_for(n.value), function(status, body)
      if mine ~= generation then
        -- Abandoned: whether the portal consumed the nonce is unknown, so
        -- it stays in use and the next request fetches a fresh one.
        return
      end
      if status ~= 200 then
        -- Only a grant consumes it; a refusal leaves it usable for a retry.
        n.in_use = false
      end
      if status == 401 and body and body.error == "invalid_nonce" and not retried then
        retried = true
        nonce = nil
        with_nonce(attempt, step)
        return
      end
      done(status, body)
    end)
  end
  with_nonce(attempt, step)
end

---Handles the answer to a request that returns a grant.
---@param step rpf.AuthStep Which request.
---@param remember boolean Whether to save the remember token.
---@param username string? The username, for `auth.password_change_required`.
---@return fun(status: integer, body: table?) handler The handler.
local function on_grant(step, remember, username)
  return function(status, body)
    if status == 200 and valid_grant(body) then
      ---@cast body table
      granted(body, remember)
    elseif status == 403 and body and body.error == "password_change_required" then
      state = "required"
      ---@type rpf.AuthPasswordChange
      local change = { username = username or "", message = body.message }
      events.emit("auth.password_change_required", change)
    else
      if step == "resume" and status == 401 and body and body.error == "invalid_token" then
        -- The saved login is dead: unknown, revoked, expired, or bound to
        -- another engine account. Forget it, so the next join asks. Any
        -- other failure (an outage, a stale nonce) says nothing about the
        -- token, so it is kept for the next try.
        save_token(nil)
      end
      fail(failure_from(status == 200 and 502 or status, body, step))
      if step == "resume" then
        events.emit("auth.required", { warning = auth.PASSWORD_REUSE_WARNING })
      end
    end
  end
end

---Refuses to start an attempt while another is running or once logged in.
---@return boolean ok True if an attempt may start.
---@return string? err Why not.
local function can_start()
  if not where then
    return false, "the server has not started the login yet"
  end
  if state == "working" or state == "resuming" or state == "redeeming" then
    return false, "a login is already in progress"
  end
  if state == "authenticated" then
    return false, "already logged in"
  end
  if state == "deleted" then
    return false, "the account was deleted; reconnect to log in to another"
  end
  return true, nil
end

---Checks that each argument is a string.
---@param names string[] The argument names, for the error.
---@param ... any The arguments.
local function strings(names, ...)
  local values = { ... }
  for i, name in ipairs(names) do
    if type(values[i]) ~= "string" then
      error("rpf: " .. name .. " must be a string", 3)
    end
  end
end

---Starts a login with a username and password. The outcome arrives as an
---event: `auth.succeeded`, `auth.failed`, or `auth.password_change_required`
---when staff have reset the password.
---@param username string The username.
---@param password string The password. Kept in memory for this attempt only (it may be resent once with a fresh nonce), never stored or logged.
---@param opts rpf.AuthLoginOptions? `remember = false` to not save a remember token.
---@return boolean started False if refused at once.
---@return string? err Why.
function auth.login(username, password, opts)
  strings({ "username", "password" }, username, password)
  local ok, err = can_start()
  if not ok then
    return false, err
  end
  local remember = not (opts and opts.remember == false)
  state = "working"
  send_with_nonce("login", function(n)
    return { nonce = n, username = username, password = password }
  end, on_grant("login", remember, username))
  return true, nil
end

---Starts registering a new account, logging in to it on success. The UI must
---show `auth.PASSWORD_REUSE_WARNING` where the player chooses the password.
---@param username string The username wanted.
---@param password string The password chosen.
---@param opts rpf.AuthLoginOptions? `remember = false` to not save a remember token.
---@return boolean started False if refused at once.
---@return string? err Why.
function auth.register(username, password, opts)
  strings({ "username", "password" }, username, password)
  local ok, err = can_start()
  if not ok then
    return false, err
  end
  local remember = not (opts and opts.remember == false)
  state = "working"
  send_with_nonce("register", function(n)
    return { nonce = n, username = username, password = password }
  end, on_grant("register", remember, username))
  return true, nil
end

---Changes a password, then logs in with the new one. This is also how a
---player gets past a staff reset: `password` is the temporary one. The UI
---must show `auth.PASSWORD_REUSE_WARNING` where the player chooses the new
---password. A change revokes every saved login for the account, on every
---device.
---@param username string The username.
---@param password string The current (or temporary) password.
---@param new_password string The new password.
---@param opts rpf.AuthLoginOptions? `remember = false` to not save a remember token.
---@return boolean started False if refused at once.
---@return string? err Why.
function auth.change_password(username, password, new_password, opts)
  strings({ "username", "password", "new_password" }, username, password, new_password)
  local ok, err = can_start()
  if not ok then
    return false, err
  end
  local remember = not (opts and opts.remember == false)
  state = "working"
  send_with_nonce("change_password", function(n)
    return { nonce = n, username = username, password = password, new_password = new_password }
  end, function(status, body)
    if status ~= 204 then
      fail(failure_from(status == 200 and 502 or status, body, "change_password"))
      return
    end
    -- Every remember token was just revoked, this one included.
    save_token(nil)
    -- The nonce was not consumed, so the login can use it straight away.
    send_with_nonce("login", function(n)
      return { nonce = n, username = username, password = new_password }
    end, on_grant("login", remember, username))
  end)
  return true, nil
end

---Forgets the saved login on this device and revokes it at the portal, with
---every session issued alongside it. The player stays in the game; the next
---join asks for a password.
---
---The portal only revokes a remember token for a live join nonce of the same
---guild and engine account (#70), so a token read out of shared client
---storage cannot be used to log its owner out. The client asks the server
---for a fresh nonce for this connection and sends it with the token. The
---token is forgotten here at once either way. The portal answers `204`
---whatever it did, so any other answer means the token may not be revoked:
---that is logged and reported as `auth.failed` with `during = "logout"`,
---because the token may still be valid at the portal. A nonce that never
---arrives is reported the same way, without cancelling a pending ticket.
function auth.logout()
  local token = saved_token() or unsaved_token
  save_token(nil)
  unsaved_token = nil
  drop_session()
  waiting = nil
  if state == "working" or state == "resuming" then
    -- A portal request is in flight and nothing has reached the server yet:
    -- cancel it (the generation has moved on, so its answer is ignored) and
    -- let the player start a fresh login.
    pending = nil
    state = account and "authenticated" or "required"
  end
  -- A ticket already handed to the server is not cancelled: the server may
  -- have redeemed it, and the client must not claim otherwise. Its result is
  -- honoured as usual, which leaves the player exactly where a logout after
  -- login does: in the game for this session, with nothing saved and no
  -- session or API token.
  if not token or not where then
    return
  end
  with_nonce(function(n)
    post("logout", { nonce = n.value, remember_token = token }, function(status)
      if status == 204 then
        return
      end
      -- The portal answers `204` whatever it did with the token, so anything
      -- else (no answer, an error, a proxy's page) means it cannot be known
      -- to have revoked it. The token is forgotten here either way, but may
      -- stay valid at the portal until it expires, which the player should
      -- hear about: they may have logged out because they no longer trust
      -- this device.
      log("warn", "the portal did not confirm the logout (HTTP " .. status .. "); the saved login was forgotten here, but may not be revoked")
      ---@type rpf.AuthFailure
      local failure = {
        code = status == 0 and "portal_unreachable" or "portal_error",
        message = "Your saved login was forgotten on this device, but the login service couldn't confirm it was cancelled. Change your password to be sure nobody can use it.",
        during = "logout",
      }
      events.emit("auth.failed", failure)
    end)
  end, "logout")
end

---Deletes the player's account at the portal (H6), for good: what is left
---is a tombstone nobody can log in to, and its names, identifiers and
---logins are gone. It needs the account's own password (a staff reset's
---temporary one is not enough). An account linked to a staff account is
---deleted too: the link goes with it, and the portal takes its in-game
---permissions away.
---
---Ends in `auth.account_deleted` or `auth.failed`. Once deleted, this
---device's saved login and the session are forgotten, the state is
---`deleted`, and nothing more can be started on this connection: the player
---is still in the game, as the account that no longer exists, until they
---leave, and the adapter should tell them to reconnect.
---@param username string The username.
---@param password string The account's password. Kept in memory for this attempt only (it may be resent once with a fresh nonce), never stored or logged.
---@return boolean started False if refused at once.
---@return string? err Why.
function auth.delete_account(username, password)
  strings({ "username", "password" }, username, password)
  if not where then
    return false, "the server has not started the login yet"
  end
  if state == "working" or state == "resuming" or state == "redeeming" then
    return false, "a login is already in progress"
  end
  if state == "deleted" then
    return false, "the account was deleted"
  end
  state = "working"
  local retried = false
  ---Sends the deletion with a nonce. Unlike `send_with_nonce`, its success
  ---is not tied to `generation`: once the request has gone, the portal may
  ---have deleted the account whatever happened here meanwhile (a logout, a
  ---refused refresh), and a deletion that happened must be reported. A
  ---refusal is, like any abandoned request's: it changed nothing, and the
  ---flow that replaced it must not be disturbed.
  ---@param n rpf.auth.Nonce The nonce.
  local function attempt(n)
    local mine = generation
    n.in_use = true
    post("delete_account", { nonce = n.value, username = username, password = password }, function(status, body)
      -- The portal does not consume the nonce, whatever it answers.
      n.in_use = false
      if status ~= 204 and mine ~= generation then
        -- Abandoned (a logout, and maybe a newer login since): nothing
        -- was deleted, so the flow that replaced this one is left alone.
        return
      end
      if status == 401 and body and body.error == "invalid_nonce" and not retried then
        retried = true
        nonce = nil
        with_nonce(attempt, "delete_account")
        return
      end
      if status ~= 204 then
        fail(failure_from(status == 200 and 502 or status, body, "delete_account"))
        return
      end
      -- The portal deleted every remember and session token the account
      -- had, so there is nothing left to revoke, only to forget.
      save_token(nil)
      unsaved_token = nil
      drop_session()
      waiting, pending, account = nil, nil, nil
      state = "deleted"
      ---@type rpf.AuthDeleted
      local deleted = { username = username }
      events.emit("auth.account_deleted", deleted)
    end)
  end
  with_nonce(attempt, "delete_account")
  return true, nil
end

---Tries the saved remember token, or asks for a login if there is none.
local function resume_or_ask()
  local token = saved_token()
  if not token then
    state = "required"
    events.emit("auth.required", { warning = auth.PASSWORD_REUSE_WARNING })
    return
  end
  state = "resuming"
  send_with_nonce("resume", function(n)
    return { nonce = n, remember_token = token }
  end, on_grant("resume", true, nil))
end

---A nonce from the server.
---@param payload string The payload.
local function on_nonce(payload)
  local fields, err = handoff.decode(handoff.NONCE, payload)
  if not fields then
    log("warn", "dropped a malformed nonce from the server: " .. tostring(err))
    return
  end
  nonce = {
    value = fields.nonce,
    received = platform.now(),
    expires_in_ms = fields.expires_in_ms,
    portal_url = fields.portal_url,
    server_id = fields.server_id,
  }
  where = { portal_url = fields.portal_url, server_id = fields.server_id }
  if waiting then
    local fn = waiting.fn
    waiting = nil
    fn(nonce)
  elseif state == "waiting" then
    resume_or_ask()
  end
end

---Tells the server this client is ready, and again every `ready_retry_ms`
---until the first nonce arrives.
local function announce_ready()
  if state ~= "waiting" then
    return
  end
  platform.to_server(handoff.CLIENT_READY, handoff.encode(handoff.CLIENT_READY))
  local mine = generation
  platform.after(options.ready_retry_ms, function()
    if mine == generation then
      announce_ready()
    end
  end)
end

---The server's answer to the ticket. An unreadable answer ends the pending
---attempt instead of leaving the login blocked, but cannot say whether the
---server redeemed it, so the player is told to reconnect.
---@param payload string The payload.
local function on_result(payload)
  local fields, err = handoff.decode(handoff.RESULT, payload)
  if not fields then
    log("warn", "dropped a malformed join result from the server: " .. tostring(err))
  end
  if state ~= "redeeming" or not pending then
    return
  end
  if fields and fields.ok then
    account = pending
    pending = nil
    state = "authenticated"
    ---@type rpf.AuthResult
    local result = { player_id = account.player_id, username = account.username, created = account.created }
    events.emit("auth.succeeded", result)
  else
    drop_session()
    fail({
      code = "ticket_refused",
      message = fields and (fields.reason or "The server could not log you in. Please try again.")
        or "The server's login reply could not be read. Reconnect to the server and try again.",
      during = "redeem",
    })
    events.emit("auth.required", { warning = auth.PASSWORD_REUSE_WARNING })
  end
end

---Where the login is.
---@return rpf.AuthState state The state.
function auth.state()
  return state
end

---The API token (P2), for scripts calling the portal directly.
---@return string? token The token, or nil before login, from a portal that issues none, or once the session has ended.
function auth.api_token()
  return api_token
end

---Where this client logs in: the portal's address and the game server's
---id, from the last join nonce. Internal, for the core's other calls to the
---player API (`rpf.items`); not part of the public API.
---@return string? portal_url The portal's HTTP address, nil before the first nonce.
---@return string? server_id The game server's id.
function auth.portal()
  if not where then
    return nil, nil
  end
  return where.portal_url, where.server_id
end

---The account this client is logged in as.
---@return rpf.AuthResult? account A copy, or nil before the server confirms the login.
function auth.account()
  if not account then
    return nil
  end
  return { player_id = account.player_id, username = account.username, created = account.created }
end

---Wires the client's login up and tells the server the client is ready.
---Called by `rpf.start_client`.
---@param p rpf.ClientPlatform The platform.
---@param settings rpf.AuthOptions? Timing overrides.
function auth.start(p, settings)
  platform = p
  options = {}
  for key, value in pairs(auth.DEFAULTS) do
    options[key] = value
  end
  for key, value in pairs(settings or {}) do
    options[key] = value
  end
  state, nonce, where, waiting, pending, account = "waiting", nil, nil, nil, nil, nil
  unsaved_token = nil
  drop_session()
  p.on_server(handoff.NONCE, on_nonce)
  p.on_server(handoff.RESULT, on_result)
  announce_ready()
end

rpf.auth = auth
return auth
