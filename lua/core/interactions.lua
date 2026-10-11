---Interactions (J3, J10): a player's client asks an addon to do something,
---by a name the addon registered, and the addon's handler decides on the
---server.
---
---This is the seam the contract's rule needs (`docs/architecture/addons.md`,
---"The Lua API"): a request from a client reaches **only a handler an
---active addon registered**, under its own namespace, never an event name
---the client chose. J4 (#81) adds rules to a registration (`rpf.targets`:
---a target in the world, distance, bucket, cooldown, permission, the
---addon's own check), all checked here on the server before the handler
---runs; J10 (#239) carries it as a request and its
---answer, over ox_lib's `lib.callback` on FiveM (`request_server` and
---`on_client_request` on the platform), and keeps this rule.
---
---On the server, `register(name, handler)`: `name` is
---`<namespace>.<name>` under an addon loaded here, its own when the caller
---is known; the handler runs with the player (a copy, as `players.get`
---gives it) and the payload, in the addon's context, under `pcall`, only
---while the addon is active and only for a player who has logged in
---(`players.on_client_request`). It answers `true` and, if it likes, a
---table of data for the client, or `false` and a reason. Everything in the
---request is hostile input: the payload is a JSON object, at most
---`handoff.MAX_PAYLOAD` bytes, nested at most `MAX_DEPTH` deep, of plain
---data, handed over as a copy; ids in it are the handler's to resolve
---inside the caller's scope. A player may send at most `MAX_PER_WINDOW`
---requests each `WINDOW_MS`; past that they are answered `too_many` and
---the handler is not run. Every request is answered, whatever it was,
---because ox_lib's transport holds a request open until it is.
---
---On the client, `request(name, payload, callback)` hears the answer as a
---callback, `callback(true, data)` or `callback(false, reason)`, and
---`send(name, payload)` as the reserved event `interactions.result`
---(`{ name, ok, reason }`). An answer that has not come in `TIMEOUT_MS` is
---`timeout`, and one that comes later is dropped.
---@class rpf.interactions
---@field MAX_DEPTH integer How deeply a payload, or the data in an answer, may nest.
---@field MAX_PER_WINDOW integer The most requests one player's client may send in `WINDOW_MS`.
---@field WINDOW_MS integer The window the rate is counted over.
---@field MAX_REASON_BYTES integer The longest reason a handler may give; a longer one is cut.
---@field MAX_ANSWER integer The longest answer, encoded, in bytes: a handler's data past it is refused `too_large`.
---@field TIMEOUT_MS integer How long a client waits for an answer.
---@field MAX_WAITING integer The most requests one client may have waiting for an answer at once.
---@field MAX_OFFERS_PER_WINDOW integer The most `rpf:target_offers` requests one player's client may send in `WINDOW_MS`, counted apart from interactions: a target resource asks as the player looks around, which must not use up what they may do.
local interactions = {}

local rpf = rpf
local json = rpf.json
local handoff = rpf.handoff

interactions.MAX_DEPTH = 8
interactions.MAX_PER_WINDOW = 20
interactions.WINDOW_MS = 10000
interactions.MAX_REASON_BYTES = 128
interactions.MAX_ANSWER = 16384
interactions.TIMEOUT_MS = 10000
interactions.MAX_WAITING = 64
interactions.MAX_OFFERS_PER_WINDOW = 60

---What an interaction's handler is told and how its answer goes.
---@class rpf.interactions.Entry
---@field handler any The addon's handler: a function, or a FiveM function reference.
---@field namespace string The addon that registered it.
---@field disown fun() Forgets the addon's ownership of it, once it is replaced.
---@field rules rpf.targets.Rules? Its rules (J4), if it was registered with any.

---@type table<string, rpf.interactions.Entry>
local handlers = {}
---Requests counted per player in the current window, by player id.
---@type table<string, { since: number, count: integer }>
local counts = {}
---Target resources' `rpf:target_offers` requests, counted the same way.
---@type table<string, { since: number, count: integer }>
local offer_counts = {}
---How many of this client's requests are waiting for an answer.
local waiting = 0
---@type rpf.ServerPlatform|rpf.ClientPlatform|nil
local platform = nil

---Whether a value is plain data a handler may be given: strings, numbers,
---booleans and tables of them, nested at most `MAX_DEPTH` deep. Decoded
---JSON is already, apart from depth; this keeps the rule in one place.
---Tables are walked with `next`, never `pairs`, and compared with
---`rawequal`, so a script's table with a `__pairs` or `__eq` that throws is
---refused rather than thrown through the API.
---@param value any The value.
---@param depth integer How deep it is.
---@return boolean plain True if it is.
local function plain(value, depth)
  local kind = type(value)
  if kind == "string" or kind == "number" or kind == "boolean" or rawequal(value, json.null) then
    return true
  end
  if kind ~= "table" or depth > interactions.MAX_DEPTH then
    return false
  end
  for key, item in next, value do
    if (type(key) ~= "string" and type(key) ~= "number") or not plain(item, depth + 1) then
      return false
    end
  end
  return true
end

---A copy of plain data marked the way the codec needs (`rpf.json`): a table
---whose keys are 1 to n is an array, one whose keys are strings (or none)
---an object. The other side gets a copy without marks, so an empty table
---arrives as an empty table either way. Reads are raw, as `plain`'s are, so
---a script's table with an `__index` that throws is refused, not thrown.
---@param value any Plain data (`plain`).
---@return any? marked The copy, or nil for a table that mixes the two kinds of key, or numbers that are not 1 to n.
local function mark(value)
  if type(value) ~= "table" or rawequal(value, json.null) then
    return value
  end
  local count, numbers = 0, 0
  for key in next, value do
    count = count + 1
    if type(key) == "number" then
      numbers = numbers + 1
    end
  end
  local out = {}
  if numbers > 0 then
    if numbers ~= count then
      return nil
    end
    for i = 1, count do
      if rawget(value, i) == nil then
        return nil
      end
      local item = mark(rawget(value, i))
      if item == nil then
        return nil
      end
      out[i] = item
    end
    return json.array(out)
  end
  for key, item in next, value do
    local marked = mark(item)
    if marked == nil then
      return nil
    end
    out[key] = marked
  end
  return json.object(out)
end

---A copy of a payload with no JSON marks and no `json.null`, as every value
---the API hands a script is.
---@param value any The value.
---@return any copy The copy.
local function copy(value)
  if rawequal(value, json.null) then
    return nil
  end
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in next, value do
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

---Tells every player in the world the rules there are now, once the
---current code has finished registering (`rpf:target_rules`, for a target
---resource).
local push_rules

---Whether every rule with a target, this one among them (in place of any
---registered under its name), still fits the one `rpf:target_rules` frame
---a client decodes (`handoff.MAX_LIST_PAYLOAD`), counting addons that are
---not running too, so a rule accepted now stays deliverable.
local rules_fit

---Registers an addon's interaction. Registering a name again replaces it,
---and the one replaced goes at once; one registered while the addon's code
---runs goes when it stops.
---@param name any `<namespace>.<name>`, under an addon loaded here.
---@param handler any `handler(player, payload, target)`, answering `true` and optionally a table of data for the client, or `false` and a reason for the player. `target` is what the rules resolved (`rpf.targets`), nil without a target rule.
---@param rules any? The rules (`rpf.targets.check_rules`): `label`, `target`, `distance`, `cooldown`, `permission`, `check`.
---@return boolean? ok True once registered.
---@return string? err `invalid` for a name, handler or rules that are not one, `not_found` when no addon of that namespace is loaded, `forbidden` for another addon's namespace, `inactive` from code of an addon activation that has ended, `too_large` for a rule that would take every rule with a target past what one `rpf:target_rules` frame carries.
---@return table? detail For rules refused, `{ error = "rules", field = <key> }`.
function interactions.register(name, handler, rules)
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
  local checked, bad = rpf.targets.check_rules(namespace, rules)
  if bad then
    return nil, "invalid", { error = "rules", field = bad }
  end
  if checked and not rules_fit(name, namespace, checked) then
    return nil, "too_large"
  end
  local previous = handlers[name]
  if previous then
    previous.disown()
  end
  rpf.targets.forget(name)
  ---@type rpf.interactions.Entry
  local entry = { handler = handler, namespace = namespace, disown = function() end, rules = checked }
  handlers[name] = entry
  entry.disown = rpf.addons.own(function()
    if handlers[name] == entry then
      handlers[name] = nil
      rpf.targets.forget(name)
      push_rules()
    end
  end)
  push_rules()
  return true
end

---Whether a player may send another request now, counting it.
---@param player_id string The player.
---@param counted table<string, { since: number, count: integer }>? Which count: the interactions' unless given.
---@param most integer? The most in a window: `MAX_PER_WINDOW` unless given.
---@return boolean allowed False past the rate.
local function admit(player_id, counted, most)
  local p = assert(platform)
  counted = counted or counts
  local now = p.now()
  local count = counted[player_id]
  if not count or now - count.since >= interactions.WINDOW_MS then
    count = { since = now, count = 0 }
    counted[player_id] = count
  end
  count.count = count.count + 1
  return count.count <= (most or interactions.MAX_PER_WINDOW)
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

---Encodes a refusal.
---@param reason string Why.
---@return string answer The answer, encoded.
local function refusal(reason)
  return handoff.encode(handoff.INTERACTION_RESULT, { ok = false, reason = reason })
end

---Encodes a handler's answer. A reason the codec cannot write (not UTF-8)
---is dropped, never thrown: the answer still goes. Data that is not plain,
---or cannot be encoded, is the addon's bug, logged, and answered `failed`;
---data past `MAX_ANSWER` is `too_large`.
---@param name string The interaction.
---@param ok boolean Whether it went through.
---@param extra any The handler's second result: data if it went through, a reason if not.
---@return string answer The answer, encoded.
local function encode_answer(name, ok, extra)
  local p = assert(platform)
  if not ok then
    local reason = type(extra) == "string" and cut_utf8(extra, interactions.MAX_REASON_BYTES) or nil
    local encoded, text = pcall(handoff.encode, handoff.INTERACTION_RESULT, { ok = false, reason = reason })
    if not encoded then
      p.log("warn", "rpf: the interaction " .. name .. " gave a reason that is not text; answering without it")
      text = handoff.encode(handoff.INTERACTION_RESULT, { ok = false })
    end
    return text
  end
  if extra == nil then
    return handoff.encode(handoff.INTERACTION_RESULT, { ok = true })
  end
  local data = type(extra) == "table" and plain(extra, 0) and mark(extra) or nil
  local encoded, text = false, nil
  if data ~= nil then
    encoded, text = pcall(handoff.encode, handoff.INTERACTION_RESULT, { ok = true, data = data })
  end
  if not encoded then
    p.log("error", "rpf: the interaction " .. name .. " answered data that is not a table of plain data (JSON-encodable, " .. interactions.MAX_DEPTH .. " deep at most); answering failed")
    return refusal("failed")
  end
  ---@cast text string
  if #text > interactions.MAX_ANSWER then
    p.log("warn", "rpf: the interaction " .. name .. " answered " .. #text .. " bytes, over " .. interactions.MAX_ANSWER .. "; answering too_large")
    return refusal("too_large")
  end
  return text
end

---Runs one request from a logged-in player's client, and answers it.
---@param player rpf.PlayerView The player, as `players.on_client_request` gives them.
---@param payload any The raw payload.
---@param respond fun(reply: string) Answers the request.
local function on_interact(player, payload, respond)
  local p = assert(platform)
  local request, why = handoff.decode(handoff.INTERACT, payload)
  if not request then
    p.log("debug", "rpf: refused a malformed interaction from " .. tostring(player.player_id) .. ": " .. tostring(why))
    respond(refusal("invalid"))
    return
  end
  if not admit(player.player_id) then
    p.log("debug", "rpf: refused an interaction from " .. tostring(player.player_id) .. ": too many")
    respond(refusal("too_many"))
    return
  end
  local name = request.name
  -- A name no addon could register is refused like one nobody did, so a
  -- probe learns nothing from the difference.
  local entry = interactions.is_name(name) and handlers[name] or nil
  if not entry then
    respond(refusal("unknown"))
    return
  end
  if request.payload ~= nil and not plain(request.payload, 0) then
    respond(refusal("invalid"))
    return
  end
  if not rpf.addons.running(entry.namespace) then
    respond(refusal("inactive"))
    return
  end
  local given = copy(request.payload) or {}
  local rules = entry.rules
  local target = nil
  -- The activation this request runs in, taken once: a check that yields
  -- may resume after the addon was disabled, re-enabled or reloaded.
  local context = rpf.addons.context_of(entry.namespace)
  if rules then
    local resolved, refused = rpf.targets.admit(name, rules, player, given)
    if resolved == nil then
      respond(refusal(refused or "not_found"))
      return
    end
    target = resolved or nil
    -- The cooldown starts now, before any addon code runs: a check or a
    -- handler that yields (FiveM) would otherwise let the same player's
    -- next request through the admission above meanwhile. A check that
    -- refuses gives it back.
    local reservation = rpf.targets.reserve(name, rules, player)
    if rules.check then
      local checked, allowed, why = rpf.addons.run(context, rules.check, player, rpf.targets.copy(target))
      if not checked or allowed ~= true then
        rpf.targets.release(reservation)
      end
      if not checked then
        p.log("error", "rpf: the check of the interaction " .. name .. " failed: " .. tostring(allowed))
        respond(refusal("failed"))
        return
      end
      if allowed ~= true then
        local read, text = pcall(encode_answer, name, false, why)
        respond(read and text or refusal("refused"))
        return
      end
      -- Still this registration, of this activation: one taken down while
      -- the check ran must not run its handler as if it belonged to the
      -- activation that replaced it.
      local now = rpf.addons.context_of(entry.namespace)
      if handlers[name] ~= entry or not rpf.addons.running(entry.namespace) or not now or not context or now.run ~= context.run then
        rpf.targets.release(reservation)
        respond(refusal("inactive"))
        return
      end
      -- And still allowed: a check that yields may resume after the player
      -- moved, left or lost the permission, or the target was hidden or
      -- deleted. Everything but the cooldown, which this request holds, is
      -- checked again, from the player and the target as they are now.
      local fresh = rpf.players.get(player.handle)
      if not fresh or fresh.player_id ~= player.player_id or fresh.state == "dropping" then
        rpf.targets.release(reservation)
        respond(refusal("not_logged_in"))
        return
      end
      player = fresh
      local again, refused_now = rpf.targets.admit(name, rules, player, given, true)
      if again == nil or not rpf.targets.same(target, again or nil) then
        -- Gone, out of reach, or now another target than the one the check
        -- approved (a reused ref): the handler runs on nothing unchecked.
        rpf.targets.release(reservation)
        respond(refusal(refused_now or "not_found"))
        return
      end
      target = again or nil
    end
  end
  local ran, ok, extra = rpf.addons.run(context, entry.handler, player, given, rpf.targets.copy(target))
  if not ran then
    p.log("error", "rpf: the interaction " .. name .. " failed: " .. tostring(ok))
    respond(refusal("failed"))
    return
  end
  -- The answer is the addon's data, read here after its code has run: a
  -- throw while reading it is still the addon's, and still answered.
  local read, text = pcall(encode_answer, name, ok == true, extra)
  if not read then
    p.log("error", "rpf: the interaction " .. name .. " answered something that could not be read: " .. tostring(text))
    respond(refusal("failed"))
    return
  end
  respond(text)
end

---A list marked as a JSON array, whether or not it is empty: `mark` takes
---an empty table for an object, and the client reads these as arrays.
---@param list table[] The list, of plain data.
---@return table marked The array.
local function list_of(list)
  if #list == 0 then
    return json.array({})
  end
  return mark(list) or json.array({})
end

---Checks a rule against the frame's size (declared above, for `register`).
---@param name string The interaction.
---@param namespace string Its addon.
---@param rules rpf.targets.Rules Its rules.
---@return boolean fits True if every rule still fits one frame.
rules_fit = function(name, namespace, rules)
  local entries = {}
  for other, entry in pairs(handlers) do
    entries[other] = entry
  end
  entries[name] = { rules = rules, namespace = namespace }
  -- Every string in a rule is checked as UTF-8 by `check_rules`; a throw
  -- here would still be a refusal, never through the API.
  local encoded, text = pcall(handoff.encode, handoff.TARGET_RULES, { rules = list_of(rpf.targets.listed(entries, true)) })
  return encoded and #text <= handoff.MAX_LIST_PAYLOAD
end

---The rules with a target, encoded for a client.
---@return string payload The `rpf:target_rules` payload.
local function rules_payload()
  return handoff.encode(handoff.TARGET_RULES, { rules = list_of(rpf.targets.listed(handlers)) })
end

---Whether a push of the rules is waiting to go.
local pushing = false

---Sends every player in the world the rules there are now, on the next
---turn of the clock, once however many registrations changed meanwhile.
push_rules = function()
  local p = platform --[[@as rpf.ServerPlatform?]]
  if pushing or not p or not rpf.players then
    return
  end
  pushing = true
  p.after(0, function()
    pushing = false
    local payload = rules_payload()
    for _, player in ipairs(rpf.players.list()) do
      if player.state == "active" then
        p.to_client(player.handle, handoff.TARGET_RULES, payload)
      end
    end
  end)
end

---Answers a client's `rpf:targets`: the options near them, counted against
---the same rate as their interactions.
---@param player rpf.PlayerView The player.
---@param payload any The raw request.
---@param respond fun(reply: string) Answers it.
local function on_targets(player, payload, respond)
  local empty = handoff.encode(handoff.TARGETS_RESULT, { options = json.array({}) })
  if not handoff.decode(handoff.TARGETS, payload) or not admit(player.player_id) then
    respond(empty)
    return
  end
  respond(handoff.encode(handoff.TARGETS_RESULT, { options = list_of(rpf.targets.options(handlers, player)) }))
end

---Answers a client's `rpf:target_offers`: which of the rules it names the
---server offers the player on the entity it names, for a target resource.
---Hostile input like any request: the names are a short list of strings,
---and anything else answers nothing offered.
---@param player rpf.PlayerView The player.
---@param payload any The raw request.
---@param respond fun(reply: string) Answers it.
local function on_offers(player, payload, respond)
  local request = handoff.decode(handoff.TARGET_OFFERS, payload)
  local names = request and request.names
  local valid = json.is_array(names) and #names <= rpf.targets.MAX_OFFER_NAMES
  if valid then
    for i = 1, #names do
      if not interactions.is_name(names[i]) then
        valid = false
        break
      end
    end
  end
  if not valid or not admit(player.player_id, offer_counts, interactions.MAX_OFFERS_PER_WINDOW) then
    respond(handoff.encode(handoff.TARGET_OFFERS_RESULT, { names = json.array({}) }))
    return
  end
  ---@cast request table
  local offered = rpf.targets.offers(handlers, player, request.ref, names)
  respond(handoff.encode(handoff.TARGET_OFFERS_RESULT, { names = json.array(offered) }))
end

---Listens for interactions and nearby requests, tells each player the
---target rules as they arrive in the world and whenever an addon starts or
---stops, and forgets a player's count when they leave. Called by
---`rpf.start_server`.
---@param p rpf.ServerPlatform The platform.
function interactions.serve(p)
  platform = p
  rpf.targets.serve(p)
  rpf.players.on_client_request(handoff.INTERACT, on_interact, refusal("not_logged_in"))
  rpf.players.on_client_request(
    handoff.TARGETS,
    on_targets,
    handoff.encode(handoff.TARGETS_RESULT, { options = json.array({}) })
  )
  rpf.players.on_client_request(
    handoff.TARGET_OFFERS,
    on_offers,
    handoff.encode(handoff.TARGET_OFFERS_RESULT, { names = json.array({}) })
  )
  rpf.events.on("players.active", function(player)
    p.to_client(player.handle, handoff.TARGET_RULES, rules_payload())
  end)
  rpf.events.on("addons.state", function()
    push_rules()
  end)
  rpf.events.on("players.dropping", function(player)
    if player.player_id then
      counts[player.player_id] = nil
      offer_counts[player.player_id] = nil
    end
  end)
end

-- The client ----------------------------------------------------------------

---Sends a request and hands its answer to `done` once: what the server
---answered, `timeout` when nothing came in `TIMEOUT_MS`, or `failed` for an
---answer that could not be read.
---@param name any The interaction's name.
---@param payload any? A table of plain data.
---@param done fun(ok: boolean, extra: any) Called once, never inside this call: `true` and the data (a table), or `false` and a reason.
---@return boolean? ok True once sent.
---@return string? err `invalid`, `too_large`, `too_many` or `unavailable`.
local function ask(name, payload, done)
  local p = platform --[[@as rpf.ClientPlatform?]]
  if not p or not p.request_server then
    return nil, "unavailable"
  end
  if not interactions.is_name(name) or (payload ~= nil and (type(payload) ~= "table" or not plain(payload, 0))) then
    return nil, "invalid"
  end
  local fields = { name = name }
  if payload ~= nil then
    local marked = mark(payload)
    if not json.is_object(marked) then
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
  if waiting >= interactions.MAX_WAITING then
    return nil, "too_many"
  end
  waiting = waiting + 1
  local finished = false
  ---Hands the answer over, once.
  ---@param answered boolean Whether it went through.
  ---@param extra any The data or the reason.
  local function finish(answered, extra)
    if finished then
      return
    end
    finished = true
    waiting = waiting - 1
    done(answered, extra)
  end
  p.after(interactions.TIMEOUT_MS, function()
    finish(false, "timeout")
  end)
  p.request_server(handoff.INTERACT, text, function(reply)
    if finished then
      return
    end
    local result, why = handoff.decode(handoff.INTERACTION_RESULT, reply)
    if not result then
      p.log("warn", "rpf: could not read the server's answer to the interaction " .. name .. ": " .. tostring(why))
      finish(false, "failed")
      return
    end
    if result.ok then
      finish(true, copy(result.data) or {})
    else
      finish(false, result.reason or "failed")
    end
  end)
  return true
end

---Asks the server to run an addon's interaction. The answer arrives as
---`interactions.result`.
---@param name any The interaction's name.
---@param payload any? A table of plain data, at most `handoff.MAX_PAYLOAD` bytes encoded.
---@return boolean? ok True once sent.
---@return string? err `invalid` for a name that is not `<namespace>.<name>` or a payload that is not plain data, `too_large`, `too_many` while `MAX_WAITING` requests wait for an answer, or `unavailable` before the client has started.
function interactions.send(name, payload)
  return ask(name, payload, function(ok, extra)
    rpf.events.emit("interactions.result", { name = name, ok = ok, reason = not ok and extra or nil })
  end)
end

---Asks the server to run an addon's interaction, and hands its answer to a
---callback: `callback(true, data)`, where `data` is the table the handler
---answered (empty if none), or `callback(false, reason)`. The callback runs
---under `pcall`, so one that throws is logged rather than lost.
---@param name any The interaction's name.
---@param payload any? A table of plain data, at most `handoff.MAX_PAYLOAD` bytes encoded.
---@param callback any The callback: a function, or a FiveM function reference.
---@return boolean? ok True once sent.
---@return string? err As for `send`, and `invalid` for a callback that cannot be called.
function interactions.request(name, payload, callback)
  if not rpf.callable(callback) then
    return nil, "invalid"
  end
  return ask(name, payload, function(ok, extra)
    local ran, err = pcall(callback, ok, extra)
    if not ran then
      local p = assert(platform)
      p.log("error", "rpf: the callback for the interaction " .. tostring(name) .. " failed: " .. tostring(err))
    end
  end)
end

---Keeps the platform the requests go through, and starts the client's
---half of the targets (`rpf.targets`). Called by `rpf.start_client`.
---@param p rpf.ClientPlatform The platform.
function interactions.start_client(p)
  platform = p
  rpf.targets.start_client(p)
end

rpf.interactions = interactions
return interactions
