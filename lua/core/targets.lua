---Targets (J4): what a player's client may point an interaction at in the
---world, and every check the server makes before the addon's handler runs.
---
---An addon registers an interaction with **rules** (`rpf.interactions`'s
---`register(name, handler, rules)`): a target, how near, how often, who
---may, and its own test. The client only **names** a target, in the
---request's payload (`payload.target`): a record by `id`, or an entity by
---its `ref` (a FiveM network id, a Gmod entity index). Everything that
---decides whether it may is read on the server, from the server's state:
---
---1. The player is in the world (`active`).
---2. They hold the rule's `permission`, as linked staff (`rpf.staff.can`
---   with `addon.<namespace>.<permission>`).
---3. The rule's `cooldown` since their last use has passed.
---4. The target resolves inside this server, and as the server has it now:
---   a record of the rule's world-backed type (a config record, or a live
---   one held here) that is visible, in the player's bucket, and within
---   `distance` of them (inside a zone's radius); or a networked entity in
---   their bucket, within `distance`, whose model is one of the rule's (or,
---   for a type's rule, that the core placed for a record of the type).
---   Missing, hidden, another bucket, another type and not this server's
---   are one answer, `not_found`, so a probe learns nothing; a target in
---   the player's world but out of reach is `too_far`.
---5. The addon's `check(player, target)`, under `pcall`, in its context.
---
---**Distances are metres.** A rule's `distance`, a zone's radius field and
---the `distance` a resolved target or a nearby option reports are all in
---metres, on every engine; the core converts to and from the engine's units
---by the scale the adapter declares (`rpf.world.units`), so an addon never
---tells engines apart. A target resource is told the rule's distance in the
---engine's units, since that is what it measures in.
---
---Only then does the handler run, with the resolved target as its third
---argument, and the cooldown starts. A client never names an event: the
---interaction's name reaches only a registered handler, as before.
---
---**Nearby targets.** The minimal interaction UI asks the server what is
---near (`rpf:targets`): every option of a type's rule within reach of the
---player and offered to them, nearest first, at most `MAX_NEARBY`. The
---server works it out, so a client never holds the records. On the client,
---`open()` asks, shows the answer as a menu (`rpf.ui`), and sends the one
---picked; an adapter binds it to a key.
---
---**Offered** means what a request would pass, as far as the server can
---tell without running the handler: the permission, the cooldown, the
---target, and the addon's own `check`, run the same way the request runs
---it (#317). So a menu never lists what the addon will refuse (a lot that
---is sold, an owner-only door). Checks are addon code and may yield, so a
---listing runs at most `MAX_CHECKS` of them and starts none after
---`CHECK_BUDGET_MS`; an option whose check did not run is left out, never
---shown unchecked. A listing is presentation: the request is checked again
---when the player picks.
---
---**Target resources.** The server tells each player in the world which
---rules there are (`rpf:target_rules`: name, label, type, kind, models,
---distance) whenever they arrive and whenever the registrations change, and
---the client announces them as `interactions.targets`, so an adapter can
---offer them through a target resource (ox_target, qb-target on FiveM).
---A resource asks on every frame whether to show an option on an entity,
---which no server can answer that often, so the client asks the server
---which of the rules it shows are offered on an entity
---(`rpf:target_offers`, `offered`), keeps the answer for `OFFER_TTL_MS`,
---and shows an option only once the server said so. What the resource
---shows is presentation: selecting an option sends the same request,
---checked the same way.
---@class rpf.targets
---@field DEFAULT_DISTANCE number How near a target must be when a rule does not say, in metres.
---@field MAX_DISTANCE number The farthest a rule may reach, in metres.
---@field MAX_COOLDOWN_MS integer The longest cooldown a rule may set: an hour.
---@field MAX_MODELS integer The most models one rule may name.
---@field MAX_LABEL integer The longest label, in bytes.
---@field MAX_NEARBY integer The most options one nearby answer lists.
---@field TIMEOUT_MS integer How long a client waits for the nearby answer.
---@field MAX_CHECKS integer The most addon checks one listing runs: a menu, or one entity's options for a target resource.
---@field CHECK_BUDGET_MS integer How long a listing may take before it starts no more checks: one that yields holds the answer up.
---@field MAX_LISTING integer The most listings one player may have running at once; past it a listing answers nothing offered. Only checks that yield keep one running.
---@field MAX_OFFER_NAMES integer The most rules one `rpf:target_offers` request may ask about.
---@field OFFER_TTL_MS integer How long a client keeps the server's answer about an entity before asking again.
---@field MAX_OFFER_REFS integer The most entities a client keeps answers for; past it, it forgets them all.
---@field MAX_OFFERS_ASKING integer The most `rpf:target_offers` requests a client has waiting at once.
local targets = {}

local rpf = rpf
local json = rpf.json
local handoff = rpf.handoff

targets.DEFAULT_DISTANCE = 3
targets.MAX_DISTANCE = 10000
targets.MAX_COOLDOWN_MS = 3600000
targets.MAX_MODELS = 32
targets.MAX_LABEL = 64
targets.MAX_NEARBY = 16
targets.TIMEOUT_MS = 10000
targets.MAX_CHECKS = 32
targets.CHECK_BUDGET_MS = 2000
targets.MAX_LISTING = 4
targets.MAX_OFFER_NAMES = 16
targets.OFFER_TTL_MS = 1500
targets.MAX_OFFER_REFS = 64
targets.MAX_OFFERS_ASKING = 2

---A registration's rules, checked.
---@class rpf.targets.Rules
---@field label string? What a menu or target resource shows.
---@field type string? The world-backed type a target must be a record of.
---@field models string[]? The models an entity target must be one of.
---@field distance number How near, in metres.
---@field cooldown integer Milliseconds between one player's uses.
---@field permission string? The full addon flag the player must hold.
---@field check any? The addon's own test: a function, or a FiveM function reference.

---A resolved target, as the handler and `check` get it.
---@class rpf.targets.Target
---@field type string? The record's type, for a record.
---@field id string? The record's id, for a record (or an entity the core placed for one).
---@field record table? A copy of the record.
---@field ref integer? The entity's ref, for an entity.
---@field model any The entity's model, for an entity.
---@field position { x: number, y: number, z: number } Where it is.
---@field distance number How far the player is from it, in metres.

---@type rpf.ServerPlatform|rpf.ClientPlatform|nil
local platform = nil
---Each player's last use of each interaction, by name then player id: the
---reservation that started its cooldown (`reserve`), known by identity, so
---a stale request giving its own back can never give back a newer one.
---@type table<string, table<string, rpf.targets.Reservation>>
local used = {}

---Whether a value is a finite number.
---@param n any The value.
---@return boolean finite True if it is.
local function finite(n)
  return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

---Whether a value is a type's full name, `<namespace>.<name>`.
---@param name any The value.
---@return boolean ok True if it is.
local function is_type_name(name)
  return type(name) == "string" and #name <= 64 and name:match("^[a-z][a-z0-9_]*%.[a-z][a-z0-9_]*$") ~= nil
end

---Whether a value is a record id as the portal writes one: a lowercase,
---hyphenated uuid.
---@param id any The value.
---@return boolean ok True if it is.
local function is_uuid(id)
  return type(id) == "string"
    and id:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
    and id:lower() == id
end

---Checks an addon's rules for an interaction, as the author wrote them.
---Every key is one the rules know, so a typo is refused, not ignored.
---@param namespace string The addon registering.
---@param raw any The rules: nil, or a table.
---@return rpf.targets.Rules? rules The rules, checked, or nil for none.
---@return string? err The key of the first rule refused (`distance`, `target.models`).
function targets.check_rules(namespace, raw)
  if raw == nil then
    return nil
  end
  if type(raw) ~= "table" then
    return nil, "rules"
  end
  local known = { label = true, target = true, distance = true, cooldown = true, permission = true, check = true }
  for key in next, raw do
    if not known[key] then
      return nil, tostring(key)
    end
  end
  ---@type rpf.targets.Rules
  local out = { distance = targets.DEFAULT_DISTANCE, cooldown = 0 }
  if raw.label ~= nil then
    if type(raw.label) ~= "string" or raw.label == "" or #raw.label > targets.MAX_LABEL or not json.is_utf8(raw.label) then
      return nil, "label"
    end
    out.label = raw.label
  end
  local target = raw.target
  if type(target) == "string" then
    target = { type = target }
  end
  if target ~= nil then
    if type(target) ~= "table" then
      return nil, "target"
    end
    for key in next, target do
      if key ~= "type" and key ~= "models" then
        return nil, "target." .. tostring(key)
      end
    end
    if (target.type == nil) == (target.models == nil) then
      return nil, "target"
    end
    if target.type ~= nil then
      if not is_type_name(target.type) then
        return nil, "target.type"
      end
      out.type = target.type
    else
      local models = target.models
      if type(models) ~= "table" or #models < 1 or #models > targets.MAX_MODELS then
        return nil, "target.models"
      end
      out.models = {}
      for i = 1, #models do
        local model = models[i]
        if type(model) ~= "string" or model == "" or #model > 256 or not json.is_utf8(model) then
          return nil, "target.models"
        end
        out.models[i] = model
      end
    end
  end
  if raw.distance ~= nil then
    if not finite(raw.distance) or raw.distance <= 0 or raw.distance > targets.MAX_DISTANCE then
      return nil, "distance"
    end
    out.distance = raw.distance
  end
  if raw.cooldown ~= nil then
    local c = raw.cooldown
    if not finite(c) or c ~= math.floor(c) or c < 0 or c > targets.MAX_COOLDOWN_MS then
      return nil, "cooldown"
    end
    out.cooldown = c
  end
  if raw.permission ~= nil then
    if type(raw.permission) ~= "string" or not raw.permission:match("^[a-z][a-z0-9_]*$") or #raw.permission > 32 then
      return nil, "permission"
    end
    out.permission = "addon." .. namespace .. "." .. raw.permission
  end
  if raw.check ~= nil then
    if not rpf.callable(raw.check) then
      return nil, "check"
    end
    out.check = raw.check
  end
  return out
end

---The distance between two positions.
---@param a { x: number, y: number, z: number } One.
---@param b { x: number, y: number, z: number } The other.
---@return number distance The distance.
local function distance(a, b)
  local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

---Where a world-backed record is, as the player may reach it: nil when the
---type has no world, or the record is hidden, on another map (#369), in
---another bucket or has no position.
---@param where table The type's `world`.
---@param fields table The record's fields.
---@param bucket integer The player's bucket.
---@return { x: number, y: number, z: number }? position Where it is.
local function placed_at(where, fields, bucket)
  if where.visible and fields[where.visible] == false then
    return nil
  end
  if not rpf.world.on_map(where, fields) then
    return nil
  end
  local record_bucket = where.bucket and fields[where.bucket]
  if not finite(record_bucket) then
    record_bucket = 0
  end
  if record_bucket ~= bucket then
    return nil
  end
  local at = fields[where.position]
  if type(at) ~= "table" or not finite(at.x) or not finite(at.y) or not finite(at.z) then
    return nil
  end
  return { x = at.x, y = at.y, z = at.z }
end

---Whether a record at `d` is within reach: inside a zone's radius, or
---within the rule's distance of anything else. Both are in metres, so the
---distance is compared in the engine's units after converting them.
---@param where table The type's `world`.
---@param fields table The record's fields.
---@param d number How far the player is, in the engine's units.
---@param rules rpf.targets.Rules The rules.
---@return boolean reach True if it is.
local function within(where, fields, d, rules)
  local metres = rules.distance
  if where.kind == "zone" then
    metres = fields[where.radius]
  end
  local reach = rpf.world.units(metres)
  return reach ~= nil and d <= reach
end

---The `world` of a type, if it is world-backed and installed.
---@param type_name string The type.
---@return table? where Its `world`.
local function world_of(type_name)
  local def = rpf.addons.definition(type_name)
  local where = type(def) == "table" and def.world or nil
  if type(where) ~= "table" or type(where.position) ~= "string" then
    return nil
  end
  return where
end

---Resolves the target a client named for a type's rule.
---@param rules rpf.targets.Rules The rules.
---@param named table The client's `target`.
---@param at { x: number, y: number, z: number } The player's position.
---@param bucket integer The player's bucket.
---@return rpf.targets.Target? target It.
---@return string? err `not_found` or `too_far`.
local function resolve_record(rules, named, at, bucket)
  local type_name = rules.type --[[@as string]]
  local id = named.id
  if id == nil and named.ref ~= nil then
    local entity = rpf.world.entity(named.ref)
    local placement = entity and entity.placement
    if not placement or placement.type ~= type_name then
      return nil, "not_found"
    end
    id = placement.id
  end
  if not is_uuid(id) then
    return nil, "not_found"
  end
  local where = world_of(type_name)
  local record = where and rpf.data.get(type_name, id)
  if not where or not record then
    return nil, "not_found"
  end
  local spot = placed_at(where, record.fields, bucket)
  if not spot then
    return nil, "not_found"
  end
  local d = distance(at, spot)
  if not within(where, record.fields, d, rules) then
    return nil, "too_far"
  end
  return { type = type_name, id = id, record = record, position = spot, distance = rpf.world.metres(d) }
end

---Resolves the entity a client named for a models rule.
---@param rules rpf.targets.Rules The rules.
---@param named table The client's `target`.
---@param at { x: number, y: number, z: number } The player's position.
---@param bucket integer The player's bucket.
---@return rpf.targets.Target? target It.
---@return string? err `not_found`, `too_far` or `unsupported`.
local function resolve_entity(rules, named, at, bucket)
  local entity, err = rpf.world.entity(named.ref)
  if not entity then
    return nil, err == "unsupported" and "unsupported" or "not_found"
  end
  if entity.bucket ~= bucket then
    return nil, "not_found"
  end
  local matched = false
  for _, name in ipairs(rules.models --[[@as string[] ]]) do
    local id = rpf.world.model(name)
    if id ~= nil and id == entity.model then
      matched = true
      break
    end
  end
  if not matched then
    return nil, "not_found"
  end
  local d = distance(at, entity.position)
  local reach = rpf.world.units(rules.distance)
  if not reach or d > reach then
    return nil, "too_far"
  end
  local target = { ref = named.ref, model = entity.model, position = entity.position, distance = rpf.world.metres(d) }
  if entity.placement then
    target.type, target.id = entity.placement.type, entity.placement.id
  end
  return target
end

---Every check a rule makes before its handler runs, but the addon's own
---(`check`, which runs in the addon's context: `rpf.interactions`).
---@param name string The interaction.
---@param rules rpf.targets.Rules The rules.
---@param player rpf.PlayerView The player.
---@param payload table The request's payload, a plain copy.
---@param again boolean? True when checking again after the addon's `check` ran (it may have yielded): the request's own cooldown is not held against it.
---@return rpf.targets.Target|false|nil target The resolved target; false for a rule with none; nil if refused.
---@return string? err `not_active`, `forbidden`, `cooldown`, `not_found`, `too_far` or `unsupported`.
function targets.admit(name, rules, player, payload, again)
  local wants_target = rules.type ~= nil or rules.models ~= nil
  if wants_target and player.state ~= "active" then
    return nil, "not_active"
  end
  if rules.permission and not rpf.staff.can(player.handle, rules.permission) then
    return nil, "forbidden"
  end
  if rules.cooldown > 0 and not again then
    local last = used[name] and used[name][player.player_id]
    if last and assert(platform).now() - last.at < rules.cooldown then
      return nil, "cooldown"
    end
  end
  if not wants_target then
    return false
  end
  local named = payload.target
  if type(named) ~= "table" then
    return nil, "not_found"
  end
  local at, why = rpf.world.position(player.handle)
  if not at then
    return nil, why == "unsupported" and "unsupported" or "not_found"
  end
  local bucket = rpf.world.bucket(player.handle)
  if not bucket then
    return nil, "not_found"
  end
  if rules.type then
    return resolve_record(rules, named, at, bucket)
  end
  return resolve_entity(rules, named, at, bucket)
end

---A cooldown taken for a request, to give back if its check refuses.
---@class rpf.targets.Reservation
---@field name string The interaction.
---@field player_id string The player.
---@field at number When it was taken.
---@field before number? When the use it replaced was, put back if it is given back: a time, never the reservation, so no reservation keeps an earlier one alive.

---Whether two resolutions of a request name the same target: the same
---record (type and id), or the same entity (ref and model) when it is no
---record. What the target an addon's check approved must still be when
---its handler runs.
---@param a rpf.targets.Target? One.
---@param b rpf.targets.Target? The other.
---@return boolean same True if they do.
function targets.same(a, b)
  if a == nil or b == nil then
    return a == b
  end
  if a.id ~= nil or b.id ~= nil then
    return a.type == b.type and a.id == b.id
  end
  return a.ref == b.ref and a.model == b.model
end

---Starts a player's cooldown for an interaction as their request is
---admitted, before any addon code runs, so a check or handler that yields
---cannot let their next request past `admit` meanwhile.
---@param name string The interaction.
---@param rules rpf.targets.Rules Its rules.
---@param player rpf.PlayerView The player.
---@return rpf.targets.Reservation? reservation What to give back if the check refuses, or nil for a rule with no cooldown.
function targets.reserve(name, rules, player)
  if rules.cooldown <= 0 then
    return nil
  end
  used[name] = used[name] or {}
  local at = assert(platform).now()
  local previous = used[name][player.player_id]
  local reservation = { name = name, player_id = player.player_id, at = at, before = previous and previous.at }
  used[name][player.player_id] = reservation
  return reservation
end

---Gives a cooldown back: the addon's check refused, so the interaction was
---not used. Only if nothing has taken the player's cooldown since.
---@param reservation rpf.targets.Reservation? What `reserve` gave.
function targets.release(reservation)
  if not reservation then
    return
  end
  local by_player = used[reservation.name]
  if by_player and rawequal(by_player[reservation.player_id], reservation) then
    local before = reservation.before
    by_player[reservation.player_id] = before
        and { name = reservation.name, player_id = reservation.player_id, at = before }
      or nil
  end
end

---Forgets an interaction's cooldowns, when it is replaced or taken down.
---@param name string The interaction.
function targets.forget(name)
  used[name] = nil
end

---Whether a rule is offered to a player now, before its target: they hold
---its permission, and its cooldown has passed.
---@param name string The interaction.
---@param rules rpf.targets.Rules Its rules.
---@param player rpf.PlayerView The player.
---@return boolean offered True if it is.
local function offered(name, rules, player)
  if rules.permission and not rpf.staff.can(player.handle, rules.permission) then
    return false
  end
  local last = used[name] and used[name][player.player_id]
  return not (rules.cooldown > 0 and last and assert(platform).now() - last.at < rules.cooldown)
end

---How many listings each player has running, by player id: only a check
---that yields keeps one running.
---@type table<string, integer>
local listing = {}

---What one listing may still spend on addon checks.
---@class rpf.targets.Budget
---@field checks integer Checks run so far.
---@field since number When the listing started.

---Starts a listing for a player, unless they have `MAX_LISTING` running.
---@param player rpf.PlayerView The player.
---@return rpf.targets.Budget? budget What it may spend, or nil when it may not start.
local function begin_listing(player)
  local id = player.player_id
  if not id then
    return nil
  end
  local running = listing[id] or 0
  if running >= targets.MAX_LISTING then
    return nil
  end
  listing[id] = running + 1
  return { checks = 0, since = assert(platform).now() }
end

---Ends a listing `begin_listing` started.
---@param player rpf.PlayerView The player.
local function end_listing(player)
  local id = player.player_id
  if not id then
    return
  end
  local running = (listing[id] or 1) - 1
  listing[id] = running > 0 and running or nil
end

---The player as they are now, if still the one a listing is for, logged in
---and in the world: a check that yielded may resume after they left.
---@param player rpf.PlayerView The player the listing is for.
---@return rpf.PlayerView? fresh A fresh copy, or nil.
local function still(player)
  local fresh = rpf.players.get(player.handle)
  if not fresh or fresh.player_id ~= player.player_id or fresh.state ~= "active" then
    return nil
  end
  return fresh
end

---Whether a player is offered an interaction on a target for a listing:
---everything a request for it would pass, the same way. The registration
---is still the one listed and its addon running; `admit` (permission,
---cooldown, the target as the server has it now) passes for the player as
---they are now; and the addon's own check, if it has one, answers `true`,
---run in its context under `pcall` with copies, within the listing's
---budget. A check may yield, so after it everything is checked again as a
---request checks it: the same activation, the player still here, and the
---same target admitted. Not run, failed, refused or changed are all no.
---@param entries table<string, { rules: rpf.targets.Rules?, namespace: string }> The registrations, by name, as they are now.
---@param name string The interaction.
---@param entry { rules: rpf.targets.Rules?, namespace: string } Its registration, as listed.
---@param player rpf.PlayerView The player.
---@param named table What a request would name: `{ id }` or `{ ref }`.
---@param budget rpf.targets.Budget What the listing may still spend.
---@return rpf.targets.Target? target The target as admitted, if offered.
local function vet(entries, name, entry, player, named, budget)
  local rules = entry.rules --[[@as rpf.targets.Rules]]
  if entries[name] ~= entry or not rpf.addons.running(entry.namespace) then
    return nil
  end
  local fresh = still(player)
  local target = fresh and targets.admit(name, rules, fresh, { target = named }) or nil
  if not fresh or not target then
    return nil
  end
  if rules.check == nil then
    return target
  end
  local p = assert(platform)
  if budget.checks >= targets.MAX_CHECKS or p.now() - budget.since >= targets.CHECK_BUDGET_MS then
    return nil
  end
  budget.checks = budget.checks + 1
  local context = rpf.addons.context_of(entry.namespace)
  local ran, allowed = rpf.addons.run(context, rules.check, fresh, targets.copy(target))
  if not ran then
    p.log("error", "rpf: the check of the interaction " .. name .. " failed while listing: " .. tostring(allowed))
    return nil
  end
  if allowed ~= true then
    return nil
  end
  local now = rpf.addons.context_of(entry.namespace)
  if entries[name] ~= entry or not rpf.addons.running(entry.namespace) or not now or not context or now.run ~= context.run then
    return nil
  end
  fresh = still(player)
  local again = fresh and targets.admit(name, rules, fresh, { target = named }) or nil
  if not again or not targets.same(target, again) then
    return nil
  end
  return again
end

---The options near a player: each type's rule's records within its reach,
---in the player's bucket and visible, offered to the player (permission,
---cooldown, and the addon's own check), nearest first, at most
---`MAX_NEARBY`. Checks run nearest first, within the listing's budget.
---@param entries table<string, { rules: rpf.targets.Rules?, namespace: string }> The registrations, by name.
---@param player rpf.PlayerView The player.
---@return { name: string, label: string, type: string, id: string, distance: number }[] options The options.
function targets.options(entries, player)
  local out = {}
  if player.state ~= "active" then
    return out
  end
  local at = rpf.world.position(player.handle)
  local bucket = rpf.world.bucket(player.handle)
  if not at or not bucket then
    return out
  end
  local names = {}
  for name in pairs(entries) do
    names[#names + 1] = name
  end
  table.sort(names)
  local found = {}
  for _, name in ipairs(names) do
    local entry = entries[name]
    local rules = entry.rules
    local where = rules and rules.type and rpf.addons.running(entry.namespace) and world_of(rules.type) or nil
    if rules and where and offered(name, rules, player) then
      local records = rpf.data.list(rules.type --[[@as string]], {}) or {}
      for _, record in ipairs(records) do
        local spot = placed_at(where, record.fields, bucket)
        local d = spot and distance(at, spot)
        if d and within(where, record.fields, d, rules) then
          found[#found + 1] = {
            name = name,
            entry = entry,
            id = record.id,
            distance = d,
          }
        end
      end
    end
  end
  table.sort(found, function(a, b)
    if a.distance ~= b.distance then
      return a.distance < b.distance
    end
    if a.name ~= b.name then
      return a.name < b.name
    end
    return a.id < b.id
  end)
  local budget = begin_listing(player)
  if not budget then
    return out
  end
  -- Ended whatever a check does: it runs under `pcall`, so nothing below throws.
  for _, option in ipairs(found) do
    if #out >= targets.MAX_NEARBY then
      break
    end
    local target = vet(entries, option.name, option.entry, player, { id = option.id }, budget)
    if target then
      local rules = option.entry.rules --[[@as rpf.targets.Rules]]
      out[#out + 1] = {
        name = option.name,
        label = rules.label or option.name,
        type = target.type,
        id = target.id,
        distance = target.distance,
      }
    end
  end
  end_listing(player)
  return out
end

---Which of the named rules are offered to a player on an entity, for a
---target resource (`rpf:target_offers`): each admitted as a request naming
---the entity would be (`admit`, without taking the cooldown), then passing
---the addon's own check, within one listing's budget. Every name is hostile
---input: one that is not a running registration with a target is simply
---not offered.
---@param entries table<string, { rules: rpf.targets.Rules?, namespace: string }> The registrations, by name.
---@param player rpf.PlayerView The player.
---@param ref any The entity, as the client named it.
---@param names string[] The rules asked about, at most `MAX_OFFER_NAMES`, each a string.
---@return string[] offered The names offered, in the order asked, each once.
function targets.offers(entries, player, ref, names)
  local out = {}
  if player.state ~= "active" then
    return out
  end
  local budget = begin_listing(player)
  if not budget then
    return out
  end
  local seen = {}
  for _, name in ipairs(names) do
    local entry = entries[name]
    local rules = entry and entry.rules
    if not seen[name] and rules and (rules.type or rules.models) and rpf.addons.running(entry.namespace) then
      seen[name] = true
      if vet(entries, name, entry, player, { ref = ref }, budget) then
        out[#out + 1] = name
      end
    end
  end
  end_listing(player)
  return out
end

---What a target resource needs to offer the rules with a target: for each,
---its name, label, and the type (with its world kind) or models it targets,
---and how near in the engine's units, in name order.
---@param entries table<string, { rules: rpf.targets.Rules?, namespace: string }> The registrations, by name.
---@param all boolean? True to list those of addons not running too: what a registration's size is checked against.
---@return table[] rules The rules, plain.
function targets.listed(entries, all)
  local names = {}
  for name, entry in pairs(entries) do
    if entry.rules and (entry.rules.type or entry.rules.models) and (all or rpf.addons.running(entry.namespace)) then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  local out = {}
  for i, name in ipairs(names) do
    local rules = entries[name].rules --[[@as rpf.targets.Rules]]
    local where = rules.type and world_of(rules.type)
    out[i] = {
      name = name,
      label = rules.label or name,
      type = rules.type,
      kind = where and where.kind or nil,
      models = rules.models and json.array(rules.models) or nil,
      distance = rpf.world.units(rules.distance),
    }
  end
  return out
end

---Keeps the platform, and forgets a player's cooldowns when they leave.
---Called by `rpf.interactions.serve`.
---@param p rpf.ServerPlatform The platform.
function targets.serve(p)
  platform = p
  used = {}
  listing = {}
  rpf.events.on("players.dropping", function(player)
    if player.player_id then
      for _, by_player in pairs(used) do
        by_player[player.player_id] = nil
      end
    end
  end)
end

-- The client -----------------------------------------------------------------

---The rules the server last sent, for a target resource.
---@type table[]
local known = {}
---Whether a nearby request is waiting for its answer.
local asking = false

---A copy of plain data with no JSON marks and no `json.null`.
---@param value any The value.
---@return any copy The copy.
local function plain(value)
  if rawequal(value, json.null) then
    return nil
  end
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = plain(item)
  end
  return out
end

---A copy of a resolved target, so the addon's `check` and its handler each
---get their own and neither can change what the other sees.
---@param target rpf.targets.Target? The target.
---@return rpf.targets.Target? copy The copy.
function targets.copy(target)
  return plain(target)
end

---The rules the server last sent: what `interactions.targets` announced.
---@return table[] rules A copy.
function targets.rules()
  return plain(known)
end

---Asks the server what is near, and hands the options to `done` once: a
---list, or nil and why (`timeout`, `failed`, `busy` while one is waiting,
---`unavailable` before the client has started).
---@param done fun(options: table[]?, err: string?) Called once.
function targets.nearby_client(done)
  local p = platform --[[@as rpf.ClientPlatform?]]
  if not p or not p.request_server then
    done(nil, "unavailable")
    return
  end
  if asking then
    done(nil, "busy")
    return
  end
  asking = true
  local finished = false
  ---Hands the answer over, once.
  ---@param options table[]? The options.
  ---@param err string? Why not.
  local function finish(options, err)
    if finished then
      return
    end
    finished = true
    asking = false
    done(options, err)
  end
  p.after(targets.TIMEOUT_MS, function()
    finish(nil, "timeout")
  end)
  p.request_server(handoff.TARGETS, handoff.encode(handoff.TARGETS, {}), function(reply)
    local result = handoff.decode(handoff.TARGETS_RESULT, reply)
    if not result or not json.is_array(result.options) then
      finish(nil, "failed")
      return
    end
    finish(plain(result.options))
  end)
end

---Asks the server what is near, for a script: `callback(options)`, each
---`{ name, label, type, id, distance }`, nearest first, or
---`callback(nil, err)`. The callback runs under `pcall`, so one that throws
---is logged rather than lost.
---@param callback any The callback: a function, or a FiveM function reference.
---@return boolean? ok True once asked.
---@return string? err `invalid` for a callback that cannot be called.
function targets.nearby(callback)
  if not rpf.callable(callback) then
    return nil, "invalid"
  end
  targets.nearby_client(function(options, err)
    local ok, failure = pcall(callback, options, err)
    if not ok and platform then
      platform.log("error", "rpf: the callback for nearby targets failed: " .. tostring(failure))
    end
  end)
  return true
end

---What the server last answered about each entity, by ref then rule name:
---whether it offers the rule there, and when it said so.
---@type table<any, table<string, { offered: boolean, at: number }>>
local offers = {}
---How many entities `offers` holds answers for.
local offer_refs = 0
---Rules waiting to be asked about, by ref, gathered over one turn of the
---clock so a resource asking about every option of an entity in one frame
---is one request.
---@type table<any, table<string, true>>
local to_ask = {}
---The request waiting for its answer about each ref, by ref: a token its
---answer must still find here to be kept, so one `recheck` or a change of
---rules has made stale is dropped, and does not hold up a new one.
---@type table<any, table>
local offers_asking = {}
---How many `rpf:target_offers` requests are waiting.
local offers_waiting = 0
---Whether a turn of the clock is due to send what is gathered.
local offers_due = false
---Forgets every answer about entities: the rules changed, or the client is
---keeping too many. An answer still on its way is dropped when it comes.
local function forget_offers()
  offers, offer_refs, offers_asking = {}, 0, {}
end

---Asks the server about one entity's gathered rules, if a request may go now.
---@param p rpf.ClientPlatform The platform.
---@param ref any The entity's ref.
---@param names table<string, true> The rules.
---@return boolean sent False when it may not go now.
local function ask_offers(p, ref, names)
  if offers_asking[ref] or offers_waiting >= targets.MAX_OFFERS_ASKING then
    return false
  end
  local list = {}
  for name in pairs(names) do
    list[#list + 1] = name
  end
  table.sort(list)
  while #list > targets.MAX_OFFER_NAMES do
    list[#list] = nil
  end
  local token = {}
  local finished = false
  offers_asking[ref], offers_waiting = token, offers_waiting + 1
  ---Keeps the answer, once: nil (no answer, or a timeout) keeps nothing, so
  ---the next look asks again.
  ---@param said table<string, true>? The names offered.
  local function finish(said)
    if finished then
      return
    end
    finished = true
    offers_waiting = offers_waiting - 1
    if offers_asking[ref] ~= token then
      return -- made stale since it was asked
    end
    offers_asking[ref] = nil
    if not said then
      return
    end
    if not offers[ref] then
      if offer_refs >= targets.MAX_OFFER_REFS then
        forget_offers()
      end
      offers[ref], offer_refs = {}, offer_refs + 1
    end
    local now = p.now()
    for _, name in ipairs(list) do
      offers[ref][name] = { offered = said[name] == true, at = now }
    end
  end
  p.after(targets.TIMEOUT_MS, function()
    finish(nil)
  end)
  p.request_server(
    handoff.TARGET_OFFERS,
    handoff.encode(handoff.TARGET_OFFERS, { ref = ref, names = json.array(list) }),
    function(reply)
      local result = handoff.decode(handoff.TARGET_OFFERS_RESULT, reply)
      if not result or not json.is_array(result.names) then
        finish(nil)
        return
      end
      local said = {}
      for _, name in ipairs(result.names) do
        if type(name) == "string" then
          said[name] = true
        end
      end
      finish(said)
    end
  )
  return true
end

---Sends what was gathered, as far as the requests waiting allow; the rest
---waits for the next look.
local function flush_offers()
  offers_due = false
  local p = platform --[[@as rpf.ClientPlatform?]]
  if not p or not p.request_server then
    to_ask = {}
    return
  end
  local gathered = to_ask
  to_ask = {}
  for ref, names in pairs(gathered) do
    -- What cannot go now is dropped: the resource asks again on its next frame.
    ask_offers(p, ref, names)
  end
end

---Whether the server offers a rule on an entity, as it last answered, for
---a target resource's `canInteract`, which asks on every frame. An answer
---older than `OFFER_TTL_MS`, or none, asks the server again (gathered over
---one turn of the clock, one request per entity), and meanwhile the last
---answer stands: false until the server has said yes. The server checks a
---request again whatever this said.
---@param name string The rule's interaction name.
---@param ref any The entity's ref, as a request names it (a FiveM network id).
---@return boolean offered True once the server said so.
function targets.offered(name, ref)
  local p = platform --[[@as rpf.ClientPlatform?]]
  if not p or ref == nil then
    return false
  end
  local known = offers[ref] and offers[ref][name]
  if not known or p.now() - known.at >= targets.OFFER_TTL_MS then
    to_ask[ref] = to_ask[ref] or {}
    to_ask[ref][name] = true
    if not offers_due then
      offers_due = true
      p.after(0, flush_offers)
    end
  end
  return known ~= nil and known.offered
end

---Forgets what the server said about an entity, so the next look asks
---again: a request was just made there, which may have started a cooldown
---or changed what is offered. An answer still on its way was given before,
---so it is dropped when it comes.
---@param ref any The entity's ref.
function targets.recheck(ref)
  if offers[ref] then
    offers[ref], offer_refs = nil, offer_refs - 1
  end
  offers_asking[ref] = nil
end

---Tells the player something went wrong, through the client's UI if it has
---one: what the minimal UI and a target resource's option do with a refusal.
---@param text string The notice.
function targets.tell(text)
  local ui = rpf.ui and rpf.ui.members()
  if ui and ui.notify then
    ui.notify({ text = text, kind = "error" }, function() end)
  end
end

---The minimal interaction UI: asks the server what is near, shows it as a
---menu, and sends the option picked, telling the player if it is refused.
---An adapter binds it to a key; a target resource is the other way in.
function targets.open()
  targets.nearby_client(function(options, err)
    if not options then
      if err ~= "busy" then
        targets.tell("Could not look around (" .. tostring(err) .. ").")
      end
      return
    end
    if #options == 0 then
      targets.tell("Nothing to do here.")
      return
    end
    local items = {}
    for i, option in ipairs(options) do
      items[i] = { label = option.label, value = i }
    end
    local ui = rpf.ui.members()
    local shown, why = ui.menu({ title = "Interact", options = items }, function(picked)
      local option = type(picked) == "number" and options[picked]
      if not option then
        return
      end
      local sent, refused = rpf.interactions.request(option.name, { target = { id = option.id } }, function(ok, reason)
        if not ok then
          targets.tell(tostring(reason))
        end
      end)
      if not sent then
        -- Never sent (`too_many` waiting), so the callback never runs.
        targets.tell(tostring(refused))
      end
    end)
    if not shown and why ~= "busy" then
      targets.tell("Could not show what is near (" .. tostring(why) .. ").")
    end
  end)
end

---Keeps the platform, and listens for the server's rules. Called by
---`rpf.start_client`.
---@param p rpf.ClientPlatform The platform.
function targets.start_client(p)
  platform = p
  known = {}
  forget_offers()
  to_ask, offers_asking, offers_waiting, offers_due = {}, {}, 0, false
  p.on_server(handoff.TARGET_RULES, function(payload)
    local decoded = handoff.decode(handoff.TARGET_RULES, payload)
    if not decoded or not json.is_array(decoded.rules) then
      p.log("warn", "rpf: could not read the server's interaction targets")
      return
    end
    known = decoded.rules
    forget_offers()
    rpf.events.emit("interactions.targets", targets.rules())
  end)
end

rpf.targets = targets
return targets
