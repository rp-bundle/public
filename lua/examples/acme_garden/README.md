# acme_garden

An example RPF addon with a timed live type: players sow plants that grow
while the server runs, need watering, and are harvested once grown or wither
if left dry. It is J6's sample (#83), and shows what a type whose state
changes during play needs from RPF, without any Rust, portal page or
migration of its own. It is a conformance fixture
(`lua/spec/conformance_acme_garden_spec.lua`,
`crates/fake-server/tests/scenarios/acme_garden.rs`). [Writing
addons](../../../docs/writing-addons.md) is the guide, and
[Addons, "Live records: the lifecycle"](../../../docs/architecture/addons.md#live-records-the-lifecycle-j6)
the contract.

| File | What |
|---|---|
| `manifest.lua` | The manifest: one live type, `acme_garden.plant`, held by the server (`hold = "server"`) and placed in the world as an object (`world`), at schema 2; and the `tend` permission |
| `server.lua` | Registers the addon; on start, `acme_garden.sow`, and `water`, `harvest` and `uproot` aimed at a plant; and a tick every minute that grows each plant by the time it kept in its own fields |
| `client.lua` | Asks the server to sow, and tells the player how it went |
| `fivem/` | The FiveM resource's manifest and entry points |
| `gmod/autorun.lua` | The Gmod entry point |

## What it shows

- **Placement.** A plant is sown where the player stands, in their routing
  bucket, and the core places it as an object while the server holds it.
  It is removed when the plant is harvested or pulled up.
- **Interactions.** Watering, harvesting and pulling up are aimed at a
  plant: the core's interaction menu (`rpf_interact`) or a target resource
  offers them when the player stands at one. The server checks the plant is
  within reach before the handler runs, and the handler checks the
  gardener.
- **State transitions on its own clock.** A tick counts the time since the
  plant's `ticked_at` with `rpf.time.elapsed`: one stage of growth per whole
  tick while it has water, `seed` → `sprout` → `grown`, or `withered` once
  dry. This is active time: a plant grows only while a server holds it.
- **Collection and destruction.** `harvest` takes the gardener's grown
  plant out of the ground, and `uproot` pulls one up whatever its stage.
  A harvest that paid out an item would go through an exchange
  (`rpf.api.commerce`), which gives the item and makes the deletion as one
  journaled intent, once per op id; `acme_shop` shows one.
- **Restart recovery.** The core claims every plant back after a restart.
  The first tick then counts at most `MAX_CATCH_UP_MS` (five minutes) of
  growth, however long the server was down.
- **Schema upgrade.** Release 1.0.0 had no `water`. 1.1.0 adds it with a
  default, which is a compatible change, so staff install it over 1.0.0 and
  every plant keeps its record, reading as full until its next tick writes
  it at schema 2.

## On FiveM

Make a resource folder `acme_garden` holding `manifest.lua`, `server.lua`,
`client.lua`, and `fivem/`'s files (`fxmanifest.lua` at the top, the two
entry points in `fivem/`). `ensure acme_garden` after `ensure rpf`. In game,
`/sow`, and the interaction key at a plant.

## On Garry's Mod

Make an addon folder `acme_garden` holding `lua/acme_garden/manifest.lua`,
`lua/acme_garden/server.lua`, `lua/acme_garden/client.lua`, and
`gmod/autorun.lua` as `lua/autorun/acme_garden.lua`. In the console, `sow`,
and `rpf_interact` at a plant.

## Then

The server proposes the addon to the portal. On the server's **Addons**
page, install it (or turn on `addons.auto_install` on a development
server); it starts at once. Plants show on the server's data pages for
`acme_garden.plant`, where staff holding `addon.acme_garden.tend` change
their water or remove them.
