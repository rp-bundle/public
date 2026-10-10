# Bridges to existing RP frameworks

A bridge lets RPF run beside an RP framework a server already has (Qbox,
DarkRP, …): the **companion** profile. The framework keeps owning
characters, money, items and jobs; RPF keeps owning player accounts and
login, moderation, the staff portal and addons. A bridge is the one place
the two meet. The design, and why it is shaped this way, is
[`docs/architecture/framework-integration.md`](../../docs/architecture/framework-integration.md).

Each bridge is a package of its own under `lua/bridges/<framework>/`: a
resource on FiveM, an addon on Gmod. It is engine-specific, because it calls
its framework's exports or hooks, and it ships free and open source with the
rest of the game side. No framework name, id or setting appears in Rust, the
protocol, the schema or the portal. The pilots are K3 (#93), Qbox, built
in [`qbox/`](qbox/README.md), and K4 (#94), DarkRP, built in
[`darkrp/`](darkrp/README.md).

## The contract

A bridge reaches the core only through `rpf.bridge` (`rpf.api.bridge`), and
the core reaches it only through the table it registers. Both are described
for the language server in `lua/core/meta/api.lua` (`rpf.api.Bridge`,
`rpf.BridgeDefinition`), which the Lua API reference publishes.

```lua
local ok, err, field = rpf.bridge.register({
  name = "qbox",                               -- [a-z][a-z0-9_]*, for the log
  version = "1.0.0",                           -- the bridge's own
  contract = { major = 1, minor = 0 },         -- rpf.bridge.CONTRACT_MAJOR / _MINOR when written
  provides = { "characters", "money", "inventory", "jobs" }, -- authority
  supports = { "money.balance", "money.debit" },             -- capability
  tested_with = { "1.21" },                    -- framework versions
  running = function() return started, version end,
  start = function(selecting) --[[ report characters already loaded; show
    the selection to each player in `selecting` ]] end,
  stop = function(reason) end,
  money = { balance = ..., debit = ... },
})
```

- **`provides` is authority**: the domains whose records the framework owns.
  It must be exactly the domains the server's profile marks external, or the
  bridge stays inactive and players stay at `registered`, which is the
  server failing closed rather than running with two writers or none.
- **`supports` is capability**: the facade calls the bridge implements, as
  `<domain>.<call>`, each with its function. A call it does not list is
  `refused("unsupported")` without reaching it. Addons ask
  `rpf.<domain>.supports(call)` first. `characters.current` is never listed:
  the core answers it from the lifecycle.
- **Versions.** A new call every bridge must implement, or any other
  breaking change, bumps `CONTRACT_MAJOR`, and the core refuses a bridge of
  another major. A new optional call bumps `CONTRACT_MINOR`: a bridge
  written for an older minor simply does not list it. Bridge, core and
  portal versions are independent.

## The lifecycle

Once the server's profile is fixed and the bridge fits it, the bridge is
active: its `start` runs, and every player logged in to RPF moves to
`character_select`. That move (`players.character_select`) is the bridge's
cue to show the framework's own character selection, and nothing before it
may load a framework character: RPF's login gate (`connecting →
authenticating → registered`) comes first, and the engine adapter holds the
player still server-side until `active`. A framework with one implicit
character per player and nothing to choose (DarkRP) has no selection to
show: its bridge reports the character once the player is at
`character_select` and the framework has their data, and it holds the gate
by keeping every player not yet `active` out of the framework's play
([`darkrp/`](darkrp/README.md#the-gate-held-out-of-play)).

| Report | When | What the core does |
|---|---|---|
| `character_loaded(player, { key, name })` | The framework loaded a character, as the bridge's own login call saw it | The player moves to `active`. `key` is the framework's own (a `citizenid`), opaque, kept on this game server only: never sent to the portal, never logged |
| `character_unloaded(player)` | The framework unloaded it | Back to `character_select` |
| `unavailable(reason)` | The framework cannot be asked (its resource stopped) | Every facade call is `unavailable` without reaching the bridge, and so is `character_loaded`: the player stays where they are |
| `available()` | It can be asked again | Calls reach the bridge again |

On FiveM only the resource that registered the bridge may report for it,
and that resource stopping withdraws the bridge: its players go back to
`character_select`, and new ones wait at `registered` until it registers
again. On Gmod every addon shares one Lua state, so there is no resource
to stop: a bridge registers once, from `Initialize`, through the `rpf`
global, and a map change, which starts a new Lua state, registers it again.

## Answering the core

Reads answer a value, or nil and `not_found` (an account the player does
not have). Commands answer `true`, or nil and a status, and the status must
be true of what the framework did:

- `refused` and a reason (`insufficient_funds`, `no_space`): the bridge
  checked before calling the framework, and nothing changed.
- `unavailable`: it could not ask the framework, and nothing changed.
- `unknown`: it called the framework and cannot say what happened.

**Classify by when, not by what.** Only an answer the bridge can prove came
before any change may be `refused` or `unavailable`. A framework export may
have written before a later step threw, so anything thrown, and anything
else answered, is read as `unknown`: logged for staff with what the command
was, never run again under its op id, never compensated. The core runs each
op id at most once (its journal outlives a restart), so **a bridge never
retries a framework call**, and needs no deduplication of its own. Amounts
reach it already checked: whole, from 1 to `MAX_AMOUNT`.

## The rules

1. **The framework's public API only**: its documented exports, events and
   hooks. Never its database tables, and no SQL of any kind.
2. **No patching**: never replace, wrap or monkey-patch a framework's
   private functions.
3. **No re-triggering framework events.** A bridge may react to one, but
   never fires the framework's own internal events itself (Qbox forbids it).
   One exception: a bridge whose client stands in for a module the
   framework switched off, as the Qbox bridge's selection stands in for
   qbx_core's, sends what that module sends after its own server-side
   login, and nothing else ([`qbox/`](qbox/README.md#the-two-events-the-selection-sends)).
4. **Framework events are notifications.** React to drive the lifecycle;
   never copy an event's payload into RPF state.
5. **Never trust a networked event alone.** A client can fire one. Drive
   `character_loaded` from the bridge's own login call, or corroborate an
   event with the framework's server-side state (Qbox's `GetPlayer(source)`
   and a current `citizenid`).
6. **One writer per record.** On a companion server the framework is the
   only writer of its domains. A bridge writes nothing of RPF's, and RPF
   never falls back to its own modules when the framework is unavailable.
7. **No sale for real money**, through a bridge, the facade or any addon:
   nothing connects to a payment (`AGENTS.md`, "Distribution").
8. **Check your framework on a native server.** `running` is asked when the
   profile is native: a framework running there is a second economy, and
   the core logs an error naming the `domains` setting.

## Proving a bridge

Every bridge runs the shared conformance suite
(`lua/spec/support/bridge_conformance.lua`, `docs/testing.md`) against a
fake of its framework, on every engine the harness boots that its
framework runs on (`platforms`: a FiveM bridge's players are server ids,
so it runs on FiveM and on the mock platform, never on Gmod; a Gmod
bridge's are `Player` entities, so it runs on Gmod and the mock, never on
FiveM). It brings a
kit (`spec.BridgeKit`): a fake of its framework, a driver over that fake
the cases act through (`spec.FrameworkDriver`: load and unload a
character, say which one is loaded, stop and start the framework, make a
call fail part way, run something inside one), and how its own code
registers it. A bridge that is its framework's selection, as the Qbox
bridge is, keeps a player who has not logged in to RPF from loading
anything at all; one that is not leaves the core to refuse the character
and log that the gate is not holding. The gate case holds either way. A
kit whose framework has one implicit character per player and never stops
(DarkRP) says `implicit`, and the steps that need a selection, an unload or
a stop are left out; its own spec covers what stands in for them. The
mock bridge (`lua/spec/support/mock_bridge.lua`, over `mock_framework.lua`)
is the worked example, and the Qbox bridge
([`qbox/`](qbox/README.md), over `spec/support/qbox_fake.lua`) and the
DarkRP bridge ([`darkrp/`](darkrp/README.md), over
`spec/support/darkrp_fake.lua`) are real ones. Then one smoke test on a
real server: an RPF login, a framework character reaching `active`, a debit
through the facade, and the framework's resource restarting mid-session (a
map change, for a framework that is the gamemode).
