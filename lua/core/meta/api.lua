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
---What is present follows the side: `players`, `staff`, `config`,
---`addons`, `records`, the facade and `world` on the game server, `auth` on
---the player's client, and `VERSION`, `engine`, `events`, `time`,
---`interactions` (`register` on the server, `send` and `request` on the
---client), `ui` and `capabilities` on both. Every table in it is
---read-only; through FiveM's export it is a plain copy, which a script may
---change without changing the API anyone else holds.
---
---**Nothing in it throws.** A call that cannot do what was asked returns nil
---(or false) and a reason, a short string such as `"invalid"`, documented on
---each call, so an addon's mistake is a value it can log, never an error in
---the middle of a player's join.
---@class rpf.Api
---@field VERSION string The core's version. Informational: compatibility with the portal is the protocol version's business, not this.
---@field engine string Which engine is running: `"fivem"`, `"gmod"` or `"mock"`. Read-only, for server owners' scripts that must differ per engine; the core itself never branches on it.
---@field events rpf.api.Events The event bus. The only way scripts hear what the core does.
---@field time rpf.api.Time The clock, and timers that run on every engine alike.
---@field addons rpf.api.Addons Lua addons: registering one with its manifest, its state, and exports between addons (J1–J3). Server only.
---@field records rpf.api.Records The records of addons' types: read, query, hold, and write the live ones this server holds (J3). Server only.
---@field characters rpf.api.Characters The domain-neutral facade (#75, J3): the character a player has in play. Server only.
---@field money rpf.api.Money The domain-neutral facade: a player's money, and moving it. Server only.
---@field inventory rpf.api.Inventory The domain-neutral facade: a player's items, and moving them. Server only.
---@field jobs rpf.api.Jobs The domain-neutral facade: a player's job. Server only.
---@field ops rpf.api.Ops Operation ids, which make the facade's commands safe to send again. Server only.
---@field commerce rpf.api.Commerce Exchanges: money and items moved together, with your change to your own records, in one intent (J5). For shops, buy-back counters, crafting and other trades. Server only.
---@field world rpf.api.World The game world, through what the engine's adapter supports (J3). Server only.
---@field interactions rpf.api.Interactions Requests a player's client makes to an addon: `register` a handler on the server, `send` or `request` on the client (J3, J10).
---@field dialogs rpf.api.Dialogs Conversations with NPCs, from the trees staff build in the panel (L1): open one for a player. An NPC whose world type names a `dialog` field talks without this. Server only.
---@field placement rpf.api.Placement Staff placement menu (L4). Server only.
---@field actions rpf.api.Actions What your addon can be asked to do by a dialog choice staff build in the panel: the handlers of the actions your manifest declares (L1). Server only.
---@field capabilities fun(): table<string, boolean> What this engine supports, by name: the game world's `position`, `bucket`, `model`, `entity`, `spawn` and `despawn` (server only), and the UI `notify`, `menu`, `input` and `progress` (both sides). Ask before offering a player something that needs one; a call to one that is missing says `unsupported`.
---@field ui rpf.api.Ui Notifications, menus, input dialogs and progress bars that look right on every engine (J10): on the client for the player, on the server for a player you name.
---@field players rpf.api.Players? The players on this game server. Server only.
---@field staff rpf.api.Staff? In-game staff: what a linked staff member may do here, account linking, and staff actions for the audit log. Server only.
---@field config rpf.api.Config? Lookups over the config the portal pushed, and linked staff's edits of it in game. Server only.
---@field auth rpf.api.Auth? The player's own login. Client only.
---@field items rpf.api.Items? The server's item catalog and item images, as the player's client sees them (P3). Client only.
---@field bridge rpf.api.Bridge The bridge to an existing RP framework (K2): how a bridge registers, and reports what its framework does. For bridge authors; an addon uses the facade, which routes to it. Server only.

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
--- - `config.edit_applied(result)` and `config.edit_discarded(result)`, an
---   `rpf.ConfigEditResult`, when the portal applied a staff member's
---   in-game config edit, or discarded it because the config had moved on;
---   `config.edit_refused(failure)`, an `rpf.ConfigEditFailure`, when it
---   refused one or never answered. The staff member has been told either
---   way. Server only.
--- - `addons.state(change)`, an `rpf.AddonStateChange`, whenever a loaded
---   addon's state changes (it started, it stopped, staff disabled it, …).
---   Server only.
--- - `records.created(change)`, `records.changed(change)` and
---   `records.deleted(change)`, an `rpf.RecordChange`, after a live addon
---   record held here was created, changed or deleted: by an addon, by a
---   staff edit from the portal, or (`records.changed`, `by = "portal"`)
---   put back because the portal refused its deletion. Server only.
--- - `interactions.result(result)`, an `rpf.InteractionResult`, when the
---   server answered an interaction this client sent with `send`, or the
---   answer did not come in time (`timeout`). Client only.
--- - `staff.changed(change)`, an `rpf.StaffChange`, once for each player
---   whose staff permissions here changed: a push from the portal gave them
---   new ones or took some away, or they left. Server only.
--- - `staff.linked(link)`, an `rpf.StaffLinked`, when a player's account was
---   linked to a staff account, and `staff.link_failed(failure)`, an
---   `rpf.StaffLinkFailure`, when it was not. The player has been told
---   either way. Server only.
--- - `domains.op_unknown(unknown)`, an `rpf.OpUnknown`, when a facade
---   command's result is `unknown`: it threw, its provider could not say,
---   its `apply` failed after it went through, or a restart cut it off (at
---   start, before any addon has subscribed: `rpf.ops.unknown()` lists those
---   too). Staff must resolve it by hand. Server only.
--- - `domains.bridge(change)`, an `rpf.BridgeState`, when the bridge became
---   active, its framework unavailable or available again, or it was
---   withdrawn. Server only.
--- - `auth.required(prompt)`, an `rpf.AuthPrompt`: show the login form.
---   `auth.succeeded(result)`, an `rpf.AuthResult`. `auth.failed(failure)`, an
---   `rpf.AuthFailure`. `auth.password_change_required(change)`, an
---   `rpf.AuthPasswordChange`. `auth.account_deleted(deleted)`, an
---   `rpf.AuthDeleted`, once `delete_account` has deleted the account.
---   Client only.
---
---**Both sides.**
---@class rpf.api.Events
local Events = {}

---Registers a handler, called on every later emit of the name. A handler
---an addon registers while its code runs (its `start`, a timer, another
---handler) is the addon's, and is removed when the addon stops, so an addon
---that subscribes in `start` is subscribed once however often it restarts.
---
---```lua
---rpf.events.on("players.active", function(player)
---  -- player is an rpf.PlayerView: a copy, safe to keep
---  greet(player.handle, player.name)
---end)
---```
---@param name string The event name, namespaced like `players.active`. Scripts use their own prefix for their own events.
---@param handler function Called with whatever the emit passes.
---@return function|string|nil handler The same handler, for `off`. Through FiveM's export, a subscription id instead, since a function does not keep its identity across that boundary (`lua/platform/fivem/README.md`). Nil if refused.
---@return "invalid"|"inactive"|nil err `invalid` for a name that is not a non-empty string, or a handler that is not a function; `inactive` from code of an addon activation that has ended.
function Events.on(name, handler) end

---Registers a handler for the next emit of the name only.
---@param name string The event name.
---@param handler function Called once.
---@return function|string|nil handler The same handler, so it can be removed with `off` before it fires. A subscription id through FiveM's export. Nil if refused.
---@return "invalid"|"inactive"|nil err As for `on`.
function Events.once(name, handler) end

---Removes every registration of a handler for a name. The function is the
---key, so a script can only remove handlers it holds.
---@param name string The event name.
---@param handler function|string The handler `on` or `once` was given, or the id they returned through FiveM's export.
---@return boolean removed Whether anything was registered.
function Events.off(name, handler) end

---Calls every handler for a name with the given arguments. Names under the
---core's prefixes (`players.`, `config.`, `auth.`, `records.`, `characters.`, `jobs.`, `staff.`, `addons.`, `domains.`, `interactions.`, `rpf.`) are refused,
---so no script can forge a lifecycle event other scripts would believe; so
---is a name under a loaded addon's namespace when the caller is known to be
---another addon (a handler the core runs for one, or, on FiveM, any call
---from another addon's resource), so one addon cannot forge another's
---events.
---@param name string The event name.
---@param ... any Passed to every handler as is.
---@return integer? failed How many handlers threw, or nil if refused.
---@return rpf.EmitRefusal? err Why it was refused.
function Events.emit(name, ...) end

---Why `events.emit` refused.
---@alias rpf.EmitRefusal
---| "invalid" # The name is not a non-empty string.
---| "reserved" # The name is under one of the core's prefixes.
---| "forbidden" # The name is under another loaded addon's namespace.

---The clock, and timers on the platform's clock, so a script's timer
---behaves alike on every engine. A timer an addon starts while its code
---runs is the addon's, and is cancelled when it stops. A callback that
---throws is logged; an `every` keeps going. On FiveM, where a function
---crossing an export becomes a reference, ids are strings for that reason.
---
---**Both sides.**
---@class rpf.api.Time
local Time = {}

---The wall clock.
---@return number? now Milliseconds since the Unix epoch, an integer; nil only before the adapter has loaded.
function Time.now() end

---Runs a function once, later.
---@param delay_ms integer Milliseconds, a whole number from 0 to 2147483647 (about 24.8 days).
---@param fn function What to run.
---@return string? id The timer, for `cancel`.
---@return rpf.TimerRefusal? err Why not.
function Time.after(delay_ms, fn) end

---Runs a function every period, the first time one period from now, until
---cancelled or its addon stops.
---@param period_ms integer Milliseconds, a whole number from 10 to 2147483647.
---@param fn function What to run.
---@return string? id The timer, for `cancel`.
---@return rpf.TimerRefusal? err Why not.
function Time.every(period_ms, fn) end

---Cancels a timer. Cancelling one that already ran or was cancelled is
---harmless.
---@param id string The id `after` or `every` returned.
---@return boolean cancelled True if it was still to run.
function Time.cancel(id) end

---How much time has passed since a moment your record stored, at most
---`max_ms`: how a timed record keeps time across restarts, which end every
---timer. Store the moment you last counted in a `timestamp` field, and on
---each tick count what passed since it and store `now`. The bound is the
---most one tick catches up after an outage or a restart (a plant grows at
---most that much at once); a clock that stepped back counts as nothing.
---
---```lua
---local spent, now = rpf.time.elapsed(plant.fields.ticked_at, 5 * 60000)
---rpf.records.update("acme_garden.plant", plant.id, { grown_ms = plant.fields.grown_ms + spent, ticked_at = now })
---```
---@param since integer The moment last counted, milliseconds since the Unix epoch.
---@param max_ms integer? The most to count; no bound if nil.
---@return integer? elapsed Milliseconds passed, from 0 to `max_ms`.
---@return integer|"invalid"|"unavailable" now The clock it was measured on, or why not.
function Time.elapsed(since, max_ms) end

---Why `time.after` or `time.every` refused.
---@alias rpf.TimerRefusal
---| "invalid" # The delay or period is not a whole number in range, or `fn` is not a function.
---| "unavailable" # The adapter has not loaded yet.
---| "inactive" # Called from code of an addon activation that has ended.

---Lua addons (`docs/architecture/addons.md`). An addon is a package with a
---manifest: the types, fields and permissions it declares. It registers the
---manifest here when it loads; the game server proposes it to the portal,
---staff install it there, and only then does it run: its `start` handler is
---called once the portal has it installed and enabled at exactly the
---manifest it registered, with everything it `requires` running.
---
---```lua
----- `rpf` is the API: the `rpf` resource's `api` export on FiveM, a global on Gmod
---rpf.addons.register(MANIFEST, {
---  start = function() rpf.time.every(60000, fade) end, -- stopped for you when it stops
---  stop = function(reason) save_scores(reason) end,
---})
---```
---
---Registering the same namespace again is a reload: the old code stops and
---the new starts. On FiveM an addon whose resource stops is unloaded with
---it. Whatever an addon set up while its code ran (timers, event handlers,
---exports) is taken down when it stops.
---
---**Server only.**
---@class rpf.api.Addons
---@field API integer The newest addon API major this core serves: what a new addon writes as its manifest's `api`.
---@field API_MIN integer The oldest addon API major it still serves. An addon written for a major outside `API_MIN`..`API` stays in state `api` (`docs/compatibility.md`).
local Addons = {}

---Registers an addon with its manifest and the handlers the core runs for
---it. Never throws: a manifest the shared rules refuse comes back with the
---rule it breaks and where.
---@param manifest rpf.AddonManifest The manifest.
---@param handlers rpf.AddonHandlers? What to run when it starts, stops or changes state.
---@return boolean? ok True once registered, which is not running: see `state`.
---@return rpf.AddonRefusal? refusal Why not.
function Addons.register(manifest, handlers) end

---Where an addon is, and why.
---@param namespace string The addon's namespace.
---@return rpf.AddonState? state Nil if no addon of that namespace is loaded here.
---@return string? reason Why, written for a server owner; nil when active.
function Addons.state(namespace) end

---Provides a function other addons call by name (`call`), so addons on
---either engine share code the same way. The name is under the addon's own
---namespace; one provided while its code runs goes when it stops.
---@param name string `<namespace>.<name>`, both identifiers.
---@param fn function The function. It runs in the providing addon's context; what it returns goes back to the caller (copied, through FiveM's export).
---@return boolean? ok True once provided.
---@return "invalid"|"not_found"|"forbidden"|"inactive"|nil err `invalid` for a bad name or a value that is not a function, `not_found` when no addon of that namespace is loaded, `forbidden` for another addon's namespace, `inactive` from code of an activation that has ended.
function Addons.provide(name, fn) end

---Calls a function another addon provides, while that addon is active.
---Never throws: a function that throws is logged and comes back as
---`false, "failed"`.
---@param name string `<namespace>.<name>`.
---@param ... any Its arguments.
---@return boolean ok True if it ran.
---@return any ... What it returned; or, when `ok` is false, why: `"not_found"`, `"inactive"` or `"failed"`.
function Addons.call(name, ...) end

---The records of addons' types (`docs/architecture/addons.md`). Every call
---names the type, so an addon keeps no handle (on FiveM it could not), and
---what comes back is a plain copy: a field with no value is absent.
---
---A `config` type's records are staff's, written in the portal and read
---here. A `live` type's records are game state: this server writes only
---those it **holds**, and the portal has each change in the next report.
---Nothing throws: a call that cannot do what it was asked returns nil, a
---reason, and for `invalid` the rule broken.
---
---```lua
---local tag, err, rule = rpf.records.create("acme_tags.tag", { text = "hi", spot = pos, fades_at = rpf.time.now() + DAY },
---  { owner = { kind = "player", id = player.player_id } })
---if not tag then return false, err end
---for _, old in ipairs(rpf.records.list("acme_tags.tag", { where = { fades_at = { lt = rpf.time.now() } } })) do
---  rpf.records.delete("acme_tags.tag", old.id)
---end
---```
---
---**Server only.**
---@class rpf.api.Records
local Records = {}

---One record: a config type's, or a live one this server holds.
---@param type string The type's full name, `<namespace>.<name>`.
---@param id string The record's id.
---@return rpf.Record? record A copy.
---@return rpf.RecordRefusal? err `not_found`, `inactive`, or `not_held` for a live record this server does not hold (`query` finds those, `hold` takes one).
function Records.get(type, id) end

---The records of a type here, read locally: every record of a config type,
---or every held record of a live one, that meets the query. Any field may
---be filtered or ordered on here. Records with no value for the order field
---come last; ties go by id.
---@param type string The type.
---@param query rpf.RecordQuery? What to keep, and in what order.
---@return rpf.Record[]? records Copies.
---@return rpf.RecordRefusal? err `not_found`, `inactive`, or `invalid`.
---@return table? rule For `invalid`, what was wrong: `{ error = "query", field = … }`.
function Records.list(type, query) end

---Asks the portal for a live type's records, including those this server
---does not hold, one page at a time. Filters and order must be on indexed
---fields. To change one, `hold` it first.
---@param type string The type.
---@param query rpf.RecordQuery? What to find; `limit` up to 100 a page, `after` the `next` the last page came with.
---@param callback fun(records: rpf.QueriedRecord[]?, next: table?, err: string?) Called once: a page and the cursor for the next (nil after the last), or nil and why.
---@return boolean? ok True once the question is on its way.
---@return rpf.RecordRefusal? err `not_found`, `inactive`, `invalid`, or `outbox_full` / `outbox_unavailable`.
function Records.query(type, query, callback) end

---Holds live records, so this server may change them until it releases
---them. The portal refuses the whole hold if any is not this server's, or
---is held by another server.
---@param type string The type.
---@param ids string[] 1 to 64 records' ids.
---@param callback fun(records: rpf.Record[]?, err: string?)? Called once: copies of those now held, or nil and the portal's refusal.
---@return boolean? ok True once the hold is on its way.
---@return rpf.RecordRefusal? err `not_found`, `inactive` or `invalid`.
function Records.hold(type, ids, callback) end

---Lets held records go, each with its final state, for the portal (and
---staff) to write. An addon's records held for the server are released for
---it when it stops.
---@param type string The type.
---@param ids string[] 1 to 64 records' ids.
---@return boolean? ok True once every one named is released.
---@return string? err `not_found`, `inactive`, `invalid`, or why some stayed held: `outbox_full`, `too_large`, `creating` (its create has not reached the portal yet).
function Records.release(type, ids) end

---Makes a live record, held by this server from the start; the portal has it
---once the next report carries it. Its fields are checked whole first.
---@param type string The type.
---@param fields table The fields, by name. Unset ones take their defaults.
---@param opts rpf.RecordCreateOptions Who owns it, and its id if you mint one.
---@return rpf.Record? record A copy of the new record.
---@return rpf.RecordRefusal? err Why not.
---@return table? rule For `invalid`, the rule broken, as the portal names it (`{ error = "too_long", field = "text" }`, `{ error = "owner" }`).
function Records.create(type, fields, opts) end

---Changes fields of a held record: only those the patch names, the record
---checked whole after.
---@param type string The type.
---@param id string The record's id.
---@param patch table? The fields to set, by name.
---@param opts rpf.RecordWriteOptions? `revision` to refuse a stale write, `clear` to clear fields.
---@return rpf.Record? record A copy of the record now, with its new revision.
---@return rpf.RecordRefusal? err Why not.
---@return table? rule For `invalid`, the rule broken.
function Records.update(type, id, patch, opts) end

---Deletes a held record. If another live record refers to it, the portal
---refuses, the record comes back, and `records.changed` says so.
---@param type string The type.
---@param id string The record's id.
---@param opts rpf.RecordWriteOptions? `revision` to refuse a stale delete.
---@return boolean? ok True once it is gone here.
---@return rpf.RecordRefusal? err Why not.
function Records.delete(type, id, opts) end

---Writes several records all or nothing: every write is checked first, and
---if one would be refused none is made. They then go to the portal together,
---in one report when they fit one frame.
---@param ops rpf.RecordOp[] 1 to 64 writes, each record at most once.
---@return (rpf.Record|boolean)[]? results For each write: the record, or true for a delete.
---@return rpf.RecordRefusal? err The first refusal.
---@return table? detail `{ index = n, … }`: which write (0 for the batch itself), and for `invalid` the rule.
function Records.batch(ops) end

---A record as a script gets it.
---@class rpf.Record
---@field id string Its id, a uuid.
---@field type string Its type's full name.
---@field owner { kind: string, id: string }? Who owns it: a live record's owner. A config record has none.
---@field revision number Moves on every change made to it; name it in `update`'s `opts.revision` to refuse a stale write.
---@field fields table Its fields, every default filled in. A field with no value is absent. A `json` field is opaque data kept whole: a null inside it is the codec's null (`{}` through FiveM's export), and writing the value back unchanged keeps it as stored.

