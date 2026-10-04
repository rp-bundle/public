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
---object keyed by setting name, every key present. `items`, `employers` and
---`jobs` (E3–E5) will be arrays of objects keyed by `slug`, and
---`config.SECTIONS` holds that in one place. The protocol decoder keeps the
---snapshot whole, so a section not listed there is kept, compared and
---reported in `config.changed`, just not indexed, and a portal that adds one
---is never refused.
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

config.SECTIONS = {
  settings = { kind = "map" },
  items = { kind = "list", key = "slug" },
  employers = { kind = "list", key = "slug" },
  jobs = { kind = "list", key = "slug" },
}

---What is applied now.
---@class rpf.config.Current
---@field version number? The version, nil before any config.
---@field hash string? Its hash.
---@field snapshot table? The snapshot, as decoded.
---@field index table<string, table<string, any>> Each indexed section, by key.

---@type rpf.config.Current
local current = { index = {} }

---A deep copy of a decoded JSON value, keeping the array and object marks so
---the copy encodes exactly as the original did.
---@param value any The value.
---@return any copy The copy.
local function copy(value)
  if type(value) ~= "table" or value == json.null then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = copy(v)
  end
  return setmetatable(out, getmetatable(value))
end

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
      -- An absent section is empty: E3–E5 add them one at a time.
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
        local key = json.is_object(entry) and entry[section.key]
        if type(key) ~= "string" then
          return nil, name .. "[" .. i .. "] has no string " .. section.key
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
  return build_index(snapshot)
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

---An item definition, by slug.
---@param slug string The item's slug.
---@return table? item A copy of the item, or nil if the config has none by that slug.
function config.item(slug)
  return lookup("items", slug)
end

---A job, by slug.
---@param slug string The job's slug.
---@return table? job A copy of the job, or nil.
function config.job(slug)
  return lookup("jobs", slug)
end

---An employer, by slug.
---@param slug string The employer's slug.
---@return table? employer A copy of the employer, or nil.
function config.employer(slug)
  return lookup("employers", slug)
end

---A setting's effective value, by key.
---@param key string The setting's key.
---@return any value A copy of the value, or nil if unset. A setting sent as null is `json.null`, so "set to null" and "not set" stay different.
function config.setting(key)
  return lookup("settings", key)
end

rpf.config = config
return config
