# The Lua core

The game-side code that is the same on every engine. It is pure Lua: no game
API is called anywhere under `lua/core/`, and it runs under `busted` with no
game and no portal.

The game side is three layers:

1. **Core** (this directory). Protocol, the connection to the portal, config
   persistence, and, from D4 on, the framework modules.
2. **Platform adapter**, one per engine (FiveM D2, Gmod D8, both Milestone 2).
   It fills in a platform table and wires engine events to the core, two lines
   per event. It is the only code that differs between engines.
3. **Mock platform** (D3, `lua/platform/mock/`), which implements the same
   interface for the fake game server in `crates/fake-server/`: the real core,
   against the real portal, with faults injected at the socket.

A new engine is one adapter and one mock. The core and its tests do not change.

## Rules

- **One global.** Everything is under `rpf`. Nothing else is written to the
  global table, because in Gmod every addon shares one Lua state.
  `spec/globals_spec.lua` loads the core, runs it, and compares the global
  table before and after.
- **No engine branches.** The platform declares `engine` and the core reports
  it in `Hello`, but the core never compares against it. A branch on `engine`
  in the core means a platform function is missing.
- **Lua 5.1/5.4 common subset.** FiveM runs Lua 5.4 and Gmod runs LuaJIT, which
  is Lua 5.1. So there is no `//`, no bitwise operators, no `goto`, no `<const>`
  or `<close>`, no `utf8` library, no `table.unpack` or `unpack`, and nothing
  relies on 5.4's integer subtype. Ids are strings, and money is never a float.
- **Every timer goes through the platform clock**, and so do storage and
  logging. The core never touches `os`, `io`, `print` or `coroutine`. That is
  what lets the tests run every backoff and retry instantly and in a fixed
  order.
- **No `require`.** See Loading.

`spec/purity_spec.lua` reads the source to enforce all of these, and
`lua-language-server --check` enforces them again: `runtime.version` is
LuaJIT, so 5.4-only syntax is an error, and `undefined-global` runs with no
game definitions loaded, so a game global is an error too.

## Loading

`init.lua` runs first. It creates `rpf` and declares, in `rpf.files`, which
files each side loads after it and in what order:

```lua
rpf.files.server -- json.lua, platform.lua, events.lua, time.lua, protocol.lua, config.lua,
                 -- client.lua, players.lua, records.lua, sync.lua, handoff.lua,
                 -- join.lua, api.lua
rpf.files.client -- json.lua, platform.lua, events.lua, time.lua, handoff.lua, auth.lua, api.lua
```

Every later file registers itself on `rpf` (`rpf.json = json`) *and* returns
its table. An adapter can therefore load them with anything that runs a file:
Gmod's `include` and plain `dofile` keep the return value, and a resource
manifest that lists the files in this order discards it, which is fine,
because the file has already registered itself. No file calls `require`, whose
search path differs on every engine. A file may read an earlier file's table
while it loads, never a later one, and `api.lua` is last because it fronts
whichever modules its side loaded. `spec/purity_spec.lua` fails on a core file
that no side declares.

Every file also keeps the core table in a local (`local rpf = rpf`), so the
core keeps working after the Gmod adapter replaces the global with the public
API (see The public API).

The client never loads `protocol.lua`, `client.lua`, `players.lua`,
`records.lua`, `sync.lua` or `join.lua`, because the player's client must never hold the server's API key
and has no players to manage.

Then the adapter starts one side:

```lua
local core = rpf -- the adapter keeps this, for the engine hooks below
core.start_server(platform, { url = "wss://…/ws", api_key = "rpf_…" })
core.start_client(platform)
```

On the server it wires two engine events, two lines each:
`core.players.connected(handle)` when the engine hands a player over, and
`core.players.dropped(handle, reason)` when one leaves. Everything else the
core does for a player follows from those and from the client's messages.

## The server platform interface

`meta/platform_server.lua` and `meta/platform_shared.lua` define it as
`---@meta` classes, one per part, so the language server type-checks an
adapter annotated `---@type rpf.ServerPlatform` against them.
`platform.lua` holds the same member list as data, and a test keeps the two in
step.

