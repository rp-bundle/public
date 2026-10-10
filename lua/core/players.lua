---The players on this game server, and where each is in its lifecycle.
---
---Every player moves through one state machine:
---
---```
---connecting → authenticating → registered → character_select ⇄ active
---     └────────────┴───────────────┴────────────────┴─────────────┴──→ dropping
---```
---
--- - `connecting`: the engine has the player, but their client's core has not
---   started yet.
--- - `authenticating`: in the game, not yet logged in to their account (C6,
---   P1). Nothing but the login flow is available: `players.on_client` drops
---   every other client message, and a player who never logs in is kicked by
---   `rpf.join`.
--- - `registered`: the portal has confirmed the account, and `player_id` is
---   known from here on.
--- - `character_select` / `active`: choosing a character, then playing one.
---   `active → character_select` is a character switch or unload.
--- - `dropping`: leaving, from any state. The record is removed once the
---   `players.dropping` handlers have run.
---
---Two kinds of caller move players, through separate functions that share one
---transition check. The login gate (`connecting → authenticating →
---registered`) is RPF's own and only `rpf.join` drives it, through
---`players.authenticating` and `players.register`, whatever framework runs the
---characters (#75). `character_select ⇄ active` is driven through
---`players.advance` by whichever module owns characters on this server: D5's
---character module on a native server, or a framework bridge (K2) on a
---companion one. `advance` refuses the gate's states, so no character owner
---can let a player past login.
---
---Any move `TRANSITIONS` does not list is refused and changes nothing. Every
---accepted move emits `players.state_changed` and then `players.<state>`, each
---with its own copy of the player, so a handler cannot change the registry by
---editing what it was given. This module is the only writer of player state;
---other modules learn of moves only through those events.
---@class rpf.players
---@field STATES rpf.PlayerState[] Every state, in lifecycle order.
---@field TRANSITIONS table<rpf.PlayerState, table<rpf.PlayerState, true>> The moves allowed out of each state. Anything absent is refused.
---@field GATE table<rpf.PlayerState, true> The states only the login flow may move a player into.
local players = {}

local rpf = rpf
local events = rpf.events

players.STATES = { "connecting", "authenticating", "registered", "character_select", "active", "dropping" }

players.TRANSITIONS = {
  connecting = { authenticating = true, dropping = true },
  authenticating = { registered = true, dropping = true },
  registered = { character_select = true, dropping = true },
  character_select = { active = true, dropping = true },
  active = { character_select = true, dropping = true },
  dropping = {},
}

players.GATE = { connecting = true, authenticating = true, registered = true }

---The account a player registers as, from the portal's `PlayerAuthenticated`.
---@class rpf.players.Account
---@field player_id string The account's uuid.
---@field username string The account's username, as stored.

---One player's record. Internal: handlers and scripts get `rpf.PlayerView`
---copies of it.
---@class rpf.players.Record
---@field handle rpf.PlayerHandle The engine's handle.
---@field serial integer Unique per connection in this process, so a timer set for one connection never acts on a later connection that reused the handle.
---@field state rpf.PlayerState Where the player is.
---@field name string The in-game name when they connected.
---@field player_id string? The account, from `registered` on.
---@field username string? The account's username, from `registered` on.
---@field connected_at number When they connected, by the platform clock.
---@field since number When they entered the current state, by the platform clock.
---@field reason string? Why they are leaving, once `dropping`.

---Records by handle. Handles may be tables (entities on Gmod), which is fine
---as a key.
---@type table<any, rpf.players.Record>
local by_handle = {}

---Handles by player id, for players who are `registered` or later.
---@type table<string, rpf.PlayerHandle>
local by_id = {}

---The platform, once `players.start` has run, for its clock and names.
---@type rpf.ServerPlatform?
local platform = nil

---The last serial handed out.
local serial = 0

---The pattern a player id must match: a hyphenated uuid.
local UUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

---Whether a move is allowed. Pure, and the rule every mover obeys.
---@param from rpf.PlayerState The current state.
---@param to any The proposed state.
---@return boolean allowed True if `players.TRANSITIONS` allows it.
function players.can(from, to)
  local out = players.TRANSITIONS[from]
  return out ~= nil and out[to] == true
end

---A copy of a record, safe to hand to a handler or a script.
---@param record rpf.players.Record The record.
---@return rpf.PlayerView view The copy.
local function view(record)
  return {
    handle = record.handle,
    serial = record.serial,
    state = record.state,
    name = record.name,
    player_id = record.player_id,
    username = record.username,
    connected_at = record.connected_at,
    since = record.since,
    reason = record.reason,
  }
end

---The current time, by the platform clock once started.
---@return number ms Milliseconds since the epoch, or 0 before start.
local function now()
  return platform and platform.now() or 0
end

---Moves waiting to be announced, oldest first. See `announce`.
---@type { changed: rpf.PlayerView, entered: rpf.PlayerView, from: rpf.PlayerState? }[]
local queue = {}

---Whether `announce` is already emitting further up the stack.
local draining = false

---Announces a move: `players.state_changed`, then `players.<state>`, each
---with its own copy, taken now.
---
---A handler may move the player again (a character owner moving a newly
---registered player to `character_select`, say). That move is queued and
---announced once the current move's events are done, so every handler sees
---moves one at a time, in order, and each event describes the move it names
---rather than whatever the record has become since.
---@param record rpf.players.Record The record, already moved.
---@param from rpf.PlayerState? The state it left, nil for a new player.
local function announce(record, from)
  queue[#queue + 1] = { changed = view(record), entered = view(record), from = from }
  if draining then
    return
  end
  draining = true
  while #queue > 0 do
    local move = table.remove(queue, 1)
    events.emit("players.state_changed", move.changed, move.from)
    events.emit("players." .. move.entered.state, move.entered, move.from)
  end
  draining = false
end

---Moves a record, if the lifecycle allows it, and announces the move.
---@param handle rpf.PlayerHandle The player.
---@param to rpf.PlayerState The state to move to.
---@param prepare (fun(record: rpf.players.Record): string?)? Checks and fills in what the new state needs, returning an error to refuse. Runs after the transition check, before anything changes.
---@return boolean moved True if the player moved.
---@return string? err Why not.
local function move(handle, to, prepare)
  local record = by_handle[handle]
  if not record then
    return false, "rpf: player " .. tostring(handle) .. " is not connected"
  end
  local from = record.state
  if not players.can(from, to) then
    return false, "rpf: a player cannot move from " .. from .. " to " .. tostring(to)
  end
  if prepare then
    local err = prepare(record)
    if err then
      return false, err
    end
  end
  record.state = to
  record.since = now()
  announce(record, from)
  return true, nil
end

---Binds the platform and forgets every player. Called by `rpf.start_server`.
---@param p rpf.ServerPlatform The platform.
function players.start(p)
  platform = p
  by_handle, by_id = {}, {}
  queue, draining = {}, false
end

---A player the engine has just handed over. The adapter calls this from its
---connect event; the player starts in `connecting`.
---@param handle rpf.PlayerHandle The engine's handle.
---@return rpf.PlayerView? player The new player, or nil if refused.
---@return string? err Why: no handle, or the handle is already connected.
function players.connected(handle)
  if handle == nil then
    return nil, "rpf: a player handle cannot be nil"
  end
  if by_handle[handle] then
    return nil, "rpf: player " .. tostring(handle) .. " is already connected"
  end
  serial = serial + 1
  local at = now()
  local record = {
    handle = handle,
    serial = serial,
    state = "connecting",
    name = platform and platform.name(handle) or tostring(handle),
    connected_at = at,
    since = at,
  }
  by_handle[handle] = record
  announce(record, nil)
  return view(record), nil
end

---Moves a player to `authenticating`: their client's core has started and
---the login can begin. The login flow's move; nothing else calls it.
---@param handle rpf.PlayerHandle The player.
---@return boolean moved True if the player moved.
---@return string? err Why not.
function players.authenticating(handle)
  return move(handle, "authenticating", nil)
end

---Moves a player to `registered`: the portal has confirmed their account.
---The login flow's move, made only on `PlayerAuthenticated`; nothing else
---calls it. Refused if the account is already playing here under another
---handle, because one account is one player.
---@param handle rpf.PlayerHandle The player.
---@param account rpf.players.Account The account the portal confirmed.
---@return boolean moved True if the player moved.
---@return string? err Why not.
function players.register(handle, account)
  return move(handle, "registered", function(record)
    if type(account) ~= "table" or type(account.player_id) ~= "string" or type(account.username) ~= "string" then
      return "rpf: registering a player needs a player_id and a username"
    end
    if not account.player_id:find(UUID) then
      return "rpf: player_id must be a uuid"
    end
    local other = by_id[account.player_id]
    if other ~= nil and other ~= record.handle then
      return "rpf: account " .. account.player_id .. " is already playing on this server"
    end
    record.player_id = account.player_id
    record.username = account.username
    by_id[account.player_id] = record.handle
    return nil
  end)
end

---Moves a player between `registered`, `character_select` and `active`.
---
---This is the move a character owner makes: D5's character module on a
---native server, a framework bridge (K2) on a companion one. It goes through
---the same transition check as every other move, and it refuses the login
---gate's states and `dropping`, so a character owner can neither let a
---player past login nor forget one the engine still has. On a server whose
---framework owns its domains it refuses every move with `"no_bridge"` until
---a bridge that fits is accepted (`rpf.domains.may_play`, K1), so a player
---stays at `registered` rather than reach a world nobody keeps.
---@param handle rpf.PlayerHandle The player.
---@param to "character_select"|"active" The state to move to.
---@return boolean moved True if the player moved.
---@return string? err Why not.
function players.advance(handle, to)
  if players.GATE[to] then
    return false, "rpf: only the login flow moves a player to " .. tostring(to)
  end
  if to == "dropping" then
    return false, "rpf: a player is dropped by the engine, through players.dropped"
  end
  -- A server whose framework owns its domains lets nobody in until the
  -- bridge to that framework is accepted (K1): failing closed, logged once.
  local open, closed = rpf.domains.may_play()
  if not open then
    return false, closed
  end
  return move(handle, to, nil)
end

---A player the engine says has left. The adapter calls this from its drop
---event. Moves them to `dropping` from whatever state they were in, then
---forgets them, once the `players.dropping` handlers have run. (A drop made
---from inside another lifecycle handler is announced after that handler's
---move, by which time the record is gone; the handlers still get their copy.)
---@param handle rpf.PlayerHandle The player.
---@param reason string? Why, as the engine reported it.
---@return boolean dropped False if the player was not connected.
function players.dropped(handle, reason)
  local moved = move(handle, "dropping", function(record)
    record.reason = type(reason) == "string" and reason or "left"
    return nil
  end)
  if moved then
    local record = by_handle[handle]
    by_handle[handle] = nil
    if record.player_id and by_id[record.player_id] == handle then
      by_id[record.player_id] = nil
    end
  end
  return moved
end

---One player, by the engine's handle.
---@param handle rpf.PlayerHandle The handle.
---@return rpf.PlayerView? player A copy, or nil if not connected.
function players.get(handle)
  local record = handle ~= nil and by_handle[handle] or nil
  return record and view(record) or nil
end

---One player, by account.
---@param player_id string The account's uuid.
---@return rpf.PlayerView? player A copy, or nil if that account is not playing here.
function players.by_player_id(player_id)
  local handle = by_id[player_id]
  return handle ~= nil and players.get(handle) or nil
end

---Whether a player has logged in: `registered` or later. Before that only
---the login flow may act for them.
---@param handle rpf.PlayerHandle The handle.
---@return boolean authenticated True from `registered` on.
function players.authenticated(handle)
  local record = handle ~= nil and by_handle[handle] or nil
  return record ~= nil and record.player_id ~= nil
end

---Every connected player, oldest connection first.
---@return rpf.PlayerView[] players Copies.
function players.list()
  local out = {}
  for _, record in pairs(by_handle) do
    out[#out + 1] = view(record)
  end
  table.sort(out, function(a, b)
    return a.serial < b.serial
  end)
  return out
end

---One entry of `players.online`: what the portal needs to re-establish a
---logged-in player's presence, and nothing engine-specific.
---@class rpf.OnlinePlayer
---@field player_id string The account's uuid.
---@field username string The account's username.
---@field name string The in-game name when they connected.
---@field state rpf.PlayerState `registered`, `character_select` or `active`.
---@field connected_at number When they connected, by the platform clock.

---The list F2's `OnlinePlayers` resync is built from: everyone whose account
---is known (`registered` or later), with what the portal needs to
---re-establish presence and nothing engine-specific. Sorted by player id, so
---the same set always produces the same frame. F2 defines the message and
---sends it; this is only the shape.
---@return rpf.OnlinePlayer[] online The list.
function players.online()
  local out = {}
  for player_id, handle in pairs(by_id) do
    local record = by_handle[handle]
    -- A player who is leaving is no longer online, even while the
    -- `players.dropping` handlers (which may build the resync) still run.
    if record.state ~= "dropping" then
      out[#out + 1] = {
        player_id = player_id,
        username = record.username,
        name = record.name,
        state = record.state,
        connected_at = record.connected_at,
      }
    end
  end
  table.sort(out, function(a, b)
    return a.player_id < b.player_id
  end)
  return out
end

---Registers the handler for one message name from clients, dropping any
---message from a player who has not logged in yet.
---
---This is the structural half of "nothing but the login flow is available
---while authenticating": a module that registers through here cannot forget
---the check. Only the login flow (`rpf.join`) registers on the platform
---directly, because it is the login flow.
---@param name string The message name, namespaced `rpf:`.
---@param handler fun(player: rpf.PlayerView, payload: string) Called for each message from a logged-in player. The payload is hostile input.
function players.on_client(name, handler)
  if not platform then
    error("rpf: players.on_client before rpf.start_server", 2)
  end
  local p = platform
  p.on_client(name, function(handle, payload)
    local record = by_handle[handle]
    if not record or record.player_id == nil or record.state == "dropping" then
      p.log("debug", "rpf: ignored " .. name .. " from a player who has not logged in")
      return
    end
    handler(view(record), payload)
  end)
end

rpf.players = players
return players
