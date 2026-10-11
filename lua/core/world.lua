---The game world, as far as the core reaches it (J3, J4): through
---capabilities the adapter declares (`platform.capabilities`), never through
---an engine branch here.
---
---A capability is a function the adapter supplies, or `false` where it does
---not support it, so an addon asks `capabilities()` before it offers a
---player something that needs one, and a call to one that is missing is
---refused `unsupported` rather than failing. Positions are plain
---`{ x, y, z }` tables, which is how an addon stores one (a `vector3`
---field); a model or an entity is engine data the core passes through and
---never reads.
---
---**Entities are named by a ref**: whatever number the engine names a
---networked entity by to every machine (a network id on FiveM, an entity
---index on Gmod). It is what a client names a target by, and what the core
---keeps for an entity it placed, so `entity(ref)` both inspects what a
---client named and tells whether a placement is still there.
---
---**Placements (J4, J6).** The core places the records of world-backed
---types whose kind is `ped` or `object` (`docs/architecture/addons.md`,
---"World definitions"), one entity per record, through the adapter's
---`spawn` and `despawn`, and keeps them placed:
---
---- **What is wanted** is every visible record of every such type of every
---  addon running here, in namespace, type and id order, at most
---  `MAX_PLACED`: a `config` type's from the config alone, and a `live`
---  type's while this server holds it (J6), since only then is it this
---  server's to show. A record staff hid, moved or deleted, an addon that
---  stopped, and a config the portal replaced change it, and so does the
---  stored config the core restores at start, so a game server that cannot
---  reach the portal still places what it last had. A held live record
---  that arrives, changes, goes or is let go changes it too
---  (`records.held`, `records.created`, `records.changed`,
---  `records.deleted`, `records.released`, `records.lost`), reconciled once
---  for a burst of them (`soon`).
---- **Reconciling** despawns what is no longer wanted or has changed, then
---  spawns what is wanted and not placed. A spawn answers through a
---  callback, at once or later (FiveM makes an entity asynchronously); a
---  placement waiting for its answer counts as placed, and one taken away
---  meanwhile has its entity removed as it arrives. A record is placed once: the
---  core keys what it placed by record id and spawns only a record with no
---  entity, so a reconnect, a config pushed twice or a reload never doubles
---  one. It runs on every `config.changed` and `addons.state`, and soon
---  after a held live record changes.
---- **Checking.** Every `CHECK_MS` the core asks the adapter whether each
---  entity is still there and still the one it placed (`entity(ref)`, whose
---  `placement` names the record), and places again one that is not: an
---  entity another script deleted, or one the engine lost. A spawn that
---  failed is tried again then too, and logged once until it succeeds.
---- **Stopping.** `clear()` despawns everything, for the adapter to call
---  as its resource stops; an adapter also removes, as it starts, any
---  entity a previous run placed and could not remove (a crash), from a
---  record of its own that no client can write, never from a tag.
---
---A live record is placed only while held here: one let go is despawned,
---and placed again whenever this server holds it next.
---
---**Maps (#369).** The adapter names the map this process runs
---(`platform.map`: `game.GetMap()` on Gmod, the `rpf_map` convar on FiveM),
---which the core reports in `Hello` and keeps until it stops: a Gmod map
---change restarts the Lua state, and FiveM reads the convar as the resource
---starts, so a new map is a new process that places from scratch. A type's
---`world` may name a `map` field; a record whose map is another one is
---neither placed nor targetable, and one whose map is null, like every
---record of a type with no map field, is on every map. The config carries
---every map's records, so a server that cannot reach the portal still
---places the right ones for the map it starts on.
---@class rpf.world
---@field CAPABILITIES string[] Every capability an adapter declares, in order.
---@field KINDS table<string, true> The world kinds the core places an entity for.
---@field MAX_PLACED integer The most entities the core keeps placed on one server: past it, the rest are left out and logged once, so a large type cannot exhaust the engine's entity pool.
---@field CHECK_MS integer How often the core checks that what it placed is still there.
---@field DEFAULT_MAP string The map a server reports when its adapter names one that is no map's name, so it still connects.
local world = {}

local rpf = rpf
local json = rpf.json

world.CAPABILITIES = { "position", "bucket", "model", "entity", "spawn", "despawn" }
world.KINDS = { ped = true, object = true }
world.MAX_PLACED = 1024
world.CHECK_MS = 10000
world.DEFAULT_MAP = "default"

---@type rpf.Capabilities?
local declared = nil
---@type rpf.ServerPlatform?
local platform = nil
---The map this process runs, from `start` on.
---@type string?
local current_map = nil

---What the core has placed, or is placing, by record id.
---@class rpf.world.Placed
---@field type string The record's type.
---@field key string What it was placed as (`key_of`), so a change places it again.
---@field ref any? The entity's ref; nil while the adapter is still making it.
---@field gone boolean? True once it was taken away while still being made, so the entity, when it comes, is removed at once.
---@field answered boolean? True once the adapter answered the spawn.

---@type table<string, rpf.world.Placed>
local placed = {}
---Records whose spawn failed, by id, with what they were spawned as, so the
---failure is logged once until it succeeds or the record changes.
---@type table<string, string>
local failed = {}
---Records left out for a bucket no engine has, by id, so each is logged
---once.
---@type table<string, true>
local refused = {}
---Whether the core stopped placing (`clear`), so nothing is placed again.
local stopped = false
---Whether the over-the-limit and cannot-place notices have been logged.
local warned = { limit = false, unsupported = false }

---Logs through the platform, once it is known.
---@param level string The level.
---@param message string The line.
local function log(level, message)
  if platform then
    platform.log(level, message)
  end
end

---A capability's function, if the adapter supports it.
---@param name string The capability.
---@return function? fn The function.
local function capability(name)
  local fn = declared and declared[name]
  if type(fn) ~= "function" then
    return nil
  end
  return fn
end

---Which capabilities this engine supports.
---@return table<string, boolean> supported By name: true where the adapter supports it.
function world.capabilities()
  local out = {}
  for _, name in ipairs(world.CAPABILITIES) do
    out[name] = capability(name) ~= nil
  end
  return out
end

---Whether a value is a finite number.
---@param n any The value.
---@return boolean finite True if it is.
local function finite(n)
  return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

---Whether a value is a whole number a bucket or a ref can be: finite,
---integral, and within ±2^31.
---@param n any The value.
---@return boolean whole True if it is.
local function whole(n)
  return finite(n) and n == math.floor(n) and n >= -2147483648 and n < 2147483648
end

---A plain `{ x, y, z }` copy of a position, or nil for anything else.
---@param at any The value.
---@return { x: number, y: number, z: number }? position The copy.
local function position_of(at)
  if type(at) ~= "table" or not finite(at.x) or not finite(at.y) or not finite(at.z) then
    return nil
  end
  return { x = at.x, y = at.y, z = at.z }
end

---Converts a distance in metres to the engine's units, by the scale the
---adapter declares (`units_per_metre`): the one place an engine's scale
---enters the core, so an addon (and a rule's `distance` or a zone's
---radius) is written once, in metres, for every engine.
---@param metres any The distance, in metres. A negative one is an offset.
---@return number? units The same distance in the engine's units.
---@return string? err `invalid` for anything but a finite number, or a result the engine's units cannot hold; `unsupported` before the core has started.
function world.units(metres)
  if not platform then
    return nil, "unsupported"
  end
  if not finite(metres) then
    return nil, "invalid"
  end
  local units = metres * platform.units_per_metre
  if not finite(units) then
    return nil, "invalid"
  end
  return units
end

---Converts a distance in the engine's units to metres: the inverse of
---`units`, for a distance the core measured (a target's `distance`).
---@param units any The distance, in the engine's units.
---@return number? metres The same distance in metres.
---@return string? err `invalid` for anything but a finite number; `unsupported` before the core has started.
function world.metres(units)
  if not platform then
    return nil, "unsupported"
  end
  if not finite(units) then
    return nil, "invalid"
  end
  return units / platform.units_per_metre
end

---The map this server runs, as it reported it in `Hello`: what decides
---which world records are placed and targetable here.
---@return string? map The map's name.
---@return string? err `unsupported` before the core has started.
function world.map()
  if not current_map then
    return nil, "unsupported"
  end
  return current_map
end

---Whether a world record is on the map this server runs: its type names no
---map field, its map is null (every map), or it is this one.
---@param where table The type's `world`.
---@param fields table The record's fields.
---@return boolean here True if it is.
function world.on_map(where, fields)
  local name = where.map
  if type(name) ~= "string" then
    return true
  end
  local map = fields[name]
  if map == nil or rawequal(map, json.null) then
    return true
  end
  return current_map ~= nil and map == current_map
end

---Calls an adapter's capability under `pcall`, logging a throw.
---@param name string The capability.
---@param fn function It.
---@param ... any Its arguments.
---@return boolean ok False if it threw.
---@return any a Its first result.
---@return any b Its second.
local function call(name, fn, ...)
  local ok, a, b = pcall(fn, ...)
  if not ok then
    log("error", "rpf: the platform's " .. name .. " failed: " .. tostring(a))
    return false, nil, nil
  end
  return true, a, b
end

---Whether a handle is a player logged in here.
---@param handle any The engine's handle.
---@return boolean known True if they are.
local function logged_in(handle)
  local player = rpf.players.get(handle)
  return player ~= nil and player.player_id ~= nil and player.state ~= "dropping"
end

---A logged-in player's position.
---@param handle any The engine's handle.
---@return { x: number, y: number, z: number }? position A plain copy.
---@return string? err `unsupported` where the adapter has no `position`, `not_found` for a player not logged in here or with no position (not spawned).
function world.position(handle)
  local fn = capability("position")
  if not fn then
    return nil, "unsupported"
  end
  if not logged_in(handle) then
    return nil, "not_found"
  end
  local ok, at = call("position", fn, handle)
  local copy = ok and position_of(at) or nil
  if not copy then
    return nil, "not_found"
  end
  return copy
end

---A logged-in player's routing bucket: the world they are in, where an
---engine has more than one (FiveM's routing buckets). On an engine without
---them every player is in bucket 0, the one world there is, which is what a
---record with no bucket field is in too.
---@param handle any The engine's handle.
---@return integer? bucket The bucket.
---@return string? err `not_found` for a player not logged in here.
function world.bucket(handle)
  if not logged_in(handle) then
    return nil, "not_found"
  end
  local fn = capability("bucket")
  if not fn then
    return 0
  end
  local ok, bucket = call("bucket", fn, handle)
  if not ok or not whole(bucket) then
    return nil, "not_found"
  end
  return bucket
end

---The engine's id for a model name, as `entity` reports a model: so a
---target rule written with a name can be compared with an entity.
---@param name any The model's name.
---@return any? id The engine's id for it, or nil.
---@return string? err `unsupported` or `invalid`.
function world.model(name)
  local fn = capability("model")
  if not fn then
    return nil, "unsupported"
  end
  if type(name) ~= "string" or name == "" or #name > 256 then
    return nil, "invalid"
  end
  local ok, id = call("model", fn, name)
  if not ok or (type(id) ~= "number" and type(id) ~= "string") then
    return nil, "invalid"
  end
  return id
end

---A networked entity, by the ref a client named it by: hostile input, so a
---ref that is not a whole number is refused before the adapter sees it.
---`placement` says which record it is, only when the core placed it: the
---adapter names it from what it placed, never from a tag a client can
---write, and it must be a record the core placed as exactly that entity.
---@param ref any The ref.
---@return { position: { x: number, y: number, z: number }, model: any, bucket: integer, placement: { type: string, id: string }? }? entity A plain copy.
---@return string? err `unsupported` where the adapter has no `entity`, `not_found` for a ref that names nothing (or nothing it can say where it is).
function world.entity(ref)
  local fn = capability("entity")
  if not fn then
    return nil, "unsupported"
  end
  if not whole(ref) then
    return nil, "not_found"
  end
  local ok, info = call("entity", fn, ref)
  if not ok or type(info) ~= "table" then
    return nil, "not_found"
  end
  local at = position_of(info.position)
  if not at then
    return nil, "not_found"
  end
  local out = {
    position = at,
    model = (type(info.model) == "number" or type(info.model) == "string") and info.model or nil,
    bucket = whole(info.bucket) and info.bucket or 0,
  }
  local id = info.placement
  local entry = type(id) == "string" and placed[id] or nil
  if entry and entry.ref == ref then
    out.placement = { type = entry.type, id = id }
  end
  return out
end

---The entity the core placed for a record, if it has.
---@param type_name any The record's type.
---@param id any The record's id.
---@return any? ref The entity's ref.
function world.placed(type_name, id)
  local entry = type(id) == "string" and placed[id] or nil
  if not entry or entry.type ~= type_name then
    return nil
  end
  return entry.ref
end

-- Placements -----------------------------------------------------------------

---A copy of a value with no JSON marks and no `json.null`: what an adapter
---is handed.
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

---A model as a stable string, for `key_of`: a JSON object's entries sorted.
---@param model any The model.
---@return string text Its text.
local function model_key(model)
  if type(model) ~= "table" then
    return tostring(model)
  end
  local keys = {}
  for key in pairs(model) do
    keys[#keys + 1] = tostring(key)
  end
  table.sort(keys)
  local parts = {}
  for i, key in ipairs(keys) do
    parts[i] = key .. "=" .. model_key(model[key])
  end
  return "{" .. table.concat(parts, ";") .. "}"
end

---What an adapter is asked to place.
---@class rpf.world.Spawn
---@field id string The record's id, which the adapter tags the entity with.
---@field type string The record's type.
---@field kind string `ped` or `object`.
---@field position { x: number, y: number, z: number } Where.
---@field heading number Which way it faces, in degrees.
---@field bucket integer Its routing bucket.
---@field model any The model field's value, unread: a string, or a table of one model per engine.

---What a placement is, so a change to any part places it again.
---@param spec rpf.world.Spawn The placement.
---@return string key Its key.
local function key_of(spec)
  return string.format(
    "%s|%.17g|%.17g|%.17g|%.17g|%d|%s",
    spec.kind,
    spec.position.x,
    spec.position.y,
    spec.position.z,
    spec.heading,
    spec.bucket,
    model_key(spec.model)
  )
end

---A record's placement, or nil if it is not placed: hidden, on another
---map, or with no position or model.
---@param type_name string Its type.
---@param where table The type's `world`.
---@param record table The record, as the config carries it or `rpf.data.list` copies it.
---@return rpf.world.Spawn? spec The placement.
local function spec_of(type_name, where, record)
  local fields = type(record.fields) == "table" and record.fields or {}
  if where.visible and fields[where.visible] == false then
    return nil
  end
  if not world.on_map(where, fields) then
    return nil
  end
  local at = position_of(fields[where.position])
  local model = plain(fields[where.model])
  if not at or model == nil then
    return nil
  end
  local heading = where.heading and fields[where.heading]
  -- No bucket is bucket 0; a bucket no engine has (negative, or past a
  -- 32-bit routing bucket) is not the public world, so the record is left
  -- out rather than put there.
  local bucket = where.bucket and fields[where.bucket]
  if bucket == nil or rawequal(bucket, json.null) then
    bucket = 0
  elseif not whole(bucket) or bucket < 0 then
    if refused[record.id] == nil then
      refused[record.id] = true
      log("warn", "rpf: could not place " .. type_name .. " " .. tostring(record.id) .. ": its bucket " .. tostring(bucket) .. " is none an engine has")
    end
    return nil
  end
  return {
    id = record.id,
    type = type_name,
    kind = where.kind,
    position = at,
    heading = finite(heading) and heading or 0,
    bucket = bucket,
    model = model,
  }
end

---What should be placed now: by id, and the ids in order.
---@return table<string, rpf.world.Spawn> wanted The placements.
---@return string[] order Their ids, in namespace, type and id order.
local function wanted()
  local out, order = {}, {}
  for _, namespace in ipairs(rpf.addons.active()) do
    for _, type_name in ipairs(rpf.addons.type_names(namespace)) do
      local def = rpf.addons.definition(type_name)
      local where = type(def) == "table" and def.world or nil
      local live = type(def) == "table" and def.authority == "live"
      if type(where) == "table" and world.KINDS[where.kind] then
        -- A config type's records from the config; a live type's, the ones
        -- held here (J6), as copies with every default filled in.
        local found = live and (rpf.data.list(type_name, {}) or {}) or rpf.addons.config_records(type_name)
        for _, record in ipairs(found) do
          local spec = type(record.id) == "string" and out[record.id] == nil and spec_of(type_name, where, record) or nil
          if spec then
            out[spec.id] = spec
            order[#order + 1] = spec.id
          end
        end
      end
    end
  end
  return out, order
end

---Despawns a placement and forgets it.
---@param id string The record's id.
local function take_away(id)
  local entry = placed[id]
  placed[id] = nil
  if not entry then
    return
  end
  if entry.ref == nil then
    -- Still being made: its entity is removed when it arrives (`made`).
    entry.gone = true
    return
  end
  -- Only if the ref still names this record's entity: one deleted behind
  -- the core's back may have handed its ref to another placement.
  local despawn, entity = capability("despawn"), capability("entity")
  if not despawn then
    return
  end
  if entity then
    local ok, info = call("entity", entity, entry.ref)
    if not ok or type(info) ~= "table" or info.placement ~= id then
      return
    end
  end
  call("despawn", despawn, entry.ref)
end

---Takes the adapter's answer to a spawn: the entity's ref, or why not. It
---may come at once or later (FiveM makes an entity asynchronously), and is
---taken once. A placement taken away meanwhile has its entity removed.
---@param id string The record's id.
---@param entry rpf.world.Placed The placement it was asked for.
---@param ref any The ref, or nil.
---@param why any Why not, when nil.
local function made(id, entry, ref, why)
  if entry.ref ~= nil or entry.answered then
    return
  end
  entry.answered = true
  local despawn = capability("despawn")
  if entry.gone or stopped or placed[id] ~= entry then
    if whole(ref) and despawn then
      call("despawn", despawn, ref)
    end
    return
  end
  if whole(ref) then
    entry.ref = ref
    failed[id] = nil
    return
  end
  placed[id] = nil
  if failed[id] ~= entry.key then
    failed[id] = entry.key
    log("warn", "rpf: could not place " .. entry.type .. " " .. id .. ": " .. tostring(why or "failed"))
  end
end

---Whether a reconcile is waiting to run, so a burst of record events
---reconciles once.
local due = false

---Reconciles as soon as the platform runs a timer, once however often it
---is asked meanwhile: what a change to a held live record calls.
function world.soon()
  if due or stopped or not platform then
    return
  end
  due = true
  platform.after(0, function()
    due = false
    world.reconcile()
  end)
end

---Brings what is placed in line with what is wanted: despawns what is no
---longer wanted or changed, then spawns what is missing: the first
---`MAX_PLACED` in order, whatever was placed before.
function world.reconcile()
  if stopped or not platform then
    return
  end
  local want, order = wanted()
  local spawn, despawn = capability("spawn"), capability("despawn")
  if not spawn or not despawn then
    if #order > 0 and not warned.unsupported then
      warned.unsupported = true
      log("info", "rpf: this engine's adapter places no entities; " .. #order .. " ped and object records are left unplaced")
    end
    return
  end
  -- The limit is on what is wanted, in order, before anything is kept: a
  -- record earlier in the order displaces a later one already placed, so
  -- what is placed depends on the config alone, never on its history.
  if #order > world.MAX_PLACED then
    if not warned.limit then
      warned.limit = true
      log("warn", "rpf: more than " .. world.MAX_PLACED .. " records want an entity placed; the rest are left out")
    end
    for i = #order, world.MAX_PLACED + 1, -1 do
      want[order[i]] = nil
      order[i] = nil
    end
  end
  for id, entry in pairs(placed) do
    local spec = want[id]
    if not spec or key_of(spec) ~= entry.key then
      take_away(id)
    end
  end
  for _, id in ipairs(order) do
    if not placed[id] then
      local spec = want[id]
      ---@type rpf.world.Placed
      local entry = { type = spec.type, key = key_of(spec) }
      placed[id] = entry
      local ok = call("spawn", spawn, plain(spec), function(ref, why)
        made(id, entry, ref, why)
      end)
      if not ok then
        made(id, entry, nil, "failed")
      end
    end
  end
  for id in pairs(failed) do
    if not want[id] then
      failed[id] = nil
    end
  end
end

---Forgets every placement whose entity is gone or is no longer the one the
---core placed, so the next reconcile places it again.
local function check()
  local entity = capability("entity")
  if not entity then
    return
  end
  local ids = {}
  for id in pairs(placed) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local entry = placed[id]
    local ok, info = true, nil
    if entry.ref ~= nil then
      ok, info = call("entity", entity, entry.ref)
    end
    if entry.ref ~= nil and (not ok or type(info) ~= "table" or info.placement ~= id) then
      placed[id] = nil
      log("info", "rpf: the entity placed for " .. entry.type .. " " .. id .. " is gone; placing it again")
    end
  end
  world.reconcile()
end

---Despawns every entity the core placed, and places nothing more. The
---adapter calls it as its resource stops, so nothing the core placed
---outlives it.
function world.clear()
  stopped = true
  local ids = {}
  for id in pairs(placed) do
    ids[#ids + 1] = id
  end
  for _, id in ipairs(ids) do
    take_away(id)
  end
end

---Reads the adapter's capabilities and map, and starts placing. A
---capability that is neither a function nor `false` is logged and counts as
---unsupported, so a typo is one line at start rather than a nil call later;
---a map that is no map's name is logged and reported as `DEFAULT_MAP`, so
---the server still connects rather than have its `Hello` refused. Called by
---`rpf.start_server`, before the stored config is restored, whose
---`config.changed` places what it holds.
---@param p rpf.ServerPlatform The platform.
function world.start(p)
  platform = p
  declared = p.capabilities
  placed, failed, refused, stopped, due = {}, {}, {}, false, false
  warned = { limit = false, unsupported = false }
  if rpf.manifest.is_map_name(p.map) then
    current_map = p.map
  else
    current_map = world.DEFAULT_MAP
    p.log("error", "rpf: the platform's map " .. tostring(p.map) .. " is no map's name (1 to 64 bytes of printable ASCII with no space); reporting " .. world.DEFAULT_MAP)
  end
  for _, name in ipairs(world.CAPABILITIES) do
    local value = declared[name]
    if value ~= false and type(value) ~= "function" then
      p.log("warn", "rpf: the platform declares capability " .. name .. " as neither a function nor false; it is unsupported")
    end
  end
  rpf.events.on("config.changed", function()
    world.reconcile()
  end)
  rpf.events.on("addons.state", function()
    world.reconcile()
  end)
  -- A held live record that arrived, changed, went or was let go changes
  -- what is placed (J6). Many can change at once (a claim's page, a batch,
  -- a timer moving every plant), so they are reconciled together, once, as
  -- soon as the platform runs a timer.
  for _, name in ipairs({
    "records.held",
    "records.created",
    "records.changed",
    "records.deleted",
    "records.released",
    "records.lost",
  }) do
    rpf.events.on(name, world.soon)
  end
  ---Checks the placements, then waits `CHECK_MS` to check again, until
  ---the core stops placing.
  local function tick()
    if stopped then
      return
    end
    check()
    p.after(world.CHECK_MS, tick)
  end
  p.after(world.CHECK_MS, tick)
end

rpf.world = world
return world
