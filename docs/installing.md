# Installing

How a server owner goes from a stock game server to one connected to the
portal, on FiveM and on Garry's Mod, and what to do when it says no. You
install a **release**: a GitHub Release of this repository, one per version,
whose downloads are built and checked by `release-addon.yml`
([Deployment](deployment.md#the-game-server-release)). Nothing is built on
your machine.

## Before you start

In the portal:

1. Create your community (a guild) and a server in it.
2. On the server's **API keys** page, issue a key. The page shows it once,
   with the exact `server.cfg` lines for FiveM and for Garry's Mod: the
   portal's websocket address and the key. Copy them now. If you lose the
   key, revoke it and issue another.

Each release's notes list its downloads with their SHA-256 checksums. To
check one, download `SHA256SUMS` beside it and run
`sha256sum --ignore-missing -c SHA256SUMS`.

Which release to install: the one the portal names. When a server runs an
older core, its **Game server** card in the portal says **Update
available** and links the release to install. Compatibility is decided by
the protocol, not the version, and a server on an older release keeps
working for its support window ([Compatibility](compatibility.md)).

## FiveM

You need a current FXServer artifact with **OneSync** on (not `legacy`), which it is by
default on a current server. The framework holds each player in a routing
bucket of their own until they have logged in, and routing buckets are a
OneSync feature.

### With txAdmin

1. In txAdmin's setup, choose **Remote URL Template** and give it the
   release's recipe:
   `https://github.com/Sampleeeee/rp-framework/releases/latest/download/rpf-txadmin-recipe.yaml`.
   For a specific release, use `releases/download/v<version>/rpf-txadmin-recipe.yaml`
   instead.
2. Run the deployer. It installs txAdmin's basic server, the default
   resources and the `[rpf]` folder, with OneSync on.
3. When the deployer shows `server.cfg`, paste the two values from the
   portal into the `set rpf_url ""` and `set rpf_api_key ""` lines at the
   bottom, then start the server.

### By hand

1. Download `rpf-fivem-<version>.zip` from the release.
2. Unzip it into the server's `resources/`. You get one folder, `[rpf]`,
   holding the two resources `rpf` and `rpf-ws`. FXServer finds resources
   inside a bracketed folder, and starts only what `server.cfg` ensures.
3. Paste the FiveM lines from the portal into `server.cfg`:

   ```
   set rpf_url "wss://portal.example/ws"
   set rpf_api_key "rpf_…"
   ensure rpf-ws
   ensure rpf
   ```

   Keep `set`. `setr` and `sets` publish a convar to every client or to
   the server list, and the key is a secret. `rpf-ws` before `rpf`: it
   carries the portal connection.
4. Start (or restart) the server.

Optional convars: `set rpf_portal_url "https://portal.example"` when
players reach the portal's web address somewhere other than the websocket's
host, and `set rpf_debug "true"` for the core's debug lines. Other
resources reach the framework as `exports.rpf:api()`
([the FiveM adapter](../lua/platform/fivem/README.md)).

### Upgrading

Replace the `[rpf]` folder with the new release's and restart the server.
Your `server.cfg` stays as it is. A release that changes anything you set
says so in its notes.

## Garry's Mod

### Install

1. **GWSockets** (required; Garry's Mod has no websocket of its own, and the
   framework has no fallback). Download the build for your server from
   <https://github.com/FredyH/GWSockets/releases> and put it in
   `garrysmod/lua/bin/` (create the folder if needed):
   `gmsv_gwsockets_win64.dll` on a 64-bit Windows server,
   `gmsv_gwsockets_linux64.dll` on a 64-bit Linux one, and the `win32` or
   `linux` build on a 32-bit server.
2. Download `rpf-gmod-<version>.zip` from the release and unzip it into
   `garrysmod/addons/`. You get one folder, `rpf`.
3. Paste the Garry's Mod lines from the portal into `garrysmod/cfg/server.cfg`:

   ```
   rpf_ws_url "wss://portal.example/ws"
   rpf_api_key "rpf_…"
   ```

   `rpf_api_key` is a protected convar: its value never reaches a client.
4. Start (or restart) the server.

Players need nothing installed: the server sends their client the
framework's Lua when they join. Optional: `rpf_portal_url
"https://portal.example"` when players reach the portal's web address
somewhere other than the websocket's host. Other addons reach the framework
through the `rpf` global ([the platform adapters](../lua/platform/README.md)).

### Upgrading

Replace the `addons/rpf` folder with the new release's and restart the
server. GWSockets and `server.cfg` stay as they are.

## The first connection

A connected server says so in its console, on both engines:

```
rpf: connected as server <its id in the portal>
```

In the portal, the server's page shows **Connected** on its **Game server**
card, with the engine and core version it reported, and the server receives
its config straight away. Players who join see the login screen. Each
player registers or logs in with their account for your community, then
picks or creates a character.

If the console shows something else, look for its line below.

## Troubleshooting

Each entry is a line the framework logs, as it appears after the level
(`[rpf] error:` on FiveM, `[error]` on Garry's Mod). Every refusal at start
is one line, and the framework connects to nothing until it is fixed.

### At start, on FiveM

**`rpf: set rpf_url and rpf_api_key in server.cfg (with `set`, never `setr` or `sets`, which publish the key); not connecting`**:
one or both convars are empty. Paste the lines from the server's **API
keys** page, then `restart rpf`.

**`rpf: rpf_url is not the portal's websocket address: …`**:
the address must start `wss://` (`ws://` only for a portal on the same
machine), like `wss://portal.example/ws`. A common slip is pasting the
portal's web address (`https://…`).

**`rpf: rpf_api_key does not look like a server API key, which starts rpf_ …`**:
the key was cut short or has a space or line break in it. Copy it again, or
issue a new one if it is gone. The line never shows the key.

**`rpf: this FXServer artifact has no SetPlayerRoutingBucket, …`** (or
another native): the artifact is too old for the routing buckets the
framework needs. Update it from <https://runtime.fivem.net/artifacts/fivem/>
(txAdmin can do it for you).

**`rpf: OneSync is off, …`** (or `legacy`): set it on with `set onesync on`
in `server.cfg`, or txAdmin's OneSync setting, and restart the server.
`legacy` is not enough: routing buckets need OneSync on.

**`rpf: the rpf-ws resource is stopped, …`** (or `missing`, `uninitialized`):
`rpf-ws` is not running. Check that both folders from the release's `[rpf]`
are in `resources/`, and that `server.cfg` ensures `rpf-ws` before `rpf`.
If it is there and still does not start, its own error is earlier in the
console. On an artifact whose Node is older than 16, the bundle cannot
load: update the artifact.

**FXServer saying it could not find the dependency `rpf-ws` for `rpf`**
(its own line, not the framework's): the `rpf-ws` folder is missing. Unzip the whole release, not only
`rpf`.

### At start, on Garry's Mod

**`rpf: the GWSockets binary module (gmsv_gwsockets) is not installed, …`**:
put the GWSockets build for your server in `garrysmod/lua/bin/` (Install,
above).

**`rpf: the GWSockets binary module is installed but would not load (…), …`**:
the file is there but is the wrong build. A 64-bit server needs the `win64`
or `linux64` build, a 32-bit one the `win32` or `linux` build. Replace it
and restart.

**`rpf: this Garry's Mod build has no sql.QueryTyped, …`**: the server is
too old. Update it.

**`rpf: set rpf_ws_url and rpf_api_key in server.cfg; the framework is not started.`**:
logged ten seconds after the map loads if either convar is still empty.
Garry's Mod runs `server.cfg` after the map loads, so the framework keeps
looking, and starts as soon as both are set, from `server.cfg` or the
console.

**`rpf: rpf_ws_url is not the portal's websocket address: …`** and
**`rpf: rpf_api_key does not look like a server API key, …`**: as on FiveM,
above. The framework starts as soon as the convar is put right.

### When it connects, on either engine

These come from the core, after it has started.

**`rpf: stopped: the portal refused Hello (unauthorised): invalid server key`**
(or `server key revoked`): the portal does not know this key, or it was
revoked. Issue a new one on the server's **API keys** page and set it. The
framework stops for good on this, so restart it after (`restart rpf` on
FiveM, a map change or restart on Garry's Mod).

**`rpf: stopped: the portal refused Hello (malformed): unsupported protocol version …; upgrade the rpf core on this game server`**:
this release is too old for the portal: its protocol is no longer served.
Install the release the portal names (Upgrading, above). The same line saying
the core is *newer* than the portal means a development build or a portal
that was rolled back. Install the release the portal names.

**`rpf: the portal refused Hello (suspended): …`**: your community is
suspended by the platform operator. The server keeps trying every few
minutes and comes back on its own once the suspension is lifted. Contact
support.

**`rpf: disconnected (…); reconnecting in … ms`**: the connection failed or
dropped, and the core is trying again with a growing delay. One now and then
is normal: a portal deploy, a network blip. If it repeats from the start,
the address is wrong or unreachable. Read the reason in brackets. On FiveM
it is the shim's (`cannot connect: …` and the websocket library's words, as
below); GWSockets words its own way:

- `Unexpected server response: 404`: the host is right but the path is not.
  The address ends `/ws`.
- `getaddrinfo ENOTFOUND …`, `ECONNREFUSED`, a timeout: the host or port is
  wrong, or the server cannot reach it (a firewall).
- A certificate error: the portal's certificate is not trusted from the game
  server, or `wss://` was used for a portal that only speaks `ws://`.

**`rpf: stopped: the portal refused Hello (duplicate_instance): another live instance is connected`**:
another game server process is connected with this server's key, and the
portal checked that it is still answering. Two game servers share one
server in the portal: give each its own server and key. The framework stops
for good on this. Restart it once the other is gone.

**`rpf: the portal is restarting; reconnecting … ms after it closes`**: a
portal deploy. Nothing to do.

## Decisions

### A txAdmin recipe: shipped

Most FiveM servers are set up through txAdmin, and its deployer is the one
place an owner can go from nothing to a running server without touching a
file. The recipe is txAdmin's own basic server plus the release's `[rpf]`
folder and the four `server.cfg` lines, with OneSync on, and the deployer's
`server.cfg` step is where the owner pastes the address and the key. So
setup through txAdmin is one URL and two values, which is as short as
it gets while each server has a key of its own. It is pinned three ways, so
it deploys the same server whenever it runs:

- each release publishes its own recipe, downloading that release's zip;
- txAdmin's basic recipe's `server.cfg` is pinned to a commit of
  `citizenfx/txAdmin-recipes`;
- the default resources are pinned to a commit of `citizenfx/cfx-server-data`.

The release that is GitHub's "latest" serves the address above. txAdmin
recipes cannot check a download's checksum. An owner who wants that installs
by hand. The recipe is not in txAdmin's built-in list, which Cfx.re curates.
Submitting it is for when the framework is public.

### Steam Workshop for Garry's Mod: not published

Publishing the addon to the Workshop was evaluated and decided against, for
now:

- **It would not remove a step.** GWSockets is a binary module, which the
  Workshop cannot carry, so every owner still downloads it by hand. The
  addon itself is one folder to unzip.
- **It would upgrade servers behind their owners' backs.** A server
  following a Workshop item downloads each update on restart. Upgrading
  here is the owner's decision, with release notes that may ask them to do
  something first ([Compatibility](compatibility.md#what-a-server-owner-touches)).
  A Workshop item pins no version.
- **Players gain nothing.** The addon is Lua only: the server sends it to
  each client on join, so no player needs to subscribe to anything.
- **It is another channel to secure.** A Workshop item is updated from a
  Steam account rather than by the tagged, checked release workflow.

Revisit it if the addon gains content a client must download (models,
materials), which the Workshop is good at.
