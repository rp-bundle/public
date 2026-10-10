---Interactions (J3): a player's client asks an addon to do something, by a
---name the addon registered, and the addon's handler decides on the server.
---
---This is the seam the contract's rule needs (`docs/architecture/addons.md`,
---"The Lua API"): a request from a client reaches **only a handler an
---active addon registered**, under its own namespace, never an event name
---the client chose. J4 (#81) builds targeting on it (which record, entity
---or zone, distance, cooldowns), and J10 (#239) the request/response
---transport over ox_lib's callbacks on FiveM; both keep this rule.
---
---On the server, `register(name, handler)`: `name` is
---`<namespace>.<name>` under an addon loaded here, its own when the caller
---is known; the handler runs with the player (a copy, as `players.get`
---gives it) and the payload, in the addon's context, under `pcall`, only
---while the addon is active and only for a player who has logged in
---(`players.on_client`). It answers `true`, or `false` and a reason for the
---player's client. Everything in the request is hostile input: the payload
---is a JSON object, at most `handoff.MAX_PAYLOAD` bytes, nested at most
---`MAX_DEPTH` deep, of plain data, handed over as a copy; ids in it are the
---handler's to resolve inside the caller's scope. A player may send at most
---`MAX_PER_WINDOW` requests each `WINDOW_MS`; past that they are dropped.
---
---On the client, `send(name, payload)`. The answer arrives as the reserved
---event `interactions.result` (`{ name, ok, reason }`).
---@class rpf.interactions
---@field MAX_DEPTH integer How deeply a payload may nest.
---@field MAX_PER_WINDOW integer The most requests one player's client may send in `WINDOW_MS`.
---@field WINDOW_MS integer The window the rate is counted over.
---@field MAX_REASON_BYTES integer The longest reason a handler may give; a longer one is cut.
local interactions = {}

local rpf = rpf
local json = rpf.json
local handoff = rpf.handoff

interactions.MAX_DEPTH = 8
interactions.MAX_PER_WINDOW = 20
interactions.WINDOW_MS = 10000
interactions.MAX_REASON_BYTES = 128

---What an interaction's handler is told and how its answer goes.
---@class rpf.interactions.Entry
---@field handler any The addon's handler: a function, or a FiveM function reference.
---@field namespace string The addon that registered it.

---@type table<string, rpf.interactions.Entry>
local handlers = {}
---Requests counted per player in the current window, by player id.
---@type table<string, { since: number, count: integer }>
local counts = {}
---@type rpf.ServerPlatform|rpf.ClientPlatform|nil
local platform = nil

---Whether a value is plain data a handler may be given: strings, numbers,
---booleans and tables of them, nested at most `MAX_DEPTH` deep. Decoded
---JSON is already, apart from depth; this keeps the rule in one place.
---@param value any The value.
---@param depth integer How deep it is.
---@return boolean plain True if it is.
local function plain(value, depth)
  local kind = type(value)
  if kind == "string" or kind == "number" or kind == "boolean" or value == json.null then
    return true
  end
  if kind ~= "table" or depth > interactions.MAX_DEPTH then
    return false
  end
  for key, item in pairs(value) do
    if (type(key) ~= "string" and type(key) ~= "number") or not plain(item, depth + 1) then
      return false
    end
  end
  return true
end

---A copy of a payload with no JSON marks and no `json.null`, as every value
---the API hands a script is.
---@param value any The value.
---@return any copy The copy.
local function copy(value)
  if value == json.null then
    return nil
  end
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copy(item)
  end
  return out
end

---Whether a value is a name an addon could register an interaction under:
---`<namespace>.<name>`, identifiers, at most 64 bytes. The one rule the
---server registers by, answers by, and the client sends by.
---@param name any The value.
---@return boolean ok True if it is one.
function interactions.is_name(name)
  return type(name) == "string" and #name <= 64 and name:match("^[a-z][a-z0-9_]*%.[a-z][a-z0-9_]*$") ~= nil
end

-- The server ----------------------------------------------------------------

---Registers an addon's interaction. Registering a name again replaces it;
---one registered while the addon's code runs goes when it stops.
---@param name any `<namespace>.<name>`, under an addon loaded here.
---@param handler any `handler(player, payload)`, answering `true`, or `false` and a reason for the player.
---@return boolean? ok True once registered.
---@return string? err `invalid` for a name or handler that is not one, `not_found` when no addon of that namespace is loaded, `forbidden` for another addon's namespace, `inactive` from code of an addon activation that has ended.
function interactions.register(name, handler)
  if not rpf.addons then
    return nil, "invalid"
  end
  if not interactions.is_name(name) or not rpf.callable(handler) then
    return nil, "invalid"
  end
  local namespace = name:match("^([^.]+)%.")
  if rpf.addons.state(namespace) == nil then
    return nil, "not_found"
  end
  if not rpf.addons.may_use(name) then
    return nil, "forbidden"
  end
  if rpf.addons.stale() then
    return nil, "inactive"
  end
  ---@type rpf.interactions.Entry
  local entry = { handler = handler, namespace = namespace }
  handlers[name] = entry
  rpf.addons.own(function()
    if handlers[name] == entry then
      handlers[name] = nil
    end
  end)
  return true
end

---Whether a player may send another request now, counting it.
---@param player_id string The player.
---@return boolean allowed False past the rate.
local function admit(player_id)
  local p = assert(platform)
  local now = p.now()
  local count = counts[player_id]
  if not count or now - count.since >= interactions.WINDOW_MS then
    count = { since = now, count = 0 }
    counts[player_id] = count
  end
  count.count = count.count + 1
  return count.count <= interactions.MAX_PER_WINDOW
end

---Cuts a string to at most `n` bytes without splitting a UTF-8 character:
---a cut that would land inside one moves back to its start.
---@param text string The string.
---@param n integer The most bytes.
---@return string cut The string, cut.
local function cut_utf8(text, n)
  if #text <= n then
    return text
  end
  local at = n
  while at > 0 do
    local next_byte = text:byte(at + 1)
    if next_byte < 0x80 or next_byte >= 0xC0 then
      break
    end
    at = at - 1
  end
  return text:sub(1, at)
end

---Answers a request.
---@param handle any The player's handle.
---@param name string The interaction.
---@param ok boolean Whether it went through.
---@param reason any Why not, for the player.
local function answer(handle, name, ok, reason)
  local p = assert(platform) --[[@as rpf.ServerPlatform]]
  if type(reason) ~= "string" then
    reason = nil
  else
    reason = cut_utf8(reason, interactions.MAX_REASON_BYTES)
  end
  -- A reason the codec cannot write (not UTF-8) is dropped, never thrown:
  -- the answer still goes.
  local encoded, text = pcall(handoff.encode, handoff.INTERACTION_RESULT, { name = name, ok = ok, reason = reason })
  if not encoded then
    p.log("warn", "rpf: the interaction " .. name .. " gave a reason that is not text; answering without it")
    text = handoff.encode(handoff.INTERACTION_RESULT, { name = name, ok = ok })
  end
  p.to_client(handle, handoff.INTERACTION_RESULT, text)
end

---Runs one request from a logged-in player's client.
---@param player rpf.PlayerView The player, as `players.on_client` gives them.
---@param payload any The raw payload.
local function on_interact(player, payload)
  local p = assert(platform)
  local request = handoff.decode(handoff.INTERACT, payload)
  if not request then
    p.log("debug", "rpf: dropped a malformed interaction from " .. tostring(player.player_id))
    return
  end
  if not admit(player.player_id) then
    p.log("debug", "rpf: dropped an interaction from " .. tostring(player.player_id) .. ": too many")
    return
  end
  local name = request.name
  -- Only a name an addon could have registered gets an answer, which
  -- echoes it: anything else is dropped here.
  if not interactions.is_name(name) then
    p.log("debug", "rpf: dropped an interaction with a name no addon can register")
    return
  end
  if request.payload ~= nil and not plain(request.payload, 0) then
    answer(player.handle, name, false, "invalid")
    return
  end
  local entry = handlers[name]
  if not entry then
    answer(player.handle, name, false, "unknown")
    return
  end
  if not rpf.addons.running(entry.namespace) then
    answer(player.handle, name, false, "inactive")
    return
  end
  local ran, ok, reason = rpf.addons.run(
    rpf.addons.context_of(entry.namespace),
    entry.handler,
    player,
    copy(request.payload) or {}
  )
  if not ran then
    p.log("error", "rpf: the interaction " .. name .. " failed: " .. tostring(ok))
    answer(player.handle, name, false, "failed")
    return
  end
  answer(player.handle, name, ok == true, ok ~= true and reason or nil)
end

---Listens for interactions, and forgets a player's count when they leave.
---Called by `rpf.start_server`.
---@param p rpf.ServerPlatform The platform.
function interactions.serve(p)
  platform = p
  rpf.players.on_client(handoff.INTERACT, on_interact)
  rpf.events.on("players.dropping", function(player)
    if player.player_id then
      counts[player.player_id] = nil
    end
  end)
end

-- The client ----------------------------------------------------------------

---Asks the server to run an addon's interaction. The answer arrives as
---`interactions.result`.
---@param name any The interaction's name.
---@param payload any? A table of plain data, at most `handoff.MAX_PAYLOAD` bytes encoded.
---@return boolean? ok True once sent.
---@return string? err `invalid` for a name that is not `<namespace>.<name>` or a payload that is not plain data, `too_large`, or `unavailable` before the client has started.
function interactions.send(name, payload)
  local p = platform --[[@as rpf.ClientPlatform?]]
  if not p or not p.to_server then
    return nil, "unavailable"
  end
  if not interactions.is_name(name) or (payload ~= nil and (type(payload) ~= "table" or not plain(payload, 0))) then
    return nil, "invalid"
  end
  local fields = { name = name }
  if payload ~= nil then
    local ok, marked = pcall(function()
      return json.decode(assert(json.encode(json.is_object(payload) and payload or json.object(payload))))
    end)
    if not ok or not json.is_object(marked) then
      return nil, "invalid"
    end
    fields.payload = marked
  end
  local ok, text = pcall(handoff.encode, handoff.INTERACT, fields)
  if not ok then
    return nil, "invalid"
  end
  if #text > handoff.MAX_PAYLOAD then
    return nil, "too_large"
  end
  p.to_server(handoff.INTERACT, text)
  return true
end

---Listens for answers. Called by `rpf.start_client`.
---@param p rpf.ClientPlatform The platform.
function interactions.start_client(p)
  platform = p
  p.on_server(handoff.INTERACTION_RESULT, function(payload)
    local result = handoff.decode(handoff.INTERACTION_RESULT, payload)
    if result then
      rpf.events.emit("interactions.result", { name = result.name, ok = result.ok, reason = result.reason })
    end
  end)
end

rpf.interactions = interactions
return interactions
