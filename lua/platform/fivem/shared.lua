---The parts of the FiveM adapter both sides use (D2): the clock, timers,
---storage, logging and how the public API is exported.
---
---Loaded after the core on both sides, and first of the adapter's files. It
---keeps everything under `rpf.fivem`, so the adapter adds no global of its
---own, as the core adds none but `rpf`.
---
---Each function here closes over a FiveM native and nothing else, so the
---fake globals in `lua/platform/mock/fivem.lua` run it unmodified.
---@class rpf.fivem.shared
---@field PLACEMENT string The state bag key every entity the core places carries (J4): `{ id, type }`, the record it is. For a target resource's eyes only: the owning client can write it.
---@field PLACED_PEDS string The event the server sends clients the network ids of the peds it placed on (J4), which they make passive.
---@field PLACED_PEDS_REQUEST string The event a client asks for that list with as it starts.
local shared = {}

shared.PLACEMENT = "rpf_placement"
shared.PLACED_PEDS = "rpf:placed_peds"
shared.PLACED_PEDS_REQUEST = "rpf:placed_peds_request"

---The core, with the FiveM adapter's namespace added. Only the FiveM
---resource loads the adapter, so the core's own definition of `rpf` does not
---name it.
---@class rpf
---@field fivem rpf.fivem The FiveM adapter (D2).
local rpf = rpf

---The FiveM adapter's namespace: one table per adapter file.
---@class rpf.fivem
---@field shared rpf.fivem.shared Clock, timers, storage, logging and the API export.
---@field ox rpf.fivem.ox Everything taken from ox_lib (J10).
---@field ws rpf.fivem.ws The portal socket, through the `rpf-ws` shim.
---@field server rpf.fivem.server The game-server platform and its engine hooks.
---@field lock rpf.fivem.lock The server-side input lock, until a player is `active`.
---@field ui rpf.fivem.ui The login and character screens' logic, apart from NUI.
---@field client rpf.fivem.client The player-client platform and its engine hooks.
---@field target rpf.fivem.target The optional ox_target or qb-target adapter (J4).
rpf.fivem = rpf.fivem or {}

---How far, in milliseconds, the estimate may run ahead of the wall clock's
---current second before it is pulled back: the wall clock only has whole
---seconds, so anything inside that second is consistent with it.
local SECOND = 1000

---A wall clock with millisecond resolution, from one that only has whole
---seconds and a millisecond timer that only counts up.
---
---`now()` is the timer's progress since an anchor on the wall clock. While
---the two agree to within the wall clock's second it is exactly that, so
---intervals keep the timer's precision; when they part (the host's clock
---was set, or the two drifted) it is moved by the least that brings it back
---inside the second, so it never jumps more than the step. The core expects
---wall-clock time (`rpf.platform.Clock`), because it stamps `sent_at` and
---ages its outbox across restarts.
---@param seconds fun(): number The wall clock, in whole seconds since the Unix epoch.
---@param timer fun(): number A millisecond timer that only counts up.
---@return fun(): number now Milliseconds since the Unix epoch.
function shared.clock(seconds, timer)
  local anchor_wall, anchor_timer
  return function()
    local wall = seconds() * 1000
    local ticks = timer()
    if not anchor_wall then
      anchor_wall, anchor_timer = wall, ticks
    end
    local estimate = anchor_wall + (ticks - anchor_timer)
    if estimate < wall then
      estimate = wall
    elseif estimate >= wall + SECOND then
      estimate = wall + SECOND - 1
    end
    anchor_wall, anchor_timer = estimate, ticks
    return estimate
  end
end

---Runs a callback once, later, on a thread of its own, which is what the
---core's `after` promises: never inside the caller's stack.
---@param delay_ms number How long to wait. May be 0.
---@param callback fun() What to run.
function shared.after(delay_ms, callback)
  Citizen.SetTimeout(math.max(0, math.floor(delay_ms)), callback)
end

---Reads a value from this resource's key-value store.
---@param key string The key.
---@return string? value The value, or nil if none is stored.
function shared.kv_get(key)
  local value = GetResourceKvpString(key)
  if type(value) ~= "string" then
    return nil
  end
  return value
end

---Writes a value to this resource's key-value store, or deletes it. The
---synchronous setter, never the `NoSync` one: the core's outbox needs a
---write to be durable when `kv_set` returns (`rpf.platform.Storage`).
---@param key string The key.
---@param value string? The value, or nil to delete it.
function shared.kv_set(key, value)
  if value == nil then
    DeleteResourceKvp(key)
  else
    SetResourceKvp(key, value)
  end
end

---Builds the log function: one console line per call, with debug lines only
---when asked for, because the core logs every reconnect at debug.
---@param verbose boolean Whether debug lines are printed.
---@return fun(level: string, message: string) log The platform's `log`.
function shared.logger(verbose)
  return function(level, message)
    if level ~= "debug" or verbose then
      print("[rpf] " .. level .. ": " .. message)
    end
  end
end

