---When this server holds live addon records, and when it lets them go (J6):
---each live type's `hold` policy, carried out by the core, so an addon
---writes no hold code and a record is held the same whether or not the
---addon's code is loaded right now.
---
--- - **`hold = "owner"`**: held with the owner's session. A player's come
---   with the session hold when they register, a character's with its
---   selection (`rpf.sync`, `rpf.characters`), and both go when the player
---   leaves or puts the character away. A record an addon creates for an
---   owner whose session is here joins that session (`through`), and so does
---   one already held for the server when the session hold names it. A
---   record owned by the server or an employer has no session, so it is
---   held as a `server` type's are.
--- - **`hold = "server"`**: held by the server for as long as it runs and the
---   installation is enabled. The core **claims** them: a `hold` naming the
---   types, which the portal answers with a page of the records nobody
---   holds (at most `MAX_CLAIMED`), claimed again while a page comes back
---   full. It claims after every declaration (so a restart, which gave every
---   hold back, takes them again), whenever the config enables an
---   installation or changes its types, and every `CLAIM_MS`, which picks
---   up a record staff created in the portal meanwhile.
--- - **No `hold`**: on demand. The addon holds what it needs
---   (`rpf.api.records.hold`) and releases it, or it goes when the addon
---   stops.
---
---**The installation decides, not the code.** Holds follow what the config
---installs and enables, never whether the addon's Lua is loaded: an addon
---whose resource stopped, that is reloading, or whose files are missing
---keeps its policy records held, and the core drains them without it. So:
---
--- - **When an addon's code stops** while its installation stays enabled
---   (its resource stops, it reloads, its `start` threw, the files and the
---   portal disagree), what it held on demand is released with its final
---   state, and its policy records stay held.
--- - **When the config disables or removes the installation**, every record
---   of its types is released with its final state, the ones players'
---   sessions hold included: the contract's drain. The portal refuses new
---   holds of them meanwhile, and one it answered before the disable that
---   lands after it is drained as it arrives.
--- - **When the config enables an installation** (installed, or enabled
---   again), its `server` records are claimed and the `owner` records of
---   every player already here are held for their sessions; so are they
---   when an upgrade gives an enabled type `hold = "owner"`.
--- - **Putting a character away** releases what its selection brought (its
---   accounts, containers and `owner` records), never a `server` record or
---   one held on demand that it owns (`rpf.characters`).
---
---A drain that cannot finish yet (a create still on its way to the
---portal, a full outbox) tries again every `RETRY_MS` for as long as the
---records are still not this server's to keep.
---@class rpf.holding
---@field CLAIM_MS integer How often the core claims again, so a record created in the portal while this server runs is held within this long.
---@field RETRY_MS integer How long a drain that could not finish waits before it tries again.
---@field MAX_CLAIMED integer The most records one claim takes: the portal's `limits::MAX_CLAIMED_PER_HOLD`. A page this full means there may be more.
local holding = {}

local rpf = rpf
local events = rpf.events
local records = rpf.records

holding.CLAIM_MS = 60 * 1000
holding.RETRY_MS = 1000
holding.MAX_CLAIMED = 32

---@type rpf.ServerPlatform?
local platform = nil
---@type rpf.Client?
local connection = nil

---Installations the config enabled when it was last seen, by namespace, so
---a config change can tell which it enabled and which it took away.
---@type table<string, true>
local enabled = {}

---The types of those installations held with their owner when the config
---was last seen, so a config change can tell a type that became one (a new
---installation, or an upgrade that gave a type `hold = "owner"`).
---@type table<string, true>
local with_owner = {}

---Whether a claim is on its way, and whether another was asked for
---meanwhile, which then runs once it is answered.
local claiming, again = false, false

---The refusal last logged for a claim, so a full server says so once, not
---every `CLAIM_MS`.
---@type string?
local last_refusal = nil

