---The framework's one global, and the load order of everything under it.
---
---Everything the core defines hangs off `rpf`, and nothing else is written to
---the global table: in Gmod every addon shares one Lua state, so a stray
---global collides with someone else's addon. This file runs first and creates
---the table. Every later file registers itself on it and also returns its
---table, so a loader that keeps return values (`dofile`, `include`) and one
---that discards them (a resource manifest) both work, and no file ever calls
---`require`.
---
---Every file also keeps this table in a local of its own (`local rpf = rpf`),
---so the core keeps working if an adapter replaces the global with the public
---API table, which is how the Gmod adapter publishes it (`platform.expose`).
---The adapter keeps its own reference to this table for the engine hooks it
---wires (`rpf.players.connected`, `rpf.players.dropped`).
---@class rpf
---@field VERSION string The core's version, reported in `Hello` as `core_version`. Compatibility is decided by the protocol version, not this.
---@field files rpf.LoadOrder The files each side loads after this one, in order.
---@field api rpf.Api The public API table the platform exposes to other scripts. Only what is in it is supported; everything else under `rpf` is internal. Built by `api.lua`.
---@field json rpf.json The bundled JSON codec.
---@field platform rpf.platform Platform interface checks.
---@field events rpf.events The event bus every module talks through.
---@field time rpf.time RFC 3339 parsing.
---@field protocol rpf.protocol Frame encoding and decoding.
---@field config rpf.config The applied config snapshot, its version, and typed lookups.
---@field client rpf.client The game server's connection to the portal.
---@field players rpf.players The players on this server and their lifecycle.
---@field commands rpf.commands The portal's staff commands, each run by the module that registered it.
---@field moderation rpf.moderation The staff actions on players that need them in game: kicks (F4).
---@field staff rpf.staff In-game staff (F9): linked staff members' permissions here, as the portal last pushed them, account linking, and staff actions reported for the audit log.
---@field manifest rpf.manifest Addon manifests and their types' records: the rules both sides hold them to (J2).
---@field records rpf.records The records this server holds (C7), and nothing else.
---@field sync rpf.sync Holds, releases and state reports for those records.
---@field accounts rpf.accounts Balances, transfers and payments on held accounts, and the ledger fold.
---@field characters rpf.characters A logged-in player's characters: list, create, select and switch.
---@field jobs rpf.jobs Characters' jobs, duty and salaries (D7).
---@field edits rpf.edits Staff edits of held records: the commands that change a character, an account or a container this server holds (F5).
---@field picker rpf.picker The client side of choosing a character.
---@field handoff rpf.handoff The login messages between server and client.
---@field join rpf.join The server side of a player's login.
---@field auth rpf.auth The client side of a player's login.
---@field connection rpf.Client? The running connection, once `start_server` has run.
---@field instance_id string? This process's instance id, once `start_server` has run.
---@field start_server fun(platform: rpf.ServerPlatform, options: rpf.ServerOptions): rpf.Client Starts the game-server half. Defined below.
---@field start_client fun(platform: rpf.ClientPlatform, options: rpf.ClientStartOptions?): rpf.ClientPlatform Starts the player-client half. Defined below.
---@field publish fun(platform: rpf.ServerPlatform|rpf.ClientPlatform) Publishes the public API through the platform. Defined by `api.lua`, which loads last.
---@field api_members fun(): table<string, string[]>, string[] The public API's member names and reserved names, for the test that holds `meta/api.lua` to them. Defined by `api.lua`.
rpf = {}

local rpf = rpf

rpf.VERSION = "0.1.0"

