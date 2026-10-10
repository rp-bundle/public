# Platform adapters

An adapter puts the Lua core (`lua/core/`) on one engine. It does two things
and nothing else: it **supplies the platform table** the core asks for, and it
**translates the engine's events** into core calls, at most two lines each.
Protocol, config and retry logic never appear in an adapter: if one does, it
is in the wrong layer and would have to be written again for the next engine.
The core never branches on `engine`; an engine difference is a platform
function.

| Directory | What |
|---|---|
| `mock/` | The mock platform (D3), standing in for an adapter in the fake game server (`crates/fake-server/`); `mock/gmod.lua` and `mock/fivem.lua`, fake engine globals the real adapters run on unmodified |
| `gmod/` | Garry's Mod (D8), over GWSockets |
| `fivem/` | FiveM (D2), over a TypeScript websocket shim in FiveM's JS runtime; [`fivem/README.md`](fivem/README.md) |

## A new platform, as a checklist

1. **The server platform table**, every member of `rpf.ServerPlatform`
   (`lua/core/meta/platform_server.lua` and `platform_shared.lua`, listed in
   `lua/core/README.md`, "The server platform interface"), annotated
   `---@type rpf.ServerPlatform` so the language server checks it.
   `rpf.start_server` refuses a table missing any member, naming each.
   - `connect` / `disconnect` / `send`: `open` once or `close` once per
     `connect`, never both for a failed attempt, nothing after `close`, never
     synchronously inside `connect`, one connection at a time. Text frames,
     byte for byte. `send` returns `false`
     for a frame that did not leave, and logs why at `warn`, once per
     connection, when the engine call raised: the core decides what a refused
     frame means (a refused `Hello` is a failed attempt, retried after a
     backoff). If the engine's Lua has no websocket, a shim in another
     runtime owns it and frames cross as strings, with the contract written
     in both languages and a test holding them together (FiveM's
     `ws-shim/`).
   - `kv_get` / `kv_set`: atomic per key and durable when `kv_set` returns
     (raise rather than return on a failed write), values of 1 MiB plus a
     header and about 9 MiB in all. Confirm both bounds on the real engine.
   - `now` is the wall clock in milliseconds; `after` runs later, never inside
     the caller.
   - `random_hex` from the best source the engine has.
   - `capabilities` declares what the engine can do with the game world,
     each capability a function or `false` (`rpf.world`): `position` a
     player's position as `{ x, y, z }`; `bucket` their routing bucket
     (`false` on an engine with one world); `model` the engine's id for a
     model name; `entity(ref)` a networked entity by the number every
     machine names it by, with `placement`, the record id its tag names;
     `spawn(spec, done)` placing a record's ped or object
     server-authoritatively, tagged with the record's id, handing `done`
     its ref at once or later (within a bounded wait), reading the record's
     model as a name or as its own engine's entry of a table; and
     `despawn(ref)` removing only an entity it placed (J4). An adapter
     that places entities also removes, as it starts and before the core
     starts, every entity a crash left, known from a record of its own
     that no client can write (a client may be able to rewrite an
     entity's tag); and it
     calls `rpf.world.clear()` as it stops, where it can stop without its
     state ending. Beside them, `notify`, `menu`, `input` and
     `progress`, each `true` or `false`: whether this engine's clients show
     an addon's UI (J10, `rpf.ui`). Never leave one out: say unsupported on
     purpose.
   - `thread` names the running coroutine (`coroutine.running`), or returns
     nil where there are none, so the core keeps whose code is running per
     coroutine.
   - `identifiers` verbatim, with the engine account identifier the portal's
     `ENGINE_IDENTIFIERS` names for this engine. **Add the engine to that list
     in the same PR**, or none of its players can log in.
   - `to_client` / `on_client` carry strings byte for byte, whatever the
     engine's message size limit; the platform supplies the sender.
   - `on_client_request` answers a client's `request_server` (J10): the
     platform pairs a request with its answer and supplies the sender, and
     the core always answers. Use the engine's own pairing where it has one
     (ox_lib's `lib.callback` on FiveM), or number them (Gmod's `net`, the
     mock: `<number>\n<body>`). `request_client` is the other direction,
     and takes an answer only from the player it asked: the core's
     callback for one player's menu must never hear another's.
   - `expose` publishes `rpf.api` the way scripts on this engine share code.
     Where each resource has its own Lua state, that is an export of a plain
     copy: read-only views do not survive serialisation, and neither does a
     function's identity (FiveM's `shared.lua`). Where the engine can say
     which code is calling (a resource), each exported call names it to the
     core (`rpf.addons.from`), and code that stops is unloaded
     (`rpf.unload_origin`), so an addon's timers and handlers go with
     it.
