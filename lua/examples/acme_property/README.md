# acme_property

Properties players buy, and doors their owners lock: a gameplay concept RPF
has never heard of, built only on `rpf.api` and the generic type system.
It has no Rust, migration, portal route or page, or protocol change of its
own ([Addons](../../../docs/architecture/addons.md)). It is a conformance
fixture too (`lua/spec/conformance_acme_property_spec.lua`,
`crates/fake-server/tests/scenarios/acme_property.rs`).

| File | What |
|---|---|
| `manifest.lua` | The manifest: `acme_property.property`, a live zone the server holds, and `acme_property.door`, a config point that refers to its property; the `manage` permission |
| `server.lua` | Registers the addon; on start, its interactions, `acme_property.buy` (aimed at the lot) and `acme_property.door` (aimed at a door), and the export `acme_property.locked` |
| `fivem/` | The FiveM resource's manifest and entry point |
| `gmod/autorun.lua` | The Gmod entry point, on the server alone |

## How it is built

- **A property is `live`, owned by the server.** Staff create it on the
  server's data page for **Property**, with its name, its lot (the middle,
  a radius and a routing bucket), its price, the buyer's account it is paid
  from, and whether it is for sale. Who owns it and whether its doors are
  locked are game state, so the server holds every property while it runs
  (`hold = "server"`), whether or not its owner is on. Staff edits of a held
  property go to the server as commands.
- **Ownership is a field, `holder`.** It is a reference to a player, not the
  record's owner: a record's owner never changes, and a property outlives
  whoever bought it. A purchase writes it, and staff holding
  `addon.acme_property.manage` change or clear it on the property's page.
  Ownership is per player account, not per character, so it works on a
  server where another framework keeps characters.
- **A door is `config`.** Staff place it as a point (nothing is spawned)
  that names its property. A property with doors cannot be deleted until
  they are.
- **Buying is one exchange.** A player standing on a lot for sale uses
  "Buy this property" from the interaction menu. The server opens a menu
  with the price, and the option's value (the property, its revision and
  price) never leaves the server. On confirming, one op id is minted, and
  `rpf.commerce.exchange` pays the price and, as its `apply`, writes the
  buyer onto the property it holds, at the revision the player was shown.
  So the money and the ownership move together or not at all. The same op
  id sent again answers as before, and the order is resent under it while
  the bank cannot be asked.
- **Doors.** The owner uses a door to lock or unlock every door of the
  property. Anyone else is told whether it is locked. RPF has no door of
  its own to move, so a server's door script (ox_doorlock on FiveM, a map
  door on Gmod) asks `rpf.addons.call("acme_property.locked", door_id)`.

Disabling the addon in the portal releases every property with its final
state. Staff see them read only, and nothing is offered in game. Enabling it
again hands them back to the server exactly as they were.

## Installing it

Every release's addon kit (`rpf-addon-kit-<version>.zip`) has it laid out:
`fivem/[rpf-examples]/acme_property` is the FiveM resource, and
`gmod/acme_property` the Garry's Mod addon. Nothing installs it for you.

- **FiveM:** a resource folder `acme_property` holding `manifest.lua`,
  `server.lua`, and `fivem/`'s files (`fxmanifest.lua` at the top, the entry
  point in `fivem/`). `ensure acme_property` after `ensure rpf`.
- **Garry's Mod:** an addon folder `acme_property` holding
  `lua/acme_property/manifest.lua`, `lua/acme_property/server.lua`, and
  `gmod/autorun.lua` as `lua/autorun/server/acme_property.lua`.

The server proposes the addon to the portal. Install it on the server's
**Addons** page. Then, as staff holding `addon.acme_property.manage`:

1. On the data page for **Property**, create one owned by the server, with
   its lot, its price and **For sale** on. The server takes it within a
   minute.
2. On the data page for **Door**, create a door naming that property, where
   the door is.

A sale needs the server's `economy.addon_account` setting to name the
account sales are paid into, as every addon's payment does.

In game, stand on the lot and use the interaction key (`rpf_interact` on
Gmod) to buy it, then use it again at the door.

## What only a real engine shows

The interaction menu on the lot and at the door, the offer's menu and its
notifications, and the radius and door distance in Gmod's units. Wiring
`acme_property.locked` to a real door is the server's own script.
