# acme_tags

An example RPF addon: players spray tags on walls, which fade after a day.
It is the worked example of [Addons](../../../docs/architecture/addons.md#a-worked-example),
runnable, and a conformance fixture (`lua/spec/conformance_acme_tags_spec.lua`,
`crates/fake-server/tests/scenarios/acme_tags.rs`). [Writing
addons](../../../docs/writing-addons.md) is the guide.

| File | What |
|---|---|
| `manifest.lua` | The manifest: one live type, `acme_tags.tag`, and the `moderate` permission |
| `server.lua` | Registers the addon; on start, the `acme_tags.spray` interaction, a fade every minute, and holding the tags the portal already has |
| `client.lua` | Asks the server to spray, and tells the player how it went |
| `fivem/` | The FiveM resource's manifest and entry points |
| `gmod/autorun.lua` | The Gmod entry point |

## On FiveM

Make a resource folder `acme_tags` holding `manifest.lua`, `server.lua`,
`client.lua`, and `fivem/`'s files (`fxmanifest.lua` at the top, the two
entry points in `fivem/`). `ensure acme_tags` after `ensure rpf`. In game,
`/spray hello`.

## On Garry's Mod

Make an addon folder `acme_tags` holding `lua/acme_tags/manifest.lua`,
`lua/acme_tags/server.lua`, `lua/acme_tags/client.lua`, and
`gmod/autorun.lua` as `lua/autorun/acme_tags.lua`. In the console, `spray
hello`.

## Then

The server proposes the addon to the portal. On the server's **Addons**
page, install it (or turn on `addons.auto_install` on a development
server); it starts at once. Sprayed tags show on the server's data pages
for `acme_tags.tag`, where staff holding `addon.acme_tags.moderate` delete
them.
