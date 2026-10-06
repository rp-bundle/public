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
---`paying_accounts` (#169) one keyed by `name`;
---`employer_departments` and `employer_jobs` (E4) are arrays of objects
---keyed by `employer` and `slug` together, because their slugs are unique
---only within their employer; and `item_defaults` is one object. There is
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
---does not define behaves as.
---
---**`paying_accounts` (#169) names the accounts this server pays out of**,
---by `name`, each with the `id` `rpf.accounts.pay` takes. Only which
---accounts: their balances are live state, and arrive when `rpf.accounts`
---holds them.
---
---**`new_character` arrives checked (E5).** `accounts` are the accounts the
---portal opens and funds when it creates a character: this side never
---provisions money. `job` is the default job, `null` when none is configured
---or when the one configured is not a job on this server; in the second case
---the setting (`economy.default_job`) still names it, and applying the
---snapshot logs that, so the server's console says why new characters get
---no job.
---@class rpf.config
---@field KEY string The storage key. Namespaced, because the store is shared with whatever else the engine persists.
---@field SECTIONS table<string, rpf.config.Section> How each known section is indexed.
local config = {}

local rpf = rpf
local json = rpf.json
local events = rpf.events

config.KEY = "rpf.config.applied"

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
  paying_accounts = { kind = "list", key = "name" },
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
---@param connection rpf.Client The connection to the portal.
function config.serve(platform, connection)
  connection:handle("config", function(frame, reply)
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
---Assigning it is the character module's.
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

---A setting's effective value, by key.
---@param key string The setting's key.
---@return any value A copy of the value, or nil if unset. A setting sent as null is `json.null`, so "set to null" and "not set" stay different.
function config.setting(key)
  return lookup("settings", key)
end

rpf.config = config
return config
