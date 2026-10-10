---The addons loaded on this server, and whether each may run (J2).
---
---An addon's Lua registers its manifest here when it loads. The core checks
---it with the shared rules (`rpf.manifest`) and declares every loaded
---manifest to the portal after each `Welcome`, and again whenever one
---registers later (`declare_addons`). Declaring proposes; staff install, in
---the portal. An addon then runs only when the config snapshot's `addons`
---section has it installed and enabled with **exactly the manifest it
---registered**, compared value for value (the portal's hash is taken over
---the same content, and Lua has no SHA-256), written for an API major this
---core serves, and with every addon it requires running
---(`docs/architecture/addons.md`, "Install, upgrade, disable, remove").
---
---Each addon is in one state, recomputed whenever the config's `addons`
---section changes and whenever one registers:
---
--- - `active`: installed, enabled, matching, its requirements active. Its
---   `start` handler has run.
--- - `not_installed`: not in the config, and not yet declared.
--- - `pending`: declared, and not (yet) installed by staff.
--- - `mismatch`: installed with another manifest: the files on the server
---   and the portal disagree.
--- - `disabled`: installed, and disabled by staff.
--- - `api`: written for an API major this core does not serve.
--- - `requires`: an addon it requires is not active.
--- - `failed`: its `start` handler threw. It stays inactive until the
---   config or its registration changes.
---
---A move into or out of `active` runs the addon's `start` or `stop`
---handler; every move runs its `state` handler and emits `addons.state`.
---Every handler runs under `pcall`, so an addon cannot stop the core or
---another addon. Addons start in dependency order and stop in reverse.
---
---**Whose code is running (J3).** The registry keeps a context: the addon
---whose handler, timer or event handler the core is running, and the
---engine's name for the code that called the public API (`origin`: a FiveM
---resource, which the adapter names on every export call; nil on Gmod,
---where every addon shares one Lua state). Three things follow from it:
---
--- - **What an addon set up is taken down when it stops.** A timer, an event
---   subscription or an export made while an addon's code runs is owned by
---   it (`addons.own`) and removed when it stops, so an addon restarted by a
---   reload or a re-enable starts clean rather than twice. One made by a
---   resource's code outside any handler is owned by the resource, and goes
---   when the resource stops (`addons.unload_origin`).
--- - **An addon's namespace is its own.** Code known to be another addon's
---   cannot emit events or provide exports under it (`addons.may_use`).
--- - **Reloading is registering again.** A second registration of a
---   namespace stops the first (and whatever requires it), then starts the
---   new code, whether or not the manifest changed.
---@class rpf.addons
---@field MAX_MANIFESTS_PER_DECLARE integer Manifests one `declare_addons` frame carries: `limits::MAX_MANIFESTS_PER_DECLARE`.
---@field API integer The newest addon API major this core serves, which a new addon writes as its manifest's `api`.
---@field API_MIN integer The oldest addon API major this core still serves (`docs/compatibility.md`).
---@field API_MAJORS table<integer, true> Every addon API major this core serves: `API_MIN` to `API`.
---@field HANDLERS table<string, true> The handlers an addon may pass with its manifest.
---@field STATES string[] Every state an addon can be in.
local addons = {}

local rpf = rpf
local json = rpf.json
local events = rpf.events

addons.MAX_MANIFESTS_PER_DECLARE = 8
addons.API = 1
addons.API_MIN = 1
addons.API_MAJORS = {}
for major = addons.API_MIN, addons.API do
  addons.API_MAJORS[major] = true
end
addons.HANDLERS = { start = true, stop = true, state = true }
addons.STATES = {
  "active",
  "not_installed",
  "pending",
  "mismatch",
  "disabled",
  "api",
  "requires",
  "failed",
}

---What an addon passes with its manifest: the code the core runs for it.
---Each is a function, or another FiveM resource's function reference.
---@class rpf.addons.Handlers
---@field start fun()? Runs when the addon becomes active.
---@field stop fun(reason: string)? Runs when it stops being active, with why.
---@field state fun(state: string, reason: string?)? Runs on every change of state.

---One loaded addon.
---@class rpf.addons.Loaded
---@field manifest table Its manifest, as `rpf.manifest.check` returned it.
---@field handlers rpf.addons.Handlers What to run for it.
---@field origin any The engine's name for the code that registered it (a FiveM resource), or nil.
---@field state string Its state, one of `addons.STATES`.
---@field reason string? Why it is in that state, for the log and its handler.
---@field starting boolean? True while its `start` handler runs, which may read its config records.
---@field leaving string? Set while it is being taken out, with why: a new registration takes its place, or its code is gone. It and its dependents stop in order first.
---@field gone boolean? Set when its code is gone (its resource stopped), so none of its handlers is called again.

