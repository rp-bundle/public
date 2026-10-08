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
                 -- client.lua, players.lua, commands.lua, moderation.lua, inventory.lua,
                 -- records.lua, sync.lua, accounts.lua, handoff.lua, join.lua,
                 -- characters.lua, jobs.lua, edits.lua, api.lua
rpf.files.client -- json.lua, platform.lua, events.lua, time.lua, handoff.lua, auth.lua,
                 -- picker.lua, api.lua
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
`commands.lua`, `moderation.lua`, `inventory.lua`, `records.lua`, `sync.lua`,
`accounts.lua`, `join.lua`, `characters.lua`, `jobs.lua` or `edits.lua`, because the player's client
must never hold the server's API key and has no players or records to
manage.

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
- **Strings are UTF-8 text, both ways.** The portal reads frames as UTF-8
  (websocket text, serde_json), so the encoder refuses a string, or a key,
  that is not UTF-8 (a lone continuation byte, a sequence cut short, an
  overlong form, a surrogate, past U+10FFFF), and the decoder refuses one too.
  The error gives the byte count, never the bytes. The refusal is where the
  frame is built, so `connection:send` returns it at once instead of the
  outbox resending an undecodable report for ever. Two helpers decide the
  rest in one place: `json.is_utf8(s)` for an API that accepts text, which
  refuses it (as `rpf.inventory` does with `malformed`), and
  `json.repair_utf8(s)` for text the core only *reports for display*, which
  becomes U+FFFD as `String::from_utf8_lossy` would write it. The core
  repairs exactly two such strings: the in-game name in `BeginJoin` and the
  reason in `PlayerDropped`, because refusing them would lose a join or a
  drop. Text that is data is never repaired, since a silent change to it is
  worse than a refusal.
- Integers are written without a fraction on every Lua, object keys are
  sorted, duplicate keys and trailing data are refused, and nesting is capped
  at `json.MAX_DEPTH`. Decoding never throws.

### `rpf.protocol`