---A record a `query` found: as the portal has it.
---@class rpf.QueriedRecord: rpf.Record
---@field held boolean Whether this server holds it; if so, `get` has the newer copy.

---What `list` and `query` keep.
---@class rpf.RecordQuery
---@field where table<string, any>? By field: a value (equal), or comparisons, `{ gte = 1, lt = 5 }`, of `eq`, `lt`, `lte`, `gt`, `gte`, `prefix`. All must hold.
---@field owner { kind: string, id: string }? Only this owner's records.
---@field order string? The field to order by; by id otherwise.
---@field descending boolean? Largest first.
---@field limit integer? At most this many.
---@field after table? `query` only: the `next` the page before came with.

---Options for `create`.
---@class rpf.RecordCreateOptions
---@field owner { kind: "player"|"character"|"employer"|"server", id: string } Who owns it: a kind the type's `owners` lists.
---@field id string? Its id, a lowercase uuid, if you mint one (to make a create you may retry); minted otherwise.

---Options for `update` and `delete`.
---@class rpf.RecordWriteOptions
---@field revision number? Refuse as `stale` unless the record is still at this revision.
---@field clear string[]? `update` only: nullable fields to clear.

---One write in a `batch`.
---@class rpf.RecordOp
---@field op "create"|"update"|"delete" What to do.
---@field type string The record's type.
---@field id string? The record's id: required to update or delete.
---@field fields table? A create's fields.
---@field owner table? A create's owner.
---@field patch table? An update's fields.
---@field clear string[]? An update's fields to clear.
---@field revision number? An update's or delete's expected revision.

---Why a records call refused.
---@alias rpf.RecordRefusal
---| "not_found" # No such installed type, or no such config record.
---| "inactive" # The type's addon is not running here.
---| "not_held" # This server does not hold that live record (it may exist: `query`, then `hold`).
---| "stale" # The record moved on since the revision named.
---| "invalid" # The write breaks a rule of the type, or a query is not one: the third value says which.
---| "conflict" # A create named an id this server already holds.
---| "limit" # The type's `limit` of records is held here already.
---| "busy" # A batch named a record whose create or last whole report the portal has not answered yet; a moment later it can go.
---| "outbox_full" # Too much is waiting for the portal; try again later.
---| "unknown" # A batch write failed after it was checked; logged. Should not happen.

---What a `records.*` event carries.
---@class rpf.RecordChange
---@field type string The record's type.
---@field id string The record's id.
---@field record rpf.Record? The record now; nil for a deletion.
---@field by "addon"|"staff"|"portal" Who changed it.
---@field reason string? For a deletion the portal refused, the portal's refusal code: `referenced` when another record refers to it, or what refused the frame it was in (`malformed`, `forbidden`, `not_found`, …), as the portal sent it. `refused` when the frame deleted several records and one was referenced, so which is not known.
---@field detail string? For a deletion the portal refused, the portal's own words, for the log; branch on `reason`.

---**The domain-neutral facade** (`docs/architecture/framework-integration.md`).
---How an addon reaches a player's character, money, items and job, whoever
---owns them on this server: RPF itself, or (with K2) an existing framework
---through a bridge. Write against these and the addon runs on both.
---
---Every call takes the engine's handle of a player who has logged in, and
---acts on the character they have in play. A read returns its value, or nil
---and why. A command returns `true`, or nil, a status and a reason:
---
--- - `refused`: nothing changed, and the reason says why (`insufficient_funds`,
---   `no_space`, `unsupported`, …).
--- - `unavailable`: nothing changed; whoever owns the domain could not be
---   asked. Trying again later is fine.
--- - `unknown`: it may have happened. Never send it again with a new op id,
---   and never grant what it paid for: staff resolve it.
---
---Every command names an op id from `rpf.ops.new()`, minted once per thing
---the player is doing. Sending the same op id again returns the first
---answer and never runs twice, so a retry is never a second payment.
---
---**Paying for a change to your own records** (a composite operation) is
---one command with an `apply` after its op id. Hold the record and check
---everything first, so `apply` cannot fail; `apply` runs only once the
---money (or the items) moved, inside the same journaled intent, and the
---intent completes once what it wrote is on its way to the portal. If the
---server dies in between, or `apply` throws or answers nil, the command is
---`unknown` and staff resolve it: nothing is refunded automatically, since
---nothing can tell a lost payment from a lost grant.
---
---```lua
---local op = rpf.ops.new()
---local ok, status, why = rpf.money.debit(player, "bank", 500, "Gold badge", op, function()
---  return rpf.records.update("acme_badges.badge", badge.id, { label = "Gold" }, { revision = badge.revision })
---end)
---```
---
---```lua
---local op = rpf.ops.new() -- once per payment, kept with it
---local ok, status, why = rpf.money.debit(player, "bank", 250, "Parking fine", op)
---if status == "refused" then
---  -- tell the player why: why == "insufficient_funds", …
---end
---```
---
---To sell an item for money, use `rpf.commerce.exchange`, which moves both in
---one intent: a debit followed by a separate give can take the money and
---then find the player has no room.
---
---**Server only.**
---@class rpf.api.Characters
local Characters = {}

---The character a player has in play.
---@param player any The engine's handle.
---@return { key: string, name: string }? character `key` names it, opaque (an RPF character's id here, a framework's own key on a companion server); `name` its full name.
---@return rpf.FacadeRead? err Why there is none.
function Characters.current(player) end

---Whether a call works on this server, before offering a player anything
---that needs it.
---@param call string `current`.
---@return boolean supported True if it does.
function Characters.supports(call) end

