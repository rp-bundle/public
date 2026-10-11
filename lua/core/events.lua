---The event bus every framework module talks through.
---
---Modules never call each other to say something happened. A module owns its
---own state and changes it through its own functions, and announces each
---change here; anything that cares listens. That keeps the load order a list
---rather than a graph, lets a server owner's script hear exactly what the
---core's own modules hear, and means a new module is a new listener rather
---than an edit to the module it reacts to.
---
---Two rules make the bus safe to share with scripts the core did not write:
---
--- - **A handler that throws is logged and skipped.** The handlers after it
---   still run, so one broken script cannot stop a player's join.
--- - **Core event names are reserved.** Anything under `players.`, `config.`,
---   `auth.`, `records.`, `characters.`, `jobs.`, `staff.`, `addons.`, `domains.`, `interactions.` or `rpf.` is emitted only by the core, so a
---   script cannot forge a lifecycle event that other scripts would believe,
---   and an addon's namespace is its own (`emit_public`).
---@class rpf.events
---@field RESERVED string[] Name prefixes only the core may emit. The public `emit` refuses them.
---@field MAX_DEPTH integer How deeply emits may nest (a handler emitting, whose handler emits, …) before the bus refuses, so a cycle is an error in the log rather than a stack overflow.
local events = {}

local rpf = rpf

---The values `t[i]` to `t[n]` as separate results. Written out because
---`unpack` is `table.unpack` on 5.4 and a global on 5.1.
---@param t any[] The values.
---@param n integer How many there are, counting nils.
---@param i integer? Where to start, 1 by default.
---@return any first The value at `i`, if there is one.
---@return any ... The rest.
local function spread(t, n, i)
  i = i or 1
  if i > n then
    return
  end
  return t[i], spread(t, n, i + 1)
end

events.RESERVED = {
  "players.",
  "config.",
  "auth.",
  "records.",
  "characters.",
  "jobs.",
  "staff.",
  "addons.",
  "domains.",
  "interactions.",
  "rpf.",
}
events.MAX_DEPTH = 32

---One registered handler.
---@class rpf.events.Entry
---@field fn function The handler.
---@field once boolean Whether it is removed before its first call.
---@field removed boolean? Set by `off`, so an emit already under way skips it.

---Handlers by event name, in registration order.
---@type table<string, rpf.events.Entry[]>
local handlers = {}

---Where errors go. Unset until a side starts; lines logged before then are
---kept in `early` and written out when it is set.
---@type fun(level: string, message: string)?
local sink = nil

---Lines logged before a platform was bound, oldest first, at most 32.
---@type { level: string, message: string }[]
local early = {}

---How many emits are running, one inside another.
local depth = 0

