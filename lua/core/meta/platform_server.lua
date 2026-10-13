---@meta

-- The game server's platform interface. Each engine's adapter (and the mock)
-- supplies one table of this shape, annotated `---@type rpf.ServerPlatform`,
-- so the language server checks it against this file. This file is a
-- definition for the language server and is never loaded; `platform.lua`
-- holds the same list for the check that runs at start.

---An engine's player, exactly as the engine hands it over: a number on one
---engine, an entity on another. The core only passes it back to the platform.
---@alias rpf.PlayerHandle any

---Callbacks for one websocket connection.
---@class rpf.platform.SocketHandlers
---@field open fun() The connection is established and `send` will work.
---@field message fun(text: string) One text frame arrived.
---@field close fun(reason: string) The connection ended, or never opened. Called once per `connect`, and never after it.

---The websocket to the portal. One connection at a time.
---@class rpf.platform.Transport
local Transport = {}

---Opens the connection. Calls `handlers.open` once it is up, or
---`handlers.close` if it fails, and never both for a failed attempt.
---@param url string The portal's websocket url.
---@param handlers rpf.platform.SocketHandlers Where events go.
function Transport.connect(url, handlers) end

---Closes the open connection, or abandons the attempt under way, so the next
---`connect` is again the only one. Its `handlers.close` is still called, now
---or later, as for any close; the core has stopped listening to it by then.
---Does nothing when there is no connection. The core uses it when the one it
---has can no longer be trusted, such as after the host clock went back.
function Transport.disconnect() end

---Sends one text frame on the open connection.
---@param text string The frame, already encoded.
---@return boolean sent False when there is no open connection, or the engine's call failed (the platform logs why, once per connection). The core keeps the frame in its outbox either way; a `Hello` that comes back false is a failed attempt, retried after a backoff.
function Transport.send(text) end

---The best randomness the engine offers, for ids and backoff jitter.
---@class rpf.platform.Random
local Random = {}

---Random lowercase hex digits. A platform with a cryptographic source uses
---it, because envelope and instance ids are minted from this.
---@param n integer How many hex digits.
---@return string hex Exactly `n` characters from `0-9a-f`.
function Random.random_hex(n) end

---Which coroutine is running, where the engine has them, so the core can
---keep whose code is running per coroutine (`rpf.addons`) without touching
---`coroutine` itself: an addon's handler that yields must not leave its
---context on code that runs while it waits.
---@class rpf.platform.Thread
local Thread = {}

---The running coroutine, or any value naming it.
---@return any thread What the engine's `running` coroutine function returns first, or nil where the engine runs no coroutines (the mock).
function Thread.thread() end

---The players connected to this game server.
---@class rpf.platform.Players
local Players = {}

---Every identifier the engine knows for a player, verbatim. Reference data
---for staff: never used to decide who someone is.
---@param player rpf.PlayerHandle The player.
---@return string[] identifiers For example `steam:…` or `license:…`.
function Players.identifiers(player) end

