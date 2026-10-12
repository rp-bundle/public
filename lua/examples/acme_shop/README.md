# acme_shop

An example RPF addon: counters that sell items for in-game money and buy
them back. It is the commerce example (J5), built only on `rpf.api`, and a
conformance fixture (`lua/spec/conformance_acme_shop_spec.lua`,
`crates/fake-server/tests/scenarios/acme_shop.rs`). [Writing
addons](../../../docs/writing-addons.md#selling-buying-back-trading-exchanges)
is the guide.

| File | What |
|---|---|
| `manifest.lua` | The manifest: `acme_shop.counter` (a shopkeeper staff place, on a `map` they name or on every map; 1.1.0 added it), `acme_shop.listing` (what a counter sells, at what price, and whether it buys it back), `acme_shop.stock` (how many a stocked listing has left), and the `restock` permission |
| `server.lua` | Registers the addon; on start, the `acme_shop.shop` interaction aimed at a counter, which opens the counter's menu and a quantity dialog from the server (`rpf.ui`). Its stock type is `hold = "server"`, so the core holds the stock, takes back what a restart gave up, and takes stock staff add within a minute |
| `fivem/` | The FiveM resource's manifest and entry point |
| `gmod/autorun.lua` | The Gmod entry point |

A sale is one exchange (`rpf.commerce.exchange`): the player's money, the
items and the stock move together, or not at all. Everything is checked
again when the player confirms, against the config as it is then: a price
staff changed since the menu opened is refused, not charged, and a listing
whose item left the catalog is refused and said in the console. The
player's client never names a listing, a price or an op id: those are the
menu's option values, which stay on the server.

There is no client script. The core offers the counter: its interaction
menu (`rpf_interact`, E by default on FiveM, a console command on Gmod),
and on FiveM ox_target or qb-target when one is running.

Every release's addon kit (`rpf-addon-kit-<version>.zip`, on the release
page) has it laid out already: `fivem/[rpf-examples]/acme_shop` is the FiveM
resource and `gmod/acme_shop` the Garry's Mod addon. Nothing installs it for
you. From this directory, by hand:

## On FiveM

Make a resource folder `acme_shop` holding `manifest.lua`, `server.lua`,
and `fivem/`'s files (`fxmanifest.lua` at the top, the entry point in
`fivem/`). `ensure acme_shop` after `ensure rpf`.

## On Garry's Mod

Make an addon folder `acme_shop` holding `lua/acme_shop/manifest.lua`,
`lua/acme_shop/server.lua`, and `gmod/autorun.lua` as
`lua/autorun/server/acme_shop.lua`.

## Then

The server proposes the addon to the portal. On the server's **Addons**
page, install it. Then, on the data pages:

1. Set the server's `economy.addon_account` setting to the paying account
   sales are paid into (a till, with `unlimited_balance` so buy-backs can
   pay out).
2. Create a **Counter**: a name, where it stands, a model for each engine
   (`{ "fivem": "mp_m_shopkeep_01", "gmod": "models/Humans/Group01/male_02.mdl" }`),
   and which of the player's accounts pays (`wallet` unless set).
3. Create a **Listing** for each item it sells: the counter, the item, the
   price, what it buys one back at (0 for none), and whether stock is
   limited.
4. For a limited listing, create its **Stock** (staff holding
   `addon.acme_shop.restock`), and edit it to restock. The server takes new
   stock within a minute.

Staff see every sale on the till's and the player's account pages (the
ledger entry, described as `<counter>: sold 2 water`), the player's
containers, and the stock's data page.
