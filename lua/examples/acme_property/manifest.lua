---acme_property: properties players buy, and doors their owners lock.
---
---The extensibility proof (J8): a gameplay concept RPF has never heard of,
---built only on `rpf.api` and the generic type system. Staff create each
---property on the portal's data page (a `live` type the server holds, since
---who owns it and whether its doors are locked are game state) and place its
---doors (a `config` type that refers to it). A player standing on a lot that
---is for sale buys it: one exchange (`rpf.commerce.exchange`) pays the price
---and writes the new owner onto the property, or refuses and moves nothing.
---The owner locks and unlocks its doors. It needs no Rust, migration, route,
---page or protocol change: everything a property is, is these types and the
---server script.
---
---In-game money only: nothing here, or anywhere in RPF, connects to a
---real-money payment.
---
---Every file adds to one table, `acme_property`: on FiveM it is the
---resource's own global, on Gmod the one global this addon takes.
---@class acme_property
---@field MANIFEST rpf.AddonManifest What the addon declares.
---@field PROPERTY string The property type's full name.
---@field DOOR string The door type's full name.
acme_property = acme_property or {}

acme_property.PROPERTY = "acme_property.property"
acme_property.DOOR = "acme_property.door"

acme_property.MANIFEST = {
  namespace = "acme_property",
  version = "1.3.0",
  api = 1,
  title = "Properties",
  permissions = { manage = "Create, change and remove properties and their doors, and assign their owners" },
  types = {
    -- A lot: an area in the world (a zone, J4) with a price and, once
    -- bought, an owner. Staff create it and say what it costs; the game
    -- writes who bought it and whether its doors are locked. So it is
    -- `live`, held by the server whether or not its owner is on (J6), and a
    -- staff edit of it goes to the server as a command while it holds it.
    property = {
      -- Schema 1 had no `map`. Adding it as a nullable field is a compatible
      -- change: 1.1.0 installs over 1.0.0 with every property kept, and an
      -- older property, which has no map, stays on every map. Schema 3
      -- (1.2.0) lays the page out (N1): the lot, the sale and the doors under
      -- their own headings, the price as `money`, the size in metres. Schema 4
      -- (1.3.0) indexes the name, so `display` can name a property by it
      -- (N2): a door's picker lists properties by name.
      schema = 4,
      authority = "live",
      -- The server's, not the buyer's: a record's owner never changes, and
      -- a property outlives whoever bought it. Who owns it in play is
      -- `holder`, a field the purchase writes and staff can change.
      owners = { "server" },
      hold = "server",
      title = "Property",
      fields = {
        name = { type = "string", max_len = 48, required = true, index = true, title = "Name", order = 1 },
        spot = { type = "vector3", required = true, title = "Middle of the lot", group = "Lot", order = 1 },
        radius = {
          type = "number",
          min = 1,
          max = 100000,
          required = true,
          unit = "metres",
          title = "Size of the lot",
          help = "How far from the middle the lot reaches",
          group = "Lot",
          order = 2,
        },
        -- Staff say which map a lot is on: a lot on `rp_downtown` is not for
        -- sale at the same coordinates on `rp_evocity`. Blank is every map.
        map = {
          type = "string",
          max_len = 64,
          index = true,
          nullable = true,
          title = "Map",
          help = "The map the lot is on; blank for every map",
          group = "Lot",
          order = 3,
        },
        bucket = { type = "integer", min = 0, max = 65535, default = 0, title = "Routing bucket", group = "Lot", order = 4 },
        for_sale = { type = "boolean", default = false, title = "For sale", group = "Sale", order = 1 },
        price = { type = "integer", min = 1, max = 1000000000, required = true, unit = "money", title = "Price", group = "Sale", order = 2 },
        account = {
          type = "string",
          max_len = 32,
          charset = "identifier",
          default = "bank",
          title = "Paid from",
          help = "The buyer's account the price comes out of",
          group = "Sale",
          order = 3,
        },
        holder = {
          type = "ref",
          to = "player",
          nullable = true,
          index = true,
          title = "Owned by",
          help = "The player who owns it in play: set by a purchase, or by staff; blank for nobody",
          group = "Owner",
          order = 1,
        },
        bought_at = { type = "timestamp", nullable = true, read_only = true, title = "Bought", group = "Owner", order = 2 },
        locked = { type = "boolean", default = true, title = "Doors locked", group = "Owner", order = 3 },
      },
      list = { "name", "price", "for_sale", "holder" },
      display = "name",
      actions = { create = "manage", edit = "manage", delete = "manage" },
      limit = 1000,
      world = { kind = "zone", position = "spot", radius = "radius", bucket = "bucket", map = "map" },
    },
    -- A door of a property: a point staff place (nothing is spawned), which
    -- the owner locks and unlocks. Staff's, like every placement, so
    -- `config`; its state is the property's `locked`.
    door = {
      -- Schema 1 had no `map`; see the property. Schema 3 (1.2.0) orders the
      -- page and puts the placement under one heading (N1). Schema 4 (1.3.0)
      -- indexes the label, so `display` can name a door by it (N2).
      schema = 4,
      authority = "config",
      title = "Door",
      fields = {
        property = { type = "ref", to = "acme_property.property", required = true, index = true, title = "Property", order = 1 },
        label = { type = "string", max_len = 48, default = "Front door", index = true, title = "Label", order = 2 },
        spot = { type = "vector3", required = true, title = "Where it is", group = "Place", order = 1 },
        map = {
          type = "string",
          max_len = 64,
          index = true,
          nullable = true,
          title = "Map",
          help = "The map the door is on; blank for every map",
          group = "Place",
          order = 2,
        },
        bucket = { type = "integer", min = 0, max = 65535, default = 0, title = "Routing bucket", group = "Place", order = 3 },
      },
      list = { "label", "property" },
      display = "label",
      actions = { create = "manage", edit = "manage", delete = "manage" },
      world = { kind = "point", position = "spot", bucket = "bucket", map = "map" },
    },
  },
}
