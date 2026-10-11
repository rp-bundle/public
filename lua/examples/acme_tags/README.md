# acme_tags

An example RPF addon: players spray tags on walls, which fade after a day.
It is the worked example of [Addons](../../../docs/architecture/addons.md#a-worked-example),
runnable, and a conformance fixture (`lua/spec/conformance_acme_tags_spec.lua`,
`crates/fake-server/tests/scenarios/acme_tags.rs`). [Writing
addons](../../../docs/writing-addons.md) is the guide.

| File | What |
|---|---|
| `manifest.lua` | The manifest: one live type, `acme_tags.tag`, and the `moderate` permission |
| `server.lua` | Registers the addon; on start, its interactions (`acme_tags.spray`; `acme_tags.mine`, which answers with the player's own tags; `acme_tags.scrub`, which resolves a client's tag id inside the player's scope), and a fade every minute. Its type is `hold = "server"`, so the core holds the tags the portal already has, and takes them back after a restart |
| `client.lua` | Asks the server to spray, shows the player's own tags in a menu (`rpf.ui.menu`) and scrubs the one picked through `rpf.interactions.request`, and tells the player how it went with `rpf.ui.notify` |
| `fivem/` | The FiveM resource's manifest and entry points |
| `gmod/autorun.lua` | The Gmod entry point |

## On FiveM

Make a resource folder `acme_tags` holding `manifest.lua`, `server.lua`,
`client.lua`, and `fivem/`'s files (`fxmanifest.lua` at the top, the two
entry points in `fivem/`). `ensure acme_tags` after `ensure rpf`. In game,
`/spray hello`, and `/tags` to pick one of yours to scrub.

## On Garry's Mod

Make an addon folder `acme_tags` holding `lua/acme_tags/manifest.lua`,
`lua/acme_tags/server.lua`, `lua/acme_tags/client.lua`, and
`gmod/autorun.lua` as `lua/autorun/acme_tags.lua`. In the console, `spray
hello`, and `tags`.

## Then

The server proposes the addon to the portal. On the server's **Addons**
page, install it (or turn on `addons.auto_install` on a development
server); it starts at once. Sprayed tags show on the server's data pages
for `acme_tags.tag`, where staff holding `addon.acme_tags.moderate` delete
them.
