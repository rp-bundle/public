# Writing addons

An addon is how you build gameplay on RPF: properties, plants, graffiti, a
taxi meter, anything. You write it in Lua against `rpf.api`, the framework's
public API, and it runs the same on FiveM and Garry's Mod. RPF gives it what
every such system needs and none should write twice: storage that survives
restarts, the portal's pages for staff, permissions, the audit log, money
and items, and the rules that keep a game server's data consistent with the
portal's.

This page is the guide. The decisions behind it are in
[Addons](architecture/addons.md); the complete, typed reference is
[`lua/core/meta/api.lua`](../lua/core/meta/api.lua), which your editor reads
for completion (below). The worked example,
[`lua/examples/acme_tags/`](../lua/examples/acme_tags/), is a small addon
you can run: players spray tags on walls, which fade after a day.

## Getting the API

| Engine | How a script gets `rpf` |
|---|---|
| FiveM | `local rpf = exports.rpf:api()`, in a resource that lists `dependency "rpf"` |
| Garry's Mod | The global `rpf`, once the RPF addon has loaded: read it in a hook such as `Initialize`, since Gmod loads addons' autorun files in name order |

For completion and type checking, add RPF's `lua/core/meta/` to your
language server's `workspace.library`, and annotate the table:
`---@type rpf.Api`.

Nothing in `rpf.api` throws. A call that cannot do what you asked returns
`nil` (or `false`) and a reason, a short string such as `"invalid"`, which
each call's documentation lists. Check it the way you would check any
other result:

```lua
local tag, err, rule = rpf.records.create("acme_tags.tag", fields, { owner = owner })
if not tag then
  print("no tag: " .. err) -- for `invalid`, `rule` says which rule, e.g. { error = "too_long", field = "text" }
end
```

## The manifest

A manifest is a table that declares, and never computes, what your addon
adds: its namespace, release, the API major it was written for, the types
of record it stores, and the permissions staff can grant. The portal checks
it with the same rules the game server does, so a mistake is refused at
registration with the rule it breaks.

```lua
local MANIFEST = {
  namespace = "acme_tags",  -- yours: every name you declare is under it
  version = "1.0.0",        -- your release
  api = 1,                  -- rpf.addons.API when you wrote it
  title = "Tags",
  permissions = { moderate = "Remove any tag" }, -- becomes addon.acme_tags.moderate
  types = {
    tag = {
      schema = 1,             -- move it on every change to `fields`
      authority = "live",     -- game state; "config" for staff-written data
      owners = { "player" },
      fields = {
        text = { type = "string", max_len = 24, required = true },
        spot = { type = "vector3", required = true },
        fades_at = { type = "timestamp", required = true, index = true },
      },
      list = { "text", "fades_at" },
      actions = { create = false, edit = false, delete = "moderate" },
      limit = 500,
    },
  },
}
```

