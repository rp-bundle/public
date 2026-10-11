# acme_notes

The walkthrough's addon: players pin notes where they stand, anyone nearby
reads them, and their author or staff take them down. [Writing
addons](../../../docs/writing-addons.md#walkthrough-a-new-type-end-to-end)
builds it step by step, from an empty folder to an interaction staff can
moderate in the portal, and these are the finished files. It is a
conformance fixture too (`lua/spec/conformance_acme_notes_spec.lua`,
`crates/fake-server/tests/scenarios/acme_notes.rs`).

| File | What |
|---|---|
| `manifest.lua` | The manifest: one live type, `acme_notes.note`, placed in the world as an object with a model per engine, and the `moderate` permission. Schema 2: 1.1.0 added `colour` with a default |
| `server.lua` | Registers the addon; on start, its interactions: `acme_notes.pin` (no target: the note goes where the player stands), `acme_notes.read` and `acme_notes.take_down` (aimed at a note, within reach in the engine's units), and `acme_notes.remove`, for linked staff holding `addon.acme_notes.moderate`. A take-down names the revision it read, and on `stale` reads the note again and checks again |
| `client.lua` | Asks the server to pin a note, from the command line or an `rpf.ui.input` dialog, and tells the player how it went |
| `fivem/` | The FiveM resource's manifest and entry points |
| `gmod/autorun.lua` | The Gmod entry point |

Every release's addon kit (`rpf-addon-kit-<version>.zip`, on the release
page) has it laid out already: `fivem/[rpf-examples]/acme_notes` is the
FiveM resource and `gmod/acme_notes` the Garry's Mod addon. Nothing installs
it for you. From this directory, by hand:

## On FiveM

Make a resource folder `acme_notes` holding `manifest.lua`, `server.lua`,
`client.lua`, and `fivem/`'s files (`fxmanifest.lua` at the top, the two
entry points in `fivem/`). `ensure acme_notes` after `ensure rpf`. In game,
`/note meet here` (or `/note` for a dialog), and the interaction key at a
note.

## On Garry's Mod

Make an addon folder `acme_notes` holding `lua/acme_notes/manifest.lua`,
`lua/acme_notes/server.lua`, `lua/acme_notes/client.lua`, and
`gmod/autorun.lua` as `lua/autorun/acme_notes.lua`. In the console, `note
meet here`, and `rpf_interact` at a note.

## Then

The server proposes the addon to the portal. On the server's **Addons**
page, install it (or turn on `addons.auto_install` on a development
server); it starts at once. Notes show on the server's data pages for
`acme_notes.note`, where staff holding `addon.acme_notes.moderate` edit and
delete them.
