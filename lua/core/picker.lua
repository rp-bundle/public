---The player's choice of character, on the player's own client (D5): the
---list the game server sends, and the requests to create, select and put
---away a character.
---
---The server decides everything (`rpf.characters`): which characters the
---player has, whether a name is acceptable, whether a character is theirs.
---This half only keeps the last list the server sent and passes the
---player's choices on, so the character select screen, which is the
---adapter's (Milestone 2, like the login form), calls these functions and
---listens for:
---
--- - `characters.listed(list, selected)` whenever the server sends the list:
---   once the player's characters are loaded after login, and after every
---   change.
--- - `characters.result(result)` with how a request went:
---   `{ during, ok, id?, reason? }`, `during` being `"create"`, `"select"`,
---   `"deselect"` or `"load"` (the characters could not be loaded; `refresh`
---   tries again).
---
---Messages from the server are checked against their schemas in
---`rpf.handoff` like every other, and a list entry that is not a character
---is left out.
---@class rpf.picker
local picker = {}

local rpf = rpf
local json = rpf.json
local events = rpf.events
local handoff = rpf.handoff

---One character as the server lists it.
---@class rpf.picker.Character
---@field id string The character's uuid.
---@field first_name string Its first name.
---@field last_name string Its last name.
---@field gender any `"male"`, `"female"` or `{ server_specific = … }`.

---@type rpf.ClientPlatform?
local platform = nil

---The last list the server sent.
---@type rpf.picker.Character[]
local list = {}

---The character in play, by the server's last list.
---@type string?
local selected = nil

---A copy of the list, safe to hand out.
---@return rpf.picker.Character[] characters The copy.
local function copy()
  local out = {}
  for i, character in ipairs(list) do
    out[i] = json.copy(character)
  end
  return out
end

---Sends one message to the server.
---@param name string The message name.
---@param fields table? Its fields.
---@return boolean sent False before `rpf.start_client`.
local function send(name, fields)
  if not platform then
    return false
  end
  platform.to_server(name, handoff.encode(name, fields))
  return true
end

---The characters the server last listed, as copies.
---@return rpf.picker.Character[] characters The characters.
function picker.list()
  return copy()
end

---The character in play, by the server's last list.
---@return string? id Its uuid, or nil while choosing.
function picker.selected()
  return selected
end

---Asks the server for the list again, which also retries loading it if
---that failed.
---@return boolean sent False before the client has started.
function picker.refresh()
  return send(handoff.CHARACTERS_REQUEST)
end

---Asks the server to create a character. The answer is a
---`characters.result` with `during = "create"`, and a new list.
---@param first_name string The first name.
---@param last_name string The last name.
---@param gender string `"male"`, `"female"`, or the server's own option.
---@return boolean? sent True if asked.
---@return string? err `"invalid"` for an argument that is not a string, `"not_started"` before the client has started.
function picker.create(first_name, last_name, gender)
  if type(first_name) ~= "string" or type(last_name) ~= "string" or type(gender) ~= "string" then
    return nil, "invalid"
  end
  if not send(handoff.CHARACTER_CREATE, { first_name = first_name, last_name = last_name, gender = gender }) then
    return nil, "not_started"
  end
  return true
end

---Asks the server to play a character, switching from the one in play. The
---answer is a `characters.result` with `during = "select"`.
---@param id string The character's uuid, from the list.
---@return boolean? sent True if asked.
---@return string? err `"invalid"` for an id that is not a string, `"not_started"` before the client has started.
function picker.select(id)
  if type(id) ~= "string" then
    return nil, "invalid"
  end
  if not send(handoff.CHARACTER_SELECT, { id = id }) then
    return nil, "not_started"
  end
  return true
end

---Asks the server to put the character in play away, back to choosing.
---@return boolean? sent True if asked.
---@return string? err `"not_started"` before the client has started.
function picker.deselect()
  if not send(handoff.CHARACTER_DESELECT) then
    return nil, "not_started"
  end
  return true
end

---Whether a list entry is a character.
---@param entry any The entry.
---@return boolean ok True if it has an id and both names as strings.
local function is_character(entry)
  return type(entry) == "table"
    and type(entry.id) == "string"
    and type(entry.first_name) == "string"
    and type(entry.last_name) == "string"
    and entry.gender ~= nil
end

---The list from the server.
---@param payload string The payload.
local function on_list(payload)
  local fields = handoff.decode(handoff.CHARACTERS, payload)
  if not fields or not json.is_array(fields.characters) then
    return
  end
  list = {}
  for _, entry in ipairs(fields.characters) do
    if is_character(entry) then
      list[#list + 1] = {
        id = entry.id,
        first_name = entry.first_name,
        last_name = entry.last_name,
        gender = json.copy(entry.gender),
      }
    end
  end
  selected = fields.selected
  events.emit("characters.listed", copy(), selected)
end

---How a request went, from the server.
---@param payload string The payload.
local function on_result(payload)
  local fields = handoff.decode(handoff.CHARACTER_RESULT, payload)
  if not fields then
    return
  end
  events.emit("characters.result", { during = fields.during, ok = fields.ok, id = fields.id, reason = fields.reason })
end

---Wires the picker up. Called by `rpf.start_client`.
---@param p rpf.ClientPlatform The platform.
function picker.start(p)
  platform = p
  list, selected = {}, nil
  p.on_server(handoff.CHARACTERS, on_list)
  p.on_server(handoff.CHARACTER_RESULT, on_result)
end

rpf.picker = picker
return picker
