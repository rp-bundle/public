# The DarkRP bridge

K4 (#94). RPF beside [DarkRP](https://github.com/FPtje/DarkRP) on Gmod, in
the companion profile: DarkRP keeps owning money and jobs, RPF owns no
characters or items beside it, and RPF keeps player accounts and login,
moderation, the staff portal and addons. This directory is the `rpf_darkrp`
addon. The contract it implements is [`../README.md`](../README.md), and
installing it is [Installing](../../../docs/installing.md#beside-darkrp).

DarkRP is the opposite shape to Qbox: it has no characters and no
persistent item inventory, and it is the gamemode, so it never stops while
the server runs. It ships in the release's Gmod zip as `rpf_darkrp/`, beside
`rpf/`, for `garrysmod/addons/`.

| File | Shipped as | What |
|---|---|---|
| `bridge.lua` | `lua/rpf_darkrp/bridge.lua` | The bridge, free of the engine: everything it reaches is passed in (`rpf_darkrp.Engine`), so busted runs this file as it ships |
| `gmod/autorun.lua` | `lua/autorun/server/rpf_darkrp.lua` | Builds that engine from Gmod's and DarkRP's functions and registers the bridge with the `rpf` global at `Initialize`. Server only: there is no selection to show a client |
| `gmod/meta/darkrp.lua` | (not shipped) | Annotations of the few DarkRP functions the entry point calls, for the language server |

## Tested with

| | Version |
|---|---|
| DarkRP | 2.7.0, master at `5abcf7a` (`tested_with = { "2.7" }`: RPF logs a warning for another) |

That is the source the fake (`lua/spec/support/darkrp_fake.lua`) was
written from. The layer-5 smoke on a real DarkRP server is #94's
checklist; record the version it ran on there, and here.

## What it provides and supports

`provides` is all four domains, `characters`, `money`, `inventory` and
`jobs`: the companion profile.

| Call | Through | Notes |
|---|---|---|
| `characters.current` | (the core, from the lifecycle) | One implicit character per player. `key` is the SteamID64, which DarkRP keys a player's data by; `name` is the `rpname`, or `Nick` while there is none |
| `money.accounts` | (fixed) | `wallet`, DarkRP's one account |
| `money.balance` | `getDarkRPVar("money")` | `not_found` for any other account |
| `money.debit` | `canAfford`, then `addMoney(-amount)` | Refused below zero, though `addMoney` takes any amount |
| `money.credit` | `addMoney(amount)` | |
| `jobs.current` | `getJobTable()` | `name` is the job's `command`, which DarkRP holds unique (the team number depends on load order). `grade` is 0 and `on_duty` true: DarkRP has neither |

- **No inventory call is supported.** DarkRP's only inventory is the
  pocket (`addPocketItem`, `removePocketItem`, `getPocketItems`), a store of
  world entities that lasts a session, not an item inventory the facade
  can address. So `inventory.count` answers nil and `unsupported`, `give`
  and `take` are refused `unsupported` without reaching DarkRP, and the
  bridge never touches the pocket. RPF inventory under DarkRP is K5's.
- **The wallet is read before and after.** `addMoney` answers nothing (or
  `false`, before any change, for an amount it cannot read), and a
  `playerWalletChanged` hook may replace the total it sets. A wallet that
  moved by exactly the amount is `true`; anything else is `unknown`, which
  the core keeps for staff and never runs again. A bridge never retries.
- **Every call is checked against the data DarkRP has loaded.** One for a
  player whose data is not loaded is `unavailable`, and one whose SteamID64
  is not the character RPF has in play is `no_character`.
- **Without DarkRP** (the addon installed on another gamemode), the bridge
  never calls DarkRP's functions: RPF answers addons that DarkRP is
  unavailable, and the console says so once at start.
- **`money.accounts()` and `supports` answer before anyone logs in**, since
  they are about the server, not a player. Every call about a player is
  refused until RPF has them `active` with their character.

## The character

DarkRP sets a player up on join and loads their data (`restorePlayerData`)
from its database, at once on SQLite and whenever the query returns on
MySQL. It has no hook for "loaded". The bridge's cue is the wallet's first
value (`DarkRPVarChanged` for `money`, which DarkRP sets once the data is
in), looked at a tick later because `setDarkRPVar` runs the hook before it
stores the value, with a sweep every second behind it, and it reads "loaded" as the
wallet set and `ply.DarkRPUnInitialized` clear: the field DarkRP sets while
it loads, and which its own `canAfford` and `canChatCommand` read. The
bridge only reads it.

- **Reported only at `character_select`,** that is once the player has
  logged in to RPF. DarkRP's data usually arrives first; the bridge waits,
  and reports it the moment the login is done. Data that arrives later is
  reported when it does.
- **A failed load is never reported.** When DarkRP gives up
  (`DarkRPDataRetrievalFailed`) it plays on with the starting money and
  saves nothing for that player. The bridge keeps them held at
  `character_select`, and logs it once at `error`, since a debit there would
  move money DarkRP will never save. DarkRP can also give up after the data
  was loaded: a new player's first save runs after their wallet is set, and
  its failure takes the load back. A player in play then has their
  character unloaded, and is held again.
- **A changed `rpname` is a rename**, reported on the same key.
- **Nothing else unloads it while the player is connected.** Leaving is
  the usual unload, and the core forgets the character itself as the
  player drops.
  A map change ends the Lua state; on the next map Gmod hands everyone over
  again, DarkRP loads their data again, and they log in again (silently, with
  their remember token).
- **The key never goes in a frame or a log line as the character's.** It is
  the SteamID64, which the portal has anyway as the player's identifier
  (`steam:<SteamID64>`): what stays on the server is that it is the key of
  a DarkRP character.

## The gate: held out of play

There is no character load to defer, so the gate is a hold, built from
Gmod's and DarkRP's own hooks with no patch to DarkRP. **Every player RPF
does not have `active` is held**, from the moment the bridge registers, on
whatever profile: on a native server RPF's own character screen releases
them. Beside RPF's lock (`lua/platform/gmod/lock.lua`: frozen, sandbox
actions refused, chat dropped), a held player is:

| Held from | By | Answer |
|---|---|---|
| The world | `PlayerSpawn`, then `KillSilent` a tick later, once DarkRP's own spawn has run; and a sweep every second | Out of the world, with no death of DarkRP's (no drops, no demotion) |
| Respawning | `PlayerDeathThink` | `false` |
| Team changes | `playerCanChangeTeam`, which DarkRP asks whatever `force` says | `false, "Log in first."` |
| DarkRP's commands | `canChatCommand`, which every command asks, typed in chat or sent as `darkrp <command>` from the console (the F4 menu's job changes and purchases) | `false` |
| Votes | `canVote`, which is all DarkRP's own `vote` console command asks | `false, "Log in first."` |
| Dropping from the pocket | `canDropPocketItem`, which DarkRP's `DarkRP_spawnPocket` message asks | `false, "Log in first."` |
| Salary | `playerGetSalary` | `true, "", 0`, as DarkRP's AFK module does it |
| Voice | `PlayerCanHearPlayersVoice`, since DarkRP's `deadvoice` lets the dead talk | `false, false` |
| Others' commands that name them | `canDemote`, `canWanted`, `canRequestWarrant`, `canRequestHit` | `false, "That player is not playing yet."` |

