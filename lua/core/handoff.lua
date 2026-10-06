---The messages the two halves of the core exchange: the login, and then the
---choice of character.
---
---The first six are the in-game leg of the join flow (C6): the server hands
---the client the join nonce the portal issued for this connection, and the
---client hands back the join ticket the portal gave it. The `character`
---ones are D5's: the server lists a logged-in player's characters, and the
---client asks to create, select or put one away (`rpf.characters`,
---`rpf.picker`). They travel over the engine's own client messaging, not the
---portal protocol, and both halves ship in the same addon, so they are not
---an external contract and have no corpus. They are still hostile input on
---the server, where any client can send anything, so every payload is
---decoded against a schema here and anything else is refused. Both sides
---load this file, which is what keeps the names and shapes in step.
---@class rpf.handoff
---@field CLIENT_READY string Client → server: the client's core has started and can receive messages. Moves the player to `authenticating`.
---@field NONCE string Server → client: a join nonce, and where to use it.
---@field NONCE_REQUEST string Client → server: the nonce ran out (or is about to); please fetch another.
---@field TICKET string Client → server: a join ticket for the server to redeem.
---@field RESULT string Server → client: whether the ticket was redeemed.
---@field PORTAL_TROUBLE string Client → server: the client could not reach the portal (or the portal failed). Unverifiable, and only ever used to word this player's own timeout kick so an outage does not read as their fault.
---@field CHARACTERS_REQUEST string Client → server: send the list of my characters again.
---@field CHARACTERS string Server → client: the player's characters and which one is selected. Sent once they are loaded, and after every change.
---@field CHARACTER_CREATE string Client → server: create a character with these names and gender.
---@field CHARACTER_SELECT string Client → server: play this character, putting away the one in play first.
---@field CHARACTER_DESELECT string Client → server: put the character in play away, back to choosing.
---@field CHARACTER_RESULT string Server → client: how a create, select or deselect went.
---@field MAX_PAYLOAD integer The longest payload decoded, in bytes, of every message but the list of characters. Real ones are a few hundred.
---@field MAX_LIST_PAYLOAD integer The longest list of characters decoded, in bytes. Only the client decodes one, from its own server; the server registers no handler for it, so a client cannot make the server decode one.
---@field schemas table<string, table<string, rpf.handoff.FieldKind>> Each message's fields and their kinds.
local handoff = {}

local rpf = rpf
local json = rpf.json

handoff.CLIENT_READY = "rpf:client_ready"
handoff.NONCE = "rpf:join_nonce"
handoff.NONCE_REQUEST = "rpf:join_nonce_request"
handoff.TICKET = "rpf:join_ticket"
handoff.RESULT = "rpf:join_result"
handoff.PORTAL_TROUBLE = "rpf:join_portal_trouble"
handoff.CHARACTERS_REQUEST = "rpf:characters_request"
handoff.CHARACTERS = "rpf:characters"
handoff.CHARACTER_CREATE = "rpf:character_create"
handoff.CHARACTER_SELECT = "rpf:character_select"
handoff.CHARACTER_DESELECT = "rpf:character_deselect"
handoff.CHARACTER_RESULT = "rpf:character_result"
handoff.MAX_PAYLOAD = 4096
handoff.MAX_LIST_PAYLOAD = 65536

---How one field is checked. A trailing `?` means it may be absent. A
---`table` is only checked to be one, so the module that reads it checks the
---rest; only messages the server sends carry one.
---@alias rpf.handoff.FieldKind "string"|"string?"|"number"|"boolean"|"boolean?"|"table"

handoff.schemas = {
  [handoff.CLIENT_READY] = {},
  [handoff.NONCE_REQUEST] = {},
  [handoff.PORTAL_TROUBLE] = {},
  [handoff.NONCE] = {
    nonce = "string",
    expires_in_ms = "number",
    portal_url = "string",
    server_id = "string",
  },
  [handoff.TICKET] = {
    ticket = "string",
  },
  [handoff.RESULT] = {
    ok = "boolean",
    player_id = "string?",
    username = "string?",
    created = "boolean?",
    reason = "string?",
  },
  [handoff.CHARACTERS_REQUEST] = {},
  [handoff.CHARACTERS] = {
    characters = "table",
    selected = "string?",
  },
  [handoff.CHARACTER_CREATE] = {
    first_name = "string",
    last_name = "string",
    gender = "string",
  },
  [handoff.CHARACTER_SELECT] = {
    id = "string",
  },
  [handoff.CHARACTER_DESELECT] = {},
  [handoff.CHARACTER_RESULT] = {
    during = "string",
    ok = "boolean",
    id = "string?",
    reason = "string?",
  },
}

---Checks a table against a message's schema. Fields not in the schema are
---dropped, as the portal protocol drops them.
---@param name string The message name.
---@param value table The fields.
---@return table? fields Only the known fields, or nil if refused.
---@return string? err Why.
local function check(name, value)
  local schema = handoff.schemas[name]
  if not schema then
    return nil, "unknown message " .. tostring(name)
  end
  local out = {}
  for field, kind in pairs(schema) do
    local optional = kind:sub(-1) == "?"
    local base = optional and kind:sub(1, -2) or kind
    local v = value[field]
    if v == nil or v == json.null then
      if not optional then
        return nil, field .. " is missing"
      end
    elseif type(v) ~= base then
      return nil, field .. " must be a " .. base
    elseif base == "string" and #v > 512 then
      return nil, field .. " is too long"
    else
      out[field] = v
    end
  end
  return out, nil
end

---Encodes a message's payload. Throws on a payload that does not match its
---schema, because that is a bug in the core, not bad input.
---@param name string The message name, one of the constants above.
---@param fields table? The fields.
---@return string payload The JSON payload.
function handoff.encode(name, fields)
  local checked, err = check(name, fields or {})
  if not checked then
    error("rpf: cannot encode " .. tostring(name) .. ": " .. tostring(err), 2)
  end
  local text, encode_err = json.encode(json.object(checked))
  if not text then
    error("rpf: cannot encode " .. name .. ": " .. tostring(encode_err), 2)
  end
  return text
end

---Decodes a payload that arrived from the other half. It is hostile input on
---the server, so every failure is a return value, never a thrown error.
---@param name string The message name it arrived under.
---@param payload any The raw payload.
---@return table? fields Only the known fields, or nil if refused.
---@return string? err Why it was refused.
function handoff.decode(name, payload)
  if type(payload) ~= "string" then
    return nil, "the payload is not a string"
  end
  if #payload > (name == handoff.CHARACTERS and handoff.MAX_LIST_PAYLOAD or handoff.MAX_PAYLOAD) then
    return nil, "the payload is too long"
  end
  local value, err = json.decode(payload)
  if err then
    return nil, err
  end
  if not json.is_object(value) then
    return nil, "the payload is not an object"
  end
  ---@cast value table
  return check(name, value)
end

rpf.handoff = handoff
return handoff