---Logs through the bound platform, or keeps the line until there is one.
---@param level "debug"|"info"|"warn"|"error" How much it matters.
---@param message string The line, without the `rpf: ` prefix.
local function log(level, message)
  if sink then
    sink(level, "rpf: " .. message)
  elseif #early < 32 then
    early[#early + 1] = { level = level, message = "rpf: " .. message }
  end
end

---Checks an event name, throwing at the caller's call site if it is not a
---non-empty string.
---@param name any The name.
---@param level integer The stack level to blame.
local function check_name(name, level)
  if type(name) ~= "string" or name == "" then
    error("rpf: an event name must be a non-empty string", level)
  end
end

---Takes one registration out of a name's list, leaving any other
---registration of the same function alone.
---@param name string The event name.
---@param target rpf.events.Entry The registration.
local function remove_entry(name, target)
  target.removed = true
  local kept = {}
  for _, entry in ipairs(handlers[name] or {}) do
    if entry ~= target then
      kept[#kept + 1] = entry
    end
  end
  handlers[name] = #kept > 0 and kept or nil
end

---Sends the bus's log lines to a platform's log from now on, and writes out
---any kept from before. Called by `rpf.start_server` and `rpf.start_client`.
---@param logger fun(level: string, message: string) The platform's `log`.
function events.bind(logger)
  sink = logger
  for _, line in ipairs(early) do
    logger(line.level, line.message)
  end
  early = {}
end

---Whether a name is one only the core may emit.
---@param name string The event name.
---@return boolean reserved True for `players.…`, `config.…`, `auth.…`, `records.…`, `characters.…`, `jobs.…`, `staff.…` and `rpf.…`.
function events.reserved(name)
  for _, prefix in ipairs(events.RESERVED) do
    if name:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

---Registers a handler, called on every later emit of the name, after the
---handlers registered before it.
---@param name string The event name, namespaced like `players.active`.
---@param handler function Called with whatever the emit passes.
---@return function handler The same handler, for `off`.
function events.on(name, handler)
  check_name(name, 3)
  if type(handler) ~= "function" then
    error("rpf: events.on needs a function", 2)
  end
  local list = handlers[name]
  if not list then
    list = {}
    handlers[name] = list
  end
  list[#list + 1] = { fn = handler, once = false }
  return handler
end

---Registers a handler for the next emit of the name only. It is removed
---before it runs, so an emit from inside it does not call it again.
---@param name string The event name.
---@param handler function Called once.
---@return function handler The same handler, so it can be removed with `off` before it fires.
function events.once(name, handler)
  local fn = events.on(name, handler)
  local list = handlers[name]
  list[#list].once = true
  return fn
end

---Removes every registration of a handler for a name. The function itself is
---the key, so a script can only remove handlers it holds. An emit already
---under way skips a handler removed during it.
---@param name string The event name.
---@param handler function The handler `on` or `once` was given.
---@return boolean removed Whether anything was registered.
function events.off(name, handler)
  check_name(name, 3)
  local list = handlers[name]
  if not list then
    return false
  end
  local kept, removed = {}, false
  for _, entry in ipairs(list) do
    if entry.fn == handler then
      entry.removed = true
      removed = true
    else
      kept[#kept + 1] = entry
    end
  end
  handlers[name] = #kept > 0 and kept or nil
  return removed
end

---Whether a table is plain data the bus copies for each handler: one with no
---metatable, or only a JSON array/object mark. Anything else (`json.null`,
---a frozen view, an engine handle wrapper) is passed by reference, because
---a copy of it would not be the thing it stands for.
---@param value table The table.
---@return boolean plain Whether copying it is safe.
local function is_plain(value)
  if getmetatable(value) == nil then
    return true
  end
  local json = rpf.json
  return json ~= nil and (json.is_array(value) or json.is_object(value))
end

---A deep copy of the plain data in a value. Non-tables, and tables that are
---not plain (see `is_plain`), are returned as they are; shared and cyclic
---tables stay shared and cyclic in the copy.
---@param value any The value.
---@param seen table<table, table> Tables already copied, so a cycle ends.
---@return any copy The copy.
local function isolate(value, seen)
  if type(value) ~= "table" or not is_plain(value) then
    return value
  end
  local done = seen[value]
  if done then
    return done
  end
  local out = {}
  seen[value] = out
  for k, v in pairs(value) do
    out[isolate(k, seen)] = isolate(v, seen)
  end
  return setmetatable(out, getmetatable(value))
end

---Calls every handler for a name, in registration order, with the given
---arguments. A handler that throws is logged, and the rest still run.
---
---Every handler but the last gets its own deep copy of the plain tables in
---the arguments, so one that changes its payload cannot change what the
---next reads (a mutation is not an error, so `pcall` would not catch it).
---The last gets the emitter's own, which costs nothing when one module
---listens, as with most events. Functions, engine handles and any table
---with a metatable of its own are passed by reference.
---
---The list is taken when the emit starts, so a handler added during it waits
---for the next one, and one removed during it is skipped.
---@param name string The event name.
---@param ... any Passed to every handler; plain tables are copied for all but the last (above).
---@return integer failed How many handlers threw.
function events.emit(name, ...)
  check_name(name, 3)
  local list = handlers[name]
  if not list then
    return 0
  end
  if depth >= events.MAX_DEPTH then
    log("error", "not emitting " .. name .. ": emits nested " .. events.MAX_DEPTH .. " deep, which is a cycle")
    return 0
  end
  local snapshot = {}
  for i, entry in ipairs(list) do
    snapshot[i] = entry
  end
  depth = depth + 1
  local failed = 0
  local argc, args = select("#", ...), { ... }
  for i, entry in ipairs(snapshot) do
    if not entry.removed then
      if entry.once then
        remove_entry(name, entry)
      end
      local ok, err
      if i < #snapshot and argc > 0 then
        local seen, copy = {}, {}
        for n = 1, argc do
          copy[n] = isolate(args[n], seen)
        end
        ok, err = pcall(entry.fn, spread(copy, argc))
      else
        ok, err = pcall(entry.fn, ...)
      end
      if not ok then
        failed = failed + 1
        log("error", "a handler for " .. name .. " failed: " .. tostring(err))
      end
    end
  end
  depth = depth - 1
  return failed
end

---The emit scripts get through the public API: the same, except that it
---never throws, and refuses what a script may not announce. A core name is
---reserved, so only the core can announce a lifecycle event; a name under
---a loaded addon's namespace is refused to code known to be someone else's
---(`rpf.addons.may_use`, J3), so one addon cannot forge another's events.
---@param name any The event name.
---@param ... any Passed to every handler.
---@return integer? failed How many handlers threw, or nil if refused.
---@return string? err `invalid` for a name that is not a non-empty string, `reserved` for a core name, `forbidden` for another addon's namespace.
function events.emit_public(name, ...)
  if type(name) ~= "string" or name == "" then
    return nil, "invalid"
  end
  if events.reserved(name) then
    return nil, "reserved"
  end
  if rpf.addons and not rpf.addons.may_use(name) then
    return nil, "forbidden"
  end
  return events.emit(name, ...)
end

---How many handlers are registered for a name, for tests and diagnostics.
---@param name string The event name.
---@return integer count The count.
function events.count(name)
  local list = handlers[name]
  return list and #list or 0
end

rpf.events = events
return events
