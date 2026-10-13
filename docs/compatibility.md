# Compatibility

The portal is hosted: one deployment, upgraded whenever a release is rolled
out. The Lua core runs inside each community's game server, and its owner
upgrades it when they choose to, which may be months later. So the day a new
portal deploys, every game server still runs whatever core it ran the day
before, and the portal is always the newest party on any connection. This
page is the contract that makes that survivable: which versions talk to
which, what changes are safe, and how the tests hold it.

Two numbers are involved, and only one decides compatibility.

- **The release version** (`0.1.0`) names a release of the whole project.
  The portal image and the Lua core ship together under one tag: the
  workspace `version` in `Cargo.toml` and `rpf.VERSION` in
  `lua/core/init.lua` are always equal
  (`the_lua_core_is_released_with_the_portal`). The core reports it in
  `Hello` as `core_version`, for staff and logs only.
- **The protocol version** (`protocol::VERSION`, mirrored by
  `rpf.protocol.VERSION`) names one set of message shapes. The core sends it
  in `Hello`, and it alone decides whether the portal can talk to a game
  server.

## Which portal serves which protocol

| Protocol | First release | Served by portal releases | Status |
|---|---|---|---|
| 1 | 0.1.0 | 0.1.0 only | Dropped before 0.2.0: no released game-side build ever spoke it, since 0.1.0 had no FiveM or Gmod adapter, and the repository owner confirmed nobody runs it (2026-10-09) |
| 2 | Unreleased | The next release and later | Current, unreleased, and the oldest served: adds `Restarting` (H1), a character's job (D7), in-game staff (F9: `link_player`, `staff_action`, `player_linked`, `staff_permissions`), the `suspended` reject code (H5), the `domain_external` reject code (K1), the `referenced` reject code (a deletion refused because another record refers to it), in-game config editing (E6: `config_changed`, `config_change_applied`, `config_change_discarded`, and `config_changes.json`), an item's `image` hash in the config snapshot (P3), an item's `weapon` (L3), the profile (K1) in `hello` and `welcome`, and the `report_unknown_ops` notice (#143) |

A row is added when a release ships a new protocol version, and a version's
last portal release is filled in when one drops it. `CHANGELOG.md` names the
protocol versions each release speaks.

## A server on an older protocol is served

