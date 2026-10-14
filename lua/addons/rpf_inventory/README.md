# rpf_inventory

A starter addon (S1, #183): the player's own items and money on their
screen, and a small HUD. It is first-party and supported, and built only on `rpf.api`, like
any addon a community writes. It is a conformance fixture as well
(`lua/spec/conformance_rpf_inventory_spec.lua`, `lua/spec/rpf_inventory_spec.lua`,
`crates/fake-server/tests/scenarios/rpf_inventory.rs`).

| File | What |
|---|---|
| `manifest.lua` | The manifest: one `config` type, `rpf_inventory.settings`, with at most one record. Staff create it on its data page when they want other than the defaults |
| `server.lua` | Registers the addon, and on start its interactions: `open` (the containers without their stacks, the money, the players near enough to be given something, and what the settings allow), `page` (one container's stacks, 24 at a time, to keep each answer under 16 KiB whatever the item names), the commands `move`, `use`, `drop`, `give` and `cash`, and `hud`; and the export `rpf_inventory.hud`, through which other addons put values on a player's HUD |
| `client.lua` | What a screen asks the server, in order: the view and its pages one after another (waiting its turn when told too many requests), each command under a request number of its own (sent once more on a timeout), each item's image (`rpf.items.image`), and the HUD every five seconds |
| `fivem/` | The FiveM resource's manifest, its entry points, and `html/`, the NUI page the inventory (`I`, or `/rpf_inventory`) and the HUD are drawn in |
| `gmod/autorun.lua`, `gmod/derma.lua`, `gmod/hud.lua` | The Gmod entry point, the Derma frame (the `rpf_inventory` console command; `bind i rpf_inventory`), and the HUD (`HUDPaint`) |

## What a player does

A player opens the inventory and sees each of their character's containers
with its weight, each stack as a tile with its item's image, name and count,
and their money in every account. Clicking a stack offers:

- **Use**, where an addon said what using the item does (`rpf.inventory.on_use`).
- **Move to** another of their containers, some or all of the stack.
- **Give** some of it to a player standing near them.
- **Throw away** some of it. The units are gone, not left on the ground: no
  container lies there for another player to pick up.

They can also **hand cash over** to a player near them, from the account
staff chose.

## The HUD

A box in a corner of the screen, there all the time: the player's money in
the accounts staff picked, their job, employer and rank, and what other
addons report. The client asks for it every five seconds, and at once after
the player's own commands. An interaction is the only way an addon's client
hears from its server, and a poll every five seconds is a tenth of what a
player may send.

Another addon puts a value on a player's HUD, without requiring this one:

```lua
-- server: rpf_needs, say
rpf.addons.call("rpf_inventory.hud", player.handle, "rpf_needs.hunger", { label = "Hunger", value = 40, max = 100 })
rpf.addons.call("rpf_inventory.hud", player.handle, "rpf_needs.hunger", nil) -- take it off
```

`max` makes it a bar. A key is the caller's own, `[a-z][a-z0-9_.]`, at most
32 bytes; a player has at most eight. Values are kept until the player
leaves. Without `rpf_inventory` running, the call answers `false,
"not_found"`, and nothing else happens.

## How it stays honest

- Every command is a call into `rpf.inventory` or `rpf.money`, with an op id
  the server mints. The client numbers each request, and the server keeps
  the op id it minted for that number, so a request sent again after a
  timeout gets the answer it had and never happens twice: the server
  answers it from the op journal before anything else, so cash handed to a
  player who has walked off since is still told as handed. That memory lasts
  while the addon's code runs, across the addon's stops and starts; the
  view names it (`session`), and a command from a view the server no longer
  remembers (after a resource restart) is refused, and the screen looks
  again, rather than given a new op id.
- The client names a stack the way the server named it (`{ container,
  index, item, key }`), and the API resolves it among the player's own
  containers. Another player's container is refused exactly as one that
  does not exist, and a stack that moved since the screen was drawn is
  refused, never mistaken for another.
- The client names another player by the id the server listed them under,
  and the server finds them again among those near enough now: in the same
  routing bucket, within the reach staff set. A player across the map is
  refused, whatever the client sends.
- A stack's data (a note in a bottle, a weapon's serial) stays on the
  server. The screen only marks the stack as one of a kind.
- Every answer fits the 16 KiB an interaction may carry, whatever staff
  named things: the view lists at most ten containers, the eight nearest
  players and eight accounts, with names cut to 64 bytes, and a
  container's stacks come 24 to a page.

## Settings

On the server's data page for **Inventory settings**, staff create one record
when they want other than the defaults:

| Setting | Default | What it does |
|---|---|---|
| Players may give items | on | Giving to a player nearby |
| Players may throw items away | on | Throwing items away |
| Players may hand cash over | on | Handing cash to a player nearby |
| Cash account | `wallet` | The account handed cash comes out of and goes into |
| How near | 3 metres | How near another player must be to be given anything |
| Beside a framework | `stand_aside` | See below |
| Show the HUD | on | Whether the HUD shows |
| Corner | `bottom_right` | Which corner of the screen it is in |
| Accounts shown | none (every account) | The accounts the HUD lists, by name |
| Show the job and rank | on | The HUD's job line |
| Show what other addons report | on | Values other addons put on the HUD |

## Beside a framework

Where a framework owns the items (Qbox, with ox_inventory), RPF has no
containers to show, and `rpf.inventory.supports("containers")` is false. The
framework has its own HUD too. The addon then stands aside, says so once in
the server console, shows no HUD, and answers a player who opens the
inventory that the server's own is in charge. With **Beside a framework**
set to `run`, it shows the money and the HUD through the bridge, and no
items.

DarkRP's companion mode is not covered yet: it waits on #84.

## Installing it

The sample-server pack (#182) will ship it ready to install. Until then,
from this directory, by hand:

- **FiveM:** make a resource folder `rpf_inventory` holding `manifest.lua`,
  `server.lua`, `client.lua` and `fivem/`'s files (`fxmanifest.lua` at the
  top, the entry points and `html/` in `fivem/`). `ensure rpf_inventory`
  after `ensure rpf`.
- **Garry's Mod:** make an addon folder `rpf_inventory` holding
  `lua/rpf_inventory/manifest.lua`, `server.lua`, `client.lua`,
  `gmod/derma.lua` and `gmod/hud.lua`, and `gmod/autorun.lua` as
  `lua/autorun/rpf_inventory.lua`.

The server proposes the addon to the portal. Install it on the server's
**Addons** page.

## What a test without a game client cannot show

The NUI page with its mouse focus and the `I` key mapping on FiveM, the
Derma frame on Gmod, item images drawn in both, and the HUD's placement in
each corner at the common resolutions. These are on #146's
list of real-engine checks.
