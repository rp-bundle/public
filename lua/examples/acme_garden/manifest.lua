---acme_garden: plants a player sows, which grow while the server runs, need
---watering, and are harvested once grown or wither if left dry.
---
---J6's sample of a timed live type, built only on `rpf.api`: a record placed
---in the world as an object, interactions that change it, stages it moves
---through on time it keeps in its own fields, collection and destruction,
---recovery after a restart, and a schema upgrade. RPF has no idea what a
---plant is. The same three files run on FiveM and Gmod; only the thin entry
---points in `fivem/` and `gmod/` differ.
---
---Every file adds to one table, `acme_garden`: on FiveM it is the
---resource's own global, on Gmod the one global this addon takes.
---@class acme_garden
---@field MANIFEST rpf.AddonManifest What the addon declares.
---@field TYPE string Its plant type's full name.
---@field TICK_MS integer How often plants grow and dry, in milliseconds: one tick of growth.
---@field MAX_CATCH_UP_MS integer The most growth one tick counts, after an outage or a restart: what keeps catch-up bounded.
---@field SPROUT_TICKS integer Ticks of growth before a seed sprouts.
---@field GROWN_TICKS integer Ticks of growth before a plant can be harvested.
---@field PER_PLAYER integer The most plants one player may have growing.
---@field MODEL table One model per engine, unread by RPF.
acme_garden = acme_garden or {}

acme_garden.TYPE = "acme_garden.plant"
acme_garden.TICK_MS = 60000
acme_garden.MAX_CATCH_UP_MS = 5 * 60000
acme_garden.SPROUT_TICKS = 10
acme_garden.GROWN_TICKS = 30
acme_garden.PER_PLAYER = 5
acme_garden.MODEL = { fivem = "prop_plant_01a", gmod = "models/props/cs_office/plant01.mdl" }

acme_garden.MANIFEST = {
  namespace = "acme_garden",
  version = "1.2.0",
  api = 1,
  title = "Garden",
  permissions = { tend = "Water, harvest and remove any plant" },
  types = {
    plant = {
      -- Schema 1 had no `water`. Adding it with a default is a compatible
      -- change, so 1.1.0 installs over 1.0.0 without touching a record: an
      -- older plant reads as full until the next tick writes it at schema 2.
      -- Schema 3 (1.2.0) added `map` the same way: an older plant has none,
      -- so it stays on every map.
      schema = 3,
      authority = "live",
      owners = { "player" },
      -- Held by the server while it runs, whether or not its gardener is on,
      -- so plants grow and dry for everyone; RPF claims them back after a
      -- restart.
      hold = "server",
      title = "Plant",
      fields = {
        spot = { type = "vector3", required = true, read_only = true },
        bucket = { type = "integer", min = 0, max = 65535, default = 0, read_only = true },
        -- The map the plant was sown on (`rpf.world.map()`): a garden on one
        -- map is not planted at the same coordinates on another. Null is
        -- every map.
        map = { type = "string", max_len = 64, index = true, nullable = true },
        model = { type = "json", max_bytes = 256, engine = true, default = acme_garden.MODEL, hidden = true },
        stage = { type = "enum", values = { "seed", "sprout", "grown", "withered" }, default = "seed", index = true },
        water = { type = "integer", min = 0, max = 100, default = 100 },
        grown_ticks = { type = "integer", min = 0, max = 1000000, default = 0, read_only = true },
        planted_at = { type = "timestamp", required = true, read_only = true },
        -- The moment growth was last counted: time is kept here, not in a
        -- timer, so a restart loses none of it.
        ticked_at = { type = "timestamp", required = true, read_only = true },
      },
      list = { "stage", "water", "planted_at" },
      actions = { create = false, edit = "tend", delete = "tend" },
      limit = 2000,
      -- Placed in the world as an object while the server holds it (J6).
      world = { kind = "object", position = "spot", bucket = "bucket", model = "model", map = "map" },
    },
  },
}