---Whose code is running: what the registry knows of the caller.
---@class rpf.addons.Context
---@field namespace string? The addon whose handler, timer or event handler the core is running.
---@field origin any The engine's name for the calling code (a FiveM resource), or nil where the engine cannot say.

---One thing an addon or a resource set up, and how to take it down.
---@class rpf.addons.Owned
---@field namespace string? The addon that owns it, if one was running.
---@field origin any The resource that owns it, if known.
---@field cleanup fun() Takes it down.
---@field done boolean? Set once it has been taken down or disowned.

---A state change, as `addons.state` emits it.
---@class rpf.addons.StateChange
---@field namespace string The addon.
---@field state string Its new state.
---@field reason string? Why.

---@type table<string, rpf.addons.Loaded>
local loaded = {}
---The context each coroutine's code is running in, by the platform's name
---for the coroutine (`platform.thread`), or `MAIN` where it has none: an
---addon's handler that yields leaves its context on its own coroutine, not
---on whatever runs while it waits. Weak keys, so a finished coroutine's
---entry goes with it.
---@type table<any, rpf.addons.Context>
local contexts = setmetatable({}, { __mode = "k" })
---The key for code with no coroutine of its own to name.
local MAIN = {}
---What addons and resources set up, by entry, each with the order it was
---set up in; an entry is dropped as soon as it is taken down or disowned,
---so a long-running addon's finished timers are not kept.
---@type table<rpf.addons.Owned, integer>
local owned = {}
---How many things have been owned, for their order.
local owned_count = 0
---Each export an addon provides, by its full name.
---@type table<string, { fn: any, namespace: string }>
local provided = {}
---Log lines from before a platform was bound, at most 32, written out by
---`start`: a manifest refused while Gmod loads addons, before the core starts,
---must still reach the console.
---@type { level: string, message: string }[]
local early = {}
---Namespaces a declaration the portal acknowledged has named, this run.
---@type table<string, true>
local declared = {}
---@type rpf.Client?
local connection = nil
---@type rpf.ServerPlatform?
local platform = nil
---Applies a checked registration; defined beside `register`.
---@type fun(checked: table, handlers: rpf.addons.Handlers, origin: any): boolean?, table?
local apply

---Whether an evaluation is running, and whether another was asked for
---while it ran (a handler registering an addon), with a retry or not.
local evaluating = false
---@type boolean?
local pending_retry = nil
---Registrations made while an evaluation ran (by a handler), applied once
---it ends, in order, so none replaces an addon whose old registration is
---still being stopped or started.
---Origins unloaded while an evaluation ran (a resource stopped while a
---handler yielded) wait here too: forgetting an addon under an evaluation
---that will read it again would break that evaluation.
---@type { manifest: table?, handlers: rpf.addons.Handlers?, origin: any, unload: boolean? }[]
local deferred = {}

