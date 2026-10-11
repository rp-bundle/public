---In-game staff (F9): what a linked staff member may do on this server, how
---a player links their account to a staff account, and how a script reports
---a staff action for the guild's audit log.
---
---**The game server enforces permissions locally, from what the portal
---pushes.** A staff member links their player account to their portal user
---with a short-lived code (`link`). From then on the portal sends this
---server `staff_permissions`: every linked staff member on its online list
---and what each may do here, resolved as the portal resolves them and named
---as on the portal (`player.kick`). It sends one after every change that
---could move anyone's permissions here, after each join, and after each
---`online_players` resync, so a reconnect repairs whatever was missed. Each
---push is the whole list, so this module replaces what it held, and a player
---left out may do nothing. Asking the portal at every check would put a
---round trip, and an outage, between a staff member and their kick.
---
---**A grant is kept by player id, whoever it names.** A push may name a
---player whose `player_authenticated` is still on its way, so every entry is
---kept, and takes effect once that player registers. A name this core does
---not know is kept too: the portal adds permissions, and addons will add
---`addon.*` ones, which a script may still ask about.
---
---**Grants outlive a dropped connection to the portal**, because staff must
---still be able to moderate while the portal is unreachable; the push after
---the next `Welcome` puts them right. They do not outlive the player: a
---player who leaves loses theirs at once. And they are memory only, so a
---restart starts with none until the portal pushes again.
---
---Nothing here believes a script about the portal's side either: `record`
---sends only what `can` allows, and the portal checks the permission again
---when the notice arrives and refuses it otherwise.
---
---Events, reserved to the core, each with a fresh table:
---`staff.changed({ player_id, permissions })` once per player whose grant a
---push or a departure changed (`permissions` sorted, empty when they lost
---everything), `staff.linked({ player_id, staff_name })` and
---`staff.link_failed({ player_id, code, reason })`.
---@class rpf.staff
---@field MAX_CODE_BYTES integer The longest link code `link` sends. The portal's codes are far shorter, so anything longer is a typo or a paste, and refusing it here costs the guild no failed guess.
---@field MAX_ACTION_BYTES integer The longest action name `record` sends, as the portal allows.
---@field MAX_CODE_WORDS integer The most words `typed` joins into a code. The portal ignores spaces, so a code typed in groups still works, but more words than any code has is a paste or a typo.
---@field COMMAND string The name of the command a player types the code into, registered on the platform (`rpflink`).
---@field LINKED string The message a player sees once linked, with `%s` for the staff account's name.
---@field LINK_UNAVAILABLE string The message a player sees when the portal could not answer a link at all.
---@field LINK_USAGE string The message a player sees when they typed the command without a code.
---@field LINK_LOGIN_FIRST string The message a player sees when they typed a code before logging in.
---@field LINK_BUSY string The message a player sees when they typed a second code while one was being checked.
---@field LINK_INVALID string The message a player sees when what they typed cannot be a code, refused here without costing the guild a guess.
local staff = {}

local rpf = rpf
local json = rpf.json
local events = rpf.events
local players = rpf.players

staff.MAX_CODE_BYTES = 32
staff.MAX_ACTION_BYTES = 64
staff.MAX_CODE_WORDS = 4
staff.COMMAND = "rpflink"
staff.LINKED = "Linked to the staff account %s."
staff.LINK_UNAVAILABLE = "Your staff account could not be linked just now. Try again in a moment."
staff.LINK_USAGE = "To link your staff account, type rpflink and the code the portal gave you."
staff.LINK_LOGIN_FIRST = "Log in to your player account first, then enter the code again."
staff.LINK_BUSY = "Your last code is still being checked. Wait for the answer."
staff.LINK_INVALID = "That link code is not valid. Check it, or ask the portal for a new one."

---What each player may do here, by player id: the last push, whole, minus
---the players who have left since.
---@type table<string, table<string, true>>
local grants = {}

---Players with a link on its way to the portal, by connection serial, so a
---player cannot queue a flood of codes, each a failed guess against the
---guild if it is wrong.
---@type table<integer, true>
local linking = {}

---@type rpf.ServerPlatform?
local platform = nil