---An API function as another resource calls it: the core is told which
---resource is calling (`GetInvokingResource`), so what an addon's resource
---sets up is its own, goes when the resource stops, and may not act under
---another addon's namespace (`rpf.addons.from`). The client has no addons,
---and calls straight through.
---@param fn function The API function.
---@return function wrapped The same call, naming its caller.
function shared.from_caller(fn)
  return function(...)
    if not rpf.addons then
      return fn(...)
    end
    return rpf.addons.from(GetInvokingResource(), fn, ...)
  end
end

---A plain copy of the public API, the shape an export can carry.
---
---`rpf.api` is read-only views, and FiveM serialises an export's result with
---msgpack, which copies tables raw and so would hand another resource empty
---tables. The member names come from `rpf.api_members`, which reads the
---tables behind the views, so the copy is whole on Lua 5.4 and LuaJIT alike.
---Functions in it cross as references, and calling one runs the closure in
---this resource's Lua state, where the core is, naming the resource that
---called it (`from_caller`).
---@param api rpf.Api The public API.
---@return table copy Plain tables, with the same members.
function shared.export_copy(api)
  local members = rpf.api_members()
  local copy = {}
  for _, name in ipairs(members[""]) do
    local value = api[name]
    local nested = members[name]
    if nested then
      local inner = {}
      for _, key in ipairs(nested) do
        local member = value[key]
        inner[key] = type(member) == "function" and shared.from_caller(member) or member
      end
      value = inner
    end
    copy[name] = value
  end
  return copy
end

---A handler another resource passed through an export, as a function.
---
---FiveM hands this resource another resource's function as a reference: a
---callable table carrying `__cfx_functionReference`, not a function, which
---`rpf.events` refuses.
---@param handler any What the other resource passed.
---@return any handler A function for a reference, or what was passed, which `rpf.events` checks itself.
function shared.callable(handler)
  if type(handler) ~= "table" then
    return handler
  end
  return function(...)
    return handler(...)
  end
end

---The exported `events`, which name a subscription by an id rather than by
---its function.
---
---A function does not keep its identity across FiveM's boundary: each time
---a resource passes one, FiveM makes a new reference to it, so `off` could
---never match the handler `on` was given. Through the export, `on` and
---`once` therefore return a subscription id, a string, and `off` takes it.
---An id is forgotten once its subscription is removed or a `once` has
---fired, so nothing here outlives what `rpf.events` holds.
---@param events rpf.api.Events The public API's events.
---@return table events Plain functions, for the export.
function shared.export_events(events)
  ---Each live subscription, by id: its handler as `rpf.events` holds it, and
  ---how to forget its ownership once the id goes.
  ---@type table<string, { registered: function, disown: fun() }>
  local subscriptions = {}
  local count = 0

  ---Forgets an id, and the core's record that its subscriber owns it.
  ---@param id string The id.
  local function drop(id)
    local subscription = subscriptions[id]
    subscriptions[id] = nil
    if subscription then
      subscription.disown()
    end
  end

  ---Registers a handler and names it.
  ---@param register fun(name: string, handler: function): function `events.on` or `events.once`.
  ---@param name string The event name.
  ---@param handler any What the other resource passed.
  ---@param one_shot boolean Whether the id goes once the handler has run.
  ---@return string? id The subscription's id, for `off`; nil if refused.
  ---@return string? err Why it was refused.
  local function subscribe(register, name, handler, one_shot)
    count = count + 1
    local id = "rpf-subscription-" .. count
    local call = shared.callable(handler)
    local registered = call
    if one_shot and type(call) == "function" then
      registered = function(...)
        drop(id)
        return call(...)
      end
    end
    local ok, err = register(name, registered)
    if not ok then
      return nil, err
    end
    -- The core takes the handler down when the addon or resource that
    -- subscribed stops; its id goes with it, or this table would keep the
    -- other resource's function reference for as long as `rpf` runs.
    local disown = function() end
    if rpf.addons then
      disown = rpf.addons.own(function()
        subscriptions[id] = nil
      end)
    end
    subscriptions[id] = { registered = registered, disown = disown }
    return id
  end

  return {
    on = shared.from_caller(function(name, handler)
      return subscribe(events.on, name, handler, false)
    end),
    once = shared.from_caller(function(name, handler)
      return subscribe(events.once, name, handler, true)
    end),
    off = shared.from_caller(function(name, id)
      local subscription = subscriptions[id]
      if not subscription or not events.off(name, subscription.registered) then
        return false
      end
      drop(id)
      return true
    end),
    emit = shared.from_caller(function(name, ...)
      return events.emit(name, ...)
    end),
  }
end

---Publishes the public API as this resource's `api` export, so another
---resource writes `local rpf = exports.rpf:api()`. Each resource has its own
---Lua state on FiveM, so an export is the only way to reach it, and nothing
---but `rpf.api` is exported.
---@param api rpf.Api The public API.
function shared.expose(api)
  local copy = shared.export_copy(api)
  copy.events = shared.export_events(api.events)
  exports("api", function()
    return copy
  end)
end

rpf.fivem.shared = shared
return shared
