# The Lua core

The game-side code that is the same on every engine. It is pure Lua: no game
API is called anywhere under `lua/core/`, and it runs under `busted` with no
game and no portal.

The game side is three layers:

1. **Core** (this directory). Protocol, the connection to the portal, config
   persistence, and, from D4 on, the framework modules.
2. **Platform adapter**, one per engine (FiveM D2, `lua/platform/fivem/`;
   Gmod D8). It fills in a platform table and wires engine events to the
   core, two lines per event. It is the only code that differs between
   engines. `lua/platform/README.md` is what a new one must implement.
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
rpf.files.server -- json.lua, platform.lua, events.lua, time.lua, protocol.lua, domains.lua,
                 -- config.lua, client.lua, players.lua, commands.lua, moderation.lua, staff.lua,
                 -- inventory.lua, manifest.lua, addons.lua, records.lua, sync.lua, accounts.lua,
                 -- handoff.lua, join.lua, characters.lua, jobs.lua, edits.lua, data.lua,
                 -- holding.lua, ops.lua, bridge.lua, facade.lua, commerce.lua, world.lua,
                 -- targets.lua, interactions.lua, ui.lua, actions.lua, dialogs.lua, api.lua
rpf.files.client -- json.lua, platform.lua, events.lua, time.lua, handoff.lua, auth.lua,
                 -- picker.lua, targets.lua, interactions.lua, ui.lua, api.lua
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

The client never loads `protocol.lua`, `domains.lua`, `client.lua`, `players.lua`,
`commands.lua`, `moderation.lua`, `staff.lua`, `inventory.lua`, `manifest.lua`, `addons.lua`, `records.lua`, `sync.lua`,
`accounts.lua`, `join.lua`, `characters.lua`, `jobs.lua`, `edits.lua`, `data.lua`, `holding.lua`, `ops.lua`, `bridge.lua`, `facade.lua`, `commerce.lua` or `world.lua`, because the player's client
must never hold the server's API key and has no players, staff or records to
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
As its resource stops (or, on Gmod, the map changes) it calls
`core.stop_server()` before it closes the transport, which flushes every
change to a held record not yet reported into the persisted outbox
(`rpf.sync.stop`), a change behind a create still on its way included,
queued after it, so a clean stop loses none of it (J6).

## The server platform interface

`meta/platform_server.lua` and `meta/platform_shared.lua` define it as
`---@meta` classes, one per part, so the language server type-checks an
adapter annotated `---@type rpf.ServerPlatform` against them.
`platform.lua` holds the same member list as data, and a test keeps the two in
step.

