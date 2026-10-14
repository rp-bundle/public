---The config this server last applied: the snapshot itself, its version and
---its hash, persisted across restarts, with typed lookups over it.
---
---Config is portal-authoritative and replicated wholesale (E2). `Hello`
---carries the version and hash the server last applied, so a reconnect at the
---current version transfers nothing, and a matching version with a different
---hash forces a full resend, which is how silent drift is caught. Because a
---reconnect at the current version transfers nothing, the snapshot has to
---survive a restart too, or a restarted server would hold a version and no
---config. So all three are stored together, in one `kv_set`, and are only
---ever read back together.
---
---Lookups return copies. A script that edits what `config.item` returned
---changes its own copy, never the cached snapshot every other module reads.
---
---The portal sends a `config` request after `Welcome` whenever the version
---and hash `Hello` named are not its current ones, and again whenever a
---change moves this server's version. `config.serve` registers the handler,
---which applies it and answers `config_applied`: `applied`, or `failed` with
---why, keeping the config it had. The request journal (`rpf.client`) makes
---that at most once per request, and answers a crash mid-apply `unknown`.
---
---**The snapshot's shape is `protocol::ConfigSnapshot`.** `settings` is an
---object keyed by setting name, every key present. `items`, `item_bases`
---(E3) and `employers` (E4) are arrays of objects keyed by `slug`, and
---`paying_accounts` (#169) one keyed by `name`, `addons` (J2) one keyed
---by `namespace`, and `dialogs` (L1) one keyed by `slug`;
---`employer_departments` and `employer_jobs` (E4) are arrays of objects
---keyed by `employer` and `slug` together, because their slugs are unique
---only within their employer; `item_defaults` is one object, and
---`employer_ids` (L2) one mapping each server-run employer's slug to its
---id. There is
---no `jobs` section: cores before E4 indexed one by `slug` alone and would
---refuse a snapshot with two employers' `officer`, so the portal never
---sends one. `config.SECTIONS` holds that
---in one place. The protocol decoder keeps the snapshot whole, so
---a section not listed there is kept, compared and reported in
---`config.changed`, just not indexed, and a portal that adds one is never
---refused.
---
---**Items arrive resolved.** The portal applies server inheritance, then
---each item's base, then the catalog defaults, before it sends anything
---(E3), so every item in `items` has its weight, size and stack limit, and
---nothing here ever resolves one. `item_bases` is reference data for scripts
---that treat a category alike; `item_defaults` is what an item the config
---does not define behaves as. An item with an image carries it as `image`,
---its content hash (P3), never a URL: the image is a player's client's to
---fetch from the portal, and the hash is what tells it the image changed.
---
---**`paying_accounts` (#169) names the accounts this server pays out of**,
---by `name`, each with the `id` `rpf.accounts.pay` takes. Only which
---accounts: their balances are live state, and arrive when `rpf.accounts`
---holds them.
---
---**Jobs carry what `rpf.jobs` needs (D7).** Every job has a `rank`, a
---whole number from 0 to 1000 compared only within its employer, and a paid
---one a `salary` per pay period; an employer that pays salaries names its
---`payroll`, one of the `paying_accounts` by name. They are fields of the
---entries already indexed, so `config.job` and `config.employer` return
---them, and nothing here checks them: `rpf.jobs` reads them at each use and
---skips, with a log line, what it cannot use.
---
---**`new_character` arrives checked (E5).** `accounts` are the accounts the
---portal opens and funds when it creates a character: this side never
---provisions money. `job` is the default job, `null` when none is configured
---or when the one configured is not a job on this server; in the second case
---the setting (`economy.default_job`) still names it, and applying the
---snapshot logs that, so the server's console says why new characters get
---no job.
---
---**Linked staff change config in game (E6) through `edit`**, never by
---changing what is held here: the change goes to the portal, which applies
---it only if the version it names is still this server's, and the result
---comes back the way every config does, in a `config` request. So this
---module stays the portal's snapshot and nothing else, and an edit the
---portal discarded (because the config moved on first, or while the edit
---waited out an outage) never shows here at all. The staff member is told
---either way, and `config.edit_applied`, `config.edit_discarded` or
---`config.edit_refused` is announced.
---@class rpf.config
---@field KEY string The storage key. Namespaced, because the store is shared with whatever else the engine persists.
---@field SECTIONS table<string, rpf.config.Section> How each known section is indexed.
---@field MAX_CHANGES integer The most changes one `edit` carries. Mirrors `limits::MAX_CONFIG_CHANGES`.
---@field EDIT_FLAGS table<string, string[]> For each kind of change, the permissions of which a staff member must hold one for `edit` to send it. The portal checks the exact one again.
---@field EDIT_APPLIED string What a staff member is told when the portal applied their edit, with `%d` for the new version.
---@field EDIT_DISCARDED string What a staff member is told when the portal discarded their edit because the config had moved on.
---@field EDIT_UNAVAILABLE string What a staff member is told when their edit got no answer from the portal at all.
local config = {}

local rpf = rpf
local json = rpf.json
local events = rpf.events

config.KEY = "rpf.config.applied"
config.MAX_CHANGES = 16
config.EDIT_APPLIED = "Config change saved. The server moves to config version %d."
config.EDIT_DISCARDED =
  "The config changed before your change reached the portal, so it was not applied. Look at the config again and redo it."
config.EDIT_UNAVAILABLE = "Your config change could not reach the portal. Try again in a moment."

local SETTINGS_FLAGS = { "config.settings.edit", "config.accounts.edit" }
local ITEMS_FLAGS = { "config.items.edit" }
local JOBS_FLAGS = { "config.jobs.edit" }

config.EDIT_FLAGS = {
  -- Which of the two a setting needs is the portal's (`SettingDef::permission`).
  setting = SETTINGS_FLAGS,
  create_item_base = ITEMS_FLAGS,
  update_item_base = ITEMS_FLAGS,
  delete_item_base = ITEMS_FLAGS,
  create_item = ITEMS_FLAGS,
  update_item = ITEMS_FLAGS,
  delete_item = ITEMS_FLAGS,
  create_employer = JOBS_FLAGS,
  update_employer = JOBS_FLAGS,
  delete_employer = JOBS_FLAGS,
  create_department = JOBS_FLAGS,
  update_department = JOBS_FLAGS,
  delete_department = JOBS_FLAGS,
  create_job = JOBS_FLAGS,
  update_job = JOBS_FLAGS,
  delete_job = JOBS_FLAGS,
}

---A placement's change (L4), by the type action whose addon flag it needs:
---the flag the installed type's `actions` names, `edit` when it names none,
---and nobody when it names `false`.
local WORLD_ACTIONS = {
  create_world_record = "create",
  update_world_record = "edit",
  delete_world_record = "delete",
}

---How one snapshot section is indexed for lookups.
---@class rpf.config.Section
---@field kind "map"|"list" `map`: an object, looked up by key. `list`: an array of objects, looked up by the `key` field of each.
---@field key string? For a list, the field that names each entry.
---@field within string? For a list whose `key` is unique only inside a parent, the field naming the parent. Entries are then indexed by both, as `parent/key`.

config.SECTIONS = {
  settings = { kind = "map" },
  items = { kind = "list", key = "slug" },
  item_bases = { kind = "list", key = "slug" },
  item_defaults = { kind = "map" },
  employers = { kind = "list", key = "slug" },
  employer_departments = { kind = "list", key = "slug", within = "employer" },
  employer_jobs = { kind = "list", key = "slug", within = "employer" },
  employer_ids = { kind = "map" },
  paying_accounts = { kind = "list", key = "name" },
  addons = { kind = "list", key = "namespace" },
  dialogs = { kind = "list", key = "slug" },
}

---The index key of an entry named within a parent: both names, joined by a
---character no slug contains.
---@param parent any The parent's name.
---@param key any The entry's own name.
---@return string? composite The index key, or nil unless both are strings.
local function composite(parent, key)
  if type(parent) ~= "string" or type(key) ~= "string" then
    return nil
  end
  return parent .. "/" .. key
end

---What is applied now.
---@class rpf.config.Current
---@field version number? The version, nil before any config.
---@field hash string? Its hash.
---@field snapshot table? The snapshot, as decoded.
---@field index table<string, table<string, any>> Each indexed section, by key.

---@type rpf.config.Current
local current = { index = {} }

---The platform and connection `serve` was given, which `edit` sends through.
---@type rpf.ServerPlatform?
local platform_in_use = nil
---@type rpf.Client?
local connection = nil

local copy = json.copy

---Builds the lookup index for a snapshot, refusing a known section of the
---wrong shape.
---@param snapshot table The snapshot, decoded.
---@return table<string, table<string, any>>? index Each indexed section, or nil if refused.
---@return string? err Which section, and what was wrong.
local function build_index(snapshot)
  local index = {}
  for name, section in pairs(config.SECTIONS) do
    local value = snapshot[name]
    local by_key = {}
    if value == nil or value == json.null then
      -- An absent section is empty: E3–E5 add them one at a time, and an older portal sends fewer.
    elseif section.kind == "map" then
      if not json.is_object(value) then
        return nil, name .. " must be an object"
      end
      for key, entry in pairs(value) do
        by_key[key] = entry
      end
    else
      if not json.is_array(value) then
        return nil, name .. " must be an array"
      end
      for i, entry in ipairs(value) do
        local named = json.is_object(entry) and entry[section.key]
        if type(named) ~= "string" then
          return nil, name .. "[" .. i .. "] has no string " .. section.key
        end
        local key = named --[[@as string]]
        if section.within then
          local within = composite(entry[section.within], named)
          if not within then
            return nil, name .. "[" .. i .. "] has no string " .. section.within
          end
          key = within
        end
        if by_key[key] ~= nil then
          return nil, name .. " has two entries named " .. key
        end
        by_key[key] = entry
      end
    end
    index[name] = by_key
  end
  return index, nil
end

---Whether a value is a whole number, the way JSON carries one.
---@param value any The value.
---@return boolean whole True for a number with no fractional part.
local function is_whole(value)
  return type(value) == "number" and value == math.floor(value)
end

---Checks the `new_character` section (E5), if there is one: an object whose
---`accounts` is an array of `{ name, amount }` and whose `job` is null or an
---`{ employer, job }` object. Fields it does not know are left alone, so a
---newer portal may add some.
---@param section any The section, as decoded.
---@return string? err What is wrong, or nil if it is acceptable.
local function check_new_character(section)
  if section == nil or section == json.null then
    return nil
  end
  if not json.is_object(section) then
    return "new_character must be an object"
  end
  local accounts = section.accounts
  if accounts ~= nil and accounts ~= json.null then
    if not json.is_array(accounts) then
      return "new_character.accounts must be an array"
    end
    for i, account in ipairs(accounts) do
      if not json.is_object(account) or type(account.name) ~= "string" or not is_whole(account.amount) or account.amount < 0 then
        return "new_character.accounts[" .. i .. "] must have a string name and a whole amount"
      end
    end
  end
  local job = section.job
  if job ~= nil and job ~= json.null then
    if not json.is_object(job) or type(job.employer) ~= "string" or type(job.job) ~= "string" then
      return "new_character.job must be null or have a string employer and job"
    end
  end
  return nil
end

---Checks the `paying_accounts` section (#169), if there is one: every entry
---has a string `id`, which `rpf.accounts` holds it by. Its `name` is checked
---by the index, like every list section's key.
---@param section any The section, as decoded.
---@return string? err What is wrong, or nil if it is acceptable.
local function check_paying_accounts(section)
  if not json.is_array(section) then
    return nil -- The index refuses a section of the wrong shape.
  end
  for i, account in ipairs(section) do
    if json.is_object(account) and type(account.id) ~= "string" then
      return "paying_accounts[" .. i .. "] has no string id"
    end
  end
  return nil
end

---Checks what `apply` and `load` accept: a non-negative integer version, a
---string hash, and a snapshot object whose known sections index.
---@param version any The version.
---@param hash any The hash.
---@param snapshot any The snapshot.
---@return table<string, table<string, any>>? index The index, or nil if refused.
---@return string? err Why.
local function check(version, hash, snapshot)
  if type(version) ~= "number" or version < 0 or version ~= math.floor(version) then
    return nil, "the version must be a non-negative integer"
  end
  if type(hash) ~= "string" then
    return nil, "the hash must be a string"
  end
  if not json.is_object(snapshot) then
    return nil, "the snapshot must be an object"
  end
  local err = check_new_character(snapshot.new_character) or check_paying_accounts(snapshot.paying_accounts)
  if err then
    return nil, err
  end
  return build_index(snapshot)
end

---Logs a default job the portal could not send (E5): the setting names a
---job, but `new_character.job` is null because it is not a job on this
---server. New characters then start with no job, and this says why.
---@param platform rpf.ServerPlatform The platform to log through.
---@param snapshot table The snapshot just made current.
local function warn_broken_job(platform, snapshot)
  local settings = snapshot.settings
  if not json.is_object(settings) then
    return
  end
  ---@type table?
  local named = settings["economy.default_job"]
  local section = snapshot.new_character
  local sent = json.is_object(section) and section.job or nil
  if type(named) == "table" and json.is_object(named) and not json.is_object(sent) then
    platform.log(
      "warn",
      "rpf: the default job "
        .. tostring(named.employer)
        .. "/"
        .. tostring(named.job)
        .. " is not a job on this server; new characters start with no job"
    )
  end
end

---Reads the stored entry: version, hash and snapshot, all or nothing.
---@param platform rpf.ServerPlatform The platform.
---@return table? stored The decoded entry, or nil if none or unreadable.
---@return table<string, table<string, any>>? index Its index.
local function read(platform)
  local raw = platform.kv_get(config.KEY)
  if raw == nil then
    return nil, nil
  end
  local stored = json.decode(raw)
  if json.is_object(stored) then
    local index = check(stored.version, stored.hash, stored.snapshot)
    if index then
      return stored, index
    end
  end
  platform.log("warn", "rpf: ignoring an unreadable stored config; the portal will send a full snapshot")
  return nil, nil
end

---The names of the sections that differ between two snapshots, sorted.
---Compared by canonical encoding (the codec sorts keys), so key order and
---table identity never count as a change.
---@param old table? The previous snapshot, nil on a cold start.
---@param new table The new snapshot.
---@return string[] sections The changed sections, sorted.
local function changed_sections(old, new)
  local names = {}
  for name in pairs(new) do
    names[name] = true
  end
  for name in pairs(old or {}) do
    names[name] = true
  end
  local out = {}
  for name in pairs(names) do
    local a = old and old[name]
    local b = new[name]
    if (a == nil) ~= (b == nil) or (a ~= nil and json.encode(a) ~= json.encode(b)) then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

---Makes a snapshot current and announces what changed.
---@param version number The version.
---@param hash string Its hash.
---@param snapshot table The snapshot.
---@param index table<string, table<string, any>> Its index.
local function install(version, hash, snapshot, index)
  local sections = changed_sections(current.snapshot, snapshot)
  current = { version = version, hash = hash, snapshot = snapshot, index = index }
  if #sections > 0 then
    ---@type rpf.ConfigChange
    local change = { version = version, sections = sections }
    events.emit("config.changed", change)
  end
end

---Reads the stored version and hash, for `Hello`.
---
---All three or nothing: an entry that is not a version, a hash and a
---snapshot that indexes is treated as nothing stored, and logged. The worst
---that costs is one full snapshot, whereas trusting it could leave a server
---on config it never applied.
---@param platform rpf.ServerPlatform The platform. Config is only ever held by a game server.
---@return number? version The config version, or nil on a cold start.
---@return string? hash Its hash, nil exactly when the version is.
function config.load(platform)
  local stored = read(platform)
  if not stored then
    return nil, nil
  end
  return stored.version, stored.hash
end

---Loads the stored snapshot into memory at start, so lookups work before the
---portal is reached, and announces it as a change from nothing. Called by
---`rpf.start_server`.
---@param platform rpf.ServerPlatform The platform.
function config.restore(platform)
  current = { index = {} }
  local stored, index = read(platform)
  if stored and index then
    install(stored.version, stored.hash, stored.snapshot, index)
    warn_broken_job(platform, stored.snapshot)
  end
end

---Applies a snapshot from the portal: checks it, persists it, makes it
---current, and emits `config.changed` with the sections that differ.
---
---It is persisted before anything reads it, and the version with it, so a
---crash at any point leaves either the old config or the new one stored,
---never a version that does not describe the snapshot.
---@param platform rpf.ServerPlatform The platform.
---@param version number The config version, a non-negative integer.
---@param hash string Its hash, exactly as the portal sent it.
---@param snapshot table The snapshot, as decoded from the wire (marked tables).
---@return boolean applied False if the snapshot was refused.
---@return string? err Why.
function config.apply(platform, version, hash, snapshot)
  -- Taken over as a copy, so a caller that keeps and edits its table cannot
  -- change the applied config behind the stored snapshot's back.
  snapshot = copy(snapshot)
  local index, err = check(version, hash, snapshot)
  if not index then
    platform.log("error", "rpf: refused a config snapshot: " .. tostring(err))
    return false, err
  end
  local text, encode_err = json.encode(json.object({ version = version, hash = hash, snapshot = snapshot }))
  if not text then
    platform.log("error", "rpf: could not store a config snapshot: " .. tostring(encode_err))
    return false, encode_err
  end
  platform.kv_set(config.KEY, text)
  install(version, hash, snapshot, index)
  warn_broken_job(platform, snapshot)
  return true, nil
end

---Answers the portal's `config` requests on a connection: applies each one
---and replies `config_applied`, `applied` or `failed` with the reason. Called
---by `rpf.start_server`.
---
---A refused snapshot leaves the config that was applied before, which is
---what the portal is told, so staff never see a version as live here that
---this server did not take.
---@param platform rpf.ServerPlatform The platform the config is stored through.
---@param c rpf.Client The connection to the portal, which `edit` sends through too.
function config.serve(platform, c)
  platform_in_use, connection = platform, c
  c:handle("config", function(frame, reply)
    local applied, err = config.apply(platform, frame.version, frame.hash, frame.snapshot)
    if applied then
      reply("config_applied", { outcome = { outcome = "applied" } })
    else
      reply("config_applied", { outcome = { outcome = "failed", reason = "refused the snapshot: " .. tostring(err) } })
    end
  end)
end

---The version applied now.
---@return number? version The version, or nil before any config.
function config.version()
  return current.version
end

---A player who may make an edit: logged in here and not leaving. Read from
---`rpf.players` when called, since that module loads after this one.
---@param handle any The engine's handle.
---@return rpf.PlayerView? player A copy, or nil.
local function editor(handle)
  local players = rpf.players
  local player = handle ~= nil and players and players.get(handle) or nil
  if not player or player.player_id == nil or player.state == "dropping" then
    return nil
  end
  return player
end

---Whether a player holds one of the permissions that may make a change of
---this kind.
---@param handle any The engine's handle.
---@param flags string[] The permissions.
---@return boolean allowed True if the last push gave them any.
local function holds_any(handle, flags)
  local staff = rpf.staff
  for _, flag in ipairs(flags) do
    if staff and staff.can(handle, flag) then
      return true
    end
  end
  return false
end

---Tells the staff member how their edit went and announces it. The player is
---looked up again by account, since they may have left while the portal
---answered; one who is not here is told nothing, and the portal has recorded
---a discarded edit for staff whether they are or not.
---@param player_id string The staff member's player account.
---@param reply rpf.Frame? The portal's answer.
---@param failure string? Why there was none: `expired`, `outbox_full`, `outbox_unavailable`.
local function edit_answered(player_id, reply, failure)
  local players = rpf.players
  local player = players and players.by_player_id(player_id) or nil
  if player and player.state == "dropping" then
    player = nil
  end
  local p = platform_in_use
  ---Tells the staff member, if they are still here.
  ---@param text string The message.
  local function tell(text)
    if p and player then
      p.notify(player.handle, text)
    end
  end
  if reply and reply.type == "config_change_applied" then
    tell(string.format(config.EDIT_APPLIED, reply.version))
    events.emit("config.edit_applied", { player_id = player_id, version = reply.version })
    return
  end
  if reply and reply.type == "config_change_discarded" then
    if p then
      p.log("warn", "rpf: the portal discarded a config edit by player " .. player_id .. ": the config had moved on to version " .. reply.version)
    end
    tell(config.EDIT_DISCARDED)
    events.emit("config.edit_discarded", { player_id = player_id, version = reply.version })
    return
  end
  local code, reason
  if reply and reply.type == "rejected" then
    -- The portal writes the reason for the staff member.
    code, reason = reply.code, reply.reason
  else
    code, reason = failure or (reply and reply.type) or "unanswered", config.EDIT_UNAVAILABLE
  end
  if p then
    p.log("warn", "rpf: a config edit by player " .. player_id .. " was not applied (" .. code .. "): " .. reason)
  end
  tell(reason)
  events.emit("config.edit_refused", { player_id = player_id, code = code, reason = reason })
end

---Changes this server's config on behalf of a linked staff member in game
---(E6): what a server's config menu or command calls once the staff member
---confirms.
---
---`base_version` is the config version the staff member was looking at when
---they made the change (`version()` when the menu opened, not when they
---confirmed). The portal applies the changes only if that is still the
---server's version, all or none; if anything moved it in between, it applies
---nothing, records the edit as discarded for staff on the portal, and the
---staff member is told to redo it on the config as it is now. Nothing here
---changes until the portal pushes the new config, so a menu re-reads after
---`config.changed`.
---
---Sent only for a logged-in player holding a permission that may make each
---kind of change (`EDIT_FLAGS`, or for a world config record the installed
---type's action flag, `WORLD_ACTIONS`). The portal checks the exact
---permission, and every value, as its own pages do, and refuses the whole
---edit otherwise.
---The outcome comes later: the staff member is told, and
---`config.edit_applied`, `config.edit_discarded` or `config.edit_refused` is
---announced. While the portal is unreachable the edit waits in the outbox,
---and is answered by the same rule when it arrives.
---@param handle any The engine's handle of the staff member.
---@param base_version any The config version the change was made against, a whole number.
---@param changes any The changes, from 1 to `MAX_CHANGES`, each a table shaped as the portal's `ConfigChange` (`{ change = "setting", key = …, value = { state = "set", value = … } }`).
---@return boolean sent True once it is on its way.
---@return rpf.ConfigEditRefusal? err Why not.
function config.edit(handle, base_version, changes)
  local player = editor(handle)
  local c = connection
  if not player or not c then
    return false, "not_logged_in"
  end
  if not is_whole(base_version) or base_version < 0 then
    return false, "invalid_version"
  end
  if type(changes) ~= "table" or #changes < 1 or #changes > config.MAX_CHANGES then
    return false, "invalid_changes"
  end
  local count = 0
  for _ in pairs(changes) do
    count = count + 1
  end
  if count ~= #changes then
    return false, "invalid_changes"
  end
  -- What is sent: the caller's own tables, except that a placement's opaque
  -- `fields` or `patch` goes as a marked object (an empty move patch is
  -- `{}`, not `[]`), copied one level deep so the caller's table is left as
  -- it was. A cycle deeper down is the encode check's refusal below.
  local sent = {}
  for i, change in ipairs(changes) do
    sent[i] = change
    local flags = type(change) == "table" and config.EDIT_FLAGS[change.change] or nil
    local action = type(change) == "table" and WORLD_ACTIONS[change.change] or nil
    if action then
      local name = change.type_name
      local namespace = type(name) == "string" and name:match("^([a-z][a-z0-9_]*)%.") or nil
      local def = namespace and rpf.addons and rpf.addons.definition(name)
      if def and def.authority == "config" and def.world then
        local copy = {}
        for key, value in pairs(change) do
          copy[key] = value
        end
        for _, key in ipairs({ "fields", "patch" }) do
          if copy[key] ~= nil then
            if type(copy[key]) ~= "table" then
              return false, "invalid_changes"
            end
            local object = rpf.json.object()
            for field, value in pairs(copy[key]) do
              object[field] = value
            end
            copy[key] = object
          end
        end
        sent[i] = copy
        local grant = def.actions and def.actions[action]
        if grant == nil then
          grant = "edit"
        end
        if type(grant) ~= "string" then
          return false, "forbidden"
        end
        flags = { "addon." .. namespace .. "." .. grant }
      end
    end
    if not flags then
      return false, "invalid_changes"
    end
    if not holds_any(handle, flags) then
      return false, "forbidden"
    end
  end
  local player_id = player.player_id --[[@as string]]
  local fields = { player_id = player_id, base_version = base_version, changes = sent }
  -- Checked as the connection will encode it, so a change of the wrong shape
  -- is the caller's refusal here rather than an error from `send`.
  local _, shape_err = rpf.protocol.encode(rpf.protocol.SERVER_TO_PORTAL, {
    id = "00000000-0000-4000-8000-000000000000",
    sent_at = "1970-01-01T00:00:00Z",
    type = "config_changed",
    player_id = player_id,
    base_version = base_version,
    changes = sent,
  })
  if shape_err then
    return false, "invalid_changes"
  end
  local id, err = c:send("config_changed", fields, function(reply, failure)
    edit_answered(player_id, reply, failure)
  end)
  if not id then
    return false, err --[[@as rpf.ConfigEditRefusal]]
  end
  return true, nil
end

---Looks one entry up in an indexed section.
---@param section string The section.
---@param key any The key.
---@return any entry A copy, or nil.
local function lookup(section, key)
  local by_key = current.index[section]
  if type(key) ~= "string" or not by_key then
    return nil
  end
  return copy(by_key[key])
end

---An item definition, by slug, as the portal resolved it (E3): its own
---fields, then its base's, then the catalog defaults, so every field is set.
---@param slug string The item's slug.
---@return rpf.ConfigItem? item A copy of the item, or nil if the config has none by that slug. An item the config does not define behaves as `config.item_defaults()`.
function config.item(slug)
  return lookup("items", slug)
end

---An item base, by slug, as staff wrote it: a field the base does not set is
---nil. Reference data only, since every item already has its base applied.
---@param slug string The base's slug, which an item names in `base`.
---@return rpf.ConfigItemBase? base A copy of the base, or nil if the config has none by that slug.
function config.item_base(slug)
  return lookup("item_bases", slug)
end

---What an item the config does not define behaves as (E3): the weight, size
---and stack limit the portal gives an unknown item when it validates
---contents, sent so this side applies the same fallback and keeps no copy
---of its own.
---@return rpf.ConfigItemDefaults? defaults A copy, or nil before any config has arrived or from a portal older than E3.
function config.item_defaults()
  local defaults = current.snapshot and current.snapshot.item_defaults
  if not json.is_object(defaults) then
    return nil
  end
  return copy(defaults)
end

---An employer the server runs, by slug (E4). An employer a player runs is
---not config, and is never here.
---@param slug string The employer's slug.
---@return rpf.ConfigEmployer? employer A copy of the employer, or nil.
function config.employer(slug)
  return lookup("employers", slug)
end

---The slug of a server-run employer, by its id (L2): what an addon record's
---reference to an employer names (a job door's `employer`), since config
---names employers by slug everywhere else.
---@param id any The employer's id, as a record holds it.
---@return string? slug Its slug, or nil for an id that is no server-run employer's here.
function config.employer_slug(id)
  if type(id) ~= "string" then
    return nil
  end
  local ids = current.index.employer_ids
  for slug, employer_id in pairs(ids or {}) do
    if employer_id == id then
      return slug
    end
  end
  return nil
end

---A department, by its employer's slug and its own (E4). Its slug is unique
---only within the employer, so it takes both.
---@param employer string The employer's slug.
---@param slug string The department's slug.
---@return rpf.ConfigDepartment? department A copy of the department, or nil.
function config.department(employer, slug)
  return lookup("employer_departments", composite(employer, slug))
end

---A job, by its employer's slug and its own (E4). Two employers may each
---offer a job of the same slug, so it takes both.
---@param employer string The employer's slug.
---@param slug string The job's slug.
---@return rpf.ConfigJob? job A copy of the job, or nil.
function config.job(employer, slug)
  return lookup("employer_jobs", composite(employer, slug))
end

---The accounts the portal opens with every new character on this server,
---and what each starts with (E5), in the order staff listed them. The portal
---opens and funds them itself when it creates a character, so this is for
---showing a player what they will start with, never for paying it.
---@return rpf.ConfigStartingAccount[]? accounts A copy, or nil before any config has arrived or from a portal older than E5.
function config.starting_accounts()
  ---@type table?
  local section = current.snapshot and current.snapshot.new_character or nil
  if type(section) ~= "table" or not json.is_object(section) or not json.is_array(section.accounts) then
    return nil
  end
  return copy(section.accounts)
end

---The job a new character on this server starts in (E5), checked by the
---portal against this server's jobs, so it is always one `config.job` finds.
---Assigning it is `rpf.jobs`'s (D7), when the character is created.
---@return rpf.ConfigJobRef? job A copy, or nil if there is none: none configured, the configured one is not a job here (logged when the config was applied), or no config yet.
function config.default_job()
  ---@type table?
  local section = current.snapshot and current.snapshot.new_character or nil
  if type(section) ~= "table" or not json.is_object(section) then
    return nil
  end
  local job = section.job
  if not json.is_object(job) then
    return nil
  end
  return copy(job)
end

---An account this server pays out of (#169), as the config names it.
---@class rpf.ConfigPayingAccount
---@field id string The account's uuid: what `rpf.accounts.pay` takes as the paying account.
---@field name string What scripts find it by, unique among this server's paying accounts.

---One of the accounts this server pays out of (#169), by name: `id` and
---`name`. Its id is what `rpf.accounts.pay` takes as the paying account.
---The core holds every paying account after each `Welcome` and whenever the
---config names one it does not hold, so a script never holds one itself;
---`rpf.accounts.balance(id)` says whether it is held yet.
---@param name string The account's name, as staff opened it.
---@return rpf.ConfigPayingAccount? account A copy, or nil if the config has none by that name.
function config.paying_account(name)
  return lookup("paying_accounts", name)
end

---Every account this server pays out of (#169), in name order, as copies.
---What `rpf.accounts` holds.
---@return rpf.ConfigPayingAccount[] accounts Copies; empty before any config has arrived or from a portal older than #169.
function config.paying_accounts()
  ---@type table?
  local section = current.snapshot and current.snapshot.paying_accounts or nil
  if type(section) ~= "table" or not json.is_array(section) then
    return {}
  end
  return copy(section)
end

---One addon installed on this server (J2), as the config's `addons` section
---carries it: `namespace`, `version`, `hash`, `enabled`, its `manifest`, the
---installed `types` that differ from the manifest's, and the `records` of
---its config types. `rpf.addons` decides from it whether the addon runs.
---@param namespace string The addon's namespace.
---@return table? addon A copy, or nil if the config does not install it.
function config.addon(namespace)
  return lookup("addons", namespace)
end

---The namespace of every addon the config installs on this server (J2),
---enabled or not, in namespace order: what `rpf.holding` walks to find the
---types it holds by policy, whether or not their code is loaded.
---@return string[] namespaces The namespaces; empty before any config has arrived.
function config.addon_namespaces()
  local out = {}
  for namespace in pairs(current.index.addons or {}) do
    out[#out + 1] = namespace
  end
  table.sort(out)
  return out
end

---A dialog tree on this server (L1, #371), by slug, as staff built it in
---the panel: `slug`, `title`, `start`, and `nodes`, each with its `key`,
---`line` and `choices` (`label`, `conditions`, `does`). `rpf.dialogs` runs
---it; nothing here checks it beyond its slug, since the portal checked it
---whole before it was stored.
---@param slug string The dialog's slug.
---@return table? dialog A copy, or nil if the config has none by that slug.
function config.dialog(slug)
  return lookup("dialogs", slug)
end

---A setting's effective value, by key.
---@param key string The setting's key.
---@return any value A copy of the value, or nil if unset. A setting sent as null is `json.null`, so "set to null" and "not set" stay different.
function config.setting(key)
  return lookup("settings", key)
end

rpf.config = config
return config
