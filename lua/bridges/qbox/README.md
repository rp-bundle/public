# The Qbox bridge

K3 (#82). RPF beside [Qbox](https://github.com/Qbox-project/qbx_core) on
FiveM, in the companion profile: qbx_core keeps owning characters, money
and jobs, ox_inventory keeps owning items, and RPF keeps player accounts and
login, moderation, the staff portal and addons. This directory is the
`rpf-qbox` resource. The contract it implements is
[`../README.md`](../README.md).

It targets **qbx_core's own exports**, not its QBCore compatibility layer.
Passing here says nothing about QBCore. It ships in the release's FiveM zip
as `[rpf]/rpf-qbox`, and installing it is
[Installing](../../../docs/installing.md#beside-qbox).

| File | What |
|---|---|
| `fxmanifest.lua` | The resource. Depends on `rpf` and `ox_lib`, but deliberately not on qbx_core or ox_inventory (below) |
| `bridge.lua` | The bridge, free of the engine: everything it reaches is passed in (`rpf_qbox.Engine`), so busted runs this file as it ships |
| `fivem/server.lua` | Builds that engine from FiveM's natives and registers the bridge through `exports.rpf:api()` |
| `fivem/client.lua` | The character selection, on ox_lib's menus |

## Tested with

| Resource | Version |
|---|---|
| qbx_core | 1.24.0 (`tested_with = { "1.24" }`: RPF logs a warning for another) |
| ox_inventory | 2.48.0 |
| ox_lib | 3.40.0 |

These are the versions the fake (`lua/spec/support/qbox_fake.lua`) was
written from, reading their source. `tested_with` names qbx_core's only,
because the contract has one framework version. The layer-5 smoke on a real
Qbox server is #82's checklist.

## What it provides and supports

`provides` is all four domains, `characters`, `money`, `inventory` and `jobs`:
the companion profile.

| Call | Through | Notes |
|---|---|---|
| `money.accounts` | (fixed) | `cash`, `bank`, `crypto`, Qbox's money types. A type an owner added to qbx_core works by name, but is not listed |
| `money.balance` | `GetMoney` | `not_found` for a type qbx_core does not have |
| `money.debit` | `GetMoney`, then `RemoveMoney` | Refused below zero for every account, `bank` included, though qbx_core lets `bank` go negative |
| `money.credit` | `AddMoney` | |
| `inventory.count` | `GetItemCount` | Every stack of the item, metadata or not, as ox_inventory counts with none given |
| `inventory.give` | `CanCarryItem`, then `AddItem` | Asked first because `AddItem` puts what fits of an item that does not stack and still answers true. The count is checked afterwards, and a difference is `unknown` |
| `inventory.take` | `GetItemCount`, then `RemoveItem` | The count is checked afterwards, as for a give |
| `jobs.current` | `GetPlayer(source).PlayerData.job` | `name`, `grade.level`, `onduty` |

- **Every call is checked against the character RPF has in play.** If
  qbx_core has another character loaded for the player, or none, the call
  is `no_character` and nothing is asked.
- **`false` is `refused`.** In qbx_core 1.24 and ox_inventory 2.48, every
  `false` their money and item exports answer comes before the change: a
  validation, an unknown type or item, a money hook's veto (`framework`),
  `dontAllowMinus`, a full inventory. Any other answer is `unknown`, and
  anything thrown the core reads as `unknown` too. A bridge never retries.
- **The `money` item is refused** (`money_item`). It is qbx_core's cash,
  synced into ox_inventory (the `inventory:accounts` convar), so moving it
  is moving money, which goes through `rpf.money` with `cash`. A name is
  checked as the item `Items` resolves it to: ox_inventory 2.48 answers
  `cash` as `money`, so `cash` is refused too.
- **ox_inventory stopping on its own** makes item calls `unavailable`,
  and debits and credits of `cash` too. qbx_core sets cash in ox_inventory,
  as the `money` item, after it has changed the balance, and that throws
  while ox_inventory is stopped. The same goes for any other money type
  `inventory:accounts` names. Balances, and `bank` and `crypto`, keep
  working. qbx_core stopping makes every call `unavailable`.
  Its players go back to `character_select`, since qbx_core loses them with
  its state, and the selection is shown again when it starts.

## The gate

With `useExternalCharacters = true` in `qbx_core/config/client.lua`,
qbx_core shows no selection of its own, and this bridge is the selection.
RPF's login comes first. When a player reaches `character_select`, the
server sends `rpf-qbox:select` and the client lists the player's
characters (`rpf-qbox:characters`, from `SearchPlayers` on the player's own
licences). The client then loads one (`rpf-qbox:load`): the server checks
the player is choosing and that the citizenid is one of theirs, refusing
another licence's as one that does not exist (qbx_core would drop the
player), and only then calls `Login`. A new character goes through
qbx_core's own `createCharacter` callback, so its rules apply: the
character cap, its checks, the cid and the starter items.

**qbx_core does not close its own login path.** `useExternalCharacters` is
read only by its client. Its server still answers
`qbx_core:server:loadCharacter` and `createCharacter` for any client, and
no export or hook lets another resource refuse a login before it happens
(its hooks cover money only). So every load qbx_core makes is checked as
it happens:

- `CreatePlayer` fires `QBCore:Server:PlayerLoaded`, a server event, for
  every character it loads. The bridge reads who is loaded from
  `GetPlayer(source)`, never from the event.
- A character loaded for a player at `character_select` (or `active`) is
  reported to RPF, if it is stored under one of the licences that player's
  connection has. Otherwise another connection asked for it and left while
  `Login` waited, and its server id has gone to someone else, so it is
  logged out. One loaded for a player who has not reached
  `character_select` is **logged out at once** (`Logout`). The log line
  names the likely cause: a client calling qbx_core's callbacks, qbx_core's
  own selection left on, or another character resource.
- A sweep every second does the same with `GetPlayer` for every player not
  yet playing, in case a later qbx_core renames that event.

RPF's lock (`lua/platform/fivem/lock.lua`) holds the player in a routing
bucket of their own, frozen, with chat refused, until `active`. What is
left is qbx_core's own `Logout` delay, about 200 ms, during which another
server script could see a loaded player. Only qbx_core can close that, by
refusing its two callbacks when an external selection is configured.

`QBCore:Server:OnPlayerLoaded` is networked, so a client can send it. Like
every event here, it is only a cue to look at `GetPlayer`. `OnPlayerUnload`
moves the player back to `character_select`. While qbx_core is still
logging them out (`GetPlayer` answers for about 200 ms more), the character
is not reported again and a load is `busy`, instead of a second `Login`,
which qbx_core would drop them for. The sweep shows the selection once
qbx_core has finished. A player has one load in flight at a time, since
qbx_core's search and `Login` both wait on its database, and the bridge
checks again that the player is still choosing after the search.

## The two events the selection sends

Once the network session starts on a server where qbx_core runs, the
client ends the loading screen, as qbx_core's own selection does, so that
RPF's login shows over the game. Qbox's recipe leaves the loading screen
for the selection to end (`loadscreen:externalShutdown`). It turns off
spawnmanager's automatic spawn only when the server first shows the
selection, which happens only while the bridge is active. A server where
the bridge stays inactive keeps its own loading screen and spawning. After
a load, the client does what qbx_core's own selection does after one
(`client/character.lua` in qbx_core 1.24): it spawns the ped (at the
character's last position, or at qbx_core's default spawn for a new one),
ends the loading screen, and sends `QBCore:Server:OnPlayerLoaded` and
`QBCore:Client:OnPlayerLoaded`. qbx_core's client sets `QBX.IsLoggedIn`,
and its server sets the `isLoggedIn` state bag, only from those two, so a
selection that replaces qbx_core's has to send them. They are the only Qbox
events the bridge sends. They go from the client, after the server's own
login, and the bridge's server never takes the networked one as a fact.
For a new character the client also sends
`qb-clothes:client:CreateFirstCharacter`, as qbx_core's selection does: it
belongs to the appearance resource (illenium-appearance, qb-clothing), not
to Qbox, and starts its first-character setup.

## Why not depend on qbx_core

FiveM stops a resource with its dependency and does not start it again.
If `rpf-qbox` depended on qbx_core, `restart qbx_core` would leave the
bridge stopped, and players would wait at `registered`. Instead the bridge
hears `onResourceStop` and `onResourceStart` for qbx_core and reports
`unavailable` and `available`. It does depend on `rpf`: `restart rpf` stops
it, so run `ensure rpf-qbox` after it.

## Proof

- `lua/spec/conformance_qbox_spec.lua`: the shared bridge conformance suite
  (K2), over the fake of qbx_core and ox_inventory, on the real FiveM
  adapter (through the `api` export) and on the mock platform.
- `lua/spec/qbox_spec.lua`: what is particular to Qbox. Loads past the
  gate are logged out, both from the event and from the sweep. A spoofed
  `OnPlayerLoaded` changes nothing. Another licence's character is
  refused. The logout window is covered, and so are ox_inventory alone
  stopping, the `money` item, partial gives, the overdraft, a hook's veto,
  and a native server, as are the selection shown again after a logout,
  and two overlapping loads.
- `lua-language-server` checks `fivem/` against FiveM's natives and ox_lib,
  and `bridge.lua` with the rest of `lua/`.
