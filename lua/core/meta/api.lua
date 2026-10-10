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
---What is present follows the side: `players`, `staff`, `config` and
---`addons` on the game server, `auth` on the player's client, and
---`VERSION`, `engine`, `events` and `time` on both. Every table in it is
---read-only.
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
---@field players rpf.api.Players? The players on this game server. Server only.
---@field staff rpf.api.Staff? In-game staff: what a linked staff member may do here, account linking, and staff actions for the audit log. Server only.
---@field config rpf.api.Config? Lookups over the config the portal pushed, and linked staff's edits of it in game. Server only.
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
--- - `staff.changed(change)`, an `rpf.StaffChange`, once for each player
---   whose staff permissions here changed: a push from the portal gave them
---   new ones or took some away, or they left. Server only.
--- - `staff.linked(link)`, an `rpf.StaffLinked`, when a player's account was
---   linked to a staff account, and `staff.link_failed(failure)`, an
---   `rpf.StaffLinkFailure`, when it was not. The player has been told
---   either way. Server only.
--- - `auth.required(prompt)`, an `rpf.AuthPrompt`: show the login form.
---   `auth.succeeded(result)`, an `rpf.AuthResult`. `auth.failed(failure)`, an
---   `rpf.AuthFailure`. `auth.password_change_required(change)`, an
---   `rpf.AuthPasswordChange`. `auth.account_deleted(deleted)`, an
---   `rpf.AuthDeleted`, once `delete_account` has deleted the account.
---   Client only.
---@class rpf.api.Events
local Events = {}

---Registers a handler, called on every later emit of the name. A handler
---an addon registers while its code runs (its `start`, a timer, another
---handler) is the addon's, and is removed when the addon stops, so an addon
---that subscribes in `start` is subscribed once however often it restarts.
---@param name string The event name, namespaced like `players.active`. Scripts use their own prefix for their own events.
---@param handler function Called with whatever the emit passes.
---@return function|string|nil handler The same handler, for `off`. Through FiveM's export, a subscription id instead, since a function does not keep its identity across that boundary (`lua/platform/fivem/README.md`). Nil if refused.
---@return "invalid"? err A name that is not a non-empty string, or a handler that is not a function.
function Events.on(name, handler) end

---Registers a handler for the next emit of the name only.
---@param name string The event name.
---@param handler function Called once.
---@return function|string|nil handler The same handler, so it can be removed with `off` before it fires. A subscription id through FiveM's export. Nil if refused.
---@return "invalid"? err As for `on`.
function Events.once(name, handler) end

---Removes every registration of a handler for a name. The function is the
---key, so a script can only remove handlers it holds.
---@param name string The event name.
---@param handler function|string The handler `on` or `once` was given, or the id they returned through FiveM's export.
---@return boolean removed Whether anything was registered.
function Events.off(name, handler) end

---Calls every handler for a name with the given arguments. Names under the
---core's prefixes (`players.`, `config.`, `auth.`, `records.`, `characters.`, `jobs.`, `staff.`, `addons.`, `rpf.`) are refused,
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

---Why `time.after` or `time.every` refused.
---@alias rpf.TimerRefusal
---| "invalid" # The delay or period is not a whole number in range, or `fn` is not a function.
---| "unavailable" # The adapter has not loaded yet.

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
---@return "invalid"|"not_found"|"forbidden"|nil err `invalid` for a bad name or a value that is not a function, `not_found` when no addon of that namespace is loaded, `forbidden` for another addon's namespace.
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
---@field reason string? For a deletion the portal refused, why (`referenced`).

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
---```lua
---local op = rpf.ops.new() -- once per purchase, kept with it
---local ok, status, why = rpf.money.debit(player, "bank", 250, "Spray can", op)
---if ok then
---  rpf.inventory.give(player, "spray_can", 1, rpf.ops.new())
---elseif status == "refused" then
---  -- tell the player why: why == "insufficient_funds", …
---end
---```
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
---@return boolean? ok True once taken.
---@return rpf.FacadeStatus? status Why not.
---@return string? reason For `refused`: `invalid`, `invalid_op`, `expired_op`, `journal_full`, `not_logged_in`, `no_character`, `no_account`, `unsupported`, `insufficient_funds`, `out_of_range`.
function Money.debit(player, account, amount, reason, op_id) end

---Pays money to a player, from the account `economy.addon_account` names.
---@param player any The engine's handle.
---@param account string The player's account's name.
---@param amount integer A whole amount from 1 to 2^53 − 1.
---@param reason string Why; at most 256 bytes.
---@param op_id string From `rpf.ops.new()`.
---@return boolean? ok True once paid.
---@return rpf.FacadeStatus? status Why not.
---@return string? reason For `refused`, as for `debit`.
function Money.credit(player, account, amount, reason, op_id) end

