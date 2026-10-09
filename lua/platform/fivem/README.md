# The FiveM adapter

D2 (#17). The core (`lua/core/`) on FiveM: a thin adapter over FiveM's
natives, a websocket shim in FiveM's JS runtime, and the in-game login and
character screens. What any adapter must do is in
[`../README.md`](../README.md); this is how FiveM does it.

## Two resources

| Resource | From | What |
|---|---|---|
| `rpf` | `fxmanifest.lua`, the files beside it, and `lua/core/` as `core/` | The core, the adapter, the NUI screens |
| `rpf-ws` | `ws-shim/` | The portal websocket, in FiveM's JS runtime, bundled with `ws` into one file |

`dev/fivem-resources [out]` assembles both (default `target/fivem/`), and CI
uploads them as the `fivem-resources` artifact. A server owner needs no
`npm install`: the shim is one bundled file. `rpf` declares
`dependency "rpf-ws"`, so FiveM starts the shim first and stops `rpf` with
it. `dev/fivem-resources --dev` also adds `dev.lua`, the smoke test's
console commands (Testing, below); a release never has it.

## Installing

Copy both folders into the server's `resources/`, then in `server.cfg`:

```
set rpf_url "wss://portal.example/ws"
set rpf_api_key "rpf_<prefix>_…"
ensure rpf-ws
ensure rpf
```

Use `set`, never `setr` or `sets`: those publish a convar to every client or
to the server list, and the API key is a secret. Without both convars the
adapter logs an error and does not connect. The server needs OneSync (the
input lock's routing buckets, below), which is on by default on a current
FXServer.

`restart rpf` reconnects at once. `restart rpf-ws` stops `rpf` with it and
leaves it stopped, because FiveM stops a resource with its dependency but
does not start it again, so follow it with `ensure rpf`. Optional:
`set rpf_portal_url "https://portal.example"` when the portal's HTTP address
is not the websocket's host, and `set rpf_debug "true"` for the core's debug
lines.

Other resources reach the public API (`rpf.api`, `lua/core/README.md`) as an
export:

```lua
local rpf = exports.rpf:api() ---@type rpf.Api
local subscription = rpf.events.on("players.active", function(player) end)
rpf.events.off("players.active", subscription)
```

One difference from `rpf.api` in the same Lua state: a function does not
keep its identity across FiveM's boundary (each crossing makes a new
reference to it), so through the export `events.on` and `events.once` return
a subscription id, a string, and `events.off` takes that id rather than the
function.

## How each part is done

| Platform member | On FiveM | File |
|---|---|---|
| `connect`, `disconnect`, `send` | The `rpf-ws` shim, below | `ws.lua` |
| `http_request` (server) | `PerformHttpRequest`, with a failure's body taken from `errorData` and held to one callback | `server.lua` |
| `http_request` (client) | The NUI page's `fetch` (client Lua has no HTTP) | `ui.lua`, `nui/app.js` |
| `now` | `os.time` (server) or `GetCloudTimeAsInt` (client), whole seconds, refined to milliseconds with `GetGameTimer` and kept inside the wall clock's current second | `shared.lua` |
| `after` | `Citizen.SetTimeout` | `shared.lua` |
| `kv_get`, `kv_set` | Resource KVP, with the synchronous `SetResourceKvp`, never the `NoSync` one | `shared.lua` |
| `random_hex` | Node's `crypto.randomBytes`, through the shim; Lua's generator, with one warning, only if the shim cannot answer | `server.lua` |
| `identifiers`, `name`, `kick` | `GetPlayerIdentifiers` verbatim, `GetPlayerName`, `DropPlayer` | `server.lua` |
| `notify` | The `rpf:notify` client event, shown as a feed notification | `server.lua`, `client.lua` |
| `to_client` / `on_client`, `to_server` / `on_server` | `TriggerClientEvent` / `RegisterNetEvent`, `TriggerServerEvent` / `RegisterNetEvent`, with the sender from FiveM's `source` and anything but a string payload dropped | `server.lua`, `client.lua` |
| `log` | `print`, as `[rpf] <level>: <message>` | `shared.lua` |
| `expose` | The `api` export, a plain copy of `rpf.api` (read-only views do not survive FiveM's msgpack), with `events` subscriptions named by id | `shared.lua` |

The engine events (`server.lua`, `client.lua`), each handler two lines at
most:

| Event | Core call |
|---|---|
| `onResourceStart` (this resource) | Starts the core from the convars, then `players.connected` for everyone already on the server |
| `onResourceStop` (this resource) | Closes every socket it has open in `rpf-ws`, which outlives a `restart rpf` (a socket left open would keep answering the portal's pings, and the portal would refuse the restarted core as a duplicate instance), and puts every held player back in their own routing bucket |
| `playerJoining` | `players.connected(source)` |
| `playerDropped` | `players.dropped(source, reason)` |
| `chatMessage` (the `chat` resource) | Cancelled for a held player (`lock.lua`) |
| `rpf-ws:open`, `rpf-ws:message`, `rpf-ws:close` | The transport, which calls the core's socket handlers |
| `onClientResourceStart` (this resource) | Starts the screens and the client core |
| `onClientResourceStop` (this resource) | Releases the input lock, which would otherwise leave the ped frozen |

`playerJoining` rather than `playerConnecting`: a connecting player's
`source` is a temporary id that changes once they join, and the core keeps
the handle for the whole session. The core's login starts when the client's
core says it is ready, which is after `playerJoining` anyway.

## The websocket shim

FiveM's Lua has no websocket client, so `rpf-ws` owns the socket in FiveM's
JS runtime. **Frames cross the Lua/JS boundary as JSON strings, never as
tables.** The shim never parses one: it moves text, so FiveM's msgpack
marshalling has one string to carry, and `rpf.json` stays the only codec.

The contract is written twice and both copies are checked:
`transport.lua` (a `---@meta` class, lua-language-server) and
`ws-shim/src/contract.ts` (an interface, `tsc --strict`).

| Lua calls | | JS emits (server-local events) | |
|---|---|---|---|
| `exports["rpf-ws"]:connect(url)` | the connection's id | `rpf-ws:open(id)` | open, `send` works |
| `exports["rpf-ws"]:send(id, text)` | `false` unless open | `rpf-ws:message(id, text)` | one text frame, verbatim |
| `exports["rpf-ws"]:close(id)` | | `rpf-ws:close(id, code, reason)` | exactly once per `connect` |
| `exports["rpf-ws"]:random_hex(n)` | `n` hex digits | | |

These are the platform's transport members with a connection id, plus
`random_hex`, because the JS runtime has the only cryptographic randomness a
FiveM server offers Lua. The events are server-local, never network events,
so no client can forge a frame. They are emitted through `setImmediate`,
because ws calls back on Node's thread, where FXServer allows no natives.
A binary frame closes the socket (1003); the
protocol is text only. A handshake that takes over 30 seconds is abandoned,
so a portal that accepts TCP and says nothing cannot leave the core waiting.

The bundle targets Node 16, the oldest an FXServer that runs this ships.

## The login and character screens

`nui/` is the page; `ui.lua` is its logic, apart from NUI so busted runs it.

- **The player is held until they are `active`, server-side**
  (`lock.lua`): from the moment the engine hands them over, they are in a
  routing bucket of their own, where they see no other player and nobody
  sees them, clients may create no entity (`strict` lockdown), and their
  chat is cancelled; reaching `active` puts them back in the bucket they
  were in. This needs OneSync. A framework bridge (K2) relies on it rather
  than building its own. On the client, the page has focus and the ped is
  frozen from the client's start until the login succeeds, and again while
  the character screen is up; that is comfort, not the lock, since a client
  is hostile.
- **The password never reaches Lua.** The page seals each password into a
  random handle and sends the handle; the core puts it where the password
  goes in its request body, and the page swaps the password back in just
  before `fetch` (`nui/seal.js`). So it goes from the form to the portal
  without crossing into Lua or any event. That is a mitigation, not a
  guarantee: the server owner ships this page.
- The login form, which also registers, and the password change both show
  `auth.PASSWORD_REUSE_WARNING`. A saved login resumes silently.
- The remember token is the only secret stored on the player's machine, in
  client KVP, and is safe there only because P1 binds it to the player's
  FiveM licence: client storage is shared by every server running a resource
  named `rpf`.
- The portal allows the page's origin, `https://cfx-nui-<resource>`, for the
  player endpoints (P1, P2).
- The character screen lists, creates and selects (D5's `rpf.picker`), so a
  fresh install reaches `active` with no script of the owner's. Styling is
  out of scope.

## Testing

| What | Where | Run |
|---|---|---|
| The adapter, unmodified, on fake FiveM globals: both platforms complete, every member, the server-side lock, the screens, the two-line handlers, the manifest against `rpf.files` | `lua/spec/fivem_spec.lua`, fakes in `lua/platform/mock/fivem.lua` | `busted` from `lua/` |
| The adapter against the real portal, under both Luas: a join with the identifiers in the expected shape, a staff kick, a cut and a restart | `crates/fake-server/tests/scenarios/fivem.rs` (`Engine::Fivem`) | `cargo test -p fake-server --features lua54 fivem` |
| Annotations, and every native name, against overextended's `fivem-lls-addon` (pinned in `dev/fivem-natives`) | `.luarc.json` | `dev/fivem-natives && lua-language-server --check=lua/platform/fivem` |
| The shim: `tsc --strict` (and the NUI page's JS, `tsconfig.nui.json`), its unit tests against a local websocket server, and the contract test | `ws-shim/` | `npm ci && npm run typecheck && npm test` |
| Frames per second through the shim | `ws-shim/bench/` | `npm run bench` |
| On a real FXServer (layer 5): resource KVP at the outbox's bounds, the benchmark under FXServer, the connection and the players | `dev.lua`, in a `dev/fivem-resources --dev` build | `rpf_dev_kv_bound`, `rpf_dev_bench`, `rpf_dev_status` at the server console |

The contract test (`ws-shim/test/contract.test.ts`) fails when the two
copies of the contract disagree on a name, a parameter or a type, and drives
the real bundle from the real `ws.lua` in a real Lua 5.4 (wasmoon), every
value through a msgpack round trip as FiveM's exports and events do, against
a local websocket server: connect, send, receive, close codes, a close in the
middle of a burst of sends, and a reconnect.

**The benchmark** sends frames from Lua through the shim to a local echo
server and back to Lua, so each crosses the boundary twice and the socket
twice. `npm run bench` does it in plain Node, through the emulated msgpack
boundary into wasmoon's Lua; `rpf_dev_bench` does it on a real FXServer,
through FiveM's own Lua 5.4, JS runtime and marshalling. On FXServer 35245
(the recommended artifact in October 2026, which ships Node 22.22.0), on a
16-core x86_64 Linux machine that was building other work at the same time,
it did 11,000 to 17,000 round trips a second at 512 bytes (60 to 90 µs each)
and 4,700 to 6,300 at 4 KiB (160 to 210 µs); `npm run bench` beside it did
13,000 to 19,000 and 6,500 to 9,700, so the emulation is a fair stand-in. Of
each round trip, the `send` export is about 50 µs. No echo arrived inside a
`send` export (an instrumented run counted them), so the shim's events do
not re-enter the core. An idle FXServer ticks every 50 ms, which is why the
benchmark sends 2,000 frames a tick: at 500 it measured the tick rate (exactly
10,000 a second, whatever the frame size) rather than the boundary. The portal
sends tens of frames a second per server at most, so the boundary is noise.

**Layer 5** runs on a real FXServer, which will not start without a Cfx.re
licence key (`sv_licenseKey`). Install a `dev/fivem-resources --dev` build,
point the convars at a portal with a server and an API key, and add
`set rpf_dev "true"`; the commands run only from the server console.

- `rpf_dev_kv_bound` writes nine values of 1 MiB plus 257 bytes through the
  adapter's `kv_set` (the outbox's largest entry, and its total plus the
  replies' share; `lua/core/README.md`, The outbox), reads each back through
  `kv_get` byte for byte, and deletes them. `rpf_dev_kv_bound write` stores
  them and stops; kill the server (`kill -9`) and start it again, and
  `rpf_dev_kv_bound read` checks them and deletes them, which shows a write
  is durable when `kv_set` returns.
- `rpf_dev_bench <ws://url> [frames] [bytes]` is the benchmark, against
  `npm run echo` in `ws-shim/` (`ws://127.0.0.1:30121`), on a socket of its
  own beside the core's. It holds the server thread for a moment each tick
  (FXServer logs hitch warnings), so run it on a server nobody is playing on.
  A run that has no answer in 60 seconds is given up.
- `rpf_dev_status` prints the connection's state and the players the core
  knows, with their lifecycle state.

Run for #186 on FXServer 35245 under OneSync, against a local portal:

- Both resources load on the artifact's Node, and the core connects and
  takes its config. The Linux artifact ships only Node 22 (22.22.0): a
  resource that asks for `node_version "16"` gets it too. The bundle targets
  16, for a server still on it, and loaded as FXServer loads it (the
  `exports` and `emit` globals) it opened, echoed and closed a socket on
  Node 16.20.2. `restart rpf` reconnects at once, and the portal does not
  refuse the new instance as a duplicate.
- Resource KVP holds the bound: `rpf_dev_kv_bound` read the nine values back
  byte for byte, in 100 to 300 ms, and after `rpf_dev_kv_bound write`, a
  `kill -9` and a restart, `rpf_dev_kv_bound read` found all nine. A
  separate probe also held 64 values of 1 MiB. So the outbox's defaults
  stand, and the adapter lowers no bound.
- The benchmark is above.
- A real client's join is still to run: the login screen, the sealed
  password, silent resume on a second join, the character screen reaching
  `active` on a fresh install, and the identifiers the portal stores (the
  account `license:` and the allowlisted kinds verbatim, with no `ip:`).
  It needs the game, and waits on the repository owner (#186).