---@type rpf.Client?
local connection = nil

---The pattern a player id must match: a hyphenated uuid.
local UUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

---Logs through the platform with the module's prefix. Never a link code.
---@param level string The level.
---@param message string The message.
local function log(level, message)
  if platform then
    platform.log(level, "rpf.staff: " .. message)
  end
end

---A set's members, sorted, as a fresh list.
---@param set table<string, true>? The set.
---@return string[] names The members.
local function sorted(set)
  local out = {}
  for name in pairs(set or {}) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

---Whether two sets hold the same members.
---@param a table<string, true>? One set, nil for none.
---@param b table<string, true>? The other.
---@return boolean same True if every member of each is in the other.
local function same_set(a, b)
  a, b = a or {}, b or {}
  for name in pairs(a) do
    if not b[name] then
      return false
    end
  end
  for name in pairs(b) do
    if not a[name] then
      return false
    end
  end
  return true
end

---A player who has logged in here and is not leaving, which is who the
---portal's grants and a staff action can be about.
---@param handle any The engine's handle, as a script gave it.
---@return rpf.PlayerView? player A copy, or nil.
local function logged_in(handle)
  local player = handle ~= nil and players.get(handle) or nil
  if not player or player.player_id == nil or player.state == "dropping" then
    return nil
  end
  return player
end

---Announces one player's grant as it now stands.
---@param player_id string The player.
local function changed(player_id)
  events.emit("staff.changed", { player_id = player_id, permissions = sorted(grants[player_id]) })
end

---Checks a push's list and builds the grants it describes. The list is the
---portal's, but checked again here, shape by shape, because a decoder is not
---the only way to reach `apply` and a list that names one player twice has
---no single meaning.
---@param list any The `staff` list of a `staff_permissions`.
---@return table<string, table<string, true>>? built The grants, or nil if refused.
---@return string? err Why.
local function build(list)
  if type(list) ~= "table" then
    return nil, "the staff list is not a list"
  end
  local count = 0
  for _ in pairs(list) do
    count = count + 1
  end
  if count ~= #list then
    return nil, "the staff list has holes"
  end
  local built = {}
  for i, entry in ipairs(list) do
    if type(entry) ~= "table" or type(entry.player_id) ~= "string" or not entry.player_id:find(UUID) then
      return nil, "entry " .. i .. " names no player"
    end
    if built[entry.player_id] then
      return nil, "player " .. entry.player_id .. " is listed twice"
    end
    local permissions = entry.permissions
    if type(permissions) ~= "table" then
      return nil, "entry " .. i .. " has no permission list"
    end
    local set, names = {}, 0
    for _ in pairs(permissions) do
      names = names + 1
    end
    if names ~= #permissions then
      return nil, "entry " .. i .. " has holes in its permissions"
    end
    for _, name in ipairs(permissions) do
      if type(name) ~= "string" then
        return nil, "entry " .. i .. " has a permission that is not a string"
      end
      set[name] = true
    end
    built[entry.player_id] = set
  end
  return built, nil
end