---Installations the config took away (disabled or removed) since this
---process saw them enabled, until it enables them again: a hold that was
---answered for one of them after its drain ran (a claim or a session hold
---already on its way when the disable arrived) is drained as it lands.
---@type table<string, true>
local withdrawn = {}

---Namespaces with a drain waiting to try again, so a drain that runs
---meanwhile (a stop, then the disable that caused it) starts no second loop.
---@type table<string, true>
local retrying = {}

---Logs a line, if started.
---@param level string The level.
---@param message string The line.
local function log(level, message)
  if platform then
    platform.log(level, "rpf.holding: " .. message)
  end
end

---A type's `hold` policy, as installed here.
---@param type_name string The type's full name.
---@return "owner"|"server"|nil policy Nil for a type held on demand, a config type, or one no installed addon has.
function holding.policy(type_name)
  local def = rpf.addons.definition(type_name)
  if type(def) ~= "table" or def.authority ~= "live" then
    return nil
  end
  if def.hold == "owner" or def.hold == "server" then
    return def.hold
  end
  return nil
end

---Whether a held record is the server's to keep by its type's policy, whoever
---runs: every record of a `server` type, and one of an `owner` type owned by
---the server or an employer, which have no session to go with.
---@param entry rpf.records.Entry The record.
---@return boolean kept True if only a disabled installation lets it go.
local function kept_for_server(entry)
  local policy = holding.policy(entry.data.type)
  if policy == "server" then
    return true
  end
  local owner = entry.data.owner
  return policy == "owner" and type(owner) == "table" and (owner.kind == "server" or owner.kind == "employer")
end

---The player whose session a new record of an `owner` type joins: the
---player who owns it, or whose character in play owns it, if they are
---here. Nil for any other type or owner, and for an owner who
---is not here: the record is then held for the server until the addon
---releases it or stops.
---@param type_name string The type.
---@param owner { kind: string, id: string } Its owner.
---@return string? player_id The session's player.
function holding.session_of(type_name, owner)
  if holding.policy(type_name) ~= "owner" or type(owner) ~= "table" then
    return nil
  end
  if owner.kind == "player" then
    return rpf.players.by_player_id(owner.id) and owner.id or nil
  end
  if owner.kind == "character" then
    -- Only the character in play: a player's other characters are held for
    -- their session too, but their own records come with a selection.
    local character = records.entries[records.key("character", owner.id)]
    local player_id = character and character.through
    local selected = player_id and rpf.characters.selected(player_id)
    return (selected and selected.id == owner.id) and player_id or nil
  end
  return nil
end

---Whether the config installs a namespace and enables it.
---@param namespace string The namespace.
---@return boolean on True if enabled.
local function is_enabled(namespace)
  local installed = rpf.config.addon(namespace)
  return type(installed) == "table" and installed.enabled == true
end

---Whether a held record stays held whether or not its addon's code runs:
---its installation is enabled, and its type's policy holds it for the
---server, or a session holds it. What a stop of the code must not let go,
---whoever lets go: the drain, and a hold answered after the code stopped
---(`rpf.data.hold`).
---@param entry rpf.records.Entry The record.
---@return boolean kept True if only a disable or the session's end lets it go.
function holding.keeps(entry)
  local namespace = entry.kind == "addon_record" and string.match(entry.data.type, "^([^.]+)%.") or nil
  return namespace ~= nil and is_enabled(namespace) and (entry.through ~= nil or kept_for_server(entry))
end