Once RPF has them `active`, the bridge spawns them (`Spawn`), so DarkRP's
own `PlayerSpawn` gives them their team's model and loadout, and every hook
leaves them to DarkRP again. The server console is never refused.

**What the hold does not cover.** These need DarkRP or another addon to
offer a hook it does not. Every console command and net message DarkRP
2.7.0's server code registers was read for this list (FAdmin, FPP and
FSpectate aside, which are admin tools):

- **DarkRP's tip jar.** Its `DarkRP_TipJarDonate` message checks only that
  the giver can afford it and stands within 100 units of the jar, and asks
  no hook. So a modified client of a held player whose data DarkRP has
  loaded, dead where they joined beside someone's tip jar, can donate from
  their wallet. Refusing their side through `playerWalletChanged` would
  still pay the jar's owner (`payPlayer` is two `addMoney` calls), which
  makes money, so the bridge leaves it. An owner who runs tip jars and
  wants this closed keeps them away from where players spawn.
- **DarkRP's other hookless commands,** none of which moves money or an
  item: answering a question put to the player (`ans`), signing a letter
  (`_DarkRP_SignLetter`), a gesture (`_DarkRP_DoAnimation`), the job model
  they prefer (`DarkRP_preferredjobmodel`), and lookups (`rp_lookup`,
  `rp_getvehicles`).

- **Admin commands.** FAdmin's `_FAdmin` command runs with no hook before
  it, so a player with an admin usergroup can use FAdmin (and ULX, SAM or
  another admin mod) before logging in to RPF, as on any Gmod server. RPF's
  own staff permissions are separate, and still need the login.
- **Other addons.** Their own net messages and console commands are theirs
  to gate. RPF's lock refuses the sandbox actions and chat for them, but an
  addon that acts on a player without asking Gmod is outside any hook.
- **Hook order.** Gmod gives hooks no order, so another addon's hook that
  answers one of these first decides it. For a spawn, the sweep takes the
  player out again within a second; for the others, that addon's answer
  stands.

## Proof

- `lua/spec/conformance_darkrp_spec.lua`: the shared bridge conformance
  suite (K2), over the fake of DarkRP, on the real Gmod adapter (through
  the `rpf` global) and on the mock platform. Its kit is `implicit`, so
  the steps that need a selection, an unload or a framework that stops
  are left out.
- `lua/spec/darkrp_spec.lua`: what stands in for them, and what is
  particular to DarkRP. The hold from join to `active`, whatever spawns the
  player meanwhile, a hook answered first included; data loaded before the
  login, after it, and never; a rename; the team's job; a wallet a hook
  moved by another amount; leaving, and a map change; DarkRP not the
  gamemode, another version, and a native server.
- `lua/spec/release_spec.lua` boots the packaged `rpf_darkrp` beside the
  packaged `rpf`.
- `lua-language-server` checks `gmod/` against the GLua annotations and
  `gmod/meta/`, and `bridge.lua` with the rest of `lua/`.