2. **The client platform table**, every member of `rpf.ClientPlatform`
   (`meta/platform_client.lua`), with the same rules where they overlap.
   `request_server` hands its callback the server's answer, or nothing;
   the core keeps its own timeout. `on_server_request` answers the server
   once, perhaps after the player has picked. `ui` builds what an addon
   shows (J10): `notify`, `menu`, `input` and `progress`, each over the
   engine's own toolkit where it has one, taking a spec `rpf.ui` checked
   and calling `done` once with what the player did; and `close(kind)`
   takes away a window whose addon stopped.
3. **The engine events**, two lines each: a player handed over calls
   `core.players.connected(handle)`, a player gone calls
   `core.players.dropped(handle, reason)`. Use the handle the engine keeps
   for the whole session (FiveM's `playerConnecting` hands over a temporary
   id, so its adapter listens for `playerJoining`). Start the client core
   when the player is in the game and can send to the server.
4. **The input lock.** Until a player is `active`, they cannot act on the
   world, held server-side by the adapter. Bridges to existing frameworks
   (K2) rely on it.
5. **The login form and the character screen**, calling `rpf.auth` and
   `rpf.picker`. The password goes from the client straight to the portal,
   never through the game server, and where the form is not Lua it keeps
   the password out of Lua too (FiveM's `nui/seal.js`); every form where a
   player chooses a password shows `PASSWORD_REUSE_WARNING`; nothing claims
   the server cannot see the password.
6. **Refuse to start clearly** when something the platform needs is missing:
   one log line naming it and how to fix it.
7. **Tests.** Fake engine globals the adapter runs on unmodified, a busted
   spec over them, a fake-server engine (`fake_server::Engine`) so a real
   login crosses the real portal, the engine's API annotations loaded in the
   language-server check if a maintained set exists, and a smoke test on a
   real server (`docs/testing.md`, layer 5).

## Garry's Mod (`gmod/`)

| File | What |
|---|---|
| `autorun.lua` | The entry point, shipped as `lua/autorun/rpf.lua`: picks the side |
| `load.lua` | Loads the core with `include`, marks the client's files for download |
| `server.lua` | The server platform, the refusals, the convars, the engine hooks |
| `client.lua` | The client platform; starts the client core on `InitPostEntity` |
| `shared.lua` | Clock, SQLite storage, `HTTP`, logging, `expose` |
| `transport.lua` | The websocket, over GWSockets |
| `messages.lua` | `net` messages, in parts past `net`'s 64 KiB, and requests with their answers, numbered |
| `random.lua` | `random_hex`: SHA-256 in counter mode over an entropy pool |
| `lock.lua` | The input lock |
| `ui.lua` | The Derma login form and character screen |
| `addon_ui.lua` | The UI addons show (J10): Gmod's notifications, and a Derma menu, input dialog and progress bar |
| `dev.lua` | Development-only console commands for the smoke test; not shipped |
| `meta/gwsockets.lua` | Annotations for GWSockets, which ships none |

**Layout.** The addon puts `lua/core/` at `lua/rpf/core/`,
`lua/platform/gmod/` at `lua/rpf/platform/gmod/`, and `gmod/autorun.lua` at
`lua/autorun/rpf.lua`. Every addon shares one Lua state, so the core's one
global is `rpf`, and once the adapter publishes it, `rpf` is the public API,
not the core.

**Install.** A release's `rpf-gmod-<version>.zip` holds the addon as one
`rpf` folder in that layout, for `garrysmod/addons/` (`dev/release-addon`,
[Deployment](../../docs/deployment.md#the-game-server-release)). GWSockets is required: put `gmsv_gwsockets_<platform>.dll` from
<https://github.com/FredyH/GWSockets> into `garrysmod/lua/bin/`. Gmod has no
websocket of its own and there is no fallback (#57), so without it the
adapter logs one line saying so and starts nothing; one that is installed
but will not load (a build for another platform) is refused the same way,
naming the build to install. Then, in `server.cfg`:

```
rpf_ws_url "wss://<portal>/ws"
rpf_api_key "rpf_…"
// rpf_portal_url "https://<portal>"   only if players log in elsewhere
```

`rpf_api_key` is a protected convar: its value never reaches a client.
Gmod runs `server.cfg` after the map loads, so the adapter looks for the
convars every second from `InitPostEntity`, says once after ten seconds if
they are still unset, and starts as soon as they are. A url or key that is
set but malformed (`rpf.client.target_problem`) is said once, and again
only if it changes to another mistake, and it starts once it is put right.
[Installing](../../docs/installing.md) is the owner's guide. It sets
`sv_hibernate_think 1`, because an empty server otherwise stops its timers
and GWSockets' `Think`, and with them the portal connection. A portal on a
private address (development) needs the game started with `-allowlocalhttp`
for the clients' `HTTP`.

**What Gmod changes, and where:**

- *Identifiers.* Gmod has one: `steam:<SteamID64>`, the engine account
  identifier remember tokens are bound to. A player with none (singleplayer)
  reports nothing, and the portal refuses the login.
- *Client storage is not private.* Any server's client Lua can read `cl.db`,
  where the client stores the remember token. That is safe only because the
  portal binds the token to the SteamID64 the server reports (P1); nothing
  else secret is stored on the client.
- *Storage* is SQLite through `sql.QueryTyped`, binding values rather than
  quoting them, so a megabyte value never meets SQLite's statement length
  limit. Gmod builds without it are refused. Checked on a real server: nine
  values of 1 MiB plus 256 bytes each, read back byte for byte.
- *`net` messages* hold 64 KiB, and the list of characters may be that long,
  so a payload travels in parts (`messages.lua`). The server takes a client's
  payload only in one part.
- *The clock.* `os.time` has whole seconds, so `now` reads `SysTime` from a
  wall-clock anchor, and re-anchors when the two disagree by two seconds.
- *Randomness.* Gmod gives Lua no cryptographic source. `random_hex` is good
  for the ids the core mints from it, none of which is a credential.
- *Map changes* end the Lua state: the adapter closes the socket on
  `ShutDown`, and the next map's state is a new instance over the same store.
- *Player disconnects* carry no reason in `PlayerDisconnected`, so the core
  is told `"disconnected"`.
- *Capabilities* (J3, J4): `position` is `ply:GetPos()`. Gmod has one
  world, so `bucket` is `false` and a record in any bucket but 0 is not
  placed. An entity's ref is its index; `model` lowercases a path, as
  `GetModel` reports one. `spawn` makes a `prop_dynamic` with the record's
  `gmod` model (a ped is a prop with a character's model, in its default
  animation, since Gmod's NPCs have AI of their own), tagged with the
  networked string `rpf_placement`; the adapter removes tagged entities as
  it starts (a Lua refresh restarts it on the same map), and a map change
  takes the rest. Drawn on fake globals only so far. All four UI kinds are supported
  (`addon_ui.lua`): a progress bar is X to cancel, as on ox_lib, and an
  input dialog will not submit a required field left empty or a value out
  of its bounds. Drawn on fake Derma only so far: a real Gmod client is
  still to show them (layer 5).

The language-server check for this directory runs on its own
(`lua/platform/gmod/.luarc.json`) with the GLua annotations
`dev/glua-api` fetches, because the main check runs with no game globals.

## FiveM (`fivem/`)

Two resources: `rpf` (the core, the adapter and its NUI screens) and
`rpf-ws` (the websocket shim, bundled with `ws`), assembled by
`dev/fivem-resources`, and ox_lib, a prerequisite the owner installs,
which `ox.lua` builds on (J10). [`fivem/README.md`](fivem/README.md) has the
install, the convars, how each platform member is done, the shim's
contract, the screens and the input lock, the tests, and the layer-5 run on
a real FXServer (resource KVP held the outbox's bounds). Its
language-server check runs on its own (`lua/platform/fivem/.luarc.json`)
with the FiveM natives and ox_lib's annotations `dev/fivem-natives` fetches.