---Logs through the platform, or keeps the line until there is one.
---@param level string The level.
---@param message string The message.
local function log(level, message)
  if platform then
    platform.log(level, "rpf.addons: " .. message)
  elseif #early < 32 then
    early[#early + 1] = { level = level, message = "rpf.addons: " .. message }
  end
end

---Whether two decoded JSON values are equal, value for value: what the
---portal's hash would say of their canonical encodings. Numbers compare as
---numbers, so a whole double and an integer are one value, as on the portal.
---@param a any One value.
---@param b any The other.
---@return boolean same Whether they are the same.
function addons.same(a, b)
  if type(a) ~= type(b) then
    return false
  end
  if type(a) ~= "table" then
    return a == b
  end
  if a == json.null or b == json.null then
    return a == b
  end
  -- An empty array and an empty object encode differently, and so hash
  -- differently: two tables that both carry a mark must carry the same one.
  local marked = function(t)
    return json.is_array(t) or json.is_object(t)
  end
  if marked(a) and marked(b) and json.is_array(a) ~= json.is_array(b) then
    return false
  end
  for key, value in pairs(a) do
    if not addons.same(value, b[key]) then
      return false
    end
  end
  for key in pairs(b) do
    if a[key] == nil then
      return false
    end
  end
  return true
end

---Every loaded namespace, sorted, so declarations and starts are in one
---order on every run.
---@return string[] names The namespaces.
local function names()
  local out = {}
  for namespace in pairs(loaded) do
    out[#out + 1] = namespace
  end
  table.sort(out)
  return out
end

---The namespaces an addon requires.
---@param manifest table Its manifest.
---@return string[] required Sorted.
local function requirements(manifest)
  local out = {}
  if type(manifest.requires) == "table" then
    for namespace in pairs(manifest.requires) do
      out[#out + 1] = namespace
    end
  end
  table.sort(out)
  return out
end

---An addon's state before its requirements are looked at, and why.
---@param namespace string The addon.
---@param addon rpf.addons.Loaded It.
---@return string state The state.
---@return string? reason Why.
local function own_state(namespace, addon)
  local manifest = addon.manifest
  if addon.leaving then
    return "not_installed", addon.leaving
  end
  if not addons.API_MAJORS[manifest.api] then
    return "api", "it is written for addon API " .. tostring(manifest.api) .. ", which this core does not serve"
  end
  local installed = rpf.config.addon(namespace)
  if not installed then
    if declared[namespace] then
      return "pending", "the portal has it as a proposal, which staff have not installed"
    end
    return "not_installed", "the portal has not installed it"
  end
  if not addons.same(installed.manifest, manifest) then
    return "mismatch",
      "the portal installed release "
        .. tostring(installed.version)
        .. " ("
        .. tostring(installed.hash)
        .. "), and this server loaded release "
        .. tostring(manifest.version)
        .. " with another manifest"
  end
  if not installed.enabled then
    return "disabled", "staff disabled it in the portal"
  end
  return "active", nil
end

---The key of the coroutine running now.
---@return any key The platform's name for it, or `MAIN`.
local function thread_key()
  local key = platform and platform.thread()
  if key == nil then
    return MAIN
  end
  return key
end

---The context of the code running now.
---@return rpf.addons.Context? context The context, or nil for the core's own code.
local function current()
  return contexts[thread_key()]
end

---Sets the context of the coroutine running now.
---@param key any The coroutine's key, as `thread_key` gave it.
---@param ctx rpf.addons.Context? The context.
local function set(key, ctx)
  contexts[key] = ctx
end

---Puts the context back after a call, passing its results through.
---@param key any The coroutine's key.
---@param saved rpf.addons.Context? The context before the call.
---@param ... any `pcall`'s results.
---@return any ... The same results.
local function restore(key, saved, ...)
  set(key, saved)
  return ...
end

---Runs a function in a context, under `pcall`, and puts the context back
---whatever it does.
---@param ctx rpf.addons.Context? Whose code it is.
---@param fn any The function, or a FiveM function reference.
---@param ... any Its arguments.
---@return boolean ok False if it threw.
---@return any ... Its results, or the error.
function addons.run(ctx, fn, ...)
  local key = thread_key()
  local saved = contexts[key]
  set(key, ctx)
  return restore(key, saved, pcall(fn, ...))
end

---The context code is running in now.
---@return rpf.addons.Context? context A copy, or nil for the core's own code.
function addons.context()
  local context = current()
  if not context then
    return nil
  end
  return { namespace = context.namespace, origin = context.origin }
end

---Rethrows after the context is back, or passes results through.
---@param key any The coroutine's key.
---@param saved rpf.addons.Context? The context before the call.
---@param ok boolean `pcall`'s first result.
---@param ... any The rest.
---@return any ... The results.
local function finish(key, saved, ok, ...)
  set(key, saved)
  if not ok then
    error((...), 0)
  end
  return ...
end

---Runs a call into the public API made by code from `origin`, the engine's
---name for it (a FiveM resource, which the adapter reads on every export
---call). Inside a handler the core runs for one of that origin's addons, the
---context already names the addon and is kept; otherwise the call runs as
---the origin's, naming its addon when it registered exactly one.
---@param origin any The caller's origin, or nil if the engine cannot say.
---@param fn function The API function.
---@param ... any Its arguments.
---@return any ... Its results. An error it throws is thrown again.
function addons.from(origin, fn, ...)
  local key = thread_key()
  local context = contexts[key]
  if origin == nil or (context and context.origin == origin) then
    return fn(...)
  end
  local sole = nil
  for namespace, addon in pairs(loaded) do
    if addon.origin == origin then
      if sole then
        sole = false
        break
      end
      sole = namespace
    end
  end
  set(key, { namespace = sole or nil, origin = origin })
  return finish(key, context, pcall(fn, ...))
end

---The namespaces the code now running is known to belong to: the addon
---whose handler runs, or every addon its origin registered. Nil when
---nothing is known (the core's own code, or a Gmod script outside any
---handler), which `may_use` lets through.
---@return table<string, true>? namespaces The set.
local function caller_namespaces()
  local context = current()
  if not context then
    return nil
  end
  if context.namespace then
    return { [context.namespace] = true }
  end
  if context.origin == nil then
    return nil
  end
  local out = {}
  for namespace, addon in pairs(loaded) do
    if addon.origin == context.origin then
      out[namespace] = true
    end
  end
  return out
end

---Whether the code now running may act under a name's namespace (emit an
---event, provide an export): yes, unless the namespace is a loaded addon's
---and the caller is known to be some other code. A Gmod script outside any
---handler is not known, and is let through: on Gmod every addon shares one
---Lua state, and the rule stops mistakes, not the server owner's own code.
---@param name string The name, `<namespace>.<rest>`.
---@return boolean allowed True if it may.
function addons.may_use(name)
  local namespace = string.match(name, "^([^.]+)%.")
  if not namespace or not loaded[namespace] then
    return true
  end
  local mine = caller_namespaces()
  return mine == nil or mine[namespace] == true
end

---Owns something the code now running set up, so it is taken down when its
---addon stops, or its resource goes. Something the core's own code set up,
---or a Gmod script's outside any handler, has no owner and is kept.
---@param cleanup fun() Takes it down. Called at most once.
---@return fun() disown Forgets it without taking it down, for something its maker took down itself.
function addons.own(cleanup)
  local context = current()
  if not context or (context.namespace == nil and context.origin == nil) then
    return function() end
  end
  ---@type rpf.addons.Owned
  local entry = { namespace = context.namespace, origin = context.origin, cleanup = cleanup }
  owned_count = owned_count + 1
  owned[entry] = owned_count
  return function()
    entry.done = true
    owned[entry] = nil
  end
end

---Takes down everything owned that `test` picks, oldest first, and forgets it.
---@param test fun(entry: rpf.addons.Owned): boolean Which.
local function take_down(test)
  local due = {}
  for entry in pairs(owned) do
    if test(entry) then
      due[#due + 1] = entry
    end
  end
  table.sort(due, function(a, b)
    return owned[a] < owned[b]
  end)
  for _, entry in ipairs(due) do
    owned[entry] = nil
  end
  for _, entry in ipairs(due) do
    entry.done = true
    local ok, err = pcall(entry.cleanup)
    if not ok then
      log("error", "could not take down something an addon set up: " .. tostring(err))
    end
  end
end

---How many things are owned now, for tests and diagnostics: a long-running
---addon's finished timers must not add up here.
---@return integer count The count.
function addons.owned_count()
  local count = 0
  for _ in pairs(owned) do
    count = count + 1
  end
  return count
end

---Calls one of an addon's handlers under `pcall`, in the addon's context,
---logging a throw. An addon whose code is gone has nothing to call.
---@param namespace string The addon.
---@param name string The handler's name.
---@param ... any Its arguments.
---@return boolean ok False if it threw.
local function call(namespace, name, ...)
  local addon = loaded[namespace]
  local handler = addon and not addon.gone and addon.handlers[name]
  if not rpf.callable(handler) then
    return true
  end
  local ok, err = addons.run({ namespace = namespace, origin = addon.origin }, handler, ...)
  if not ok then
    log("error", "the " .. name .. " handler of " .. namespace .. " failed: " .. tostring(err))
  end
  return ok
end

---Moves an addon to a state, running its handlers and announcing it, if it
---is not already there.
---@param namespace string The addon.
---@param state string The new state.
---@param reason string? Why.
local function move(namespace, state, reason)
  local addon = loaded[namespace]
  if addon.state == state and addon.reason == reason then
    return
  end
  if addon.state == "active" and state ~= "active" then
    call(namespace, "stop", reason or state)
    -- Whatever its code set up while it ran goes with it, after its own
    -- `stop` had the chance to take it down itself.
    take_down(function(entry)
      return entry.namespace == namespace
    end)
  end
  addon.state, addon.reason = state, reason
  if state ~= "active" then
    log("info", namespace .. " is " .. state .. (reason and (": " .. reason) or ""))
  end
  call(namespace, "state", state, reason)
  ---@type rpf.addons.StateChange
  local change = { namespace = namespace, state = state, reason = reason }
  events.emit("addons.state", change)
end

---Recomputes every loaded addon's state, stopping those that may no longer
---run (dependents first) and starting those that now may (requirements
---first). An addon whose `start` throws is `failed`, and so is not a
---requirement anyone else may start on; it is tried again only on a
---`retry`, which a config change and a registration are, and a
---declaration's acknowledgement is not.
---@param retry boolean? Whether a `failed` addon may be started again.
function addons.evaluate(retry)
  -- A handler that registers an addon asks for an evaluation while one is
  -- running. It is run after this one, never inside it, so no addon's
  -- `start` runs twice for one activation.
  if evaluating then
    pending_retry = pending_retry or retry or false
    return
  end
  evaluating = true
  local ok, err = pcall(addons.evaluate_once, retry)
  local rounds = 0
  while ok and (pending_retry ~= nil or #deferred > 0) and rounds <= 4 * rpf.manifest.MAX_ADDONS_PER_SERVER do
    rounds = rounds + 1
    if pending_retry ~= nil then
      local again = pending_retry
      pending_retry = nil
      ok, err = pcall(addons.evaluate_once, again)
    else
      -- Applied outside the evaluation, which runs its own.
      local registration = table.remove(deferred, 1)
      evaluating = false
      if registration.unload then
        ok, err = pcall(addons.unload_origin, registration.origin)
      else
        ok, err = pcall(apply, registration.manifest --[[@as table]], registration.handlers --[[@as rpf.addons.Handlers]], registration.origin)
      end
      evaluating = true
    end
  end
  evaluating, pending_retry, deferred = false, nil, {}
  if not ok then
    error(err, 0)
  end
end

---One evaluation pass: what `evaluate` runs, never re-entered.
---@param retry boolean? Whether a `failed` addon may be started again.
function addons.evaluate_once(retry)
  local order = names()
  local want = {}
  local reasons = {}
  for _, namespace in ipairs(order) do
    local addon = loaded[namespace]
    want[namespace], reasons[namespace] = own_state(namespace, addon)
    if want[namespace] == "active" and addon.state == "failed" and not retry then
      want[namespace], reasons[namespace] = "failed", addon.reason
    end
  end
  -- An addon may run only once everything it requires may; demote until
  -- nothing changes, which takes at most one pass per addon.
  local changed = true
  while changed do
    changed = false
    for _, namespace in ipairs(order) do
      if want[namespace] == "active" then
        for _, required in ipairs(requirements(loaded[namespace].manifest)) do
          if want[required] ~= "active" then
            want[namespace] = "requires"
            reasons[namespace] = "it requires " .. required .. ", which is not active here"
            changed = true
            break
          end
        end
      end
    end
  end

  -- Stop first, dependents before what they require: reverse dependency
  -- order is the reverse of the start order below.
  local starts = {}
  local placed = {}
  ---Appends an addon to the start order after what it requires. `depth`
  ---bounds the walk, so a cycle the portal refused can never loop.
  ---@param namespace string The addon.
  ---@param depth integer How deep the walk is.
  local function place(namespace, depth)
    if placed[namespace] or depth > #order then
      return
    end
    for _, required in ipairs(requirements(loaded[namespace].manifest)) do
      if loaded[required] then
        place(required, depth + 1)
      end
    end
    placed[namespace] = true
    starts[#starts + 1] = namespace
  end
  for _, namespace in ipairs(order) do
    place(namespace, 0)
  end
  for i = #starts, 1, -1 do
    local namespace = starts[i]
    if want[namespace] ~= "active" then
      move(namespace, want[namespace], reasons[namespace])
    end
  end
  for _, namespace in ipairs(starts) do
    if want[namespace] == "active" and loaded[namespace].state ~= "active" then
      -- A requirement that failed to start since this pass decided holds
      -- this one back.
      local blocked = nil
      for _, required in ipairs(requirements(loaded[namespace].manifest)) do
        if not loaded[required] or loaded[required].state ~= "active" then
          blocked = required
          break
        end
      end
      if blocked then
        move(namespace, "requires", "it requires " .. blocked .. ", which is not active here")
      else
        local addon = loaded[namespace]
        addon.starting = true
        local started = call(namespace, "start")
        addon.starting = nil
        if started then
          move(namespace, "active", nil)
        else
          -- What it set up before it threw goes, so the retry starts clean.
          take_down(function(entry)
            return entry.namespace == namespace
          end)
          move(namespace, "failed", "its start handler failed")
        end
      end
    end
  end
end

---Checks the handlers an addon passes: nil, or a table of `start`, `stop`
---and `state`, each callable (a FiveM function reference is). Anything else
---is refused, so a misspelt handler fails at registration rather than
---never running.
---@param handlers any What was passed.
---@return table? refusal `{ error = "handler", path = "handlers.<name>" }`, or `"handlers"` for something that is not a table; nil if they are fine.
local function check_handlers(handlers)
  if handlers == nil then
    return nil
  end
  if type(handlers) ~= "table" or rpf.callable(handlers) then
    return { error = "handlers", path = "handlers" }
  end
  for name, handler in pairs(handlers) do
    if not addons.HANDLERS[name] or not rpf.callable(handler) then
      return { error = "handler", path = "handlers." .. tostring(name) }
    end
  end
  return nil
end

---Registers an addon: checks its manifest and handlers, keeps them,
---recomputes its state, and declares it to the portal if the connection is
---up. The registration belongs to the calling code's origin (`addons.from`),
---so it goes when that code does.
---
---Registering the same namespace again is a reload: the old registration is
---stopped (after whatever requires it), whatever its code set up is taken
---down, and the new one starts if it may, whether or not the manifest
---changed. Nothing throws: a manifest the shared rules refuse, handlers
---that are not handlers, or one more addon than a server may install, is
---refused with why. A registration a handler makes while the core is
---starting or stopping addons is applied once that ends, so it never
---replaces an addon mid-change; one past the addon limit is then refused in
---the log.
---@param manifest table The manifest, as the addon wrote it.
---@param handlers rpf.addons.Handlers? What to run for it.
---@return boolean? ok True once registered.
---@return table? refusal `{ error = <rule>, path = <where> }` if refused.
function addons.register(manifest, handlers)
  local checked, refusal = rpf.manifest.check(manifest)
  if not checked then
    refusal = refusal or { error = "wrong_type", path = "" }
    log("error", "an addon's manifest was refused: " .. tostring(refusal.error) .. " at " .. tostring(refusal.path))
    return nil, refusal
  end
  refusal = check_handlers(handlers)
  if refusal then
    log("error", checked.namespace .. "'s handlers were refused: " .. refusal.error .. " at " .. refusal.path)
    return nil, refusal
  end
  local copy = {}
  for name, handler in pairs(handlers or {}) do
    copy[name] = handler
  end
  local context = current()
  local origin = context and context.origin
  if evaluating then
    deferred[#deferred + 1] = { manifest = checked, handlers = copy, origin = origin }
    return true, nil
  end
  return apply(checked, copy, origin)
end

---Forgets a stopped addon; defined beside `take_out`.
---@type fun(namespace: string)
local forget

---Takes an addon out: stops it and whatever requires it, in order, takes
---down what it set up, and forgets it. What stays is the portal's: its
---installation and records.
---@param namespace string The addon.
---@param reason string Why, for the log and its handlers.
---@param gone boolean? Whether its code is gone, so none of its handlers may be called.
local function take_out(namespace, reason, gone)
  local addon = loaded[namespace]
  addon.leaving, addon.gone = reason, gone or nil
  addons.evaluate(false)
  forget(namespace)
end

---Forgets an addon already stopped: its registration, its declaration, its
---exports, and whatever its code set up.
---@param namespace string The addon.
forget = function(namespace)
  loaded[namespace] = nil
  declared[namespace] = nil
  for name, export in pairs(provided) do
    if export.namespace == namespace then
      provided[name] = nil
    end
  end
  take_down(function(entry)
    return entry.namespace == namespace
  end)
end

---Applies a registration whose manifest and handlers were checked: what
---`register` does once no evaluation is running.
---@param checked table The manifest, as `rpf.manifest.check` returned it.
---@param handlers rpf.addons.Handlers What to run for it.
---@param origin any The engine's name for the code that registered it.
---@return boolean? ok True once registered.
---@return table? refusal `{ error = "too_many", path = "" }` past the addon limit.
apply = function(checked, handlers, origin)
  local namespace = checked.namespace
  local previous = loaded[namespace]
  if not previous and #names() >= rpf.manifest.MAX_ADDONS_PER_SERVER then
    log("error", "an addon was refused: this server already has as many addons as it may")
    return nil, { error = "too_many", path = "" }
  end
  local was_declared = declared[namespace]
  if previous then
    -- A reload, or another release under the same name: what ran was the
    -- old code, and it stops as any addon does, after whatever requires it.
    take_out(namespace, "the addon registered again")
    if addons.same(previous.manifest, checked) then
      declared[namespace] = was_declared
    end
  end
  loaded[namespace] = {
    manifest = checked,
    handlers = handlers,
    origin = origin,
    state = previous and previous.state or "not_installed",
    reason = previous and previous.reason,
  }
  addons.evaluate(true)
  if connection and connection.state == "ready" then
    addons.declare()
  end
  return true, nil
end

---Forgets every addon an origin registered, and takes down whatever that
---origin's code set up: its code is gone (on FiveM, its resource stopped).
---Its addons stop, in order, without their handlers being called, since
---there is no code left to call. The portal is told they are no longer
---loaded; their installations and records stay.
---@param origin any The origin, as the adapter names it.
function addons.unload_origin(origin)
  if origin == nil then
    return
  end
  if evaluating then
    -- Its code is gone now, so nothing of it is called again; it is
    -- forgotten once the evaluation that may still read it has ended.
    for _, addon in pairs(loaded) do
      if addon.origin == origin then
        addon.gone = true
      end
    end
    deferred[#deferred + 1] = { origin = origin, unload = true }
    return
  end
  local gone = {}
  for _, namespace in ipairs(names()) do
    if loaded[namespace].origin == origin then
      gone[#gone + 1] = namespace
    end
  end
  -- Every one is marked gone before anything stops, so stopping one that
  -- another of the same origin requires calls none of their handlers.
  for _, namespace in ipairs(gone) do
    log("info", namespace .. " is unloaded: its code stopped")
    loaded[namespace].leaving, loaded[namespace].gone = "its code stopped", true
  end
  addons.evaluate(false)
  for _, namespace in ipairs(gone) do
    forget(namespace)
  end
  take_down(function(entry)
    return entry.origin == origin
  end)
  if #gone > 0 then
    addons.evaluate(true)
    if connection and connection.state == "ready" then
      addons.declare()
    end
  end
end

---Provides an export other addons call by name, `<namespace>.<name>`, under
---an addon loaded here. The namespace must be the caller's own when the
---caller is known (`may_use`). One provided while the addon's code runs is
---taken down when it stops; providing a name again replaces it.
---@param name any The export's full name.
---@param fn any The function, or a FiveM function reference.
---@return boolean? ok True once provided.
---@return string? err `invalid` for a name that is not `<namespace>.<identifier>` or a value that cannot be called, `not_found` when no addon of that namespace is loaded, `forbidden` for another addon's namespace.
function addons.provide(name, fn)
  if type(name) ~= "string" or not rpf.callable(fn) then
    return nil, "invalid"
  end
  local namespace, rest = string.match(name, "^([a-z][a-z0-9_]*)%.([a-z][a-z0-9_]*)$")
  if not namespace or #rest > 32 then
    return nil, "invalid"
  end
  if not loaded[namespace] then
    return nil, "not_found"
  end
  if not addons.may_use(name) then
    return nil, "forbidden"
  end
  local export = { fn = fn, namespace = namespace }
  provided[name] = export
  addons.own(function()
    if provided[name] == export then
      provided[name] = nil
    end
  end)
  return true
end

---Turns an export's `pcall` results into `call`'s: logged and `failed` on a
---throw, passed through otherwise.
---@param name string The export.
---@param ok boolean Whether it ran.
---@param ... any Its results, or the error.
---@return boolean ok The same.
---@return any ... Its results, or `"failed"`.
local function answer(name, ok, ...)
  if ok then
    return true, ...
  end
  log("error", "the export " .. name .. " failed: " .. tostring((...)))
  return false, "failed"
end

---Calls another addon's export, in that addon's context, under `pcall`.
---It answers only while the addon that provided it is active.
---@param name any The export's full name.
---@param ... any Its arguments, as they are.
---@return boolean ok True if it ran.
---@return any ... Its results; or, when `ok` is false, why: `not_found` (nothing provides that name), `inactive` (its addon is not active here) or `failed` (it threw, which is logged).
function addons.call(name, ...)
  local export = type(name) == "string" and provided[name] or nil
  if not export then
    return false, "not_found"
  end
  local addon = loaded[export.namespace]
  if not addon or addon.state ~= "active" then
    return false, "inactive"
  end
  return answer(name, addons.run({ namespace = export.namespace, origin = addon.origin }, export.fn, ...))
end

---An addon's state, and why it is in it.
---@param namespace string The addon.
---@return string? state Its state, or nil if no addon of that name is loaded.
---@return string? reason Why.
function addons.state(namespace)
  local addon = loaded[namespace]
  if not addon then
    return nil, nil
  end
  return addon.state, addon.reason
end

---A type's definition as installed here: the config's own record of it
---when the installation keeps one apart from its manifest (a type kept for
---its records, or one ahead after a rollback), else the manifest's.
---@param type_name string The type's full name, `<namespace>.<name>`.
---@return table? definition A copy, or nil if no installed addon has the type.
function addons.definition(type_name)
  local namespace, name = string.match(type_name, "^([^.]+)%.(.+)$")
  local installed = namespace and rpf.config.addon(namespace)
  if not installed then
    return nil
  end
  if type(installed.types) == "table" and installed.types[type_name] ~= nil then
    return installed.types[type_name]
  end
  local declared_types = type(installed.manifest) == "table" and installed.manifest.types
  if type(declared_types) == "table" then
    return declared_types[name]
  end
  return nil
end

---The records of a `config` type, as the config carries them, while their
---addon is active or its `start` handler runs: staff write them, and this
---server only reads them.
---@param type_name string The type's full name.
---@return table[] records Copies, each `{ id, type, revision, fields }`, in id order; empty if the addon is not active here.
function addons.config_records(type_name)
  local namespace = string.match(type_name, "^([^.]+)%.")
  local addon = namespace and loaded[namespace]
  if not addon or (addon.state ~= "active" and not addon.starting) then
    return {}
  end
  local installed = rpf.config.addon(namespace)
  local out = {}
  for _, record in ipairs(installed and installed.records or {}) do
    if record.type == type_name then
      out[#out + 1] = record
    end
  end
  return out
end

---Declares every loaded addon to the portal: the whole `loaded` list in
---every frame, and the manifests split across frames of at most
---`MAX_MANIFESTS_PER_DECLARE`. One frame with no addons tells the portal
---none are loaded. A frame the outbox cannot take is logged; the next
---`Welcome` declares again.
function addons.declare()
  if not connection then
    return
  end
  local order = names()
  local chunks = { {} }
  for _, namespace in ipairs(order) do
    local chunk = chunks[#chunks]
    if #chunk >= addons.MAX_MANIFESTS_PER_DECLARE then
      chunk = {}
      chunks[#chunks + 1] = chunk
    end
    chunk[#chunk + 1] = loaded[namespace].manifest
  end
  for _, chunk in ipairs(chunks) do
    local listed = {}
    for i, namespace in ipairs(order) do
      listed[i] = namespace
    end
    local names_in = {}
    for _, manifest in ipairs(chunk) do
      names_in[#names_in + 1] = manifest.namespace
    end
    local _, err = connection:send(
      "declare_addons",
      { loaded = json.array(listed), manifests = json.array(chunk) },
      function(reply, failure)
        if reply and reply.type == "ack" then
          for _, namespace in ipairs(names_in) do
            declared[namespace] = true
          end
          addons.evaluate()
        elseif reply and reply.type == "rejected" then
          log("warn", "the portal refused this server's addons (" .. tostring(reply.reason) .. ")")
        elseif failure then
          log("warn", "could not declare this server's addons (" .. tostring(failure) .. ")")
        end
      end
    )
    if err then
      log("warn", "could not declare this server's addons (" .. err .. ")")
    end
  end
end

---Wires the registry up. Called by `rpf.start_server`, before the stored
---config is restored, so the restore's `config.changed` is heard. Addons
---that registered before the core started keep their registration.
---@param p rpf.ServerPlatform The platform.
---@param client rpf.Client The connection to the portal.
function addons.start(p, client)
  platform = p
  connection = client
  declared = {}
  for _, line in ipairs(early) do
    p.log(line.level, line.message)
  end
  early = {}
  local ready = client.on_ready
  ---Runs at every `Welcome`: whatever was set before, then the declaration.
  ---@param c rpf.Client The connection, now ready.
  client.on_ready = function(c)
    if ready then
      ready(c)
    end
    addons.declare()
  end
  events.on("config.changed", function(change)
    for _, section in ipairs(change.sections) do
      if section == "addons" then
        addons.evaluate(true)
        return
      end
    end
  end)
end

rpf.addons = addons
return addons
