# Writing addons

An addon is how you build gameplay on RPF: properties, plants, graffiti, a
taxi meter, anything. You write it in Lua against `rpf.api`, the framework's
public API, and it runs the same on FiveM and Garry's Mod. RPF gives it what
every such system needs and none should write twice: storage that survives
restarts, the portal's pages for staff, permissions, the audit log, money
and items, and the rules that keep a game server's data consistent with the
portal's.

This page is the guide. It starts with what RPF provides and what it
leaves to you, then walks through building an addon end to end, then
covers each part in turn. The decisions behind it are in
[Addons](architecture/addons.md). The complete, typed reference is the
[Lua API reference](luadoc/docs/index.md), generated from
[`lua/core/meta/api.lua`](../lua/core/meta/api.lua), which your editor reads
for completion (below). The example addons are in every release's addon
kit, ready to install, and none is installed for you (below).

## What RPF provides, and what it leaves to you

RPF is a framework for building an RP server, not a server that comes
ready to play. A fresh install has player accounts, characters, money,
items and the staff portal. It has no shop, NPC, property, persistent prop,
vehicle or job of its own. Nothing on that second list has to be installed
on any server: you build what yours needs as addons, or take an example.

**Built in, on a server in the native profile** (RPF owns every domain):

| Service | What it does | How an addon reaches it |
|---|---|---|
| Player accounts and login | A player's account in your community, its password, the login screen, bans, kicks and warnings | Through `rpf.players` and the `players.*` events; never the password |
| Characters | The character screen, a player's characters (as many as staff allow), the one in play | `rpf.characters.current(player)` |
| Money | Accounts per character (`wallet` and `bank` unless staff set other starting accounts), every move a ledger entry staff can read | `rpf.money`, with op ids; `rpf.commerce.exchange` with items |
| Items | The item catalog staff keep in the portal, and each character's containers | `rpf.inventory`, `rpf.commerce.exchange` |
| Jobs | Employers, departments, jobs and ranks staff configure. A new character starts in the server's default job if staff set one, and in none otherwise | `rpf.jobs.current(player)` |
| Staff | The portal, its roles and permissions, the audit log, and in-game staff for players linked to a staff account | `rpf.staff.can(handle, permission)`; the `permission` rule on an interaction |
| Addon storage | Your types' records, kept across restarts, held and replicated, shown and edited on generic portal pages, audited | `rpf.records` |
| The world | Positions and routing buckets, and placing your types' peds and objects | `rpf.world`, a type's `world` |
| Interactions and UI | The interaction menu (**E** on FiveM, `rpf_interact` on Gmod), ox_target and qb-target where present, notifications, menus, input dialogs and progress bars | `rpf.interactions`, `rpf.ui` |

