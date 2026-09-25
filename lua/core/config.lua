---The config version this server last applied, persisted across restarts.
---
---Config is portal-authoritative and replicated wholesale (E2). `Hello` carries
---the version and hash the server last applied, so a reconnect at the current
---version transfers nothing, and a matching version with a different hash
---forces a full resend, which is how silent drift is caught. Both are kept
---through `kv_set` so a restart does not cost a full snapshot. D4 adds typed
---lookups over the snapshot itself to this table.
---@class rpf.config
---@field KEY string The storage key. Namespaced, because the store is shared with whatever else the engine persists.
local config = {}

local json = rpf.json

config.KEY = "rpf.config.version"

---Reads the stored version and hash.
---
---Both or neither: a version without a hash (or the reverse) is what `Hello`
---forbids, so an entry that is not exactly a version and a hash is treated
---as nothing stored, and logged. The worst that costs is one full snapshot,
---whereas trusting it could leave a server on config it never applied.
---@param platform rpf.ServerPlatform The platform. Config is only ever held by a game server.
---@return number? version The config version, or nil on a cold start.
---@return string? hash Its hash, nil exactly when the version is.
function config.load(platform)
  local raw = platform.kv_get(config.KEY)
  if raw == nil then
    return nil, nil
  end
  local stored = json.decode(raw)
  if
    json.is_object(stored)
    and type(stored.version) == "number"
    and stored.version >= 0
    and stored.version == math.floor(stored.version)
    and type(stored.hash) == "string"
  then
    return stored.version, stored.hash
  end
  platform.log("warn", "rpf: ignoring an unreadable stored config version; the portal will send a full snapshot")
  return nil, nil
end

---Records the version and hash just applied. Called only once the snapshot is
---applied, never on receipt, so a crash in between re-fetches it.
---@param platform rpf.ServerPlatform The platform. Config is only ever held by a game server.
---@param version number The config version, a non-negative integer.
---@param hash string Its hash, exactly as the portal sent it.
function config.save(platform, version, hash)
  if type(version) ~= "number" or version < 0 or version ~= math.floor(version) or type(hash) ~= "string" then
    error("rpf: config.save needs a non-negative integer version and a string hash", 2)
  end
  local text = json.encode(json.object({ version = version, hash = hash }))
  platform.kv_set(config.KEY, text)
end

rpf.config = config
return config
