# rp-framework

The Lua side of rp-framework (RPF): a roleplay framework for FiveM and
Garry's Mod whose game servers are configured from a hosted web portal.
Everything a game server runs is here, under the MIT License
([`lua/LICENSE`](lua/LICENSE)): the core, the FiveM and Garry's Mod
adapters, the bridges to Qbox and DarkRP, the FiveM websocket shim, the
login and character screens, and the example addons. The portal is a hosted
service and is not in this repository.

## Installing

Download a release from this repository's
[Releases](https://github.com/rp-bundle/public/releases): the FiveM resources,
the Garry's Mod addon, a txAdmin recipe and the addon kit, with their
SHA-256 checksums. [Installing](docs/installing.md) takes a server from a
stock install to one connected to the portal.

Each release's documentation, kept as it was for that release, is at
<https://rp-bundle.github.io/public/>: installing, upgrading, compatibility,
writing addons and the Lua API reference.

## Writing addons

An addon is Lua against `rpf.api`, the same on both engines.
[Writing addons](docs/writing-addons.md) is the guide, and the API's
annotations are in [`lua/core/meta/`](lua/core/meta/), which your editor
reads for completion.

## Layout

| Path | What it is |
|---|---|
| `lua/core/` | The engine-independent core ([its README](lua/core/README.md)) |
| `lua/platform/` | The FiveM and Garry's Mod adapters, and the mock the tests drive ([its README](lua/platform/README.md)) |
| `lua/bridges/` | Running beside Qbox or DarkRP |
| `lua/examples/` | Example addons |
| `lua/spec/` | The `busted` suite |
| `protocol/corpus/` | The portal↔game-server wire's conformance corpus, which the specs read |

## This repository is a mirror

The framework is developed alongside the portal in a private repository,
because a change to what the portal sends and the Lua that handles it land
together. Every change reaches this repository from there, one way, with
its history: `main` here is never pushed to by hand. See
[Contributing](CONTRIBUTING.md) for how a pull request here is taken.

Security issues: please read [SECURITY.md](SECURITY.md) and report
privately.