---Which files each side loads after `init.lua`, in the order they must run.
---Order matters because a file may read an earlier file's table while it
---loads; nothing may read a later one until a function is called. `api.lua`
---is last on both sides, because it fronts whichever modules the side loaded.
---@class rpf.LoadOrder
---@field server string[] The game server's files, relative to `lua/core/`.
---@field client string[] The player client's files, relative to `lua/core/`. The client never loads the portal connection, because it must never hold the server's API key, and never loads the server's player registry, join flow, staff grants, records, characters or jobs.
rpf.files = {
  server = {
    "json.lua",
    "platform.lua",
    "events.lua",
    "time.lua",
    "protocol.lua",
    "config.lua",
    "client.lua",
    "players.lua",
    "commands.lua",
    "moderation.lua",
    "staff.lua",
    "inventory.lua",
    "manifest.lua",
    "records.lua",
    "sync.lua",
    "accounts.lua",
    "handoff.lua",
    "join.lua",
    "characters.lua",
    "jobs.lua",
    "edits.lua",
    "api.lua",
  },
  client = {
    "json.lua",
    "platform.lua",
    "events.lua",
    "time.lua",
    "handoff.lua",
    "auth.lua",
    "picker.lua",
    "api.lua",
  },
}

---Options for `rpf.start_server`. Everything but the url and key has a default
---suited to production, and tests shrink the timings.
---@class rpf.ServerOptions
---@field url string The portal's websocket url.
---@field api_key string The portal-issued API key (C2). A secret: never logged.
---@field portal_url string? The portal's HTTP address, which players' clients log in to. Worked out from `url` when left out (`wss://host/ws` becomes `https://host`).
---@field client rpf.ClientOptions? Overrides for the connection's timings.
---@field join rpf.JoinOptions? Overrides for the login timings, such as how long a player may take to log in.
---@field sync rpf.SyncOptions? Overrides for how often held records are reported.

---Starts the game-server half of the core on a platform.
---
---Refuses a platform that is missing anything the server interface requires,
---naming what is missing, rather than failing later at the first call that
---needs it. The instance id is minted here, once per process start, and never
---persisted: it is what tells the portal a reconnect from a second host
---sharing the key (C1). The stored config is restored before the connection
---starts, so lookups answer from the last applied snapshot while the portal is
---still being reached.
---@param platform rpf.ServerPlatform The engine's server platform table.
---@param options rpf.ServerOptions Where to connect, and as whom.
---@return rpf.Client connection The running connection to the portal.
function rpf.start_server(platform, options)
  rpf.platform.check(platform, "server")
  rpf.events.bind(platform.log)
  rpf.instance_id = rpf.protocol.new_id(platform)
  rpf.connection = rpf.client.new(platform, {
    url = options.url,
    api_key = options.api_key,
    instance_id = rpf.instance_id,
    options = options.client,
  })
  rpf.players.start(platform)
  rpf.commands.serve(rpf.connection)
  rpf.moderation.start(platform)
  rpf.staff.start(platform, rpf.connection)
  rpf.sync.start(platform, rpf.connection, options.sync)
  rpf.accounts.start(platform, rpf.connection)
  rpf.join.start(platform, rpf.connection, {
    url = options.url,
    portal_url = options.portal_url,
    options = options.join,
  })
  rpf.characters.start(platform, rpf.connection)
  rpf.jobs.start(platform)
  rpf.edits.start()
  rpf.config.restore(platform)
  rpf.config.serve(platform, rpf.connection)
  rpf.publish(platform)
  rpf.connection:start()
  return rpf.connection
end

---Options for `rpf.start_client`.
---@class rpf.ClientStartOptions
---@field auth rpf.AuthOptions? Overrides for the login timings.

---Starts the player-client half of the core on a platform.
---
---The same refusal rule as the server: a missing function is named now, not
---discovered at the first login. Starting the client starts its login: it
---tells the game server it is ready, and the server answers with a join nonce.
---@param platform rpf.ClientPlatform The engine's client platform table.
---@param options rpf.ClientStartOptions? Timing overrides, for tests.
---@return rpf.ClientPlatform platform The same platform, checked.
function rpf.start_client(platform, options)
  rpf.platform.check(platform, "client")
  rpf.events.bind(platform.log)
  rpf.publish(platform)
  rpf.auth.start(platform, options and options.auth)
  rpf.picker.start(platform)
  return platform
end

return rpf
