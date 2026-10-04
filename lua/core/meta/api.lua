---@meta

-- The public `rpf` API, for server owners' language servers.
--
-- This is the documented, supported surface: what `platform.expose`
-- publishes, as the `rpf` global on Gmod and through the resource's export
-- table on FiveM. Anything under `rpf` that is not described here is internal
-- and may change in any release. Add this directory (`lua/core/meta/`) to
-- `workspace.library` and annotate the table your script holds with
-- `---@type rpf.Api` to get completion and type checking for it.
--
-- `lua/core/api.lua` builds the table, and `spec/api_spec.lua` holds this
-- file to exactly its members, so neither can drift from the other. This file
-- is a definition for the language server and is never loaded.
--
-- Nothing here names a framework, a framework's key, or an engine-specific
-- id as a portable id (#75). A player's portable id is their RPF `player_id`;
-- the engine's handle is only something to pass back to the engine.

---The public API table.
---
---What is present follows the side: `players` and `config` on the game
---server, `auth` on the player's client, and `VERSION`, `engine` and `events`
---on both. Every table in it is read-only.
---@class rpf.Api
---@field VERSION string The core's version. Informational: compatibility with the portal is the protocol version's business, not this.
---@field engine string Which engine is running: `"fivem"`, `"gmod"` or `"mock"`. Read-only, for server owners' scripts that must differ per engine; the core itself never branches on it.
---@field events rpf.api.Events The event bus. The only way scripts hear what the core does.
---@field players rpf.api.Players? The players on this game server. Server only.
---@field config rpf.api.Config? Lookups over the config the portal pushed. Server only.
---@field auth rpf.api.Auth? The player's own login. Client only.
---@field bridge rpf.api.Bridge? **Reserved for Milestone 2 (K2, #92).** Always nil in 0.1. It will register the one bridge to an existing RP framework on a companion server (see `docs/architecture/framework-integration.md`). The name is reserved now so no script claims it first.

---The event bus, shared by the core and every script.
---
---A handler that throws is logged and skipped, and the handlers after it
---still run, so one broken script cannot stop a player's join. Handlers run
---in registration order, synchronously, inside `emit`.
---
---Events the core emits (their names are reserved: scripts cannot emit them):
---
--- - `players.state_changed(player, from)`, then `players.<state>(player,
---   from)` for each move: `players.connecting`, `players.authenticating`,
---   `players.registered`, `players.character_select`, `players.active`,
---   `players.dropping`. `player` is an `rpf.PlayerView`, `from` the state it
---   left (nil for `connecting`). Server only.
--- - `config.changed(change)`, an `rpf.ConfigChange`, when an applied
---   snapshot differs from the one before. Server only.
--- - `auth.required(prompt)`, an `rpf.AuthPrompt`: show the login form.
---   `auth.succeeded(result)`, an `rpf.AuthResult`. `auth.failed(failure)`, an
---   `rpf.AuthFailure`. `auth.password_change_required(change)`, an
---   `rpf.AuthPasswordChange`. Client only.
---@class rpf.api.Events
local Events = {}

---Registers a handler, called on every later emit of the name.
---@param name string The event name, namespaced like `players.active`. Scripts use their own prefix for their own events.
---@param handler function Called with whatever the emit passes.
---@return function handler The same handler, for `off`.
function Events.on(name, handler) end

---Registers a handler for the next emit of the name only.
---@param name string The event name.
---@param handler function Called once.
---@return function handler The same handler, so it can be removed with `off` before it fires.
function Events.once(name, handler) end

---Removes every registration of a handler for a name. The function is the
---key, so a script can only remove handlers it holds.
---@param name string The event name.
---@param handler function The handler `on` or `once` was given.
---@return boolean removed Whether anything was registered.
function Events.off(name, handler) end

---Calls every handler for a name with the given arguments. Names under the
---core's prefixes (`players.`, `config.`, `auth.`, `records.`, `rpf.`) are refused with an
---error, so no script can forge a lifecycle event other scripts would believe.
---@param name string The event name.
---@param ... any Passed to every handler as is.
---@return integer failed How many handlers threw.
function Events.emit(name, ...) end

---The players on this game server. Read-only: players are moved by the core
---(the login flow) and by whichever module owns characters on the server.
---@class rpf.api.Players
local Players = {}

---One player, by the engine's handle.
---@param handle any The engine's player handle, as the engine hands it over.
---@return rpf.PlayerView? player A copy, or nil if not connected.
function Players.get(handle) end

---One player, by account.
---@param player_id string The account's uuid.
---@return rpf.PlayerView? player A copy, or nil if that account is not playing here.
function Players.by_player_id(player_id) end

---Every connected player, oldest connection first, including those still
---logging in. Check `state` (or `authenticated`) before treating one as
---logged in.
---@return rpf.PlayerView[] players Copies.
function Players.list() end

---Whether a player has logged in to their account: `registered` or later.
---Before that, nothing but the login flow may act for them.
---@param handle any The engine's player handle.
---@return boolean authenticated True from `registered` on.
function Players.authenticated(handle) end

---Where a player is in their lifecycle:
---`connecting → authenticating → registered → character_select ⇄ active`,
---and `dropping` from any of them.
---@alias rpf.PlayerState
---| "connecting" # The engine has the player; their client's core has not started.
---| "authenticating" # In the game, not logged in yet. Only the login flow is available.
---| "registered" # Logged in: `player_id` is known.
---| "character_select" # Choosing a character.
---| "active" # Playing a character.
---| "dropping" # Leaving. The last event for this connection.

---A copy of one player's record. Editing it changes nothing.
---@class rpf.PlayerView
---@field handle any The engine's handle, to pass back to engine calls. Not portable: never store it or send it anywhere as an id.
---@field serial integer Unique per connection in this process, so a timer set for one connection can tell a later connection that reused the handle.
---@field state rpf.PlayerState Where the player is.
---@field name string The in-game name when they connected.
---@field player_id string? The account's uuid, the player's portable id, from `registered` on.
---@field username string? The account's username, from `registered` on.
---@field connected_at number When they connected, in milliseconds since the Unix epoch.
---@field since number When they entered the current state, in milliseconds since the Unix epoch.
---@field reason string? Why they are leaving, once `dropping`.

---Lookups over the config the portal pushed (E2). Config is portal-
---authoritative, so these are read-only, and each returns a copy.
---@class rpf.api.Config
local Config = {}

---An item definition, by slug, with every field resolved by the portal (E3):
---the item's own value, else its base's, else the catalog default.
---@param slug string The item's slug.
---@return rpf.ConfigItem? item A copy, or nil if the config has none by that slug. Treat such an item as `item_defaults()`.
function Config.item(slug) end

---An item base, by slug: the template an item names in `base`. Reference
---data, since every item already has its base's values applied.
---@param slug string The base's slug.
---@return rpf.ConfigItemBase? base A copy, or nil if the config has none by that slug.
function Config.item_base(slug) end

---What an item the config does not define behaves as, which is what the
---portal assumes of it too.
---@return rpf.ConfigItemDefaults? defaults A copy, or nil before any config has arrived.
function Config.item_defaults() end

---A job, by slug.
---@param slug string The job's slug.
---@return table? job A copy, or nil.
function Config.job(slug) end

---An employer, by slug.
---@param slug string The employer's slug.
---@return table? employer A copy, or nil.
function Config.employer(slug) end

---A setting's effective value, by key.
---@param key string The setting's key.
---@return any value A copy, or nil if unset.
function Config.setting(key) end

---The config version applied now.
---@return number? version The version, or nil before any config has arrived.
function Config.version() end

---A grid footprint, in cells.
---@class rpf.ConfigSize
---@field x number Columns.
---@field y number Rows.

---An item as the config snapshot carries it (E3), resolved by the portal so
---no field is ever missing.
---@class rpf.ConfigItem
---@field slug string The item's id, which stacks name it by.
---@field name string Its display name.
---@field base string? The slug of the base it was resolved against, nil if it names none.
---@field weight number Weight of one unit.
---@field size rpf.ConfigSize Footprint in a grid container, before rotation.
---@field stack_limit number The most that may sit in one stack.

---An item base as the config snapshot carries it (E3): what staff wrote,
---with the fields it leaves to the defaults absent.
---@class rpf.ConfigItemBase
---@field slug string What items name the base by.
---@field name string Its display name.
---@field weight number? Weight its items take unless they set their own.
---@field size rpf.ConfigSize? Footprint its items take unless they set their own.
---@field stack_limit number? Stack limit its items take unless they set their own.

---What an item the config does not define behaves as (E3).
---@class rpf.ConfigItemDefaults
---@field weight number Weight of one unit.
---@field size rpf.ConfigSize Footprint in a grid container.
---@field stack_limit number The most that may sit in one stack.

---What `config.changed` carries.
---@class rpf.ConfigChange
---@field version number The version just applied.
---@field sections string[] The top-level sections that differ from the snapshot before, sorted, such as `items` or `settings`.

---The player's own login, on their client (P1). The client talks to the
---portal directly, so no server-side code handles the password.
---
---**That is a mitigation, not a guarantee.** The community running the
---server ships this client code, and a modified copy can capture what a
---player types. Every UI that asks a player to choose a password must show
---`PASSWORD_REUSE_WARNING` beside the field.
---
---Each function starts an attempt and returns at once; the outcome arrives as
---an `auth.*` event. The login form itself is the adapter's (Milestone 2).
---@class rpf.api.Auth
---@field PASSWORD_REUSE_WARNING string P1's warning, shown wherever a player chooses a password.
local Auth = {}

---Logs in with a username and password. Ends in `auth.succeeded`,
---`auth.failed`, or `auth.password_change_required` when staff have reset the
---password.
---@param username string The username.
---@param password string The password. Kept in memory for this attempt only (it may be resent once with a fresh nonce), never stored or logged.
---@param opts rpf.AuthLoginOptions? `remember = false` to not save a login on this device.
---@return boolean started False if refused at once.
---@return string? err Why.
function Auth.login(username, password, opts) end

---Registers a new account and logs in to it. Show `PASSWORD_REUSE_WARNING`
---where the player chooses the password.
---@param username string The username wanted.
---@param password string The password chosen.
---@param opts rpf.AuthLoginOptions? `remember = false` to not save a login on this device.
---@return boolean started False if refused at once.
---@return string? err Why.
function Auth.register(username, password, opts) end

---Changes a password, then logs in with the new one. This is also how a
---player gets past a staff reset, with the temporary password as `password`.
---Show `PASSWORD_REUSE_WARNING` where the player chooses the new password.
---A change logs the account out on every other device.
---@param username string The username.
---@param password string The current (or temporary) password.
---@param new_password string The new password.
---@param opts rpf.AuthLoginOptions? `remember = false` to not save a login on this device.
---@return boolean started False if refused at once.
---@return string? err Why.
function Auth.change_password(username, password, new_password, opts) end

---Forgets the saved login on this device and revokes it at the portal. The
---player stays in the game; the next join asks for a password.
function Auth.logout() end

---Where the login is.
---@return rpf.AuthState state The state.
function Auth.state() end

---The account this client is logged in as.
---@return rpf.AuthResult? account A copy, or nil before the server has confirmed the login.
function Auth.account() end

---The player API token (P2), for calling the portal's player API directly.
---Refreshed automatically before it expires.
---@return string? token The token, or nil before login, when the portal issues none, or once the session has ended.
function Auth.api_token() end

---Where the client's login is.
---@alias rpf.AuthState
---| "waiting" # The server has not sent a join nonce yet.
---| "required" # The player must log in or register: show the form.
---| "resuming" # Trying the saved login silently.
---| "working" # A login, registration or password change is in flight.
---| "redeeming" # The portal accepted the login; the server is redeeming the ticket.
---| "authenticated" # Logged in.

---Which request an `rpf.AuthFailure` came from.
---@alias rpf.AuthStep "login"|"register"|"resume"|"change_password"|"redeem"|"refresh"|"logout"

---Options for `login`, `register` and `change_password`.
---@class rpf.AuthLoginOptions
---@field remember boolean? False to not save a login on this device. Saved by default.

---What `auth.required` carries.
---@class rpf.AuthPrompt
---@field warning string `PASSWORD_REUSE_WARNING`, for the form to show.

---What `auth.succeeded` carries, and what `account` returns.
---@class rpf.AuthResult
---@field player_id string The account's uuid.
---@field username string The username as stored.
---@field created boolean Whether this login registered the account.

---What `auth.failed` carries. `message` may be shown to the player as is.
---A portal that cannot be reached is `portal_unreachable`, worded so it never
---reads as the player's fault.
---@class rpf.AuthFailure
---@field code string The portal's code (`invalid_credentials`, `username_taken`, `too_many_attempts`, …), or the core's own: `portal_unreachable`, `portal_error`, `invalid_nonce`, `ticket_refused`.
---@field message string Written for the player.
---@field during rpf.AuthStep Which request failed.
---@field retry_after number? Seconds to wait, when rate limited.

---What `auth.password_change_required` carries: staff reset the password,
---and the player must choose a new one through `change_password`.
---@class rpf.AuthPasswordChange
---@field username string The username that was used.
---@field message string? The portal's message, written for the player.

---**Reserved for Milestone 2 (K2, #92).** Nothing implements it in 0.1, and
---`rpf.bridge` is nil. On a companion server a bridge to an existing RP
---framework will register here, declaring which domains the framework owns
---(`provides`) and which facade calls it implements (`supports`). See
---`docs/architecture/framework-integration.md`.
---@class rpf.api.Bridge
local Bridge = {}

---Registers the one bridge for this server. Milestone 2 (K2).
---@param bridge table The bridge: `name`, `version`, `contract`, `provides`, `supports`, `start` and `stop`.
---@return boolean accepted False if the contract major or `provides` does not match this server's config.
---@return string? err Why.
function Bridge.register(bridge) end

---Refusals the domain-neutral facade returns instead of throwing. Reserved for
---Milestone 2 (K1, K2): nothing returns them in 0.1.
---@alias rpf.api.Refusal
---| "domain_external" # The domain (`characters`, `money`, `inventory`, `jobs`) is owned by an existing framework on this server, so RPF's own operation on it is refused. Use the facade, which routes to the bridge.
---| "unsupported" # The active provider does not implement this call. Check `supports` first.