---Replaces every grant with a push's list, and announces `staff.changed`
---for each player whose grant is now different, in player id order. A list
---that does not check out changes nothing.
---@param list any The `staff` list: `{ player_id, permissions }` entries.
---@return boolean applied False if the list was refused.
---@return string? err Why.
function staff.apply(list)
  local built, err = build(list)
  if not built then
    return false, err
  end
  local moved = {}
  for player_id, set in pairs(built) do
    if not same_set(grants[player_id], set) then
      moved[#moved + 1] = player_id
    end
  end
  for player_id in pairs(grants) do
    if not built[player_id] then
      moved[#moved + 1] = player_id
    end
  end
  table.sort(moved)
  grants = built
  for _, player_id in ipairs(moved) do
    changed(player_id)
  end
  return true, nil
end

---Takes a `staff_permissions` notice from the portal. It has been acked
---already, so a refused one is logged and the grants it would have replaced
---stay; the portal's next push puts them right.
---@param frame rpf.Frame The decoded notice.
function staff.receive(frame)
  local ok, err = staff.apply(frame.staff)
  if not ok then
    log("warn", "refused a staff_permissions from the portal (" .. tostring(err) .. "); keeping the grants it would have replaced")
  end
end

---A player is leaving: their grant goes with them, announced if they had
---one, and any link of theirs still on its way will tell no one.
---@param player rpf.PlayerView The player, as `players.dropping` hands them over.
local function on_dropping(player)
  linking[player.serial] = nil
  local player_id = player.player_id
  if player_id and grants[player_id] then
    grants[player_id] = nil
    changed(player_id)
  end
end

---Whether a player may do something here: logged in, not leaving, and the
---last push from the portal gave them exactly that permission.
---@param handle any The engine's handle.
---@param permission any The permission, by its portal name (`player.kick`).
---@return boolean allowed False for anyone else, and for anything that is not a permission name.
function staff.can(handle, permission)
  if type(permission) ~= "string" then
    return false
  end
  local player = logged_in(handle)
  local set = player and grants[player.player_id --[[@as string]]]
  return set ~= nil and set[permission] == true
end

---What a player may do here.
---@param handle any The engine's handle.
---@return string[] permissions A sorted copy, empty for a player with no grant, and for one not logged in.
function staff.permissions(handle)
  local player = logged_in(handle)
  if not player then
    return {}
  end
  return sorted(grants[player.player_id --[[@as string]]])
end

---Tells the player how their link went and announces it. The player is
---looked up again by account, since they may have left (or come back) while
---the portal answered; one who is not here is told nothing.
---@param player_id string The player who typed the code.
---@param reply rpf.Frame? The portal's answer: `player_linked` or `rejected`.
---@param failure string? Why there was none: `expired`, `outbox_full`, `outbox_unavailable`.
local function link_answered(player_id, reply, failure)
  local player = players.by_player_id(player_id)
  if player and player.state == "dropping" then
    player = nil
  end
  local p = platform
  if reply and reply.type == "player_linked" then
    log("info", "player " .. player_id .. " linked to the staff account " .. reply.staff_name)
    if p and player then
      p.notify(player.handle, string.format(staff.LINKED, reply.staff_name))
    end
    events.emit("staff.linked", { player_id = player_id, staff_name = reply.staff_name })
    return
  end
  local code, reason
  if reply and reply.type == "rejected" then
    -- The portal writes the reason for the player, and never echoes the code.
    code, reason = reply.code, reply.reason
  else
    code, reason = failure or (reply and reply.type) or "unanswered", staff.LINK_UNAVAILABLE
    log("warn", "a link for player " .. player_id .. " got no answer from the portal (" .. code .. ")")
  end
  if p and player then
    p.notify(player.handle, reason)
  end
  events.emit("staff.link_failed", { player_id = player_id, code = code, reason = reason })
end

---Links a player's account to the staff account that issued a code: what
---the built-in `rpflink` command (`typed`), or a server's own command,
---calls when a player types the code the portal gave them. The code goes to the portal exactly as typed (it ignores case,
---spaces and hyphens) and is never logged.
---
---The outcome comes later: the player is told, and `staff.linked` or
---`staff.link_failed` is announced. Their permissions follow in the portal's
---next push, never in the answer, so there is one way a grant arrives. Each
---wrong code counts against the player, the guild and every live code, so a
---player has one link in flight at a time.
---@param handle any The engine's handle of the player who typed it.
---@param code any The code, as typed.
---@return boolean sent True once it is on its way. False if refused; for an outbox refusal the player has already been told, as for any answer.
---@return rpf.StaffRefusal? err Why not.
function staff.link(handle, code)
  local player = logged_in(handle)
  local c = connection
  if not player or not c then
    return false, "not_logged_in"
  end
  if type(code) ~= "string" or code == "" or #code > staff.MAX_CODE_BYTES or not json.is_utf8(code) then
    return false, "invalid_code"
  end
  local serial = player.serial
  if linking[serial] then
    return false, "busy"
  end
  local player_id = player.player_id --[[@as string]]
  linking[serial] = true
  local id, err = c:send("link_player", { player_id = player_id, link_code = code }, function(reply, failure)
    linking[serial] = nil
    link_answered(player_id, reply, failure)
  end)
  if not id then
    return false, err --[[@as rpf.StaffRefusal]]
  end
  return true, nil
end

---What a player is told when `link` refused before sending anything, by
---reason. An outbox refusal is not here: `link_answered` told the player.
---@type table<string, string>
local REFUSED = {
  not_logged_in = staff.LINK_LOGIN_FIRST,
  invalid_code = staff.LINK_INVALID,
  busy = staff.LINK_BUSY,
}

---The built-in command a player types a link code into (`rpflink <code>`),
---which the platform calls for each player who runs it. It is what makes a
---fresh install linkable without a script of the server's own, and it only
---turns the words into a code for `link`, so a script that offers its own
---command still gets the same checks.
---
---**The words are hostile input and a credential.** They are never logged
---and never repeated back, in a message or an event: a refusal says what is
---wrong, not what was typed. Nothing here trusts the platform to have
---limited them either, so the count and the length are checked.
---@param handle any The engine's handle of the player who ran the command.
---@param args any The words after the command, as the platform split them.
function staff.typed(handle, args)
  local p = platform
  if not p then
    return
  end
  local words = type(args) == "table" and #args or 0
  if words == 0 then
    p.notify(handle, staff.LINK_USAGE)
    return
  end
  local code = nil
  if words <= staff.MAX_CODE_WORDS then
    local parts = {}
    for i = 1, words do
      if type(args[i]) ~= "string" then
        parts = nil
        break
      end
      parts[i] = args[i]
    end
    code = parts and table.concat(parts)
  end
  local sent, err = staff.link(handle, code)
  if not sent and REFUSED[err] then
    p.notify(handle, REFUSED[err])
  end
end

---Reports a staff action a script carried out in game, for the guild's audit
---log: who did it, under which permission, what they did and to whom. Sent
---only if `can` allows it; the portal checks the permission again, and a
---refusal there is logged here, since the action has already happened.
---@param handle any The engine's handle of the staff member.
---@param permission any The permission the action needed, by its portal name (`player.kick`).
---@param action any What they did: an identifier, `[a-z][a-z0-9_]*`, at most `MAX_ACTION_BYTES` (`kick`, `teleport_to`). Free text never reaches the log.
---@param target any? The engine's handle of the player it was done to, if any. Must be logged in here.
---@return boolean sent True once it is on its way.
---@return rpf.StaffRefusal? err Why not.
function staff.record(handle, permission, action, target)
  local player = logged_in(handle)
  local c = connection
  if not player or not c or not staff.can(handle, permission) then
    return false, "forbidden"
  end
  if type(action) ~= "string" or #action > staff.MAX_ACTION_BYTES or not action:find("^[a-z][a-z0-9_]*$") then
    return false, "invalid_action"
  end
  local target_id = nil
  if target ~= nil then
    local victim = logged_in(target)
    if not victim then
      return false, "invalid_target"
    end
    target_id = victim.player_id
  end
  local player_id = player.player_id --[[@as string]]
  local what = action .. " (" .. permission .. ") by player " .. player_id
  local id, err = c:send("staff_action", {
    player_id = player_id,
    permission = permission,
    action = action,
    target_player_id = target_id,
  }, function(reply, failure)
    if reply and reply.type == "rejected" then
      log("warn", "the portal did not record the staff action " .. what .. ": " .. reply.code .. ": " .. reply.reason)
    elseif not reply then
      log("warn", "the staff action " .. what .. " was not recorded: " .. tostring(failure))
    end
  end)
  if not id then
    return false, err --[[@as rpf.StaffRefusal]]
  end
  return true, nil
end

---Starts the module: takes the portal's `staff_permissions`, forgets a
---player's grant when they leave, and registers the command a player types
---a link code into. Called by `rpf.start_server`, after
---`rpf.players`.
---@param p rpf.ServerPlatform The platform players are told through.
---@param c rpf.Client The connection to the portal.
function staff.start(p, c)
  platform, connection = p, c
  grants, linking = {}, {}
  c:listen("staff_permissions", staff.receive)
  events.on("players.dropping", on_dropping)
  p.on_command(staff.COMMAND, staff.typed)
end

rpf.staff = staff
return staff
