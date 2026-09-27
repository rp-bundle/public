---The server side of a player's login: from `connecting` to `registered`.
---
---The flow (C6, P1), as the game server sees it:
---
---1. The client's core starts and says so (`rpf:client_ready`). The player
---   moves to `authenticating` and the server sends `BeginJoin` with the
---   engine's identifiers and the in-game name.
---2. The portal answers `JoinChallenge`. The server passes the nonce to that
---   player's client, with the portal's address and this server's id. The
---   client logs in to the portal directly (`rpf.auth`), so no password passes
---   through here.
---3. The client hands back a join ticket. The server sends `RedeemTicket`,
---   and on `PlayerAuthenticated` moves the player to `registered`.
---
---**Joins fail closed.** A player who has not logged in within
---`auth_timeout_ms` is kicked, and the reason says whose fault it was: if the
---connection to the portal is down, or the portal has left a login request
---unanswered, the player is told the login service is unreachable, not that
---they failed to log in. A portal that does not answer `BeginJoin` within
---`challenge_timeout_ms` fails the join early, for the same reason.
---
---Every client message is hostile input. Only the three handoff messages are
---accepted before `registered`, each only in the state it belongs to, at most
---one request per player is in flight to the portal at a time, and nonces are
---fetched at most once per `renew_interval_ms` per player however often a
---client asks. A logged-in client may still ask for a nonce, because logging
---out needs a live one (#70), under the same limit.
---@class rpf.join
---@field DEFAULTS rpf.JoinOptions The production timings.
---@field REASONS table<string, string> The kick messages, written for the player.
local join = {}

local rpf = rpf
local events = rpf.events
local players = rpf.players
local handoff = rpf.handoff
local time = rpf.time

---Timings for the join. Every one has a production default; tests shrink
---them.
---@class rpf.JoinOptions
---@field auth_timeout_ms number? How long a player may stay unauthenticated, counted from `connecting`. Generous, because it covers loading into the game and a new player reading the form and choosing a password.
---@field challenge_timeout_ms number? How long the portal may take to answer `BeginJoin` before the join fails as unreachable.
---@field renew_interval_ms number? The least time between two nonces for one player, however often their client asks.
join.DEFAULTS = {
  auth_timeout_ms = 15 * 60 * 1000,
  challenge_timeout_ms = 2 * 60 * 1000,
  renew_interval_ms = 10 * 1000,
}

join.REASONS = {
  portal_unreachable = "The login service can't be reached right now, so nobody can join. "
    .. "This isn't a problem with your account. Please try again in a few minutes.",
  timed_out = "You didn't log in within %d minutes. Reconnect to try again.",
  refused = "The server refused your login: %s",
  already_online = "This account is already playing on this server.",
}

---One player's login. Keyed by handle, and compared by identity, so a
---callback for a connection that has since dropped (even if the engine reused
---the handle) finds a different table and does nothing.
---@class rpf.join.Session
---@field handle rpf.PlayerHandle The player.
---@field begin_pending integer? The sequence number of the `BeginJoin` awaiting its answer, if one is.
---@field begins integer How many `BeginJoin`s were sent for this connection.
---@field last_begin number? When the last one was sent, by the platform clock.
---@field redeem_pending boolean Whether a `RedeemTicket` is awaiting its answer.
---@field renew_wanted boolean? Whether a nonce request arrived while a redemption was in flight, to serve once it is answered.
---@field client_trouble boolean? Whether the client said it could not reach the portal. Unverifiable: it only words this player's own kick.
---@field renew_scheduled boolean? Whether a deferred nonce request is waiting for the renewal interval to pass.
---@field portal_failed boolean Whether a request to the portal for this login went unanswered or could not be sent.
---@field kicked boolean Whether the player has been kicked, so nothing else acts for them.

---@type table<any, rpf.join.Session>
local sessions = {}

---@type rpf.ServerPlatform
local platform

---@type rpf.Client
local connection

---@type rpf.JoinOptions
local options

---The portal's HTTP address, which clients log in to.
---@type string
local portal_url

---Logs with the core's prefix.
---@param level "debug"|"info"|"warn"|"error" How much it matters.
---@param message string The line. Never a secret.
local function log(level, message)
  platform.log(level, "rpf: " .. message)
end

---Works out the portal's HTTP address from its websocket url: `wss` becomes
---`https`, `ws` becomes `http`, and the path is dropped, because the player
---endpoints live at the root (`/api/v1/player/…`).
---@param url string The websocket url, like `wss://portal.example/ws`.
---@return string base Like `https://portal.example`.
function join.http_base(url)
  local scheme, rest = url:match("^(wss?)://([^/]+)")
  if not scheme then
    return url
  end
  return (scheme == "wss" and "https" or "http") .. "://" .. rest
end

---Kicks a player, once.
---@param session rpf.join.Session The player's login.
---@param reason string Shown to the player.
local function kick(session, reason)
  if session.kicked then
    return
  end
  session.kicked = true
  log("info", "kicking player " .. tostring(session.handle) .. ": " .. reason)
  platform.kick(session.handle, reason)
end

---Whether a callback still belongs to a live connection: the same session,
---not kicked, and not leaving.
---@param session rpf.join.Session The login the callback was made for.
---@return boolean current True if it may act.
local function current(session)
  return sessions[session.handle] == session and not session.kicked
end

---Whether a callback still belongs to a login in progress: current, and the
---player still `authenticating`.
---@param session rpf.join.Session The login the callback was made for.
---@return boolean live True if it may act on the login.
local function live(session)
  if not current(session) then
    return false
  end
  local player = players.get(session.handle)
  return player ~= nil and player.state == "authenticating"
end

---Whether the portal is to blame for a login that has not finished: the
---connection is down, it has left a request unanswered, or a request could
---not be sent at all.
---@param session rpf.join.Session The login.
---@return boolean blame True if the kick should say the portal is unreachable.
local function portal_at_fault(session)
  return connection.state ~= "ready"
    or session.portal_failed
    or session.client_trouble
    or session.begin_pending ~= nil
    or session.redeem_pending
end

---The identifiers sent in `BeginJoin`: everything the engine reports except
---`ip:`, which is never stored (C6) and so never needs to leave the server.
---@param handle rpf.PlayerHandle The player.
---@return string[] identifiers The identifiers, in the engine's order.
local function identifiers(handle)
  local out = {}
  for _, id in ipairs(platform.identifiers(handle) or {}) do
    if type(id) == "string" and id:sub(1, 3) ~= "ip:" then
      out[#out + 1] = id
    end
  end
  return rpf.json.array(out)
end

---Handles the portal's answer to one `BeginJoin`.
---@param session rpf.join.Session The login.
---@param seq integer Which `BeginJoin` this answers.
---@param reply rpf.Frame? The answer.
---@param err string? Why there was none.
local function challenged(session, seq, reply, err)
  if session.begin_pending == seq then
    session.begin_pending = nil
  end
  if not current(session) then
    return
  end
  local authenticating = live(session)
  if not reply then
    session.portal_failed = true
    log("warn", "BeginJoin went unanswered (" .. tostring(err) .. ")")
    if authenticating then
      kick(session, join.REASONS.portal_unreachable)
    end
  elseif reply.type == "join_challenge" then
    -- Both times are the portal's, so the lifetime is right however far the
    -- clocks here and on the client are from the portal's.
    local expires, sent = time.parse(reply.expires_at), time.parse(reply.sent_at)
    local ttl = (expires and sent) and math.max(expires - sent, 0) or 0
    platform.to_client(
      session.handle,
      handoff.NONCE,
      handoff.encode(handoff.NONCE, {
        nonce = reply.nonce,
        expires_in_ms = ttl,
        portal_url = portal_url,
        server_id = connection.server_id or "",
      })
    )
  elseif reply.type == "rejected" and authenticating then
    kick(session, string.format(join.REASONS.refused, reply.reason))
  elseif reply.type == "rejected" then
    log("warn", "the portal refused a nonce for a logged-in player (" .. reply.code .. ")")
  else
    log("warn", "ignored a " .. reply.type .. " answering BeginJoin")
  end
end

---Asks the portal for a join nonce for a player.
---@param session rpf.join.Session The login.
local function begin(session)
  session.begins = session.begins + 1
  local seq = session.begins
  session.begin_pending = seq
  session.last_begin = platform.now()
  connection:send("begin_join", {
    identifiers = identifiers(session.handle),
    name = platform.name(session.handle),
  }, function(reply, err)
    challenged(session, seq, reply, err)
  end)
  platform.after(options.challenge_timeout_ms, function()
    if session.begin_pending == seq and live(session) then
      session.portal_failed = true
      kick(session, join.REASONS.portal_unreachable)
    end
  end)
end

---Fetches a fresh nonce for a player whose client asked, if nothing is in
---flight for them.
---
---A request inside `renew_interval_ms` of the last `BeginJoin` is not
---dropped, because the client asks once and waits: it is deferred to the end
---of the interval, and any further requests before then fold into that one.
---So a client can never make the server send more than one `BeginJoin` per
---interval, and a fast logout or retry still gets its nonce.
---@param session rpf.join.Session The login.
local function renew(session)
  if session.redeem_pending then
    -- Served once the redemption is answered: a client logging out straight
    -- after handing over its ticket still gets its nonce.
    session.renew_wanted = true
    return
  end
  if session.begin_pending or session.renew_scheduled then
    -- The nonce already on its way answers this request too.
    return
  end
  local wait = session.last_begin and session.last_begin + options.renew_interval_ms - platform.now() or 0
  if wait <= 0 then
    begin(session)
    return
  end
  session.renew_scheduled = true
  platform.after(wait, function()
    session.renew_scheduled = false
    if current(session) then
      -- Through the same rules again, so a redemption that started while it
      -- waited defers it until that is answered rather than losing it.
      renew(session)
    end
  end)
end

---Handles the portal's answer to `RedeemTicket`.
---@param session rpf.join.Session The login.
---@param reply rpf.Frame? The answer.
---@param err string? Why there was none.
local function redeemed(session, reply, err)
  session.redeem_pending = false
  if session.renew_wanted then
    session.renew_wanted = false
    if current(session) then
      renew(session)
    end
  end
  if not live(session) then
    return
  end
  local handle = session.handle
  if not reply then
    session.portal_failed = true
    log("warn", "RedeemTicket went unanswered (" .. tostring(err) .. ")")
    kick(session, join.REASONS.portal_unreachable)
  elseif reply.type == "player_authenticated" then
    local moved, move_err = players.register(handle, {
      player_id = reply.player_id,
      username = reply.username,
    })
    if moved then
      platform.to_client(
        handle,
        handoff.RESULT,
        handoff.encode(handoff.RESULT, {
          ok = true,
          player_id = reply.player_id,
          username = reply.username,
          created = reply.created,
        })
      )
    else
      log("warn", tostring(move_err))
      kick(session, join.REASONS.already_online)
    end
  elseif reply.type == "rejected" and reply.code == "forbidden" then
    -- A ban (F3): logging in again will not help.
    kick(session, string.format(join.REASONS.refused, reply.reason))
  elseif reply.type == "rejected" then
    -- An expired or reused ticket: the client logs in again for a new one.
    platform.to_client(handle, handoff.RESULT, handoff.encode(handoff.RESULT, { ok = false, reason = reply.reason }))
  else
    log("warn", "ignored a " .. reply.type .. " answering RedeemTicket")
  end
end

---Decodes a handoff message from a client, logging and dropping one that
---does not decode.
---@param name string The message name.
---@param payload any The raw payload.
---@return table? fields The fields, or nil if dropped.
local function decode(name, payload)
  local fields, err = handoff.decode(name, payload)
  if not fields then
    log("debug", "dropped a malformed " .. name .. ": " .. tostring(err))
  end
  return fields
end

---The client's core has started: move to `authenticating` and fetch a nonce.
---A client that says so again (its core restarted, or it never heard back)
---is asking for a nonce, under the same limit as any other request.
---@param handle rpf.PlayerHandle The sender, as the platform reported it.
---@param payload string The payload.
local function on_ready(handle, payload)
  local session = sessions[handle]
  local player = players.get(handle)
  if not session or not current(session) or not player or not decode(handoff.CLIENT_READY, payload) then
    return
  end
  if player.state == "connecting" then
    players.authenticating(handle)
    begin(session)
  elseif player.state == "authenticating" then
    renew(session)
  end
end

---The client wants a fresh nonce: its last one ran out, or it is logging
---out. Honoured once the player is `authenticating`, with nothing in flight,
---and not too often.
---@param handle rpf.PlayerHandle The sender.
---@param payload string The payload.
local function on_nonce_request(handle, payload)
  local session = sessions[handle]
  local player = players.get(handle)
  if not session or not current(session) or not player or player.state == "connecting" then
    return
  end
  if not decode(handoff.NONCE_REQUEST, payload) then
    return
  end
  renew(session)
end

---The client could not reach the portal. A client can say this falsely,
---but all it gains is a kinder wording of its own kick, so it is believed
---while the player is logging in.
---@param handle rpf.PlayerHandle The sender.
---@param payload string The payload.
local function on_trouble(handle, payload)
  local session = sessions[handle]
  if session and live(session) and decode(handoff.PORTAL_TROUBLE, payload) then
    session.client_trouble = true
  end
end

---The client has a join ticket: redeem it.
---@param handle rpf.PlayerHandle The sender.
---@param payload string The payload.
local function on_ticket(handle, payload)
  local session = sessions[handle]
  if not session or not live(session) or session.redeem_pending then
    return
  end
  local fields = decode(handoff.TICKET, payload)
  if not fields then
    return
  end
  session.redeem_pending = true
  connection:send("redeem_ticket", { ticket = fields.ticket }, function(reply, err)
    redeemed(session, reply, err)
  end)
end

---Starts a login for each new player, with its deadline.
---@param player rpf.PlayerView The player, just `connecting`.
local function on_connecting(player)
  ---@type rpf.join.Session
  local session = {
    handle = player.handle,
    begins = 0,
    redeem_pending = false,
    portal_failed = false,
    kicked = false,
  }
  sessions[player.handle] = session
  platform.after(options.auth_timeout_ms, function()
    if not current(session) or players.authenticated(session.handle) then
      return
    end
    if portal_at_fault(session) then
      kick(session, join.REASONS.portal_unreachable)
    else
      kick(session, string.format(join.REASONS.timed_out, math.ceil(options.auth_timeout_ms / 60000)))
    end
  end)
end

---Tells the portal a logged-in player has left, and forgets the login.
---@param player rpf.PlayerView The player, now `dropping`.
local function on_dropping(player)
  sessions[player.handle] = nil
  if player.player_id then
    local _, err = connection:send("player_dropped", { player_id = player.player_id, reason = player.reason or "left" })
    if err then
      log("warn", "could not report player " .. player.player_id .. " as dropped (" .. err .. ")")
    end
  end
end

---Settings for `join.start`, from the server's start options.
---@class rpf.join.Settings
---@field url string The portal's websocket url.
---@field portal_url string? The portal's HTTP address, when it is not the websocket's host.
---@field options rpf.JoinOptions? Timing overrides.

---Wires the join flow up. Called by `rpf.start_server`, after `players`.
---@param p rpf.ServerPlatform The platform.
---@param client rpf.Client The connection to the portal.
---@param settings rpf.join.Settings Where the portal is, and the timings.
function join.start(p, client, settings)
  platform = p
  connection = client
  sessions = {}
  options = {}
  for key, value in pairs(join.DEFAULTS) do
    options[key] = value
  end
  for key, value in pairs(settings.options or {}) do
    options[key] = value
  end
  portal_url = settings.portal_url or join.http_base(settings.url)
  events.on("players.connecting", on_connecting)
  events.on("players.dropping", on_dropping)
  p.on_client(handoff.CLIENT_READY, on_ready)
  p.on_client(handoff.NONCE_REQUEST, on_nonce_request)
  p.on_client(handoff.TICKET, on_ticket)
  p.on_client(handoff.PORTAL_TROUBLE, on_trouble)
end

rpf.join = join
return join