| Part | Member | What it does |
|---|---|---|
| Engine | `engine` | `"fivem"`, `"gmod"` or `"mock"`. Reported in `Hello`, never branched on |
| Transport | `connect(url, handlers)` | Opens the websocket. `handlers` has `open()`, `message(text)` and `close(reason)`. One connection at a time |
| | `disconnect()` | Closes the open connection or abandons the attempt. Its `close` is still called, and the core ignores it |
| | `send(text) -> boolean` | Sends one text frame. `false` when there is no open connection |
| Http | `http_request(method, url, headers, body, callback)` | `callback(status, body, headers)`, exactly once. `status` is 0 when no response arrived |
| Clock | `now() -> ms` | Wall-clock milliseconds since the Unix epoch |
| | `after(delay_ms, callback)` | Runs `callback` once, later. No cancel: the core ignores a timer it no longer wants |
| Storage | `kv_get(key) -> string?` | Reads a persisted string |
| | `kv_set(key, value?)` | Writes one, or deletes it with `nil`. Strings only, so the core owns the encoding |
| Random | `random_hex(n) -> string` | `n` lowercase hex digits from the best randomness the engine offers |
| Players | `identifiers(player) -> string[]` | Every identifier the engine knows, verbatim. Reference data, never identity |
| | `name(player) -> string` | The in-game name |
| | `kick(player, reason)` | Disconnects a player |
| | `notify(player, message)` | Shows a player a message |
| ToClients | `to_client(player, name, payload)` | Sends a string to one client |
| | `on_client(name, handler)` | `handler(player, payload)`. The platform supplies the sender, and the payload is hostile input |
| Log | `log(level, message)` | `"debug"`, `"info"`, `"warn"` or `"error"`. The core never logs a secret |
| Api | `expose(api)` | Publishes the public API table: through the resource's export table on FiveM, where each resource has its own Lua state, and through the `rpf` global on Gmod, where every addon shares one. Only `rpf.api` is published, never the rest of `rpf` |

A player is an `rpf.PlayerHandle`: whatever the engine uses (a number on
FiveM, an entity on Gmod). The core only hands it back to the platform.

Messages between server and client carry strings, not tables, for the same
reason JSON is bundled: the engines serialize tables differently, and the
core should decide the bytes.

## The client platform interface

`meta/platform_client.lua`. The client has different capabilities and
different trust from the server, so it gets its own interface: `engine`,
`http_request`, `kv_get` / `kv_set` (for the remember token), `now` / `after`,
`to_server(name, payload)` / `on_server(name, handler)`, `log`, and `expose`
(the client's scripts get the public API too, with `auth` in place of
`players` and `config`). It has no websocket, no `random_hex` and no player
management.

## Refusal

`rpf.start_server` and `rpf.start_client` check the platform before doing
anything else, and refuse one that is missing a member, naming every missing
member at once:

```
rpf: the server platform is missing kv_get (function), random_hex (function)
```

Better a loud error in the console at start than a nil call deep inside a
retry.

## Modules

### `rpf.json`

A bundled pure-Lua codec, used instead of the engines' own JSON functions,
which disagree on empty tables and on numbers. The protocol corpus tests go
through it.

- Empty tables are ambiguous, so an unmarked one is refused on encode. Mark it
  with `json.array()` or `json.object()`. Decoded tables carry the mark.
- `null` decodes to `json.null`, not `nil`, so "sent as null" and "left out"
  stay different.
- **Integers outside ±(2^53 − 1) are refused on decode**, not rounded,
  because LuaJIT numbers are doubles. Integer literals are checked digit by
  digit before conversion. Anything else whose magnitude reaches 2^53 is
  refused too. The encoder refuses to produce one.
- Integers are written without a fraction on every Lua, object keys are
  sorted, duplicate keys and trailing data are refused, and nesting is capped
  at `json.MAX_DEPTH`. Decoding never throws.

### `rpf.protocol`

