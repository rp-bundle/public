---A logged-in player's characters (D5): listing them, creating one,
---selecting one to play, and switching to another.
---
---This module owns `character_select ⇄ active` on a native server, through
---`players.advance`, the one move a character owner may make (#75): it never
---touches the login gate.
---
---**Everything here is a held record (C7).** No message lists or selects
---characters, because holding already does both:
---
--- - **Listing.** When a player registers, `rpf.sync` holds their session
---   records, which is everything their account owns here, their characters
---   included. Once that hold lands (`records.session`) the player moves to
---   `character_select` and their client is sent the list. `characters.list`
---   reads it from `rpf.records` every time, so it is never a copy of a
---   record this server has let go.
--- - **Creating** is `create_character`. The portal opens the character's
---   starting accounts and funds them from the server's starting funds in
---   the same transaction (E5), so nothing here pays a starting balance, and
---   a resent request, answered from the portal's request log, cannot pay
---   one twice. The new character is then held for the player's session.
--- - **Selecting** holds the character's own records, its accounts and
---   containers, with a hold naming the character as their owner, and moves
---   the player to `active` once they are here. Until then the player stays
---   in `character_select`: a character is never in play without its money.
--- - **Switching** puts the character in play away first: its own records
---   are released, with their final state, and the player goes back to
---   `character_select` before the next one is held. The character itself
---   stays held, as one of the player's session records.
---
---Everything is held for the player's session, so `rpf.sync` releases all of
---it when they leave, whatever is selected.
---
---**One request per player at a time.** A create, select or deselect waits
---for the portal; another one from the same player meanwhile is refused as
---`busy`, so a client cannot queue up a flood of character creations.
---
---Client messages are hostile input: they arrive through
---`players.on_client`, so nobody who has not logged in reaches this module,
---and each is decoded against its schema in `rpf.handoff`. A character id a
---client names is looked up among that player's own held characters, so
---another player's character, or one this server does not hold, is refused
---as `not_found`, one answer for both.
---
---Events, reserved to the core, each with copies:
---`characters.created(player, character)`,
---`characters.selected(player, character)` once the player is `active`, and
---`characters.deselected(player, character_id)` once they are back in
---`character_select`.
---@class rpf.characters
---@field DEFAULTS rpf.CharacterOptions The production bounds.
---@field MAX_NAME_BYTES integer The longest first or last name, or server-specific gender, a character may be created with, in bytes after trimming.
---@field options rpf.CharacterOptions The options in force.
local characters = {}

local rpf = rpf
local json = rpf.json
local events = rpf.events
local players = rpf.players
local records = rpf.records
local handoff = rpf.handoff

---Bounds on what one player may do.
---@class rpf.CharacterOptions
---@field max_characters integer? The most characters one player may have on this server. Creating another is refused as `limit`. A bound on what a client can make the server create, not a game rule: a server owner wanting more raises it.
characters.DEFAULTS = {
  max_characters = 5,
}

characters.MAX_NAME_BYTES = 64

characters.options = {}

---One logged-in player's character state.
---@class rpf.characters.Session
---@field player_id string The player's account.
---@field handle rpf.PlayerHandle The player's handle, for moving them and messaging their client.
---@field serial integer The player's connection (`rpf.PlayerView.serial`), so an answer meant for an earlier connection of theirs never lands on this one, even on a reused handle.
---@field loaded boolean Whether their session records have been held, so their characters can be listed.
---@field loading boolean Whether a hold of their session records is in flight.
---@field again boolean? Whether the session must be held once more when the hold in flight is answered, because a character may have been created after it was sent.
---@field stale boolean Whether the list may be missing characters that are still theirs: the last hold of their session records, asked for again, was refused, or a character may have been created without being held (its hold failed, or the portal never answered the create). The session is held again at once, a client's request for the list holds it again rather than resending it, and creating waits until it lands.
---@field selected string? The character in play, from the moment its records are held.
---@field busy string? The request in flight for them: `"create"` or `"select"`.
---@field selecting string? The character a selection in flight is for.
---@field recovering integer How many holds of the selected character's own records are in flight after the portal took some of them back (`on_lost`). The player counts as busy while any is, so the selection cannot change under one.

---Sessions by player id. Compared by identity in every callback, so an
---answer for a player who has left (or left and come back) does nothing.
---@type table<string, rpf.characters.Session>
local sessions = {}

---@type rpf.ServerPlatform?
local platform = nil

---@type rpf.Client?
local connection = nil

---Logs through the platform with the module's prefix.
---@param level string The level.
---@param message string The message.
local function log(level, message)
  if platform then
    platform.log(level, "rpf.characters: " .. message)
  end
end

---Whether a record's owner is the given one.
---@param data table The record's data.
---@param kind string The owner's kind.
---@param id string The owner's uuid.
---@return boolean owned True if it belongs to them.
local function owned(data, kind, id)
  return type(data.owner) == "table" and data.owner.kind == kind and data.owner.id == id
end

---The session for a player, only while they are still here under it.
---@param player_id string The player.
---@return rpf.characters.Session? session The session, or nil.
local function session_of(player_id)
  return sessions[player_id]
end

---Whether a request of the player's is in flight, a recovery included, so
---another must wait.
---@param session rpf.characters.Session The player.
---@return boolean busy True while one is.
local function is_busy(session)
  return session.busy ~= nil or session.recovering > 0
end

---Every character a player has here, as copies, by name and then id. Only
---characters this server holds: a player's are held for their session, so
---this is all of them once `characters.loaded` says so.
---@param player_id string The player.
---@return table[] characters Copies of each character.
function characters.list(player_id)
  local out = {}
  for _, ref in ipairs(records.held()) do
    if ref.kind == "character" then
      local character = records.get("character", ref.id)
      if character and owned(character, "player", player_id) then
        out[#out + 1] = character
      end
    end
  end
  table.sort(out, function(a, b)
    if a.first_name ~= b.first_name then
      return a.first_name < b.first_name
    end
    if a.last_name ~= b.last_name then
      return a.last_name < b.last_name
    end
    return a.id < b.id
  end)
  return out
end

---Whether a player's characters have been loaded (held), so `list` is
---complete.
---@param player_id string The player.
---@return boolean loaded True once their session records are held.
function characters.loaded(player_id)
  local session = session_of(player_id)
  return session ~= nil and session.loaded
end

---The character a player has in play, as a copy.
---@param player_id string The player.
---@return table? character A copy, or nil if they have none selected.
function characters.selected(player_id)
  local session = session_of(player_id)
  if not session or not session.selected then
    return nil
  end
  return records.get("character", session.selected)
end

---One of the player's own held characters, by id. A character of another
---player's, and one this server does not hold, are the same answer.
---@param player_id string The player.
---@param id any The character's id, as a caller gave it.
---@return table? character A copy, or nil.
local function own_character(player_id, id)
  if type(id) ~= "string" then
    return nil
  end
  local character = records.get("character", id)
  if character and owned(character, "player", player_id) then
    return character
  end
  return nil
end

---The records a character owns that this server holds: its accounts and
---containers. Never the character itself, which is a session record.
---@param id string The character.
---@return rpf.RecordRef[] refs The records.
local function owned_records(id)
  local out = {}
  for _, ref in ipairs(records.held()) do
    if ref.kind ~= "character" then
      local data = records.get(ref.kind, ref.id)
      if data and owned(data, "character", id) then
        out[#out + 1] = ref
      end
    end
  end
  return out
end

---Releases the records a character owns that this server still holds, with
---their final state. One the outbox cannot take yet stays held for the
---player's session, and is released with the rest when they leave; that is
---logged, never an error, because nothing a player does should wait on it.
---@param id string The character.
---@param context string What was happening, for the log.
local function release_owned(id, context)
  local refs = owned_records(id)
  if #refs == 0 then
    return
  end
  local ok, err = rpf.sync.release(refs)
  if not ok then
    log("warn", context .. ": a character's records could not all be released (" .. tostring(err) .. "); they stay held until the player leaves")
  end
end

-- Telling the client ---------------------------------------------------------

---Sends a player's client their characters and the selected one.
---@param session rpf.characters.Session The player.
local function send_list(session)
  if not platform then
    return
  end
  local list = {}
  for i, character in ipairs(characters.list(session.player_id)) do
    list[i] = json.object({
      id = character.id,
      first_name = character.first_name,
      last_name = character.last_name,
      gender = character.gender,
    })
  end
  platform.to_client(
    session.handle,
    handoff.CHARACTERS,
    handoff.encode(handoff.CHARACTERS, { characters = json.array(list), selected = session.selected })
  )
end

---Tells a player's client how a request went.
---@param session rpf.characters.Session The player.
---@param during string `"create"`, `"select"` or `"deselect"`.
---@param id string? The character, when there is one.
---@param err string? Why it failed, or nil if it worked.
local function send_result(session, during, id, err)
  if not platform then
    return
  end
  platform.to_client(
    session.handle,
    handoff.CHARACTER_RESULT,
    handoff.encode(handoff.CHARACTER_RESULT, { during = during, ok = err == nil, id = id, reason = err })
  )
end

-- Loading --------------------------------------------------------------------

---Asks for a player's session records again, unless a hold of them is
---already in flight.
---@param session rpf.characters.Session The player.
local function load(session)
  if session.loading then
    return
  end
  session.loading = true
  rpf.sync.hold_session(session.player_id)
end

---Marks a player's list as possibly missing a character of theirs and holds
---their session records again, so it comes back. Until that lands, creating
---is refused and a list request holds them again.
---@param session rpf.characters.Session The player.
local function reload(session)
  session.stale = true
  if session.loading then
    -- The hold in flight may have been sent before the character existed.
    session.again = true
    return
  end
  load(session)
end

---A player's session, made when they register. Made here as well as on
---`players.registered`, because `rpf.sync`, which starts first, can answer
---the session hold before this module hears of the registration (an outbox
---that refuses it at once).
---@param player_id string The player.
---@return rpf.characters.Session? session The session, or nil if the player is not here.
local function ensure(player_id)
  local player = players.by_player_id(player_id)
  if not player or player.state == "dropping" then
    return nil
  end
  local session = sessions[player_id]
  if session and session.serial == player.serial then
    return session
  end
  session = {
    player_id = player_id,
    handle = player.handle,
    serial = player.serial,
    loaded = false,
    loading = true,
    stale = false,
    selected = nil,
    busy = nil,
    recovering = 0,
  }
  sessions[player_id] = session
  return session
end

---A hold of a player's session records was answered: they are listed now,
---and a player who has just registered moves on to choosing a character.
---@param player_id string The player.
---@param err string? The refusal, or nil once the records are held.
---@param serial integer? The connection the hold was sent for.
local function on_session(player_id, err, serial)
  local player = players.by_player_id(player_id)
  if not player or player.serial ~= serial then
    -- An answer for an earlier connection of theirs: what it held was
    -- released when they left, so it says nothing about this connection's
    -- list, whose own hold is still to come.
    return
  end
  local session = ensure(player_id)
  if not session then
    return
  end
  session.loading = false
  if session.again then
    session.again = false
    load(session)
    return
  end
  if err then
    log("warn", "could not load a player's characters (" .. tostring(err) .. ")")
    session.stale = session.loaded
    send_result(session, "load", nil, "unavailable")
    return
  end
  session.loaded = true
  session.stale = false
  local player = players.get(session.handle)
  if player and player.state == "registered" then
    players.advance(session.handle, "character_select")
  end
  send_list(session)
end

-- Selecting and switching ----------------------------------------------------

---Puts the character in play away: releases its own records with their
---final state, and moves the player back to `character_select`.
---
---A record whose final state the outbox cannot take yet stays held, for the
---player's session, and is released with the rest when they leave: the
---switch goes on regardless, because a switch the player cannot make is
---worse than a record held a little longer. It is logged.
---@param session rpf.characters.Session The player.
local function put_away(session)
  local id = session.selected
  if not id then
    return
  end
  release_owned(id, "putting a character away")
  session.selected = nil
  players.advance(session.handle, "character_select")
  local player = players.get(session.handle)
  if player then
    events.emit("characters.deselected", player, id)
  end
end

---Puts away the character a player has in play, if any, and moves them back
---to `character_select`.
---@param handle rpf.PlayerHandle The player.
---@return boolean? ok True if they are choosing now.
---@return string? err `"not_ready"` before their characters are loaded, `"busy"` while a request of theirs is in flight.
function characters.deselect(handle)
  local player = players.get(handle)
  local session = player and player.player_id and session_of(player.player_id)
  if not session or not session.loaded then
    return nil, "not_ready"
  end
  if is_busy(session) then
    return nil, "busy"
  end
  put_away(session)
  send_list(session)
  return true
end

---Selects a character for a player to play, switching from the one in play
---if there is one. The character's own records (its accounts and
---containers) are held first; the player moves to `active`, and
---`characters.selected` is emitted, once they are here.
---@param handle rpf.PlayerHandle The player.
---@param id string The character's uuid: one of the player's own.
---@param callback fun(character: table?, err: string?)? Called with a copy of the character once it is in play, or why not: the portal's refusal, or `"gone"` if the player left first.
---@return boolean? ok True if the selection is under way (or already made).
---@return string? err `"not_ready"` before their characters are loaded, `"busy"` while a request of theirs is in flight, `"not_found"` for a character that is not theirs here.
function characters.select(handle, id, callback)
  local player = players.get(handle)
  local session = player and player.player_id and session_of(player.player_id)
  if not session or not session.loaded then
    return nil, "not_ready"
  end
  if is_busy(session) then
    return nil, "busy"
  end
  local character = own_character(session.player_id, id)
  if not character then
    return nil, "not_found"
  end
  if session.selected == id then
    if callback then
      callback(character, nil)
    end
    return true
  end
  put_away(session)
  session.busy = "select"
  session.selecting = id
  rpf.sync.hold({ owners = { { kind = "character", id = id } } }, session.player_id, function(_, err)
    if sessions[session.player_id] ~= session then
      if callback then
        callback(nil, "gone")
      end
      return
    end
    session.busy = nil
    session.selecting = nil
    local now = own_character(session.player_id, id)
    if err or not now then
      err = err or "not_found"
      log("warn", "could not hold a selected character's records (" .. tostring(err) .. ")")
      -- The character went while the hold was in flight; whatever of its
      -- own the hold brought must not stay held with nothing in play.
      release_owned(id, "a selection whose character went")
      if callback then
        callback(nil, err)
      end
      return
    end
    session.selected = id
    players.advance(session.handle, "active")
    local view = players.get(session.handle)
    if view then
      events.emit("characters.selected", view, now)
    end
    if callback then
      callback(now, nil)
    end
  end)
  return true
end

-- Creating -------------------------------------------------------------------

---Trims and checks one name for a new character.
---@param value any The name as given.
---@return string? name The name, or nil if it is not one.
local function new_name(value)
  local name = records.check_name(value)
  if not name or #name > characters.MAX_NAME_BYTES then
    return nil
  end
  return name
end

---Creates a character for a player, through the portal, which opens and
---funds its starting accounts (E5). Once it is created it is held for the
---player's session, so it is in their list, and `characters.created` is
---emitted. It is not selected.
---@param handle rpf.PlayerHandle The player.
---@param fields { first_name: any, last_name: any, gender: any } The names, trimmed and at most `MAX_NAME_BYTES` each, and the gender: `"male"`, `"female"` or `{ server_specific = … }` of at most `MAX_NAME_BYTES`.
---@param callback fun(character: table?, err: string?)? Called with a copy of the character once it is held, or why not: `"unavailable"` when the portal could not be asked or did not answer, the portal's reject code, or `"gone"` if the player left first.
---@return boolean? ok True if the request is under way.
---@return string? err `"not_ready"` before the characters are loaded, and while the list may be missing one (`stale`), so `max_characters` is never checked against a short list; `"busy"`, `"invalid"` for a bad name or gender, `"limit"` at `max_characters`.
function characters.create(handle, fields, callback)
  local player = players.get(handle)
  local session = player and player.player_id and session_of(player.player_id)
  if not session or not session.loaded or session.stale then
    return nil, "not_ready"
  end
  if is_busy(session) then
    return nil, "busy"
  end
  if type(fields) ~= "table" then
    return nil, "invalid"
  end
  local first_name, last_name = new_name(fields.first_name), new_name(fields.last_name)
  local gender = records.check_gender(fields.gender)
  if
    not first_name
    or not last_name
    or not gender
    or (type(gender) == "table" and #gender.server_specific > characters.MAX_NAME_BYTES)
  then
    return nil, "invalid"
  end
  if #characters.list(session.player_id) >= characters.options.max_characters then
    return nil, "limit"
  end
  session.busy = "create"
  ---Ends the request, for this session only.
  ---@param character table? The character.
  ---@param err string? Why not.
  local function finish(character, err)
    if sessions[session.player_id] ~= session then
      if callback then
        callback(nil, "gone")
      end
      return
    end
    session.busy = nil
    if callback then
      callback(character, err)
    end
  end
  assert(connection):send("create_character", {
    owner = json.object({ kind = "player", id = session.player_id }),
    first_name = first_name,
    last_name = last_name,
    gender = gender,
  }, function(reply, err)
    if not reply or reply.type ~= "character_created" then
      local why = reply and reply.code or "unavailable"
      log("warn", "a character was not created (" .. tostring(reply and reply.code or err) .. ")")
      if not reply and sessions[session.player_id] == session then
        -- Unanswered: it may have been created all the same.
        reload(session)
      end
      finish(nil, why)
      return
    end
    local id = reply.character.id
    if sessions[session.player_id] ~= session then
      -- They left: the character exists, and is theirs next time.
      finish(nil, "gone")
      return
    end
    rpf.sync.hold({ records = { { kind = "character", id = id } } }, session.player_id, function(_, hold_err)
      if sessions[session.player_id] ~= session then
        -- They left (and may be back on a new connection, whose own session
        -- hold lists it): nothing of this request is theirs any more.
        finish(nil, "gone")
        return
      end
      local character = own_character(session.player_id, id)
      if hold_err or not character then
        -- It exists, but is not in their list: hold the whole session again.
        reload(session)
        finish(nil, hold_err or "unavailable")
        return
      end
      local view = players.get(session.handle)
      if view then
        events.emit("characters.created", view, character)
      end
      finish(character, nil)
    end)
  end)
  return true
end

-- Client messages ------------------------------------------------------------

---Decodes one message from a client, logging and dropping one that does not
---fit its schema.
---@param name string The message name.
---@param payload any The raw payload.
---@return table? fields The fields, or nil if refused.
local function decode(name, payload)
  local fields, err = handoff.decode(name, payload)
  if not fields then
    log("debug", "ignored a malformed " .. name .. ": " .. tostring(err))
  end
  return fields
end

---The session of the player a client message came from.
---@param player rpf.PlayerView The sender, as `players.on_client` gives it.
---@return rpf.characters.Session? session The session, or nil.
local function sender(player)
  return player.player_id and session_of(player.player_id) or nil
end

---A client asked for its list again: sent if loaded, and the load tried
---again if it failed.
---@param player rpf.PlayerView The sender.
---@param payload any The raw payload.
local function on_request(player, payload)
  local session = sender(player)
  if not session or not decode(handoff.CHARACTERS_REQUEST, payload) then
    return
  end
  if session.loaded and not session.stale then
    send_list(session)
  else
    load(session)
  end
end

---A client asked to create a character. The gender is a string: `"male"`
---and `"female"` as themselves, anything else as the server's own option.
---@param player rpf.PlayerView The sender.
---@param payload any The raw payload.
local function on_create(player, payload)
  local session = sender(player)
  local fields = session and decode(handoff.CHARACTER_CREATE, payload)
  if not session or not fields then
    return
  end
  local gender = fields.gender
  if gender ~= "male" and gender ~= "female" then
    gender = json.object({ server_specific = gender })
  end
  local ok, err = characters.create(session.handle, {
    first_name = fields.first_name,
    last_name = fields.last_name,
    gender = gender,
  }, function(character, why)
    if why == "gone" then
      return
    end
    send_result(session, "create", character and character.id, why)
    if character then
      send_list(session)
    end
  end)
  if not ok then
    send_result(session, "create", nil, err)
  end
end

---A client asked to play a character.
---@param player rpf.PlayerView The sender.
---@param payload any The raw payload.
local function on_select(player, payload)
  local session = sender(player)
  local fields = session and decode(handoff.CHARACTER_SELECT, payload)
  if not session or not fields then
    return
  end
  local ok, err = characters.select(session.handle, fields.id, function(character, why)
    if why == "gone" then
      return
    end
    send_result(session, "select", character and character.id or fields.id, why)
    send_list(session)
  end)
  if not ok then
    send_result(session, "select", fields.id, err)
  end
end

---A client asked to put its character away.
---@param player rpf.PlayerView The sender.
---@param payload any The raw payload.
local function on_deselect(player, payload)
  local session = sender(player)
  if not session or not decode(handoff.CHARACTER_DESELECT, payload) then
    return
  end
  local ok, err = characters.deselect(session.handle)
  send_result(session, "deselect", nil, not ok and err or nil)
end

-- Lifecycle ------------------------------------------------------------------

---A player registered: their session records are being held (`rpf.sync`),
---and they are listed when that lands.
---@param player rpf.PlayerView The player.
local function on_registered(player)
  ensure(player.player_id)
end

---A player is leaving: their records are released by `rpf.sync`, and their
---session here is forgotten, so an answer still in flight finds nothing.
---@param player rpf.PlayerView The player.
local function on_dropping(player)
  if player.player_id and sessions[player.player_id] and sessions[player.player_id].handle == player.handle then
    sessions[player.player_id] = nil
  end
end

---Holds the character in play's own records again, after the portal took
---some of them back while the character stayed selected (`on_lost`).
---
---The player counts as busy until it is answered, so they cannot switch or
---put the character away meanwhile: a record this hold brings back was not
---held when the character was put away, so nothing would give it back. The
---character can still go with another loss, and then whatever the hold
---brings back is released at once. If the portal refuses the hold (the
---record cannot be held again), the character is put away and the player
---goes back to choosing, from where selecting it again tries once more:
---a character is never in play without its money.
---@param session rpf.characters.Session The player.
---@param id string The character in play.
local function recover(session, id)
  session.recovering = session.recovering + 1
  rpf.sync.hold({ owners = { { kind = "character", id = id } } }, session.player_id, function(_, err)
    if sessions[session.player_id] ~= session then
      -- They left: `rpf.sync` releases everything held for their session.
      return
    end
    session.recovering = session.recovering - 1
    if session.selected ~= id then
      release_owned(id, "a character put away during its recovery")
      return
    end
    if err then
      log("warn", "could not hold the character in play's records again (" .. tostring(err) .. "); back to choosing")
      put_away(session)
      send_result(session, "select", id, "unavailable")
      send_list(session)
    end
  end)
end

---The portal says this server no longer holds some records (force-released
---by staff, or purged). A player whose character in play went with them is
---put back to choosing, and whatever the character owns that is still held
---here is released, as a put-away does. Every player's records are asked
---for again, their list counting as `stale` until they land: whatever is
---still theirs comes back, and the rest is gone from their list.
---
---The release waits a tick: this runs while the reply that found the loss
---is being settled, and the records it names are resynced after it.
---@param _ rpf.RecordRef[] The records lost.
local function on_lost(_)
  local ids = {}
  for player_id in pairs(sessions) do
    ids[#ids + 1] = player_id
  end
  table.sort(ids)
  for _, player_id in ipairs(ids) do
    local session = sessions[player_id]
    if session.selected and not records.is_held("character", session.selected) then
      local id = session.selected --[[@as string]]
      session.selected = nil
      players.advance(session.handle, "character_select")
      local view = players.get(session.handle)
      if view then
        events.emit("characters.deselected", view, id)
      end
      -- Their client is told now, whether or not the session hold lands.
      send_list(session)
      assert(platform).after(0, function()
        -- Unless the character came back and is in play, or being put in play.
        if sessions[player_id] == session and session.selected ~= id and session.selecting ~= id then
          release_owned(id, "a character the portal took away")
        end
      end)
    end
    if session.loaded then
      reload(session)
      if session.selected then
        recover(session, session.selected)
      end
    end
  end
end

---Starts the module: listens for registrations, session holds, drops and
---lost records, and for the client's character messages.
---@param p rpf.ServerPlatform The platform.
---@param client rpf.Client The connection to the portal.
---@param options rpf.CharacterOptions? Overrides for the bounds.
function characters.start(p, client, options)
  platform = p
  connection = client
  sessions = {}
  characters.options = {}
  for key, value in pairs(characters.DEFAULTS) do
    characters.options[key] = value
  end
  for key, value in pairs(options or {}) do
    characters.options[key] = value
  end
  events.on("players.registered", on_registered)
  events.on("players.dropping", on_dropping)
  events.on("records.session", on_session)
  events.on("records.lost", on_lost)
  players.on_client(handoff.CHARACTERS_REQUEST, on_request)
  players.on_client(handoff.CHARACTER_CREATE, on_create)
  players.on_client(handoff.CHARACTER_SELECT, on_select)
  players.on_client(handoff.CHARACTER_DESELECT, on_deselect)
end

rpf.characters = characters
return characters
