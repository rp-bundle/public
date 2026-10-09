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
     byte for byte. If the engine's Lua has no websocket, a shim in another
     runtime owns it and frames cross as strings, with the contract written
     in both languages and a test holding them together (FiveM's
     `ws-shim/`).
   - `kv_get` / `kv_set`: atomic per key and durable when `kv_set` returns
     (raise rather than return on a failed write), values of 1 MiB plus a
     header and about 9 MiB in all. Confirm both bounds on the real engine.
   - `now` is the wall clock in milliseconds; `after` runs later, never inside
     the caller.
   - `random_hex` from the best source the engine has.
   - `identifiers` verbatim, with the engine account identifier the portal's
     `ENGINE_IDENTIFIERS` names for this engine. **Add the engine to that list
     in the same PR**, or none of its players can log in.
   - `to_client` / `on_client` carry strings byte for byte, whatever the
     engine's message size limit; the platform supplies the sender.
   - `expose` publishes `rpf.api` the way scripts on this engine share code.
     Where each resource has its own Lua state, that is an export of a plain
     copy: read-only views do not survive serialisation, and neither does a
     function's identity (FiveM's `shared.lua`).
2. **The client platform table**, every member of `rpf.ClientPlatform`
   (`meta/platform_client.lua`), with the same rules where they overlap.
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
| `messages.lua` | `net` messages, in parts past `net`'s 64 KiB |
| `random.lua` | `random_hex`: SHA-256 in counter mode over an entropy pool |
| `lock.lua` | The input lock |
| `ui.lua` | The Derma login form and character screen |
| `dev.lua` | Development-only console commands for the smoke test; not shipped |
| `meta/gwsockets.lua` | Annotations for GWSockets, which ships none |

**Layout.** The addon puts `lua/core/` at `lua/rpf/core/`,
`lua/platform/gmod/` at `lua/rpf/platform/gmod/`, and `gmod/autorun.lua` at
`lua/autorun/rpf.lua`. Every addon shares one Lua state, so the core's one
global is `rpf`, and once the adapter publishes it, `rpf` is the public API,
not the core.

**Install.** GWSockets is required: put `gmsv_gwsockets_<platform>.dll` from
<https://github.com/FredyH/GWSockets> into `garrysmod/lua/bin/`. Gmod has no
websocket of its own and there is no fallback (#57), so without it the
adapter logs one line saying so and starts nothing. Then, in `server.cfg`:

```
rpf_ws_url "wss://<portal>/ws"
rpf_api_key "rpf_…"
// rpf_portal_url "https://<portal>"   only if players log in elsewhere
```

`rpf_api_key` is a protected convar: its value never reaches a client.
Gmod runs `server.cfg` after the map loads, so the adapter looks for the
convars every second from `InitPostEntity`, says once after ten seconds if
they are still unset, and starts as soon as they are. It sets
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

The language-server check for this directory runs on its own
(`lua/platform/gmod/.luarc.json`) with the GLua annotations
`dev/glua-api` fetches, because the main check runs with no game globals.

## FiveM (`fivem/`)

Two resources: `rpf` (the core, the adapter and its NUI screens) and
`rpf-ws` (the websocket shim, bundled with `ws`), assembled by
`dev/fivem-resources`. [`fivem/README.md`](fivem/README.md) has the
install, the convars, how each platform member is done, the shim's
contract, the screens and the input lock, the tests, and the layer-5 run on
a real FXServer (resource KVP held the outbox's bounds). Its
language-server check runs on its own (`lua/platform/fivem/.luarc.json`)
with the FiveM natives `dev/fivem-natives` fetches.
