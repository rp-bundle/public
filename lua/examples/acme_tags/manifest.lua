---acme_tags: tags players spray on walls, which fade after a day.
---
---The worked example from `docs/architecture/addons.md`, runnable: an addon
---RPF has never heard of, built only on `rpf.api`. It declares one live
---type, registers an interaction a player's client calls to spray, has the
---core hold the tags across restarts (`hold = "server"`), and fades them on
---a timer. The same three files
---run on FiveM and Gmod; only the thin entry points in `fivem/` and `gmod/`
---differ, because each engine loads a script its own way.
---
---Every file adds to one table, `acme_tags`: on FiveM it is the resource's
---own global, on Gmod the one global this addon takes.
---@class acme_tags
---@field MANIFEST rpf.AddonManifest What the addon declares.
---@field TYPE string Its tag type's full name.
---@field DAY integer How long a tag lasts, in milliseconds.
---@field FADE_EVERY integer How often faded tags are cleared, in milliseconds.
acme_tags = acme_tags or {}

acme_tags.TYPE = "acme_tags.tag"
acme_tags.DAY = 24 * 60 * 60 * 1000
acme_tags.FADE_EVERY = 60000

acme_tags.MANIFEST = {
  namespace = "acme_tags",
  version = "1.1.0",
  api = 1,
  title = "Tags",
  permissions = { moderate = "Remove any tag" },
  types = {
    tag = {
      -- Schema 1 had no `map`. Adding it as a nullable field is a compatible
      -- change: 1.1.0 installs over 1.0.0 with every tag kept, and an older
      -- tag, which has no map, stays on every map.
      schema = 2,
      authority = "live",
      owners = { "player" },
      -- Held by the server while it runs (J6), whether or not the player who
      -- sprayed it is here, so a tag fades on time; the core takes them back
      -- after a restart.
      hold = "server",
      title = "Tag",
      fields = {
        text = { type = "string", max_len = 24, charset = "printable", required = true },
        spot = { type = "vector3", required = true },
        -- The map the tag was sprayed on (`rpf.world.map()`), so a wall on
        -- one map does not carry it on another. Null is every map.
        map = { type = "string", max_len = 64, index = true, nullable = true },
        fades_at = { type = "timestamp", required = true, index = true },
      },
      list = { "text", "fades_at" },
      actions = { create = false, edit = false, delete = "moderate" },
      limit = 500,
      -- A tag is a spot on a wall (J4): nothing is placed there, but a
      -- player can aim an interaction at it by where it is, and only on the
      -- map it was sprayed on.
      world = { kind = "point", position = "spot", map = "map" },
    },
  },
}