The field kinds, their bounds, the limits, and which changes to a type are
compatible are in [Addons, "The manifest"](architecture/addons.md#the-manifest)
and ["Versions and schema evolution"](architecture/addons.md#versions-and-schema-evolution).
Two things to know from the start:

- **There is no money field, and no item field that holds items.** A price
  is an integer your addon passes to the money calls; a player's money and
  items are moved only through them (Money and items, below).
- **Records are never rewritten for you.** Add fields as optional, nullable
  or defaulted, and a new release installs over the old one with every
  record kept. A breaking change to a type with records is refused: add a
  new type instead.

## Registering, installing, running

```lua
rpf.addons.register(MANIFEST, {
  start = function() --[[ set up: timers, handlers, holds ]] end,
  stop = function(reason) --[[ optional: save what you keep yourself ]] end,
  state = function(state, reason) --[[ optional: every change of state ]] end,
})
```

Registering is not running. The game server proposes your manifest to the
portal; staff holding `addons.manage` install it from the server's
**Addons** page (on a development server, the `addons.auto_install` setting
installs proposals for you). Your `start` runs once the portal has the addon
installed and enabled at exactly the manifest you registered, with
everything you `requires` running. `rpf.addons.state(namespace)` says where
it is and why:

| State | Means |
|---|---|
| `active` | Running: `start` ran |
| `not_installed`, `pending` | The portal has not installed it; `pending` once it has your proposal |
| `mismatch` | The portal installed another release: your files and the portal disagree |
| `disabled` | Staff disabled it |
| `api` | Written for an API major this server does not serve |
| `requires` | Something it requires is not running |
| `failed` | Its `start` threw; tried again on the next config change or registration |

**Set things up in `start`.** A timer, an event handler, an export or an
interaction your addon creates while its code runs belongs to it, and RPF
takes it down when the addon stops (disabled, reloaded, mismatched,
uninstalled), so a restart never leaves two of anything. Code of yours that
runs after its addon stopped (a callback that waited across a disable) is
refused `inactive` if it tries to set something up.

**Reloading is registering again.** A Gmod Lua refresh or a FiveM resource
restart runs your files again; the second registration stops the old code
and starts the new. On FiveM, when your resource stops, your addon is
unloaded with it.

**Errors stay yours.** Every handler runs under `pcall`: one that throws is
logged with your namespace, and a `start` that throws leaves the addon
`failed`. Nothing your addon does can stop a player's login or another
addon.

## Records

A type's records are stored by RPF, shown and edited by staff in the
portal's generic pages, and audited. Every call names the type, and returns
a plain copy: a field with no value is absent.

- **`config` types** are staff's: written in the portal, read here with
  `rpf.records.get(type, id)` and `rpf.records.list(type, query)`.
- **`live` types** are game state, which a game server writes only while
  it **holds** the record. Records your addon creates are held from the
  start; find others with `rpf.records.query` (it asks the portal) and take
  them with `rpf.records.hold`. Let them go with `rpf.records.release`; when
  your addon stops, RPF releases the ones it held for it.

| Call | Does |
|---|---|
| `get(type, id)` | One record; `not_held` for a live one this server does not hold |
| `list(type, { where, owner, order, descending, limit })` | Records here: every config record, or every held live one, filtered (`where = { fades_at = { lt = now } }`, `eq`, `lt`, `lte`, `gt`, `gte`, `prefix`) on any field |
| `query(type, query, callback)` | A page of a live type's records from the portal (indexed fields only; `limit` up to 100, `after` the `next` the last page came with), each with `held` |
| `hold(type, ids, callback)`, `release(type, ids)` | Take and give back up to 64 records |
| `create(type, fields, { owner, id })` | A new live record, held from the start. Mint the `id` yourself if you may retry |
| `update(type, id, patch, { revision, clear })` | Change the fields the patch names; `clear` lists nullable fields to clear; `revision` refuses a write over a change you did not see (`stale`) |
| `delete(type, id, { revision })` | Gone here at once, and at the portal with the next report |
| `batch(ops)` | Several writes, checked together and made all or nothing |

The portal has your changes within about a second, and keeps them if the
game server goes down afterwards; if the portal is unreachable they wait,
on disk, until it is back. Every change to a held record is announced:
`records.created`, `records.changed` and `records.deleted`, with `by` saying
who (`addon`, `staff`, or `portal` when it refused a deletion because
another record refers to the one you deleted, which puts it back).

## Interactions

A request from a player's client reaches only a handler your addon
registered, under its own namespace, never an event the client named:

```lua
-- server
rpf.interactions.register("acme_tags.spray", function(player, payload)
  if type(payload.text) ~= "string" then
    return false, "Write something to spray."
  end
  -- resolve every id in the payload inside this player's scope first
  return true
end)

-- client
rpf.interactions.send("acme_tags.spray", { text = "hello" })
rpf.events.on("interactions.result", function(result) --[[ result.ok, result.reason ]] end)
```

The handler runs only while your addon is active, only for a player who has
logged in, at most 20 times per player every 10 seconds, with a copy of the
payload (plain data, at most 4 KiB). Treat the payload as hostile: a client
can send anything.

## Money and items

Addons move money and items only through one set of calls, which work the
same whoever owns those domains on the server: RPF itself, or (once its
bridges arrive) an existing framework such as Qbox or DarkRP. They take the
player's engine handle and act on the character they have in play.

```lua
local op = rpf.ops.new() -- mint once per purchase, and keep it with the purchase
local ok, status, why = rpf.money.debit(player, "bank", price, "Spray can", op)
if ok then
  rpf.inventory.give(player, "spray_can", 1, rpf.ops.new())
elseif status == "refused" then
  -- nothing changed; `why` says why: "insufficient_funds", "no_account", ...
elseif status == "unknown" then
  -- it may have happened: never grant, never send again under a new op id
end
```

- **Ask first.** `rpf.money.supports("debit")` and its siblings say whether
  a call works on this server. On an RPF server, debits and credits need
  staff to set the `economy.addon_account` setting to the paying account
  your addon's money goes into and comes out of.
- **Name accounts from the list.** `rpf.money.accounts()` gives the names
  (`wallet`, `bank` on an RPF server); make the one your addon uses a
  setting of your own rather than a constant.
- **Retries are safe with the same op id.** A command runs at most once per
  op id; sending it again returns the first answer. An op id is good for a
  day.
- **`unknown` is for staff.** It means the game server cannot tell whether
  the command happened (it stopped mid-way). It is logged, and never run
  again. Do not compensate on your own.

Do not build anything that sells in-game money or items for real money:
the Cfx.re platform rules forbid it, and RPF connects nothing to a payment.

## Timers, exports, the world

- `rpf.time.now()`, `after(ms, fn)`, `every(ms, fn)` and `cancel(id)` run on
  the engine's clock alike.
- `rpf.addons.provide("acme_tags.count", fn)` lets other addons call
  `rpf.addons.call("acme_tags.count", ...)`, which answers
  `true, ...results`, or `false` and why, only while your addon runs.
- `rpf.capabilities()` says which game-world capabilities the engine's
  adapter supports: `position` today (`rpf.world.position(player)`), with
  models, zones and entities to come. Ask before offering something that
  needs one; a call to one the engine lacks says `unsupported`.

## Engines

The API is the same on both engines; what differs is how a script is loaded
and how functions cross into RPF.

- **FiveM.** Your addon is another resource, so every call crosses an
  export: tables are copied, and a function you pass becomes a reference.
  That is why the API names the type in every call and returns copies.
  `rpf.events.on` returns a subscription id there, which `off` takes.
  ox_lib is RPF's dependency on FiveM; an addon for FiveM alone may use it
  directly.
- **Garry's Mod.** Every addon shares one Lua state, and `rpf` is a global.
  Gmod loads autorun files in name order, so read `rpf` in a hook, not at
  load.

## Versions

Three versions meet on a running server: your addon's (its `api` major),
the game server's RPF release (which serves a range of API majors,
`rpf.addons.API_MIN` to `rpf.addons.API`), and the portal's (which checks
manifests). [Compatibility](compatibility.md#addon-api-majors) says how they
move and what each side does when they disagree.

## A checklist

- [ ] The manifest registers without a refusal, and the portal installs it.
- [ ] Everything is set up in `start`; nothing at file load but `register`.
- [ ] Every `rpf.api` call's second return is looked at.
- [ ] Every interaction checks its payload, and resolves its ids in the
      caller's scope.
- [ ] Money and items move only through `rpf.money` and `rpf.inventory`,
      each command with an op id minted once and kept with what it pays for.
- [ ] The addon runs on both engines, or says which it needs.
