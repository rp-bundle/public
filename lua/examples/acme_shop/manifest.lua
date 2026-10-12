---acme_shop: counters that sell items and buy them back, for in-game money.
---
---The commerce example (J5): an addon RPF has never heard of, built only on
---`rpf.api`. Staff place counters and price what each sells in the portal
---(two `config` types), and stock what is limited (a `live` type the server
---holds). A player walks up to a counter, picks from its menu, says how
---many, and pays: one exchange (`rpf.commerce.exchange`) moves the money,
---the items and the stock together, or refuses and moves nothing. It needs
---no Rust, migration, route or protocol change: everything a shop is, is
---these types and the server script.
---
---In-game money only: nothing here, or anywhere in RPF, connects to a
---real-money payment.
---
---Every file adds to one table, `acme_shop`: on FiveM it is the resource's
---own global, on Gmod the one global this addon takes.
---@class acme_shop
---@field MANIFEST rpf.AddonManifest What the addon declares.
---@field COUNTER string The counter type's full name.
---@field LISTING string The listing type's full name.
---@field STOCK string The stock type's full name.
---@field MAX_STOCK integer The most one stock record holds.
acme_shop = acme_shop or {}

acme_shop.COUNTER = "acme_shop.counter"
acme_shop.LISTING = "acme_shop.listing"
acme_shop.STOCK = "acme_shop.stock"
acme_shop.MAX_STOCK = 1000000

acme_shop.MANIFEST = {
  namespace = "acme_shop",
  version = "1.3.0",
  api = 1,
  title = "Shops",
  permissions = { restock = "Stock shops: create, change and remove stock" },
  types = {
    -- A shopkeeper staff place in the portal (J4): the server spawns one
    -- for each counter shown, and a player aims the shop at it.
    counter = {
      -- Schema 1 had no `map`. Adding it as a nullable field is a compatible
      -- change: 1.1.0 installs over 1.0.0 with every counter kept, and an
      -- older counter, which has no map, stays on every map. Schema 3 (1.2.0)
      -- lays the page out (N1): `order` puts the name first and `group`
      -- gathers where the counter stands and what it looks like under two
      -- headings; `unit` and `slider` give the heading a dial. None of it
      -- changes what a record holds, so it installs over 1.1.0 as well.
      -- Schema 4 (1.3.0) indexes the name, so `display` can name a counter
      -- by it (N2): a listing's picker lists counters by name.
      schema = 4,
      authority = "config",
      title = "Counter",
      fields = {
        name = { type = "string", max_len = 48, required = true, index = true, title = "Name", order = 1 },
        shown = { type = "boolean", default = true, title = "Open", order = 2 },
        account = {
          type = "string",
          max_len = 32,
          charset = "identifier",
          default = "wallet",
          title = "Paid from",
          help = "The player's account purchases come out of and buy-backs go into",
          order = 3,
        },
        spot = { type = "vector3", required = true, title = "Where it stands", group = "Place", order = 1 },
        heading = {
          type = "number",
          min = 0,
          max = 360,
          default = 0,
          unit = "degrees",
          slider = true,
          title = "Facing",
          group = "Place",
          order = 2,
        },
        -- Staff say which map a counter stands on: a shopkeeper placed for
        -- `rp_downtown` is not spawned at the same coordinates on
        -- `rp_evocity`. Blank is every map.
        map = {
          type = "string",
          max_len = 64,
          index = true,
          nullable = true,
          title = "Map",
          help = "The map it stands on; blank for every map",
          group = "Place",
          order = 3,
        },
        model = {
          type = "json",
          max_bytes = 256,
          engine = true,
          required = true,
          title = "Shopkeeper",
          help = 'One model per engine: { "fivem": "mp_m_shopkeep_01", "gmod": "models/Humans/Group01/male_02.mdl" }',
          group = "Appearance",
        },
      },
      list = { "name", "account", "shown" },
      display = "name",
      world = { kind = "ped", position = "spot", heading = "heading", model = "model", visible = "shown", map = "map" },
    },
    -- What a counter sells, and at what price: staff's, like every price.
    listing = {
      -- Schema 2 (1.2.0) lays the page out (N1): the prices are `money`, so
      -- the portal shows them with the server's currency, and the two sit
      -- under one heading.
      schema = 2,
      authority = "config",
      title = "Listing",
      fields = {
        counter = { type = "ref", to = "acme_shop.counter", required = true, index = true, title = "Counter", order = 1 },
        item = { type = "ref", to = "item", required = true, title = "Item", order = 2 },
        price = { type = "integer", min = 1, max = 1000000, required = true, unit = "money", title = "Price", group = "Prices", order = 1 },
        buyback = {
          type = "integer",
          min = 0,
          max = 1000000,
          default = 0,
          unit = "money",
          title = "Buys back at",
          help = "What the counter pays for one; 0 buys none back",
          group = "Prices",
          order = 2,
        },
        most = { type = "integer", min = 1, max = 100, default = 10, slider = true, title = "Most per sale", group = "Stock", order = 1 },
        stocked = {
          type = "boolean",
          default = false,
          title = "Limited stock",
          help = "Sold only while its stock record has some left; unlimited otherwise",
          group = "Stock",
          order = 2,
        },
      },
      list = { "counter", "item", "price", "buyback", "stocked" },
    },
    -- How many a stocked listing has left: game state, so `live`, held by
    -- the server, and moved by every sale in the same exchange as the money.
    -- Staff create and restock it on the generic data page.
    stock = {
      schema = 1,
      authority = "live",
      owners = { "server" },
      -- Held by the server while it runs (J6): the core takes back the stock
      -- after a restart, and takes stock staff add within a minute.
      hold = "server",
      title = "Stock",
      fields = {
        listing = { type = "ref", to = "acme_shop.listing", required = true, index = true, unique = true, title = "Listing" },
        left = { type = "integer", min = 0, max = 1000000, required = true, title = "Left" },
      },
      list = { "listing", "left" },
      actions = { create = "restock", edit = "restock", delete = "restock" },
      limit = 1000,
    },
  },
}
