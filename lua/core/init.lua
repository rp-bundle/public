---The framework's one global, and the load order of everything under it.
---
---Everything the core defines hangs off `rpf`, and nothing else is written to
---the global table: in Gmod every addon shares one Lua state, so a stray
---global collides with someone else's addon. This file runs first and creates
---the table. Every later file registers itself on it and also returns its
---table, so a loader that keeps return values (`dofile`, `include`) and one
---that discards them (a resource manifest) both work, and no file ever calls
---`require`.
---@class rpf
---@field VERSION string The core's version, reported in `Hello` as `core_version`. Compatibility is decided by the protocol version, not this.
---@field files rpf.LoadOrder The files each side loads after this one, in order.
---@field api table The public API table the platform exposes to other scripts. Only what is put here is supported; everything else under `rpf` is internal. D4 fills it.
---@field json rpf.json The bundled JSON codec.
---@field platform rpf.platform Platform interface checks.
---@field protocol rpf.protocol Frame encoding and decoding.
---@field config rpf.config Persisted config version.
---@field client rpf.client The game server's connection to the portal.
---@field connection rpf.Client? The running connection, once `start_server` has run.
---@field instance_id string? This process's instance id, once `start_server` has run.
rpf = {}

rpf.VERSION = "0.1.0"

---Which files each side loads after `init.lua`, in the order they must run.
---Order matters because a file may read an earlier file's table while it
---loads; nothing may read a later one until a function is called.
---@class rpf.LoadOrder
---@field server string[] The game server's files, relative to `lua/core/`.
---@field client string[] The player client's files, relative to `lua/core/`. The client never loads the portal connection, because it must never hold the server's API key.
rpf.files = {
  server = { "json.lua", "platform.lua", "protocol.lua", "config.lua", "client.lua" },
  client = { "json.lua", "platform.lua" },
}

rpf.api = {}

---Options for `rpf.start_server`. Everything but the url and key has a default
---suited to production, and tests shrink the timings.
---@class rpf.ServerOptions
---@field url string The portal's websocket url.
---@field api_key string The portal-issued API key (C2). A secret: never logged.
---@field client rpf.ClientOptions? Overrides for the connection's timings.

---Starts the game-server half of the core on a platform.
---
---Refuses a platform that is missing anything the server interface requires,
---naming what is missing, rather than failing later at the first call that
---needs it. The instance id is minted here, once per process start, and never
---persisted: it is what tells the portal a reconnect from a second host
---sharing the key (C1).
---@param platform rpf.ServerPlatform The engine's server platform table.
---@param options rpf.ServerOptions Where to connect, and as whom.
---@return rpf.Client connection The running connection to the portal.
function rpf.start_server(platform, options)
  rpf.platform.check(platform, "server")
  rpf.instance_id = rpf.protocol.new_id(platform)
  rpf.connection = rpf.client.new(platform, {
    url = options.url,
    api_key = options.api_key,
    instance_id = rpf.instance_id,
    options = options.client,
  })
  platform.expose(rpf.api)
  rpf.connection:start()
  return rpf.connection
end

---Starts the player-client half of the core on a platform.
---
---The same refusal rule as the server: a missing function is named now, not
---discovered at the first login. The client half has no connection of its
---own; P1 and D4 build login on the platform checked here.
---@param platform rpf.ClientPlatform The engine's client platform table.
---@return rpf.ClientPlatform platform The same platform, checked.
function rpf.start_client(platform)
  rpf.platform.check(platform, "client")
  return platform
end

return rpf