---A player's money. Accounts are named by whoever owns money here: `accounts`
---lists them, so an addon configures which it uses rather than naming one.
---
---**Server only.**
---@class rpf.api.Money
local Money = {}

---The names of the accounts a player's money is in (`wallet`, `bank`).
---@return string[] names The names.
function Money.accounts() end

---A player's balance in one account.
---@param player any The engine's handle.
---@param account string The account's name.
---@return number? balance The balance, in the server's smallest currency unit.
---@return rpf.FacadeRead? err Why not.
function Money.balance(player, account) end

---Takes money from a player. On an RPF server it goes to the paying account
---the server's `economy.addon_account` setting names; without one, debits
---are `unsupported`.
---@param player any The engine's handle.
---@param account string The player's account's name.
---@param amount integer A whole amount from 1 to 2^53 − 1.
---@param reason string Why, for the player's statement and staff; at most 256 bytes.
---@param op_id string From `rpf.ops.new()`.
---@param apply (fun(): any)? Your change this pays for: run once the money moved, in the same intent. Answer non-nil (what `rpf.records.update` returns does); nil, false or a throw make the debit `unknown`.
---@return boolean? ok True once taken (and applied).
---@return rpf.FacadeStatus? status Why not.
---@return string? reason For `refused`: `invalid`, `invalid_op`, `expired_op`, `journal_full`, `not_logged_in`, `no_character`, `no_account`, `unsupported`, `insufficient_funds`, `out_of_range`.
function Money.debit(player, account, amount, reason, op_id, apply) end

---Pays money to a player, from the account `economy.addon_account` names.
---@param player any The engine's handle.
---@param account string The player's account's name.
---@param amount integer A whole amount from 1 to 2^53 − 1.
---@param reason string Why; at most 256 bytes.
---@param op_id string From `rpf.ops.new()`.
---@param apply (fun(): any)? Your change this goes with, as for `debit`.
---@return boolean? ok True once paid (and applied).
---@return rpf.FacadeStatus? status Why not.
---@return string? reason For `refused`, as for `debit`.
function Money.credit(player, account, amount, reason, op_id, apply) end

---Moves money from one player to another, from an account to the other
---player's account of the same name, as one ledger entry: cash handed
---over. Both statements carry `reason`. It is RPF's own: where a framework
---owns money (a companion server) it is `unsupported`, since no bridge can
---make it one change.
---
---Whether the two are near each other is yours to decide, from
---`rpf.world.position`; a player's client may name anyone.
---
---```lua
---local op = rpf.ops.new()
---local ok, status, why = rpf.money.transfer(player.handle, other, "wallet", 50, "Cash from Ann Lee", op)
---```
---@param player any The engine's handle of the player paying.
---@param target any The engine's handle of the player paid: another logged-in player with a character in play.
---@param account string The account's name on both sides (`rpf.money.accounts()`).
---@param amount integer A whole amount from 1 to 2^53 − 1.
---@param reason string Why, for both statements and staff; at most 256 bytes.
---@param op_id string From `rpf.ops.new()`.
---@return boolean? ok True once moved.
---@return rpf.FacadeStatus? status Why not.
---@return string? reason For `refused`: `invalid`, `invalid_op`, `expired_op`, `journal_full`, `unsupported`, `not_logged_in`, `no_character`, `no_target` (the target is not another logged-in player with a character in play), `no_account` (either side has no account of that name), `insufficient_funds`, `out_of_range`.
function Money.transfer(player, target, account, amount, reason, op_id) end

