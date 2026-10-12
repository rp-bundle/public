# Changelog

Every release of rp-framework: the hosted portal and the Lua core, which ship
together under one version tag. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Whether a game
server keeps working across a portal upgrade is decided by the **protocol
version**, not by this number; each release names the protocol versions it
speaks, and [Compatibility](docs/compatibility.md) says how long each is
served.

A change that a game server or a deployment must act on goes under its
release here: a protocol version deprecated or dropped, a migration that is a
one-way door, a new environment variable.

## [Unreleased]

**Protocol:** speaks protocol 2, and serves protocol 2 only. Protocol 2
adds the `restarting` notice (below), a character's job (D7), in-game
staff (F9: `link_player`, `staff_action`, `player_linked` and
`staff_permissions`), the `suspended` reject code (H5) and in-game config
editing (E6: `config_changed`, `config_change_applied` and
`config_change_discarded`), the `domain_external` reject code (K1), the
`referenced` reject code (a held addon record's deletion that another
record refers to), an
item's `image` hash in the config snapshot (P3), and the profile (K1) in
`hello` (optional: a core that leaves it out runs native) and `welcome`,
the `report_unknown_ops` notice (#274), the map the game server runs
in `hello` (#369; `default` when left out), and the config snapshot's
`dialogs` (#371; empty when left out), and an item's `weapon` (L3, #373;
left out for an item that is not one). A
message newer than a connection's protocol is refused `malformed` at the
socket.

### Added

- An item can be a weapon (L3, #373): on the items page, staff name the
  engine weapon it gives on FiveM (a GTA weapon such as `WEAPON_PISTOL`)
  and on Gmod (a SWEP class such as `weapon_pistol`), picking from each
  engine's stock weapons or typing one their server added, and the item it
  fires as ammo. The config snapshot carries it as `weapon` on the item,
  and `rpf.config.item(slug).weapon` reads it. Equipping comes next.
- The generic record pages lay themselves out from the manifest (N1,
  #376). A field may set `group` (a heading), `order`, and, on an integer
  or number, `unit` (`money`, `seconds`, `minutes`, `hours`, `metres`,
  `degrees`, `percent`) and `slider`; each kind gets the control that fits
  it: a switch, a slider, a duration typed in the unit staff choose, money
  with the server's currency, a picker of the server's items with their
  images, a picker of its jobs by employer and rank, a position in one row.
  The list page searches the start of any indexed string column. A new
  server setting, **`economy.currency`** (`config.settings.edit`, `$` by
  default), is what the panel puts before an amount; game servers read it
  like any setting. `acme_shop` and `acme_property` 1.2.0 use the keys.
- The dialog editor (#371): the server's **Dialogs** page lists its trees
  and builds them, node by node, with no script needed: lines, choices,
  where each goes, conditions, and the action a choice runs with its
  parameters, picked from the installed addons' declarations. A choice
  whose action cannot run is marked broken with why. A new flag,
  **`config.dialogs.edit`**, gates the editing; every staff member of the
  server sees the trees. An NPC type's record form picks its tree from a
  list.
- NPCs talk (#371): a world type names a `dialog` field (a `ref` to
  `dialog`) in its `world`, and the core offers Talk on its records and
  runs the tree they name on the server, a menu per node, every pick
  checked again against the tree as it is now, its conditions and the
  player's reach. A choice whose action is unavailable is shown and
  refused with a message. `rpf.api.dialogs.open(player, slug)` opens a
  tree from an addon's code. Interaction names under `rpf_` are the
  core's (`reserved`).
- Dialog trees (#371): what a server's NPCs say and the choices they
  offer, stored per server (`dialogs`), checked against the actions the
  server's installed addons declare, and pushed whole in the config
  snapshot's new `dialogs` section, which the core reads as
  `rpf.config.dialog(slug)`. Writes are audited `dialog.create`,
  `dialog.edit` and `dialog.delete`.
- A server's page in the panel shows its health first (#390): whether the
  game server is connected and how many players are on, whether it should
  upgrade, whether it runs the current config, the week's problems in
  plain words (refused frames, commands that timed out, configs not
  applied, refused addons, unknown operations) each linked to the
  installing guide, every connection and disconnect of the week with its
  reason, the most players online each day, and, for staff who manage the
  server, what the community uses of its plan. The history is kept a week
  (`RPF_WS_PLAYER_SAMPLE_SECS` sets how often players are counted, five
  minutes by default).
- `rpf.api.ui.menu` takes `text`, up to 1 KiB read above the options and
  never picked (#371): an NPC's line in a dialog. A read-only first entry
  of ox_lib's context menu on FiveM, a wrapped label on Gmod.
- Addons declare **actions** (#371): what a dialog choice staff build in
  the panel can make an addon do. A manifest's new top-level `actions`
  names each with a title, help and parameters (field definitions, minus
  `index`, `unique`, `hidden`, `read_only`, `engine` and owner
  references), checked by the same rules on both sides and held to the
  shared corpus. The addon registers each handler with
  `rpf.api.actions.register(name, handler)`, and the core runs it only
  while the addon is active, with parameters checked against the
  declaration. The install view lists the actions a release adds and the
  ones it stops declaring. `actions` and `dialogs` are reserved
  namespaces.
- Placements know which map they belong to (#369). A game server reports
  the map it runs in `Hello`: `game.GetMap()` on Gmod, and on FiveM the
  new `rpf_map` convar, which names one setup of the one map (`default`
  unset). A world type may name a `map` field (an indexed string) in its
  `world`, and the core places and targets only the records on the map it
  runs, or those whose map is null, which are on every map.
  `rpf.api.world.map()` says which map that is. In the portal, each
  placement's page shows its map, a type's records filter by map (those
  on it and those on every map), and the map field suggests the maps the
  server reported and its records use, while taking any name typed. The
  worked examples show the pattern (#412): `acme_notes`, `acme_tags` and
  `acme_garden` set `map` with `rpf.world.map()` in the records they
  create, and the counters, lots and doors staff place in `acme_shop` and
  `acme_property` have a `map` field staff fill in. Each is a compatible
  minor version, and an older record, with no map, stays on every map.
- Item images on the player's client (#243). `rpf.api.items.image(slug,
  callback)` hands an addon an item's image ready to draw: a `data:` URL on
  FiveM, for an `<img>` in any resource's page or ox_lib's `image`, and a
  path for `Material()` on Gmod. The client reads the server's catalog
  from the portal with its API token (`rpf.api.items.catalog`), and keeps
  each image under its content hash, checked, on disk (IndexedDB on FiveM,
  `data/rpf/images/` on Gmod), so an unchanged image is fetched once. A
  client platform now has an `item_image` member.
- Item images in `rpf.api.ui` menus (P3 follow-up, #361). A menu option
  names an item with `item = "apple"`, on the client or from the server,
  and is drawn with the item's image beside its label on either engine
  (ox_lib's `icon` on FiveM, a `DImage` on Gmod). The spec carries the
  slug alone: the player's client finds the image through
  `rpf.api.items.image`, waiting up to two seconds the first time, and an
  item it cannot draw keeps its label. An adapter's menu spec may now carry
  an option's `item` and `image`; an adapter outside this repository that
  ignores them draws the label as before.

- Distances in metres on every engine (J8 follow-up, #318). An
  interaction's `distance`, a zone's `radius` field and the `distance` a
  resolved target or a nearby option reports are metres on FiveM and Gmod
  alike, converted by the engine's scale (FiveM 1, Gmod about 39.37 to the
  metre). `rpf.api.world.units(metres)` gives the engine's units for a
  distance an addon measures itself, and `rpf.api.world.metres(units)` takes
  it back, so no addon keeps a table of engines. The platform gains a
  required member, `units_per_metre`, which both adapters and the mock
  declare; an adapter outside this repository must add it. The default
  interaction distance (3) is three metres on Gmod too, where it was three
  units, and the examples drop their hand conversions. Nothing on FiveM
  changes. A Gmod server that stored a zone radius in game units (the
  `acme_property` example) must enter it in metres.
- A built-in command to enter a staff link code in game (F9 follow-up,
  #198): `/rpflink <code>` in chat or `rpflink <code>` in the console, on
  FiveM and Garry's Mod. The platform gains a required member,
  `on_command(name, handler)`, which both adapters implement (FiveM's
  `RegisterCommand`; Gmod's `concommand.Add` and a `PlayerSay` line that is
  run and dropped); an adapter outside this repository must add it. The
  words typed are never logged or repeated. The portal's in-game account page
  names the command.
- The Lua framework is published from its own public repository,
  [Sampleeeee/rpf](https://github.com/Sampleeeee/rpf) (H4 follow-up, #189):
  its source with its history, its releases, and each release's docs site,
  now at <https://sampleeeee.github.io/rpf/>. Download releases from there:
  the txAdmin recipe's address and the portal's **Update available** link
  point at it. Report a vulnerability, in the framework or the portal,
  through that repository's *Security* tab.
- The Lua framework is licensed MIT (H4 follow-up, #190). `lua/LICENSE`
  covers everything a game server runs: the core, both adapters, the `rpf-ws`
  shim, the NUI pages, the bridges and the examples, and every FiveM
  resource, the Gmod addon and the addon kit carries it. The portal is closed
  source and has no licence file. The shim and NUI `package.json` files say
  `"license": "MIT"`. `rpf-ws` now ships `THIRD-PARTY-NOTICES`, the licence
  text of what the shim bundles (`ws`, MIT), in place of `LICENSE.ws`. The
  first release tag is no longer refused for want of a licence.
- Account deletion on the login screens (H6, #229): a "Delete my account"
  button beside "Log in" opens a form in the FiveM NUI page and the Gmod
  Derma UI that asks for the username and password and a ticked box, says
  it cannot be undone and that bans, warnings and game records stay, and
  ends on a screen telling the player to reconnect. On FiveM the password
  is sealed and goes to the portal without reaching Lua.
- Account deletion for a player who is logged in (H6, #322): the same form
  opens with the console command `rpf_delete_account` on Gmod and the client
  command of that name on FiveM (F8 or chat), with the same text,
  confirmation and sealed password. Back returns to the game, or to the
  character screen.
- A player linked to a staff account can delete their own account (H6,
  #331): it is no longer refused `account_linked`. The link goes with the
  account, the staff account stays, and the portal pushes the guild's servers
  their staff lists, so the link's in-game permissions go at once, as when
  staff delete the account.
- Unknown facade operations in the portal (K2 follow-up, #274): the core
  reports every operation its journal could not vouch for
  (`report_unknown_ops`), as it arises and after each `Welcome` until the
  portal has it, and staff holding the new `ops.view` see them on the
  server's **Unknown operations** page (and a count on its overview): when,
  the call, the player, what it moved, the addon's reason and what went
  wrong. Staff holding the new `ops.resolve` mark one resolved with a note
  on what they did in the framework, audited as
  `server.unknown_op.resolve`; resolving moves nothing. One row per op id
  on a server, the first report winning; a server may have 1024 open at
  once; rows go 180 days after the portal first received them
  (`retention::UNKNOWN_OP_RETENTION`). The migration
  `20261011080758_unknown_ops` adds the table.
- A removed addon is purged after 14 days (J6, #302): staff removing an
  addon can restore it by installing the namespace again for
  `retention::ADDON_REMOVAL_RETENTION`; after that the retention sweep
  deletes its records, types and installation, and installing it again (or
  a declaration with `addons.auto_install` on) starts fresh with no records.
  The migration `20261011085242_addon_removal_purge` adds two partial
  indexes the sweep reads.
- The property example (J8, #85): `lua/examples/acme_property/`,
  properties players buy and doors their owners lock, built on the public
  API and the generic types with no Rust, route, page, protocol variant or
  migration of its own. Staff create each property on the data page (a
  live zone the server holds) and place its doors (config points that
  refer to it). A player on a lot for sale buys it in one exchange, whose
  `apply` writes them onto the property as its `holder`. The owner locks
  and unlocks its doors, and a server's own door script asks
  `acme_property.locked` whether a door is locked. Staff reassign a
  property by editing `holder` in the portal. It ships in the addon kit
  with the other examples.
- The addon walkthrough (J7, #84): `docs/writing-addons.md` now begins with
  what RPF provides and what only the examples supply, then builds a new
  example, `acme_notes`, step by step. The steps are the type, registering
  and installing, records, interactions, the permission in the portal and
  in game, a staff edit, a schema upgrade, retries and per-engine values.
  `acme_notes` ships in the addon kit with the other examples.
- The addon kit (J7, #84): each release gains `rpf-addon-kit-<version>.zip`,
  for addon authors and for nobody's server by default. It holds the API's
  annotations for the language server (`meta/`) and the example addons
  (`acme_tags`, `acme_shop`, `acme_garden`) ready to install, as FiveM
  resources under `fivem/[rpf-examples]/` and Garry's Mod addons under
  `gmod/`. An example runs only once a server ensures it and staff install
  the manifest it proposes. On FiveM, an ox_lib that runs but whose loader
  gave RPF nothing now says so at start, instead of asking for ox_lib to be
  installed.
- Hold policies for live addon records (J6, #83): a live type's `hold =
  "server"` records are held by the server while it runs, claimed from the
  portal with a new optional `types` field on `hold` (a page at a time,
  after every reconnect and every minute), and its `hold = "owner"`
  records come and go with their owner's session, including the ones an
  addon creates. When an addon's code stops, only what it held on demand
  is released; disabling its installation releases everything. Adapters
  call `rpf.stop_server()` as they stop, which puts unreported changes in
  the persisted outbox. The `acme_tags` example uses `hold = "server"`
  instead of holding its tags itself. A world-backed live type's `ped` and
  `object` records are placed while the server holds them, as config ones
  are. `rpf.api.time.elapsed(since, max_ms)` counts the time since a
  stored moment with a bounded catch-up, and a new example,
  `lua/examples/acme_garden/`, is a timed live type built on it. The
  portal shows each live type's hold policy on the addon page and the
  record page. The `acme_shop` example's stock is `hold = "server"` too,
  rather than held by the addon on a timer.
- The commerce example (J5, #82): `lua/examples/acme_shop/`, counters that
  sell items and buy them back, built only on `rpf.api`. Staff place
  counters and price listings as config records and stock what is limited
  as a live record; a player picks from a menu the server opens, and one
  exchange moves the money, the items and the stock. It runs on FiveM and
  Gmod alike, and needs no Rust, route, protocol change or migration.
  `rpf.api.ops.result(op_id)` says how an op id already went, so an addon
  answers a repeated order as it was answered. The conformance harness can
  now drop the portal's connection (`World:disconnect`).
- Exchanges (J5, #82): `rpf.api.commerce.exchange(player, deal, op_id,
  apply)` moves money and items together, with an addon's change to its own
  records, as one journaled intent, once per op id; `check(player, deal)`
  makes the same checks without moving anything. A deal is `{ account,
  pay | paid, take, give, reason, records }`, the last naming the records it
  was priced against at the revisions read (`stale` otherwise). On a native
  server it is all or nothing: everything is checked first, including the
  items as one plan across the character's containers, then made in one
  step. Through a bridge the framework's calls run in order, and a failure
  after one went through is `unknown` for staff, refunding nothing. The
  journal's detail for staff now carries what a deal moved (`paid`, `take`,
  `give`). No wire change.

- World definitions on addon types (J4, #81): a type may declare `world =
  { kind, position, heading, bucket, model, visible, radius }`, naming its
  own fields by the part each plays, with `kind` one of `ped`, `object`,
  `point` and `zone`. The portal and the core check it with the same rules
  (one new rule, `world_field`, held to the addon corpus), a change to it
  is compatible, and the generic record page shows a world-backed record's
  placement. No migration, route or protocol change: a world-backed type is
  still only fields.
- Placements (J4, #81): the core places the visible ped and object records
  of running addons' world-backed config types, one entity each, through
  new adapter capabilities (`bucket`, `model`, `entity`, `spawn`,
  `despawn`), and keeps them in step with the config. On FiveM they are
  created server-side under OneSync (frozen, in their routing bucket, kept
  across owner changes, tagged with a state bag, made passive on clients),
  removed when the resource stops and swept as it starts; on Gmod they are
  `prop_dynamic`s. `rpf.api.world` gains `bucket`, `model`, `entity` and
  `placed`. The `zone` capability, never supported, is gone: a zone is a
  record's radius, and the core does the arithmetic.
- Interactions with targets (J4, #81): `rpf.api.interactions.register`
  takes rules (`target`, `distance`, `cooldown`, `permission`, `check`,
  `label`), and the server checks the target the client names (a record of
  a world-backed type, or an entity of given models) for the player being
  in the world, their permission, their cooldown, the target's visibility,
  bucket and distance, and the addon's own check, before the handler runs
  with the target resolved. A minimal interaction UI lists what is near as
  a menu (FiveM key `rpf_interact`, default E, `setr rpf_interact_key`;
  Gmod console command `rpf_interact`), and on FiveM the same rules are
  offered through ox_target or qb-target when one runs. The client API
  gains `open`, `nearby` and `targets`. The `acme_tags` example reads a tag
  you stand at.

- Bridges to existing RP frameworks, the DarkRP pilot (K4, #94):
  `rpf_darkrp`, an addon in the Gmod zip that only a DarkRP server keeps,
  runs RPF beside DarkRP in the companion profile. A player's character is
  their DarkRP data, under their SteamID64, in play once they have logged
  in and DarkRP has loaded it. The facade's money is DarkRP's `wallet` and
  its job the team's `command`; no item call is supported, since DarkRP's
  pocket is not an item inventory. Until a player is in play the bridge
  holds them out of DarkRP's play with DarkRP's and Garry's Mod's own
  hooks: dead, with team changes, commands, votes, pocket drops, salary and
  voice refused, and other players' commands that name them. It was tested
  against DarkRP 2.7.0's source. Installing it is in
  [Installing](docs/installing.md#beside-darkrp).

  **Release note: what the DarkRP login gate does not hold.** DarkRP's tip
  jar asks no hook before a donation, so a modified client of a player who
  has not logged in, beside a tip jar where they joined, can donate from
  their DarkRP wallet; keep tip jars away from spawns. A few hookless
  DarkRP commands that move nothing (answering a question, signing a
  letter, a gesture, a job model preference) also work. Admin mods
  (FAdmin, ULX, SAM) work for admins before the RPF login, as on any
  server. Other addons' own commands and net messages are theirs to gate,
  and an addon whose hook answers before the bridge's decides that hook,
  since Garry's Mod gives hooks no order.
- Bridges to existing RP frameworks, the Qbox pilot (K3, #93): `rpf-qbox`, a
  resource in the FiveM zip that only a Qbox server ensures, runs RPF beside
  qbx_core and ox_inventory in the companion profile. It is the character
  selection after the RPF login, logs out at once a character qbx_core's own
  callbacks load before it, and routes the facade's money (`cash`, `bank`,
  `crypto`), items and job to qbx_core's and ox_inventory's exports. It was
  tested with qbx_core 1.24.0, ox_inventory 2.48.0 and ox_lib 3.40.0.
  Installing it is in [Installing](docs/installing.md#beside-qbox).
- Bridges to existing RP frameworks, part 3 (K2, #92): the shared bridge
  conformance suite (`lua/spec/support/bridge_conformance.lua`) every
  bridge runs against a fake of its framework, on the mock platform and the
  real FiveM and Gmod adapters: the lifecycle and RPF's login gate, every
  supported call once per op id, a framework failing part way, its resource
  stopping and starting, a restart that cut a command off inside the
  framework, and a composite operation refused, unknown, and cut off
  between the debit and the grant reaching the outbox, which ends `unknown`
  for staff with nothing compensated. A mock bridge over a fake framework
  passes it, as K3's Qbox and K4's DarkRP bridges will.

- Bridges to existing RP frameworks, part 2 (K2, #92): the bridge
  contract, 1.0. A bridge registers through `rpf.api.bridge.register`,
  declaring the domains its framework owns (`provides`) and the facade
  calls it implements (`supports`); the core refuses one of another
  contract major or with a field the contract does not allow, with one log
  line, and activates it once the server's profile is fixed and it
  provides exactly the external domains. Players then move on to
  `character_select`, and the bridge reports `character_loaded` (to
  `active`), `character_unloaded`, `unavailable` and `available`. On a
  companion server the facade's calls go to the bridge and never to RPF's
  own modules: an unsupported call is `refused("unsupported")`, an outage
  `unavailable`, and a command the bridge cannot prove did nothing
  `unknown`, journaled once per op id as on a native server. A framework's
  key stays on the game server. On a native profile, a bridge whose
  framework is running anyway logs an error naming the `domains` setting.
  On FiveM, a bridge's resource stopping withdraws it. The rules every
  bridge follows are in `lua/bridges/README.md`, and
  [Compatibility](docs/compatibility.md#bridge-contract-majors) says how
  the contract is versioned. A facade command whose result is
  `unavailable` is no longer kept in the journal, so the same op id may be
  sent again once the provider is back.

- Bridges to existing RP frameworks, part 1 (K2, #92): an addon pays for a
  change to its own records in one intent. Each facade command
  (`rpf.api.money.debit`, `credit`, `rpf.api.inventory.give`, `take`)
  takes an optional `apply` after its op id, run only once the command
  went through; the intent completes only once what `apply` wrote is on
  its way to the portal, so a server that dies between the payment and the
  grant reads `unknown` after its restart, and nothing is refunded
  automatically. Every `unknown` is logged at `error` with what it was
  (the player's account, the account or item, the amount and the reason),
  announced as `domains.op_unknown`, and listed by `rpf.api.ops.unknown()`
  for a staff tool in game. The journal never runs an op id twice when a
  crash lost its index: an id it does not know is looked up by its own
  storage key first.
- Authority per domain, part 1 (K1, #91). A server's **profile** says who
  owns characters, money, inventory and jobs on it: RPF (native, the
  default) or the game server's own RP framework (companion). Staff save it
  as the `domains` setting, inherited like any other; only the two uniform
  profiles validate, and a switch is refused while the server still holds a
  record of a domain it would switch. The game server's core fixes its
  profile at its process's first `Welcome` and reports it in every later
  `Hello`, so a saved change applies at its next restart, and the portal
  enforces the profile it is running, showing "pending restart" meanwhile.
  A restart that turns a domain external archives that domain's records on
  the server for good. Every portal path that writes or holds a record of
  an external domain refuses it, whether or not the game server is
  connected, and a game server is told so with the new reject code
  `domain_external` (part 2). The core refuses too: RPF's own character,
  money, inventory and job modules answer `domain_external` there, the
  facade `unavailable`, and on a companion server without its bridge (K2)
  no player gets past `registered`, with one log line saying why (part 3).
  The portal shows "managed by the game server's framework" in place of an
  external domain's characters, containers and accounts, offers no edit of
  them, marks the item catalog and the jobs "not applied", and lists the
  archived records behind an explicit, read-only Archived filter (part 4).
- Release docs (H7, #56). Every release publishes its own docs site on
  GitHub Pages, from its tag: installing, upgrading from the release before
  (`docs/upgrading.md`, which a tag now requires), compatibility, the
  changelog and the Lua API reference, one directory per release that no
  later tag rebuilds, with `latest` and per-line aliases and a version
  switcher on every page. The Release's notes link it. CI builds the site
  strictly on every pull request, so a broken link fails there.
- A browsable Lua API reference (J9, #191): a page for `rpf.Api` and each of
  its tables and types, with what every call takes and returns, which side
  it runs on, examples on the calls an addon reaches for first, linked
  types and search, generated from the annotations so it cannot drift from
  the code. The core's own modules are under a labelled Internals section.
  It is in each release's docs site, and `dev/luadoc` builds it to open from
  disk. The annotations now list the `inactive` refusals `events.on`,
  `events.once`, the timers and `addons.provide` already returned.
- Setup (H7, #56). [Installing](docs/installing.md) takes an owner from a
  stock server to a connected one on FiveM and Garry's Mod, with a
  troubleshooting section keyed by the console lines. Each release also
  publishes `rpf-txadmin-recipe.yaml`, which txAdmin's deployer turns into a
  server with the framework installed and OneSync on. The server's **API
  keys** page shows the portal's websocket address, and on issuing a key the
  exact `server.cfg` lines for each engine. The FiveM adapter refuses to
  start, in one line saying what to do, on a malformed `rpf_url` or
  `rpf_api_key`, an artifact without routing buckets, OneSync off, or
  `rpf-ws` not started, and a refused start no longer takes player events;
  the Gmod adapter does the same for a malformed convar and for a GWSockets
  module that is installed but will not load.
- Game-server releases (H7, #56). A version tag now also publishes a
  GitHub Release with `rpf-fivem-<version>.zip` (one `[rpf]` folder holding
  the `rpf` and `rpf-ws` resources, for `resources/`), `rpf-gmod-<version>.zip`
  (the `rpf` addon, for `garrysmod/addons/`) and their `SHA256SUMS`, with
  notes naming the protocol the release speaks and the portal releases that
  serve it. A tag whose version, changelog section, compatibility row,
  frozen corpus or licence is missing is refused before anything is
  published.
- The portal tells staff when a game server should upgrade (H7, #56). A
  connected server's **Game server** card says **Update available** when
  its core is an older release than the portal's, linking the release to
  install, and **Upgrade needed**, with the date, when the protocol it
  speaks has been announced as going (`rpf_protocol::SUNSETS`, empty
  until a release deprecates one)
  ([Compatibility](docs/compatibility.md#seeing-who-is-behind)).
- Item images and object storage (P3, #49). Staff with `config.items.edit`
  upload a PNG, JPEG or WebP of at most 256 KiB for an item on its items
  page; the portal re-encodes it as a PNG of its pixels alone, at most 256
  pixels a side, and stores it in S3-compatible object storage. The config
  snapshot and the player API's item catalog name each image by its
  SHA-256, and `GET /api/v1/player/items/{slug}/image` redirects a player's
  client to a short-lived signed URL on the user-content domain, a separate
  registrable domain from the portal's. A guild's images count against its
  plan's new storage allowance (50 MiB standard), which the operator's
  console sets. Uploads and removals are audited as
  `config.item_image.set` and `config.item_image.delete`.
- In-game config editing (E6, #48). A linked staff member changes their
  server's settings, items, item bases, employers, departments and jobs in
  game with `rpf.api.config.edit(handle, base_version, changes)`, with the
  flags the portal's config pages need, checked by the portal when the edit
  arrives. The portal applies an edit only on the config version it was made
  against, through the same checks as its pages, and pushes the result back
  as config; one made against a version that has since moved (a portal edit
  landed first, or the portal moved on while it waited out an outage) is
  applied in no part, the staff member is told to redo it, and the server's
  settings page lists it under "Discarded in-game changes". Audited with the
  server and the player as the actor and the staff account linked.
- The platform operator (H5, #54). Platform admins, made only with
  `rpf-portal platform-admin grant <account>` and separate from every guild
  role, get a console at `/platform` to suspend a guild (its game servers
  are disconnected and refused `suspended`, its players cannot register or
  log in, its portal is read-only for its staff), set its plan (servers,
  player accounts and its game servers' frame rate, which replace the fixed
  limits; billing stays off-platform), open read-only support access for a
  few hours, announced on every page of the guild, and hand a guild to a
  new owner who has lost every sign-in factor. Everything an operator does
  is in the guild's own audit log with their reason.
- Removing staff (F9 follow-up, #197). Staff holding `member.remove` get a
  Staff page for the guild and for each server they hold it on, listing who
  holds a role there and removing them: from the guild (every role they
  hold) or from one server (only that server's roles). The change reaches
  their linked player in game at once, and is audited as `member.remove`. A
  removed staff member keeps their player link.
- The Lua core waits out a `suspended` refusal of its `Hello`: it tries
  again every `suspended_retry_ms` (five minutes) plus jitter, so a server
  comes back on its own once its community's suspension is lifted.

- The FiveM adapter (D2, #17): the `rpf` resource (the Lua core, the adapter
  and its login and character screens) and the `rpf-ws` resource (the
  portal websocket in FiveM's JS runtime, `ws` bundled in, no
  `npm install`), assembled by `dev/fivem-resources` and configured with the
  `rpf_url` and `rpf_api_key` convars. Other resources reach the public API
  as `exports.rpf:api()`. The login page keeps the player's password out of
  Lua, and the server holds a player in a routing bucket of their own until
  they are `active` (OneSync)
  ([the adapter's README](lua/platform/fivem/README.md)).
- The portal stops in order on `SIGTERM` (H1, #50): readiness answers
  `503 draining` and new websocket upgrades are refused at once; after
  `RPF_SHUTDOWN_NOTICE_SECS` every connected game server is sent
  `restarting` with `RPF_SHUTDOWN_RETRY_AFTER_MS` and closed; the process
  exits once its connections are done or after `RPF_SHUTDOWN_GRACE_SECS`.
  Started beside a ready replacement, a deploy no longer leaves game
  servers without a portal to reconnect to, and their reconnects are spread
  over the delay plus jitter instead of landing together.
- The Lua core honours `restarting`: the reconnect after an announced close
  waits `retry_after_ms` plus jitter, capped by `max_retry_after_ms`, without
  advancing the backoff.
- Jobs in game (D7, #40): `rpf.jobs` in the Lua core gives a new character
  the server's default job, sets and clears jobs, puts characters on and off
  duty, checks ranks, and pays a job's salary each pay period on duty from
  its employer's payroll account. A character's job is live state, reported
  with the character and shown on its page. Staff give jobs a rank and a
  salary, and employers a payroll account (one of the server's paying
  accounts), on the jobs page; two settings, `economy.salary_interval_minutes`
  and `economy.salary_account`, set the pay period and the account salaries
  go into.
- `rpf_ws_handshake_seconds`, the time from a game server's `Hello` to its
  `Welcome`, and a reconnect-storm load test in the fake game server that
  reads it, so the delay is chosen from data.
- The Garry's Mod adapter (D8, #47): the core on a real Gmod server over
  GWSockets, which it requires (it says so in one line and starts nothing
  without it), configured by the `rpf_ws_url` and `rpf_api_key` convars.
  Players are reported as `steam:<SteamID64>`, held still until they are
  playing a character, and log in and choose a character through Derma
  screens; the password goes from the client to the portal, never over
  `net`. See `lua/platform/README.md`.

- In-game staff (F9, #41): staff link their player account in a guild with
  a short-lived code from their new in-game account page
  (`/guilds/:slug/link`), typed in game through `rpf.api.staff.link`, and
  then hold their portal permissions there, as `rpf.api.staff.can(player,
  "player.kick")` answers them. The portal pushes each server its linked
  staff's permissions on every change, on join and after each reconnect.
  Codes are 40 bits, single use and live five minutes, and wrong guesses are
  limited per player and per guild and lock a guild's codes out. Scripts
  report in-game staff actions with `rpf.api.staff.record`, and the audit
  log names the staff account each was taken under.
- Staff email and account recovery (H3, #52). Rauthy's deployment config
  (`deploy/rauthy/config.toml`): open signup verified by mail, every mail
  carrying the product's name, TLS-only SMTP. The dashboard asks every
  staff member to keep a second passkey and links to their Rauthy account
  page (`/auth/account`). The portal keeps a staff member's address only
  when Rauthy says it is verified, so an operator naming an account by
  address finds only someone who proved they hold it. Support
  follows a written owner-recovery procedure, with its identity checks.
- Sign out everywhere else (H3 follow-up, #222). The dashboard shows how
  many other browsers are signed in to a staff member's account and ends
  all of them in one click, keeping the one it is pressed in; the way to cut
  a session off after taking an account back at Rauthy, which does not end
  the portal's own sessions. Each guild the account is staff in logs it as
  `staff.sessions.end`, with how many sessions ended.
- The addon API, part 1 (J3, #80). `rpf.api.addons` registers a Lua addon
  with its manifest and `start`, `stop` and `state` handlers, reports its
  state, serves addon API majors as a range (`API_MIN` to `API`), and lets
  addons share functions by namespaced name (`provide`, `call`).
  `rpf.api.time` has the clock and timers (`now`, `after`, `every`,
  `cancel`) on every engine alike. Timers, event handlers and exports an
  addon sets up while its code runs are taken down when it stops;
  registering again reloads it; on FiveM a stopped resource's addons are
  unloaded with it, and a handler may be another resource's function
  reference. Nothing in `rpf.api` throws any more: `events.emit` of a core
  name, or of another addon's namespace, returns `nil` and a reason rather
  than raising ([Writing addons](docs/writing-addons.md)).
- Backups, restore drills and the restore runbook (H2, #51). Postgres
  archives every WAL segment to an S3-compatible bucket with WAL-G,
  encrypted before it leaves, and a `backup` service takes a base backup a
  day and keeps four weeks: an RPO of five minutes, an RTO of four hours,
  and deleted data gone from every backup within 35 days. Rauthy keeps its
  data in the same cluster, so one restore brings both back to the same moment.
  `deploy/restore-drill` restores the newest backup to a scratch instance,
  migrates it and starts Rauthy on it, weekly in `restore-drill.yml`; the
  restore runbook is written down and rehearsed.
- `rpf-portal restore reapply` (H2, #256): after a restore to an earlier
  moment, it compares the restored database with the copy kept from before
  it, erases again the player accounts erased since, cancels again the
  deletions their owners cancelled since, lists the deletions requested
  since for the operator to tell their owners, and brings back item images
  the portal deleted since from the images bucket's versions, auditing what
  it changes in each guild's log. It is the restore runbook's step 7, and
  needs, for the images, a key that may read, list the bucket and its
  versions, and delete a version.
- The addon API, part 2 (J3, #80). `rpf.api.records` reads, finds, holds
  and writes addons' records: `get` and `list` locally, `query` through the
  portal, `hold` and `release` on demand, `create`, `update` (a patch, with
  an optional `revision` and fields to `clear`), `delete`, and `batch`, all
  or nothing and reported together. Results are plain copies and refusals
  are values. `records.created`, `records.changed` and `records.deleted`
  announce every change to a held addon record, staff edits included. An
  addon's calls close when it stops, and the records it held for the
  server are released.
- The addon API, part 3 (J3, #80): the domain-neutral facade, so an addon
  reaches a player's character, money, items and job the same way whoever
  owns them. `rpf.api.characters.current`, `money.accounts`, `balance`,
  `debit` and `credit`, `inventory.count`, `give` and `take`,
  `jobs.current`, each domain's `supports`, and `rpf.api.ops.new()`. Every
  command runs at most once per op id, recorded in a journal that outlives
  a restart, which turns an operation it cut off into `unknown` for staff
  rather than running it again. A new server setting,
  **`economy.addon_account`** (`config.accounts.edit`, unset by default),
  names the paying account addons charge into and pay out of; until staff
  set it, addons cannot move money.
- The addon API, part 4 (J3, #80). `rpf.api.interactions`: an addon
  registers a handler by namespaced name, and a player's client sends a
  request to it (`rpf:interact`), answered as `interactions.result`; nothing
  else a client sends reaches addon code. `rpf.api.capabilities()` and
  `rpf.api.world.position(player)`, from what each engine's adapter
  declares. The worked example ships runnable as `lua/examples/acme_tags/`,
  and [Writing addons](docs/writing-addons.md) is the author's guide on the
  docs site. [Compatibility](docs/compatibility.md#addon-api-majors) says
  how addon API majors, game servers and the portal move.
- Interactions that answer (J10, #239, part 1). On the client,
  `rpf.api.interactions.request(name, payload, callback)` hands the
  handler's answer, and now a table of data, to a callback, with a timeout;
  every request is answered, `unknown`, `too_many` and `not_logged_in`
  included, rather than dropped. Requests travel as a request and its
  answer, which the platform pairs: ox_lib's `lib.callback` on FiveM,
  numbered `net` messages on Garry's Mod. The example addon lists a
  player's own tags and scrubs one by id, resolved in the player's scope.
  **A FiveM server needs ox_lib 3.40.0 or newer**, ensured before `rpf`
  ([Installing](docs/installing.md#fivem)); the txAdmin recipe installs it.
  It is LGPL-3.0 and never part of the release's zip.
- Portable UI for addons (J10, #239, part 2). `rpf.api.ui` has `notify`,
  `menu`, `input` (text, number, checkbox and select fields) and
  `progress`, the same call on both engines: built on ox_lib on FiveM and
  in Derma on Garry's Mod. On the client they show what the player's own
  client asks; on the server each takes the player first, and the
  client's answer is read against what was offered (a menu option's
  `value` never leaves the server). `rpf.api.capabilities()` reports the
  four, now on the client too. The example addon's `/tags` picks a tag to
  scrub from a menu.

### Removed

- Protocol 1: never served by a released game-side build; dropped on the
  repository owner's confirmation that nobody runs it (2026-10-09). A
  `Hello` naming it is refused `malformed` with the upgrade message, like
  any version below the served range, and the paths the portal kept for it
  are gone: the drain's plain close, the `forbidden` answer to a suspended
  guild, the `forbidden` stand-in for `domain_external`, and the refusals
  of staff, config and addon frames on an older connection
  ([Compatibility](docs/compatibility.md#changing-the-wire)).

### Fixed

- The interaction menu and the target resources offered an interaction
  the addon's own `check` would refuse, such as a sold lot (J8 follow-up,
  #317). The server now runs `check` as it lists, the same way the
  request runs it: at most 32 per listing, nearest first, and none after
  2 seconds. A check now also runs whenever a player nearby opens the menu
  or aims at the target, so it must be quick and only read. On FiveM,
  ox_target and qb-target show an option once the server has said it is
  offered there (`rpf:target_offers`, asked in the background). The
  `acme_property` and `acme_notes` examples move their sold and not-yours
  refusals into `check`.
- A composite operation's `apply` that yielded could lose sight of what it
  wrote when another one ran meanwhile, so the journal could record it done
  before its change reached the outbox (`rpf.records.watch`).
- A deleted player account is kicked from the game (J8 follow-up, #319).
  Deleting an account, by staff or by the player from another server's
  login screen, kicks it from every server of the guild it is logged in on
  with "This account has been deleted.", through the `kick` command every
  core already runs; a server that was not connected kicks it at its next
  `OnlinePlayers` resync. Before, the player stayed in play on an account
  the portal refused every change for, so an addon's record owned by them,
  or a property bought for them, was refused after the money moved. The
  player page shows how each kick went. An erased account is no longer put
  back on a server's online list by a resync. No protocol or Lua change.

### Database

- `20261012055417_dialogs` is additive: the `dialogs` table (#371).
- `20261010083508_domain_authority` is additive: `servers.effective_domains`,
  defaulted to native, and a nullable `archived_at` on characters, accounts
  and containers.
- `20261009213553_item_images` is additive: item images, the storage
  deletion queue and the trigger that fills it, and a nullable
  `guild_plans.max_storage_mib`.
- `20261009035000_player_links` is additive: player links, link codes and
  failed link attempts.
- `20261008222809_character_jobs` is additive: a character's job, a job's
  rank and salary, and an employer's payroll account, all nullable or
  defaulted.

### Deployment

- Staging (H2, #51): a second deployment of `deploy/compose.yml`, with its
  own hosts, Rauthy, keys and backup prefix, follows `main` on a host of
  its own. `deploy/staging/update`, on a systemd timer, builds each new
  commit there, deploys it and checks it through the public hostnames, and
  a weekly timer runs the restore drill against staging's backups. A
  release is tagged only from a commit staging has run.
  `deploy/compose.yml` takes the hosts, TLS and listening address of a real
  deployment (`RPF_PORTAL_HOST`, `PORTAL_BASE_URL`, `RPF_TLS`, `RPF_HTTPS_BIND`) and
  passes the `RPF_STORAGE_*` variables through.
- The database runs the image built from `deploy/postgres/` (the official
  Postgres 17 with WAL-G), with the `backup` service beside it, and needs a
  backup bucket at another provider: the `RPF_BACKUP_*` variables, a
  writer's and a reader's key, an encryption key kept apart from the
  bucket, and the bucket's access log turned on. Optional
  `RPF_ALERT_WEBHOOK_URL` receives backup and drill failures.
- Rauthy keeps its data in Postgres, in a `rauthy` database and role the
  database's image creates on its first start (`RPF_RAUTHY_DB_PASSWORD`),
  instead of its embedded Hiqlite; its `/app/data` volume is only a cache.
  `deploy/compose.yml` now runs Rauthy behind the same proxy, on a host of
  its own. Rauthy's `ENC_KEYS` are needed to restore it: keep them with the
  backups' key.
- Item images need object storage and a user-content domain: the
  `RPF_STORAGE_*` variables (unset, images are off), an S3-compatible
  bucket, and a separate registrable domain in front of it that passes the
  `Host` through and adds `X-Content-Type-Options: nosniff` and a
  sandboxing `Content-Security-Policy` to every response. The portal
  refuses to start with a user-content URL on its own site.
- New optional environment variables `RPF_SHUTDOWN_NOTICE_SECS`,
  `RPF_SHUTDOWN_RETRY_AFTER_MS` and `RPF_SHUTDOWN_GRACE_SECS`; the defaults
  suit a single process behind a proxy. The orchestrator's kill timeout must
  exceed the first plus the third, or it ends the drain early.
- Rauthy needs a mail provider: the `SMTP_*` variables and the sending
  domain's SPF, DKIM and DMARC records, and it exits at startup without
  one. The portal's client gets its client URI, `${PORTAL_BASE_URL}`. A
  staff member's address is cleared at their next sign-in unless Rauthy marks it
  verified, which it does for every account that signed up or used its
  setup mail.

## [0.1.0] - 2026-10-06

Milestone 1 (#35): a game server can connect, authenticate, be configured and
be moderated, players can log in to their accounts, and a fake game server
proves all of it. Real FiveM and Garry's Mod adapters are Milestone 2 (#57).

**Protocol:** speaks protocol 1, and serves protocol 1 only. Its corpus,
`protocol/corpus/v1/`, is frozen from this release on.

### Added

#### Portal and staff

- Tenant isolation as structure: every store method that touches guild or
  server data takes a scoped handle that only authentication mints, and
  refuses another tenant's record exactly as a missing one (#63).
- Money as positive `i64` ledger entries between two accounts, with balances
  derived from the ledger, never stored (#61).
- Staff sign in through Rauthy (OIDC) only; users are keyed by issuer and
  subject, sessions are stored as token hashes and expire (#64, #69).
- Guilds, servers, roles and role assignments, with permissions as pure domain
  logic and a staff authorization guard on every page and server function
  (#65, #68, #88, #101, #130, #151).
- Staff invites and onboarding (#124).
- The audit log: every write records its event in the same transaction
  (#104).
- Server settings with three-state inheritance through a parent server
  (#109).
- The item catalog and item bases (#141), employers, departments and jobs
  (#156), and economy config: starting accounts, a server's starting funds and
  default job (#163), and paying accounts for wages and rewards (#178).
- Player roster and player page (#138), the live online list (#157), bans
  (#149), kick and warn (#170), and views and edits of characters, accounts and
  containers (#177).
- The portal shell, designed stylesheet and components, every page working
  with scripting disabled (#108, #114, #140, #146, #160).

#### Players

- Per-guild player accounts with Argon2id passwords, registration, login,
  join tickets and remember tokens; identifiers are reference data, never
  identity (#67, #76, #89, #102).
- Player API tokens for direct portal requests (#105).
- The join flow: ticket redemption by the connected server, with identifiers
  stored as reference data (#117).

#### Game servers and the protocol

- Protocol 1: one flat envelope per frame with a sender-minted request id, the
  account-based join messages, and a checked-in conformance corpus that the
  Rust types and the Lua decoder are both held to (#60).
- Game-server API keys, stored as SHA-256 and shown once (#107).
- The authenticated websocket with abuse limits (#111), durable request
  idempotency and ordered dispatch (#112), and the connection registry behind
  a trait (#113).
- Config sync: one versioned `ConfigSnapshot`, pushed on change and skipped
  on a reconnect at the current version (#119, #161).
- Record holding and state reports: a game server is the writer of the
  characters, accounts and containers it holds, and Postgres keeps a replica
  (#128, #154).
- Forward compatibility: the portal serves every protocol version from
  `MIN_VERSION` to `VERSION`, refuses others with an upgrade message, freezes
  each released version's corpus, and logs which versions connected servers
  run (#32).

#### Lua core

- The engine-agnostic core under the `rpf` global, for Lua 5.1 and 5.4: the
  connection, the persisted outbox and the request journal (#66, #99, #122).
- The framework runtime: namespace, events, players, auth and config API
  (#106).
- Inventory, with the container validation corpus shared with the portal
  (#158, #165, #173).
- Characters and accounts, including payments from a server's paying accounts
  (#171, #174, #176, #178).
- The contract for coexisting with existing RP frameworks (#98).

#### Operations

- The container image and its TLS-proxied verification, health endpoints,
  and the hosting notes (#134, #150).
- Production observability: correlation ids from an HTTP request across the
  websocket, JSON logs split by tenant with secrets redacted, and Prometheus
  metrics behind a token (#180).
- Frame capture for development, and the capture-to-fixture workflow (#115).

#### Development

- The Cargo workspace whose crates follow the dependency direction (#127,
  #123), compile-checked queries (#100), the fake game server running the real
  Lua core under both Luas (#118, #162, #167), bounded database tests (#166),
  the local CI runner and worktree build seeding (#142, #155), and the agent
  workflow (#58, #59, #62, #129, #152, #153).

### Database

Every Milestone 1 migration is in this release, and a 0.1.0 deployment
applies them all to an empty database. Five rewrite or drop data
(`oidc_identity`, `player_accounts`, `drop_password_auth`, `oidc_logins`,
`record_holds`) and are one-way doors, but no database existed before this
release for them to matter to. The review is in
[Compatibility](docs/compatibility.md#the-database).

[Unreleased]: https://github.com/Sampleeeee/rpf/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Sampleeeee/rpf/releases/tag/v0.1.0
