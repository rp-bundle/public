# The FiveM adapter

D2 (#21). The core (`lua/core/`) on FiveM: a thin adapter over FiveM's
natives, a websocket shim in FiveM's JS runtime, and the in-game login and
character screens. What any adapter must do is in
[`../README.md`](../README.md); this is how FiveM does it.

## Two resources

| Resource | From | What |
|---|---|---|
| `rpf` | `fxmanifest.lua`, the files beside it, and `lua/core/` as `core/` | The core, the adapter, the NUI screens |
| `rpf-ws` | `ws-shim/` | The portal websocket, in FiveM's JS runtime, bundled with `ws` into one file |

`dev/fivem-resources [out]` assembles both (default `target/fivem/`), and CI
uploads them as the `fivem-resources` artifact. A release ships them as
`rpf-fivem-<version>.zip`, both inside one `[rpf]` folder
([Installing](../../../docs/installing.md#by-hand)). A server owner needs no
`npm install`: the shim is one bundled file. `rpf` declares
`dependency "rpf-ws"`, so FiveM starts the shim first and stops `rpf` with
it.

## ox_lib

`rpf` is built on [ox_lib](https://github.com/overextended/ox_lib) (J10,
#131): `dependency "ox_lib"`, and `shared_script "@ox_lib/init.lua"`, which
puts `lib` in the resource's Lua state on both sides before any script of
its own. Most FiveM servers run it already (Qbox requires it), and it has
the callbacks, notify, menus, input dialogs and progress bars an addon
needs, which would otherwise be NUI written from scratch. Every call to it
is in `ox.lua`, so leaving it is one file's work: upstream has moved once
(Overextended archived it in 2025, CommunityOx forked it, and by October
2026 Overextended's repository was active again and the fork archived).

- **It is a prerequisite, never bundled.** ox_lib is LGPL-3.0; a release
  names it and the txAdmin recipe downloads its own release. FXServer cannot
  pin a dependency's version, so `ox.MINIMUM` is checked at start from
  ox_lib's `version` metadata: 3.40.0, the release the adapter is built
  and type-checked against, which also closes a hole in ox_lib's callbacks
  that let one player answer what the server asked another.
- **`lib.callback` is only a transport,** for a client's requests. It
  carries a request and its answer (`request_server` / `on_client_request`)
  under one fixed name per request kind (`rpf:interact`); what a client
  asks reaches only the handler an addon registered, checked by the core
  (`rpf.interactions`). ox_lib's own registry has no access control, so
  nothing else of RPF's is registered with it. The server's requests to a
  client (`rpf.ui`) are the adapter's own numbered events instead: ox_lib
  keeps every server-to-client callback nobody answers for good, and a
  player who leaves with a menu open never answers.
- **The login and character screens stay RPF's NUI.** ox_lib's dialogs
  hand their values to Lua, and the password must never reach Lua (below).
- **The core never calls it**, as it never calls a native. `dev/fivem-resources --dev` also adds `dev.lua`, the smoke test's
console commands (Testing, below); a release never has it.

## Installing

[Installing](../../../docs/installing.md) is the owner's guide, with the
txAdmin recipe and the troubleshooting lines; this is the adapter's view.
Unzip a release's `rpf-fivem-<version>.zip` into the server's `resources/`,
which gives it one `[rpf]` folder (FXServer finds resources inside a
bracketed folder, and starts only what `server.cfg` ensures), or copy both
folders of a `dev/fivem-resources` build there. Then in `server.cfg`:

```
set rpf_url "wss://portal.example/ws"
set rpf_api_key "rpf_<prefix>_…"
ensure ox_lib
ensure rpf-ws
ensure rpf
```

Use `set`, never `setr` or `sets`: those publish a convar to every client or
to the server list, and the API key is a secret. The server needs OneSync
(the input lock's routing buckets, below), which is on by default on a
current FXServer.

The adapter refuses to start, in one console line saying what to do
(`server.refusal`), when either convar is empty, when `rpf_url` is not a
`ws://`/`wss://` address or `rpf_api_key` is not shaped like a key
(`rpf.client.target_problem`, which never repeats the key), when the
artifact lacks a routing-bucket native (`server.NATIVES`), when OneSync is
not `on` (routing buckets do not work under `legacy`), when `rpf-ws` is not started, or when ox_lib is not started or older than
3.40.0 (`ox.problem`). A missing ox_lib or `rpf-ws` is FXServer's own line
first: it will not start `rpf` without its dependencies. A refused start hands the core no
player events either. Those lines are what `docs/installing.md`'s
troubleshooting section is keyed by.

`restart rpf` reconnects at once. `restart rpf-ws` stops `rpf` with it and
leaves it stopped, because FiveM stops a resource with its dependency but
does not start it again, so follow it with `ensure rpf`. Optional:
`set rpf_portal_url "https://portal.example"` when the portal's HTTP address
is not the websocket's host, `set rpf_debug "true"` for the core's debug
lines, and `set rpf_map "<name>"` to name the map setup this server runs
(#173): FiveM has one map, so this is the name staff give the records of
one setup (an event's, say), and the core places only those and the ones on
every map. `default` when unset. It is read as the resource starts, so
change it with `restart rpf`.

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

Every call through the export names the resource that made it
(`GetInvokingResource`, `shared.from_caller`), so the core knows whose code
is calling: an addon registered from a resource is that resource's, what it
sets up through the API (timers, event handlers, exports) is taken down when
it stops (`onResourceStop` hands its name to `rpf.unload_origin`),
and one addon's resource cannot emit events under another addon's
namespace. A handler an addon passes (`start`, a timer, an event handler)
arrives as a function reference, which the core calls like a function.

## How each part is done

| Platform member | On FiveM | File |
|---|---|---|
| `connect`, `disconnect`, `send` | The `rpf-ws` shim, below | `ws.lua` |
| `http_request` (server) | `PerformHttpRequest`, with a failure's body taken from `errorData` and held to one callback | `server.lua` |
| `http_request` (client) | The NUI page's `fetch` (client Lua has no HTTP), bounded at 30 s on the page and answered status 0 by `ui.lua` once 45 s pass or the page reloads, so it is answered exactly once whatever the page does | `ui.lua`, `nui/bridge.js` |
| `item_image` (client) | The NUI page's `fetch` too: the portal's redirect followed with `Authorization` dropped, the bytes checked with `crypto.subtle`, kept in IndexedDB under the hash (at most 512, least recently used dropped), answered as a `data:image/png;base64,` URL ending `#.png`, so ox_lib's `isIconUrl` takes it for an image, the only answer `ui.lua` takes (below) | `ui.lua`, `nui/images.js` |
| `now` | `os.time` (server) or `GetCloudTimeAsInt` (client), whole seconds, refined to milliseconds with `GetGameTimer` and kept inside the wall clock's current second | `shared.lua` |
| `after` | `Citizen.SetTimeout` | `shared.lua` |
| `kv_get`, `kv_set` | Resource KVP, with the synchronous `SetResourceKvp`, never the `NoSync` one | `shared.lua` |
| `random_hex` | Node's `crypto.randomBytes`, through the shim; Lua's generator, with one warning, only if the shim cannot answer | `server.lua` |
| `capabilities` | `position`: the player's ped's coordinates (`GetPlayerPed`, `GetEntityCoords`, which OneSync knows on the server), nil while they have no ped. `bucket`: `GetPlayerRoutingBucket`. `model`: `GetHashKey`. `entity(ref)`: a network id (`NetworkGetEntityFromNetworkId`), with its coordinates, model hash, routing bucket and the record its `rpf_placement` state bag names. `spawn`: placements below. `despawn`: `DeleteEntity`, only for an entity carrying the tag | `server.lua` |
| `thread` | `coroutine.running`: FiveM runs each event handler and timer in a coroutine of its own | `server.lua` |
| `identifiers`, `name`, `kick` | `GetPlayerIdentifiers` verbatim, `GetPlayerName`, `DropPlayer` | `server.lua` |
| `notify` | The `rpf:notify` client event, shown as a feed notification | `server.lua`, `client.lua` |
| `to_client` / `on_client`, `to_server` / `on_server` | `TriggerClientEvent` / `RegisterNetEvent`, `TriggerServerEvent` / `RegisterNetEvent`, with the sender from FiveM's `source` and anything but a string payload dropped | `server.lua`, `client.lua` |
| `request_server` / `on_client_request` | ox_lib's `lib.callback` / `lib.callback.register`, with no client-side rate limit (the core keeps its own); the server waits on the callback's thread (`Citizen.Await`) for the core's answer, which always comes, and answers a payload that is not a string with nothing | `ox.lua` |
| `request_client` / `on_server_request` | The other direction: a net event under the request's name, `<number>\n<payload>`, answered under the same number and taken only from the player asked (`server.ask`, `client.asked`); forgotten when the player leaves or after `ANSWER_TTL`. Not `lib.callback`, which keeps every request nobody answers for good. A client keeps at most `MAX_UNANSWERED` of its own requests with ox_lib at once | `server.lua`, `client.lua` |
| `ui` (client) | `lib.notify`; a context menu (`lib.registerContext`, `lib.showContext`), counted as closed when another resource's replaces it, and told it closed only once ox_lib has finished closing it, an option's item image its `icon` (#169); `lib.inputDialog`, a select's options by number, text bounds checked in bytes; `lib.progressBar`; `close` with `lib.hideContext`, `lib.closeInputDialog` and `lib.cancelProgress`. The server's `capabilities` declares all four | `ox.lua` |
| `log` | `print`, as `[rpf] <level>: <message>` | `shared.lua` |
| `expose` | The `api` export, a plain copy of `rpf.api` (read-only views do not survive FiveM's msgpack), with `events` subscriptions named by id | `shared.lua` |

The engine events (`server.lua`, `client.lua`), each handler two lines at
most:

| Event | Core call |
|---|---|
| `onResourceStart` (this resource) | Starts the core from the convars, then `players.connected` for everyone already on the server |
| `onResourceStop` (this resource) | Closes every socket it has open in `rpf-ws`, which outlives a `restart rpf` (a socket left open would keep answering the portal's pings, and the portal would refuse the restarted core as a duplicate instance), puts every held player back in their own routing bucket, and removes every entity the core placed (`rpf.world.clear`) |
| `entityRemoved` | Forgets a placed entity whoever removed it (`server.removed`), since its handle may be reused |
| `rpf:placed_peds_request` | Sends that client the placed peds (`server.peds_asked`) |
| `rpf:placed_peds` (client) | Keeps the server's placed peds, to make passive (`client.placed_peds`) |
| `playerJoining` | `players.connected(source)` |
| `playerDropped` | `players.dropped(source, reason)` |
| `chatMessage` (the `chat` resource) | Cancelled for a held player (`lock.lua`) |
| `/rpflink <code>` (`RegisterCommand`, not restricted) | `on_command`'s handler with the player's `source` (F9, #115); the server console (`source` 0) runs nothing. See below |
| `rpf-ws:open`, `rpf-ws:message`, `rpf-ws:close` | The transport, which calls the core's socket handlers |
| `onClientResourceStart` (this resource) | Starts the screens and the client core |
| `onClientResourceStop` (this resource) | Releases the input lock, which would otherwise leave the ped frozen |

`playerJoining` rather than `playerConnecting`: a connecting player's
`source` is a temporary id that changes once they join, and the core keeps
the handle for the whole session. The core's login starts when the client's
core says it is ready, which is after `playerJoining` anyway.

## Placements

The core places the ped and object records of world-backed config types
([Writing addons](../../../docs/writing-addons.md#things-in-the-world)), and the adapter does
it the OneSync way, from the server:

- **Server-authoritative.** `server.spawn` creates the entity on the server
  (`CreatePed`, `CreateObjectNoOffset`, networked), from the record's model
  name hashed with `GetHashKey` (a table's `fivem` entry, so one record
  serves both engines). Those are RPC natives: the handle they return names
  an entity only once a client has made it, so the adapter looks every
  `SPAWN_POLL_MS` (50) for it to exist with a network id, up to
  `SPAWN_TIMEOUT_MS` (5 s), and answers the core then (`failed`, its
  handle deleted, if it never came). A pending spawn whose handle the
  engine reports removed meanwhile fails, and an entity is set up only if
  the engine says this resource made it with the model asked for, so a
  recycled handle is never adopted. Then it is frozen where the record
  says (`FreezeEntityPosition`, `SetEntityHeading`), put in the record's
  routing bucket (`SetEntityRoutingBucket`), and kept when the client that
  owns it leaves (`SetEntityOrphanMode` 2, `KEEP_ENTITY`), so ownership can
  move between clients without the entity going. Its ref is its network
  id.
- **Tagged, but not trusted.** Each carries the replicated state bag
  `rpf_placement` (`{ id, type }`), for a target resource to read. The client that owns
  an entity can rewrite its state, so the adapter never reads the tag: it
  knows what it placed by its own table (`placed_here`, by server handle,
  with the model), and `server.mine` also asks the engine which resource
  made the entity (`GetEntityScript`), which no client and no other script
  can claim. An entry goes when the engine removes its entity
  (`entityRemoved`), whoever removed it, because FiveM recycles handles
  and network ids. So a client clearing the tag cannot make the core place
  a second entity, one forging it names nothing, and another script's
  entity that inherits a handle is never taken for ours.
- **Streaming and range** are OneSync's: a server entity streams to the
  players near it in its bucket, and stays whether or not anyone is near.
- **Passive peds.** What a ped does is up to its owning client, so each
  client makes the server's placed peds invincible, deaf to the world
  (`SetBlockingOfNonTemporaryEvents`) and frozen, whichever owns them. Which
  peds those are is the server's word, never the tag: the server sends the
  network ids of the peds it placed (`rpf:placed_peds`) to every client
  when they change, and to a client that asks as it starts
  (`rpf:placed_peds_request`, at most once a second per player), and the
  client looks every `PASSIVE_MS` (1 s) for those it has streamed in,
  again for one streamed in anew.
- **Cleanup.** The core removes what it placed when this resource stops
  (`onResourceStop`, `rpf.world.clear`, then `server.clear` for anything the
  adapter still holds or is still making), and `server.sweep` removes, as
  the resource starts and before the core places anything, every ped and
  object the engine says this resource made (`GetEntityScript`; it makes
  no other entity): what a crash left. So a restart, a reconnect, a config
  pushed twice or an entity another script deleted (placed again within
  `rpf.world.CHECK_MS`) never leaves a record with two entities or none.

Proven on the fake natives only: a real FXServer is still to show a server
ped's ownership moving between clients, a placed ped made passive as it
streams in, the ped staying put, how long creation takes, and
that `GetEntityScript` still names this resource for an entity an earlier
run of it made (layer 5).

## The link command

`on_command` (F9, #115) is `RegisterCommand(name, handler, false)`: not
restricted, because FiveM would otherwise want an ace permission for every
player who runs it, and the handler is what checks who they are. The core
registers one, `rpflink`, which a staff member types the code from the
portal into: `/rpflink <code>` in chat, or `rpflink <code>` in the F8
console. The `chat` resource runs a command a resource registered without
broadcasting the line, and nothing in the adapter logs or repeats the words
(`args`; never `rawCommand`). The line is the player's own typing, so a
server with a chat or command logger of its own (txAdmin's included) may
record it: that is that logger's, and a code works once and for five
minutes. Not yet seen on a real FXServer with the stock `chat` resource and
txAdmin (layer 5).

## Interactions

The core's minimal interaction UI (`rpf.targets.open`, J4) is the command
`rpf_interact`, mapped to a key with `RegisterKeyMapping`: E unless the
replicated convar `rpf_interact_key` names another, and each player can
rebind it in FiveM's settings.

`target.lua` is the optional target-resource adapter. When ox_target or
qb-target is started, it offers the rules the server sends
(`interactions.targets`) through it: a type's rule of kind `ped` on every
ped (`addGlobalPed`, `AddGlobalPed`) and of kind `object` on every object,
shown only where the entity's `rpf_placement` state bag names the rule's
type, and a models rule on those models (`addModel`, `AddTargetModel`),
each with the rule's label and distance. Each option's `canInteract`
(`target.shows`) also asks whether the server offers it to the player on
that entity, the addon's own check included (`core.targets.offered`, by
network id, so an entity that is not networked shows nothing): the
resource calls it every frame, and the core answers from what the server
last said and asks again in the background, so an option appears one
round trip after the player first aims at the entity. qb-target keys its options by
label, so each label it is given carries an invisible marker
(`target.qb_label`): two rules both labelled "Talk" stay two options, and
no other script's "Talk" is replaced or taken away. Selecting one sends the
interaction with the entity's network id, and a refusal is shown with
ox_lib's notify; the entity's answer is then asked again, since the
interaction may have changed what is offered there. New rules replace the old ones, and stopping the
resource takes them back. A target resource that starts (or restarts)
after the rules came is offered them then, and one that stops is never
asked to take them back: its exports went with it. Proven on fake exports only: a real FXServer
with ox_target and with qb-target is still to show the options (layer 5).

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
An export that raises (`rpf-ws` stopped) is not the same as `false`: `ws.lua`
logs it at `warn`, once per connection, with the error, and still returns
`false`. A `send` that returns `false` because the socket is not open is
ordinary and logs nothing. A `Hello` the platform refuses makes the core drop
the connection and back off at once.
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
- **Nothing waits without an answer** (#170). The page's `fetch` to the
  portal gives up after 30 s, and `ui.lua` answers any request the page has
  not answered status 0 after 45 s, or at once if the page reloads (it says
  `ready` again), and refuses the page's answer after that; a request that
  timed out before the page was ready is never sent. Either is an outage the
  core reports and the player can retry, with a line in the client's log. A
  NUI callback that fails, takes over 10 s or answers anything but `{ ok }`
  shows "The game did not answer" and is written to the page's console
  (`nui/bridge.js`); a login it may have started keeps its sealed
  passwords.
- The login form, which also registers, and the password change both show
  `auth.PASSWORD_REUSE_WARNING`. A saved login resumes silently.
- The login form leads to a "Delete my account" form (H6): username,
  password, and a box ticked to say it cannot be undone, with the text
  naming what stays (bans, warnings, game records). The password is sealed
  like the others and goes to the portal, never to Lua, and `ui.lua`
  refuses a `delete_account` callback the page does not say was confirmed.
  A refusal shows the portal's message; `auth.account_deleted` shows a screen telling the
  player to reconnect, with input still held. A player who is logged in, and
  so never sees the login screen, opens the same form with the client
  command `rpf_delete_account` (`RegisterCommand`, not restricted; F8 or
  `/rpf_delete_account` in chat) (#160): `ui.lua`'s `open_delete` does
  nothing unless the core is `authenticated`, locks input while the form is
  up, and the page's Back sends `close_delete`, which puts back the screen
  and lock that were up (the character screen for a player still choosing,
  the game for one in play). Back is refused while a deletion is under way,
  since putting a screen back makes the page forget its sealed passwords.
- The remember token is the only secret stored on the player's machine, in
  client KVP, and is safe there only because P1 binds it to the player's
  FiveM licence: client storage is shared by every server running a resource
  named `rpf`.
- The portal allows the page's origin, `https://cfx-nui-<resource>`, for the
  player endpoints (P1, P2).
- **Item images** (P3, #132, `rpf.items.image`) are fetched by this page
  too (`nui/images.js`), because the image route needs the API token in a
  header, which an `<img>` cannot send. The token goes in the NUI message
  to this resource's own page and from there to the portal in a header,
  never in a URL another resource could read. `fetch` follows the portal's
  redirect to the user-content domain and drops `Authorization` on the
  cross-origin hop, as the Fetch standard requires. A CEF too old to drop
  it would fail the user-content domain's CORS preflight, and every image
  would be `unavailable`: that is the first thing a real client checks.
  The user-content domain must answer with
  `Access-Control-Allow-Origin: *`.
  The bytes are checked against the hash before they are kept, in
  IndexedDB (in memory where the page has none), so an image is fetched
  once per hash, even across restarts. The answer is a `data:` URL, not a
  blob URL, which would belong to this page's origin alone: any resource's
  page can show it, and ox_lib takes it as an `image` or `icon`. A page
  that reloads mid-fetch loses its requests: its next `ready` answers each
  one `unavailable`, so nothing waits on them.
- The character screen lists, creates and selects (D5's `rpf.picker`), so a
  fresh install reaches `active` with no script of the owner's. Styling is
  out of scope.

## Testing

| What | Where | Run |
|---|---|---|
| The adapter, unmodified, on fake FiveM globals: both platforms complete, every member, the server-side lock, the screens, the two-line handlers, the manifest against `rpf.files`, ox_lib's refusals and its callback transport (a fake `lib.callback`, framed as the mock frames a request) | `lua/spec/fivem_spec.lua`, fakes in `lua/platform/mock/fivem.lua` | `busted` from `lua/` |
| A hostile client's unknown name and another player's record id refused over `lib.callback`, against the real portal | `crates/fake-server/tests/scenarios/acme_tags.rs` | `cargo test -p fake-server --features lua54 acme_tags` |
| The adapter against the real portal, under both Luas: a join with the identifiers in the expected shape, a staff kick, a cut and a restart | `crates/fake-server/tests/scenarios/fivem.rs` (`Engine::Fivem`) | `cargo test -p fake-server --features lua54 fivem` |
| Annotations, every native name and every ox_lib call, against overextended's `fivem-lls-addon` and ox_lib's own annotations at 3.40.0 (both pinned in `dev/fivem-natives`) | `.luarc.json` | `dev/fivem-natives && lua-language-server --check=lua/platform/fivem` |
| The shim: `tsc --strict` (and the NUI page's JS, `tsconfig.nui.json`), its unit tests against a local websocket server, the page's sealing, callbacks and portal requests, and item images (`test/nui.test.ts`, `test/bridge.test.ts`, `test/images.test.ts`), and the contract test | `ws-shim/` | `npm ci && npm run typecheck && npm test` |
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
  knows, with their lifecycle state and the identifiers FiveM reports for
  them (an `ip:` without its address), to compare with what the portal
  stored.

Run for #110 on FXServer 35245 under OneSync, against a local portal:

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
  password (the delete form's included), a deletion from the login screen
  ending on the reconnect screen, silent resume on a second join, the character screen reaching
  `active` on a fresh install, and the identifiers the portal stores (the
  account `license:` and the allowlisted kinds verbatim, with no `ip:`).
  It needs the game, and waits on the repository owner (#110).
- Item images on a real client (#132) are still to run: CEF dropping
  `Authorization` on the portal's redirect (the user-content domain's log
  shows no bearer token), the user-content domain's CORS answer, IndexedDB
  keeping an image across a restart of the game, and a `data:` URL drawn
  in another resource's page and as ox_lib's `image`.
- ox_lib on a real server (J10, #131) is still to run: `rpf` refusing to
  start beside an ox_lib older than 3.40.0 with the `ox.problem` line, and
  an interaction's request and answer crossing `lib.callback` from a real
  client (`/spray`, and `/tags`, which lists the player's tags as data and
  shows them in `rpf.ui.menu`), including one sent while the server is
  restarting, which the core's timeout answers; and `rpf.ui` drawn by
  ox_lib's NUI: a notification of each kind, a menu picked and closed
  (and one replaced by another resource's), an input dialog with each
  field kind, a select's default and a required field, a progress bar run
  out and cancelled with X, and a server's menu answered from the client.