The messages in `crates/rpf-protocol/src/lib.rs`, as schemas: `protocol.decode(direction,
text)` and `protocol.encode(direction, frame)`. A frame is flat, as on the
wire (`frame.type`, `frame.id`, `frame.re`, and the message's fields).

- Unknown fields are ignored at every depth and do not appear in the decoded
  frame. Unknown `type`s are refused, and so is a missing field or one of the
  wrong type. A nullable field must still be present, with one exception:
  a character's `job` (D7), which the portal leaves out for none so that
  frames recorded before it existed re-encode exactly. Absent and null both
  decode as no job.
- `answered_by` and `reissuable` mirror `Message::answered_by` and
  `Message::reissuable`, and `may_retry` mirrors `RejectCode::may_retry`.
- `redact` replaces the credentials (`api_key`, `ticket`, `nonce`) for logging.

`spec/protocol_spec.lua` decodes and re-encodes every file in
`protocol/corpus/v<VERSION>/`, the corpus of the protocol version this core
speaks, the same files `crates/rpf-protocol/tests/protocol.rs` reads. **This is the
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
  half that again in random jitter, so a portal that went away without
  warning does not get every server back in the same second. **An announced
  restart is waited out instead:** before a deploy closes a socket the portal
  sends `restarting` with `retry_after_ms` (protocol 2, H1), and the
  reconnect that follows the close waits that long plus the same jitter,
  without advancing the backoff, because the portal chose the delay from how
  many servers it was dropping. A core that then finds nothing listening
  falls back to its backoff from the first step. The delay is clipped to
  `max_retry_after_ms` (five minutes), so a portal cannot park a server for
  an hour by mistake, and a `Welcome` forgets a notice that was not followed
  by a close. The notice is never acked: the socket is closing.
  A `Hello` refused with a code that may not be
  retried (`unauthorised`, `duplicate_instance`, …) stops the connection for
  good, and so does a `Welcome` naming a protocol version other than
  `rpf.protocol.VERSION`. A portal that no longer serves this core's protocol
  refuses `Hello` as `malformed` with a reason saying which side to upgrade,
  which is logged as the connection stops
  ([Compatibility](../../docs/compatibility.md)).
- **`instance_id`** is minted once per process start and never persisted.
- **Inbound frames** are decoded as hostile input: one that does not decode is
  logged and dropped. Replies and notices are acked, and a duplicate of one is
  acked again and not handled again. The ack goes out before the frame is
  acted on, so it precedes anything its callback sends: the portal reads a
  `player_authenticated`'s ack as the moment this server learned of the join
  (F2), and a drop the callback reports must not look older than it. Requests (`apply_command`) go to the
  handler registered with `connection:handle(type, handler)`, under the rules
  in Portal requests, below. `rpf.commands` is the `apply_command` handler
  (Staff commands, below), and a command no module registered is answered as
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
   can check its own effect is how F5 narrows this window further.
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
`config.item_defaults()`, `config.employer(slug)`,
`config.department(employer, slug)`, `config.job(employer, slug)`,
`config.starting_accounts()`, `config.default_job()`,
`config.paying_account(name)`, `config.paying_accounts()`,
`config.setting(key)` and `config.version()`. A department's or a job's slug
is unique only within its employer (E4), so they are looked up by both: two
employers may each have an `officer`. Only employers the server runs are
config; a player's business is never in it. A setting sent as `null` is
`json.null`, apart from one never sent.

Items arrive **resolved** (E3). The portal applies server inheritance, then
each item's base, then the catalog defaults, before it sends a snapshot, so
`config.item(slug)` always has `weight`, `size` and `stack_limit`, plus the
`base` it names if any, and the core never resolves anything. `item_base` is
the base as staff wrote it, for a script that treats every `weapon` alike.
`item_defaults()` is what an item the config does not define behaves as, the
same fallback the portal applies when it validates contents.

`new_character` (E5) arrives **checked**. `config.starting_accounts()` is
what the portal opens, and funds with ledger entries from the server's
starting funds, when it creates a character; the core never pays a starting
balance itself, so a resent `create_character` cannot create money twice.
`config.default_job()` is `{ employer, job }`, always a job `config.job`
finds: when the `economy.default_job` setting names a job this server does
not have (deleted, or inherited from a parent whose employers it does not
share), the portal sends no default job, and applying the snapshot logs a
warning naming the setting's job. `rpf.jobs` gives a new character the
default job (below). The starting funds account is the portal's
alone and is never handed to a hold.

Jobs carry what `rpf.jobs` (D7) needs: every job a `rank` (0 to 1000,
compared only within its employer) and a paid one a `salary` per pay period,
and an employer that pays salaries its `payroll`, the name of one of the
server's `paying_accounts`. They are fields of the entries `config.job` and
`config.employer` already return, so nothing indexes them separately.

`paying_accounts` (#169) names the accounts this server pays out of, each
`{ id, name }`, found by name with `config.paying_account(name)`: the
sources `rpf.accounts.pay` draws on. Only which accounts; their balances are
live state and arrive with the hold `rpf.accounts` takes of them (below).
Neither lookup is in `rpf.api` yet, like `rpf.accounts` itself.

The portal sends a `config` request (E2) after `Welcome` unless `Hello`
named its current version and hash, and again whenever a change moves this
server's version. `config.serve`, registered by `rpf.start_server`, applies
it and answers `config_applied`: `applied`, or `failed` with why, keeping
the config it had. It runs through the request journal like a command, so a
resend is answered from the journal and a crash mid-apply is `unknown`; the
next `Hello` names whichever config was stored. What the portal shows staff
as live is this answer, never what it sent.

The snapshot is `protocol::ConfigSnapshot`: `settings` an object by key,
every key present; `items`, `item_bases` (E3) and `employers` (E4),
arrays of objects keyed by `slug`; `employer_departments` and `employer_jobs` (E4), arrays of
objects keyed by `employer` and `slug` together (never a `jobs` section,
which cores before E4 indexed by `slug` alone); `item_defaults` and
`new_character` (E5) one object each, `new_character` checked for shape but
not indexed. That is held in one place, `config.SECTIONS`. The protocol decoder
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
  `players.`, `config.`, `auth.`, `records.`, `characters.`, `jobs.` or `rpf.`, so a
  script cannot forge a lifecycle event other scripts would believe.

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
  to)` by whichever module owns characters on the server: `rpf.characters`
  (D5, below) on a native server, a framework bridge (K2) on a companion one. `advance` refuses the
  gate's states and `dropping`, so a character owner can neither let a player
  past login nor forget one the engine still has.

Nothing but the login flow is available while `authenticating`. A module that
listens to clients registers through `players.on_client(name, handler)`,
which drops every message from a player who has not logged in, so it cannot
forget the check.

`players.online()` is what F2's `online_players` resync is built from:
registered players only, `{ player_id, username, name, state, connected_at }`,
sorted by player id, nothing engine-specific. `rpf.join` sends it (below).

### Staff commands (`rpf.commands`, `rpf.moderation`)

Every staff command arrives as one request type, `apply_command`, so
`rpf.commands` is its one handler: it looks the command's name up among the
handlers modules registered with `commands.register(name, handler)` and
replies `command_applied` with what the handler reports. A handler runs the
command at once and returns `true`, or `false` and a reason for staff;
throwing is answered `unknown` by the connection, because it may have done
part of the work. A command nobody registered is `failed`. Adding a command
is a decoder entry in `rpf.protocol` and a `register` call in the module
that owns it, so no two modules compete for `apply_command`.

`rpf.moderation` registers `kick` (F4): it disconnects the player logged in
to the command's account on this server, with the portal's reason as the
message their game shows, and answers `failed` (`moderation.NOT_ONLINE`) for
anyone else, kicking nobody. The portal only sends a kick for a player its
online list has, so that is a player who left while it was on its way.
Warnings and bans need nothing here: a warning stays on the portal, and a
ban arrives as a kick and as a refusal at the next login.

`rpf.edits` registers the record commands (F5): `adjust_balance`,
`give_item`, `take_item`, `move_item`, `edit_character` and
`delete_character`, the portal's edits of a character, an account or a
container this server holds. Each names the revision the staff member saw,
and is applied only if `records.current(kind, id, revision)` says the record
is held at exactly that revision with no change of this server's own still
to report; anything else is `failed` with a reason for staff
(`edits.REASONS`), and nothing changes. A command is made through the calls a
script uses (`records.set_character`, `records.adjust`,
`inventory.apply_edit`, `characters.remove`), so it keeps every rule they
keep, and the change is flushed (`sync.flush`) before the answer, so the
portal has the new state when it reads `applied`. `delete_character` lets
the character and everything it owns go, with their final state (a player
with it in play goes back to choosing first); the portal purges them once
it has the answer.

### Held records (`rpf.records`, `rpf.sync`)

C7's half of the consistency rules in `docs/architecture/data-model.md`. A game server is the
only writer of a character, account or container while it **holds** it, and
the portal writes Postgres directly for one nobody holds. Both rest on one
invariant, enforced here rather than left to each module:

**The core never keeps a record it does not hold.** `rpf.records` is the
only place records live. A record enters only from the portal's `held`
reply and leaves the moment it is released or the portal says this server
does not hold it. `records.get` hands out copies, and returns nil for
anything not held, so a module keeps ids and reads through it every time.

- **Holding.** A registered player's records (everything their account owns
  on this server) are held for their session (`sync.hold_session`, announced
  with `records.session(player_id, err, serial)`), and released when they leave.
  The server's paying accounts are held by `rpf.accounts` after every
  `Welcome` (#169, below).
  Anything else is held with `rpf.sync.hold({ owners = …, records = … })`:
  `owners` holds every live record an owner has here (not transitively: a
  character's own accounts are held through the character). The portal
  refuses the whole hold if any named record is not this server's. A hold
  is sent once every report and release queued before it has been answered
  (and any resync recovering a stale or refused one, queued or still to be),
  because the portal can ask for a frame again and answer the ones behind
  it first: what `held` hands over then includes everything reported, so a
  record released and held again comes back as this server left it. A
  record released while a hold naming it was in flight is not kept when
  that hold's reply arrives: it is given straight back. A player's hold the
  outbox refuses is tried again as the outbox drains.
- **Changing.** `records.set_character(id, fields)`,
  `records.set_job(id, ref)`, `records.set_contents(id, contents)` and
  `records.transfer(from, to, amount, description)`. A character's job
  (D7) is `{ employer, job }` or nil, checked here for shape only (whether
  it is a job on this server is `rpf.jobs`'s rule), and reported as
  `employment`: in a change, `null` when the job did not change and
  `{ job = null }` when it changed to none, since a null field in a change
  means unchanged; in a whole report, always `{ job = … }`. A transfer needs both accounts held, mints the
  ledger entry's `client_id` here, refuses to overdraw an account without
  `unlimited_balance`, and keeps every balance within ±`MAX_AMOUNT`.
  A description is at most `records.MAX_DESCRIPTION_BYTES` (256).
  A character's names are trimmed of the portal's whitespace (Rust's
  `str::trim`, the Unicode `White_Space` set, `records.WHITESPACE`, which a
  spec holds equal to `characters::NAME_WHITESPACE`; Lua's `%s` would miss
  U+00A0) and refused if then blank. Names, trimmed, and a server-specific gender are at most
  `records.MAX_NAME_BYTES` (64), the portal's
  `limits::MAX_CHARACTER_NAME_BYTES`, which it checks on every write of a
  character, so a rename here never becomes a report it refuses.
  A staff adjustment (F5) is `records.adjust(account, funds_account,
  amount, client_id, description)`: one entry between the held account and
  the server's funds account, which this server never holds, under the
  portal's `client_id`, so it is made once however often it is sent. The
  portal accepts an entry naming its funds account only as the adjustment it
  asked for.
  Contents are validated whole by `rpf.inventory` (below) against the
  container's flags and the config's catalog, and refused as `"invalid"`
  with the rule they break, so nothing the portal would refuse is ever
  reported. Contents the portal could not even decode are `malformed`: a
  frame carrying them would fail before the portal read it, so a release
  would end nothing.
- **Reporting.** A change marks its record, and `flush_interval_ms` (1 s)
  later (a minute while the portal is unreachable, so a long outage cannot
  fill the outbox) every marked record goes in one `state_changed`, each change naming
  its base revision. The record moves to the next revision as it is sent,
  so reports queued behind each other name consecutive revisions, and every
  report waits in the persisted outbox while the portal is unreachable. A
  change the outbox refuses stays marked for the next flush; a batch over
  the frame limit is split. An account reports at most
  `max_transactions_per_report` (256) ledger entries at a time and the rest
  in the reports that follow, so a backlog built up through an outage never
  outgrows a frame.
- **A refused report is taken apart.** A report the portal refuses outright
  (contents that no longer fit after a catalog change, say) lands nothing,
  and its frame leaves the outbox. Every record it named goes again whole,
  since its changes were cleared as the frame was queued and an account's
  report is never stale, so nothing else would send them again. Each goes
  in a frame of its own until one of its reports is applied, so one change
  the portal will not take cannot hold back the others. A record refused
  alone goes again with the next flush, not in a loop.
- **Stale is answered whole.** The portal applies a report's characters and
  containers all or nothing; ledger entries on a held account it appends
  whatever else it makes of the report, since they have no state to be
  stale against.
  If a base revision is stale, it answers `resync_required`, and every
  record the report named goes whole in a `resync`: this server holds it,
  so its state is the truth. Every whole report (a resync or a release)
  takes a revision of its own, one past the higher of this server's and
  the portal's, so a late resend of an older one cannot land over it. A
  record the portal says this server does not hold (force-released by
  staff, purged) is dropped and announced with `records.lost`. Ledger
  entries stay unacknowledged until a reply says they landed, so a resync
  carries every one still in doubt; the portal appends each `client_id` once.
  An account with more of them than one report carries sends the oldest,
  and the next whole report only once that one is answered, so no whole
  report can overtake an earlier one and leave entries behind.
- **Releasing.** `rpf.sync.release(refs)` flushes everything marked, then
  reports each record whole as its final state and forgets it at once. Final
  states too large for one frame together go in several. A record whose
  final state cannot be queued whole (the outbox is full, it is too large
  for any frame, or it is an account with more unacknowledged entries than
  one report carries: `"backlog"`) is not released, because some of its
  final state would be lost, and the call says so. A departing player's release that could not be queued
  is tried again whenever a frame leaves the outbox, unless they have come
  back.
- **After a restart** the held records are gone from memory, but the reports
  the old process queued are still in the outbox and go out first. One the
  portal finds stale cannot be answered with a resync, so the connection
  sends it again as it is (`on_orphan`) for as long as a report queued
  before it is unanswered: that one was asked for again and is on its way.
  With nothing before it left it gets `orphan_retries` more tries, and one
  naming a record no longer held here is dropped at once.
- **The declaration.** After every `Welcome`, once each hold, release and
  report queued before it has been answered, the server sends
  `declare_holds`: what it holds and at which revision. The portal releases
  anything not declared, which is how a restart, which holds nothing,
  gives back what the old process held, and answers a stale or released one
  as above. New holds wait for its answer, so it can never release one.

Events, all reserved: `records.held(views)`, `records.released(refs)`,
`records.lost(refs, reason)` and `records.session(player_id, err, serial)`,
`serial` being the player's connection the hold was sent for.

### `rpf.inventory`

What a held container holds, and the moves a server makes on it (D6). Server
only, and internal for now: the public inventory calls are K1's
domain-neutral facade (`docs/architecture/framework-integration.md`), which
routes to this module when RPF owns inventory.

**One validator, on both sides.** `inventory.validate(contents, flags,
catalog)` is a port of the portal's `ContainerContents::validate`: the same
rules in the same order, so the two agree on the verdict and on the first
rule broken, which comes back as the portal's `ContentsError` serialises
(`{ error = "too_heavy", limit = 19, actual = 20 }`):

1. `wrong_layout`: grid contents need a `grid` flag, and list contents must
   not have one.
2. `too_many_stacks`: at most `max_stacks` stacks or placements.
3. `data_too_large`: no stack's `ItemData` over `max_data_bytes`, measured as
   serde_json writes it (an absent one is `{}`, two bytes).
4. Each stack in order: `empty_stack`, then `stack_too_large` past the
   item's stack limit, or past one in an `unstackable` container.
5. `duplicate`: one stack per item in an `unstackable = false` container.
6. `too_heavy`: over `max_weight`, inclusive.
7. Each placement in order: `out_of_bounds`, then `overlap`, naming the
   first cell claimed twice, walking each placement column by column.

Two refusals are Lua's own: `malformed`, contents the portal could not decode
(a wrong shape, a count that is not a `u32`, text that is not UTF-8), and
`unknown_flag`, a flag from a newer portal this core cannot enforce. The
first flag of each kind counts, as on the portal, and `server_specific`
flags are ignored.

**The shared corpus.** Neither validator is tested against the other.
Both are held to the cases in `protocol/corpus/containers/`
(`spec/containers_spec.lua` here, `crates/rpf-domain/tests/containers.rs`
there), each a container's flags, contents and the exact error expected,
and every `ContentsError` variant needs an invalid case: both suites read
the variants out of the Rust source.

**The catalog** is the config's (`inventory.catalog()`): the items as the
portal resolved them and `item_defaults` for anything else, so an item the
config has not caught up with behaves as the portal assumes. The two size
bounds are not in the snapshot; `MAX_DATA_BYTES` (4 KiB) and `MAX_STACKS`
(500) mirror `ItemCatalog::default`, and so does `DEFAULTS`, used before any
config has arrived. A spec reads the Rust default to keep them equal.

**Data is measured exactly as the portal measures it.** The portal re-encodes
`ItemData` with serde_json, which differs from `rpf.json`: it writes DEL raw,
and a fraction in Ryu's shortest form (`0.00001234`, `1e-7`) where C's `%g`
writes `1.234e-05`. So the size is computed for serde's form, not taken from
what this side sends. The portal parses floats exactly (`float_roundtrip`), or
a fraction could come back an ulp off and measure a byte longer there.

**Moves.** Each reads the container from `rpf.records`, changes a copy,
validates the result and hands it to `records.set_contents`, which
validates it again and marks it for the next report. Refused, nothing
changes, and a move between two containers validates both before writing
either.

| Call | What |
|---|---|
| `add(id, item, count, opts)` | Tops up stacks of the same item and identical data, then starts new ones within the stack limit. In a grid, new stacks take the first free spots, row by row, upright before turned; `opts.position` (and `rotated`) puts them in one placement there, or onto the matching placement already there. `opts.data` is the units' `ItemData` |
| `remove(id, item, count, opts)` | Takes from the last stacks of the item whose data is identical to `opts.data` (none by default), so removing water never takes the bottle with a note in it |
| `move(from, index, to, opts)` | Moves `opts.count` units (the whole stack by default) of the stack or placement at `index`, with its data, to where `add` would put them. `to` may be `from`: a new spot in a grid |
| `split(id, index, count, opts)` | Splits units into a new stack with the same data: next to it in a list, at `opts.position` or the first free spot in a grid. Never merges |
| `count(id, item)` | Units of an item across every stack |

`inventory.edit(contents, flags, catalog, edit)` is the staff edits' pure
twin of the portal's `ContentsEdit::apply` (F5): `give` (units with no data,
where `add` would put them), `take` (units off the stack at an index,
whatever its data) and `move` (a whole grid placement to a new cell), with
indexes from zero as the wire carries them, and the result validated whole.
The portal works an edit out with its port before it sends it, so both are
held to `protocol/corpus/containers/edits/`. `inventory.apply_edit(id,
edit)` makes one on a held container.

Each returns `true`, or `nil, err` with `err` one of `not_held`,
`invalid_argument`, `no_stack`, `insufficient`, `no_space`, or `invalid` plus
the refusal (and, for a move, which container broke the rule). A container
this server does not hold, or no longer holds, is never changed.

A stack's `data` is the server's own: nothing here reads it, a move or
split carries it as it is, two stacks merge only when their data encodes
identically, and it is reported byte for byte.

### Characters (`rpf.characters`, `rpf.picker`)

A logged-in player's characters (D5): list, create, select and switch. Server
only for the decisions; `rpf.picker` is the client half the character select
screen (the adapter's, Milestone 2, like the login form) calls. Both are
internal for now: the public character calls are K1's domain-neutral facade
(`docs/architecture/framework-integration.md`), which routes here when RPF
owns characters.

**Everything is a held record (C7)**, so no protocol message lists or
selects characters: holding already does both, and a second way to hand
records over would break "the core never keeps a record it does not hold".

- **Listing.** A player's session hold (owners: the player) brings every
  character their account has here. When it lands (`records.session`) the
  player moves `registered → character_select` and their client is sent the
  list. `characters.list(player_id)` reads `rpf.records` every time.
- **Creating** is `create_character` (owner: the player). The portal opens and
  funds the starting accounts from the server's starting funds in the same
  transaction (E5), so nothing here pays a starting balance, and a resent
  request, replayed from the request log, pays nothing twice. The new
  character is then held for the session; it is not selected. How many a
  player may have is the portal's `characters.max_per_player` setting,
  which the portal enforces for every caller, so this module reads it from
  the config rather than keeping a bound of its own.
- **Selecting** holds the character's own records (owners: the character),
  its accounts and containers, and only once they are here moves the player
  to `active` and emits `characters.selected`: a character is never in play
  without its money.
- **Switching** releases the character in play's own records first, with
  their final state, moves the player back to `character_select` and emits
  `characters.deselected`, then selects the next. The hold for the next one
  waits for that release to be answered, as every hold waits for the reports
  queued before it. A record whose final state the outbox cannot take yet
  stays held for the session and is released when the player leaves; the
  switch is not refused for it.
- **Lost records.** If the portal takes the character in play away
  (force-release, purge), the player goes back to `character_select` and
  whatever the character owns that is still held here is released, as a
  put-away does. Every player's session (and character in play) is held
  again, so whatever is still theirs comes back; until it lands their list
  counts as stale and `create` waits. While a character in play's records are held
  again the player counts as `busy`, so they cannot switch or put it away
  under that hold; a character that goes away meanwhile has whatever the
  hold brings back released at once. If the portal refuses to hand them
  back, the character is put away (a `select` result with `unavailable`)
  and the player chooses again, from where selecting it retries.

Everything is held through the player, so it is all released when they
leave, whatever is selected.

`characters.remove(id)` lets a character go for a staff deletion (F5): a
player with it in play is put away first, then it and what it owns still
held here are released with their final state, and its player's client gets
the list without it. Refused as `busy` while its player has a request in
flight, and refused if the release cannot be queued.

| Call | What |
|---|---|
| `list(player_id)` | The player's held characters, as copies, by name |
| `loaded(player_id)` | Whether their session hold has landed, so `list` is complete |
| `selected(player_id)` | The character in play, as a copy, or nil |
| `create(handle, fields, callback)` | Names trimmed and at most `MAX_NAME_BYTES` (64), gender `"male"`, `"female"` or `{ server_specific = … }` (also at most 64). At most `max_per_player()` per player |
| `max_per_player()` | The portal's `characters.max_per_player` setting from the config in force, or `MAX_CHARACTERS` (40, the portal's `limits::MAX_CHARACTERS_PER_OWNER`, so the list always fits in what the client reads) without a usable one. The portal refuses a create past it too, as `forbidden` |
| `select(handle, id, callback)` | One of the player's own held characters, switching from the one in play |
| `deselect(handle)` | Back to `character_select` |

Each returns `true` (under way) or `nil, err`: `not_ready` before the
characters are loaded (and, for `create`, while the list may be missing one
of theirs: a created character whose hold failed, a create the portal never
answered, or a refused re-hold, after each of which the session is held
again and a client's list request retries it), `busy` while one of the player's requests is in
flight (one at a time, so a client cannot queue a flood of creations),
`not_found` for a character that is not theirs here (another player's and a
missing one are one answer), `invalid`, `limit`. The callback gets the
character, or the portal's refusal code, `unavailable`, or `gone` if the
player left first.

**The client messages** (`rpf.handoff`, decoded against their schemas,
reaching the module only through `players.on_client`):

| Message | Direction | Fields |
|---|---|---|
| `rpf:characters_request` | client → server | none: send the list again (and retry a failed load) |
| `rpf:characters` | server → client | `characters` (each `id`, `first_name`, `last_name`, `gender`), `selected`, `truncated` (set when the list was cut short to fit `MAX_LIST_PAYLOAD`, keeping the character in play: only a portal that bounds neither names nor characters per player can make one that long, #168) |
| `rpf:character_create` | client → server | `first_name`, `last_name`, `gender` (a string: `"male"`, `"female"`, or the server's own option) |
| `rpf:character_select` | client → server | `id` |
| `rpf:character_deselect` | client → server | none |
| `rpf:character_result` | server → client | `during` (`create`, `select`, `deselect` or `load`), `ok`, `id`, `reason` |

On the client, `rpf.picker` keeps the last list (`list()`, `selected()`),
sends `create`, `select`, `deselect` and `refresh`, and emits
`characters.listed(list, selected, truncated)` and `characters.result(result)`.

Events on the server, reserved: `characters.created(player, character)`,
`characters.selected(player, character)` and
`characters.deselected(player, character_id)`.

### Money (`rpf.accounts`)

Balances, transfers and payments on held accounts (D5). Server only, and
internal for now, like `rpf.characters`.

**A balance is a fold over the ledger.** An account's balance here is the
one the portal folded when it handed the account over, moved by every entry
made since: a running balance, kept only for speed, that always equals the
fold. **No function sets a balance**; money moves only as a ledger entry
through `records.transfer`, which mints its `client_id` from
`platform.random_hex` (C7's idempotency key) and marks both accounts for the
next report.

| Call | What |
|---|---|
| `balance(id)` | A held account's balance, or `nil, "not_held"` |
| `get(id)`, `owned_by(kind, id)` | Held accounts, as copies, by name |
| `transfer(from, to, amount, description)` | Between two held accounts. Refused (`insufficient_funds`) if it would overdraw the payer, unless it has `unlimited_balance` |
| `pay(from, to, amount, description)` | Server-sourced money: a transfer whose payer must have `unlimited_balance` and be owned by the server or an employer (a treasury or payroll account the server holds), refused `not_a_source` otherwise, the owner included because staff can set the flag on any account, so a script that means "the server pays" cannot drain a player's account. The server's paying accounts are such sources, held for it (below); its starting funds are never held, so never a source |
| `hold_paying()` | Holds every paying account the config lists that is not held or being asked for; run after each `Welcome`, on a config that changes `paying_accounts`, and when one is lost |
| `fold(account_id, ledger)` | The fold itself |

**The paying accounts are held for the server (#169).** Staff open them in
the portal, and the config lists them (`config.paying_account(name)`).
`accounts.start`, run by `rpf.start_server` after `rpf.sync`, holds every
one after each `Welcome`, chained after the declaration so the hold waits for
its answer and can never be released by it, and again whenever a config
changes `paying_accounts`, so `pay` has a source without a script holding
one:

```lua
local treasury = rpf.config.paying_account("treasury")
rpf.accounts.pay(treasury.id, wallet_id, 250, "Wage")
```

They are held for no player, so no departure releases them; a restart gives
them back with the declaration and holds them again, and so does a
declaration that says one was force-released while this server was away
(`records.lost`). Until a hold lands,
`pay` from one is `not_held`. A hold the portal refuses, or that never
reaches it, is logged and asked for again at the next `Welcome` or config
change.

**No floats, and no Lua 5.4 integers.** Every amount is a whole number from
1 to `protocol.MAX_AMOUNT` (2^53 − 1), the widest integer a double holds
exactly, and every balance stays within ±`MAX_AMOUNT` (`out_of_range`
otherwise). An amount past it never arrives: `rpf.json` refuses one on
decode rather than round it. `fold` keeps its running total in two exact
parts (`high * 2^32 + low`), so a total that passes 2^53 on the way to its
answer is still exact, on LuaJIT as on 5.4.

**The shared ledger cases.** `fold` and the portal's
`money::checked_balance` are held to the same cases in
`protocol/corpus/ledger/cases/` (`spec/ledger_spec.lua` here,
`crates/rpf-domain/tests/ledger.rs` there), never to each other: an account,
a ledger, and the balance or the error expected (`invalid_amount`,
`out_of_range`). A case whose amount the codec will not decode (2^53) is
refused here before any fold, and expects `invalid_amount`. The spec also
replays each case as transfers on held accounts, so the running balance is
held to the same answers.

### Jobs (`rpf.jobs`)

Characters' jobs, duty and salaries (D7): the game side of the employers,
departments and jobs staff define in the portal (E4) and of the default job
(E5). Server only, and internal for now, like `rpf.characters`: the public
jobs calls are K2's domain-neutral facade
(`docs/architecture/framework-integration.md`, `jobs.current`), which will
route here when RPF owns jobs. Until then the game server's own code calls
it directly.

**A job is part of the character**, a held record, so it changes only
through `records.set_job` and goes to the portal with the character's next
report, as `employment` (above). Nothing here keeps a copy: a character this
server does not hold has no job here.

| Call | What |
|---|---|
| `job_of(character_id)` | The job, `{ employer, job }`, and its definition from the config (`config.job`), as copies. Nil and nil for no job or a character not held; the definition is nil for a job the config no longer has |
| `set_job(character_id, employer, job)` | Gives a job, or takes it away with both nil. `not_held`, `invalid` (not two strings, nor both nil), `not_found` (not a job in the applied config). The job it has already is a success that changes nothing. A change takes the character off duty first |
| `on_duty(character_id)` | `not_in_play` unless some player has it selected, `no_job` without a job in the config. Already on duty is a success |
| `off_duty(character_id)`, `is_on_duty(character_id)` | Off duty is always a success |
| `rank_of(character_id)` | The job's configured `rank`, or nil with no job in the config |
| `has_rank(character_id, employer, minimum)` | Whether its job is at that employer and at least `minimum`: a job slug there, whose rank is the bar, or a whole number. False for another employer, an unknown slug, or no job in the config |
| `pay_period_ms()`, `salary_account()` | The settings below as they apply now. Internal |

**Hiring is not staff-only.** A player can run a business (an employer a
player owns), so `set_job` is a plain script call, and who may hire whom is
the calling script's rule. What the core holds to is that the job is one of
the server's in the applied config.

**The default job.** When `rpf.characters` announces a new character
(`characters.created`) with no job, it is given `config.default_job()`. With
none to give while the `economy.default_job` setting names one, the setting
names a job this server does not have: that is logged, as E5 logs it when
the config is applied, and the character starts with no job.

**Duty is memory only**, never stored or reported, because it is a fact
about the character in play now. A character goes on duty only while a
player has it selected, and goes off duty, with the event, when it is put
away, when its player leaves, when its record is released or lost, when its
job changes, and when the config drops its job.

**Salaries.** While a character is on duty, each pay period
(`economy.salary_interval_minutes`, 15 without a whole number from 1 to
1440), measured from going on duty, pays the job's `salary` from the
employer's `payroll` account (`config.paying_account(payroll)`, held for the
server by `rpf.accounts`) into the character's held account named by
`economy.salary_account` (`bank` without an identifier), through
`accounts.pay(source, destination, salary, "Salary: <employer>/<job>")`: one
ledger entry, appended once. The timers are `platform.after`, so the mock
runs a shift in an `advance`. They cannot be cancelled, so each shift has a
token, and a timer from an ended shift does nothing. The config and settings
are read again at every payment, so a change mid-shift applies from the next
one; a payment that cannot be made (no salary, no payroll, a payroll that is
not a paying account or not held, no such account on the character) is
skipped and logged at `warn` (an unpaid job at `debug`), and the shift goes
on. Nobody is paid off duty or out of play.

**A job removed from the config** stays on the character, since staff may
restore it, but counts as no job meanwhile: no rank, no duty, no salary.
Applying a config that drops a job a held character has logs it once, naming
the job (again only if it comes back and goes again), and takes everyone on
duty in it off duty. `set_job(id, nil, nil)` still clears it.

Events, reserved: `jobs.changed(character_id, job, previous)` (each
`{ employer, job }` or nil), `jobs.duty(character_id, on_duty)` and
`jobs.paid(character_id, amount, client_id)`, `client_id` being the ledger
entry's.

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

**The online list (F2).** The portal lists a player as online on this server
when it answers `RedeemTicket`, and unlists them on `player_dropped`. It
forgets the whole list when the connection goes, so after every `Welcome`,
once the outbox has been flushed, `join.resync` sends `online_players`: every
player `registered` or later, by `player_id`, and nobody who is leaving. The
portal weighs it against the joins and drops around it by when each was sent
(the module docs of `rpf_backend::ws::presence`), so it waits for nothing. A
`player_authenticated` the server does not act on, because the player left or
was kicked while it was in flight, or because a restart lost the login
whose `redeem_ticket` the outbox resent, is answered with a `player_dropped` for
that account, unless the account is playing here under another handle, so
the portal does not list a player who never arrived. A `player_dropped` the
host clock would stamp below the newest presence event (a join acted on, the
resync, a drop) sent on this connection, after the clock went back by less
than the outbox notices, would look older than the join it ends, so the core
sends it and then reconnects: the new connection's list starts from its
resync, and the drop is resent there.

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
| `config` | server | `item`, `item_base`, `item_defaults`, `employer`, `department`, `job`, `starting_accounts`, `default_job`, `setting`, `version` |
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
