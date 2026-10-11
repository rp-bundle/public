---The messages the two halves of the core exchange: the login, and then the
---choice of character.
---
---The first six are the in-game leg of the join flow (C6): the server hands
---the client the join nonce the portal issued for this connection, and the
---client hands back the join ticket the portal gave it. The `character`
---ones are D5's: the server lists a logged-in player's characters, and the
---client asks to create, select or put one away (`rpf.characters`,
---`rpf.picker`). The `interact` pair is J3's: a client asks an addon's
---registered interaction to run, and is told how it went
---(`rpf.interactions`), as a request and its answer, which the platform
---pairs (J10). The `ui` ones are J10's too: the server asks a client to show
---an addon's menu, dialog or progress bar and hears what the player did,
---or to show a notification (`rpf.ui`). They travel over the engine's own client messaging, not the
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
---@field INTERACT string Client → server, as a request (`request_server`): run an addon's registered interaction, by name, with a payload (J3, J10).
---@field INTERACTION_RESULT string Server → client, as the answer to `INTERACT`: how it went, and the handler's data. Never a message of its own: the platform pairs it with its request.
---@field UI string Server → client, as a request (`request_client`): show a menu, an input dialog or a progress bar an addon asked for (`rpf.ui`, J10).
---@field UI_ANSWER string Client → server, as the answer to `UI`: what the player did, raw, for the server to read against what it offered. Never a message of its own.
---@field UI_NOTIFY string Server → client: show a notification an addon asked for.
---@field TARGETS string Client → server, as a request (`request_server`): what this player may interact with near them (J4, `rpf.targets`).
---@field TARGETS_RESULT string Server → client, as the answer to `TARGETS`: the options, nearest first. Never a message of its own.
---@field TARGET_RULES string Server → client: every interaction rule with a target, for a target resource to offer (J4).
---@field TARGET_OFFERS string Client → server, as a request (`request_server`): which of these rules the server offers this player on an entity, by its ref, for a target resource (#317, `rpf.targets.offers`).
---@field TARGET_OFFERS_RESULT string Server → client, as the answer to `TARGET_OFFERS`: the names offered. Never a message of its own.
---@field UI_CLOSE string Server → client: close what a `UI` request showed, by its id, because the addon that asked has stopped.
---@field MAX_PAYLOAD integer The longest payload decoded, in bytes, of every message but the list of characters. Real ones are a few hundred.
---@field MAX_LIST_PAYLOAD integer The longest list of characters, answer to an interaction, UI request, nearby answer or list of target rules, decoded, in bytes. Only the client decodes these, from its own server; the server registers no handler for them, so a client cannot make the server decode one.
---@field MAX_UI_ANSWER integer The longest answer to a UI request decoded, in bytes: room for an input dialog's twelve fields of 512 bytes each, every byte escaped. The server decodes one only as the answer to a request it sent that player.
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
handoff.INTERACT = "rpf:interact"
handoff.INTERACTION_RESULT = "rpf:interaction_result"
handoff.UI = "rpf:ui"
handoff.UI_ANSWER = "rpf:ui_answer"
handoff.UI_NOTIFY = "rpf:ui_notify"
handoff.UI_CLOSE = "rpf:ui_close"
handoff.TARGETS = "rpf:targets"
handoff.TARGETS_RESULT = "rpf:targets_result"
handoff.TARGET_RULES = "rpf:target_rules"
handoff.TARGET_OFFERS = "rpf:target_offers"
handoff.TARGET_OFFERS_RESULT = "rpf:target_offers_result"
handoff.MAX_PAYLOAD = 4096
handoff.MAX_LIST_PAYLOAD = 65536
handoff.MAX_UI_ANSWER = 40960

---The longest payload decoded for each message that may be longer than
---`MAX_PAYLOAD`.
---@type table<string, integer>
local LIMITS = {
  [handoff.CHARACTERS] = handoff.MAX_LIST_PAYLOAD,
  [handoff.INTERACTION_RESULT] = handoff.MAX_LIST_PAYLOAD,
  [handoff.UI] = handoff.MAX_LIST_PAYLOAD,
  [handoff.UI_NOTIFY] = handoff.MAX_LIST_PAYLOAD,
  [handoff.UI_ANSWER] = handoff.MAX_UI_ANSWER,
  [handoff.TARGETS_RESULT] = handoff.MAX_LIST_PAYLOAD,
  [handoff.TARGET_RULES] = handoff.MAX_LIST_PAYLOAD,
}

---How one field is checked. A trailing `?` means it may be absent. A
---`table` is only checked to be one, so the module that reads it checks the
---rest; of what a client sends, an interaction's payload is one, which
---`rpf.interactions` checks is plain data before any handler sees it, and
---the names a target resource asks about, which it checks are a short
---list of strings.
---@alias rpf.handoff.FieldKind "string"|"string?"|"number"|"number?"|"boolean"|"boolean?"|"table"|"table?"

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
    truncated = "boolean?",
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
  [handoff.INTERACT] = {
    name = "string",
    payload = "table?",
  },
  [handoff.INTERACTION_RESULT] = {
    ok = "boolean",
    reason = "string?",
    data = "table?",
  },
  [handoff.UI] = {
    kind = "string",
    id = "string?",
    spec = "table",
  },
  [handoff.UI_ANSWER] = {
    ok = "boolean",
    reason = "string?",
    index = "number?",
    values = "table?",
    done = "boolean?",
  },
  [handoff.UI_NOTIFY] = {
    spec = "table",
  },
  [handoff.UI_CLOSE] = {
    id = "string",
  },
  [handoff.TARGETS] = {},
  [handoff.TARGETS_RESULT] = {
    options = "table",
  },
  [handoff.TARGET_RULES] = {
    rules = "table",
  },
  [handoff.TARGET_OFFERS] = {
    ref = "number",
    names = "table",
  },
  [handoff.TARGET_OFFERS_RESULT] = {
    names = "table",
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
  if #payload > (LIMITS[name] or handoff.MAX_PAYLOAD) then
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