---Every type the config's enabled installations hold by policy for the
---server, in name order: what a claim names.
---@return string[] types The types.
function holding.claimable()
  local out = {}
  for _, namespace in ipairs(rpf.config.addon_namespaces()) do
    if is_enabled(namespace) then
      for _, type_name in ipairs(rpf.addons.type_names(namespace)) do
        if holding.policy(type_name) then
          out[#out + 1] = type_name
        end
      end
    end
  end
  table.sort(out)
  return out
end

---Claims a page of the records this server holds by policy, and again while
---a page comes back full. Does nothing while the connection is not ready,
---since the next `Welcome` claims, or when no enabled type has a policy.
---One claim is on its way at a time: asked for meanwhile, another runs once
---it is answered. The hold waits for the declaration and the reports queued
---before it, as every hold does, so the declaration can never release what
---it takes.
function holding.claim()
  if not connection or connection.state ~= "ready" then
    return
  end
  if claiming then
    again = true
    return
  end
  local types = holding.claimable()
  if #types == 0 then
    return
  end
  claiming, again = true, false
  rpf.sync.hold({ types = types }, nil, function(views, err)
    claiming = false
    if err then
      if err ~= last_refusal then
        log("warn", "could not claim the records this server holds (" .. tostring(err) .. "); trying again later")
      end
      last_refusal = err
    else
      last_refusal = nil
    end
    if again or (views and #views >= holding.MAX_CLAIMED) then
      holding.claim()
    end
  end)
end

---Holds the `owner` records of every player here for their sessions: the
---player's own, and their selected character's. Run when the config enables
---an installation with an `owner` type, whose records no session hold
---brought. Everything else those holds name is held already, and keeps the
---state it has here.
local function hold_sessions()
  for _, player in ipairs(rpf.players.list()) do
    local player_id = player.player_id
    if player_id then
      local owners = { { kind = "player", id = player_id } }
      local character = rpf.characters.selected(player_id)
      if character then
        owners[2] = { kind = "character", id = character.id }
      end
      rpf.sync.hold({ owners = owners }, player_id, function(_, err)
        if err then
          log("warn", "could not hold a player's records of a type now held with its owner (" .. tostring(err) .. ")")
        end
        if character then
          -- Put away or switched while this was on its way: what it brought
          -- of that character goes back.
          rpf.characters.settle_hold(player_id, character.id)
        end
      end)
    end
  end
end

---Lets go of the records of an addon's types that are not this server's to
---keep now. With its installation disabled or gone, that is every one, a
---session's included; with it enabled but its code stopped, those held on
---demand; with it running, none. Worked out again on every try, so a drain
---that waited across an enable stops, and one that waited across a disable
---takes everything.
---@param namespace string The addon.
function holding.drain(namespace)
  if not rpf.sync.connection then
    return
  end
  local everything = not is_enabled(namespace)
  if not everything and rpf.addons.running(namespace) then
    return
  end
  local prefix = namespace .. "."
  local refs, deleting = {}, false
  for _, entry in pairs(records.entries) do
    if entry.kind == "addon_record" and entry.data.type:sub(1, #prefix) == prefix then
      if everything or (entry.through == nil and not kept_for_server(entry)) then
        if entry.deleted then
          -- Gone once the portal has the deletion; back, to be released,
          -- if it refuses it (another record refers to it).
          deleting = true
        else
          refs[#refs + 1] = { kind = "addon_record", id = entry.id }
        end
      end
    end
  end
  table.sort(refs, function(a, b)
    return a.id < b.id
  end)
  ---@type boolean?, string?
  local ok, err = true, nil
  if #refs > 0 then
    ok, err = rpf.sync.release(refs)
  end
  if ok and deleting then
    ok, err = nil, "deleting"
  end
  if ok then
    return
  end
  if err == "too_large" then
    log("error", "a record of " .. namespace .. " is too large to release, and stays held")
  else
    log("debug", "some of " .. namespace .. "'s records stay held for now (" .. tostring(err) .. "); trying again")
    if not retrying[namespace] and platform then
      retrying[namespace] = true
      platform.after(holding.RETRY_MS, function()
        retrying[namespace] = nil
        holding.drain(namespace)
      end)
    end
  end
end

---Takes a config change: drains what it disabled or removed, holds
---sessions for the types it made held with their owner, and claims. Any change to the installations
---claims again, since an upgrade may have given a type a policy.
---@param change rpf.ConfigChange The change.
local function on_config(change)
  local touched = false
  for _, section in ipairs(change.sections) do
    touched = touched or section == "addons"
  end
  if not touched then
    return
  end
  local now, owner_types, newly_owner = {}, {}, false
  for _, namespace in ipairs(rpf.config.addon_namespaces()) do
    if is_enabled(namespace) then
      now[namespace] = true
      for _, type_name in ipairs(rpf.addons.type_names(namespace)) do
        if holding.policy(type_name) == "owner" then
          owner_types[type_name] = true
          newly_owner = newly_owner or not with_owner[type_name]
        end
      end
    end
  end
  with_owner = owner_types
  -- A type an upgrade moved between the server's hold and its owner's: its
  -- records held for a session are the server's now, so the session's end
  -- must not let them go; and the other way, those held for the server
  -- whose owner's session is here join it, so their owner leaving does.
  for _, entry in pairs(records.entries) do
    if entry.kind == "addon_record" then
      local policy = holding.policy(entry.data.type)
      if entry.through ~= nil and policy == "server" then
        records.hold_for(entry.kind, entry.id, nil)
      elseif entry.through == nil and policy == "owner" then
        local session = holding.session_of(entry.data.type, entry.data.owner)
        if session then
          records.hold_for(entry.kind, entry.id, session)
        end
      end
    end
  end
  local gone = {}
  for namespace in pairs(enabled) do
    if not now[namespace] then
      gone[#gone + 1] = namespace
    end
  end
  enabled = now
  table.sort(gone)
  for _, namespace in ipairs(gone) do
    withdrawn[namespace] = true
    holding.drain(namespace)
  end
  local stopped = {}
  for namespace in pairs(now) do
    withdrawn[namespace] = nil
    if not rpf.addons.running(namespace) then
      stopped[#stopped + 1] = namespace
    end
  end
  -- An enabled addon whose code is not running has no state change to come,
  -- so a type this change took a policy from (its records now held on
  -- demand, by nobody) is drained here.
  table.sort(stopped)
  for _, namespace in ipairs(stopped) do
    holding.drain(namespace)
  end
  if newly_owner then
    -- No session hold brought these types' records: the players already
    -- here have theirs held now.
    hold_sessions()
  end
  holding.claim()
end

---Starts the lifecycle on a connection: claims after every `Welcome`
---(chained after whatever ran there before, so the declaration is owed by
---then and the claim waits for it) and every `CLAIM_MS` from the first
---`Welcome` on, follows the
---config's installations, and drains an addon whose code stops. Called by
---`rpf.start_server`, after `rpf.sync.start` and before the config is
---restored, whose `config.changed` it reads.
---@param p rpf.ServerPlatform The platform.
---@param client rpf.Client The connection to the portal.
function holding.start(p, client)
  platform = p
  connection = client
  enabled, with_owner, retrying, withdrawn = {}, {}, {}, {}
  claiming, again, last_refusal = false, false, nil
  ---Claims again every `CLAIM_MS`, read at each tick, for as long as the
  ---process runs.
  local function tick()
    holding.claim()
    p.after(holding.CLAIM_MS, tick)
  end
  local ticking = false
  local ready = client.on_ready
  ---Runs at every `Welcome`: whatever was set before, then a claim, and
  ---from the first one on, the periodic claim.
  ---@param c rpf.Client The connection, now ready.
  client.on_ready = function(c)
    if ready then
      ready(c)
    end
    holding.claim()
    if not ticking then
      ticking = true
      p.after(holding.CLAIM_MS, tick)
    end
  end
  events.on("config.changed", on_config)
  -- A hold answered after the config took its addon away: drained as it
  -- lands, or it would stay held, blocking staff's direct edits, until the
  -- next restart.
  events.on("records.held", function()
    local names = {}
    for namespace in pairs(withdrawn) do
      names[#names + 1] = namespace
    end
    table.sort(names)
    for _, namespace in ipairs(names) do
      holding.drain(namespace)
    end
  end)
  events.on("addons.state", function(change)
    if change.state ~= "active" then
      holding.drain(change.namespace)
    end
  end)
end

rpf.holding = holding
return holding