| Part | Member | What it does |
|---|---|---|
| Engine | `engine` | `"fivem"`, `"gmod"` or `"mock"`. Reported in `Hello`, never branched on |
| | `map` | The map this process runs (#173): `game.GetMap()` on Gmod, the owner's `rpf_map` convar on FiveM (`default` unset). A non-empty string, reported in `Hello` and fixed until the core stops; one that is no map's name is logged and reported as `default` (`rpf.world.map`) |
| Transport | `connect(url, handlers)` | Opens the websocket. `handlers` has `open()`, `message(text)` and `close(reason)`. One connection at a time |
| | `disconnect()` | Closes the open connection or abandons the attempt. Its `close` is still called, and the core ignores it |
| | `send(text) -> boolean` | Sends one text frame. `false` when there is no open connection or the engine's call failed (the platform logs why). A `Hello` that returns `false` is a failed attempt, retried after a backoff |
| Http | `http_request(method, url, headers, body, callback)` | `callback(status, body, headers)`, exactly once. `status` is 0 when no response arrived |
| Clock | `now() -> ms` | Wall-clock milliseconds since the Unix epoch |
| | `after(delay_ms, callback)` | Runs `callback` once, later. No cancel: the core ignores a timer it no longer wants |
| Storage | `kv_get(key) -> string?` | Reads a persisted string |
| | `kv_set(key, value?)` | Writes one, or deletes it with `nil`. Strings only, so the core owns the encoding |
| Random | `random_hex(n) -> string` | `n` lowercase hex digits from the best randomness the engine offers |
| World | `units_per_metre` | A number: how many of the engine's position units are a metre (FiveM 1, Gmod 39.37), positive and finite. `rpf.world.units` and `metres` convert by it; the platform is refused at start without it |
| World | `capabilities` | A table, not a function: what the engine can do with the game world for addons, each capability a function or `false` for unsupported (`rpf.world`). `position(player) -> { x, y, z }?`, `bucket(player) -> integer?`, `model(name) -> id?`, `entity(ref) -> { position, model, bucket, placement }?`, `spawn(spec) -> ref?, err?` and `despawn(ref)` (J4: `rpf.world`). Beside them, the UI its clients show addons (J10): `notify`, `menu`, `input`, `progress`, each `true` or `false` (`rpf.ui`) |
| Thread | `thread() -> any` | The running coroutine (`coroutine.running`), or nil where there are none (the mock), so `rpf.addons` keeps whose code is running per coroutine without the core touching `coroutine` |
| Players | `identifiers(player) -> string[]` | Every identifier the engine knows, verbatim. Reference data, never identity |
| Players | `hardware_tokens(player) -> string[]` | The hardware tokens the engine reports (FiveM's `GetPlayerTokens`), verbatim; empty where it has none. An alt signal the portal keeps only as hashes (I4) |
| | `name(player) -> string` | The in-game name |
| | `kick(player, reason)` | Disconnects a player |
| | `notify(player, message)` | Shows a player a message |
| ToClients | `to_client(player, name, payload)` | Sends a string to one client |
| | `on_client(name, handler)` | `handler(player, payload)`. The platform supplies the sender, and the payload is hostile input |
| | `on_client_request(name, handler)` | `handler(player, payload, respond)`: a client's request (`request_server`), answered by calling `respond(reply)` once. The platform pairs the two (ox_lib's `lib.callback` on FiveM, numbered `net` messages on Gmod) and supplies the sender; the core always answers (J10) |
| | `request_client(player, name, payload, callback)` | The other direction: asks one player's client and hands `callback` the answer, or nil, taking it only from that player, and forgetting a request when the player leaves (numbered events on both engines: ox_lib's callbacks never let an unanswered one go). The core keeps the timeout and reads the answer as hostile input (J10) |
| Commands | `on_command(name, handler)` | `handler(player, args)`: a player ran the command `name`, typed in chat (`/name words`) or in the console, `args` the words after it as strings. Called for a connected player, never for the server console. The words are hostile input and often a credential: the platform never logs or repeats them, and keeps the line out of the chat others read. The core registers one, `rpflink` (F9, #115) |
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
`to_server(name, payload)` / `on_server(name, handler)`,
`request_server(name, payload, callback)` (a request, and the server's
answer handed to `callback`, or nil; the core keeps the timeout),
`on_server_request(name, handler)` (the server's requests, answered once
by `respond(reply)`), `ui` (what an addon shows the player, J10: `notify`,
`menu`, `input`, `progress`, each a function taking a spec `rpf.ui` has
checked and a `done` callback, or `false`, and `close(kind)`, which takes
away what an addon that stopped had on show),
`item_image(url, headers, hash, done)` (fetches an item's image unless one
is kept under `hash`, follows the portal's redirect without the
`Authorization` header, refuses bytes whose SHA-256 is not `hash`, keeps
them under it, and calls `done(src)` with what the engine draws, or
`done(nil, "not_found" | "unavailable")`: `rpf.items` below), `log`, and
`expose` (the client's scripts get the public API too, with `auth` and
`items` in place of `players`, `staff` and `config`). It has no websocket, no `random_hex` and no player
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
- `json.serde_bytes(value)` is a decoded value's size as the portal's
  serde_json writes it, which is how the portal measures every byte bound
  on what a game server sends (a stack's `ItemData`, an addon manifest, a
  record's fields): serde writes DEL raw and fractions in Ryu's shortest
  form (`0.00001234`, `1e-7`) where `rpf.json` and C's `%g` do not, so the
  size is computed for serde's form, not taken from what this side sends.

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
- `redact` replaces the credentials (`api_key`, `ticket`, `nonce`, and a
  staff `link_code`, F9) for logging.

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
  A `Hello` refused `suspended` (protocol 2, H5) means the platform operator
  has suspended this server's community: the reason is logged, the
  connection is dropped, and it is made again after `suspended_retry_ms`
  (five minutes) plus the same jitter, for as long as the suspension lasts,
  so the server comes back on its own once it is lifted. The outbox keeps
  everything meanwhile.
  A `Hello` refused with any other code that may not be
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
  Notices (a frame with no `re` that asks only for an `Ack`, such as
  `staff_permissions`) go to every listener registered with
  `connection:listen(type, listener)`, in order, after the ack, each under
  the same guard as a callback, so one that throws is logged and the rest
  still run. `restarting` is the connection's own. Listening for a request
  or an answer is refused with an error, since none would ever arrive.

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
provide: whatever store an adapter uses has to take one value of 1 MiB plus
the header, and about 9 MiB in total (`max_bytes` plus the replies' share).
Each adapter confirms its store at the bound on the real engine. Gmod's
(SQLite through `sql.QueryTyped`, D8) held nine values of 1 MiB plus 256
bytes on a real server (`lua/platform/README.md`), and FiveM's resource KVP
(D2) held them on FXServer 35245, surviving a `SIGKILL` straight after the
write (`lua/platform/fivem/README.md`, Testing). An adapter whose store
cannot lowers `max_frame_bytes` and `max_bytes` through the client options.

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

An item that is a weapon has `weapon` (L3): `{ fivem?, gmod?, ammo? }`, the
engine weapon it gives on each engine it is one on, as staff wrote it, and
the slug of the item it fires. An item that is not one has no `weapon`.

An item staff gave an image has `image`, the image's content hash (P3): the
SHA-256 of the stored PNG, 64 lowercase hex digits. Never a URL, and the core
fetches nothing: a player's client fetches the image from the portal
(`/api/v1/player/items/<slug>/image`, with its API token), which redirects
it to the user-content domain, and keeps it under the hash, which changes
exactly when the image does.

`new_character` (E5) arrives **checked**. `config.starting_accounts()` is
what the portal opens, and funds with ledger entries from the server's
starting funds, when it creates a character; the core never pays a starting
balance itself, so a resent `create_character` cannot create money twice.
`config.default_job()` is `{ employer, job }`, always a job `config.job`
finds: when the `economy.default_job` setting names a job this server does
not have (deleted, or inherited from a parent whose employers it does not
share), the portal sends no default job, and applying the snapshot logs a
warning naming the setting's job. The portal creates every character in
the default job (D7), so a new character arrives holding it. The starting funds account is the portal's
alone and is never handed to a hold.

Jobs carry what `rpf.jobs` (D7) needs: every job a `rank` (0 to 1000,
compared only within its employer) and a paid one a `salary` per pay period,
and an employer that pays salaries its `payroll`, the name of one of the
server's `paying_accounts`. They are fields of the entries `config.job` and
`config.employer` already return, so nothing indexes them separately.

`paying_accounts` (#106) names the accounts this server pays out of, each
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

**In-game edits (E6).** `config.edit(handle, base_version, changes)` is how
a server's config menu changes config for a linked staff member: up to
`config.MAX_CHANGES` (16) changes, each shaped as the portal's
`ConfigChange` (`{ change = "setting", key, value = { state = "set", value }
}`, `{ change = "create_item", item = … }`, `{ change = "delete_job",
employer, slug }`, …), made against `base_version`, the version the staff
member was looking at. It refuses before sending anything a player not
logged in, a version that is not a whole number, changes of an unknown kind
or the wrong shape (`invalid_changes`, checked by the encoder the connection
uses), and a player whose grants (`rpf.staff`) hold none of the flags that
kind of change takes (`config.EDIT_FLAGS`); otherwise it sends
`config_changed` through the outbox, so an edit made during an outage goes
out after the next `Welcome`. Nothing here changes on sending: the portal
applies the edit only if `base_version` is still the server's version and
pushes the result as the next `config`. The answer tells the staff member
(`config.EDIT_APPLIED`, `config.EDIT_DISCARDED`, or the portal's reason) and
announces `config.edit_applied` or `config.edit_discarded` with `{
player_id, version }`, or `config.edit_refused` with `{ player_id, code,
reason }`. A discarded edit is listed on the server's settings page.

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
  `players.`, `config.`, `auth.`, `records.`, `characters.`, `jobs.`, `staff.`, `addons.`, `domains.`, `interactions.` or `rpf.`, so a
  script cannot forge a lifecycle event other scripts would believe. It
  returns `nil, "reserved"` rather than throwing, and `nil, "forbidden"` for
  a name under another loaded addon's namespace (`rpf.addons.may_use`).

### `rpf.time`

RFC 3339 parsing (`time.parse`, for the portal's timestamps), and the clock
and timers scripts use (J3), on both sides: `now()`, `after(delay_ms, fn)`,
`every(period_ms, fn)` and `cancel(id)`. They run on the platform's clock
(`now`, `after`), bound when the API is published, which on Gmod is as the
adapter loads, so an addon loading then can set a timer. Delays are whole
milliseconds up to `MAX_DELAY_MS` (2^31 − 1, which every engine's timer
holds), and a period at least `MIN_INTERVAL_MS` (10), so a mistake cannot
spin the server's thread; anything else is `invalid`. Ids are strings, so
they cross a FiveM export unchanged. A callback runs under `pcall` in the
context it was made in (`rpf.addons`): one that throws is logged, and an
`every` keeps going. A timer an addon makes while its code runs is its own,
and is cancelled when it stops.

`elapsed(since, max_ms)` (J6) is how a record keeps time across restarts,
which end every timer: the milliseconds from a moment a record stored to
`now()`, never negative (a clock stepped back counts as nothing) and at
most `max_ms` (a bounded catch-up), with `now()` to store as the new
moment.

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
  own, on every server whatever framework runs the characters (#67). Only
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

### Staff (`rpf.staff`)

In-game staff (F9). A staff member links their player account to their
portal user once, and from then on may do in game what their portal roles
allow on this server, under the portal's own permission names
(`player.kick`).

**The game server enforces permissions locally, from what the portal
pushes.** The portal sends `staff_permissions`, a notice, acked: every
linked staff member on this server's online list and what each may do
here. It sends one after every change that could move anyone's permissions
here (a link or unlink, a role edited or assigned), on each join, and after
each `online_players` resync, so a reconnect repairs anything missed. Each
push is the whole list, so `rpf.staff` replaces what it held, and a player
left out may do nothing. Grants are kept by `player_id` whoever they name,
since a push may arrive before the `player_authenticated` of a player it
lists, and take effect once that player registers. Permission names this
core does not know are kept as they are (the portal adds flags). A grant's
addon flags (`addon_permissions`, J8) join its core names, so a linked
member of an addon-only role is listed too (L4). A push that does not decode is dropped by the
connection; one that decodes but names a player twice is logged and
refused; either way the grants stay as they were. Grants outlive a dropped
connection to the portal, so staff can still moderate through an outage,
but not the player: a player who leaves loses theirs at once. They are
memory only, so a restart has none until the portal pushes again.

| Call | What |
|---|---|
| `can(handle, permission)` | True only for a player logged in here (`registered` or later, not `dropping`) whose last grant holds exactly that name, or, for an `addon.<namespace>.<name>` flag, the guild owner's grant of every addon flag (`all_addon_permissions`, which covers addons installed later) |
| `permissions(handle)` | Their names, sorted, as a copy; empty for anyone else. The owner's grant of every addon flag is not a name and is not listed |
| `link(handle, code)` | Sends `link_player` with the code as typed. Refused, with nothing sent, as `not_logged_in`, `invalid_code` (not a non-empty UTF-8 string of at most `MAX_CODE_BYTES`, 32) or `busy` (one link per player in flight, since each wrong code counts against the player, the guild and every live code) |
| `record(handle, permission, action, target)` | Sends `staff_action` for the guild's audit log. Refused, with nothing sent, as `forbidden` unless `can(handle, permission)`, `invalid_action` unless `action` is `[a-z][a-z0-9_]*` of at most 64 bytes, `invalid_target` for a `target` that is not a logged-in player. `target_player_id` goes as `null` for no target |

Both sending calls return `true` once the frame is queued, or `false` and
the outbox's `outbox_full` / `outbox_unavailable`.

**Linking.** The portal answers `link_player` with `player_linked`, naming
the staff account, or `rejected`: `forbidden` with a reason written for the
player (a code that does not link, or too many tries), `not_found` for a
player not on its online list. The player is told either way through
`platform.notify` (looked up again by `player_id`, so one who has left is
told nothing), with the portal's reason on a refusal and a generic sentence
(`LINK_UNAVAILABLE`) when the portal never answered (`expired`, or an
outbox refusal). Linking grants nothing by itself: the permissions follow
in the portal's next push. **The code is a credential and is never
logged**; `rpf.protocol.redact` hides it too. The core registers
the command a player types it into, `rpflink` (`staff.COMMAND`), through
the platform's `on_command`: `staff.typed` joins the words (the portal
ignores spaces), refuses what cannot be a code (none, too many, too long,
not text) before it costs the guild a guess, tells the player when they
have not logged in or have a code still being checked, and calls `link`.
It never logs or repeats what was typed. A server's own script may still
call `rpf.api.staff.link(handle, code)` from a command of its own.

**Recording.** A script that kicks, teleports or otherwise acts as staff
checks `can` first, does the deed, and reports it with `record`. The portal
believes none of it on the server's word: it checks the link and the
permission again when the notice arrives, and a refusal there is logged
here at `warn` (the deed is done; nobody is told in game).

Events, reserved: `staff.changed({ player_id, permissions })` once for
each player whose grant a push or a departure changed (`permissions`
sorted, empty when they lost everything), `staff.linked({ player_id,
staff_name })` and `staff.link_failed({ player_id, code, reason })`, `code`
being the portal's refusal or the local error.

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
  `Welcome` (#106, below), and live addon records by their type's policy
  (`rpf.holding`, J6, below).
  Anything else is held with `rpf.sync.hold({ owners = …, records = …, types = … })`:
  `owners` holds every live record an owner has here (not transitively: a
  character's own accounts are held through the character), and `types`
  claims a page of the records of those addon types this server holds by
  policy. The portal
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
only, and internal: addons reach items through the domain-neutral facade
(`rpf.facade`, below), which routes here when RPF owns inventory.

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

**Data is measured exactly as the portal measures it**, by
`json.serde_bytes`. The portal parses floats exactly (`float_roundtrip`), or
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

### `rpf.manifest`

Addon manifests and the records of their types (J2,
`docs/architecture/addons.md`): the pure rules, server only. Registration,
declaration and activation (`rpf.addons`, below) build on it, and so will
the public `rpf.api.addons` and record calls (J3).

**One rule set, on both sides.** `manifest.check(m)` is a port of the
portal's `Manifest::parse` and `manifest.check_fields(def, fields)` of
`TypeDef::check_fields`: the same rules in the same order, so the two agree
on the verdict and on the first rule broken, which comes back as the portal
serialises it, `{ error = "bound", path = "types.plant.fields.water.max" }`
for a manifest and `{ error = "too_long", field = "tags", item = 1 }` for a
record. The order is documented once, in `crates/rpf-domain/src/addons/`.
`manifest.apply_patch(def, current, patch)` is `TypeDef::apply_patch` (a
write names only what it changes, and a null clears a nullable field), and
`manifest.with_defaults(def, fields)` is what a record reads as.
A type's `world` (J4) is checked last, against the type's checked fields:
each role names a field of a kind it may be (`world_field` otherwise; a
`map` must be an indexed string), and the kind decides whether `model` and
`radius` are needed or refused. `check_fields` then holds the field a
type's `map` role names to a map's name (`manifest.is_map_name`, #173).
A manifest's `actions` (L1) come after its types, and each action's
`params` are checked as a type's fields are, except that a parameter takes
no `index`, `unique`, `hidden`, `read_only` or `engine` (`unknown_key`) and
refers to no owner (`unknown_value` at `to`); a choice's parameters are
checked against them with `check_fields({ fields = params }, given)`.
`manifest.is_version` and `manifest.is_range` check the shape of a release
and of a `requires` range; matching one against the other is the portal's,
at install.

**The shared corpus.** Both sides are held to `protocol/corpus/addons/`
(`spec/manifest_spec.lua` here, `crates/rpf-domain/tests/addons.rs` there):
`manifests/`, each a manifest and the exact error expected, and `records/`,
each a type of the shared `manifest.json`, the fields (or a record and a
patch) and the fields as stored or the exact error. Both suites read the
rules out of the Rust source and need a case for every one, and the spec
reads the limits (`MAX_MANIFEST_BYTES` and the rest) from
`crates/rpf-domain/src/limits.rs`.

**Tables an author wrote are read as JSON.** A manifest written in Lua has
unmarked tables, and its empty ones (`requires = {}`, `list = {}`) could be
either shape, so an empty unmarked table is read as whichever the rule
expects; a table mixing string and number keys is refused where it stands.
`check` and `check_fields` return a marked copy, which `rpf.json` encodes
exactly as the portal reads it, and never change the caller's table. A
`json` field is judged by what it encodes to, so one holding an empty table
it cannot tell the shape of is refused.

### `rpf.addons`

The addons loaded on this server, and whether each may run (J2), and whose
code is running (J3). Server only; `rpf.api.addons` fronts `register`,
`state`, `provide`, `call`, `API` and `API_MIN` (The public API, below).

| Call | Does |
|---|---|
| `register(manifest, handlers)` | Checks the manifest with `rpf.manifest.check` and the handlers (nil, or a table of `start()`, `stop(reason)` and `state(state, reason)`, each callable: a FiveM function reference is), keeps them, and declares the addon if connected. Returns true, or nil and `{ error, path }`: a manifest rule, `handlers`/`handler` (`handlers.strat`), or `too_many` past `MAX_ADDONS_PER_SERVER`. Registering a namespace again is a reload |
| `state(namespace)` | The addon's state and why: `active`, `not_installed`, `pending`, `mismatch`, `disabled`, `api`, `requires` or `failed` |
| `provide(name, fn)`, `call(name, ...)` | Exports between addons, `<namespace>.<name>`: `call` answers `true, …results` while the providing addon is active, else `false` and `not_found`, `inactive` or `failed` (it threw, logged) |
| `unload_origin(origin)` | Forgets every addon an origin registered, without calling their handlers (their code is gone), takes down what that origin set up, and declares again. The FiveM adapter calls it from `onResourceStop` |
| `from(origin, fn, ...)`, `run(context, fn, ...)`, `context()` | The context below: a public call from an origin, a call into an addon's code |
| `own(cleanup)`, `may_use(name)` | Ownership and namespaces, below |
| `definition(type)` | A type's installed definition: the config's own for a kept or ahead type, else the manifest's |
| `config_records(type)` | The records of a config type, as the config carries them, while their addon is active |
| `declare()` | Sends `declare_addons`; run after each `Welcome` and on each registration |

**Declaring.** After every `Welcome` (chained on the connection's
`on_ready` after `rpf.sync`'s declaration) the core sends `declare_addons`:
every loaded namespace, and their manifests split across frames of at most
`MAX_MANIFESTS_PER_DECLARE` (8, `limits::MAX_MANIFESTS_PER_DECLARE`). With
nothing loaded it still sends one, empty, so the portal forgets the
proposals of addons that are gone. It is a notice, logged by the portal and
not reissuable; the next `Welcome` declares again. Once one is acked, its
addons are `pending` until staff install them.

**Running.** An addon runs only when the config's `addons` section
(`config.addon(namespace)`) has it installed and enabled with exactly the
manifest it registered, compared value for value by `addons.same` (the
portal's hash is over the same content, and Lua has no SHA-256), for an API
major from `API_MIN` to `API` (`API_MAJORS`; 1 to 1 now), and with
everything it `requires` active. States are recomputed on every
`config.changed` naming `addons` and every registration. Moving into
`active` runs `start`, out of it `stop`; every move runs `state` and emits
`addons.state` (`{ namespace, state, reason }`). Handlers run under `pcall`:
one that throws is logged, and a `start` that throws leaves the addon
`failed`, retried on the next config change or registration. Addons start
in dependency order and stop in reverse. A refusal logged before the core
starts (Gmod loads addons before the convars are read) is kept and written
out at start.

**Reloading.** Registering a namespace that is already loaded stops the old
registration (after whatever requires it), then registers and starts the new
one if it may, whether or not the manifest changed: a Gmod Lua refresh, or a
FiveM resource restarted, runs the addon's file again, and its new code must
start rather than be skipped because the manifest is the same.

**Whose code is running.** The registry keeps a context, `{ namespace,
origin }`: the addon whose handler, timer, event handler or export the core
is running, and the engine's name for the code that called the public API.
On FiveM the adapter names the calling resource on every export call
(`addons.from(GetInvokingResource(), …)`), and a registration belongs to
its resource; on Gmod every addon shares one Lua state and the origin is
nil. The context is kept per coroutine (`platform.thread`), so a handler
that yields leaves it on its own coroutine, not on whatever runs while it
waits; and what is owned is forgotten as soon as it is taken down, so a
long-running addon's finished timers do not add up. From it:

- **Ownership.** A timer (`rpf.time`), an event subscription
  (`rpf.api.events.on`) or an export made while an addon's code runs is the
  addon's (`addons.own`), and is taken down when it stops (after its own
  `stop` ran) or its `start` throws, so an addon that starts `every` in
  `start` has exactly one however often it restarts. One made by a
  resource's code outside any handler is the resource's, and goes in
  `unload_origin`. Something the core or a Gmod script sets up outside any
  handler has no owner and stays.
- **Namespaces.** `may_use(name)`: code known to be one addon's (its
  context, or a resource that registered other addons) may not emit an
  event or provide an export under another loaded addon's namespace. Code
  that cannot be named (a Gmod script outside any handler) is let through:
  the rule stops mistakes, not the owner's own code, which on Gmod can
  reach past anything with `rawset` anyway.
- **Context follows the code.** A timer runs in the context it was made in,
  and so does an event handler, so what they set up and emit is attributed
  to the same addon.
- **An activation ends.** Each start of an addon is numbered (`run`), and
  the context carries it. An addon's code outside a running activation (a
  callback that yielded across a disable or a reload, or a `state` handler
  while the addon is not active) may run to its end, but `addons.stale()` is
  true for it and it sets nothing up: a timer, an event handler or an export
  from it is refused `inactive`. A FiveM resource's own code outside any
  handler is the resource's, never stale; what it sets up goes with the
  resource.

### Live addon records (`rpf.records`, J2)

Held like any record (`kind = "addon_record"`, its data `{ id, type, owner,
fields }`), and written only through these calls, each checked whole
against the type's installed definition (`rpf.addons.definition`) with
`rpf.manifest`:

| Call | Does |
|---|---|
| `create_addon_record(type, owner, fields, id?, through?)` | A record of an active addon's live type, held from the start (for `through`'s session when given); reported as `addon_record_created` with every field, never whole, until the portal has it (a create lands even in a frame answered `resync_required`; one in a refused frame goes again as a create) |
| `set_addon_fields(id, patch)` | Fields of a held record, `json.null` clearing one; reported as the patch, the changes since the last report merged |
| `delete_addon_record(id)` | Reported as `addon_record_deleted`, forgotten once applied; a create that has not left yet is just dropped; a deletion the portal refuses (another record refers to it) is undone and the record reported whole |
| `query_addon_records(type, query, callback)` | `query_records`: a page of a type's live records, each with its revision and whether this server holds it, to hold before changing |

A disabled addon's held records can still be changed and released (the
drain); creating and querying need it active. Staff edits arrive as
`edit_addon_record` and `delete_addon_record` commands (`rpf.edits`): the
first applies the patch at the revision staff saw, the second releases the
record, with its final state, for the portal to delete.

### Addons' records (`rpf.data`, J3)

The record calls addons make, which `rpf.api.records` fronts, over
`rpf.records`, `rpf.sync`, `rpf.addons` and the config:

| Call | Does |
|---|---|
| `get(type, id)` | A config record, or a held live one: a plain copy, `{ id, type, owner, revision, fields }`, every default filled in, a field with no value absent; a `json` field is kept whole, nulls and shapes included |
| `list(type, query)` | Every config record, or every held live record, of the type that meets `query` (`where`, `owner`, `order`, `descending`, `limit`), read locally: any field may be filtered or ordered; no value for the order field sorts last; ties by id |
| `query(type, query, callback)` | `query_records` for unheld live records: `where` (`eq`, `lt`, `lte`, `gt`, `gte`, `prefix`) becomes `RecordQuery.filters`, on indexed fields as the portal requires; `callback(records, next, err)` in the caller's context |
| `hold(type, ids, callback)`, `release(type, ids)` | `rpf.sync.hold` and `release` for up to 64 records of the type, held for the server (no player's session) |
| `create(type, fields, opts)` | `records.create_addon_record` with `opts.owner` and an optional `opts.id`, after checking the owner kind, the id, the type's `limit` of held records and the fields; a record of a type held with its owner joins the owner's session when it is here (`rpf.holding.session_of`) |
| `update(type, id, patch, opts)` | `records.set_addon_fields`, `opts.clear` naming the nullable fields to clear (`json.null`, which an export cannot carry), `opts.revision` refusing a stale write. An empty table in what is written takes its shape (array or object) from the stored value at the same place, so a `json` field read and written back unchanged is accepted though the plain copy lost its marks |
| `delete(type, id, opts)` | `records.delete_addon_record`, `opts.revision` likewise |
| `batch(ops)` | Every write checked against the records as they are, none made unless all would be; what was queued before is flushed first, then the writes are made and flushed, so they go in one report when they fit one frame (64 records, `max_records_per_frame`). A record whose create or whole report is still unanswered goes in a report of its own, so a batch naming one is `busy` until it is |

Refusals: `not_found` (no such installed type, or config record),
`inactive` (its addon is not running: `rpf.addons.running`, which a `start`
handler counts as; or the caller is code of an activation that has ended,
`rpf.addons.stale`), `not_held` (a live record not held here, of another
type, or being deleted), `stale`, `busy` (a batch, above), `invalid` with the rule as the portal
names it (`{ error, field }`), `conflict`, `limit`, `outbox_full`. A
record's `revision` here is `entry.version`: the portal's revision when it
was held (1 when created here), moved on by every change made here, so a
compare-and-set between scripts sees each change even when several reach
the portal in one report.

An addon's calls close when it stops being active; which of its records
are then released is `rpf.holding`'s (below). A hold answered after the
addon stopped is given back. Its held records still drain to the portal as
J2 made them (staff edits, reports, releases).

Events, reserved, each an `rpf.data.Change` (`{ type, id, record, by,
reason }`): `records.created`, `records.changed` and `records.deleted` after
an addon's write, a staff edit (`rpf.edits`, `by = "staff"`), or a deletion
the portal refused, which puts the record back (`records.changed`, `by =
"portal"`). Its `reason` is the portal's refusal code as sent: `referenced`
when another record refers to it, but a frame is applied all or nothing, so
also whatever refused the frame it was in (`malformed` for another record's
change failing its checks, `forbidden`, `not_found`, …). A frame that
deleted several records and was refused `referenced` cannot say which was
referenced, so each comes back as `refused`. `detail` is the portal's own
words, for the log; an addon branches on `reason`.

### Hold policies (`rpf.holding`, J6)

When a live addon record is held, by its type's `hold`, carried out by the
core so no addon writes hold code, and decided by the config's
installation rather than by whether the addon's code is loaded:

| Policy | Held | Let go |
|---|---|---|
| `owner` | A player's records with their session hold, a character's with its selection; a record an addon creates for an owner whose session is here joins that session, and so does one held for the server that a session hold names. Records owned by the server or an employer are held as `server` ones | When the player leaves or puts the character away |
| `server` | Claimed: `hold` with `types`, a page (`MAX_CLAIMED`, the portal's `limits::MAX_CLAIMED_PER_HOLD`) of the records nobody holds, again while a page comes back full; after every `Welcome` (waiting for the declaration, as every hold does), whenever the config's `addons` section changes, and every `CLAIM_MS` (a minute), which picks up records staff created meanwhile. A refusal (a full server, a disable racing the claim) is logged once until it changes | Only by a disable (below) |
| none | On demand, `rpf.data.hold` | `rpf.data.release`, or when the addon's code stops |

- **Code stops, installation enabled** (`addons.state` leaves `active`: a
  resource stop, a reload, `mismatch`, a `start` that threw): what was held
  for the server on demand is released with its final state; policy
  records stay held.
- **The config disables or removes the installation**: every record of its
  types is released, sessions' included (`holding.drain`), tried again
  every `RETRY_MS` while some cannot go yet (a create on its way, a full
  outbox), worked out afresh on each try. A hold the portal answered
  before the disable that lands after it (`records.held`) is drained as it
  arrives.
- **The config enables an installation, or gives an enabled type `hold =
  "owner"`**: a claim, and, for an `owner` type new to it, a hold of each
  logged-in player's own and selected character's records for their
  session.
- **An upgrade changes a type's `hold`**: held records follow (`records.hold_for`):
  to `server`, session-held ones become the server's; to `owner`, those of
  owners here join their sessions; to none, an addon whose code is not
  running is drained.
- **Putting a character away** (`rpf.characters`) releases what its
  selection brought: its accounts, containers and `owner` records, never a
  `server` record or one held on demand.

### The domain-neutral facade (`rpf.facade`, `rpf.ops`, J3)

How an addon reaches a player's character, money, items and job whoever
owns them (`docs/architecture/framework-integration.md`, decided in #67).
`rpf.facade` is the native provider: each call goes to RPF's own module.
For a domain the server's framework owns (K1), each call goes to the
bridge instead (`rpf.bridge`, K2, below), behind the same calls. Server
only; `rpf.api.characters`, `money`, `inventory`, `jobs` and `ops` front it.

| Call | Native |
|---|---|
| `characters.current(player)` | `{ key, name }` of the character the player has in play (`rpf.characters.selected`): `key` its id, opaque to the addon |
| `money.accounts()` | The names of the starting accounts (`config.starting_accounts`) |
| `money.balance(player, account)` | The balance of the character's held account of that name (`rpf.accounts.owned_by`) |
| `money.debit` / `credit(player, account, amount, reason, op_id)` | One ledger entry between that account and the paying account the setting `economy.addon_account` names: `records.transfer` into it, `accounts.pay` out of it. Without the setting, or with one naming no paying account, `unsupported` |
| `inventory.count(player, item)` | Plain units (stacks with no data, `inventory.count(id, item, { plain = true })`) across the character's held containers |
| `inventory.give` / `take(player, item, count, op_id)` | `give` puts every unit in the first container, by name then id, that takes them all (`inventory.add`); `take` checks the plain units are there and works out and validates every container's contents after (`inventory.plan_remove`) before it changes any, so a container that no longer passes its rules refuses the whole take (`invalid_contents`) |
| `jobs.current(player)` | `{ name, employer, grade, on_duty }` from `rpf.jobs` (the job's slug, its employer's, its rank, duty) |
| `<domain>.supports(call)` | Whether the call works here: every native call does, except `money.debit` and `credit` without the addon account |
| `ops.new()` | An op id, `<ms>-<16 hex>`: when it was minted, and the platform's randomness |
| `ops.unknown()` | The commands whose result is `unknown`, oldest first, each `{ op_id, call, at, detail, cause }`: for a staff tool in game |
| `ops.result(op_id)` | How an op id already went (`rpf.ops.result`): nil when it never ran here, `true`, or `false`, a status and a reason. What running it again would answer, without running it, so an addon answers a repeated order as it was answered |

Every call takes the engine's handle of a logged-in player and acts on the
character in play. A read is its value, or nil and `not_logged_in`,
`no_character`, `not_found`. A command is `true`, or nil, a status and a
reason: `refused` (nothing changed), `unavailable` (nothing changed; for
instance the server's account is not held yet) or `unknown` (it may have
happened). Arguments are checked first, and a bad one is `refused`
(`invalid`, `invalid_op`) without being journaled.

**`rpf.ops` runs each command once per op id.** Before a command runs its
intent is written `pending`, under `ENTRY_PREFIX .. op_id` in the
platform's storage with an index of ids at `KEY`, and its result replaces
it, kept for `WINDOW_MS` (a day). A repeated op id gets the recorded result
without running. At start an intent still `pending` (the process died
inside the command) becomes `unknown`, is logged at `warn` for staff, and
never runs. Results go only by age; at `MAX_ENTRIES` (1024) a new command is
`refused` (`journal_full`) rather than evicting a young result, and an op id
older than the window is `refused` (`expired_op`), so an old id can never
pay twice. A command that throws is `unknown`; an intent that cannot be
written runs nothing and is `unavailable`. A success is recorded on disk
only once its change is (`rpf.sync.flush` queued its report in the
persisted outbox), tried again each second until then: a crash in between
would otherwise lose the change while the journal answered a retry `true`.
Until then the entry is `pending` on disk, which a restart reads as
`unknown`.

**Every `unknown` is surfaced to staff** (K2), whenever it arises: a
command that threw or answered `unknown`, an `apply` that failed, or an
intent a restart cut off. The journal keeps each intent's `detail` (the
player's account, the account or item, the amount or count, the reason;
never a framework's key), and an `unknown` one is logged at `error` with
it, announced as `domains.op_unknown`, and listed by `ops.unknown()` until
it ages out. A durability check that throws is logged once and tried again.

**Every `unknown` reaches the portal** (#143). `ops.report()` sends each
one the portal has not answered in `report_unknown_ops` frames of
`MAX_PER_REPORT` (32, `limits::MAX_UNKNOWN_OPS_PER_REPORT`): on the next
tick after one arises, and after every `Welcome` (chained on the
connection's `on_ready`). Each carries the op id, the call, the cause and
the detail, its text cut to `MAX_TEXT_BYTES` (256) at a character
boundary, a player id only if it is a uuid, and numbers only whole and in
range. The portal's ack marks the entry `reported` on disk, so neither a
reconnect nor a restart sends it again; a frame dropped unanswered leaves
its ops for the next `Welcome`, and one the portal refuses (past its cap of
unresolved ones) is logged at `error` with the op ids and marked too, since
the same frame would be refused again. The sweep keeps an `unknown` entry
not yet reported past the window until it is: staff see it however long
the portal was out of reach, and its op id is refused for running all the
same.

**A lost index never lets an op id run twice.** Each entry is written
under its own key before the index, so an id the journal does not know (an
unreadable index, or one a crash cut short) is looked up by that key before
it may run: what is there is its result, and an entry that cannot be read
is `unknown`. One found joins the index again.

**Composite operations** (conflict rule 4). Each command takes an optional
`apply` after its op id: the addon's own change the command pays for (or
goes with). It runs inside the same journaled intent, only once the
command went through, under `rpf.records.watch`, which lists the held
records written while it runs (an `apply` that yields keeps watching until
it returns, so two that resume out of order each still see their own); the intent completes on disk only once each of them is
reported (`rpf.sync.reported`: carried by a report queued in the
persisted outbox) as well as the command's own change. An `apply` that
throws or answers nil or false makes the command `unknown`, with the money
or items already moved: nothing compensates. A non-callable `apply` is
`refused` (`invalid`) before anything is journaled.

### Exchanges (`rpf.commerce`, J5)

What a shop, a buy-back counter or a crafting bench builds on: money and
items moved together, with the addon's own change, as one journaled intent
(`commerce.exchange(player, deal, op_id, apply)`), and the same checks as a
dry run (`commerce.check(player, deal)`). Server only;
`rpf.api.commerce` fronts it.

A deal is `{ account, pay | paid, take, give, reason, records }` from the
player's side: what they pay from one of their accounts (or are paid into
it), the plain units they hand over and receive (at most `MAX_LINES` lines
each), why, and the records the addon priced it against, each with the
revision it read. Anything else in it is `refused` (`invalid`), so a typo
cannot sell for nothing.

**Native: all or nothing.** Inside `rpf.ops.run`, everything is checked
before anything changes: the character, each record still at its revision
(`stale` otherwise; `not_found`, `not_held`, `inactive` as `rpf.data.get`
answers), each item given in the current catalog (`unknown_item`), the
items as one plan across the character's containers
(`inventory.plan_moves`: each take out of them in turn, then each give whole
into the first that takes it, so a take makes room for a give), the
account and the paying account, and the payment
(`records.check_transfer`, or `accounts.check_pay` for `paid`). Then, in
the same synchronous step, the ledger entry, each container's contents,
and `apply` under `rpf.records.watch`. The intent completes on disk only
once the entry, the contents and what `apply` wrote are each in the
persisted outbox, as for a facade command.

**Companion: conflict rule 4, for several calls.** The money and items are
the framework's, so the deal's calls go to the bridge in a fixed order (the
money, each take, each give), each reached before the journal (an
unsupported one is `refused`, an outage `unavailable`) and each with an op
id of its own for the bridge. The records are checked first and `apply`
runs last. While no call has gone through, a refusal or an outage changes
nothing; once one has, any later failure is `unknown`, with a cause naming
what went and what did not, and nothing is refunded. `check` asks the
framework what it can first (the balance, the counts).

The journal's `detail` for an exchange carries `amount` (paid by the
player) or `paid`, and the items as `take` and `give` (`water:2,bread:1`),
so staff resolving an `unknown` one know what moved.

### Bridges (`rpf.bridge`, K2)

The bridge to an existing RP framework on a companion server
(`docs/architecture/framework-integration.md`, "The bridge contract";
`lua/bridges/README.md` for the rules a bridge follows). `rpf.api.bridge`
fronts it.

| Part | What |
|---|---|
| `CONTRACT` | `{ major = 1, minor = 0 }`. Another major is refused; a later minor's unknown calls are left out |
| `CALLS` | The optional calls, by domain: `money.accounts`, `balance`, `debit`, `credit`; `inventory.count`, `give`, `take`; `jobs.current`. `characters.current` is the core's, from the lifecycle |
| `register(def)` | Checks the table whole (`invalid` naming the field, `contract`, `registered`), logs a refusal once, notes the registering origin, offers it to `rpf.domains.accept_bridge`, and activates it if the profile is fixed already |
| activation | On `domains.fixed`, or at `register` after it: a native profile leaves it inactive (an `error` line naming `domains` if `running()` says the framework runs); a profile it does not fit leaves it inactive and the gate holds players; one it fits makes it active, warns outside `tested_with`, runs `start` with the engine handles already at `character_select` (a bridge registering again picks them up; withdrawing it, after its `stop`, if `start` throws), announces `domains.bridge` (`active`), and moves every `registered` player to `character_select`, as it does each later one on `players.registered` |
| `character_loaded(handle, { key, name })` | `forbidden` from another origin, `inactive`, `invalid` (key or name not 1 to 128 bytes), `not_found`, `not_registered` (logged). Same key: rename. Otherwise through `character_select` to `active`, holding `{ key, name }` in memory by handle |
| `character_unloaded(handle)` | Back to `character_select`, the character forgotten (`no_character` if none) |
| `unavailable(reason)`, `available()` | The outage every call answers `unavailable` to without reaching the bridge; each change announced as `domains.bridge` |
| `unload_origin(origin)` | The registering resource stopped (`rpf.unload_origin`): `withdraw`, which moves active players to `character_select`, forgets every character, takes the offer back (`rpf.domains.withdraw_bridge`) and announces `withdrawn` |
| `supports`, `reach`, `character` | What the facade asks: whether a call works, the bridge's function for it now (or `unsupported`, `unavailable`), and a player's reported character (`not_logged_in`, `no_character`; `unavailable` during an outage, kept for after it). Every read but `money.accounts` is a player's, so a nil handle is `not_logged_in`, never a call without one |
| `read(fn, call, valid, ...)` | A read under `pcall`: a throw, a value `valid` refuses (`balance_of`, `count_of`, `job_of`, `accounts_of`) or an error outside `not_found`, `no_character`, `unavailable` is `unavailable`, logged; `jobs.current` may answer nil for no job |
| `command(fn, call, ...)` | A command under `pcall`: `true`; nil and `refused` (with a reason of at most 64 bytes), `unavailable` or `unknown`; anything else, or a throw, is `unknown` with the cause for staff |

The facade (above) asks the journal first (`rpf.ops.known`): an op id it
has answers as recorded, outage or not, since `unavailable` would say a
command that may have happened did not. A new one asks `reach` before it
journals anything, so an unsupported call and an outage leave no intent
behind; the command itself
runs inside `rpf.ops.run`, with the player checked first, and `apply`
after a `true`. The journal drops an `unavailable` result on both paths,
since nothing changed, so the same op id may be sent again.

### The game world (`rpf.world`, J3, J4, J6)

The world as far as the core reaches it: through the capabilities the
adapter declares (`platform.capabilities`), never an engine branch.
`world.capabilities()` is `{ position, bucket, model, entity, spawn,
despawn }` as booleans, for `rpf.api.capabilities()`. A capability that is
neither a function nor `false` is logged at start and counts as
unsupported, and every call into one runs under `pcall`, a throw logged.

- **`position(handle)`**: a logged-in player's position as a plain `{ x, y,
  z }` (how a record stores one, a `vector3` field), or `unsupported`, or
  `not_found` (not logged in, not spawned, or the adapter's call failed).
- **`bucket(handle)`**: their routing bucket; 0 on an engine with one world.
- **`units(metres)`** and **`metres(units)`**: a distance in metres as the
  engine's units, and back, by the platform's `units_per_metre`. The one
  place the scale enters the core: `targets` converts a rule's `distance`
  and a zone's radius with it, and reports a resolved target's and a nearby
  option's `distance` in metres. Both return `nil, "invalid"` for anything
  but a finite number (or a result that is not one), and `unsupported`
  before the core has started.
- **`model(name)`**: the engine's id for a model name, as `entity` reports
  one.
- **`entity(ref)`**: a networked entity by its ref (a FiveM network id, a
  Gmod entity index), which a client names targets by. A ref that is not a
  whole number is refused before the adapter sees it. `placement` (`{
  type, id }`) is set only when the adapter's tag names a record the core
  placed as exactly that entity, so a forged tag names nothing.
- **`placed(type, id)`**: the ref of a record's entity.
- **`map()`**: the map this server runs (#173), the platform's `map` as
  `start` checked it: one that is no map's name (`manifest.is_map_name`)
  is logged and is `DEFAULT_MAP`, so the server still connects rather
  than have its `Hello` refused. `unsupported` before the core starts.
- **`on_map(where, fields)`**: whether a record is on that map: its
  type's `world` names no `map` field, its map is null (every map), or it
  is this one. Placements and `targets` both ask it, so a record on
  another map is neither placed nor targetable.

**Placements.** The core places, one entity each, the visible records on
its map (`on_map`) of the world-backed `config` types of kind `ped` or
`object` of every addon running here (`addons.active`, `addons.config_records`), worked out from
the config alone, so the stored config restored at start places them
before the portal is reached. `reconcile` runs on every `config.changed`
and `addons.state`: it despawns what is no longer wanted or whose
placement changed (position, heading, bucket, model) and spawns what is
wanted and not placed, at most `MAX_PLACED` (1024), the rest logged once.
Every `CHECK_MS` (10 s) it asks `entity` whether each is still there and
still tagged with its record, and places again one that is not; a spawn
that failed (`no_model`, `no_bucket`, the engine's refusal) is tried again
then, logged once until it succeeds or the record changes. `clear()`
despawns everything and stops placing, for an adapter's stop. A world
`live` type's records are placed the same way while held here (J6), read
with `rpf.data.list`; a held record's event (`records.held`,
`records.created`, `records.changed`, `records.deleted`,
`records.released`, `records.lost`) calls `soon`, which reconciles once at
the next timer however many arrive meanwhile.

### Interactions (`rpf.interactions`, J3, J10)

A player's client asks an addon to do something, by a name the addon
registered: the one way a client's request reaches addon code, so a client
never names an event. Loaded on both sides. A request and its answer travel
as a request the platform pairs with its answer (`request_server`,
`on_client_request`), over ox_lib's `lib.callback` on FiveM (J10).

- **Server.** `register(name, handler)`: `name` is `<namespace>.<name>`
  under a loaded addon, its own when the caller is known (`may_use`), and
  the registration is owned like a timer; registering a name again
  replaces it and forgets the old one's ownership. A name whose part after
  the namespace starts `rpf_` is the core's (`reserved`), which
  `register_reserved` takes for the Talk `rpf.dialogs` offers on an addon's
  NPCs; `rules_of(name)` gives a registration's checked rules. `rpf:interact`
  (`{ name, payload }`) reaches only a logged-in player
  (`players.on_client_request`, which answers anyone else
  `not_logged_in`), at most `MAX_PER_WINDOW` (20) per `WINDOW_MS` (10 s)
  per player, past which it is answered `too_many`. The payload is a JSON
  object within `handoff.MAX_PAYLOAD` (4 KiB) and `MAX_DEPTH` (8); it is
  handed over as a plain copy. A request that cannot be decoded is
  answered `invalid`, a name nobody registered (or no addon could) is
  `unknown`, a payload too deep `invalid`, an addon not running
  `inactive`, and a handler that throws `failed` (logged); otherwise the
  handler's own answer, `true` and optionally a table of plain data (at
  most `MAX_ANSWER`, 16 KiB, encoded; data that is not plain is `failed`
  and logged for the addon), or `false` and a reason of at most
  `MAX_REASON_BYTES`. Every request is answered, as `{ ok, reason, data }`
  (`rpf:interaction_result`'s schema), because ox_lib holds one open until
  it is.
- **Client.** `send(name, payload)` and `request(name, payload, callback)`
  check the name and that the payload is plain data within the size (a
  table is walked with `next`, so a throwing `__pairs` is refused, not
  thrown), and ask; at most `MAX_WAITING` (64) wait for an answer at once.
  `send`'s answer is announced as `interactions.result` (`{ name, ok,
  reason }`), a reserved name; `request`'s goes to its callback,
  `callback(true, data)` or `callback(false, reason)`, under `pcall`. No
  answer in `TIMEOUT_MS` (10 s) is `timeout`, a later one is dropped, and
  one that cannot be read is `failed`, logged.

**Rules (J4).** `register(name, handler, rules)` checks the rules with
`rpf.targets.check_rules` (refused `invalid`, with `{ error = "rules",
field }`), and every request for a registration with rules goes through
`rpf.targets.admit` (in the world, permission, cooldown, the target) and
the rules' `check`, in the addon's context, before the handler runs with
the resolved target as its third argument; the cooldown starts as the
request is admitted, and a refusing check gives it back. Empty lists go
to clients as JSON arrays. The server answers `rpf:targets` (what is near, `targets.options`)
on the same rate, and `rpf:target_offers` (which of a short list of rules
it offers on an entity, `targets.offers`) on a rate of its own,
`MAX_OFFERS_PER_WINDOW` (60) per `WINDOW_MS`, so a target resource asking
as the player looks around never uses up what they may do; a list that is
not at most `targets.MAX_OFFER_NAMES` (16) names answers nothing offered.
It sends `rpf:target_rules` (`targets.listed`) to each
player as they become `active` and to everyone in the world when a
registration or an addon's state changes, once per turn of the clock.

### Targets (`rpf.targets`, J4)

What an interaction may be aimed at, and the checks the server makes. Loaded
on both sides, before `rpf.interactions`.

- **Server.** `check_rules(namespace, rules)` reads an addon's rules (`label`,
  `target` as a type name or `{ type }` or `{ models }`, `distance` (in
  metres on every engine; default `DEFAULT_DISTANCE`, 3, at most
  `MAX_DISTANCE`), `cooldown` (at most an
  hour), `permission` (made `addon.<namespace>.<permission>`), `check`),
  refusing an unknown key. `admit(name, rules, player, payload)` checks the
  player is `active` when there is a target, holds the permission
  (`rpf.staff.can`), is past the cooldown, and resolves `payload.target`
  from the server's state: `{ id }` (or `{ ref }` of the entity the core
  placed for one) through `rpf.data.get` and the type's `world`, against
  the player's position and bucket (`rpf.world`), a zone by its radius;
  `{ ref }` for a models rule through `rpf.world.entity` and
  `rpf.world.model`. Missing, hidden, other bucket and other type are
  `not_found`, out of reach `too_far`. `reserve` starts a player's
  cooldown as their request is admitted, before any addon code runs (a
  check or handler that yields cannot let the next request in meanwhile),
  `release` gives it back when the check refuses, and `forget` drops an
  interaction's. `options(entries, player)` lists what is
  near, offered to the player, nearest first, at most `MAX_NEARBY` (16);
  `offers(entries, player, ref, names)` says which of the named rules are
  offered on an entity (`admit` without the cooldown taken, then the
  check); `listed(entries)` is what a target resource needs. **Offered**
  includes the addon's own `check` (#156), run as a request runs it (the
  addon's context, `pcall`, a copy of the player and the target, only
  `true` passes, a throw logged), so a menu never lists what the addon
  will refuse. Checks may yield, so one listing runs at most `MAX_CHECKS`
  (32), nearest first, and starts none after `CHECK_BUDGET_MS` (2 s).
  Each option is admitted as the player and the target are when it is
  reached, and after its check everything is checked again as a request
  checks it (the same activation, the player still here, the same target
  admitted), since a check that yielded may resume after they changed; a
  player may have at most `MAX_LISTING` (4) running, past which a listing
  answers nothing. An option whose check did not run is left out.
- **Client.** `start_client` keeps the server's `rpf:target_rules` and
  emits `interactions.targets`; `rules()` is a copy. `nearby_client(done)`
  asks `rpf:targets` (one at a time, `TIMEOUT_MS`), `nearby(callback)` is
  the public form, and `open()` is the minimal UI: ask, show `rpf.ui`'s
  menu, send the pick as `{ target = { id } }`, and `tell` the player a
  refusal through `rpf.ui`'s notify. `offered(name, ref)` is for a target
  resource's per-frame `canInteract`: the server's last answer about the
  entity, false until it has said yes, asking `rpf:target_offers` again
  when the answer is older than `OFFER_TTL_MS` (1.5 s). Rules looked at in
  one turn of the clock are one request per entity, at most
  `MAX_OFFERS_ASKING` (2) wait at once, answers are kept for at most
  `MAX_OFFER_REFS` (64) entities, and every answer is forgotten when the
  rules change (one that comes after is dropped); `recheck(ref)` forgets
  one entity's, once a request was made there.

### UI (`rpf.ui`, J10)

What an addon shows a player, the same call on every engine: `notify`,
`menu`, `input` and `progress`. Loaded on both sides. `ui.spec` checks an
addon's options (bounded text, at most `MAX_OPTIONS` options and
`MAX_FIELDS` fields, each field `text`, `number`, `checkbox` or `select`
with its bounds) and gives the plain spec an adapter shows and what an
answer is read by; `ui.read` reads an answer against it, on both sides.
A menu may carry `text`, at most `MAX_TEXT` bytes, read above its options
and never picked (an NPC's line, L1).

- **Client.** The four take the options and a callback, show through
  `platform.ui`, and hand the callback the result once: a menu option's
  `value` (its number if it has none), the dialog's values by field name,
  `true` for a bar that ran to its end, or nil and `cancelled`. One of each
  kind is open at a time (`busy`); `unsupported` where the adapter has
  none. It answers the server's `rpf:ui` requests the same way, with what
  the player did, raw. A menu option that names an item (`item`, a slug
  `[a-z][a-z0-9_]*` of at most `MAX_ITEM` bytes; P3, #169) is shown with
  the item's image: before the adapter sees the spec, `with_images` asks
  `rpf.items.image` for each distinct slug and puts what came under the
  option as `image`, at once when every image is kept, else once all have
  answered or `IMAGE_WAIT_MS` has passed. The spec carries the slug alone
  from either side, never an image, so a server cannot make a client draw
  anything but its own catalog's; an option whose image did not come keeps
  its label. The kind is `busy` while the images are on their way, and a
  close from the server meanwhile means the menu is never shown. An
  adapter that throws once the wait is over says `failed` through the
  callback (or the `rpf:ui_answer`), the call having been answered already.
- **Server.** The four take the player's handle first. `notify` is a
  message (`rpf:ui_notify`); the other three are a request to the client
  (`rpf:ui`, `request_client`) with the spec alone: a menu's values and a
  select's stay on the server, which reads the client's answer
  (`rpf:ui_answer`: `index`, `values` or `done`) against what it offered
  (`invalid` for anything else). One of each kind per player at a time;
  `gone` when the player leaves, `timeout` after `TIMEOUT_MS` (a bar: its
  length and `GRACE_MS`). A callback runs in the context of the code that
  asked, under `pcall`. A wait is that addon's, like a timer: when it
  stops, the wait goes, its callback is never called, and the client is
  told to close the window by the request's id (`rpf:ui_close`), which it
  does through `platform.ui.close`.

### Actions (`rpf.actions`, L1)

What an addon can be asked to do by a dialog choice staff build in the
panel (#175). Server only; `rpf.api.actions` fronts `register`. The portal
never sends code, so a choice names an action an installed addon declared
in its manifest (`actions`, read through `rpf.addons.action`) and fills in
its parameters as data.

- **`register(name, handler)`**: under the caller's own namespace
  (`forbidden` otherwise, as `rpf.addons.may_use` decides), for an action
  its registered manifest declares (`not_declared`), owned like a timer
  (`rpf.addons.own`): it goes when the addon stops. Registering the name
  again replaces it.
- **`available(name)`**: `true`, or `false` and `not_declared` (no addon
  loaded here declares it), `inactive` (its addon is loaded and not
  running) or `not_registered` (it runs and never registered the
  handler). What a dialog asks before it offers a choice as working.
- **`run(player, name, params, context)`**: `available`, then the
  parameters checked against the declaration with its defaults
  (`invalid` and the rule, since staff may have saved the choice under an
  older release), then the handler in its addon's context under `pcall`
  with a plain copy of them. It answers `true`, or `false` and `refused`
  with the handler's message (cut to `MAX_MESSAGE` bytes on a character's
  boundary), or `failed` for a throw or an answer that is neither `true`
  nor `false`, which is logged.

### Dialogs (`rpf.dialogs`, L1)

A conversation with an NPC, from a tree in the config (`rpf.config.dialog`).
Server only; `rpf.api.dialogs` fronts `open`.

- **`open(handle, slug, opts)`** shows the tree's start node as an
  `rpf.ui` menu: the title, the node's line as `text`, an option per
  choice whose conditions hold (`holds`), valued by the choice's number,
  or "Goodbye." for a node with none. `not_found` for a slug the config
  lacks, `not_logged_in`, or what the menu says (`busy`, …). One per
  player, the one whose menu is on their screen: one that could not open
  leaves it working.
- **A pick** is read against the tree as it is now: the same choice,
  encoded the same (`changed` otherwise), its conditions still holding,
  the NPC still in reach when opened through Talk (`rpf.targets.admit`
  with the rule's checked rules, `rpf.interactions.rules_of`). Then
  `goto`, `end`, or `rpf.actions.run`, whose refusals become `MESSAGES`
  told to the player as a notification, and logged when the choice is
  broken.
- **`holds(handle, condition)`**: `job` through `facade.current_job`,
  `item` through `facade.count`, `permission` through `staff.can`, each
  negated when `negate`; nil when a read fails or the kind is one this
  core does not know, which hides the choice.
- **Talk**: on every `addons.state` to `active`, each of the addon's
  types whose `world` names a `dialog` gets
  `interactions.register_reserved("<namespace>.rpf_talk<n>", …)` in the
  addon's context, aimed at the type, offered where the record's field
  names a tree the config has.

### Placement (`rpf.placement`, L4)

Linked staff run `rpfplace` to place, move or remove an installed world
config record where they stand; a server script opens the same menu with
`rpf.api.placement.open(player)`. It is built on `rpf.ui`, so its choices
(types, records and their revisions) stay on the server, and it offers
only the types and actions the staff member's pushed addon grants allow
(`rpf.staff.can`). Position, facing, bucket and map come from the server
adapter (`capabilities.heading` beside `position`), never from the client;
other required fields are asked for. A confirmed change goes through
`rpf.config.edit` as `create_world_record`, `update_world_record` or
`delete_world_record`, named against the config version the menu read its
records from, and the portal applies it with its own writer under E6's
compare-and-set: nothing changes here before the config push. Before
confirming, the staff member's client shows a temporary model where the
engine can (`ui.preview`, which returns its disposer), removed on
confirmation, cancellation or after a minute; point and zone types confirm
without one.

### Characters (`rpf.characters`, `rpf.picker`)

A logged-in player's characters (D5): list, create, select and switch. Server
only for the decisions; `rpf.picker` is the client half the character select
screen (the adapter's, like the login form: `lua/platform/gmod/ui.lua` on
Gmod, `lua/platform/fivem/nui/` on FiveM) calls. Both are
internal: addons reach the character in play through the domain-neutral
facade (`rpf.facade`, above), which routes here when RPF owns characters.

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
| `rpf:characters` | server → client | `characters` (each `id`, `first_name`, `last_name`, `gender`), `selected`, `truncated` (set when the list was cut short to fit `MAX_LIST_PAYLOAD`, keeping the character in play: only a portal that bounds neither names nor characters per player can make one that long, #105) |
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
internal, like `rpf.characters`: addons move money through the facade
(`rpf.facade`).

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

**The paying accounts are held for the server (#106).** Staff open them in
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
(E5). Server only, and internal, like `rpf.characters`: addons read a
player's job through the facade (`rpf.facade`, `jobs.current`), which
routes here when RPF owns jobs; setting jobs is not in the facade
(`docs/architecture/framework-integration.md`), so the game server's own
code calls `set_job` directly.

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

**The default job** is the portal's to give: it creates every character in
the snapshot's `new_character.job`, in the same transaction as its starting
accounts, so a character whose creation reply or first hold is lost still
has it when it is held again. When `rpf.characters` announces a new
character (`characters.created`) with no job while the `economy.default_job`
setting names one, the setting names a job this server does not have: that
is logged, as E5 logs it when the config is applied.

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
   sends `BeginJoin` with the engine's identifiers (never `ip:`), name and
   hardware tokens (FiveM's; at most `join.MAX_HARDWARE_TOKENS` of at most
   `join.MAX_TOKEN_BYTES` each, left out when there are none).
2. On `JoinChallenge` the server sends the client `rpf:join_nonce`: the nonce,
   its lifetime (`expires_at − sent_at`, both the portal's clocks), the
   portal's HTTP address and the server's id.
3. The client resumes silently from the remember token saved for that server
   id, or emits `auth.required` for the form. `login`, `register` and
   `change_password` post to `/api/v1/player/*` with the nonce.
4. The client sends the grant's ticket in `rpf:join_ticket`. The server sends
   `RedeemTicket`, registers the player on `PlayerAuthenticated`, and answers
   `rpf:join_result`. The client emits `auth.succeeded`.

A malformed `rpf:join_result` is logged with the decoder's reason, never
the payload. If a ticket is pending, it ends that attempt, drops its session
and API tokens, and emits `auth.failed` with `during = "redeem"`, followed
by `auth.required`, so the client cannot stay stuck in `redeeming`. The
message tells the player to reconnect: an unreadable answer does not say
whether the server already redeemed the ticket. Outside `redeeming`, the
warning leaves the login state alone.

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
  to 10 minutes, because the client's clock may be wrong). Always issued since P2; a grant without one (an older portal) is accepted with a warning and just never refreshed.
  A refresh never stops silently (#171). An expiry that cannot be read, an
  outage or `5xx`, and an answer that is not the portal's (a `200` that is
  not a JSON object or has no token, a redirect) each log a warning and try
  again after `retry_ms` (30 s), keeping the token in hand, which is still
  good until it expires. Only a `4xx` ends the session: both tokens are
  forgotten and `auth.failed` is emitted with `during = "refresh"`.

`auth.logout()` forgets the saved login at once, then asks the server for a
fresh nonce for this connection and posts `{ nonce, remember_token }` (#62),
so a token read out of shared client storage cannot log its owner out. It
cancels a login whose portal request is still in flight, but not a ticket
already handed to the server, which may have redeemed it: that result is
honoured, leaving the player logged in for this session with nothing saved,
exactly as a logout after login does. The portal answers `204` whatever it
did with the token, so any other answer (no answer, an error, a proxy's page)
logs a warning and emits `auth.failed` with `during = "logout"`: the token is
forgotten here, but may still be valid at the portal. A fresh nonce that
does not arrive within `nonce_wait_ms` (30 s) is reported the same way,
without changing the login state or discarding a pending ticket's result.
The adapters do not
put it on the login form. Every other request that sends a nonce (a login,
registration, password change, resume or deletion) is sent once more with a
fresh nonce when the portal calls the first `invalid_nonce`; a logout never
hears that, since it is always `204`.

`auth.delete_account(username, password)` deletes the account at the portal
(H6): it posts `{ nonce, username, password }` to `/delete_account` with a
fresh nonce, which the portal does not consume, and on `204` forgets the
saved login and the session and moves to `deleted`, in which nothing more
can be started on this connection. The player is still in the game, as an
account that no longer exists, until they leave; the adapter tells them to
reconnect. A refusal (a wrong password, a staff reset's temporary one)
is `auth.failed` with `during = "delete_account"`,
and the login stands. The password goes in the body as a login's does, so
FiveM's sealed handles work for it unchanged.

Events: `auth.required`, `auth.succeeded`, `auth.failed` (with `code`,
`message`, `during`, and `retry_after` when rate limited),
`auth.password_change_required` and `auth.account_deleted`. The form that calls this is the adapter's:
Gmod's is `lua/platform/gmod/ui.lua` (D8). FiveM's is an NUI page that keeps
the password out of Lua altogether (`lua/platform/fivem/README.md`). Both
adapters' login screens lead to a delete form that asks for the username and
password and a ticked box, says it cannot be undone and what stays, and
shows `account_deleted` as a screen telling the player to reconnect.

### Items on the client (`rpf.items`, P3)

A client has no config snapshot. `items.lua` keeps the server's catalog as
the player API serves it (`GET /api/v1/player/items` with the API token,
public fields only), used for `CATALOG_FRESH_MS` (a minute) and then
revalidated with `If-None-Match`, one request at a time; a catalog that
cannot be revalidated is still used, and one from another portal or server
is dropped. `items.catalog(callback)` hands a script a copy of it.

`items.image(slug, callback)` finds the slug in the catalog and asks the
platform's `item_image` for the image at the catalog's `image_url` (only
that path, which carries the hash), once per hash however many ask at a
time, and keeps what comes back under the hash for the session
(`MAX_IMAGES`); the adapter keeps it on disk, checked against the hash, so
an unchanged image is never fetched again, even after a restart. The
callback gets `{ slug, hash, src }`, `src` being what the engine draws: a
`data:` URL on FiveM (an `<img>` in any resource's page, ox_lib's `image`
and `icon`), a path for `Material()` on Gmod. A `404` means the image was
replaced since the catalog was read: the catalog is revalidated, and the
image asked for again once if its hash moved. Refusals: `invalid`,
`not_logged_in` (no API token yet), `not_found` (no such item, or its image
is gone), `no_image`, `busy` (the portal's rate limit), `unavailable`
(anything else, including a fetch that took longer than `TIMEOUT_MS`).

### The public API

`rpf.api` (`api.lua`) is the documented, supported surface, and the only
table `platform.expose` publishes: through the resource's export table on
FiveM, and as the `rpf` global on Gmod. Everything else under `rpf` is
internal.

| Member | Side | What |
|---|---|---|
| `VERSION`, `engine` | both | The core's version, and the engine (`"fivem"`, `"gmod"` or `"mock"`) for owners' scripts. The core never branches on it |
| `events` | both | `on`, `once`, `off`, `emit`. `emit` refuses a core name (`reserved`) or another addon's namespace (`forbidden`) |
| `time` | both | `now`, `after`, `every`, `cancel`: `rpf.time`'s timers |
| `addons` | server | `API`, `API_MIN`, `register`, `state`, `provide`, `call` (`rpf.addons` above) |
| `records` | server | `get`, `list`, `query`, `hold`, `release`, `create`, `update`, `delete`, `batch` (`rpf.data` above) |
| `capabilities`, `world` | both, server | `capabilities()` on both sides (the world's on the server, the UI's on both), and `world.position` on the server (`rpf.world` above) |
| `ui` | both | `notify`, `menu`, `input`, `progress`; on the server each takes the player first (`rpf.ui` above) |
| `interactions` | both | `register` on the server, `send` and `request` on the client (`rpf.interactions` above) |
| `actions` | server | `register` (L1, `rpf.actions` above) |
| `dialogs` | server | `open` (L1, `rpf.dialogs` above) |
| `characters`, `money`, `inventory`, `jobs`, `ops` | server | The domain-neutral facade (`rpf.facade` above): `characters.current`; `money.accounts`, `balance`, `debit`, `credit`; `inventory.count`, `give`, `take`; `jobs.current`; each domain's `supports`; `ops.new`, `ops.unknown`, `ops.result` |
| `commerce` | server | `exchange`, `check` (J5, `rpf.commerce` above) |
| `players` | server | `get`, `by_player_id`, `list`, `authenticated`, all returning copies |
| `staff` | server | `can`, `permissions`, `link`, `record` (F9, `rpf.staff` above) |
| `config` | server | `item`, `item_base`, `item_defaults`, `employer`, `department`, `job`, `starting_accounts`, `default_job`, `setting`, `version`, and `edit` (E6, above) |
| `auth` | client | `login`, `register`, `change_password`, `delete_account`, `logout`, `state`, `account`, `api_token`, `PASSWORD_REUSE_WARNING` |
| `items` | client | `catalog`, `image` (P3, `rpf.items` above) |
| `bridge` | server | `CONTRACT_MAJOR`, `CONTRACT_MINOR`, `register`, `character_loaded`, `character_unloaded`, `unavailable`, `available` (K2, `rpf.bridge` above) |

**Nothing in it throws** (J1's rule for addons, `docs/architecture/addons.md`):
a call that cannot do what it was asked returns nil (or false) and a reason
string, documented on the call in `meta/api.lua`, and a handler that takes a
function from a script takes a FiveM function reference too
(`rpf.callable`). A handler the API runs for a script runs under `pcall`.

Every member is a closure over its module or a plain value, never a module
table, the connection or the platform, so nothing internal is reachable, and
every table in it refuses writes, so one script cannot replace `events.on`
for the others. That stops accidents, not attackers:
`rawset` and the debug library reach past it.

`meta/api.lua` is the `---@meta` definition of this surface for server
owners' language servers: add `lua/core/meta/` to `workspace.library` and
annotate the table your script holds `---@type rpf.Api`. It also reserves, for
Milestone 2, `rpf.bridge` and the facade's `domain_external` refusal
(`rpf.api.Refusal`), so nothing assumes RPF always owns characters, money,
inventory and jobs (#67). Nothing in it names a framework or treats an engine
handle as a portable id. `spec/api_spec.lua` holds it to exactly the members
`api.lua` builds.

**The reference (J9).** `dev/luadoc` builds a browsable reference from the
annotations and prints the path of its `index.html`, which opens from disk,
search included: a page for `rpf.Api` and each `rpf.api.*` table and type
`meta/api.lua` declares, and the rest of `lua/core/` under a labelled Internals
section. Nothing generated is committed, so it is always the code's own; CI
uploads it as the `lua-api-reference` artifact, and each release's docs site
carries it. What a reader sees is what the annotations say, so write them
for an addon's author: say on each table which side it runs on, give the
calls an author reaches for first a fenced `lua` example, and
name a type as `` `rpf.X` `` so the reference links it. The landing page is
`docs/luadoc/docs/index.md`; how the pages are arranged is in
`docs/site/luadoc.py`.

## Testing

```bash
cd lua
busted                                   # whichever Lua busted was installed for
lua-language-server --check=. --checklevel=Warning
../dev/glua-api && lua-language-server --check=platform/gmod --checklevel=Warning
```

Run the suite under both LuaJIT and Lua 5.4. `docs/testing.md` has
the commands, including installing busted for each without root.

The suite tests the core against a fake platform it drives by hand
(`spec/support`). The fake game server (`crates/fake-server/`, layer 4 in
`docs/testing.md`) runs the same core on the mock platform against the real portal,
over a real socket, under both Luas; `spec/mock_spec.lua` holds the mock to
the platform interfaces.