The messages in `crates/rpf-protocol/src/lib.rs`, as schemas: `protocol.decode(direction,
text)` and `protocol.encode(direction, frame)`. A frame is flat, as on the
wire (`frame.type`, `frame.id`, `frame.re`, and the message's fields).

- Unknown fields are ignored at every depth and do not appear in the decoded
  frame. Unknown `type`s are refused, and so is a missing field or one of the
  wrong type. A nullable field must still be present.
- `answered_by` and `reissuable` mirror `Message::answered_by` and
  `Message::reissuable`, and `may_retry` mirrors `RejectCode::may_retry`.
- `redact` replaces the credentials (`api_key`, `ticket`, `nonce`) for logging.

`spec/protocol_spec.lua` decodes and re-encodes every file in
`protocol/corpus/v1/`, the same files `crates/rpf-protocol/tests/protocol.rs` reads. **This is the
Lua side's ratchet:** a corpus file with no decoder here fails, and so does a
decoder with no corpus file. When a variant lands in Rust with its sample, the
Lua suite stays red until `protocol.lua` learns it.

### `rpf.client`

The game server's connection to the portal (`rpf.connection` once started).

- **Correlation.** `connection:send(type, fields, callback)` returns the
  frame's id. The frame waits in the outbox until a frame whose `re` is its id
  arrives, and `callback(reply)` gets that frame (the reply, a `Rejected`, or
  an `Ack`).
- **Retries reuse the id.** After a reconnect, every waiting frame is resent
  byte for byte, in order, under its original id, which is what C3's request
  log relies on. A `Rejected` with `retry` or `rate_limited` resends under the
  same id after a backoff. Any other refusal is final.
- **The outbox is persisted** through `kv_set`, written before a frame is
  sent, so it survives a restart. See The outbox, below, for its layout and
  bounds.
- **The retry window.** When an entry reaches C3's retry window minus a
  margin (7 days minus 12 hours by default), or the portal refuses it as
  `expired`, a reissuable entry (a state report) is re-sent under a fresh id
  and `sent_at`, and anything else is dropped, logged, and its callback called
  with `nil, "expired"`. A long outage never loses a state report and never
  replays a request the portal may have forgotten.
- **A host clock that goes back.** Entries are aged by the host clock, and
  the portal keeps request ids for two windows, which covers a clock
  corrected back by less than one. For a larger step (a VM restored from a
  snapshot whose clock ran fast, a host that booted with a bad clock and
  synced later) the outbox keeps a high-water mark of the clock, persisted
  under `rpf.outbox.clock` by the sweep (at most one write a minute, never
  on an ordinary `send`). So the stored mark can trail the newest entry by
  a minute, and a load raises it to the newest entry's stamp before
  checking. A reading more than `clock_step_tolerance_ms` (30 s) below the
  mark, seen at load, in a sweep, or at `send` before the new frame is
  stamped, is a step: every non-reissuable entry is dropped, logged, and its
  callback called with `nil, "expired"`; every reissuable one is reissued
  under a fresh id and `sent_at`; a portal request still running has its
  timeout restarted from now; and the mark is reset to now. A connection
  whose `Hello` went out before the step is closed (`disconnect`) and made
  again through the usual backoff, before anything is sent: the portal
  reads `sent_at` against the offset it measured at `Hello`, so on the old
  connection a reissued frame would look older by the step, be refused
  `expired`, and be reissued again in a loop. The reissued frames, and
  anything a callback sends meanwhile, go out once, after the new
  `Welcome`. A smaller regress is left alone, but the mark does not move
  down, so several add up until they cross the tolerance. An unreadable
  mark is treated as a step. While an unreadable slot count has halted the
  outbox, the mark is neither checked nor written, so the higher mark
  stays for the process that runs once storage is repaired. The
  tolerance sits under the portal's `SENT_AT_TOLERANCE` (60 s), so a frame
  stamped before a step is reissued or expired here rather than refused as
  from the future, and far under the window, so a regress it misses stays
  inside the portal's margin. The cost is that a step of more than 30 s
  expires requests that might still have been answered; they are joins and
  character creations a player can retry.
- **Reconnects** back off exponentially from 1 s to a 60 s cap, plus up to
  half that again in random jitter, so a portal restart does not bring every
  server back in the same second. A `Hello` refused with a code that may not be
  retried (`unauthorised`, `duplicate_instance`, …) stops the connection for
  good.
- **`instance_id`** is minted once per process start and never persisted.
- **Inbound frames** are decoded as hostile input: one that does not decode is
  logged and dropped. Replies and notices are acked, and a duplicate of one is
  acked again and not handled again. Requests (`apply_command`) go to the
  handler registered with `connection:handle(type, handler)`, under the rules
  in Portal requests, below. Until D5 registers one, a command is answered as
  failed (truthfully: nothing ran), so the portal is never left waiting.

#### Portal requests: the delivery guarantee

A portal request is journalled before its handler runs, and the handler's
reply replaces the journal entry in the same storage slot, with one
`kv_set`. That gives, across reconnects and restarts:

- **At most once.** A request id is handed to a handler once. A duplicate of
  an answered request gets the original reply again, byte for byte under the
  same id. A duplicate while the handler is still running starts nothing, and
  the one reply, which names the request in `re`, answers every copy. A
  duplicate that arrives after the portal acked the reply is ignored.
- **An outcome is never guessed.** If the handler started and no outcome was
  recorded, the answer is `command_applied` with outcome `unknown`, never
  `failed` or `applied`, and the handler is never run again to find out. That
  covers a restart mid-handler (answered at load, before anything is sent), a
  handler that throws, and one that has not replied after
  `request_timeout_ms` (5 minutes). A reply after that, or a second reply, is
  logged and ignored: one command has one outcome.
- **The reply is delivered at least once**: it is an ordinary outbox entry,
  resent under its id until the portal acks it. After the ack the entry is
  deleted and the id is remembered only in memory. A load remembers every
  journalled id too, so a copy that arrives after the ack is ignored in a
  restarted process as well.

The crash windows, in order:

1. Before the journal entry is written: nothing ran and nothing is stored.
   The portal resends, and the request runs then.
2. After the journal entry, before the reply is stored: the game effect may
   or may not have happened, because an engine effect and a `kv_set` cannot
   be atomic. This window is reported as `unknown`, which C4 shows staff as
   "may or may not have been applied". Commands carry their own idempotency
   key (`AdjustBalance.client_id`) and, with F5, a revision, so a handler that
   can check its own effect is how D5 narrows this window further.
3. After the reply is stored: the portal gets that reply, however often it
   asks.

This is **not exactly-once**, and nothing may claim it is. It rests on three
assumptions: `kv_set` is atomic per key and durable when it returns (see
`meta/platform_shared.lua`); the portal records a reply before acking it and
never resends a request it has the reply to; and the game server's storage
survives. A wiped store, or two hosts sharing one, loses the journal as it
loses the outbox.

A request that arrives when `max_requests` (64) are already journalled is
neither run nor remembered, and the portal's next resend gets another chance.
A new kind of portal request is not handed to any handler until
`client.lua`'s `UNKNOWN` table says what it is answered with when
interrupted.

#### The outbox

Each entry is its own key, `rpf.outbox.<slot>`, and `rpf.outbox.slots` holds
the highest slot in use (`rpf.outbox.clock`, the clock's high-water mark, is
the one other key). Adding, answering or reissuing an entry writes that
entry alone, whatever else is queued, and a freed slot is reused, so a load
reads at most as many keys as were ever held at once. Order comes from a
sequence number in each entry, so there is no index to rewrite. An entry is a
seven-line header and then the frame verbatim, not a JSON wrapper, which
would escape every quote in the frame again (up to doubling it) and make a
load parse every byte. The overhead is a fixed ~150 bytes. An entry that does
not parse exactly fails closed: if its header still names a portal request,
that id is never run again and, when its type is readable, it is answered
`unknown` in place; anything else is logged as lost and left in its slot for
a human.

Every byte bound counts an entry at its stored size plus what a reissue could
add (`sent_at` gains `.mmm` when a frame first sent on a whole second is
reissued on a fractional one), so a reissue never takes the outbox, a frame
or a reply past the bound that admitted it.

The bounds, all in `client.DEFAULTS`:

| Bound | Default | Why |
|---|---|---|
| `max_frame_bytes` | 1 MiB | The portal's `limits::MAX_FRAME_BYTES`; a spec reads `limits.rs` to keep them equal. A larger frame would be refused on arrival, so `send` refuses it at once with an error. It also caps any one stored value at 1 MiB plus the header |
| `max_entries` | 2048 | Frames this server originates. A day's outage on a busy server is a few hundred joins and leaves, and C7's reports batch every changed record into one frame per flush, so thousands is headroom, while a load still reads only a couple of thousand keys |
| `max_bytes` | 8 MiB | Their stored size. Eight maximum-size frames, or thousands of ordinary ones. It bounds the disk the engine's store takes and what a load reads at start, which is plain string scanning with no JSON parse |
| `request_share` | 0.5 | Non-reissuable requests (`begin_join`, `redeem_ticket`, `create_character`) may use only half of both, so they cannot crowd out state reports. They are also useless long after the player who asked has gone |
| `max_requests` | 64 | Journalled portal requests, which with their replies have a budget of their own, so a full outbox never stops a command from being answered |
| `max_reply_bytes` / `max_reason_bytes` | 8 KiB / 1 KiB | A reply's `reason` is cut at a character boundary, so replies take at most 64 × 8 KiB beside `max_bytes` |

The platform limits these are sized against are what the adapters must
provide, because there is no adapter yet to measure: whatever store D2
(FiveM's resource KVP) and D8 (Gmod's data store) use has to take one value
of 1 MiB plus the header, and about 9 MiB in total (`max_bytes` plus the
replies' share). Neither documents a smaller cap, and D2 and D8 each confirm
theirs with a test at the bound. If one cannot, the adapter lowers
`max_frame_bytes` and `max_bytes` through the client options.

At capacity, behaviour follows the message type:

- **State reports and notices** (reissuable) use the whole budget. One that
  does not fit is refused, not queued: `send` returns `nil, "outbox_full"`,
  and its callback, if given, is called with `nil, "outbox_full"`. Nothing
  already queued is dropped to make room, and a refusal is never reported as
  a success. The caller keeps the report and sends it again later, when a
  newer one supersedes it anyway.
- **Requests** get the same refusal once they reach `request_share`.
- **Replies to portal requests** are never refused, because they have their
  own budget; a request that would exceed it is not run (above).
- A full outbox logs one warning, not one per refusal, until something is
  answered.

Recovery: entries leave the outbox as the portal answers them, and each
answer frees its slot and its bytes at once, so the next `send` fits. A
restart loads every stored entry even if the bounds have since been lowered,
because dropping one would lose state, and refuses new frames until it
drains. If `rpf.outbox.slots` is unreadable, the core logs an error and
refuses new portal requests and outbound frames. `send` and its callback
receive `"outbox_unavailable"`. The damaged key and entries are left intact:
an operator must restore the correct high slot number and restart the core
before new work can run. Guessing from the current limits could miss a
journalled command in a higher slot after those limits were lowered.

### `rpf.config`

The config the server last applied. `config.apply(platform, version, hash,
snapshot)` checks a snapshot, persists it with its version and hash in one
`kv_set` under `rpf.config.applied`, makes it current, and emits
`config.changed` with `{ version, sections }`: the top-level sections that
differ from the snapshot before, compared by canonical encoding, so key order
never counts as a change. A refused snapshot changes nothing. `config.load`
reads back the version and hash for `Hello` (or `null` for both on a cold
start), and `rpf.start_server` restores the snapshot before connecting, so
lookups answer from the last applied config while the portal is still being
reached.

Typed lookups return copies: `config.item(slug)`, `config.item_base(slug)`,
`config.item_defaults()`, `config.job(slug)`, `config.employer(slug)`,
`config.setting(key)` and `config.version()`. A setting sent as `null` is
`json.null`, apart from one never sent.

Items arrive **resolved** (E3). The portal applies server inheritance, then
each item's base, then the catalog defaults, before it sends a snapshot, so
`config.item(slug)` always has `weight`, `size` and `stack_limit`, plus the
`base` it names if any, and the core never resolves anything. `item_base` is
the base as staff wrote it, for a script that treats every `weapon` alike.
`item_defaults()` is what an item the config does not define behaves as, the
same fallback the portal applies when it validates contents.

The portal sends a `config` request (E2) after `Welcome` unless `Hello`
named its current version and hash, and again whenever a change moves this
server's version. `config.serve`, registered by `rpf.start_server`, applies
it and answers `config_applied`: `applied`, or `failed` with why, keeping
the config it had. It runs through the request journal like a command, so a
resend is answered from the journal and a crash mid-apply is `unknown`; the
next `Hello` names whichever config was stored. What the portal shows staff
as live is this answer, never what it sent.

The snapshot is `protocol::ConfigSnapshot`: `settings` an object by key,
every key present; `items` and `item_bases` (E3), and later `employers` and
`jobs` (E4, E5), arrays of objects keyed by `slug`; `item_defaults` one
object. That is held in one place, `config.SECTIONS`. The protocol decoder
keeps the snapshot whole rather than field by field, so a section not listed
there is kept and reported in `config.changed`, just not indexed, and a
newer portal adding one is never a refusal.

### `rpf.events`

The bus every module talks through. Modules never call each other to say
something happened: a module changes its own state through its own functions
and announces the change here, and anything that cares listens. That keeps
the load order a list rather than a graph, and means a server owner's script
hears exactly what the core's own modules hear.

- `on(name, handler)`, `once(name, handler)`, `off(name, handler)` and
  `emit(name, ...)`. Handlers run in registration order, synchronously. The
  list is taken when an emit starts, so a handler added during it waits for
  the next, and one removed during it is skipped.
- **A handler that throws is logged and skipped**, and the handlers after it
  still run, so one broken script cannot stop a player's join. Emits nested
  `MAX_DEPTH` (32) deep are refused and logged, so a cycle is a log line, not
  a stack overflow.
- **Core event names are reserved.** The public `emit` refuses anything under
  `players.`, `config.`, `auth.`, `records.` or `rpf.`, so a script cannot forge a
  lifecycle event other scripts would believe.

### `rpf.players`

The players on this server and one state machine per connection:

```
connecting → authenticating → registered → character_select ⇄ active
     └────────────┴───────────────┴────────────────┴─────────────┴──→ dropping
```

Every accepted move emits `players.state_changed(player, from)` and then
`players.<state>(player, from)`, each with its own copy. A move a handler
makes is queued and announced after the move that triggered it, so handlers
see moves one at a time, in order. Any other move is refused and changes
nothing. Two kinds of caller move players, through
separate functions that share one transition check:

- **The login gate** (`connecting → authenticating → registered`) is RPF's
  own, on every server whatever framework runs the characters (#75). Only
  `rpf.join` drives it, through `players.authenticating` and
  `players.register`. One account is one player: registering an account that
  is already playing here is refused.
- **`character_select ⇄ active`** is driven through `players.advance(handle,
  to)` by whichever module owns characters on the server: D5 on a native
  server, a framework bridge (K2) on a companion one. `advance` refuses the
  gate's states and `dropping`, so a character owner can neither let a player
  past login nor forget one the engine still has.

Nothing but the login flow is available while `authenticating`. A module that
listens to clients registers through `players.on_client(name, handler)`,
which drops every message from a player who has not logged in, so it cannot
forget the check.

`players.online()` is the shape F2's `OnlinePlayers` resync is built from:
registered players only, `{ player_id, username, name, state, connected_at }`,
sorted by player id, nothing engine-specific. F2 defines and sends the message.

### Held records (`rpf.records`, `rpf.sync`)

C7's half of the consistency rules in `AGENTS.md`. A game server is the
only writer of a character, account or container while it **holds** it, and
the portal writes Postgres directly for one nobody holds. Both rest on one
invariant, enforced here rather than left to each module:

**The core never keeps a record it does not hold.** `rpf.records` is the
only place records live. A record enters only from the portal's `held`
reply and leaves the moment it is released or the portal says this server
does not hold it. `records.get` hands out copies, and returns nil for
anything not held, so a module keeps ids and reads through it every time.

- **Holding.** A registered player's records (everything their account owns
  on this server) are held for their session, and released when they leave.
  Anything else is held with `rpf.sync.hold({ owners = …, records = … })`:
  `owners` holds every live record an owner has here (not transitively: a
  character's own accounts are held through the character). The portal
  refuses the whole hold if any named record is not this server's.
- **Changing.** `records.set_character(id, fields)`,
  `records.set_contents(id, contents)` and `records.transfer(from, to,
  amount, description)`. A transfer needs both accounts held, mints the
  ledger entry's `client_id` here, refuses to overdraw an account without
  `unlimited_balance`, and keeps every balance within ±`MAX_AMOUNT`.
- **Reporting.** A change marks its record, and `flush_interval_ms` (1 s)
  later (a minute while the portal is unreachable, so a long outage cannot
  fill the outbox) every marked record goes in one `state_changed`, each change naming
  its base revision. The record moves to the next revision as it is sent,
  so reports queued behind each other name consecutive revisions, and every
  report waits in the persisted outbox while the portal is unreachable. A
  change the outbox refuses stays marked for the next flush; a batch over
  the frame limit is split.
- **Stale is answered whole.** The portal applies a report all or nothing.
  If a base revision is stale, it answers `resync_required`, and every
  record the report named goes whole in a `resync`, at no lower than the
  portal's revision: this server holds it, so its state is the truth. A
  record the portal says this server does not hold (force-released by
  staff, purged) is dropped and announced with `records.lost`. Ledger
  entries stay unacknowledged until a reply says they landed, so a resync
  carries every one still in doubt; the portal appends each `client_id` once.
- **Releasing.** `rpf.sync.release(refs)` reports each record whole as its
  final state and forgets it at once. A release the outbox cannot take is
  refused and nothing is released, because its final state would be lost.
- **The declaration.** After every `Welcome`, once each hold, release and
  report queued before it has been answered, the server sends
  `declare_holds`: what it holds and at which revision. The portal releases
  anything not declared, which is how a restart, which holds nothing,
  gives back what the old process held, and answers a stale or released one
  as above. New holds wait for its answer, so it can never release one.

Events, all reserved: `records.held(views)`, `records.released(refs)` and
`records.lost(refs, reason)`.

### The login (`rpf.join`, `rpf.handoff`, `rpf.auth`)

The in-game leg of P1 and C6. The client logs in to the portal directly, so
no server-side code handles a password. That is a mitigation, not a
guarantee: the community running the server ships the client code. Every UI
where a player chooses a password shows `auth.PASSWORD_REUSE_WARNING`, which a
spec holds to the portal's `PASSWORD_REUSE_WARNING` word for word.

1. The client's core starts and sends `rpf:client_ready` (again every 15 s
   until it hears back). The server moves the player to `authenticating` and
   sends `BeginJoin` with the engine's identifiers (never `ip:`) and name.
2. On `JoinChallenge` the server sends the client `rpf:join_nonce`: the nonce,
   its lifetime (`expires_at − sent_at`, both the portal's clocks), the
   portal's HTTP address and the server's id.
3. The client resumes silently from the remember token saved for that server
   id, or emits `auth.required` for the form. `login`, `register` and
   `change_password` post to `/api/v1/player/*` with the nonce.
4. The client sends the grant's ticket in `rpf:join_ticket`. The server sends
   `RedeemTicket`, registers the player on `PlayerAuthenticated`, and answers
   `rpf:join_result`. The client emits `auth.succeeded`.

`rpf.handoff` holds the handoff messages' schemas, loaded by both sides. They
are not a portal contract, so they have no corpus, but the server decodes
them as hostile input: size-capped, schema-checked, unknown fields dropped,
each accepted only in the state it belongs to, one portal request per player
in flight, and nonces fetched at most once per 10 s per player (a request
inside that is deferred to the end of the interval, not dropped, because the
client asks once and waits).

**Joins fail closed.** A player who has not logged in within
`auth_timeout_ms` (15 minutes by default, because a new player may be reading
the form and choosing a password) is kicked. The reason says whose fault it
was: if the portal connection is down, a login request went unanswered, the
outbox refused it, or the client reported (`rpf:join_portal_trouble`) that its
own call to the portal failed, the player is told the login service is unreachable
and that it is not a problem with their account. A `BeginJoin` unanswered for
`challenge_timeout_ms` (2 minutes) fails the join early, for the same reason.

On the client, each token is kept by its own rule:

- **Remember token**: `kv_set` under `rpf.auth.remember.<server id>`, saved
  before the ticket is handed over, rotated on every resume. Forgotten only
  when the portal says `invalid_token`; an outage or a stale nonce says nothing
  about it.
- **Session token**: memory only, never `kv`, and never reachable from the
  public API. It refreshes the P2 API token through `/token`, which never
  rotates the remember token.
- **API token**: memory only, refreshed before `api_token_expires_at` (clamped
  to 10 minutes, because the client's clock may be wrong). Always issued since P2; a grant without one (an older portal) is accepted and just never refreshed.

`auth.logout()` forgets the saved login at once, then asks the server for a
fresh nonce for this connection and posts `{ nonce, remember_token }` (#70),
so a token read out of shared client storage cannot log its owner out. It
cancels a login whose portal request is still in flight, but not a ticket
already handed to the server, which may have redeemed it: that result is
honoured, leaving the player logged in for this session with nothing saved,
exactly as a logout after login does. A nonce the portal calls
`invalid_nonce` is replaced once with a fresh one.

Events: `auth.required`, `auth.succeeded`, `auth.failed` (with `code`,
`message`, `during`, and `retry_after` when rate limited) and
`auth.password_change_required`. The form that calls this is the adapter's
(Milestone 2).

### The public API

`rpf.api` (`api.lua`) is the documented, supported surface, and the only
table `platform.expose` publishes: through the resource's export table on
FiveM, and as the `rpf` global on Gmod. Everything else under `rpf` is
internal.

| Member | Side | What |
|---|---|---|
| `VERSION`, `engine` | both | The core's version, and the engine (`"fivem"`, `"gmod"` or `"mock"`) for owners' scripts. The core never branches on it |
| `events` | both | `on`, `once`, `off`, `emit` (core names refused) |
| `players` | server | `get`, `by_player_id`, `list`, `authenticated`, all returning copies |
| `config` | server | `item`, `item_base`, `item_defaults`, `job`, `employer`, `setting`, `version` |
| `auth` | client | `login`, `register`, `change_password`, `logout`, `state`, `account`, `api_token`, `PASSWORD_REUSE_WARNING` |
| `bridge` | — | Reserved for K2 (Milestone 2), nil now |

Every member is a closure over its module or a plain value, never a module
table, the connection or the platform, so nothing internal is reachable, and
every table in it refuses writes, so one script cannot replace `events.on`
for the others or claim `bridge` first. That stops accidents, not attackers:
`rawset` and the debug library reach past it.

`meta/api.lua` is the `---@meta` definition of this surface for server
owners' language servers: add `lua/core/meta/` to `workspace.library` and
annotate the table your script holds `---@type rpf.Api`. It also reserves, for
Milestone 2, `rpf.bridge` and the facade's `domain_external` refusal
(`rpf.api.Refusal`), so nothing assumes RPF always owns characters, money,
inventory and jobs (#75). Nothing in it names a framework or treats an engine
handle as a portable id. `spec/api_spec.lua` holds it to exactly the members
`api.lua` builds.

CI builds an API reference from the annotations
(`lua-language-server --doc=lua/core`) and uploads it as the
`lua-api-reference` artifact, so the reference is always the code's own.

## Testing

```bash
cd lua
busted                                   # whichever Lua busted was installed for
lua-language-server --check=. --checklevel=Warning
```

Run the suite under both LuaJIT and Lua 5.4. `docs/testing.md` has
the commands, including installing busted for each without root.

The suite tests the core against a fake platform it drives by hand
(`spec/support`). The fake game server (`crates/fake-server/`, layer 4 in
`docs/testing.md`) runs the same core on the mock platform against the real portal,
over a real socket, under both Luas; `spec/mock_spec.lua` holds the mock to
the platform interfaces.