**The portal serves every protocol version from `protocol::MIN_VERSION` to
`protocol::VERSION`**, and on each connection it speaks the version that
connection's `Hello` named. Both constants were `1` in 0.1.0, and the
first change after it (H1's `Restarting`) made `VERSION` 2. `MIN_VERSION`
became 2 before 0.2.0 shipped, when protocol 1 was dropped on the owner's
confirmation that nobody runs it ("Compatibility is kept clean, or not
kept", below), so for now the range is the one version.

- A `Hello` naming a version in the range is answered with `Welcome`, whose
  `protocol` is that same version (`rpf_backend::ws::auth`). The Lua core
  stops for good if `Welcome` names any other version, because every frame
  after it would be read against the wrong shapes.
- A `Hello` naming a version **below** `MIN_VERSION` is refused, before its
  key is even checked, as `Rejected` with code `malformed` and a reason that
  is the upgrade message: *"unsupported protocol version 1: this portal
  speaks protocol 2 to 2; upgrade the rpf core on this game server"*. The
  core treats `malformed` as final, stops reconnecting, and logs the reason,
  so the server's owner reads exactly what to do.
- A version **above** `VERSION` (a core newer than the portal: a development
  build, or a portal rolled back) is refused the same way, with a reason
  saying the core is newer than the portal.

The refusal uses an existing code on purpose. A game server too old to be
served is exactly one that could not decode a `RejectCode` added for the
occasion, so the message travels in `reason`, which every version decodes.

Serving rather than refusing is the choice because the portal deploys on its
own schedule: if a protocol bump refused every older server, every deploy
that changed the wire would take every community that had not upgraded yet
offline at once.

## Support window

A protocol version stays served for **at least 180 days after the first
release whose portal speaks its successor**. Dropping it means raising
`MIN_VERSION` in a release, which:

- is announced under **Deprecated** in `CHANGELOG.md` in the release that
  ships the successor, with the earliest date the old version may go, and
  added to `rpf_protocol::SUNSETS` with that date, so the portal tells the
  staff of every server still on it (Seeing who is behind, below);
- happens only after the census (below) shows no connected server, or only
  ones whose owners have been told, still on it;
- is listed under **Removed** in the release that does it, and in the table
  above.

`MIN_VERSION` never goes above `VERSION` (a compile-time assertion in
`rpf-protocol`), and every version from `MIN_VERSION` up to `VERSION` must
have a frozen corpus (`released_corpora_are_frozen`).

## Compatibility is kept clean, or not kept

Compatibility is worth exactly as much as the people it keeps running. A
path for an older version is code everyone reads for as long as the version
is served, so it has a shape, and a path that cannot take that shape is a
question for the repository owner, not a decision for whoever is writing it.

**The clean shape.** An older version is handled at the edge and nowhere
else: a version's own decode and encode at the frame boundary, a
`<NAME>_PROTOCOL` gate where the registry queues a frame, a defaulted field.
Handlers, the store and the Lua core work in the current shapes only and
never ask which version they are serving.

**Ask before going further.** If keeping an older version working would
mean any of these, stop before writing it:

- a check of the connection's protocol, the addon `api` major or the core
  version anywhere past the edge: in a handler, the store, the config
  builder, or `lua/core/`;
- a second copy of a handler, a query or a Lua module kept alive for one
  version;
- a type, field or table kept only so an older version still decodes,
  where it costs more than a defaulted field;
- anything a reviewer would call a hack, or that would need a paragraph in
  this page to explain.

Ask the repository owner, with the census (below) and the release history
in front of them: **does anyone actually run the version this keeps
working?** Give them the two options, the compatibility path as it would
look and the breaking change with what it costs a server still on the old
version. Never assume nobody does, and never assume someone does.

- **Somebody does, or the owner wants the window kept:** write the path, in
  the cleanest shape it can take, with the reason in its doc comment and a
  note under **Deprecated** in `CHANGELOG.md` so it goes when the window
  closes.
- **Nobody does:** make the breaking change. Drop the version from the
  served range in the same release (raise `MIN_VERSION`, or the oldest
  addon `api` major), list it under **Removed** in `CHANGELOG.md` saying the
  owner confirmed it had no users and when, and fix the table above. The
  support window is a promise to users; with none, it promises nothing.

An agent working unattended (`next-task`) asks by commenting on the issue
with both options and the census, leaves the PR as a draft, and stops on
that issue. A decision recorded on the issue is not taken again for the
same version.

## What a server owner touches

A server owner's setup is a contract too: they upgrade by replacing the
resource folders and restarting, and expect it to come back up. From the
first published release, these follow the rules for names in `AGENTS.md`
("Names that are schema"): a shipped one is never renamed or retyped, and
one that goes is deprecated a release ahead, with the replacement named in
`CHANGELOG.md` and the release's upgrade notes.

- The resource and addon names (`rpf`, `rpf-ws`), and the folder layout an
  owner installs: the FiveM release's one `[rpf]` folder holding the two
  resources, and the Gmod release's `rpf` addon folder
  ([Installing](installing.md)), and the release
  assets' names, which links like the txAdmin recipe's
  `releases/latest/download/rpf-txadmin-recipe.yaml` name.
- Convars (`rpf_url`, `rpf_api_key`, …) and their Gmod equivalents.
- Exports and globals other resources call (`exports.rpf:api()`, the
  `rpf` global on Gmod), and the public Lua API behind them, whose majors
  are the addon `api` ([Writing addons](writing-addons.md#versions)).
- What the resource requires of the server: OneSync, GWSockets, ox_lib
  and its minimum version (J10), the artifact or Node version. A new
  requirement, or a higher minimum, is named in the release's upgrade notes,
  and the resource refuses to start without it in one console line that
  says what to install.

The same "ask before going further" rule applies when keeping one of these
would be ugly.

## Addon API majors

Addons are a fourth party to a server's versions, written by people who
are not us and upgraded on their own schedule. Three versions meet (J3):

- **The addon's `api`**, in its manifest: the addon API major it was
  written for.
- **The game server's RPF release**, which serves a range of majors,
  `rpf.addons.API_MIN` to `rpf.addons.API` (1 to 1 in 0.2.0). An addon
  whose `api` is outside it stays in state `api`, with the reason, and
  never runs; the others on the server are not affected.
- **The portal's release**, which checks every manifest by the shared
  rules (`rpf_domain::addons`). Nothing unknown is accepted, so a manifest
  using a key a newer contract added is refused, with the rule, by an older
  portal rather than half-read; the game server's own check (`rpf.manifest`)
  is the same rules, and refuses it at registration first.

How each moves:

- **Within a major, the API only grows.** A new call, a new optional
  argument, a new field in what a call returns, a new event or a new
  refusal reason is compatible: an addon written for an older minor runs
  unchanged. Addons check what they need with `supports` and
  `capabilities()`, and treat an unknown refusal reason as a refusal.
- **A breaking change is a new major**, served beside the old one for the
  support window above. `API` moves to it; `API_MIN` moves only with the
  deprecation notice `CHANGELOG.md` gives for protocol versions. The
  compatibility path lives at the edge, an API table per major, never in
  the modules behind it; if it cannot, the owner decides, as for the wire.
- **Skew between a game server and the portal** is the protocol's, above:
  everything an addon does reaches the portal through frames J2 added at
  protocol 2, and the portal upgrades first, so a game server months
  behind is served its protocol and its addons' manifests are checked by
  the rules its own core applied.
- **Records outlive releases.** A type's records stay valid through every
  compatible schema change, an older release of the addon keeps fields it
  does not know (writes are patches), and records stay when the addon's
  files leave the server ([Writing addons](writing-addons.md#8-change-the-schema)).

## Bridge contract majors

A bridge to an existing RP framework (`lua/bridges/README.md`) is written
against the **bridge contract**, versioned on its own (K2): the core
speaks `rpf.bridge.CONTRACT` (1.0 in 0.2.0), and a bridge declares the
`contract` it was written for.

- **A new optional call bumps the minor.** A bridge written for an older
  minor does not list it in `supports`, and the facade answers it
  `refused("unsupported")` there, which addons check with `supports`. A
  bridge written for a newer minor than the core's may list calls the core
  does not know: they are left out.
- **A breaking change bumps the major**, a new call every bridge must
  implement included, and the core refuses a bridge of another major, with
  one log line, and holds players at `registered`: the server fails closed
  rather than half-routed.
- Bridge, core and portal versions are independent: the contract never
  crosses the wire, and nothing in the portal names a framework.

## Changing the wire

### The freeze

`protocol/corpus/v<N>/` is the spec of protocol `N`: one sample frame per
message type in each direction, plus `commands.json`,
`command_outcomes.json` and, from protocol 2, `reject_codes.json`. **Once a release ships version `N`, its corpus is
frozen**: `protocol/corpus/frozen.json` lists every file with a digest, and
`released_corpora_are_frozen` fails if any file is changed, added or removed.
v1 is frozen as of 0.1.0.

So the first change to the wire after a release, of any kind, compatible or
not, **bumps `protocol::VERSION`** (and `rpf.protocol.VERSION`), and
`UPDATE_CORPUS=1 cargo test -p rpf-protocol --test protocol` writes the new
`v<N+1>/` while the frozen one stays as it was. Changes between two releases
all land in the one unreleased version; it is frozen when its release is
cut. The container, ledger and addon corpora under `protocol/corpus/` are
validation cases, not wire shapes, and are not versioned.

A version bump that is a pure addition needs no other code: the portal
serves the older version with the same handlers, because the older core
ignores what it does not know and the portal defaults what the older core
does not send. Only a breaking change needs a path of its own.

### What is compatible

The two directions are not symmetric, because only the portal is ever newer.

| Change | In a frame the portal sends | In a frame a game server sends |
|---|---|---|
| Add a field | Compatible: an older core ignores unknown fields | Compatible **only if optional-with-default** (`#[serde(default)]`). A required one makes every older server's frame fail to decode |
| Add a message type, or a variant of a nested enum (`Command`, `CommandOutcome`, `RejectCode`, a record kind, …) | **Not compatible**: an older core refuses an unknown type or variant. Send it only on connections whose protocol has it (below) | Compatible: an older server never sends it |
| Add a config section to `ConfigSnapshot` | Compatible: the core keeps the snapshot whole, sections it does not know included | n/a |
| Add a setting key | Compatible: settings are data, keyed by name ("Names that are schema" in `AGENTS.md`) | n/a |
| Remove, rename or retype a field; make an optional field required; rename a type or variant | **Breaking** | **Breaking** |

A breaking change keeps a path for each older version still in its support
window: the portal decodes that version's frames and encodes its frames to
that version's shapes, choosing by the connection's protocol, or the change
waits until the old version is dropped.

Whatever is new in a version is gated on the connection's protocol, at
the edge and nowhere else. Something the portal sends gets a
`<NAME>_PROTOCOL` constant beside its type, holding the version it is new
in, and the check sits in the one place that sends it: the registry, which
holds each connection and its version, so no caller can forget it. A
command checks `Command::protocol` there, and the registry treats a
connection too old for it as offline. A message a game server sends names
its version in `ServerToPortal::protocol`, exhaustive, so a new one cannot
land without saying which version it is new in; the socket refuses one
newer than its connection's protocol `malformed` before dispatch, so no
handler is reached by it or answers in shapes the connection cannot read.
A refusal code new in a version is turned into one the older connection
knows where the socket writes the reply, or at the handshake for a
`Hello`.

A gate lives only as long as an older version is served. Raising
`MIN_VERSION` to the version a gate names retires it: the constant, its
check and the tests that played the older core go in the same change.
Protocol 2 brought six (`Restarting`, `StaffPermissions`, the `suspended`
and `domain_external` codes, in-game config editing and addons), and all six
went when protocol 1 was dropped, which left every message in every served
version (`Command::protocol` and `ServerToPortal::protocol` are
`MIN_VERSION` throughout) and the mechanism in place for protocol 3.

### How the tests hold it

All in `crates/rpf-protocol/tests/protocol.rs` unless named otherwise.

| Test | What it proves |
|---|---|
| `released_corpora_are_frozen` | No released corpus has changed, and every served older version has one |
| `every_supported_version_is_still_read_and_written` | For every version from `MIN_VERSION` to `VERSION`: each frame a game server on it sends still decodes, and each frame the portal sends it, decoded and written again, still carries every field it had, with the same value. A required field added to a server's frame, or a field removed, renamed or retyped anywhere, fails it |
| `every_field_is_required_or_named_optional` | Every field in the corpus is required unless `OPTIONAL` names it. Making a field optional or required is a decision, not a side effect |
| `server_to_portal_unknown_fields_are_ignored`, `portal_to_server_unknown_fields_are_ignored`, `unknown_fields_in_nested_samples_are_ignored` | An unknown field at any depth of any sample is ignored, and changes nothing |
| `reject_codes_corpus_matches_the_type` | `reject_codes.json` lists every `RejectCode`, which `lua/spec/protocol_spec.lua` decodes inside a `rejected` frame, so the core knows every refusal its version can be sent |
| `unknown_message_types_are_rejected`, `unknown_nested_variants_are_rejected` | An unknown message type, command, outcome or reject code is refused, not misread |
| `missing_fields_are_rejected` | A required field left out is refused, nullable ones included |
| `the_lua_core_is_released_with_the_portal` | The core's release and protocol versions match the portal's |
| `lua/spec/protocol_spec.lua` | The Lua decoder reads the current corpus, ignores unknown fields at every depth, refuses unknown types and missing fields |
| `protocol_versions_outside_the_supported_range_are_refused_with_directions` (`rpf_backend::ws::auth`), `handshake_and_duplicate_instance_are_scoped_and_bounded` (`tests/endpoints/ws.rs`) | The supported range is served, and a `Hello` outside it either way is refused with the upgrade message |
| `lua/spec/client_spec.lua` | The core stops on a `Welcome` naming another protocol |

## Required and optional fields

**Every field is required unless listed below.** A frame without a required
field is refused, on both sides. A nullable field is not an optional one: it
must still be sent, as `null` (`Hello`'s `config_version` and `config_hash`,
a command's or a state change's unchanged fields), because a sender that
left it out is a bug, and defaulting it would hide the bug.

These are **optional-with-default**: a sender may leave them out, and the
receiver takes the default (empty, `false` or `None`).

| Field | Where | Default | Why optional |
|---|---|---|---|
| `domains` | `hello` | Native | Added by K1. A core from before it runs only the native profile, so an absent field means native, never `null`, which is a core with no profile fixed yet |
| `map` | `hello` | `default` | Added by #173. A core from before it places every world record on whatever map it runs, which is what FiveM's unnamed setup, `default`, means |
| `hardware_tokens` | `begin_join` | Empty: none reported | Added by I4 to a frame a game server sends, and left out where the engine has none (Garry's Mod), so a join from a core before it decodes as one with no tokens |
| `types` | `hold` | Empty: claims nothing | Added by J6 to a frame a game server sends, and left out by one that claims nothing, so every hold before it decodes as one that claims nothing |
| `addon_permissions`, `all_addon_permissions` | A `StaffGrant` in `staff_permissions` | Empty, `false` | Added by L4 so linked staff can use installed addon action grants in game. Older captures keep their core flags; the owner grant includes future addon flags |
| `domains` | `welcome` | Native | Added by K1, and left out when native: a native server's `welcome` is the one it was before K1, which is what every portal enforced then |
| `items`, `item_bases`, `item_defaults`, `employers`, `employer_departments`, `employer_jobs`, `new_character`, `paying_accounts`, `addons`, `dialogs` | `ConfigSnapshot` (`config`) | Empty | Sections added after `settings`, so a snapshot from before one still decodes |
| `choices` | A node of a dialog in `dialogs` | Empty | Omitted for a node that ends the conversation; added by L1 |
| `conditions` | A dialog choice | Empty | Omitted for a choice anyone may pick |
| `employer`, `job`, `min_grade`, `on_duty`, `negate` | A dialog choice's condition | `None`, `None`, `None`, `None`, `false` | A job condition names what it tests and leaves the rest out; every condition leaves `negate` out unless it is negated |
| `params` | A dialog choice's `action` | Empty | Omitted for an action that takes none |
| `payroll` | An employer in `employers` | `None` | Omitted when the employer pays no salaries; added by D7 |
| `rank`, `salary` | A job in `employer_jobs` | `0`, `None` | Added by D7; `salary` is omitted for an unpaid job |
| `job` | A character in `held` and `character_created` | `None` | Omitted when the character has no job, so a frame for one re-encodes as it did before D7 |
| `employment` | A character's `StateChange` and `RecordReport` (`state_changed`, `resync`, `release`) | `None`: says nothing of the job | A field added by D7 to frames a game server sends, which a core from before it leaves out; `{"job": null}` is what clears a job |
| `base` | An item in `items` | `None` | Omitted when the item has no base |
| `image` | An item in `items` | `None` | Omitted when the item has no image; added by P3, and ignored by an older core, which keeps the snapshot whole |
| `weapon` | An item in `items` | `None` | Omitted when the item is not a weapon; added by L3 |
| `fivem`, `gmod`, `ammo` | An item's `weapon`, in `items` and in an in-game config change | `None` | A weapon names its weapon on one engine or both, and takes ammo or not |
| `weight`, `size`, `stack_limit` | An item base in `item_bases` | `None` | Omitted when the base leaves it to the item or the defaults |
| `description` | An employer, department or job | Empty | Free text, possibly empty |
| `department` | A job in `employer_jobs` | `None` | Omitted when the job has none |
| `job` | `new_character` | `None` | No default job |
| `data` | A stack in container contents | Empty | Omitted when empty, which is the common case |
| `rotated` | A grid placement in container contents | `false` | Upright is the common case |
| `weight`, `size`, `stack_limit` | An item base in an in-game config change (`config_changes`) | `None` | Left out when the base leaves it to its items and the defaults, as in the snapshot |
| `base`, `weight`, `size`, `stack_limit` | An item in an in-game config change | `None` | Left out when the item takes it from its base |
| `weapon` | An item in an in-game config change | `None` | Left out when the item is not a weapon (L3) |
| `description`, `payroll` | An employer in an in-game config change | Empty, `None` | Free text, possibly empty; no payroll for an employer that pays none |
| `description` | A department in an in-game config change | Empty | Free text, possibly empty |
| `department`, `description`, `rank`, `salary` | A job in an in-game config change | `None`, empty, `0`, `None` | As for a job in the snapshot |

Container contents travel both ways (a hold hands them to a game server, a
state report brings them back); `employment` and an in-game config change's
definitions (E6, new in protocol 2, so no older core sends one) are only
ever sent by a game server, and a character's `job` only by the portal;
`domains` is the handshake's, one in each direction; addon staff grants are
only sent by the portal; everything else in the table is in the config
snapshot, which only the portal sends. `OPTIONAL` in the protocol
tests is the same list as far as the corpus shows it: a snapshot base's
`stack_limit`, `data` and `rotated` are absent from every sample, so the
test cannot see them, and this table is where they are recorded.

The Lua core requires every field of the protocol version it speaks, apart
from what it keeps whole (the config snapshot, container contents and
flags) and a character's `job`, which the portal leaves out for a character
without one. That is safe because a portal serving its version always sends
every field that version has.

### What is not a field

Three shapes on the wire have keys that are not fields, and the unknown-field
rules do not apply inside them:

- **Maps**: the snapshot's `settings` are keyed by setting name. A new key is
  a new setting the receiver keeps.
- **Opaque values**: a setting's value is whatever its setting holds, carried
  as JSON, in the snapshot and in an in-game config change's `set` state
  alike. The Lua core also keeps the whole snapshot, and container contents
  and flags, as received.
- **Variants**: `Gender` is externally tagged, and `{"server_specific": "…"}`
  is exactly one key on both sides. A key beside it is a different value, not
  an unknown field.

## Seeing who is behind

A protocol version can only be dropped once nobody runs it, so who is behind
has to be visible beforehand. `Hello` carries `protocol`, `engine` and
`core_version`, which the handshake validates to a short plain charset, and
the portal reports them three ways, all from the live connections
(`ConnectionRegistry::census`), so they never disagree:

- **Every connection's log lines** carry them, in the `game_socket` span,
  from `game server authenticated` on.
- **The census log**, every 15 minutes (`observability::census`): a line
  `connected game servers by version` per protocol, engine and core version
  with its `servers` count, then a `version census` line with the total, the
  `oldest_protocol` connected, and the `protocol` and `min_protocol` this
  portal serves. Every deployment has it, with or without a scraper.
- **The metric** `rpf_game_servers_connected_by_version{protocol,engine,core_version}`,
  on the portal's metrics endpoint.

The people who can do something about it see it too. A connected server's
page in the portal (its **Game server** card) says when it should upgrade
(`rpf_domain::portal::updates`, H7):

- **Update available**, when the core it reports is an older release than
  this portal's own (`PORTAL_RELEASE`, the workspace version, which a game
  server installs as the release of the same number). It keeps working; the
  notice links the release to install when its owner chooses. A version
  that is not a release (a development build) is left alone.
- **Upgrade needed**, with a date, when the protocol it speaks is in
  `rpf_protocol::SUNSETS`: the versions announced under **Deprecated**,
  each with the earliest day a portal may stop serving it. This is said
  whatever version the core reports, because the protocol is what decides
  whether it is served.

A release that deprecates a protocol adds it to `SUNSETS` with the date
`CHANGELOG.md` announces, and the release that drops it removes it as it
raises `MIN_VERSION`; a compile-time assertion keeps every entry served and
older than `VERSION`. The notice is advice for staff: the core's version is
its own word, and nothing is decided by it.

## The database

The portal migrates its database at startup and refuses to serve if that
fails. sqlx's migrator also refuses a database that has applied a migration
the binary does not carry, so **an older image never starts against a
database a newer one has migrated**, additive or not. A rollback across a
migration is a restore, never the previous tag.
That refusal is kept deliberately: it is what stops an old binary running
against a schema it was not compiled for.

Additivity still matters, for what a migration does to data that is already
there. From 0.1.0 on:

- **A migration is additive by default**: new tables, columns that are
  nullable or have a default, indexes, constraints existing rows already
  satisfy.
- **A one-way door** is a migration that drops, renames or retypes, rewrites
  rows, or deletes them: undoing it needs the backup. It is said so in its
  PR, and listed under its release's **Database** heading in
  `CHANGELOG.md`, which tells the operator to take a restore point before
  deploying. Where it can, it follows an additive release that stopped
  reading the old shape (expand, then contract), so the contract step loses
  nothing the running portal still needs.

### Milestone 1's migrations

Reviewed for 0.1.0. No database was deployed before this release, so a
0.1.0 deployment applies all of them to an empty database, and none of the
one-way doors below has any data to lose. They are recorded so that nobody
mistakes them for a precedent.

| Migration | Verdict | What it does |
|---|---|---|
| `0001_initial` | Baseline | The initial schema |
| `20260925224154_oidc_identity` | **One-way door** | Renames `users.username` to `display_name`; drops and recreates `sessions` (every session ends) |
| `20260925224522_player_accounts` | **One-way door** | Drops `players.primary_identifier` and its unique key; gives legacy rows an unusable password; re-keys `player_identifiers` |
| `20260925225622_drop_password_auth` | **One-way door** | Deletes local (non-OIDC) users and the guilds they own, with everything under them; drops `users.password_hash` |
| `20260925225623_oidc_logins` | **One-way door** | Deletes every session, then adds a required `id_token` |
| `20260926040548_roles` | Additive | Roles and assignments |
| `20260926150000_audit_log` | Additive | The audit log |
| `20260927001829_server_keys` | Additive | Game-server API keys |
| `20260927002209_server_settings` | Additive | Per-server settings |
| `20261002120000_request_log` | Additive | The request log |
| `20261002140000_connection_epoch` | Additive | `servers.connection_epoch`, defaulted |
| `20261004004449_player_server_joins` | Additive | Which servers a player joined |
| `20261004150000_config_versions` | Additive | `servers.config_version` (defaulted) and `config_hash` (nullable) |
| `20261004170000_invites` | Additive | Staff invites |
| `20261004230357_item_catalog` | Additive | Item bases and definitions |
| `20261004230418_player_roster_search` | Additive | `pg_trgm`, a search function and indexes |
| `20261005202804_record_holds` | **One-way door** | Adds revisions and holds (additive), backfills `transactions.client_id` with random ids, and rewrites stored grid flags from the internally tagged form to the adjacently tagged one |
| `20261005211421_bans` | Additive | Bans and identifier blocks |
| `20261006015905_employment_rules` | Additive, tightening | Check constraints on employers, departments and jobs, and the job-department key made composite. No data changes; a row the M1 portal could not write would now be refused |
| `20261006035602_starting_funds` | Additive | `accounts.issuance`, defaulted, and its unique index |
| `20261006063910_warnings` | Additive | Warnings |
| `20261006190259_money_adjustments` | Additive | Money adjustments; two transaction indexes rebuilt with a second column |
| `20261006200144_paying_accounts` | Additive | `accounts.paying`, defaulted, and its unique index |