---Whether a call works on this server: `debit` and `credit` need the
---server's addon account set.
---@param call string `accounts`, `balance`, `debit` or `credit`.
---@return boolean supported True if it does.
function Money.supports(call) end

---A player's items, by item slug. Units are plain ones: a stack carrying
---data (a bottle with a note) is a thing of its own the facade leaves alone.
---@class rpf.api.Inventory
local Inventory = {}

---How many of an item a player's character holds.
---@param player any The engine's handle.
---@param item string The item's slug.
---@return number? count The count.
---@return rpf.FacadeRead? err Why not.
function Inventory.count(player, item) end

---Gives a player's character units of an item, all into one container.
---@param player any The engine's handle.
---@param item string The item's slug.
---@param count integer How many, from 1.
---@param op_id string From `rpf.ops.new()`.
---@return boolean? ok True once given.
---@return rpf.FacadeStatus? status Why not.
---@return string? reason For `refused`: `invalid`, `invalid_op`, `expired_op`, `journal_full`, `not_logged_in`, `no_character`, `no_container`, `no_space`.
function Inventory.give(player, item, count, op_id) end

---Takes units of an item from a player's character.
---@param player any The engine's handle.
---@param item string The item's slug.
---@param count integer How many, from 1.
---@param op_id string From `rpf.ops.new()`.
---@return boolean? ok True once taken.
---@return rpf.FacadeStatus? status Why not.
---@return string? reason For `refused`: as for `give`, and `insufficient`.
function Inventory.take(player, item, count, op_id) end

---Whether a call works on this server.
---@param call string `count`, `give` or `take`.
---@return boolean supported True if it does.
function Inventory.supports(call) end

---A player's job.
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
---@class rpf.api.Ops
local Ops = {}

---Mints an op id: one per thing a player does (a purchase), kept with it, so
---sending that command again can never do it twice. It carries when it was
---minted, and is refused (`expired_op`) after a day.
---@return string? op_id The id, or nil before the core has started.
function Ops.new() end

---Why a facade read has no value.
---@alias rpf.FacadeRead
---| "not_logged_in" # The player has not logged in here, or is leaving.
---| "no_character" # They have no character in play.
---| "not_found" # No such account (or item slug).
---| "unavailable" # Whoever owns the domain cannot be asked now.

---How a facade command failed.
---@alias rpf.FacadeStatus
---| "refused" # Nothing changed; the third value says why.
---| "unavailable" # Nothing changed; it could not be asked. Fine to try again later.
---| "unknown" # It may have happened. Never send it again under a new op id.

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
---@field actions table<string, string|false>? `view`, `create`, `edit`, `delete`, each the flag staff need, or false to offer none.
---@field limit integer? The most records of it on a server, at most 50000.

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
---@field hidden boolean? Never shown in the portal.
---@field read_only boolean? Shown, not editable by staff.
---@field engine boolean? Engine-specific data (a model), stored as is.
---@field max_len integer? A string's or text's most bytes.
---@field min_len integer? A string's fewest bytes.
---@field charset "identifier"|"printable"|"any"? What a string may hold.
---@field min number? The least a number may be.
---@field max number? The most a number may be.
---@field values string[]? An enum's values.
---@field to string? What a `ref` names: a type, or `player`, `character`, `employer`, `server`, `item`, `job`.
---@field of string? A list's item kind.
---@field max_items integer? A list's most items.
---@field max_bytes integer? A json field's most bytes.

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

---Links a player's account to the staff account that issued a code, for the
---command a player types it into. The code is sent exactly as typed, and
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
---@field image string? The item's image by content hash (P3): the SHA-256 of the image, 64 lowercase hex digits, nil if staff uploaded none. A player's client fetches it from the portal at `/api/v1/player/items/<slug>/image` with its API token, and may keep what it fetched under this hash, which changes exactly when the image does.

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

---Deletes the player's account at the portal, for good (H6): nobody can log
---in to it again, and its names, identifiers and logins are gone. Needs the
---account's own password; an account linked to a staff account is refused
---`account_linked` until the link is removed on the portal. Ends in
---`auth.account_deleted` or `auth.failed`. Once deleted the state is
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
---| "working" # A login, registration or password change is in flight.
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

---Refusals the domain-neutral facade will return once a server can hand a
---domain to an existing framework (K1, K2). Nothing returns them yet: on an
---RPF server, RPF owns every domain.
---@alias rpf.api.Refusal
---| "domain_external" # The domain (`characters`, `money`, `inventory`, `jobs`) is owned by an existing framework on this server, so RPF's own operation on it is refused. Use the facade, which routes to the bridge.
---| "unsupported" # The active provider does not implement this call. Check `supports` first.
