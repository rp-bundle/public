---acme_notes: notes players pin where they stand, which anyone nearby can
---read and which their author, or staff, take down.
---
---The walkthrough's addon (`docs/writing-addons.md`, "Walkthrough: a new
---type, end to end"): each step of the guide adds a part of these files, and
---the finished files are these. It is built only on `rpf.api`; RPF has no
---idea what a note is. The same three files run on FiveM and Gmod; only the
---thin entry points in `fivem/` and `gmod/` differ.
---
---Every file adds to one table, `acme_notes`: on FiveM it is the resource's
---own global, on Gmod the one global this addon takes.
---@class acme_notes
---@field MANIFEST rpf.AddonManifest What the addon declares.
---@field TYPE string Its note type's full name.
---@field PER_PLAYER integer The most notes one player may have pinned.
---@field MODEL table One model per engine, unread by RPF.
acme_notes = acme_notes or {}

acme_notes.TYPE = "acme_notes.note"
acme_notes.PER_PLAYER = 3
acme_notes.MODEL = { fivem = "prop_notepad_01", gmod = "models/props_c17/paper01.mdl" }

acme_notes.MANIFEST = {
  namespace = "acme_notes",
  version = "1.2.0",
  api = 1,
  title = "Notes",
  -- Becomes `addon.acme_notes.moderate`, which staff grant to a role.
  permissions = { moderate = "Edit and take down any note" },
  types = {
    note = {
      -- Schema 1 had no `colour`. Adding it with a default is a compatible
      -- change: 1.1.0 installs over 1.0.0 with every note kept, and an older
      -- note reads as white. Schema 3 (1.2.0) added `map` the same way: an
      -- older note has none, so it stays on every map.
      schema = 3,
      authority = "live",
      owners = { "player" },
      -- Held by the server while it runs, whoever pinned it, so every note
      -- is in the world and readable whether or not its author is on.
      hold = "server",
      title = "Note",
      fields = {
        text = { type = "string", max_len = 120, required = true },
        colour = { type = "enum", values = { "white", "yellow", "pink" }, default = "white" },
        spot = { type = "vector3", required = true, read_only = true },
        bucket = { type = "integer", min = 0, max = 65535, default = 0, read_only = true },
        -- The map the note was pinned on (`rpf.world.map()`), so a server
        -- that switches maps does not show it at the same coordinates on
        -- another. Null is every map; staff may clear it on the data page.
        map = { type = "string", max_len = 64, index = true, nullable = true },
        -- One model per engine: the record is the same on both.
        model = { type = "json", max_bytes = 256, engine = true, default = acme_notes.MODEL, hidden = true },
        pinned_at = { type = "timestamp", required = true, read_only = true, index = true },
      },
      list = { "text", "colour", "pinned_at" },
      -- Staff holding `moderate` edit and delete notes on the data pages;
      -- notes are made only in game.
      actions = { create = false, edit = "moderate", delete = "moderate" },
      limit = 1000,
      world = { kind = "object", position = "spot", bucket = "bucket", model = "model", map = "map" },
    },
  },
}
