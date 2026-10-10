---Bridges to existing RP frameworks (K2, decided in #75): the contract a
---bridge implements, its registration, the lifecycle it reports, and the
---calls the facade (`rpf.facade`) routes to it where the server's framework
---owns the domains (`docs/architecture/framework-integration.md`).
---
---A bridge is a Lua package beside the core (`lua/bridges/<framework>/`, a
---resource of its own on FiveM), which reaches the core only through
---`rpf.api.bridge`: it registers one table, the **contract**, and reports
---what its framework does through the lifecycle calls. It never writes
---RPF's state, and RPF never writes the framework's: on a companion server
---the framework is the one writer of characters, money, items and jobs.
---
--- - **Registration.** `register` checks the table whole and refuses it, with
---   one log line, unless its `contract.major` is this core's, its
---   `provides` names domains and no other, and every call it `supports`
---   has its function. It is then offered to `rpf.domains`, which accepts it
---   only if `provides` is exactly the set of domains the fixed profile marks
---   external (K1). At most one bridge is registered.
--- - **Activation.** Once the profile is fixed (the first `Welcome`) and the
---   bridge fits it, the bridge is active: its `start` runs, and every
---   logged-in player moves on to `character_select`, which is the bridge's
---   signal to show its framework's own character selection. On a native
---   profile it stays inactive, and if its framework is running anyway the
---   log says so at `error`, naming the `domains` setting: two economies.
--- - **The lifecycle.** The bridge reports `character_loaded(player,
---   { key, name })`, `character_unloaded(player)`, `unavailable(reason)`
---   and `available()`. A loaded character moves its player to `active`, an
---   unloaded one back to `character_select`; RPF's login gate stays RPF's
---   and comes first. The key is the framework's own (a `citizenid`), kept in
---   memory here and never sent to the portal or written to the log.
--- - **Routing.** The facade sends each call of an external domain here
---   (`reach`): never to RPF's own module. A call the bridge does not
---   `support` is `unsupported` without reaching it; while it says its
---   framework is unavailable, every call is `unavailable` without reaching
---   it.
--- - **Results.** What a bridge answers is checked (`read`, `command`). A
---   read that throws, or answers what the contract does not allow, is
---   `unavailable`, and logged. A command that throws, or answers anything
---   but `true` or one of the refusals, is `unknown`: the framework may have
---   changed something before it failed, and only the bridge can prove it
---   did not, by answering `refused` or `unavailable` itself.
--- - **Withdrawal.** On a platform that names the calling code (FiveM), a
---   bridge's resource stopping withdraws it: its players go back to
---   `character_select`, and the gate holds new ones at `registered` until
---   it registers again.
---
---**Versioning.** `CONTRACT.major` changes on any breaking change, a new
---call every bridge must implement included; `CONTRACT.minor` when an
---optional call is added (`CALLS`). A bridge of another major is refused. A
---bridge written for a later minor may list calls this core does not know:
---they are left out, since nothing here routes to them.
---@class rpf.bridge
---@field CONTRACT { major: integer, minor: integer } The contract this core speaks: 1.0.
---@field CALLS table<string, string[]> The optional calls a bridge may implement, by domain, as of `CONTRACT`. `characters.current` is not among them: the core answers it from the lifecycle.
---@field MAX_KEY_BYTES integer The longest framework key a bridge may report.
---@field MAX_NAME_BYTES integer The longest character name, bridge name, version or reason a bridge may give.
local bridge = {}

local rpf = rpf

bridge.CONTRACT = { major = 1, minor = 0 }
bridge.CALLS = {
  money = { "accounts", "balance", "debit", "credit" },
  inventory = { "count", "give", "take" },
  jobs = { "current" },
}
bridge.MAX_KEY_BYTES = 128
bridge.MAX_NAME_BYTES = 128

---The most units one give or take moves, as the native path: a `u32`.
local MAX_UNITS = 4294967295

---The most accounts a bridge may list.
local MAX_ACCOUNTS = 32

---The refusal statuses a bridge's command may answer besides `true`.
local STATUSES = { refused = true, unavailable = true, unknown = true }

---What a read may answer besides its value.
local READ_ERRORS = { not_found = true, no_character = true, unavailable = true }

---The registered bridge, once one is.
---@class rpf.bridge.Registered
---@field name string Its name.
---@field version string Its own version.
---@field contract { major: integer, minor: integer } The contract it was written for.
---@field provides string[] The domains its framework owns.
---@field supports table<string, function> The calls it implements, by `<domain>.<call>`.
---@field tested_with string[] The framework versions it was tested against.
---@field running function Whether its framework is running, and its version.
---@field start function? Runs when it becomes active, with the players already waiting at `character_select`.
---@field stop function? Runs when the core stops using it while its code still runs.
---@field origin any The code that registered it (a FiveM resource), or nil where the engine cannot say.

---@type rpf.bridge.Registered?
local registered = nil

---Whether the registered bridge is active: it fits the fixed profile and
---its `start` ran.
local active = false

---Whether the bridge is being withdrawn: its reports are refused from the
---first move withdrawal makes, since a bridge answering the moves' cue
---(`players.character_select`) at once would put a player back in play
---with no provider behind them.
local closing = false

---Why the bridge's framework is unavailable, while it says so.
---@type string?
local outage = nil

---The character each player has in play, as the bridge reported it, by
---the engine's handle.
---@type table<any, { key: string, name: string }>
local loaded = {}

---@type rpf.ServerPlatform?
local platform = nil

---Logs through the platform.
---@param level string The level.
---@param message string The line.
local function log(level, message)
  if platform then
    platform.log(level, "rpf.bridge: " .. message)
  end
end

---What a bridge or its framework threw, with every framework key the
---bridge reported taken out, so it may go to the log: a framework's error
---often names the character it was working on (qbx_core's carry the
---`citizenid`), and the key never leaves the game server's memory.
---@param err any What was thrown.
---@param characters table<any, { key: string }>? The characters whose keys to take out; those in play by default.
---@return string text The text, safe to log.
local function scrub(err, characters)
  local out = tostring(err)
  for _, character in pairs(characters or loaded) do
    -- Escaped, so a key is matched as written whatever it holds.
    out = out:gsub(character.key:gsub("%W", "%%%0"), "<key>")
  end
  return out
end

---Whether a value is a string of 1 to `max` bytes.
---@param value any The value.
---@param max integer The most bytes.
---@return boolean ok True if it is.
local function text(value, max)
  return type(value) == "string" and #value >= 1 and #value <= max
end

---Whether a value is a whole number from `min` to `max`.
---@param value any The value.
---@param min number The least.
---@param max number The most.
---@return boolean ok True if it is.
local function whole(value, min, max)
  return type(value) == "number" and value == math.floor(value) and value >= min and value <= max
end

---Whether a value is a list (a table whose keys are 1..n), so a bridge's
---`provides` or `supports` reads the same on every engine.
---@param value any The value.
---@return boolean list True if it is.
local function is_list(value)
  if type(value) ~= "table" then
    return false
  end
  local n = 0
  for _ in pairs(value) do
    n = n + 1
  end
  for i = 1, n do
    if value[i] == nil then
      return false
    end
  end
  return true
end

---Announces a change of the bridge's state, for scripts: `domains.bridge`.
---@param state "active"|"unavailable"|"available"|"withdrawn" The new state.
---@param reason string? Why, where there is one.
local function announce(state, reason)
  rpf.events.emit("domains.bridge", { name = registered and registered.name or nil, state = state, reason = reason })
end

---Whether code from an origin may speak for the registered bridge: only
---its own, where the engine names the calling code.
---@return boolean ok True if it may.
local function from_bridge()
  if not registered or registered.origin == nil then
    return true
  end
  local context = rpf.addons and rpf.addons.context()
  return context ~= nil and context.origin == registered.origin
end

-- Registration ---------------------------------------------------------------

---Checks a bridge's table whole.
---@param def any What the bridge passed.
---@return rpf.bridge.Registered? checked The bridge, or nil.
---@return string? err `invalid` or `contract`.
---@return string? field For `invalid`, what was wrong.
local function check(def)
  if type(def) ~= "table" then
    return nil, "invalid", "bridge"
  end
  if type(def.name) ~= "string" or not def.name:match("^[a-z][a-z0-9_]*$") or #def.name > 32 then
    return nil, "invalid", "name"
  end
  if not text(def.version, 32) then
    return nil, "invalid", "version"
  end
  local contract = def.contract
  if type(contract) ~= "table" or not whole(contract.major, 0, 1e6) or not whole(contract.minor, 0, 1e6) then
    return nil, "invalid", "contract"
  end
  if contract.major ~= bridge.CONTRACT.major then
    return nil, "contract", "contract"
  end
  if not is_list(def.provides) or #def.provides == 0 then
    return nil, "invalid", "provides"
  end
  local provides, seen = {}, {}
  for _, domain in ipairs(def.provides) do
    local known = false
    for _, name in ipairs(rpf.domains.NAMES) do
      known = known or name == domain
    end
    if not known or seen[domain] then
      return nil, "invalid", "provides"
    end
    seen[domain] = true
    provides[#provides + 1] = domain
  end
  if def.supports ~= nil and not is_list(def.supports) then
    return nil, "invalid", "supports"
  end
  local supports = {}
  for _, name in ipairs(def.supports or {}) do
    local domain, call = nil, nil
    if type(name) == "string" then
      domain, call = name:match("^([a-z]+)%.([a-z_]+)$")
    end
    local known = false
    for _, listed in ipairs(domain and bridge.CALLS[domain] or {}) do
      known = known or listed == call
    end
    if not known then
      if contract.minor <= bridge.CONTRACT.minor then
        return nil, "invalid", "supports." .. tostring(name)
      end
      -- A later minor's call: this core routes nothing to it.
    else
      local fns = def[domain]
      local fn = type(fns) == "table" and fns[call] or nil
      if not seen[domain] or not rpf.callable(fn) or supports[name] then
        return nil, "invalid", "supports." .. name
      end
      supports[name] = fn
    end
  end
  local tested = {}
  if def.tested_with ~= nil then
    if not is_list(def.tested_with) then
      return nil, "invalid", "tested_with"
    end
    for _, version in ipairs(def.tested_with) do
      if not text(version, 32) then
        return nil, "invalid", "tested_with"
      end
      tested[#tested + 1] = version
    end
  end
  if not rpf.callable(def.running) then
    return nil, "invalid", "running"
  end
  for _, hook in ipairs({ "start", "stop" }) do
    if def[hook] ~= nil and not rpf.callable(def[hook]) then
      return nil, "invalid", hook
    end
  end
  return {
    name = def.name,
    version = def.version,
    contract = { major = contract.major, minor = contract.minor },
    provides = provides,
    supports = supports,
    tested_with = tested,
    running = def.running,
    start = def.start,
    stop = def.stop,
  }
end

---Asks the bridge whether its framework is running, and which version.
---@param b rpf.bridge.Registered The bridge.
---@return boolean? running True if it is; nil if the bridge could not say.
---@return string? version Its version, if the bridge knows it.
local function framework(b)
  local ok, running, version = pcall(b.running)
  if not ok then
    log("error", "the " .. b.name .. " bridge could not say whether its framework is running: " .. scrub(running))
    return nil
  end
  return running == true, type(version) == "string" and version or nil
end

---Whether a framework version is one the bridge was tested against: equal
---to one it lists, or under it (`1.21` covers `1.21.3`).
---@param tested string[] The versions it lists.
---@param version string The framework's version.
---@return boolean ok True if it was.
local function was_tested(tested, version)
  for _, listed in ipairs(tested) do
    if version == listed or version:sub(1, #listed + 1) == listed .. "." then
      return true
    end
  end
  return false
end

---Moves a player on to `character_select`, where the bridge's framework
---shows its own character selection.
---@param handle any The engine's handle.
local function to_select(handle)
  local moved, err = rpf.players.advance(handle, "character_select")
  if not moved then
    log("warn", "could not move a player on to character_select: " .. tostring(err))
  end
end

---Stops using the bridge. Players with a character in play go back to
---`character_select`, since nothing reports their framework's state now,
---and the gate holds every new one at `registered`.
---@param why string Why, for the log.
---@param call_stop boolean Whether the bridge's code still runs, so its `stop` may.
local function withdraw(why, call_stop)
  local b = registered
  if not b then
    return
  end
  closing = true
  for _, player in ipairs(rpf.players.list()) do
    if player.state == "active" and active then
      rpf.players.advance(player.handle, "character_select")
    end
  end
  local were = loaded
  loaded = {}
  if call_stop and active and b.stop then
    local ok, err = pcall(b.stop, why)
    if not ok then
      log("error", "the " .. b.name .. " bridge's stop threw: " .. scrub(err, were))
    end
  end
  active, outage, closing = false, nil, false
  rpf.domains.withdraw_bridge()
  log("warn", "the " .. b.name .. " bridge is withdrawn (" .. why .. "); players stay at registered until a bridge registers again")
  announce("withdrawn", why)
  registered = nil
end

---Activates the registered bridge once the profile is fixed and it fits,
---or says why it stays inactive. Runs when it registers and when the
---profile is fixed, whichever is later.
local function evaluate()
  local b = registered
  local profile = rpf.domains.current()
  if not b or active or not profile then
    return
  end
  if rpf.domains.kind(profile) == "native" then
    if framework(b) then
      log(
        "error",
        "the "
          .. b.name
          .. " bridge's framework is running, and this server's `domains` setting is native, so RPF and the framework"
          .. " each keep an economy of their own. Set the server's profile to companion in the portal, or remove the framework"
      )
    end
    return
  end
  if rpf.domains.bridge() ~= b.name then
    -- The profile leaves other domains to the framework: the gate says
    -- why, once, and holds players at `registered`.
    rpf.domains.may_play()
    return
  end
  local running, version = framework(b)
  if running and version and #b.tested_with > 0 and not was_tested(b.tested_with, version) then
    log(
      "warn",
      "the " .. b.name .. " bridge was tested against " .. table.concat(b.tested_with, ", ") .. ", and its framework is " .. version
    )
  end
  active = true
  if b.start then
    -- The players already choosing (a bridge registering again after its
    -- resource restarted) saw their `players.character_select` before it
    -- was here: it shows them its selection now.
    local selecting = {}
    for _, player in ipairs(rpf.players.list()) do
      if player.state == "character_select" then
        selecting[#selecting + 1] = player.handle
      end
    end
    local ok, err = pcall(b.start, selecting)
    if not ok then
      log("error", "the " .. b.name .. " bridge's start threw: " .. scrub(err))
      withdraw("its start threw", true)
      return
    end
  end
  log("info", "the " .. b.name .. " bridge " .. b.version .. " is active")
  announce("active")
  for _, player in ipairs(rpf.players.list()) do
    if player.state == "registered" then
      to_select(player.handle)
    end
  end
end

---Registers the one bridge for this server. Checked whole, then offered to
---the profile (`rpf.domains.accept_bridge`), and active once the profile is
---fixed and fits. A refusal is logged, once, and changes nothing.
---@param def any The bridge's table (`rpf.BridgeDefinition`).
---@return boolean? ok True once registered (active or waiting for the profile).
---@return string? err `invalid`, `contract` (another major), `registered` (one is already) or `start` (it activated at once, and its `start` threw, which withdrew it).
---@return string? field For `invalid`, what was wrong.
function bridge.register(def)
  local name = type(def) == "table" and type(def.name) == "string" and def.name or "unnamed"
  if registered then
    log("error", "the " .. name .. " bridge was refused: the " .. registered.name .. " bridge is registered already")
    return nil, "registered"
  end
  local checked, err, field = check(def)
  if not checked then
    if err == "contract" then
      log(
        "error",
        "the "
          .. name
          .. " bridge was refused: it was written for contract "
          .. tostring(def.contract.major)
          .. ", and this core speaks contract "
          .. bridge.CONTRACT.major
          .. "."
          .. bridge.CONTRACT.minor
      )
    else
      log("error", "the " .. name .. " bridge was refused: its " .. tostring(field) .. " is not one the contract allows")
    end
    return nil, err, field
  end
  local context = rpf.addons and rpf.addons.context()
  checked.origin = context and context.origin or nil
  local offered, why = rpf.domains.accept_bridge(checked.name, checked.provides)
  if not offered then
    log("error", "the " .. checked.name .. " bridge was refused: " .. tostring(why))
    return nil, "registered"
  end
  registered = checked
  evaluate()
  if registered ~= checked then
    -- Activated at once, and withdrawn: its `start` threw.
    return nil, "start"
  end
  return true
end

-- The lifecycle ---------------------------------------------------------------

---A player the bridge may report a character for: connected, logged in,
---not leaving.
---@param handle any The engine's handle.
---@return rpf.PlayerView? player The player.
---@return string? err `not_found` or `not_registered`.
local function reportable(handle)
  local player = rpf.players.get(handle)
  if not player or player.state == "dropping" then
    return nil, "not_found"
  end
  if not player.player_id then
    return nil, "not_registered"
  end
  return player
end

---The bridge reports that a player's framework character is loaded: their
---player moves to `active`, through `character_select`. A character
---reported again with the same key changes its name only; another key is a
---switch, which goes through `character_select` again.
---@param handle any The engine's handle.
---@param character any `{ key, name }`: the framework's key for it, opaque, and its name.
---@return boolean? ok True once the player is active with it.
---@return string? err `forbidden` (not the bridge's code), `inactive`, `unavailable` (the bridge said its framework is: the player stays where they are, since nothing could be asked of the character), `invalid`, `not_found`, `not_registered` (they have not logged in: the framework loaded a character past RPF's gate), `superseded` (the bridge reported another character while this one was moving the player, and that later one stands), or the move's refusal.
function bridge.character_loaded(handle, character)
  if not from_bridge() then
    return nil, "forbidden"
  end
  if not active or closing then
    return nil, "inactive"
  end
  if outage then
    -- In play, the player would be released (FiveM's lock) to a character
    -- every call about answers `unavailable`.
    return nil, "unavailable"
  end
  if
    type(character) ~= "table"
    or not text(character.key, bridge.MAX_KEY_BYTES)
    or not text(character.name, bridge.MAX_NAME_BYTES)
  then
    return nil, "invalid"
  end
  local player, err = reportable(handle)
  if not player then
    if err == "not_registered" then
      log("warn", "the framework loaded a character for a player who has not logged in to RPF: its login gate is not holding")
    end
    return nil, err
  end
  local current = loaded[handle]
  if player.state == "active" and current and current.key == character.key then
    current.name = character.name
    return true
  end
  if player.state == "active" then
    loaded[handle] = nil
    rpf.players.advance(handle, "character_select")
  elseif player.state == "registered" then
    to_select(handle)
  end
  -- The move to `character_select` is the bridge's cue, and a bridge may
  -- answer it at once with a report of its own: that later report stands.
  local now = rpf.players.get(handle)
  if not now or now.state == "dropping" then
    return nil, "not_found"
  end
  if now.state == "active" then
    local current = loaded[handle]
    if current and current.key == character.key then
      current.name = character.name
      return true
    end
    return nil, "superseded"
  end
  loaded[handle] = { key = character.key, name = character.name }
  local moved, why = rpf.players.advance(handle, "active")
  if not moved then
    loaded[handle] = nil
    return nil, why
  end
  return true
end

---The bridge reports that a player's framework character is unloaded:
---their player goes back to `character_select`.
---@param handle any The engine's handle.
---@return boolean? ok True once they are.
---@return string? err `forbidden`, `inactive`, `not_found` or `no_character`.
function bridge.character_unloaded(handle)
  if not from_bridge() then
    return nil, "forbidden"
  end
  if not active or closing then
    return nil, "inactive"
  end
  local player, err = reportable(handle)
  if not player then
    return nil, err
  end
  if not loaded[handle] then
    return nil, "no_character"
  end
  loaded[handle] = nil
  if player.state == "active" then
    rpf.players.advance(handle, "character_select")
  end
  return true
end

---The bridge reports that its framework cannot be asked (its resource
---stopped): every facade call is `unavailable` until it says `available`.
---@param reason any Why, for the log.
---@return boolean? ok True.
---@return string? err `forbidden` or `inactive` (nothing is registered).
function bridge.unavailable(reason)
  if not from_bridge() then
    return nil, "forbidden"
  end
  if not registered then
    return nil, "inactive"
  end
  local why = text(reason, bridge.MAX_NAME_BYTES) and reason or "unavailable"
  if outage == nil then
    log("warn", "the " .. registered.name .. " bridge's framework is unavailable (" .. why .. ")")
    outage = why
    announce("unavailable", why)
  end
  outage = why
  return true
end

---The bridge reports that its framework can be asked again.
---@return boolean? ok True.
---@return string? err `forbidden` or `inactive`.
function bridge.available()
  if not from_bridge() then
    return nil, "forbidden"
  end
  if not registered then
    return nil, "inactive"
  end
  if outage ~= nil then
    outage = nil
    log("info", "the " .. registered.name .. " bridge's framework is available again")
    announce("available")
  end
  return true
end

-- Routing ----------------------------------------------------------------------

---The active bridge's name.
---@return string? name The bridge, or nil while none is active.
function bridge.active()
  return active and registered and registered.name or nil
end

---Whether the active bridge implements a call. `characters.current` is the
---core's, from the lifecycle, so it works wherever a bridge is active.
---@param domain string The domain.
---@param call string The call.
---@return boolean supported True if it does.
function bridge.supports(domain, call)
  if not active or not registered then
    return false
  end
  if domain == "characters" then
    return call == "current"
  end
  return registered.supports[domain .. "." .. tostring(call)] ~= nil
end

---The bridge's function for a call, if it may be asked now.
---@param domain string The domain.
---@param call string The call.
---@return function? fn The function.
---@return string? status `unavailable` (no active bridge, or its framework is unavailable) or `unsupported`.
function bridge.reach(domain, call)
  if not active or not registered then
    return nil, "unavailable"
  end
  local fn = registered.supports[domain .. "." .. call]
  if not fn then
    return nil, "unsupported"
  end
  if outage then
    return nil, "unavailable"
  end
  return fn
end

---The character a player has in play, as the bridge reported it. While
---the framework is unavailable this is too, like every other call: the
---framework may be unloading it as it stops. It is kept for when it is back.
---@param handle any The engine's handle.
---@return { key: string, name: string }? character A copy.
---@return string? err `unavailable` (no active bridge, or its framework is unavailable), `not_logged_in` or `no_character`.
function bridge.character(handle)
  if not active or outage then
    return nil, "unavailable"
  end
  local player = rpf.players.get(handle)
  if not player or not player.player_id or player.state == "dropping" then
    return nil, "not_logged_in"
  end
  local character = loaded[handle]
  if not character or player.state ~= "active" then
    return nil, "no_character"
  end
  return { key = character.key, name = character.name }
end

---Asks the bridge for a read and checks what it answered.
---@param fn function The bridge's function.
---@param call string The call, `<domain>.<call>`, for the log.
---@param valid fun(value: any): any The check of a value: the value to hand on, or nil if it is not one.
---@param ... any The call's arguments.
---@return any value The value.
---@return string? err `not_found`, `no_character` or `unavailable`.
function bridge.read(fn, call, valid, ...)
  local ok, value, err = pcall(fn, ...)
  if not ok then
    log("error", call .. " threw: " .. scrub(value))
    return nil, "unavailable"
  end
  if value == nil then
    if err == nil and call == "jobs.current" then
      return nil
    end
    if READ_ERRORS[err] then
      return nil, err
    end
    log("error", call .. " answered nil and " .. tostring(err) .. ", which the contract does not allow")
    return nil, "unavailable"
  end
  local checked = valid(value)
  if checked == nil then
    log("error", call .. " answered a value the contract does not allow")
    return nil, "unavailable"
  end
  return checked
end

---Checks a balance a bridge read: a whole amount within `MAX_AMOUNT` either
---way (a framework may let an account go below zero).
---@param value any The value.
---@return number? balance The balance.
function bridge.balance_of(value)
  local max = rpf.protocol.MAX_AMOUNT
  return whole(value, -max, max) and value or nil
end

---Checks a count a bridge read.
---@param value any The value.
---@return number? count The count.
function bridge.count_of(value)
  return whole(value, 0, MAX_UNITS) and value or nil
end

---Checks a job a bridge read, and copies what the facade gives. The grade
---is any finite number: frameworks number grades their own way.
---@param value any The value.
---@return table? job `{ name, grade, on_duty, employer? }`.
function bridge.job_of(value)
  if
    type(value) ~= "table"
    or not text(value.name, bridge.MAX_NAME_BYTES)
    or type(value.grade) ~= "number"
    or value.grade ~= value.grade
    or value.grade == math.huge
    or value.grade == -math.huge
    or type(value.on_duty) ~= "boolean"
    or (value.employer ~= nil and not text(value.employer, bridge.MAX_NAME_BYTES))
  then
    return nil
  end
  return { name = value.name, grade = value.grade, on_duty = value.on_duty, employer = value.employer }
end

---Checks the account names a bridge listed: each once.
---@param value any The value.
---@return string[]? names A copy.
function bridge.accounts_of(value)
  if not is_list(value) or #value > MAX_ACCOUNTS then
    return nil
  end
  local out, seen = {}, {}
  for i, name in ipairs(value) do
    if not text(name, bridge.MAX_NAME_BYTES) or seen[name] then
      return nil
    end
    seen[name] = true
    out[i] = name
  end
  return out
end

---Asks the bridge for a command and classifies what it answered. Only an
---answer the bridge gave itself can say nothing changed: a throw, or
---anything the contract does not allow, is `unknown`, since the framework
---may have changed something before it. What it threw is logged with the
---framework's keys taken out, and stays out of the journal, which keeps an
---unknown intent's cause for staff: that says only which call threw.
---@param fn function The bridge's function.
---@param call string The call, for staff.
---@param ... any The call's arguments.
---@return boolean? ok True if it went through.
---@return string? status `refused`, `unavailable` or `unknown`.
---@return string? reason For `refused`, why; for `unknown`, what went wrong, for staff.
function bridge.command(fn, call, ...)
  local ok, done, status, reason = pcall(fn, ...)
  if not ok then
    log("error", call .. " threw: " .. scrub(done))
    return nil, "unknown", "the bridge threw from " .. call
  end
  if done == true then
    return true
  end
  if done == nil and STATUSES[status] then
    if status == "refused" then
      return nil, "refused", text(reason, 64) and reason or "framework"
    elseif status == "unavailable" then
      return nil, "unavailable"
    end
    return nil, "unknown", "the framework could not say whether " .. call .. " happened"
  end
  return nil, "unknown", "the bridge answered " .. call .. " with something the contract does not allow"
end

---Withdraws the bridge an origin registered, because that origin's code is
---gone (on FiveM, its resource stopped). Called by `rpf.unload_origin`.
---@param origin any The origin.
function bridge.unload_origin(origin)
  if registered and origin ~= nil and registered.origin == origin then
    withdraw("its resource stopped", false)
  end
end

---Wires the module up: activation when the profile is fixed, a newly
---logged-in player moved on while a bridge is active, and a leaving
---player's character forgotten. Called by `rpf.start_server`.
---@param p rpf.ServerPlatform The platform.
function bridge.start(p)
  platform = p
  rpf.events.on("domains.fixed", function()
    evaluate()
  end)
  rpf.events.on("players.registered", function(player)
    if active then
      to_select(player.handle)
    end
  end)
  rpf.events.on("players.dropping", function(player)
    loaded[player.handle] = nil
  end)
end

rpf.bridge = bridge
return bridge
