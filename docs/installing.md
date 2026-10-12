# Installing

How a server owner goes from a stock game server to one connected to the
portal, on FiveM and on Garry's Mod, and what to do when it says no. You
install a **release**: a GitHub Release of the framework's public
repository, [Sampleeeee/rpf](https://github.com/Sampleeeee/rpf/releases),
one per version, whose downloads are built and checked before they are
published. Nothing is built on your machine. The framework is open source
under the MIT License, and that repository holds its source and history.

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

You also need **[ox_lib](https://github.com/overextended/ox_lib) 3.40.0 or
newer**, which most FiveM servers run already (Qbox requires it). The
framework carries requests between players' clients and the server over its
callbacks, and builds the menus and dialogs addons show on it. It is a
separate download under its own licence (LGPL-3.0), so the release does not
include it: the txAdmin recipe installs it, and by hand you download
`ox_lib.zip` from its [releases](https://github.com/overextended/ox_lib/releases).

### With txAdmin

1. In txAdmin's setup, choose **Remote URL Template** and give it the
   release's recipe:
   `https://github.com/Sampleeeee/rpf/releases/latest/download/rpf-txadmin-recipe.yaml`.
   For a specific release, use `releases/download/v<version>/rpf-txadmin-recipe.yaml`
   instead.
2. Run the deployer. It installs txAdmin's basic server, the default
   resources, ox_lib and the `[rpf]` folder, with OneSync on.
3. When the deployer shows `server.cfg`, paste the two values from the
   portal into the `set rpf_url ""` and `set rpf_api_key ""` lines at the
   bottom, then start the server.

### By hand

1. Download `rpf-fivem-<version>.zip` from the release.
2. Unzip it into the server's `resources/`. You get one folder, `[rpf]`,
   holding the resources `rpf` and `rpf-ws`, and `rpf-qbox`, which only a
   server running Qbox uses ([Beside Qbox](#beside-qbox)). FXServer finds
   resources inside a bracketed folder, and starts only what `server.cfg`
   ensures.
3. If the server has no ox_lib, or one older than 3.40.0, download
   `ox_lib.zip` from [its releases](https://github.com/overextended/ox_lib/releases)
   and unzip it into `resources/` too: one folder, `ox_lib`. Take the
   release's `ox_lib.zip`, not GitHub's "Source code" archive, which lacks
   its built web page.
4. Paste the FiveM lines from the portal into `server.cfg`:

   ```
   set rpf_url "wss://portal.example/ws"
   set rpf_api_key "rpf_…"
   ensure ox_lib
   ensure rpf-ws
   ensure rpf
   ```

   Keep `set`. `setr` and `sets` publish a convar to every client or to
   the server list, and the key is a secret. `ox_lib` and `rpf-ws` before
   `rpf`: `rpf` is built on the first, and the second carries the portal
   connection. A server that ensures ox_lib already keeps its own line.
5. Start (or restart) the server.

Optional convars: `set rpf_portal_url "https://portal.example"` when
players reach the portal's web address somewhere other than the websocket's
host, `set rpf_debug "true"` for the core's debug lines, and `set rpf_map
"<name>"` when the server loads a setup of the map whose placed things
staff keep apart, such as an event's: things placed in the portal for
another map name stay out of the world. Without it the map is `default`.
`restart rpf` takes a new name. Other
resources reach the framework as `exports.rpf:api()`
([the FiveM adapter](../lua/platform/fivem/README.md)).

Staff link their player account to their portal account with the code
from the portal's in-game account page, typed as `/rpflink <code>` in chat
or `rpflink <code>` in the F8 console. It is registered for every player
(it needs no ace permission), and nothing logs the code.

A player deletes their own account, for good, from the login screen or, once
logged in, with `rpf_delete_account` in the F8 console or chat. It asks for
the username and password and a ticked box, and an account linked to a staff
account must be unlinked on the portal first.

Players open a menu of what they can interact with near them with **E**
(`rpf_interact`, which each player can rebind in FiveM's key settings).
Change the default with `setr rpf_interact_key "G"`: `setr`, because each
player's client reads it. If the server runs **ox_target** or
**qb-target**, the framework also offers the same interactions through it
on the peds and objects it places; nothing to configure. Either way a
player is only offered what they may use there.

### Upgrading

Replace the `[rpf]` folder with the new release's and restart the server.
Your `server.cfg` stays as it is. A release that changes anything you set
says so in its notes, and so does one that needs a newer ox_lib, which the
console says at start too.

### Beside Qbox

A server already running [Qbox](https://github.com/Qbox-project/qbx_core)
can keep it. Qbox goes on owning characters, money and jobs, ox_inventory
goes on owning items, and the framework adds its player accounts and
login, moderation, the staff portal and addons. This is the **companion**
profile, and the release's `rpf-qbox` resource is the bridge between them
([the bridge](../lua/bridges/qbox/README.md)). It was tested with qbx_core
1.24.0, ox_inventory 2.48.0 and ox_lib 3.40.0, and logs a warning on
another qbx_core.

1. In the portal, on the server's **Settings** page, set **Profile** to
   **Companion**. The game server takes it at its next start, and the page
   says "Pending restart" until then.
2. In `qbx_core/config/client.lua`, set `useExternalCharacters = true`. The
   bridge is the character selection now, shown once a player has logged
   in to the framework. Remove any other character selection resource: a
   second one would load characters past the framework's login, and the
   bridge logs those out (Troubleshooting, below).
3. In `server.cfg`, after Qbox's own lines (`ensure [ox]`, `ensure [qbx]`
   in its recipe, which start ox_lib, oxmysql, qbx_core and ox_inventory),
   ensure the framework and then the bridge:

   ```
   set rpf_url "wss://portal.example/ws"
   set rpf_api_key "rpf_…"
   ensure rpf-ws
   ensure rpf
   ensure rpf-qbox
   ```

4. Restart the server.

A player logs in to the framework first, and then picks or creates a
character in the bridge's selection. Creating one goes through qbx_core's
own creation, so its character limit and starter items apply. Restarting
qbx_core or ox_inventory needs nothing else: until it is back, the bridge
answers addons that it is unavailable. `restart rpf` stops `rpf-qbox` with
it, so follow it with `ensure rpf-qbox`.

What qbx_core leaves open: its own character callbacks still log in any
client that asks, whatever `useExternalCharacters` says. The bridge logs
such a character out at once, while the framework still holds the player
still, but qbx_core keeps it loaded for about 200 ms first. Closing that
gap is qbx_core's to do.

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
   `garrysmod/addons/`. You get two folders: `rpf`, the framework, and
   `rpf_darkrp`, the bridge to DarkRP. Delete `rpf_darkrp` unless the
   server runs DarkRP (Beside DarkRP, below).
3. Paste the Garry's Mod lines from the portal into `garrysmod/cfg/server.cfg`:

   ```
   rpf_ws_url "wss://portal.example/ws"
   rpf_api_key "rpf_…"
   ```

   `rpf_api_key` is a protected convar: its value never reaches a client.
4. Start (or restart) the server.

Players open a menu of what they can interact with near them with the
console command `rpf_interact`, which they bind to a key themselves
(`bind f rpf_interact`): Garry's Mod's E is already `+use`.

Staff link their player account to their portal account with the code
from the portal's in-game account page, typed as `rpflink <code>` in the
console or `/rpflink <code>` in chat. The console is the safer way where
other addons log chat: their hooks may see a chat line before RPF drops it.

A player deletes their own account, for good, from the login screen or, once
logged in, with the console command `rpf_delete_account`. It asks for the
username and password and a ticked box, and an account linked to a staff
account must be unlinked on the portal first.

Players need nothing installed: the server sends their client the
framework's Lua when they join. Optional: `rpf_portal_url
"https://portal.example"` when players reach the portal's web address
somewhere other than the websocket's host. Other addons reach the framework
through the `rpf` global ([the platform adapters](../lua/platform/README.md)).
Things staff place in the portal for one map appear only on that map: the
server reports the map it loaded, and a map change reconnects with the new
one.

### Upgrading

Replace the `addons/rpf` folder with the new release's, and
`addons/rpf_darkrp` too if you run it, and restart the server. GWSockets
and `server.cfg` stay as they are.

### Beside DarkRP

A server already running [DarkRP](https://github.com/FPtje/DarkRP) can keep
it. DarkRP goes on owning money and jobs, and the framework adds its player
accounts and login, moderation, the staff portal and addons, without
characters or items of its own. This is the **companion** profile, and the
release's `rpf_darkrp` addon is the bridge between them
([the bridge](../lua/bridges/darkrp/README.md)). It was tested with DarkRP
2.7.0, and logs a warning on another version.

1. In the portal, on the server's **Settings** page, set **Profile** to
   **Companion**. The game server takes it at its next start, and the page
   says "Pending restart" until then.
2. Keep both folders from the zip in `garrysmod/addons/`: `rpf` and
   `rpf_darkrp`. Nothing in DarkRP or `darkrpmodification` changes.
3. Restart the server.

DarkRP has no characters, so a player's character is their DarkRP data,
under their SteamID64: once they have logged in to the framework and
DarkRP has loaded their wallet, they are in play. Until then they are held
out of DarkRP's play: they stay dead on the login screen, cannot change
team, use DarkRP's commands (chat or the F4 menu), vote or drop from their
pocket, are paid no salary, cannot be heard, and other players cannot
demote, want, warrant or put a hit on them. When DarkRP cannot load a
player's data (its database is down), it plays on without saving for them,
so the framework keeps them held and says so in the console. A map change ends the session on both
sides: everyone logs in again (silently, with their remember token) and
DarkRP loads their data again.

What the hold does not cover, because nothing public in DarkRP or Garry's
Mod would let it:

- **DarkRP's tip jar.** Its donation asks no hook, so a modified client of
  a player who has not logged in yet, standing where they joined within
  100 units of someone's tip jar, can donate from their DarkRP wallet. Keep
  tip jars away from where players spawn.
- **DarkRP's hookless commands that move nothing:** answering a question
  put to the player, signing a letter, a gesture, the job model they prefer.
- **Admin commands.** A player in an admin usergroup can use FAdmin, ULX,
  SAM or another admin mod before logging in to the framework, as on any
  server. The framework's own staff permissions still need the login.
- **Other addons' own commands and menus.** Those that act through
  DarkRP's commands or Garry's Mod's sandbox actions are held; those that
  act on a player some other way are each addon's to gate.
- **Another addon's hook answering first.** Garry's Mod runs hooks in no
  fixed order, so an addon that answers `PlayerSpawn`, `PlayerDeathThink`
  or one of DarkRP's refusal hooks before the bridge decides that one. A
  player spawned that way is taken out again within a second.

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

**FXServer saying it could not find the dependency `ox_lib` for `rpf`**
(its own line): ox_lib is not installed. Install it as
[By hand](#by-hand) says, step 3, and `ensure ox_lib` before `ensure rpf`.

**FXServer saying it could not start the dependency `rpf` for an addon's
resource** (its own line, such as `Could not start dependency rpf for
resource acme_notes`): `rpf` itself did not start, and the reason is the
line just above, one of these. Fix that and restart the server; the addon
starts with `rpf`.

**`rpf: ox_lib is stopped, and RPF's FiveM adapter is built on it; …`** (or
another state): ox_lib is there but not running, or failed to start; its
own error is earlier in the console. A folder from GitHub's "Source code"
archive fails this way (`Unable to load UI`): use the release's
`ox_lib.zip`.

**`rpf: ox_lib is started, but its loader (@ox_lib/init.lua) gave RPF no `lib`; …`**:
ox_lib runs, but loading it into RPF failed; its own error is above. This
is usually a folder from GitHub's "Source code" archive, or a damaged
copy: replace the folder with a release's `ox_lib.zip` and restart the
server.

**`rpf: ox_lib is version 3.30.0, and RPF needs 3.40.0 or newer; …`**: the
server's ox_lib is too old. Replace its folder with a current release's,
then restart the server. RPF is built and checked against 3.40.0, which
also fixes a hole in ox_lib's callbacks that let one player answer what
the server asked another.

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

### Beside Qbox

These are the bridge's lines (`[rpf-qbox] error:`) and the framework's own
lines about it (`[rpf] error:`).

**`[rpf-qbox] error: qbx_core loaded a character for player … before they logged in to RPF, so it was logged out`**:
something other than the bridge logged a character in. Either
`useExternalCharacters` is still `false`, so qbx_core's own selection is
showing, or another character resource is running, or a player's client
called qbx_core's character callbacks itself. Set the config and remove
the other resource. If the line keeps naming the same player, that client
is doing it on purpose.

**``rpf.bridge: the qbox bridge's framework is running, and this server's `domains` setting is native, …``**:
`rpf-qbox` is running on a server whose profile is native, so the framework
and Qbox each keep an economy. Set the profile to **Companion** and restart,
or stop ensuring `rpf-qbox` and remove Qbox.

**`rpf.bridge: the qbox bridge was tested against 1.24, and its framework is …`**
(a warning):
the bridge runs, but this qbx_core version was not tested with it.

**`rpf.domains: this server runs the companion profile, whose characters, money, inventory, jobs are its framework's, and no bridge to that framework is registered, so players stay at registered until a bridge that provides exactly those is`**:
players log in and go no further, because `rpf-qbox` is not running.
Ensure it after `rpf`, and run `ensure rpf-qbox` again after a
`restart rpf`. Its own line says why if it was refused.

**`[rpf-qbox] error: RPF refused the bridge: …`**: the bridge is not one
this release of the framework takes, usually a bridge from another
release. Install the `[rpf]` folder of one release whole.

### Beside DarkRP

These are the bridge's lines (`[error] rpf_darkrp:`) and the framework's own
lines about it.

**`rpf_darkrp: DarkRP could not load …'s data, so they stay out of play`**:
DarkRP's database query for that player failed, so DarkRP itself saves
nothing for them this session. They stay dead on the login screen. Fix
DarkRP's database connection (MySQL's settings in `darkrpmodification`),
and have them rejoin.

**`rpf_darkrp: DarkRP is not the gamemode, …`**: `rpf_darkrp` is installed
on a server running another gamemode. Remove the folder, or run DarkRP.
Players are still held until the framework has them in play.

**``rpf.bridge: the darkrp bridge's framework is running, and this server's `domains` setting is native, …``**:
the server's profile is native while DarkRP runs, so the framework and
DarkRP each keep an economy. Set the profile to **Companion** and restart,
or remove `rpf_darkrp` and DarkRP.

**`rpf.bridge: the darkrp bridge was tested against 2.7, and its framework is …`**
(a warning): the bridge runs, but this DarkRP version was not tested with it.

**`rpf_darkrp: RPF is not running …`**: the `rpf` addon is missing or
refused to start; its own line above says why. Nothing is held then.

**`rpf_darkrp: RPF refused the bridge: …`**: the bridge is not one this
release of the framework takes, usually a bridge from another release.
Install both folders of one release.

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

**`rpf: the rpf-ws resource could not send a frame on socket …`** (FiveM) or
**`rpf: GWSockets could not send a frame: …`** (Garry's Mod): the engine's
websocket call failed, and the words after the colon are why. It is logged
once per connection. The core treats the connection as dead and reconnects
with a growing delay, so a `disconnected` line follows. On FiveM it usually
means `rpf-ws` was stopped or restarted while `rpf` kept running: `ensure
rpf-ws`, then `restart rpf`. A `could not close …` line is the same for the
call that closes a socket, and on Garry's Mod `rpf: GWSockets could not open
the websocket: …` is the same for the call that starts one; the core then
retries after the normal backoff.

**`rpf: stopped: the portal refused Hello (duplicate_instance): another live instance is connected`**:
another game server process is connected with this server's key, and the
portal checked that it is still answering. Two game servers share one
server in the portal: give each its own server and key. The framework stops
for good on this. Restart it once the other is gone.

**`rpf: the portal is restarting; reconnecting … ms after it closes`**: a
portal deploy. Nothing to do.

### What the panel's health section says

The server's page in the panel shows the last week first: whether the game
server is connected, every time it dropped and why, how many players were
on, and the problems the portal met on its connection. Each problem is one
of these.

**Disconnected: `closed by the game server`**: the framework or the host
closed the socket: a restart, a map change, a stopped resource. One at a
time is normal. Many in a row with no restart on your side means the
host's websocket is failing; read the `disconnected (…)` lines on the
server (above).

**Disconnected: `replaced by a newer connection from the same game server`**:
the framework reconnected and the portal dropped the old socket for the
new one. Normal after a `disconnected (…); reconnecting` line.

**Disconnected: `its API key was revoked`** or **`closed by the portal: the
community was suspended or the server deleted`**: the portal ended it on
purpose. Issue a new key, or contact support about the suspension.

**Disconnected: `nothing heard for … seconds`**: the server stopped
answering the portal's pings: it hung, or its connection died without
closing. The framework reconnects when it can.

**Disconnected: `… malformed frames in a row`** or **`the game server kept
sending past its frame rate`**: the framework sent what the portal could
not read, or sent too fast. A released core does neither; a modified one,
or another resource writing to the socket, does. Reinstall the release.

**Problem: `Frame refused (malformed)`, `(expired)`, `(not_found)`, …**: the
portal refused a frame and said why in the detail. `expired` means the
host's clock is far off, or a frame was retried days later; `not_found`
and `forbidden` mean the server asked about a record or a player that is
not its own. `retry` is the portal's own fault, and the framework resends.

**Problem: `Frame refused (rate_limited)`**: the server sends faster than
its plan's frame rate. A burst after a reconnect is expected; a steady
stream means an addon is sending in a loop, or the plan is too small for
the server. The plan card on the same page shows the rate.

**Problem: `Command timed out`**: staff sent a command from the panel (a
kick, a balance change) and the game server did not answer in time. The
panel says the outcome is unknown; check in game before retrying. A
server that times out often is overloaded or its websocket is stalling.

**Problem: `Config not applied`**: the framework refused the config the
portal sent, for the reason in the detail (a snapshot over its size limit
is the common one). The server keeps the config it had; fix what the
reason names in the panel.

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
