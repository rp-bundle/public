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
one-way door, a new environment variable. How to cut a release is in
[Deployment](docs/deployment.md#releasing).

## [Unreleased]

**Protocol:** speaks protocol 2, and serves protocols 1 and 2. Protocol 2
adds the `restarting` notice (below), a character's job (D7), in-game
staff (F9: `link_player`, `staff_action`, `player_linked` and
`staff_permissions`) and the `suspended` reject code (H5); a game server on
protocol 1 is served unchanged, and is simply closed where a protocol 2 one
is told first, is never sent `staff_permissions`, and is refused
`forbidden` where a protocol 2 one is refused `suspended`. A protocol 1
core ignores a held character's `job`, and its reports, which carry none,
keep the job the portal has.

### Added

- The platform operator (H5, #54). Platform admins, made only with
  `rpf-portal platform-admin grant <account>` and separate from every guild
  role, get a console at `/platform` to suspend a guild (its game servers
  are disconnected and refused `suspended`, its players cannot register or
  log in, its portal is read-only for its staff), set its plan (servers,
  player accounts and its game servers' frame rate, which replace the fixed
  limits; billing stays off-platform), open read-only support access for a
  few hours, announced on every page of the guild, and hand a guild to a
  new owner who has lost every sign-in factor. Everything an operator does
  is in the guild's own audit log with their reason
  ([Deployment](docs/deployment.md#the-platform-operator)).
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
  over the delay plus jitter instead of landing together
  ([Deployment](docs/deployment.md#deploys)).
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
  log names the staff account each was taken under
  ([Players](docs/architecture/players.md#staff-links)).

### Database

- `20261009035000_player_links` is additive: player links, link codes and
  failed link attempts.
- `20261008222809_character_jobs` is additive: a character's job, a job's
  rank and salary, and an employer's payroll account, all nullable or
  defaulted.

### Deployment

- New optional environment variables `RPF_SHUTDOWN_NOTICE_SECS`,
  `RPF_SHUTDOWN_RETRY_AFTER_MS` and `RPF_SHUTDOWN_GRACE_SECS`; the defaults
  suit a single process behind a proxy. The orchestrator's kill timeout must
  exceed the first plus the third, or it ends the drain early.

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

[Unreleased]: https://github.com/Sampleeeee/rp-framework/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Sampleeeee/rp-framework/releases/tag/v0.1.0
