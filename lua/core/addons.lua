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
---@class rpf.addons
---@field MAX_MANIFESTS_PER_DECLARE integer Manifests one `declare_addons` frame carries: `limits::MAX_MANIFESTS_PER_DECLARE`.
---@field API_MAJORS table<integer, true> The addon API majors this core serves.
---@field STATES string[] Every state an addon can be in.
local addons = {}

local rpf = rpf
local json = rpf.json
local events = rpf.events

addons.MAX_MANIFESTS_PER_DECLARE = 8
addons.API_MAJORS = { [1] = true }
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
---@class rpf.addons.Handlers
---@field start fun()? Runs when the addon becomes active.
---@field stop fun(reason: string)? Runs when it stops being active, with why.
---@field state fun(state: string, reason: string?)? Runs on every change of state.

---One loaded addon.
---@class rpf.addons.Loaded
---@field manifest table Its manifest, as `rpf.manifest.check` returned it.
---@field handlers rpf.addons.Handlers What to run for it.
---@field state string Its state, one of `addons.STATES`.
---@field reason string? Why it is in that state, for the log and its handler.

---A state change, as `addons.state` emits it.
---@class rpf.addons.StateChange
---@field namespace string The addon.
---@field state string Its new state.
---@field reason string? Why.

---@type table<string, rpf.addons.Loaded>
local loaded = {}
---Namespaces a declaration the portal acknowledged has named, this run.
---@type table<string, true>
local declared = {}
---@type rpf.Client?
local connection = nil
---@type rpf.ServerPlatform?
local platform = nil

---Logs through the platform, when there is one.
---@param level string The level.
---@param message string The message.
local function log(level, message)
  if platform then
    platform.log(level, "rpf.addons: " .. message)
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

---Calls one of an addon's handlers under `pcall`, logging a throw.
---@param namespace string The addon.
---@param name string The handler's name.
---@param ... any Its arguments.
---@return boolean ok False if it threw.
local function call(namespace, name, ...)
  local handler = loaded[namespace] and loaded[namespace].handlers[name]
  if type(handler) ~= "function" then
    return true
  end
  local ok, err = pcall(handler, ...)
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
      elseif call(namespace, "start") then
        move(namespace, "active", nil)
      else
        move(namespace, "failed", "its start handler failed")
      end
    end
  end
end

---Registers an addon: checks its manifest, keeps it, recomputes its state,
---and declares it to the portal if the connection is up.
---
---Registering the same namespace again replaces the manifest and the
---handlers; an addon that was running is stopped first if the manifest
---changed. Nothing throws: a manifest the shared rules refuse, or one more
---addon than a server may install, is refused with why.
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
  local namespace = checked.namespace
  local previous = loaded[namespace]
  if not previous and #names() >= rpf.manifest.MAX_ADDONS_PER_SERVER then
    log("error", "an addon was refused: this server already has as many addons as it may")
    return nil, { error = "too_many", path = "" }
  end
  if previous and not addons.same(previous.manifest, checked) then
    -- Another release under the same name: what ran was the old one.
    if previous.state == "active" then
      call(namespace, "stop", "the addon registered another manifest")
    end
    previous.state = "not_installed"
    declared[namespace] = nil
  end
  loaded[namespace] = {
    manifest = checked,
    handlers = handlers or {},
    state = previous and previous.state or "not_installed",
    reason = previous and previous.reason,
  }
  addons.evaluate(true)
  if connection and connection.state == "ready" then
    addons.declare()
  end
  return true, nil
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
---addon is active: staff write them, and this server only reads them.
---@param type_name string The type's full name.
---@return table[] records Copies, each `{ id, type, revision, fields }`, in id order; empty if the addon is not active here.
function addons.config_records(type_name)
  local namespace = string.match(type_name, "^([^.]+)%.")
  if not namespace or addons.state(namespace) ~= "active" then
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