---Whether a call works on this server: `debit` and `credit` need the
---server's addon account set, and `transfer` RPF's own money (not a
---framework's, through a bridge).
---@param call string `accounts`, `balance`, `debit`, `credit` or `transfer`.
---@return boolean supported True if it does.
function Money.supports(call) end

---A player's items. `count`, `give` and `take` deal in plain units by item
---slug: a stack carrying data (a bottle with a note) is a thing of its own
---they leave alone.
---
---**Stacks.** An inventory screen deals in the stacks a player sees:
---`containers` reads the character's containers with every stack
---numbered, and `move`, `discard` and `hand` act on one of them, named by an
---`rpf.InventoryStackRef` (`{ container, index, item, key }`), data and all. Pass
---what a player's client sent: the container is looked for only among the
---character's own held containers, so another character's container, one
---not held here and one that never existed are the same `not_found`, and a
---stack whose item or data is no longer the one named (it moved since the
---screen was drawn, and another took its index) is `stale`, never another
---stack. Indexes count from 1. These
---four are RPF's own: where a framework owns items (a companion server),
---they are `unsupported`, which is how an inventory screen knows to stand
---aside for the framework's.
---
---```lua
---local containers = rpf.inventory.containers(player.handle)
---local bag = containers[1]
---local first = bag.stacks[1] -- { index = 1, item = "water", name = "Water", count = 3, key = "…" }
---local op = rpf.ops.new()
---rpf.inventory.move(player.handle, { container = bag.id, index = 1, item = first.item, key = first.key }, containers[2].id, op, { count = 1 })
---```
---
---**Server only.**
---@class rpf.api.Inventory
local Inventory = {}

---How many of an item a player's character holds.
---@param player any The engine's handle.
---@param item string The item's slug.
---@return number? count The count.
---@return rpf.FacadeRead? err Why not. An item nobody holds counts 0, so `not_found` is only for an item that is not a string.
function Inventory.count(player, item) end

---Gives a player's character units of an item, all into one container.
---@param player any The engine's handle.
---@param item string The item's slug.
---@param count integer How many, from 1.
---@param op_id string From `rpf.ops.new()`.
---@param apply (fun(): any)? Your change this goes with, as for `rpf.money.debit`.
---@return boolean? ok True once given (and applied).
---@return rpf.FacadeStatus? status Why not.
---@return string? reason For `refused`: `invalid`, `invalid_op`, `expired_op`, `journal_full`, `not_logged_in`, `no_character`, `no_container`, `no_space`.
function Inventory.give(player, item, count, op_id, apply) end

---Takes units of an item from a player's character.
---@param player any The engine's handle.
---@param item string The item's slug.
---@param count integer How many, from 1.
---@param op_id string From `rpf.ops.new()`.
---@param apply (fun(): any)? Your change this pays for, as for `rpf.money.debit`.
---@return boolean? ok True once taken (and applied).
---@return rpf.FacadeStatus? status Why not.
---@return string? reason For `refused`: as for `give`, and `insufficient`.
function Inventory.take(player, item, count, op_id, apply) end

---The character's held containers, for a screen: each with its rules and
---its stacks numbered, named and weighed. An addon's own UI reads this on
---the server and sends the client what it draws.
---@param player any The engine's handle.
---@return rpf.InventoryContainer[]? containers By name, then id; empty when the character has none held.
---@return rpf.FacadeRead? err Why not: `unsupported` where a framework owns items, `not_logged_in`, `no_character`.
function Inventory.containers(player) end

---Moves a stack, or units of it, to another of the character's containers,
---or to a spot in the same grid. Both containers are checked before either
---changes: units that do not fit are `no_space`, and nothing moves.
---@param player any The engine's handle.
---@param stack rpf.InventoryStackRef The stack.
---@param to string The destination container's id, one of the character's own (the stack's own for a new spot in a grid).
---@param op_id string From `rpf.ops.new()`.
---@param opts { count: integer?, position: { x: integer, y: integer }?, rotated: boolean? }? How many (the whole stack unless given), and in a grid where (the first free spot unless given) and whether turned.
---@return boolean? ok True once moved.
---@return rpf.FacadeStatus? status Why not.
---@return string? reason For `refused`: `invalid`, `invalid_op`, `expired_op`, `journal_full`, `unsupported`, `not_logged_in`, `no_character`, `not_found`, `stale`, `no_space`, `invalid_contents` (the source container's contents no longer pass its rules, as when the catalog changed).
function Inventory.move(player, stack, to, op_id, opts) end

---Destroys units of one of the character's stacks: what a player throws
---away. They go nowhere: nothing is left for another player to pick up.
---@param player any The engine's handle.
---@param stack rpf.InventoryStackRef The stack.
---@param count integer How many, from 1 to all the stack holds.
---@param op_id string From `rpf.ops.new()`.
---@return boolean? ok True once gone.
---@return rpf.FacadeStatus? status Why not.
---@return string? reason For `refused`: as for `move`, and `insufficient` for more than the stack holds.
function Inventory.discard(player, stack, count, op_id) end

---Hands units of one of the character's stacks to another player's
---character, data and all: into the first of their held containers that
---takes them all. Both sides are checked before either changes. Whether
---the two are near each other is yours to decide, from
---`rpf.world.position`.
---@param player any The engine's handle of the player handing over.
---@param target any The engine's handle of the player receiving: another logged-in player with a character in play.
---@param stack rpf.InventoryStackRef The stack.
---@param count integer How many, from 1 to all the stack holds.
---@param op_id string From `rpf.ops.new()`.
---@return boolean? ok True once handed over.
---@return rpf.FacadeStatus? status Why not.
---@return string? reason For `refused`: as for `discard`, `no_target` (the target is not another logged-in player with a character in play), and `no_space` when none of their containers takes the units.
function Inventory.hand(player, target, stack, count, op_id) end

---Whether a call works on this server: `containers`, `move`, `discard`
---and `hand` only where RPF owns items, not through a bridge.
---@param call string `count`, `give`, `take`, `containers`, `move`, `discard` or `hand`.
---@return boolean supported True if it does.
function Inventory.supports(call) end

---One stack of the character's, as `rpf.inventory.containers` read it and
---as `move`, `discard` and `hand` name it back: a plain table a client may
---send, which RPF checks.
---@class rpf.InventoryStackRef
---@field container string The container's id.
---@field index integer The stack's index in it, from 1.
---@field item string The item's slug you saw there: another item there now is `stale`.
---@field key string The stack's `key` you saw there (`rpf.InventoryStack.key`). Another stack of the same item with other data there now, as when an earlier stack was taken and the rest shifted up, is `stale`.

---A container of the character's, read for a screen.
---@class rpf.InventoryContainer
---@field id string Its id, what an `rpf.InventoryStackRef` and `move` name it by.
---@field name string Its name, as staff gave it ("Pockets", "Backpack").
---@field layout "list"|"grid" How it holds its stacks: in a row, or placed on a grid.
---@field grid { x: integer, y: integer }? A grid's size, in cells.
---@field max_weight integer? Its weight limit, inclusive; nil for none.
---@field weight number What it holds weighs, by the catalog.
---@field stacks rpf.InventoryStack[] Its stacks, in order.

---One stack in an `rpf.InventoryContainer`.
---@class rpf.InventoryStack
---@field index integer Its index, from 1.
---@field item string The item's slug.
---@field name string? The item's name from the catalog, nil for an item it does not have. A client's catalog has no names, so send it this.
---@field count integer How many units.
---@field data table? Its data (a bottle's note, a weapon's serial), a copy, when it carries any.
---@field key string A fingerprint of its data, 16 hex digits, the same for every stack of plain units. Name the stack back with it (`rpf.InventoryStackRef.key`): a string survives the trip to a client and back, where the data itself may not.
---@field position { x: integer, y: integer }? In a grid, its top-left cell, from 0.
---@field rotated boolean? In a grid, whether it lies a quarter turn.

---A player's job.
---
---**Server only.**
---@class rpf.api.Jobs
local Jobs = {}

---The job of the character a player has in play.
---@param player any The engine's handle.
---@return { name: string, employer: string, grade: number, on_duty: boolean }? job Nil for none. `grade` is its seniority at its employer.
---@return rpf.FacadeRead? err Why not.
function Jobs.current(player) end

---Whether a call works on this server.
---@param call string `current`.
---@return boolean supported True if it does.
function Jobs.supports(call) end

---Operation ids for the facade's commands.
---
---**Server only.**
---@class rpf.api.Ops
local Ops = {}

---Mints an op id: one per thing a player does (a purchase), kept with it, so
---sending that command again can never do it twice. It carries when it was
---minted, and is refused (`expired_op`) after a day.
---@return string? op_id The id, or nil before the core has started.
function Ops.new() end

---The commands whose result is `unknown`, oldest first: each may or may not
---have happened, and staff must resolve it by hand (grant what was paid
---for, or refund it through whoever owns the money). For a staff tool in
---game; the server's log has a line for each too. Each is listed for a day.
---@return rpf.OpUnknown[] unknown Copies.
function Ops.unknown() end

---How an op id already went on this server: what sending its command again
---would answer, without sending it. Ask it first when you answer a repeat
---of something a player did (an order sent again), so they get the answer
---they had, not a fresh refusal because the stock has since run out.
---@param op_id string The op id.
---@return boolean? done Nil when it never ran here (or changed nothing, or is older than a day): run it. True if it went through; false if not.
---@return rpf.FacadeStatus? status For false: `refused`, `unknown` (staff resolve it; never run it again), or `unavailable` (the journal could not be read; try later).
---@return string? reason For `refused`, why.
function Ops.result(op_id) end

---A facade command whose result is `unknown`.
---@class rpf.OpUnknown
---@field op_id string Its op id.
---@field call string What it was: `money.debit`, `money.credit`, `money.transfer`, `inventory.give`, `inventory.take`, `inventory.move`, `inventory.discard`, `inventory.hand` or `commerce.exchange`.
---@field at number When its op id was minted, in milliseconds since the Unix epoch.
---@field detail { player: string?, to: string?, account: string?, amount: number?, paid: number?, item: string?, count: number?, take: string?, give: string?, reason: string? } What it was: the player's account (`player_id`), the other player's (`to`) for a transfer or a hand-over, and the command's arguments; for an exchange, what the player paid (`amount`) or was paid (`paid`), and the items taken and given (`water:2,bread:1`).
---@field cause string What went wrong, for staff.

---**Exchanges** (J5): money and items moved together, with your change to
---your own records, as one intent. What a shop, a buy-back counter, a
---crafting bench or a licence office builds on, rather than chaining facade
---commands and finding out half way that the second is refused.
---
---A deal names what moves, from the player's side:
---
---```lua
---local op = rpf.ops.new() -- once per purchase, kept with it
---local ok, status, why = rpf.commerce.exchange(player, {
---  account = "wallet",                         -- the player's account, by name
---  pay = 10,                                   -- or `paid = 10`: the player is paid
---  give = { { item = "water", count = 2 } },   -- what the player receives
---  take = { { item = "empty_bottle", count = 2 } }, -- what they hand over
---  reason = "Corner shop: 2 water",            -- on their statement, and for staff
---  records = { { type = "acme_shop.stock", id = stock.id, revision = stock.revision } },
---}, op, function()
---  return rpf.records.update("acme_shop.stock", stock.id, { left = stock.fields.left - 2 }, { revision = stock.revision })
---end)
---```
---
---- **On an RPF server it is all or nothing.** Everything is checked before
---  anything moves: the account and its balance, every item given in the
---  current catalog, every record in `records` still at the revision you
---  read, and the items as one plan across the character's containers (so
---  what is taken can make room for what is given). Then the money, the items
---  and `apply` move together. A refusal changes nothing.
---- **Through a bridge to a framework** (a companion server), the
---  framework's calls cannot be made atomic: they run in order (the money,
---  each take, each give), then `apply`. A refusal before anything went
---  through changes nothing; a failure after one did is `unknown`, for staff,
---  and nothing is refunded. `check` first makes that rare.
---- **Retries** are safe with the same op id: the deal runs at most once, and
---  sending it again returns the first answer.
---- **`apply`** is your change the deal pays for, run only once everything
---  moved. Check everything it needs first (name the records in `records`),
---  so it cannot fail; nil, false or a throw make the deal `unknown`. Keep
---  it to fields of records you hold, which nothing but you can refuse.
---
---Only in-game money and items: never connect a deal to a real-money
---payment (Cfx.re's rules forbid it).
---
---**Server only.**
---@class rpf.api.Commerce
local Commerce = {}

---Makes a deal once per op id: what the player pays or is paid, hands over
---and receives, with your change to your own records.
---@param player any The engine's handle.
---@param deal rpf.Deal What moves.
---@param op_id string From `rpf.ops.new()`.
---@param apply (fun(): any)? Your change the deal pays for: run once everything moved, in the same intent. Answer non-nil (what `rpf.records.update` returns does); nil, false or a throw make the deal `unknown`.
---@return boolean? ok True once made (and applied).
---@return rpf.FacadeStatus? status Why not.
---@return string? reason For `refused`: as for `check`, and `invalid_op`, `expired_op`, `journal_full`.
function Commerce.exchange(player, deal, op_id, apply) end

---Whether a deal can be made now, without making it, so you can show a
---player what they can afford and carry. Through a bridge it asks the
---framework what it can (the balance, the counts); whether a give fits is
---only known when it runs.
---@param player any The engine's handle.
---@param deal rpf.Deal The deal.
---@return boolean? ok True if it can.
---@return "refused"|"unavailable"|nil status Why not.
---@return string? reason For `refused`: `invalid` (not a deal), `not_logged_in`, `no_character`, `not_found`, `not_held` or `inactive` (a record in `records`), `stale` (one moved on since you read it), `unknown_item` (an item given that the catalog does not have), `no_container`, `insufficient`, `no_space`, `invalid_contents`, `no_account`, `unsupported`, `insufficient_funds`, `out_of_range`.
function Commerce.check(player, deal) end

---A deal: what moves, from the player's side. At least one of `pay`,
---`paid`, `take` and `give`. Any other key is refused (`invalid`), so a
---misspelt one cannot sell for nothing.
---@class rpf.Deal
---@field account string? The player's account's name (`rpf.money.accounts()`); needed when money moves.
---@field pay integer? What the player pays, from 1 to 2^53 − 1. Not with `paid`.
---@field paid integer? What the player is paid. Not with `pay`.
---@field take { item: string, count: integer }[]? What the player hands over: plain units, at most 16 lines.
---@field give { item: string, count: integer }[]? What the player receives: plain units, at most 16 lines.
---@field reason string Why, for the player's statement and staff: 1 to 256 bytes.
---@field records { type: string, id: string, revision: integer }[]? Records you priced the deal against (a listing, the stock), each at the revision you read: one that moved on since is `stale`, and nothing moves. At most 16.

---The game world, through capabilities the engine's adapter declares. The
---core never branches on the engine: where an adapter does not support a
---capability, the call says `unsupported` (check `rpf.capabilities()`).
---Positions are plain `{ x, y, z }`, in the engine's units, which is how a
---record stores one (a `vector3` field).
---
---**Distances are written in metres, on every engine.** An interaction's
---`distance` and a zone's radius are metres, and `units` turns metres into
---the engine's units for a distance you measure yourself against
---`position`. FiveM's units are metres; Gmod's are about 39.37 to the
---metre.
---
---**Server only.**
---@class rpf.api.World
local World = {}

---A distance in metres, as the engine's units: what to compare against
---positions you measure yourself (`position`, `entity`), so the same number
---of metres comes out on FiveM, where the units are metres, and on Gmod,
---where they are about 39.37 to the metre. The adapter declares the scale;
---you never tell engines apart. An interaction's `distance` and a zone's
---radius are already in metres and need no conversion.
---
---```lua
---local reach = rpf.world.units(4) -- four metres
---local at, spot = rpf.world.position(player.handle), counter.fields.spot
---local dx, dy, dz = at.x - spot.x, at.y - spot.y, at.z - spot.z
---local near = dx * dx + dy * dy + dz * dz <= reach * reach
---```
---@param metres number The distance in metres. Negative is allowed, for an offset.
---@return number? units The same distance in the engine's units.
---@return "invalid"|nil err For anything but a finite number.
function World.units(metres) end

---A distance in the engine's units, as metres: the inverse of `units`, for
---a distance you measured from positions.
---@param units number The distance in the engine's units.
---@return number? metres The same distance in metres.
---@return "invalid"|nil err For anything but a finite number.
function World.metres(units) end

---Where a logged-in player is.
---@param player any The engine's handle.
---@return { x: number, y: number, z: number }? position A copy.
---@return "unsupported"|"not_found"|nil err `unsupported` where the engine's adapter cannot say, `not_found` for a player not logged in here or not spawned.
function World.position(player) end

---Which routing bucket a logged-in player is in: the world they are in,
---where the engine has more than one (FiveM's routing buckets). On an engine
---with one world (`capabilities().bucket` false) every player is in bucket
---0, as a record with no bucket field is.
---@param player any The engine's handle.
---@return integer? bucket The bucket.
---@return "not_found"|nil err For a player not logged in here.
function World.bucket(player) end

---The engine's id for a model name: what `entity` reports an entity's
---model as (a hash on FiveM, a lowercased path on Gmod), so a model you
---know by name can be compared with an entity a client named.
---@param name string The model's name.
---@return (number|string)? id The engine's id for it.
---@return "unsupported"|"invalid"|nil err `unsupported` where the engine has no models to name, `invalid` for a name that is not one.
function World.model(name) end

---A networked entity, by the ref a client named it by (a network id on
---FiveM, an entity index on Gmod): hostile input, resolved by the engine.
---`placement` names the record when RPF placed it for a world-backed type,
---and only then.
---
---```lua
---local entity = rpf.world.entity(payload.ref)
---if not entity or not entity.placement then
---  return false, "Nothing to talk to there."
---end
---```
---@param ref any The ref.
---@return { position: { x: number, y: number, z: number }, model: any, bucket: integer, placement: { type: string, id: string }? }? entity A copy: where it is, its model (the engine's id for it, as `capabilities().model` names it), its bucket.
---@return "unsupported"|"not_found"|nil err `unsupported` where the engine cannot say, `not_found` for a ref that names nothing.
function World.entity(ref) end

---The ref of the entity RPF placed for a record of a world-backed `config`
---type of kind `ped` or `object`, so the addon can hand it to a client
---(to point at it, or name it as a target). Nil while it is not placed: the
---record is hidden, its addon is not running, or the engine places nothing.
---@param type_name string The record's type.
---@param id string The record's id.
---@return integer? ref The entity's ref.
function World.placed(type_name, id) end

---The map this server runs, as it reported it to the portal: on Gmod the
---loaded map (`rp_downtown`), on FiveM the name the owner gave this setup in
---the `rpf_map` convar, `default` unless set. It stays the same until the
---server stops: changing map restarts the Lua state on Gmod, and FiveM
---reads the convar as the resource starts.
---
---A world type whose `world` names a `map` field has its records placed and
---targetable only on that map, or on every map where the field is null, so
---records staff placed are already sorted by map. Ask it to give a record
---you create the map it was made on:
---
---```lua
---rpf.data.create("acme_tags.tag", owner, {
---  spot = rpf.world.position(player.handle),
---  map = rpf.world.map(),
---})
---```
---@return string? map The map's name.
---@return "unsupported"|nil err Before RPF has started.
function World.map() end

---Interactions: a player's client asks an addon to do something, and the
---addon decides on the server. A request reaches only a handler an addon
---registered, under its own namespace; never an event the client named.
---
---```lua
----- server
---rpf.interactions.register("acme_tags.read", function(player, payload)
---  -- resolve every id in payload inside this player's scope before using it
---  local tag = rpf.records.get("acme_tags.tag", payload.id)
---  if not tag or tag.owner.id ~= player.player_id then
---    return false, "not_found" -- not there and not yours are one answer
---  end
---  return true, { text = tag.fields.text }
---end)
----- client
---rpf.interactions.request("acme_tags.read", { id = id }, function(ok, result)
---  if ok then show(result.text) else show("No: " .. result) end
---end)
---```
---
---**Targets (J4).** Register with rules, and the server checks the target
---the client names before the handler runs, then hands it over resolved:
---
---```lua
----- server: talk to a greeter staff placed (a world-backed config type)
---rpf.interactions.register("acme_npcs.talk", function(player, payload, target)
---  return true, { line = target.record.fields.line }
---end, { target = "acme_npcs.greeter", label = "Talk", distance = 2.5, cooldown = 2000 })
----- client: a key opens a menu of what is near (or a target resource does)
---rpf.interactions.open()
---```
---
---**Both sides:** `register` on the server; `send`, `request`, `open`,
---`nearby` and `targets` on the client.
---@class rpf.api.Interactions
local Interactions = {}

---Server only. Registers an interaction, under the addon's own namespace.
---One registered while the addon's code runs goes when it stops;
---registering the name again replaces it.
---
---The handler runs only while the addon is active, only for a player who
---has logged in, and at most 20 times per player every 10 seconds. The
---payload is hostile input: a copy of plain data (at most 4 KiB, 8 deep),
---whatever the player's client chose to send.
---
---`rules` (J4), all optional, are checked on the server, in this order,
---before the handler runs; a refusal is the reason the client hears:
---
--- - `target`: what the client must name in `payload.target`. A
---   world-backed type's name (`"acme_npcs.greeter"`): `{ id = <record> }`,
---   or `{ ref = <entity> }` for the entity RPF placed for one; the record
---   must be visible, in the player's routing bucket and within `distance`
---   (inside a zone's radius). Or `{ models = { "prop_atm_01", … } }`: `{
---   ref = <entity> }` of one of those models, in the player's bucket and
---   within `distance`. With a target the player must be in the world
---   (`not_active`), and a target that is missing, hidden, in another bucket
---   or not this server's is `not_found`; one out of reach is `too_far`.
--- - `distance`: how near, in metres on every engine; 3 unless given. A
---   zone's radius is in metres too.
--- - `cooldown`: milliseconds between one player's uses (`cooldown`).
--- - `permission`: one of the addon's permissions, which the player must
---   hold as linked staff (`forbidden`).
--- - `check(player, target)`: the addon's own test, answering `true`, or
---   `false` and a reason. It also decides what a player is **offered**:
---   the menu (`open`, `nearby`) and a target resource list only what
---   passes every rule, `check` included, so put a refusal you can tell in
---   advance here (sold, closed, not yours), not in the handler. It runs
---   for every listing as well as for the request, so keep it quick and
---   free of side effects: read, never write or show anything. One listing
---   runs at most 32 checks, nearest first, and starts none after 2
---   seconds; an option whose check did not run, threw or answered
---   anything but `true` is not offered.
--- - `label`: what the menu (`open`) and a target resource show.
---@param name string `<namespace>.<name>`.
---@param handler fun(player: rpf.PlayerView, payload: table, target: rpf.targets.Target?): boolean, (table|string)? Answers `true` and, optionally, a table of plain data for a `request` (at most 16 KiB encoded, 8 deep), or `false` and a reason the player's client is told. `target` is the resolved target: `{ type, id, record, position, distance }` for a record, `{ ref, model, position, distance }` (with `type` and `id` when RPF placed it) for an entity. Its `distance` is how far the player is, in metres.
---@param rules { target: (string|{ type: string?, models: string[]? })?, distance: number?, cooldown: integer?, permission: string?, check: (fun(player: rpf.PlayerView, target: rpf.targets.Target?): boolean, string?)?, label: string? }? The rules.
---@return boolean? ok True once registered.
---@return "invalid"|"reserved"|"not_found"|"forbidden"|"inactive"|"too_large"|nil err `invalid` for a bad name, handler or rules, `reserved` for a name starting `rpf_` after your namespace (the core's, for the Talk it offers on your NPCs), `not_found` when no addon of that namespace is loaded, `forbidden` for another addon's namespace, `inactive` from code of an activation that has ended, `too_large` when the server's rules with a target would no longer fit what a client reads (64 KiB).
---@return { error: "rules", field: string }? detail Which rule was refused.
function Interactions.register(name, handler, rules) end

---Client only. Asks the server to run an interaction. The answer arrives as
---`interactions.result`, with the refusals `request` lists. Use `request`
---to hear the answer, and the handler's data, in a callback instead.
---@param name string `<namespace>.<name>`.
---@param payload table? Plain data, at most 4 KiB encoded.
---@return boolean? ok True once sent.
---@return "invalid"|"too_large"|"too_many"|"unavailable"|nil err `invalid` for a bad name or a payload that is not plain data, `too_large` past 4 KiB, `too_many` while 64 requests wait for an answer, `unavailable` before the client has started.
function Interactions.send(name, payload) end

---Client only. Asks the server to run an interaction and hands the answer
---to `callback`, once: `callback(true, data)`, with the table the handler
---answered (empty if it gave none), or `callback(false, reason)`. The
---reason is the handler's own, or `unknown` when nothing is registered by
---that name, `inactive` while its addon is not, `invalid` for a payload the
---server refused, `failed` when the handler threw (or answered data that is
---not plain), `too_large` for data past 16 KiB, `too_many` past the rate,
---`not_logged_in` before the player has, or `timeout` when no answer came
---in 10 seconds. On FiveM it travels over ox_lib's `lib.callback`, but
---only to the handler an addon registered.
---@param name string `<namespace>.<name>`.
---@param payload table? Plain data, at most 4 KiB encoded.
---@param callback fun(ok: boolean, result: table|string) Called once, later: `true` and the data, or `false` and why.
---@return boolean? ok True once sent; the callback runs only then.
---@return "invalid"|"too_large"|"too_many"|"unavailable"|nil err As for `send`, and `invalid` for a callback that cannot be called.
function Interactions.request(name, payload, callback) end

---Client only. The minimal interaction UI (J4): asks the server what this
---player may interact with near them, shows it as a menu, and sends the
---option they pick, telling them if it is refused. RPF binds it to a key
---(`rpf_interact`); call it from your own key or command too.
function Interactions.open() end

---Client only. Asks the server what this player may interact with near
---them, for a UI of your own: `callback(options)`, each `{ name, label,
---type, id, distance }` (metres), nearest first, at most 16, each passing
---every rule including the addon's `check`; or `callback(nil, err)`
---(`timeout`, `failed`, `busy` while one is waiting). Send the one chosen
---with `request(name, { target = { id = id } }, …)`.
---@param callback fun(options: { name: string, label: string, type: string, id: string, distance: number }[]?, err: string?) Called once: at once for `busy` (or before the client has started, `unavailable`), else later.
---@return boolean? ok True once asked.
---@return "invalid"|nil err For a callback that cannot be called.
function Interactions.nearby(callback) end

---Client only. Every interaction with a target the server has, as it last
---told this client (also announced as `interactions.targets`): `{ name,
---label, type, kind, models, distance }`. What a target resource offers.
---@return table[] rules A copy.
function Interactions.targets() end

---Dialogs (L1): conversations with NPCs, from the trees staff build in
---the panel. Each node is a menu on the player's screen; the server checks
---every pick against the tree as it is now, and runs a choice's action
---(below) only if the player may still pick it.
---
---You rarely call this. Give a world type a `dialog` field and name it in
---`world`, and RPF offers Talk on its records and opens the tree the
---record names:
---
---```lua
---npc = {
---  schema = 1, authority = "config",
---  fields = {
---    spot = { type = "vector3", required = true },
---    model = { type = "json", engine = true, required = true },
---    talks = { type = "ref", to = "dialog", nullable = true },
---  },
---  world = { kind = "ped", position = "spot", model = "model", dialog = "talks" },
---},
---```
---
---**Server only.**
---@class rpf.api.Dialogs
local Dialogs = {}

---Server only. Opens a dialog tree for a player, from its start node: from
---a phone, a command, or an NPC of your own. While the player has a menu
---open (a conversation or anything else) it is `busy`, and what they have
---open goes on.
---@param player any The player's engine handle.
---@param slug string The tree's slug, as staff named it in the panel.
---@return boolean? ok True once shown.
---@return "not_found"|"not_logged_in"|"busy"|"unsupported"|"inactive"|"unavailable"|nil err `not_found` for a tree this server does not have, `not_logged_in` for a player who is not, `busy` while they have another menu open, `unsupported` on an engine without menus, `inactive` from code of an activation that has ended.
function Dialogs.open(player, slug) end

---Actions (L1): what your addon can be asked to do by a dialog choice.
---Staff build an NPC's conversation in the panel, and a choice can run an
---action an installed addon declared, with parameters staff fill in. The
---portal never sends code, so this is how a choice makes something happen:
---declare the action and its parameters in your manifest, and register its
---handler here while your addon runs.
---
---```lua
----- manifest.lua
---actions = {
---  start_route = {
---    title = "Start a delivery route",
---    help = "Gives the player a route to drive.",
---    params = { -- field definitions, as a type's fields are
---      route = { type = "ref", to = "rpf_delivery.route", required = true },
---      bonus = { type = "integer", min = 0, max = 1000, default = 0 },
---    },
---  },
---},
----- server.lua, in your `start` handler
---rpf.actions.register("rpf_delivery.start_route", function(player, params, context)
---  if busy(player) then
---    return false, "You already have a route." -- the player is told this
---  end
---  start(player.handle, params.route, params.bonus)
---  return true
---end)
---```
---
---**Server only.**
---@class rpf.api.Actions
local Actions = {}

---Server only. Registers the handler of an action your manifest declares
---(`actions.<name>`), under your addon's namespace. One registered while
---your addon's code runs goes when it stops; registering the name again
---replaces it.
---
---The handler runs only while your addon is active, for the player who
---picked the choice. `params` is a plain copy, already checked against the
---declaration with its defaults filled in: staff may have saved the choice
---under an older release of your manifest, and a choice whose parameters
---no longer pass is refused before your handler sees it. A `ref` to one of
---your types is the record's id; read it with `rpf.records.get`, since
---staff may have deleted the record since.
---@param name string `<namespace>.<name>`, as declared.
---@param handler fun(player: rpf.PlayerView, params: table, context: { dialog: string?, node: string?, target: rpf.targets.Target? }): boolean, string? Answers `true`, or `false` and a sentence the player is shown. A throw is logged and the player told it failed.
---@return boolean? ok True once registered.
---@return "invalid"|"not_found"|"forbidden"|"not_declared"|"inactive"|nil err `invalid` for a bad name or handler, `not_found` when no addon of that namespace is loaded, `forbidden` for another addon's namespace, `not_declared` when your manifest does not declare the action, `inactive` from code of an activation that has ended.
function Actions.register(name, handler) end

---UI an addon shows a player, the same on every engine (J10): over ox_lib
---on FiveM, in Derma on Gmod. It holds what an addon for both engines
---needs, not all of ox_lib; an addon for FiveM alone may call `lib.*` itself.
---
---```lua
----- server: the player picks, and the server reads the pick
---rpf.ui.menu(player.handle, {
---  title = "Your tags",
---  options = { { label = "hello", value = tag_id }, { label = "Close" } },
---}, function(choice, err)
---  if choice == tag_id then scrub(tag_id) end -- `value` never left the server
---end)
----- client
---rpf.ui.notify("Sprayed.")
---rpf.ui.input({ title = "Spray", fields = { { name = "text", label = "Text", required = true, max = 24 } } },
---  function(values) if values then rpf.interactions.send("acme_tags.spray", values) end end)
---```
---
---Each call returns `true` once it is shown, or nil and why: `invalid` for
---options it cannot show, `too_large` (server) for options each within
---bounds but together more than a client takes (64 KiB), `unsupported` where the engine has none
---(`rpf.capabilities()`), `busy` while one of its kind is open for the
---player, `not_found` (server) for a player not logged in here, `inactive`
---(server) from code of an addon activation that has ended. A wait is the
---addon's, like a timer: when it stops, the wait goes and its callback is
---never called. The callback
---runs once, later: with the result, or nil and why, `cancelled` when the
---player closed it, and on the server `timeout` (5 minutes, or a progress
---bar's length and 30 seconds), `gone` when the player left, `invalid` for
---an answer their client was not offered, or the client's own refusal.
---
---**On the server, the client's answer is checked against what was
---offered**: a menu answers one of its options, by number, and its `value`
---stays on the server; an input dialog's values are of each field's kind and
---within its bounds. It is still only what the player chose: check that
---they may do what they picked before you do it.
---
---**Both sides:** on the server each call takes the player's handle first.
---@class rpf.api.Ui
local Ui = {}

---Shows a notification. A string is the text alone.
---@param opts rpf.UiNotice|string What to show.
---@return boolean? ok True once shown (on the server, once sent).
---@return "invalid"|"unsupported"|"not_found"|"failed"|"unavailable"|nil err Why not.
---@overload fun(player: any, opts: rpf.UiNotice|string): boolean?, string?
function Ui.notify(opts) end

---Shows a menu to pick one option from. The callback gets the chosen
---option's `value` (its number if it has none), or nil and `cancelled`
---when the player closed it. An option that names an item (`item`) is
---drawn with the item's image beside its label, on either engine, as
---`rpf.items.image` would give it: the client finds the image itself, so
---the server sends the slug alone.
---@param opts rpf.UiMenu The menu.
---@param callback fun(choice: any, err: string?) Called once. `failed` when the engine could not show a menu that waited for its items' images (logged).
---@return boolean? ok True once shown; for a menu whose options name items, once it is to be shown with their images, which may take a moment the first time.
---@return "invalid"|"too_large"|"unsupported"|"busy"|"not_found"|"inactive"|"failed"|"unavailable"|nil err Why not.
---@overload fun(player: any, opts: rpf.UiMenu, callback: fun(choice: any, err: string?)): boolean?, string?
function Ui.menu(opts, callback) end

---Shows an input dialog. The callback gets the values by field name (a
---select's chosen option's `value`, a checkbox's boolean, nothing for a
---field left empty), or nil and `cancelled`.
---@param opts rpf.UiInput The dialog.
---@param callback fun(values: table<string, any>?, err: string?) Called once.
---@return boolean? ok True once shown.
---@return "invalid"|"too_large"|"unsupported"|"busy"|"not_found"|"inactive"|"failed"|"unavailable"|nil err Why not.
---@overload fun(player: any, opts: rpf.UiInput, callback: fun(values: table<string, any>?, err: string?)): boolean?, string?
function Ui.input(opts, callback) end

---Shows a progress bar. The callback gets `true` when it ran to its end,
---or nil and `cancelled` when the player cancelled it or something
---interrupted it. On the server, `true` is only the client's word: time the
---action yourself if it matters.
---@param opts rpf.UiProgress The bar.
---@param callback fun(completed: true?, err: string?) Called once.
---@return boolean? ok True once shown.
---@return "invalid"|"too_large"|"unsupported"|"busy"|"not_found"|"inactive"|"failed"|"unavailable"|nil err Why not.
---@overload fun(player: any, opts: rpf.UiProgress, callback: fun(completed: true?, err: string?)): boolean?, string?
function Ui.progress(opts, callback) end

---A notification.
---@class rpf.UiNotice
---@field text string What it says, at most 256 bytes.
---@field title string? A title above it, at most 128 bytes.
---@field kind "info"|"success"|"warning"|"error"? How it looks: `info` unless given.
---@field duration_ms integer? How long it shows: 5000 unless given, 1000 to 30000.

---A menu.
---@class rpf.UiMenu
---@field title string Its title, at most 128 bytes.
---@field text string? What it says above its options, read and never picked, at most 1024 bytes and over several lines if you like: what an NPC says before the player answers (L1). A read-only entry at the top of ox_lib's context menu on FiveM, a wrapped label on Gmod.
---@field options rpf.UiMenuOption[] Its options, 1 to 32, in order.

---One menu option.
---@class rpf.UiMenuOption
---@field label string What it says, at most 128 bytes.
---@field description string? A line under it (a tooltip on Gmod).
---@field disabled boolean? Shown, but cannot be picked.
---@field item string? An item's slug (`[a-z][a-z0-9_]*`, at most 64 bytes), whose image is drawn beside the label: ox_lib's `icon` on FiveM, a `DImage` on Gmod. The client finds the image through `rpf.items.image`, so only the slug travels; an item the catalog does not have, or one staff gave no image, or an image that takes longer than two seconds to arrive, leaves the option with its label alone (the image is kept for the next menu).
---@field value any? What the callback gets when it is picked: its number unless given. Never sent to the client.

---An input dialog.
---@class rpf.UiInput
---@field title string Its title, at most 128 bytes.
---@field fields rpf.UiField[] Its fields, 1 to 12, in order.

---One input dialog field.
---@class rpf.UiField
---@field name string Its key in the values, `[A-Za-z_][A-Za-z0-9_]*`, unique in the dialog.
---@field label string Its label, at most 128 bytes.
---@field kind "text"|"number"|"checkbox"|"select"? What it takes: `text` unless given.
---@field required boolean? Must be filled in; a checkbox, ticked.
---@field placeholder string? Shown while it is empty.
---@field min number? Text: the fewest bytes (0). Number: the least value.
---@field max number? Text: the most bytes (128 unless given, at most 512). Number: the greatest value.
---@field default any? What it starts as: text, a number, a boolean, or one of a select's option values.
---@field options { label: string, value: any? }[]? A select's options, 1 to 32: each `value` (its number unless given) is what the values hold.

---A progress bar.
---@class rpf.UiProgress
---@field label string What it says, at most 128 bytes.
---@field duration_ms integer How long it runs, 100 to 600000.
---@field cancel boolean? Whether the player may cancel it: yes unless `false`.

---What `interactions.result` carries.
---@class rpf.InteractionResult
---@field name string The interaction.
---@field ok boolean Whether it went through.
---@field reason string? Why not.

---Why a facade read has no value.
---@alias rpf.FacadeRead
---| "not_logged_in" # The player has not logged in here, or is leaving.
---| "no_character" # They have no character in play.
---| "not_found" # No such account (or item slug).
---| "unavailable" # Whoever owns the domain cannot be asked now.
---| "unsupported" # This server cannot answer it: a bridge that does not read it, or a call only RPF's own modules answer (`rpf.inventory.containers`) where a framework owns the domain.

---How a facade command failed.
---@alias rpf.FacadeStatus
---| "refused" # Nothing changed; the third value says why.
---| "unavailable" # Nothing changed; it could not be asked. Fine to try again later.
---| "unknown" # It may have happened. Never send it again under a new op id; staff resolve it (`rpf.ops.unknown()`).

---Where an addon is.
---@alias rpf.AddonState
---| "active" # Installed, enabled, matching, its requirements active; its `start` ran.
---| "not_installed" # The portal has not installed it, and it has not been proposed yet.
---| "pending" # Proposed to the portal; staff have not installed it.
---| "mismatch" # Installed with another manifest: the files on the server and the portal disagree.
---| "disabled" # Staff disabled it in the portal.
---| "api" # Written for an addon API major this core does not serve.
---| "requires" # An addon it requires is not active here.
---| "failed" # Its `start` handler threw. Tried again on the next config change or registration.

---What an addon passes with its manifest. Each is optional.
---@class rpf.AddonHandlers
---@field start fun()? Runs when it becomes active. Set up timers and handlers here: they are taken down when it stops.
---@field stop fun(reason: string)? Runs when it stops being active: disabled, a mismatch, reloaded, a config that no longer installs it.
---@field state fun(state: rpf.AddonState, reason: string?)? Runs on every change of state.

---Why `addons.register` refused, as the portal names the same rule.
---@class rpf.AddonRefusal
---@field error string The rule: a manifest rule (`version`, `bound`, `unknown`, …), `handlers` or `handler` for handlers that are not, `too_many` past the addons a server may load.
---@field path string Where, like `types.tag.fields.text.max_len` or `handlers.strat`.

---What `addons.state` carries.
---@class rpf.AddonStateChange
---@field namespace string The addon.
---@field state rpf.AddonState Its new state.
---@field reason string? Why.

---An addon's manifest (`docs/architecture/addons.md`, "The manifest"):
---data, never code, checked by the same rules here and in the portal.
---Every key not listed is refused, so a typo fails at registration.
---@class rpf.AddonManifest
---@field namespace string `[a-z][a-z0-9_]{2,31}`, not reserved. Everything the addon declares is under it.
---@field version string Its release, `MAJOR.MINOR.PATCH`.
---@field api integer The addon API major it was written for: `rpf.addons.API` when written.
---@field title string Shown to staff, at most 64 bytes.
---@field requires table<string, string>? Other addons by namespace, each with a semver range (`^1.0`, `>=1.2.0`, `*`).
---@field permissions table<string, string>? Its own flags, `addon.<namespace>.<name>`, each with a description for staff.
---@field types table<string, rpf.AddonType>? Its types, by name.

---One type an addon declares.
---@class rpf.AddonType
---@field schema integer Moves on every change to `fields`.
---@field authority "config"|"live" `config`: staff write its records in the portal, and the server reads them. `live`: game state this server holds and writes.
---@field owners ("player"|"character"|"employer"|"server")[]? Who may own a live type's records.
---@field hold "owner"|"server"? When a live type's records are held (J6).
---@field title string? Shown to staff.
---@field fields table<string, rpf.AddonField> Its fields, by name: at least one, at most 64.
---@field list string[]? The fields the portal's list shows.
---@field display string? The field that names a record in the portal (N2): what a reference to it shows and a picker searches. A shown, indexed `string`; without it, the first such field of `list`, then of the layout.
---@field actions table<string, string|false>? `view`, `create`, `edit`, `delete`, each the flag staff need, or false to offer none.
---@field limit integer? The most records of it on a server, at most 50000.
---@field world rpf.AddonWorld? Which of its fields place its records in the game world (J4).

---Which of a type's fields say where its records are in the game world, by
---the part each plays. Every value names a field of the type.
---@class rpf.AddonWorld
---@field kind "ped"|"object"|"point"|"zone" What is placed: a ped or object by the game server, a point nothing, a zone a sphere.
---@field position string A `vector3` field: where it is.
---@field heading string? A number field: which way it faces, in degrees.
---@field radius string? A number field a zone needs: its size, in metres.
---@field bucket string? An integer field: the routing bucket, 0 where unnamed.
---@field model string? An `engine = true` string or json field a ped or object needs: its model.
---@field visible string? A boolean field: false hides the record from the world.
---@field map string? An indexed, nullable string field: the map it is on, null for every map (#369).

---One field of a type: its kind and its bounds.
---@class rpf.AddonField
---@field type "string"|"text"|"integer"|"number"|"boolean"|"enum"|"timestamp"|"vector3"|"ref"|"list"|"json" Its kind.
---@field required boolean? Must have a value.
---@field nullable boolean? May be cleared.
---@field default any? What a record without it reads as.
---@field index boolean? Queries may filter and order on it.
---@field unique boolean? No two records share a value (an indexed field only).
---@field title string? Shown to staff.
---@field help string? Shown to staff under the input.
---@field group string? The heading the portal shows it under, at most 64 bytes; fields with none come first (N1).
---@field order integer? Where the portal puts it, 0 to 1000, lowest first, then by name; fields with none come last (N1).
---@field hidden boolean? Never shown in the portal.
---@field read_only boolean? Shown, not editable by staff.
---@field engine boolean? Engine-specific data (a model), stored as is.
---@field max_len integer? A string's or text's most bytes.
---@field min_len integer? A string's fewest bytes.
---@field charset "identifier"|"printable"|"any"? What a string may hold.
---@field min number? The least a number may be.
---@field max number? The most a number may be.
---@field unit "money"|"seconds"|"minutes"|"hours"|"metres"|"degrees"|"percent"? What an integer or number counts, which decides its editor in the portal; `money` on an integer only (N1).
---@field slider boolean? Edit an integer or number with a slider; needs `min` and `max`, and never `nullable` (N1).
---@field values string[]? An enum's values.
---@field to string? What a `ref` names: a type, or `player`, `character`, `employer`, `server`, `item`, `job`.
---@field of string? A list's item kind.
---@field max_items integer? A list's most items.
---@field max_bytes integer? A json field's most bytes.

---The players on this game server. Read-only: players are moved by the core
---(the login flow) and by whichever module owns characters on the server.
---
---**Server only.**
---@class rpf.api.Players
local Players = {}

---One player, by the engine's handle.
---
---```lua
---local player = rpf.players.get(source) -- FiveM's `source`; a Player on Gmod
---if player and player.state == "active" then
---  remember(player.player_id) -- the portable id; never store the handle
---end
---```
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

---In-game staff (F9). A staff member links their player account to their
---portal account once, with a code the portal gives them, and from then on
---may do here what their portal roles allow on this server, under the same
---permission names (`player.kick`). The portal pushes every change, so `can`
---answers from memory, at once, even while the portal is unreachable.
---
---The core has no chat command of its own: a server's script calls `link`
---from whatever command it offers. Nothing here acts on a player either;
---the script that kicks or teleports checks `can` first, and reports what
---it did with `record`.
---
---**Server only.**
---@class rpf.api.Staff
local Staff = {}

---Whether a player may do something on this server: logged in, and the
---portal's last push gave them exactly that permission.
---@param handle any The engine's player handle.
---@param permission string The permission, by its portal name, like `player.kick`.
---@return boolean allowed False for anyone not logged in, not linked, or without it here.
function Staff.can(handle, permission) end

---Every permission a player has on this server.
---@param handle any The engine's player handle.
---@return string[] permissions Sorted names, a copy. Empty for anyone not logged in or not linked.
function Staff.permissions(handle) end

---Links a player's account to the staff account that issued a code. RPF
---registers the command a player types it into (`rpflink <code>`) and calls
---this for them, so a script needs it only for a command of its own. The code is sent exactly as typed, and
---never logged. The answer comes later: the player is told, and
---`staff.linked` or `staff.link_failed` is announced; their permissions
---follow in the portal's next push. One link per player at a time, because
---each wrong code counts against the player and the guild.
---@param handle any The engine's handle of the player who typed it.
---@param code string The code, at most 32 bytes.
---@return boolean sent True once it is on its way.
---@return rpf.StaffRefusal? err Why not. For `outbox_full` and `outbox_unavailable` the player has already been told.
function Staff.link(handle, code) end

---Reports a staff action your script carried out, for the guild's audit log
---on the portal. Sent only if `can(handle, permission)`; the portal checks
---the permission again and refuses the entry otherwise.
---@param handle any The engine's handle of the staff member.
---@param permission string The permission the action needed, like `player.kick`.
---@param action string What they did: an identifier, `[a-z][a-z0-9_]*`, at most 64 bytes, like `kick` or `teleport_to`. It is all the detail the log keeps.
---@param target any? The engine's handle of the player it was done to, if any. Must be logged in.
---@return boolean sent True once it is on its way.
---@return rpf.StaffRefusal? err Why not.
function Staff.record(handle, permission, action, target) end

---Why `staff.link` or `staff.record` refused before sending anything.
---@alias rpf.StaffRefusal
---| "not_logged_in" # The player has not logged in to their account here, or is leaving.
---| "invalid_code" # The code is not a non-empty UTF-8 string of at most 32 bytes.
---| "busy" # This player already has a link on its way to the portal.
---| "forbidden" # The player may not do this: not linked, or no such permission here.
---| "invalid_action" # The action is not an identifier (`[a-z][a-z0-9_]*`) of at most 64 bytes.
---| "invalid_target" # A target was given that is not a logged-in player.
---| "outbox_full" # Too much is waiting for the portal; try again later.
---| "outbox_unavailable" # The game server's stored outbox needs repair.

---What `staff.changed` carries.
---@class rpf.StaffChange
---@field player_id string The player's account.
---@field permissions string[] What they may do here now, sorted. Empty when they lost everything.

---What `staff.linked` carries.
---@class rpf.StaffLinked
---@field player_id string The player's account.
---@field staff_name string The staff account's display name, for display only.

---What `staff.link_failed` carries.
---@class rpf.StaffLinkFailure
---@field player_id string The player's account.
---@field code string The portal's refusal (`forbidden` for a code that does not link or too many tries, `not_found` for a player the portal does not have online here), or why it never answered: `expired`, `outbox_full`, `outbox_unavailable`.
---@field reason string What the player was told.

---Lookups over the config the portal pushed (E2), and the one way to change
---it from the game (E6). Lookups are read-only, and each returns a copy:
---config changes only when the portal pushes a new snapshot, an in-game
---edit included.
---
---**Server only.**
---@class rpf.api.Config
local Config = {}

---An item definition, by slug, with every field resolved by the portal (E3):
---the item's own value, else its base's, else the catalog default.
---
---```lua
---local item = rpf.config.item("water") or rpf.config.item_defaults()
---local fits = item.weight * count <= capacity_left
---```
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

---An employer the server runs, by slug (E4). An employer a player runs is
---not config, and is never here.
---@param slug string The employer's slug.
---@return rpf.ConfigEmployer? employer A copy, or nil if the config has none by that slug.
function Config.employer(slug) end

---A department, by its employer's slug and its own (E4). A department's
---slug is unique only within its employer, so both are needed.
---@param employer string The employer's slug.
---@param slug string The department's slug.
---@return rpf.ConfigDepartment? department A copy, or nil if the config has none.
function Config.department(employer, slug) end

---A job, by its employer's slug and its own (E4). Two employers may each
---offer a job of the same slug, so both are needed.
---@param employer string The employer's slug.
---@param slug string The job's slug.
---@return rpf.ConfigJob? job A copy, or nil if the config has none.
function Config.job(employer, slug) end

---The accounts every new character on this server is opened with, and what
---each starts with (E5). The portal opens and funds them when it creates the
---character; never pay them out yourself.
---@return rpf.ConfigStartingAccount[]? accounts A copy, or nil before any config has arrived.
function Config.starting_accounts() end

---The job a new character on this server starts in (E5), always one
---`job(employer, slug)` finds: the portal sends none rather than a job this
---server does not have.
---@return rpf.ConfigJobRef? job A copy, or nil if there is none.
function Config.default_job() end

---A setting's effective value, by key.
---@param key string The setting's key.
---@return any value A copy, or nil if unset.
function Config.setting(key) end

---The config version applied now.
---@return number? version The version, or nil before any config has arrived.
function Config.version() end

---Changes this server's config for a linked staff member in game (E6), for
---your config menu or command to call once they confirm.
---
---Pass the version the staff member was looking at (`version()` when the
---menu opened). The portal applies every change or none, and only if that is
---still the server's version: if a portal edit, or another edit, landed
---first, nothing is applied, the edit is listed as discarded on the server's
---settings page, and the staff member is told to redo it. The new config
---arrives as `config.changed`, never from this call. The staff member is told
---how it went, and `config.edit_applied`, `config.edit_discarded` or
---`config.edit_refused` is announced.
---
---Sent only for a player holding a permission that may make each kind of
---change (`config.settings.edit` or `config.accounts.edit` for a setting,
---`config.items.edit` for items and bases, `config.jobs.edit` for
---employers, departments and jobs). The portal checks the exact one, and
---every value, as its own pages do.
---@param handle any The engine's handle of the staff member.
---@param base_version number The config version the change was made against.
---@param changes rpf.ConfigEditChange[] From 1 to 16 changes, applied in order.
---@return boolean sent True once it is on its way.
---@return rpf.ConfigEditRefusal? err Why not.
function Config.edit(handle, base_version, changes) end

---One change in an in-game config edit (E6): exactly what one of the
---portal's config forms submits, tagged by `change`. Which other fields it
---has follows the tag:
---
--- - `setting`: `key`, and `value` as `{ state = "set", value = … }` to
---   override, `{ state = "null" }` to clear, or `{ state = "inherit" }` to
---   take the parent server's.
--- - `create_item_base`, `update_item_base`: `base`, an
---   `rpf.ConfigItemBase`. `delete_item_base`: `slug`.
--- - `create_item`, `update_item`: `item`, with `slug`, `name`, and
---   optionally `base`, `weight`, `size` and `stack_limit`; one left out
---   comes from the base. `delete_item`: `slug`.
--- - `create_employer`, `update_employer`: `employer`, an
---   `rpf.ConfigEmployer`. `delete_employer`: `slug`.
--- - `create_department`, `update_department`: `department`, an
---   `rpf.ConfigDepartment`. `delete_department`: `employer` and `slug`.
--- - `create_job`, `update_job`: `job`, an `rpf.ConfigJob`. `delete_job`:
---   `employer` and `slug`.
---@class rpf.ConfigEditChange
---@field change string What kind of change, as above.
---@field key string? A setting's key.
---@field value table? A setting's new state.
---@field base rpf.ConfigItemBase? An item base.
---@field item table? An item as staff define it.
---@field employer rpf.ConfigEmployer|string? An employer, or for a department or job delete the employer's slug.
---@field department rpf.ConfigDepartment? A department.
---@field job rpf.ConfigJob? A job.
---@field slug string? What a delete names.

---Why `config.edit` refused before sending anything.
---@alias rpf.ConfigEditRefusal
---| "not_logged_in" # The player has not logged in to their account here, or is leaving.
---| "invalid_version" # The base version is not a whole number from 0.
---| "invalid_changes" # The changes are not a list of 1 to 16 changes, each of a known kind and the shape that kind takes.
---| "forbidden" # The player holds no permission that may make one of the changes here.
---| "outbox_full" # Too much is waiting for the portal; try again later.
---| "outbox_unavailable" # The game server's stored outbox needs repair.

---What `config.edit_applied` and `config.edit_discarded` carry.
---@class rpf.ConfigEditResult
---@field player_id string The staff member's player account.
---@field version number The server's config version: the one the edit made, or the one it was discarded against.

---What `config.edit_refused` carries.
---@class rpf.ConfigEditFailure
---@field player_id string The staff member's player account.
---@field code string The portal's refusal (`forbidden`, `malformed`, `not_found`), or why it never answered: `expired`, `outbox_full`, `outbox_unavailable`.
---@field reason string What the staff member was told.

---A job by its employer's slug and its own, as a character holds one (D7) and
---the config's default job names one.
---@class rpf.JobRef
---@field employer string The employer's slug.
---@field job string The job's slug, unique within the employer.

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
---@field image string? The item's image by content hash (P3): the SHA-256 of the image, 64 lowercase hex digits, nil if staff uploaded none. A player's client draws it through `rpf.items.image`, which keeps what it fetched under this hash, which changes exactly when the image does.
---@field weapon rpf.ConfigItemWeapon? The engine weapon equipping it gives (L3), nil if it is not a weapon.

---What makes an item a weapon (L3): the engine weapon it gives on each
---engine, as staff wrote it, and the item it fires. A weapon names at least
---one engine's; the other is nil on an item that is a weapon on one engine
---only.
---@class rpf.ConfigItemWeapon
---@field fivem string? The GTA weapon's name on FiveM, such as `WEAPON_PISTOL`.
---@field gmod string? The weapon's class on Gmod, such as `weapon_pistol`.
---@field ammo string? The slug of the item it fires, nil if it takes none. May be the weapon itself (a throwable), or an item the catalog has stopped defining, which counts as none carried.

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

---An employer as the config snapshot carries it (E4).
---@class rpf.ConfigEmployer
---@field slug string What Lua, its departments and its jobs name it by.
---@field name string Its display name.
---@field description string Free text, possibly empty.
---@field payroll string? The name of the server's paying account its salaries come from (D7), as `rpf.config.paying_account` finds it; nil when it pays none.

---A department as the config snapshot carries it (E4).
---@class rpf.ConfigDepartment
---@field employer string The slug of the employer it belongs to.
---@field slug string Its slug, unique within the employer.
---@field name string Its display name.
---@field description string Free text, possibly empty.

---A job as the config snapshot carries it (E4).
---@class rpf.ConfigJob
---@field employer string The slug of the employer offering it.
---@field slug string Its slug, unique within the employer.
---@field name string Its display name.
---@field department string? The slug of the employer's department it sits in, nil if none.
---@field description string Free text, possibly empty.
---@field rank number Its seniority at its employer (D7), a whole number from 0 to 1000: higher is more senior, and ranks compare only within one employer.
---@field salary number? What one pay period on duty earns (D7), a whole amount from 1; nil for an unpaid job.

---An account every new character is opened with (E5).
---@class rpf.ConfigStartingAccount
---@field name string The account's name, which it is opened under (`wallet`, `bank`).
---@field amount number What it starts with, in the server's smallest currency unit. Zero opens it empty.

---A job, named by its employer's slug and its own (E5), as `job(employer, slug)` takes them.
---@class rpf.ConfigJobRef
---@field employer string The employer's slug.
---@field job string The job's slug.

---What `config.changed` carries.
---@class rpf.ConfigChange
---@field version number The version just applied.
---@field sections string[] The top-level sections that differ from the snapshot before, sorted, such as `items` or `settings`.

---The server's item catalog and its items' images, on the player's client
---(P3). The client has no config snapshot; this reads the portal's player
---API with the player's API token, keeps the catalog, and fetches an
---image once per content hash, so an inventory or shop UI draws an item's
---icon in one call:
---
---```lua
---rpf.items.image("apple", function(image, err)
---  if not image then
---    return -- "no_image", "not_found", "not_logged_in", "busy" or "unavailable"
---  end
---  -- FiveM: a data: URL, for an <img> in your page or ox_lib's `image`.
---  SendNUIMessage({ type = "icon", slug = image.slug, src = image.src })
---  -- Gmod: a path for Material(): surface.SetMaterial(Material(image.src))
---end)
---```
---
---An image that has not changed is never fetched again, even after a
---restart: the adapter keeps it on disk under its hash. Ask again whenever
---you draw; a kept image answers at once. Nothing is sent before the player
---has logged in (`not_logged_in`). A menu shown through `rpf.ui.menu`
---draws an option's item for you: name it with `item = "apple"` on the
---option, on either side (`rpf.UiMenuOption`).
---
---**Client only.**
---@class rpf.api.Items
local Items = {}

---The server's item catalog: every item its config defines, public fields
---only, as the portal last said (revalidated after a minute).
---@param callback fun(catalog: rpf.PlayerItemCatalog?, err: string?) Called once, later: a copy of the catalog, or nil and why (`not_logged_in`, `busy`, `unavailable`).
---@return boolean? ok True once asked.
---@return string? err `invalid` for a callback that cannot be called, `unavailable` before the client has started.
function Items.catalog(callback) end

---An item's image, by its slug.
---@param slug string The item's slug.
---@param callback fun(image: rpf.ItemImage?, err: string?) Called once, later: the image, or nil and why: `no_image` for an item staff gave none, `not_found` for a slug the catalog does not have (or an image removed meanwhile), `not_logged_in`, `busy` when the portal's rate limit was reached, `unavailable` for anything else (the portal or the image could not be reached).
---@return boolean? ok True once asked.
---@return string? err `invalid` for a slug that is not a non-empty string or a callback that cannot be called, `unavailable` before the client has started.
function Items.image(slug, callback) end

---The server's item catalog as a client sees it.
---@class rpf.PlayerItemCatalog
---@field defaults rpf.PlayerItem What an item missing from `items` behaves as. Never has an image.
---@field items table<string, rpf.PlayerItem> Every item the server's config defines, by slug.

---One item in the client's catalog: what draws it in a grid and predicts
---what a move will do.
---@class rpf.PlayerItem
---@field weight integer Weight of one unit.
---@field size { x: integer, y: integer } Footprint in a grid container, in cells, before rotation.
---@field stack_limit integer The most that may sit in one stack.
---@field image string? The image's content hash (SHA-256, 64 lowercase hex digits), nil when the item has none. It changes exactly when the image does.

---An item's image, ready to draw.
---@class rpf.ItemImage
---@field slug string The item's slug.
---@field hash string The image's content hash.
---@field src string What the engine draws: on FiveM a `data:image/png;base64,…#.png` URL (the fragment is what makes ox_lib take it for an image), for an `<img>` in any resource's page or ox_lib's `icon` (beside an option's title) and `image` (in its hover card); on Gmod a path for `Material()` and `DImage:SetImage` (`data/rpf/images/<hash>.png`). PNG, at most 256 pixels a side.

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
---A script on the client reads the outcome rather than asking for the
---password itself:
---
---```lua
---rpf.events.on("auth.succeeded", function(result)
---  show_welcome(result.username, result.created)
---end)
---if rpf.auth.state() == "authenticated" then
---  show_welcome(rpf.auth.account().username, false)
---end
---```
---
---**Client only.**
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

---Deletes the player's account at the portal, for good (H6): nobody can log
---in to it again, and its names, identifiers and logins are gone. Needs the
---account's own password. An account linked to a staff account is deleted
---too: the link goes with it, and the portal takes its in-game permissions
---away. Ends in `auth.account_deleted` or `auth.failed`. Once deleted the state is
---`deleted` and nothing more can be started on this connection: the player
---is still in the game until they leave, so tell them to reconnect.
---@param username string The username.
---@param password string The account's password. Kept in memory for this attempt only, never stored or logged.
---@return boolean started False if refused at once.
---@return string? err Why.
function Auth.delete_account(username, password) end

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
---| "working" # A login, registration, password change or account deletion is in flight.
---| "redeeming" # The portal accepted the login; the server is redeeming the ticket.
---| "authenticated" # Logged in.
---| "deleted" # The account was deleted on this connection; nothing more can be started until the player reconnects.

---Which request an `rpf.AuthFailure` came from.
---@alias rpf.AuthStep "login"|"register"|"resume"|"change_password"|"redeem"|"refresh"|"logout"|"delete_account"

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

---What `auth.account_deleted` carries.
---@class rpf.AuthDeleted
---@field username string The username the account had.

---What `auth.password_change_required` carries: staff reset the password,
---and the player must choose a new one through `change_password`.
---@class rpf.AuthPasswordChange
---@field username string The username that was used.
---@field message string? The portal's message, written for the player.

---The bridge to an existing RP framework (K2, `docs/architecture/framework-integration.md`).
---On a companion server the framework owns characters, money, items and
---jobs, and one bridge, a package beside RPF (`lua/bridges/<framework>/`),
---reaches it through its public API: it registers its contract here, and
---reports what the framework does through the lifecycle calls. Addons never
---call these: the facade (`rpf.money`, …) routes to the bridge.
---
---The core accepts the bridge only if its `contract.major` is this core's
---and its `provides` is exactly the domains the server's profile leaves to
---the framework; until then players stay at `registered`. Once the profile
---is fixed and fits, the bridge is active: its `start` runs, and each
---logged-in player moves to `character_select`, the bridge's cue to show
---the framework's character selection. On FiveM only the resource that
---registered the bridge may report for it, and that resource stopping
---withdraws it. `rpf.BridgeDefinition` is the table a bridge registers;
---`lua/bridges/README.md` states the rules a bridge follows.
---
---**Server only.**
---@class rpf.api.Bridge
---@field CONTRACT_MAJOR integer The bridge contract's major this core speaks: a bridge written for another is refused.
---@field CONTRACT_MINOR integer The contract's minor: a bridge written for a later one may list calls this core leaves out.
local Bridge = {}

---Registers the one bridge for this server. A refusal is logged once and
---changes nothing.
---@param bridge rpf.BridgeDefinition The bridge.
---@return boolean? ok True once registered: active, or waiting for the profile.
---@return "invalid"|"contract"|"registered"|"start"|nil err `invalid` for a field the contract does not allow (the third value names it), `contract` for another major, `registered` when a bridge is already, `start` when it activated at once and its `start` threw, which withdrew it (logged).
---@return string? field For `invalid`, which field.
function Bridge.register(bridge) end

---Reports that a player's framework character is loaded: the player moves
---to `active`. Report the same character again to change its name; another
---key is a switch, through `character_select`.
---@param player any The engine's handle.
---@param character rpf.BridgeCharacter The character: the framework's key and its name.
---@return boolean? ok True once the player is active with it.
---@return "forbidden"|"inactive"|"unavailable"|"invalid"|"not_found"|"not_registered"|"superseded"|nil err `forbidden` from code other than the bridge's, `inactive` while it is not active, `unavailable` while the bridge says its framework is (the player stays where they are: report the character again once it is `available`), `invalid` for a key or name that is not one, `not_found` for a player not here, `not_registered` for one who has not logged in to RPF (the framework loaded a character past RPF's gate; logged), `superseded` when the bridge reported another character while this one was moving the player (answering `players.character_select` at once), which stands.
function Bridge.character_loaded(player, character) end

---Reports that a player's framework character is unloaded: the player
---goes back to `character_select`.
---@param player any The engine's handle.
---@return boolean? ok True once they are.
---@return "forbidden"|"inactive"|"not_found"|"no_character"|nil err Why not.
function Bridge.character_unloaded(player) end

---Reports that the framework cannot be asked (its resource stopped):
---every facade call is `unavailable`, without reaching the bridge, until
---`available`. Report its characters unloaded as the framework does.
---@param reason string? Why, for the log.
---@return boolean? ok True.
---@return "forbidden"|"inactive"|nil err `inactive` when no bridge is registered.
function Bridge.unavailable(reason) end

---Reports that the framework can be asked again.
---@return boolean? ok True.
---@return "forbidden"|"inactive"|nil err Why not.
function Bridge.available() end

---Refusals for a domain an existing framework owns on this server (K1, K2),
---and for a call nobody implements here. RPF's own modules answer
---`domain_external` for an external domain; the facade answers
---`unsupported` for a call its provider does not implement (a native
---debit or credit without the server's `economy.addon_account`, too).
---@alias rpf.api.Refusal
---| "domain_external" # The domain (`characters`, `money`, `inventory`, `jobs`) is owned by an existing framework on this server, so RPF's own operation on it is refused. Use the facade, which routes to the bridge.
---| "unsupported" # The active provider does not implement this call. Check `supports` first.

-- The bridge contract (K2, #92), version 1.0: the table a bridge to an
-- existing RP framework passes to `rpf.bridge.register`, and the calls the
-- core makes into it. `lua/bridges/README.md` states the rules a bridge
-- follows, and `docs/architecture/framework-integration.md` why.
--
-- Every function in `rpf.BridgeDefinition` is the bridge's, called by the core. Each takes the
-- engine's handle of a player the core has already checked is logged in
-- with a character the bridge reported loaded, and nothing in it may throw
-- on purpose: a read that throws is `unavailable`, and a command that throws
-- is `unknown`, since the framework may have changed something first.

---What a bridge registers (`rpf.bridge.register`). Checked whole: a field
---that is not what the contract allows refuses the bridge, with one line in
---the server's log naming it.
---
---```lua
----- `qbx` stands for the framework's public API, as the bridge reaches it.
---local bridge = {
---  name = "qbox",
---  version = "1.0.0",
---  contract = { major = 1, minor = 0 },
---  provides = { "characters", "money", "inventory", "jobs" },
---  supports = { "money.accounts", "money.balance", "money.debit", "money.credit", "jobs.current" },
---  tested_with = { "1.21" },
---  running = function() return qbx.started(), qbx.version() end,
---  money = {
---    accounts = function() return { "cash", "bank" } end,
---    balance = function(player, account) return qbx.get_money(player, account) end,
---    debit = function(player, account, amount, reason)
---      if qbx.get_money(player, account) < amount then return nil, "refused", "insufficient_funds" end
---      if not qbx.remove_money(player, account, amount, reason) then return nil, "unknown" end
---      return true
---    end,
---  },
---}
---rpf.bridge.register(bridge)
---```
---@class rpf.BridgeDefinition
---@field name string The bridge's name, `[a-z][a-z0-9_]*`, at most 32 bytes: the framework it reaches, in the log.
---@field version string The bridge's own release, for the log. Independent of the core's and the portal's.
---@field contract { major: integer, minor: integer } The contract it was written for: `rpf.bridge.CONTRACT` when written. A major this core does not speak refuses it; a later minor's calls it lists are left out.
---@field provides rpf.DomainName[] **Authority**: the domains whose records its framework owns. Must be exactly the domains the server's profile marks external, or the bridge stays inactive and players stay at `registered`.
---@field supports string[]? **Capability**: the facade calls it implements, as `<domain>.<call>` (`money.debit`). Each needs its function below, in a domain it provides. A call it does not list is `refused("unsupported")` without reaching it. `characters.current` is never listed: the core answers it from `character_loaded`.
---@field tested_with string[]? The framework versions it was tested against; `1.21` covers `1.21.3`. Outside them the core logs a warning, never refuses.
---@field running fun(): boolean, string? Whether its framework is running, and its version if it can tell. Asked on a native profile, where a running framework is a second economy the log says so of, and on a companion one, for `tested_with`.
---@field start fun(selecting: any[])? Runs once the bridge is active: the profile is fixed and fits. Pick up the players already here: report every character its framework has loaded, with `character_loaded`, and show its selection to each player in `selecting`, the engine handles already at `character_select` (a bridge registering again after its resource restarted), who will not see `players.character_select` again. Players who log in later arrive as `players.character_select`.
---@field stop fun(reason: string)? Runs when the core stops using the bridge while its code still runs (its `start` threw).
---@field money rpf.BridgeMoney? The money calls it supports.
---@field inventory rpf.BridgeInventory? The item calls it supports.
---@field jobs rpf.BridgeJobs? The job call it supports.

---A domain of the profile.
---@alias rpf.DomainName
---| "characters" # Characters, and which one a player has in play.
---| "money" # Accounts and their balances.
---| "inventory" # Items.
---| "jobs" # Employment and duty.

---What a bridge's command answers. `true` once it happened. Otherwise nil
---and a status, and the status must be true of what the framework did:
---
--- - `refused`, and a reason (`insufficient_funds`, `no_space`, …): it
---   checked before calling the framework, and nothing changed.
--- - `unavailable`: it could not ask the framework, and nothing changed.
--- - `unknown`: it called the framework and cannot say what happened (a
---   framework call that returned an error after it may have written).
---
---Only an answer the bridge can prove came before any change may be
---`refused` or `unavailable`. Anything else is read as `unknown`.
---@alias rpf.BridgeResult boolean?

---The money calls (`supports` lists the ones implemented).
---@class rpf.BridgeMoney
---@field accounts (fun(): string[])? The account names a player's money is in (`cash`, `bank`), at most 32, which addons configure which to use from.
---@field balance (fun(player: any, account: string): number?, string?)? A balance: a whole amount within `MAX_AMOUNT` either way, or nil and `not_found` for an account the player does not have.
---@field debit (fun(player: any, account: string, amount: integer, reason: string, op_id: string): rpf.BridgeResult, string?, string?)? Takes money from the player. `amount` is a whole number from 1 to `MAX_AMOUNT`, already checked; `op_id` is the core's, for the framework's own log only: the core runs each op id at most once, and the bridge must not retry.
---@field credit (fun(player: any, account: string, amount: integer, reason: string, op_id: string): rpf.BridgeResult, string?, string?)? Pays money to the player, as `debit`.

---The item calls.
---@class rpf.BridgeInventory
---@field count (fun(player: any, item: string): number?, string?)? How many of an item the player has: a whole number from 0.
---@field give (fun(player: any, item: string, count: integer, op_id: string): rpf.BridgeResult, string?, string?)? Gives the player units of an item; `refused` with `no_space` if they do not fit.
---@field take (fun(player: any, item: string, count: integer, op_id: string): rpf.BridgeResult, string?, string?)? Takes units of an item; `refused` with `insufficient` if the player has fewer.

---The job call.
---@class rpf.BridgeJobs
---@field current (fun(player: any): { name: string, grade: number, on_duty: boolean, employer: string? }?, string?)? The player's job, or nil for none.

---A loaded character, as a bridge reports it.
---@class rpf.BridgeCharacter
---@field key string The framework's own key for it (a `citizenid`): opaque, at most 128 bytes. It stays on this game server: never sent to the portal, never logged.
---@field name string Its name, as the framework shows it; at most 128 bytes.

---What `domains.bridge` carries.
---@class rpf.BridgeState
---@field name string? The bridge.
---@field state "active"|"unavailable"|"available"|"withdrawn" What changed.
---@field reason string? Why, where there is a reason.

---Linked staff's world config placement menu; uses the portable UI and E6.
---@class rpf.api.Placement
local Placement = {}

---Offers installed world types the player may change. Position and facing
---come from the server; the portal rechecks permissions and config version.
---@param player rpf.PlayerHandle The joined, linked staff player.
---@return boolean? opened True if offered.
---@return string? err Why unavailable or refused.
function Placement.open(player) end
