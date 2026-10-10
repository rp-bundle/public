---acme_tags: tags players spray on walls, which fade after a day.
---
---The worked example from `docs/architecture/addons.md`, runnable: an addon
---RPF has never heard of, built only on `rpf.api`. It declares one live
---type, registers an interaction a player's client calls to spray, keeps
---the tags across restarts, and fades them on a timer. The same three files
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
  version = "1.0.0",
  api = 1,
  title = "Tags",
  permissions = { moderate = "Remove any tag" },
  types = {
    tag = {
      schema = 1,
      authority = "live",
      owners = { "player" },
      title = "Tag",
      fields = {
        text = { type = "string", max_len = 24, charset = "printable", required = true },
        spot = { type = "vector3", required = true },
        fades_at = { type = "timestamp", required = true, index = true },
      },
      list = { "text", "fades_at" },
      actions = { create = false, edit = false, delete = "moderate" },
      limit = 500,
    },
  },
}