On a server in the **companion** profile, beside Qbox or DarkRP, that
framework keeps characters, money, items and jobs. The same `rpf.characters`,
`rpf.money`, `rpf.inventory` and `rpf.jobs` calls reach it through its
bridge, and `supports(call)` says what it offers ([Installing](installing.md#beside-qbox)).

**What the examples supply.** They ship in each release's addon kit
(`rpf-addon-kit-<version>.zip`), and none is installed or ensured for you.
You copy one in, ensure it, and staff install the manifest it proposes,
exactly as for an addon of your own. None creates records when it starts
or ships coordinates: staff place what needs placing in the portal, and
players make the rest in play.

| Example | The gameplay it adds | What it does not |
|---|---|---|
| [`acme_notes`](../lua/examples/acme_notes/) | Notes players pin where they stand, which anyone nearby reads and which their author or staff take down. The walkthrough below builds it | Anything else: it is the smallest addon that uses every step |
| [`acme_tags`](../lua/examples/acme_tags/) | Tags players spray, which fade after a day; players list and scrub their own | No placed entity: a tag is a position and text |
| [`acme_garden`](../lua/examples/acme_garden/) | Plants placed in the world, which grow while the server runs, need watering, and are harvested or wither | A harvest pays nothing: an addon that paid out an item would use an exchange |
| [`acme_shop`](../lua/examples/acme_shop/) | Shopkeepers staff place, listings staff price, limited stock, sales and buy-backs as exchanges | No stock of its own until staff create it; no counter until staff place one |
| [`acme_property`](../lua/examples/acme_property/) | Properties staff create and players buy in one exchange, and doors their owners lock | No door of its own to move: a server's door script asks whether one is locked. Ownership is per player account, not per character |


## Getting the API

| Engine | How a script gets `rpf` |
|---|---|
| FiveM | `local rpf = exports.rpf:api()`, in a resource that lists `dependency "rpf"` |
| Garry's Mod | The global `rpf`, once the RPF addon has loaded: read it in a hook such as `Initialize`, since Gmod loads addons' autorun files in name order |

For completion and type checking, add the addon kit's `meta/` (RPF's
`lua/core/meta/`) to your language server's `workspace.library`, and
annotate the table: `---@type rpf.Api`.

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

## Walkthrough: a new type, end to end

This takes you from an empty folder to an addon players use and staff
moderate in the portal, without changing RPF: `acme_notes`, notes players
pin where they stand. Each step adds part of its files, and
[`lua/examples/acme_notes/`](../lua/examples/acme_notes/) (in the addon kit
as `fivem/[rpf-examples]/acme_notes` and `gmod/acme_notes`) holds the
finished ones, so you can compare as you go. The sections after the
walkthrough are the reference for each call it uses.

### 0. Before you start

- A development server connected to the portal ([Installing](installing.md)),
  and your own community on the portal, where you hold every permission.
- On the server's **Settings** page, turn on `addons.auto_install`, so the
  server installs your manifest each time you change it. Leave it off on a
  server players use: there, staff review each proposal. It never installs
  a breaking change, which always needs a person.
- From the release, `rpf-addon-kit-<version>.zip`. Its `meta/` goes in your
  language server's `workspace.library`, for completion and type checks.

### 1. A folder per engine

The addon's own code is three engine-neutral files: `manifest.lua`,
`server.lua` and `client.lua`. Each adds to one global table named after
the addon. Around them, each engine needs a small entry point that gets
`rpf` and starts the server half.

On FiveM, a resource. `fxmanifest.lua`:

```lua
fx_version("cerulean")
game("gta5")
lua54("yes")
dependency("rpf")
shared_script("manifest.lua")
server_scripts({ "server.lua", "fivem/server.lua" })
client_scripts({ "client.lua", "fivem/client.lua" })
```

and `fivem/server.lua`:

```lua
local rpf = exports.rpf:api() ---@type rpf.Api
assert(acme_notes.start_server(rpf))
```

On Garry's Mod, an addon: the three files under `lua/acme_notes/`, and an
autorun file, `lua/autorun/acme_notes.lua`, that includes them on each
side and starts the server half at `Initialize`, when `rpf` is there
([`gmod/autorun.lua`](../lua/examples/acme_notes/gmod/autorun.lua)).
Gmod mounts every addon's `lua/` over one tree, so keep to that shape: one
autorun file, named after your addon, and everything else under
`lua/<your addon>/`. Two addons shipping the same path collide, and only
one of the files loads.

### 2. Declare the type

`manifest.lua` declares what the addon stores. Start at release 1.0.0,
schema 1:

```lua
acme_notes = acme_notes or {}
acme_notes.TYPE = "acme_notes.note"
acme_notes.MANIFEST = {
  namespace = "acme_notes",
  version = "1.0.0",
  api = 1,
  title = "Notes",
  permissions = { moderate = "Edit and take down any note" },
  types = {
    note = {
      schema = 1,
      authority = "live",
      owners = { "player" },
      hold = "server",
      title = "Note",
      fields = {
        text = { type = "string", max_len = 120, required = true },
        spot = { type = "vector3", required = true, read_only = true },
        bucket = { type = "integer", min = 0, max = 65535, default = 0, read_only = true },
        model = { type = "json", max_bytes = 256, engine = true, hidden = true,
                  default = { fivem = "prop_notepad_01", gmod = "models/props_c17/paper01.mdl" } },
        pinned_at = { type = "timestamp", required = true, read_only = true, index = true },
      },
      list = { "text", "pinned_at" },
      actions = { create = false, edit = "moderate", delete = "moderate" },
      limit = 1000,
      world = { kind = "object", position = "spot", bucket = "bucket", model = "model" },
    },
  },
}
```

Each choice, and why:

- **`authority = "live"`**: notes are game state the server writes. A type
  staff write (prices, NPCs they place) is `"config"`.
- **`owners = { "player" }`**: each note belongs to the player who pinned
  it, whichever character they were playing.
- **`hold = "server"`**: the server holds every note while it runs, so every
  note is placed and readable whether or not its author is on.
- **`read_only`** fields have no input on the portal's form: where a note is
  and when it was pinned are the game's to say. `hidden` keeps the model off
  the portal's pages altogether.
- **`engine = true`** lets one field hold a value per engine: the same note
  record is a notepad on FiveM and a sheet of paper on Gmod (step 9).
- **`world`** has RPF place each note as an object, in its routing bucket,
  while the server holds it, and remove it when it goes.
- **`permissions`** declares `moderate`, which becomes
  `addon.acme_notes.moderate`; **`actions`** gives staff with it the edit
  and delete forms. With `create = false` nobody makes notes in the portal.
  Every installed addon also has `addon.acme_notes.view`, which `view`
  takes unless you name another.
- **`limit`** caps the records a server keeps of the type, so no player can
  fill the database.

### 3. Register, and install the proposal

`server.lua` registers the manifest, and sets everything else up in
`start`:

```lua
function acme_notes.start_server(rpf)
  return rpf.addons.register(acme_notes.MANIFEST, {
    start = function()
      -- step 5 registers the interactions here
    end,
  })
end
```

Start the server (`ensure acme_notes` on FiveM, after `ensure rpf`). The
game server proposes the manifest to the portal. On the server's
**Addons** page the proposal shows what installing it does: one type, its
fields, and one new permission. A manifest the portal refuses shows the
rule it breaks, and the console has the same line. With `auto_install` on
it is installed already; otherwise press **Install**. `start` runs once the
portal has exactly this manifest installed, and `rpf.addons.state("acme_notes")`
says `active`. If it says something else, its second value says why
([Registering](#registering-installing-running)).

### 4. Make records, and query them

A player's client asks for a note, and the server makes it. `pin` checks
the payload, which is whatever the client sent, then counts the player's
notes and makes one where the server says the player stands:

```lua
function acme_notes.pin(rpf, player, payload)
  if type(payload.text) ~= "string" or payload.text == "" then
    return false, "Write something on the note."
  end
  local mine, err = rpf.records.list(acme_notes.TYPE, { owner = { kind = "player", id = player.player_id } })
  if not mine then
    return false, "The board is closed now (" .. tostring(err) .. ")."
  end
  if #mine >= 3 then
    return false, "Take one of your notes down first."
  end
  local spot, where = rpf.world.position(player.handle)
  if not spot then
    return false, "You cannot pin a note here (" .. tostring(where) .. ")."
  end
  local note, why, rule = rpf.records.create(acme_notes.TYPE, {
    text = payload.text,
    spot = spot,
    bucket = rpf.world.bucket(player.handle) or 0,
    pinned_at = rpf.time.now(),
  }, { owner = { kind = "player", id = player.player_id } })
  if not note then
    if why == "invalid" and rule then
      return false, "Not that note (" .. tostring(rule.field) .. ": " .. tostring(rule.error) .. ")."
    end
    return false, "It would not stick (" .. tostring(why) .. ")."
  end
  return true
end
```

Nothing here validates the text's length: the type's definition does, and
the create answers `invalid` with the rule (`{ field = "text", error =
"too_long" }`). The portal has the note within about a second, and it shows
on the server's data page for **Note**. `rpf.records.list` reads what this
server holds, filtered by owner or any field (`where = { pinned_at = { gt
= since } }`). For records it does not hold, `rpf.records.query` asks the
portal, on indexed fields, a page at a time ([Records](#records)).

### 5. Attach interactions

Register the handlers in `start`, so they go when the addon stops:

```lua
start = function()
  local reach = 2 -- metres, on every engine (step 10)
  assert(rpf.interactions.register("acme_notes.pin", function(player, payload)
    return acme_notes.pin(rpf, player, payload)
  end))
  assert(rpf.interactions.register("acme_notes.read", function(player, _, target)
    local fields = target.record.fields
    rpf.ui.notify(player.handle, { title = "A note", text = fields.text })
    return true, { text = fields.text }
  end, { target = acme_notes.TYPE, label = "Read the note", distance = reach }))
  assert(rpf.interactions.register("acme_notes.take_down", function(player, _, target)
    return acme_notes.take_down(rpf, player, target.record, false)
  end, { target = acme_notes.TYPE, label = "Take your note down", distance = reach }))
end,
```

`pin` has no target: the note goes where the player stands. `read` and
`take_down` are **aimed** at a note. Before either handler runs, the server
checks that the note the client named is in the player's bucket and
within `reach`, and hands the handler the record. Players get both on the
interaction menu (**E**, `rpf_interact`) when they stand at a note, and on
ox_target or qb-target where the server runs one. That needs no client
code at all. `take_down` checks that the note is the player's own. Another
player's note is refused, and so is a note that is not there: an id from a
client is never trusted.

The client asks to pin, from a command and an `rpf.ui.input` dialog
([`client.lua`](../lua/examples/acme_notes/client.lua)):

```lua
rpf.interactions.request("acme_notes.pin", { text = text }, function(ok, reason)
  tell(ok and "Pinned." or tostring(reason))
end)
```

`fivem/client.lua` binds it to `/note`, and the Gmod autorun file to the
`note` console command. In game: `/note meet here`, then **E** at the note.

### 6. Grant the permission

On the community's **Roles** page, give a role `addon.acme_notes.moderate`
on this server (or guild-wide), and give the role to a staff member.
Addon flags are granted, inherited and checked exactly as RPF's own.
Staff who hold it see the edit and delete forms on a note's page, and
staff who hold only `addon.acme_notes.view` see the notes and nothing
more.

The same flag works in game, for a player whose account is linked to a
staff account (Staff links, in the portal). An interaction's `permission`
rule offers it only to them:

```lua
assert(rpf.interactions.register("acme_notes.remove", function(player, _, target)
  return acme_notes.take_down(rpf, player, target.record, true)
end, { target = acme_notes.TYPE, label = "Remove the note (staff)", distance = reach, permission = "moderate" }))
```

`rpf.staff.can(player.handle, "addon.acme_notes.moderate")` asks the same
in your own code. A staff member gets their link code on the portal's
in-game account page and enters it with the command RPF registers itself,
`/rpflink <code>` in chat or `rpflink <code>` in the console, so your addon
needs nothing for it. If you want your own command, call
`rpf.staff.link(handle, code)` from it: the code is a credential, so never
log it or echo it back to the player.

### 7. Inspect and edit in the portal

The **Note** data page lists every note with the `list` columns, filters
on the indexed `pinned_at` and the owner, and links each note's page:
every field not `hidden`, its owner, revision, and which server holds it.
A staff member with `moderate` edits the text there. While the server
holds the note, the edit goes to it as a command. The server applies it
and reports back, and your code hears `records.changed` with `by =
"staff"`. While the server is down holding it, the edit is refused rather
than queued. Every staff write is in the audit log under their name.

### 8. Change the schema

Release 1.1.0 lets players choose a colour. Add the field with a default,
and move the type's `schema` and the addon's `version`:

```lua
version = "1.1.0",
-- …
note = {
  schema = 2,
  fields = {
    -- …
    colour = { type = "enum", values = { "white", "yellow", "pink" }, default = "white" },
  },
  list = { "text", "colour", "pinned_at" },
},
```

`pin` passes `colour = payload.colour` to the create, so the definition
refuses a colour it lacks. Move `version` in `fxmanifest.lua` too, then
restart the resource (a Lua refresh on Gmod). The server proposes 1.1.0,
the Addons page shows it as an upgrade adding one field, and installing it
keeps every note. Nothing is rewritten: a note pinned under 1.0.0 reads
`colour = "white"` until something writes it, which stores it at schema 2.

That works because the change is **compatible**: a field that is optional,
nullable or defaulted, a wider bound, a new enum value. A **breaking**
change to a type with records (removing or retyping a field, a new
required field with no default, a narrower bound) is refused at install,
with the first breaking change named. Make it a new type instead
(`acme_notes.note2`), and move the records over in your own code with
`list`, `create` and `delete`, a batch at a time. Installing an older
release never lowers a schema, so rolling back loses nothing
([Addons, "Versions and schema evolution"](architecture/addons.md#versions-and-schema-evolution)).

### 9. Retries

Every request crosses a network, and an answer can be lost. Write each
handler so that a second attempt does no harm:

- **An interaction the client sends again** after `timeout` reaches the
  server again, so make sure a repeat cannot do the thing twice. An aimed
  interaction is safe by its rules: a take-down sent again after the first
  worked names a note that no longer resolves, and is refused `not_found`
  before your handler runs. `pin` has no target, so a pin sent twice makes
  two notes, both inside the player's cap. Where a duplicate would matter,
  check for it in the handler before you make anything.
- **A write over a change you did not see.** `delete` (and `update`) with
  `{ revision = note.revision }` is refused `stale` if the note changed
  since you read it (staff edited it in the portal, say), and `not_held`
  if it is no longer here at all. `take_down` then reads the note again.
  If the note is still there, it checks again that the player may take it
  down and tries once more:

  ```lua
  function acme_notes.take_down(rpf, player, note, anyone)
    for _ = 1, 2 do
      if not anyone and not owns(player, note) then
        return false, "That note is not yours."
      end
      local done, why = rpf.records.delete(acme_notes.TYPE, note.id, { revision = note.revision })
      if done then
        return true
      end
      if why ~= "stale" and why ~= "not_held" then
        return false, "It would not come off (" .. tostring(why) .. ")."
      end
      local now = rpf.records.get(acme_notes.TYPE, note.id)
      if not now then
        return false, "That note is gone."
      end
      note = now
    end
    return false, "Someone is changing it; try again."
  end
  ```

- **A create** happens on the game server and answers at once: it made the
  record or it did not, and the portal gets it with the next report, which
  RPF resends until the portal has it. If you mint the record's `id`
  yourself (`opts.id`, to name it somewhere first), a second create with
  that id answers `conflict` when the first one made it. Read it with
  `get` then, rather than making another.
- **Money and items** move with an op id minted once per purchase and kept
  with it. Sending again with the same id never moves anything twice
  ([Money and items](#money-and-items)).

### 10. Engine-specific metadata

The record is the same on both engines, but some values in it are not:

- **Models.** A field with `engine = true` holds one value per engine,
  `{ fivem = "prop_notepad_01", gmod = "models/props_c17/paper01.mdl" }`,
  and RPF places the one for the engine it runs on. Staff can change both
  in the portal.
- **Distances.** Write them in metres. An interaction's `distance` and a
  zone's `radius` are metres on both engines, and the target a handler gets
  reports its `distance` in metres. Positions are the engine's own units
  (metres on FiveM, about 39 to the metre on Gmod), so for a distance you
  measure yourself, `rpf.world.units(metres)` gives the engine's units and
  `rpf.world.metres(units)` takes you back. You never test `rpf.engine`.
- **What the engine can do.** `rpf.capabilities()` says which world and UI
  calls this engine supports. Ask before offering something that needs
  one: a call to one it lacks says `unsupported`.
- **Routing buckets.** A note stores the bucket it was pinned in, and RPF
  places it, and lets players reach it, only in that bucket.

### 11. Ship it

An addon is its files: a zip of the resource folder, or of the Gmod
addon. Nothing in it should name a portal, an API key, a community or a
place on a particular map. The server's owner sets the key in their
`server.cfg`, and staff place whatever needs a place in the portal.
Whoever installs your addon copies the folder in, ensures it, and their
staff review the manifest it proposes, as on your server.

What a test without a game client cannot show, and what to try in game:
the interaction menu at a note, ox_target on the placed object, the
notification with its text, and the dialog `/note` opens.

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
      hold = "server",        -- RPF holds every tag while the server runs
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

### Things in the world

If your records are places in the game world (an NPC, a prop, a spawn
point, a zone), say which fields hold where they are with `world`. It adds
no field, and the portal then shows each record's placement and lets staff
move it with the usual form:

```lua
greeter = {
  schema = 1,
  authority = "config",
  fields = {
    spot = { type = "vector3", required = true },
    heading = { type = "number", default = 0 },
    model = { type = "json", engine = true, required = true },
    line = { type = "string", max_len = 120, required = true },
  },
  world = { kind = "ped", position = "spot", heading = "heading", model = "model" },
},
```

`kind` is `ped` or `object` (placed for you, so it needs a `model`),
`point` (nothing placed) or `zone` (needs a `radius` field, in metres). `bucket` and
`visible` name an integer and a boolean field when you want them, and
`map` an indexed string field (`map = { type = "string", index = true,
nullable = true }`) saying which map a record is on: Gmod servers switch
maps, and a record placed on `rp_downtown` should not stand in a wall on
`rp_evocity`. A record whose map is null is on every map, as is every
record of a type without one, so give a type a `map` whenever its records
belong to one place. For a record your addon creates in game,
`rpf.world.map()` is the map it is made on. A model
field marked `engine = true` can hold one model per engine, `{ fivem =
"a_m_y_business_01", gmod = "models/Humans/Group01/male_02.mdl" }`, so the
same record works on both. Staff then place them in the portal, and RPF
keeps a `ped` or `object` record placed for you while your addon runs:
one entity each, moved, hidden and removed as staff change the record,
and gone when your addon stops. `rpf.world.placed(type, id)` gives the
entity's ref, and `rpf.world.entity(ref)` tells you which record an entity
a client names is. The rules are in
[Addons, "World definitions"](architecture/addons.md#world-definitions).

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
  start. Which others are held, and when, is the type's `hold`, and RPF
  does the holding:
  - `hold = "server"`: every record, whoever owns it, for as long as the
    server runs. RPF takes them back after a restart, and picks up one
    staff created in the portal within a minute. Use it for anything that
    changes on its own: plants growing, printers printing, tags fading.
  - `hold = "owner"`: a player's records while they are on the server, a
    character's while it is in play. Use it for things only their owner
    uses: a player's own settings or a character's stash of notes.
  - Neither: you hold what you need. Find records with `rpf.records.query`
    (it asks the portal), take them with `rpf.records.hold`, and let them
    go with `rpf.records.release`. When your addon stops, RPF releases
    what you held this way.

  If staff disable your addon, RPF releases all of its records with their
  final state. A record nobody holds is still stored, and staff can still
  edit it in the portal. The details are in [Addons, "Live records: the
  lifecycle"](architecture/addons.md#live-records-the-lifecycle-j6).

| Call | Does |
|---|---|
| `get(type, id)` | One record; `not_held` for a live one this server does not hold |
| `list(type, { where, owner, order, descending, limit })` | Records here: every config record, or every held live one, filtered (`where = { fades_at = { lt = now } }`, `eq`, `lt`, `lte`, `gt`, `gte`, `prefix`) on any field |
| `query(type, query, callback)` | A page of a live type's records from the portal (indexed fields only; `limit` up to 100, `after` the `next` the last page came with), each with `held` |
| `hold(type, ids, callback)`, `release(type, ids)` | Take and give back up to 64 records |
| `create(type, fields, { owner, id })` | A new live record, held from the start. With an `id` you minted, a second create answers `conflict` once the first made it (Retries, in the walkthrough) |
| `update(type, id, patch, { revision, clear })` | Change the fields the patch names; `clear` lists nullable fields to clear; `revision` refuses a write over a change you did not see (`stale`) |
| `delete(type, id, { revision })` | Gone here at once, and at the portal with the next report |
| `batch(ops)` | Several writes, checked together and made all or nothing |

The portal has your changes within about a second, and keeps them if the
game server goes down afterwards; if the portal is unreachable they wait,
on disk, until it is back. Every change to a held record is announced:
`records.created`, `records.changed` and `records.deleted`, with `by` saying
who (`addon`, `staff`, or `portal` when it refused a deletion, which puts
the record back). A refusal's `reason` is the portal's own code, to branch
on: `referenced` when another record refers to the one you deleted, or what
refused the report it was in (`malformed` when another record's change in
it was not valid, for one), and `refused` when you deleted several records
at once and the portal says one of them is referenced without saying which.
`detail` is the portal's sentence, for your log; don't show it to players.

### Records that keep time

A timer ends when the server stops; a record does not. Keep time in the
record's fields, never in a timer, and let a timer only read it:

- **Something that happens at a moment** (a tag that fades after a day)
  stores the moment, `fades_at = rpf.time.now() + DAY`, and a timer checks
  it against `rpf.time.now()`. It happens on time even across a restart.
- **Something that happens only while in play** (a plant that grows while a
  server holds it) stores when it last counted, and each tick adds what
  passed, bounded so a server that was down for a week does not apply a
  week at once:

```lua
local spent, now = rpf.time.elapsed(plant.fields.ticked_at, 5 * 60000) -- at most five minutes
local ticks = math.floor(spent / TICK)
if ticks > 0 then
  rpf.records.update("acme_garden.plant", plant.id, {
    grown_ticks = plant.fields.grown_ticks + ticks,
    ticked_at = now - (spent - ticks * TICK), -- keep the part of a tick not yet counted
  }, { revision = plant.revision })
end
```

`lua/examples/acme_garden/` is a whole addon built this way: placed in the
world, watered and harvested through interactions, growing on its own
clock, and upgraded with a new field without losing a plant.

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

To hear the answer where you asked, and to send data back, use `request`:
the handler answers `true` and a table, and the client's callback gets it.
An id that came from a client is resolved inside the player's scope, and
"not yours" is the same answer as "not there":

```lua
-- server
rpf.interactions.register("acme_tags.scrub", function(player, payload)
  local tag = type(payload.id) == "string" and rpf.records.get("acme_tags.tag", payload.id)
  if not tag or tag.owner.id ~= player.player_id then
    return false, "No such tag of yours."
  end
  local deleted, why = rpf.records.delete("acme_tags.tag", tag.id)
  if not deleted then
    return false, "It would not come off (" .. tostring(why) .. ")."
  end
  return true, { scrubbed = tag.fields.text }
end)

-- client
rpf.interactions.request("acme_tags.scrub", { id = id }, function(ok, result)
  print(ok and ("Scrubbed " .. result.scrubbed) or ("No: " .. result))
end)
```

The callback runs once: with the handler's answer, or `false` and
`timeout` when none came in 10 seconds. The other refusals are `unknown`
(nothing registered by that name), `inactive`, `invalid`, `failed` (the
handler threw, or answered data that is not plain), `too_large` (data past
16 KiB), `too_many` and `not_logged_in`. On FiveM a request travels over
ox_lib's `lib.callback`, and it still reaches only the handler you
registered.

### Aiming at something in the world

When an interaction is about a thing in the world (talk to this NPC, read
this tag, use this ATM), give it **rules**, and the server checks the
target the client names before your handler runs. Your handler gets the
target already resolved:

```lua
-- server: greeters are a world-backed config type staff place in the portal
rpf.interactions.register("acme_npcs.talk", function(player, payload, target)
  return true, { line = target.record.fields.line }
end, {
  target = "acme_npcs.greeter", -- a world-backed type (or { models = { "prop_atm_01" } })
  label = "Talk",               -- what the menu and ox_target show
  distance = 2.5,               -- how near, in metres on every engine; 3 unless you say
  cooldown = 2000,              -- ms between one player's uses
  permission = "boss",          -- optional: an addon permission the player holds as linked staff
  check = function(player, target) return true end, -- optional: your own test, `false, reason` refuses
})
```

Before the handler runs, the server checks that the player is in the
world, holds the permission, is past the cooldown, and that the target is
a visible record of that type in the player's bucket within `distance`
metres (inside a zone's radius, also in metres), or an entity of one of the
models in their bucket within `distance`. Then it runs your `check`. A missing, hidden,
other-bucket or other-type target is `not_found` whatever the reason, and
one out of reach is `too_far`. The client never decides any of it.

The same rules decide what a player is **offered**. The menu and ox_target
list an interaction only where every rule passes, your `check` included,
which the server runs as it lists. So a refusal you can tell in advance
belongs in `check`, not in the handler: a property that is sold, a door
only its owner may lock, a note only its author may take down. The
handler still gets the request only after `check` passed again.

```lua
-- server: offered only on a lot that is for sale, to someone who does not own it
rpf.interactions.register("acme_property.buy", function(player, payload, target)
  return acme_property.offer(rpf, player, target)
end, {
  target = "acme_property.property",
  label = "Buy this property",
  check = function(player, target)
    local fields = target.record.fields
    if fields.holder == player.player_id then return false, "You own it already." end
    if fields.holder or not fields.for_sale then return false, fields.name .. " is not for sale." end
    return true
  end,
})
```

Because `check` runs whenever a nearby player opens the menu or aims at
the target, as well as for the request, keep it quick and make it only
read: never write a record, take money or show a UI from it. The server
runs at most 32 checks for one listing, nearest first, and starts none
after 2 seconds, so a check that waits on something slow (a database, an
HTTP call) delays the menu and may leave options out. A check that throws
is logged and its option is not offered.

On the client you usually write nothing: players press **E** on FiveM
(`rpf_interact` on Gmod) for a menu of everything near them they may use,
and on a FiveM server with ox_target or qb-target your rule also appears on
the peds and objects RPF placed for the type (and on the models). For your
own UI, `rpf.interactions.nearby(callback)` gives the same list, and you
send a pick with `rpf.interactions.request(name, { target = { id = id } },
callback)`; an entity is `{ target = { ref = ref } }`, its network id on
FiveM and its index on Gmod.

## UI

What a player sees: notifications, a menu to pick from, an input dialog and
a progress bar. There are two ways to show them.

**`rpf.ui`, for an addon that runs on both engines.** One call looks right
everywhere: RPF builds it on ox_lib on FiveM and in Derma on Garry's Mod.
It holds what an addon for both engines needs, not all of ox_lib. Every
call takes plain tables and a callback, and returns `true` once shown or
`nil` and why:

```lua
-- client: tell the player, ask them something, show a bar
rpf.ui.notify("Sprayed.")
rpf.ui.input({
  title = "Spray a tag",
  fields = {
    { name = "text", label = "Text", required = true, max = 24 },
    { name = "colour", label = "Colour", kind = "select",
      options = { { label = "Red", value = "red" }, { label = "Blue", value = "blue" } } },
  },
}, function(values, err)
  if values then rpf.interactions.send("acme_tags.spray", values) end -- err is "cancelled" if closed
end)
rpf.ui.progress({ label = "Spraying", duration_ms = 3000 }, function(done)
  -- done is true when it ran to the end; nil, "cancelled" otherwise
end)
```

On the server, the same four take the player's handle first and show it on
their client. Use it when the server decides what to offer: the client's
answer is checked against what you offered before your callback sees it. A
menu answers one of your options, and its `value` never leaves the server,
so it can be an id the player must not be able to choose freely:

```lua
-- server
rpf.ui.menu(player.handle, {
  title = "Your tags",
  options = {
    { label = "hello", value = tag.id },          -- the callback gets tag.id
    { label = "faded", disabled = true },
    { label = "Spray can", item = "spray_can" },  -- drawn with the item's image
  },
}, function(id, err)
  if id then scrub(player, id) end -- err: "cancelled", "timeout", "gone", ...
end)
```

An option that names an item (`item`, its slug) is drawn with the item's
image beside its label, on either engine and from either side: the
player's client fetches it for itself (below), so the server sends the
slug alone. An item the catalog does not have, or one staff gave no
image, leaves the option with its label. The first time an image is
needed the menu waits up to two seconds for it, then shows without it;
from then on it is kept.

The fields an input dialog takes are `text`, `number`, `checkbox` and
`select`, each with `required`, a `default` and bounds (`min`, `max`); on
the server the values are checked against them. A progress bar's `true` is
still only the player's client saying so: if timing matters, keep the time
yourself. `rpf.capabilities()` says which of the four an engine shows
(`notify`, `menu`, `input`, `progress`). A call to one it does not show
says `unsupported`, and one of each can be open per player at a time
(`busy`).

**`lib.*`, for an addon for FiveM alone.** Every RPF server on FiveM runs
ox_lib 3.40.0 or newer, so a FiveM-only addon may use all of it directly:
radial menus, zones, skill checks, anything `rpf.ui` leaves out. Load it in
your resource as you would anywhere:

```lua
-- fxmanifest.lua
dependencies { "rpf", "ox_lib" }
shared_script "@ox_lib/init.lua"

-- client.lua
local rpf = exports.rpf:api()
lib.notify({ title = "Tags", description = "Sprayed.", type = "success" })
if lib.progressCircle({ duration = 3000, label = "Spraying", canCancel = true }) then
  rpf.interactions.send("acme_tags.spray", { text = "hello" })
end
```

Whichever you use, a client's request to the server still goes through
`rpf.interactions`, even on FiveM, where it travels over `lib.callback`
anyway. Do not register your own `lib.callback` handlers for what your
addon does: an interaction reaches your handler only for a logged-in
player, rate-limited, with a checked copy of its payload, and is taken down
with your addon.

### Item images

An inventory or a shop shows items by their images. Staff upload one per
item in the portal. A `rpf.ui` menu draws them for you: put `item =
"apple"` on the option (above). For UI of your own, on the player's
client, ask for the image by the item's slug and draw what comes back. RPF
fetches it with the player's token, checks it, and keeps it on disk under
its content hash, so an image is fetched once and asking again answers at
once: ask whenever you draw.

```lua
-- client
rpf.items.image("apple", function(image, err)
  if not image then
    return -- "no_image", "not_found", "not_logged_in", "busy", "unavailable"
  end
  -- FiveM: a data: URL. Put it in your page's <img>, or in ox_lib (`icon`
  -- beside the title, `image` in the hover card):
  lib.registerContext({ id = "shop", title = "Shop",
    options = { { title = "Apple", icon = image.src, image = image.src } } })
  -- Garry's Mod: a path for Material().
  -- local material = Material(image.src)
end)
```

`rpf.items.catalog(callback)` gives the whole catalog the client sees:
each item's weight, footprint, stack limit and image hash, by slug. Both
are client only, and answer `not_logged_in` until the player has logged
in. Never fetch an image yourself with the token from `rpf.auth.api_token()`:
the token must not end up in a URL, and RPF already keeps the image under
the right key (its hash, which changes exactly when the image does).

## Money and items

Addons move money and items only through one set of calls, which work the
same whoever owns those domains on the server: RPF itself, or an existing
framework such as Qbox or DarkRP, through its bridge. They take the
player's engine handle and act on the character they have in play. Through
a bridge, the character's `key` is the framework's own (Qbox's
`citizenid`, DarkRP's SteamID64): keep it on the game server, never in a
record's field. Ask `rpf.<domain>.supports(call)` before offering a player
anything that needs it: under DarkRP, for one, no `inventory` call works,
and the only account is `wallet`.

```lua
local op = rpf.ops.new() -- mint once per payment, and keep it with the payment
local ok, status, why = rpf.money.debit(player, "bank", 250, "Parking fine", op)
if status == "refused" then
  -- nothing changed; `why` says why: "insufficient_funds", "no_account", ...
elseif status == "unknown" then
  -- it may have happened: never send it again under a new op id
end
```

To sell an item, use an exchange (below), not a debit and then a give: the
give can find the player has no room after the money is gone.

- **Ask first.** `rpf.money.supports("debit")` and its siblings say whether
  a call works on this server. On an RPF server, debits and credits need
  staff to set the `economy.addon_account` setting to the paying account
  your addon's money goes into and comes out of.
- **Name accounts from the list.** `rpf.money.accounts()` gives the names
  (`wallet`, `bank` on an RPF server); make the one your addon uses a
  setting of your own rather than a constant.
- **Retries are safe with the same op id.** A command runs at most once per
  op id; sending it again returns the first answer. An op id is good for a
  day. `rpf.ops.result(op_id)` says how one already went (nil if it never
  ran), so a repeated order is answered as it was, before you check it
  again against stock or prices that have since moved.
- **`unknown` is for staff.** It means the game server cannot tell whether
  the command happened (it stopped mid-way). It is logged with what it was,
  announced as `domains.op_unknown`, listed by `rpf.ops.unknown()`, shown
  to staff on the server's **Unknown operations** page in the portal, and
  never run again. Do not compensate on your own: staff look it up and
  settle it by hand.

To charge for a change to your own records (a badge, an upgrade), pass the
change as `apply` after the op id. Hold the record and check everything
first, so the change cannot fail; `apply` runs only once the money moved,
in the same intent, and the intent completes only once what it wrote is on
its way to the portal. If the server dies in between, or `apply` throws or
answers nil, the debit is `unknown` and staff grant or refund it by hand.

```lua
local op = rpf.ops.new()
local ok, status, why = rpf.money.debit(player, "bank", 500, "Gold badge", op, function()
  return rpf.records.update("acme_badges.badge", badge.id, { label = "Gold" }, { revision = badge.revision })
end)
```

### Selling, buying back, trading: exchanges

`rpf.commerce.exchange` moves money and items together, and your change to
your own records with them, as one intent. A deal says what moves, from the
player's side: what they `pay` (or are `paid`), the items they hand over
(`take`) and receive (`give`), and the records you priced it against
(`records`), each at the revision you read.

```lua
local listing = rpf.records.get("acme_shop.listing", listing_id) -- a config record staff priced
local stock = rpf.records.get("acme_shop.stock", stock_id)       -- a live record this server holds
local op = rpf.ops.new() -- once per purchase, kept with it
local ok, status, why = rpf.commerce.exchange(player, {
  account = "wallet",
  pay = listing.fields.price * 2,
  give = { { item = listing.fields.item, count = 2 } },
  reason = "Corner shop: 2 water",
  records = {
    { type = "acme_shop.listing", id = listing.id, revision = listing.revision },
    { type = "acme_shop.stock", id = stock.id, revision = stock.revision },
  },
}, op, function()
  return rpf.records.update("acme_shop.stock", stock.id, { left = stock.fields.left - 2 }, { revision = stock.revision })
end)
```

- **On an RPF server it is all or nothing.** Everything is checked before
  anything moves: the player's account and balance, each item given in the
  catalog (`unknown_item`), each record in `records` still at the revision
  you read (`stale`: staff changed the price, or another sale took the
  stock), and the items across the player's containers as one plan, so
  what they hand over makes room for what they get (`no_space`,
  `insufficient`). A refusal changes nothing.
- **Through a bridge** (Qbox, DarkRP), the framework's calls run one after
  another: the money, then each take, then each give. A refusal before any
  went through changes nothing; a failure after one did (the framework
  refuses the give for want of room) is `unknown`, for staff, and nothing
  is refunded. Under DarkRP no item call works, so a deal with items is
  `refused` (`unsupported`) without reaching it.
- **Check first.** `rpf.commerce.check(player, deal)` makes the same checks
  without moving anything: offer only what the player can afford and carry.
- **Retries** with the same op id are safe: the deal runs once, and sending
  it again returns the first answer.
- **Keep `apply` to fields of records you hold** (the stock), which nothing
  but your server can refuse, and name those records in `records` so that
  `apply` cannot find them changed.

### The shop example

[`lua/examples/acme_shop/`](../lua/examples/acme_shop/) is the whole of a
shop, with nothing in RPF that knows it is one. Staff place counters
(`acme_shop.counter`, a `config` type whose records are shopkeepers placed
in the world) and price what each sells (`acme_shop.listing`), both on the
generic data pages. What is limited has stock (`acme_shop.stock`, a `live`
type the server holds). A player aims the `acme_shop.shop` interaction at
a counter, picks from a menu and says how many, both opened from the
server with `rpf.ui`, so the menu's values (which listing, at what price)
never reach the client. Then:

- **Everything is checked again when the player confirms**, against the
  config and the stock as they are then: the listing still there, the
  counter still open and within reach, the price still the one shown (a
  price staff changed meanwhile is refused, not charged), the item still in
  the catalog (refused and said in the console otherwise), and enough
  stock.
- **One exchange** moves the money, the items and the stock (`apply`), with
  the listing and the stock named in `records` at the revisions just read.
- **One op id per order**, minted when the player confirms. While the till
  cannot be asked (`unavailable`, just after a restart) the order is sent
  again under the same op id, so it can never be made twice, and an order
  sent again is answered as it was (`rpf.ops.result`), even once the stock
  it took has run out.
- **The listing as the player saw it.** The menu keeps the listing's
  revision with the option, so an order for a listing staff changed while
  the dialog was open (another item at the same price) is refused, never
  filled with what the listing has become.
- **Staff see every sale** where they already look: the ledger entry on the
  till's and the player's account pages (`Corner shop: sold 2 water`), the
  player's containers, and the stock on its data page. What it bought is an
  ordinary item: the player moves and uses it like any other.

### The property example

[`lua/examples/acme_property/`](../lua/examples/acme_property/) sells
something that changes hands, which neither the money nor the items know
about. Two choices make it work, and both apply to anything like it:

- **Ownership that changes is a field, not the record's owner.** A record's
  `owner` is fixed when it is made, and its records go with it when the
  owner is deleted. A property outlives whoever bought it, so it is owned by
  the server, and who has it in play is `holder`, a reference to a player
  that the purchase writes and staff can change on its page.
- **A purchase changes a record that already exists.** Staff create each
  property (a `live` type, `hold = "server"`), so the exchange's `apply` is
  an update of a record the server holds, named in `records` at the
  revision the player was shown. Making a record in `apply` instead (a
  "deed" referring to the property) could be refused by the portal after
  the money moved, if staff deleted the property meanwhile. Nor can an
  exchange's `records` show that no deed exists yet: just after a restart,
  before the core has claimed every deed back, a second one could be sold.
  Only a `unique` field would refuse it, and the portal would refuse it
  after the money moved.
- **A reference to the buyer** is one the portal refuses in one case: the
  buyer's account was deleted. RPF kicks a deleted account from every
  server it is in game on as the deletion commits, so nothing an addon does
  for that player afterwards can name them; only a purchase made in the
  moment between the deletion and the kick is refused after the money
  moved, and its record is logged as refused rather than written.

Its doors are a `config` type that refers to the property, placed by
staff. A door's state is the property's `locked` field, which the owner
changes through an interaction aimed at the door, and which a server's own
door script reads with `rpf.addons.call("acme_property.locked", door_id)`.

### Licences, dealerships and the like

The same contract covers what else is sold in game, with no change to it:

- **A licence** is a `live` record the addon writes when it is bought (a
  `licence` type owned by the character, with an expiry field), bought by
  an exchange (`pay`, and the create as `apply`) or a plain
  `rpf.money.debit` with the create as its `apply`. Give the type no
  `unique` field and a `limit` well above what you sell, so the portal has
  nothing to refuse the create for once it is paid. Checking it later is
  the addon's own `rpf.records.list` on the player's records, as an
  interaction's `check` rule or in its handler.
- **A dealership** sells something that is not an item: a vehicle record
  the addon owns (`live`, owned by the character, its model and plate as
  fields), created by the exchange's `apply`, with the stock on the lot as
  `acme_shop` keeps it. Spawning it is the addon's, through
  `rpf.world` where the engine supports it.
- **Trades in kind**, a crafting bench or a recycler, are exchanges with
  `take` and `give` and no money at all.

What none of them may do is keep a balance or an inventory of their own
(money and items stay the core's, behind the facade), take a real-money
payment, or create a record in `apply` that the portal could refuse after
the money moved (a `unique` field, a reference to something staff may have
deleted, a type at its `limit`): keep `apply` to fields of records the
server holds, and records it creates to types with nothing to clash on.

Do not build anything that sells in-game money or items for real money:
the Cfx.re platform rules forbid it, and RPF connects nothing to a payment.

## Timers, exports, the world

- `rpf.time.now()`, `after(ms, fn)`, `every(ms, fn)` and `cancel(id)` run on
  the engine's clock alike.
- `rpf.addons.provide("acme_tags.count", fn)` lets other addons call
  `rpf.addons.call("acme_tags.count", ...)`, which answers
  `true, ...results`, or `false` and why, only while your addon runs.
- `rpf.capabilities()` says what the engine's adapter supports: in the
  game world (server only) `position` and `bucket` (`rpf.world.position`,
  `rpf.world.bucket`), `model`, `entity`, `spawn` and `despawn`, and the UI
  above. Ask before offering something that needs one; a call to one the
  engine lacks says `unsupported`.

## Engines

The API is the same on both engines; what differs is how a script is loaded
and how functions cross into RPF.

- **FiveM.** Your addon is another resource, so every call crosses an
  export: tables are copied, and a function you pass becomes a reference.
  That is why the API names the type in every call and returns copies.
  `rpf.events.on` returns a subscription id there, which `off` takes.
  ox_lib (3.40.0 or newer) is RPF's dependency on FiveM, so it is on every
  RPF server; an addon for FiveM alone may use it directly.
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
      caller's scope: another player's record is refused exactly as a
      missing one is.
- [ ] An aimed interaction's refusals that can be told in advance are in
      its `check`, which only reads, so the menu offers it only to those
      who may use it.
- [ ] Money and items move only through `rpf.money`, `rpf.inventory` and
      `rpf.commerce`, each command with an op id minted once and kept with
      what it pays for; money and items that move together are one
      exchange.
- [ ] The addon runs on both engines (its UI through `rpf.ui`), or says
      which it needs.
