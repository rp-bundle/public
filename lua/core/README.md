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
3. **Mock platform** (D3), which implements the same interface for tests.

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
rpf.files.server -- json.lua, platform.lua, protocol.lua, config.lua, client.lua
rpf.files.client -- json.lua, platform.lua
```

Every later file registers itself on `rpf` (`rpf.json = json`) *and* returns
its table. An adapter can therefore load them with anything that runs a file:
Gmod's `include` and plain `dofile` keep the return value, and a resource
manifest that lists the files in this order discards it, which is fine,
because the file has already registered itself. No file calls `require`, whose
search path differs on every engine.

The client never loads `protocol.lua` or `client.lua`, because the player's
client must never hold the server's API key.

Then the adapter starts one side:

```lua
rpf.start_server(platform, { url = "wss://…/ws", api_key = "rpf_…" })
rpf.start_client(platform)
```

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
`to_server(name, payload)` / `on_server(name, handler)`, and `log`. It has no
websocket, no `random_hex` and no player management.

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

The messages in `src/protocol/mod.rs`, as schemas: `protocol.decode(direction,
text)` and `protocol.encode(direction, frame)`. A frame is flat, as on the
wire (`frame.type`, `frame.id`, `frame.re`, and the message's fields).

- Unknown fields are ignored at every depth and do not appear in the decoded
  frame. Unknown `type`s are refused, and so is a missing field or one of the
  wrong type. A nullable field must still be present.
- `answered_by` and `reissuable` mirror `Message::answered_by` and
  `Message::reissuable`, and `may_retry` mirrors `RejectCode::may_retry`.
- `redact` replaces the credentials (`api_key`, `ticket`, `nonce`) for logging.

`spec/protocol_spec.lua` decodes and re-encodes every file in
`protocol/corpus/v1/`, the same files `tests/protocol.rs` reads. **This is the
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
the highest slot in use. Adding, answering or reissuing an entry writes that
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
| `max_entries` | 2048 | Frames this server originates. A day's outage on a busy server is a few hundred joins and leaves, and C7's reports are per record and superseded by revision, so thousands is headroom, while a load still reads only a couple of thousand keys |
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

`config.load(platform)` and `config.save(platform, version, hash)` persist the
config version and hash (E2) under `rpf.config.version`. `Hello` reports them,
or `null` for both on a cold start. D4 adds typed lookups over the snapshot.

## Testing

```bash
cd lua
busted                                   # whichever Lua busted was installed for
lua-language-server --check=. --checklevel=Warning
```

Run the suite under both LuaJIT and Lua 5.4. `AGENTS.md`'s Testing section has
the commands, including installing busted for each without root.