---The hardware tokens the engine reports for a player, verbatim: FiveM's
---`GetPlayerTokens`, which fingerprint the machine and are specific to the
---server. An alt signal for staff (I4), which the portal hashes before it
---stores anything. An engine with none (Garry's Mod) returns an empty list.
---@param player rpf.PlayerHandle The player.
---@return string[] tokens For example `2:…` or `4:…`; empty when the engine has none.
function Players.hardware_tokens(player) end

---The player's current in-game name.
---@param player rpf.PlayerHandle The player.
---@return string name As the engine reports it.
function Players.name(player) end

---Disconnects a player.
---@param player rpf.PlayerHandle The player.
---@param reason string Shown to the player.
function Players.kick(player, reason) end

---Shows a player a message in game.
---@param player rpf.PlayerHandle The player.
---@param message string The text.
function Players.notify(player, message) end

---Messages between this server and its players' clients. Payloads are
---strings, so every engine carries the same bytes and the core owns the
---encoding, exactly as it does for JSON.
---@class rpf.platform.ToClients
local ToClients = {}

---Sends a message to one player's client.
---@param player rpf.PlayerHandle The recipient.
---@param name string The message name, namespaced `rpf:`.
---@param payload string The message, already encoded.
function ToClients.to_client(player, name, payload) end

---Registers the handler for one message name from clients. The platform
---supplies the sender; a client never names itself.
---@param name string The message name, namespaced `rpf:`.
---@param handler fun(player: rpf.PlayerHandle, payload: string) Called for each message. The payload is hostile input.
function ToClients.on_client(name, handler) end

---Registers the answerer for one request name from clients: the other half
---of the client's `request_server` (J10). The platform pairs the answer
---with the request and supplies the sender, as for `on_client`; on FiveM it
---is ox_lib's `lib.callback.register`, so a client reaches the name only
---through it. A request whose payload is not a string never reaches the
---handler.
---@param name string The request's name, namespaced `rpf:`.
---@param handler fun(player: rpf.PlayerHandle, payload: string, respond: fun(reply: string)) Called for each request. The payload is hostile input. The handler calls `respond` exactly once, with the answer encoded; the core always answers, so a client's request never holds anything open.
function ToClients.on_client_request(name, handler) end

---Asks one player's client something and hears its one answer: the other
---half of the client's `on_server_request` (J10), for the UI an addon
---shows a player from the server (`rpf.ui`). Numbered messages on both
---engines (net events on FiveM, `net` on Gmod), not ox_lib's callbacks,
---which keep a request nobody answers for good: the platform forgets one
---when the player leaves or after a while, and takes an answer only from
---the player it asked. The core keeps its own timeout, and checks the
---answer as hostile input.
---@param player rpf.PlayerHandle The player.
---@param name string The request's name, namespaced `rpf:`.
---@param payload string The request, already encoded.
---@param callback fun(reply: string?) Called at most once, with the client's answer, or nil if the platform knows none will come. Never inside the call.
function ToClients.request_client(player, name, payload, callback) end

---Commands a player runs on this server.
---@class rpf.platform.Commands
local Commands = {}

---Registers a command players run, by typing its name in chat (`/rpflink
---code`) or in the console, as the engine offers (F9, #198). The platform
---calls `handler` once per run, for a connected player and never for the
---server console or RCON, since the handlers act for a player. `args` are
---the words after the name, as the engine split them, and are hostile
---input, often a credential: **the platform never logs them, never
---repeats them to anyone, and keeps the line out of the chat other players
---see.** Registering a name again replaces its handler. The handler
---answers through `notify`.
---@param name string The command's name without a prefix, lowercase: `[a-z][a-z0-9_]*`.
---@param handler fun(player: rpf.PlayerHandle, args: string[]) Called for each run.
function Commands.on_command(name, handler) end

---What the engine can do with the game world for addons (J3), each a
---function, or `false` where this adapter does not support it: the core
---never branches on the engine, so an engine difference is one of these.
---`rpf.api.capabilities()` tells addons which are there.
---
---Beside them the adapter states the scale of the engine's positions, which
---is a fact about the engine and not something it can decline to support.
---@class rpf.platform.World
---@field capabilities rpf.Capabilities What it can do.
---@field map string The map this process runs (#369), reported in `Hello`: `game.GetMap()` on Gmod, the owner's `rpf_map` convar on FiveM (`default` unset). Fixed until the core stops, so read once as the adapter starts; a map change is a new process. One that is no map's name (1 to 64 bytes of printable ASCII with no space) is logged and reported as `default`.
---@field units_per_metre number How many of the engine's units are one metre: 1 where positions are metres (FiveM), about 39.37 where they are inches (Gmod's Hammer units). A positive, finite number. The core multiplies every distance an addon gives in metres by it (`rpf.api.world.units`, an interaction's `distance`, a zone's radius) so an addon never tells engines apart.

---The game-world capabilities an adapter declares (J3), each a function or
---`false`, and the UI its clients show (J10), each `true` or `false`. One
---not supported is `false`, never missing, so an adapter says so on
---purpose.
---@class rpf.Capabilities
---@field heading (fun(player: rpf.PlayerHandle): number?)|false? Server-trusted facing in degrees for placement.
---@field position (fun(player: rpf.PlayerHandle): { x: number, y: number, z: number }?)|false A player's position in the world, in the engine's units, or nil while they have none (not spawned).
---@field bucket (fun(player: rpf.PlayerHandle): integer?)|false A player's routing bucket (J4): the world they are in, where the engine has more than one. `false` on an engine with one world, where every player is in bucket 0.
---@field model (fun(name: string): (number|string)?)|false The engine's id for a model name, as `entity` reports a model (a hash on FiveM, a lowercased path on Gmod), so a target rule written with names can be compared with an entity.
---@field entity (fun(ref: integer): { position: { x: number, y: number, z: number }, model: (number|string)?, bucket: integer?, placement: string? }?)|false A networked entity, by its ref: the number the engine names it by on every machine (a network id on FiveM, an entity index on Gmod). Nil when the ref names nothing. `placement` is the record id the adapter tagged it with, for one `spawn` placed.
---@field spawn (fun(spec: rpf.world.Spawn, done: fun(ref: integer?, err: string?)))|false Places a record's entity, server-authoritative, tagged with the record's id for its clients, and hands `done` its ref, or nil and why (`no_model` when the record has no model for this engine), once: at once, or later where the engine makes entities asynchronously (FiveM), within a bounded wait.
---@field despawn (fun(ref: integer))|false Removes an entity `spawn` placed. A ref that names nothing, or something `spawn` did not place, is left alone.
---@field notify boolean Whether this engine's clients show an addon's notification (`rpf.ui`, J10). The client's adapter builds it (`rpf.ClientPlatform.ui`); the server only says whether it can.
---@field menu boolean Whether they show a menu to pick from.
---@field input boolean Whether they show an input dialog.
---@field progress boolean Whether they show a progress bar.

---Everything the game-server half of the core needs from its engine.
---`rpf.start_server` refuses a table missing any of it.
---@class rpf.ServerPlatform: rpf.platform.Engine, rpf.platform.Transport, rpf.platform.Http, rpf.platform.Clock, rpf.platform.Storage, rpf.platform.Random, rpf.platform.Thread, rpf.platform.World, rpf.platform.Players, rpf.platform.ToClients, rpf.platform.Commands, rpf.platform.Log, rpf.platform.Api
