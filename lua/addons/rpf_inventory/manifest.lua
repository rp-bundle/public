---rpf_inventory: the player's own items and money, on their screen (S1,
---#183). A starter addon: first-party and supported, built only on
---`rpf.api` like any addon a community writes, so everything it does is
---what an addon may do.
---
---A player opens the inventory (`I` on FiveM, `rpf_inventory` on Gmod) and
---sees their character's containers with each item's image, their money,
---and the players near them. They move a stack between containers, use
---it, throw it away or give it to a player nearby, and hand cash over.
---Every one of those is a call into `rpf.inventory` or `rpf.money` with an
---op id the server mints, and every id the client names (a container, a
---stack, a player) is resolved again on the server, inside the player's
---own scope.
---
---Staff set it up on the generic record page of its one `config` type,
---**Inventory settings**: whether giving, throwing away and handing cash
---over are allowed, which account cash comes from, how near another player
---must be, and what the addon does beside a framework's own inventory. With
---no record, the defaults below hold.
---
---Every file adds to one table, `rpf_inventory`: on FiveM it is the
---resource's own global, on Gmod the one global this addon takes.
---@class rpf_inventory
---@field MANIFEST rpf.AddonManifest What the addon declares.
---@field SETTINGS string The settings type's full name.
---@field DEFAULTS rpf_inventory.Settings What the settings are with no record: the fields' own defaults.
rpf_inventory = rpf_inventory or {}

rpf_inventory.SETTINGS = "rpf_inventory.settings"

---What staff set on the settings record.
---@class rpf_inventory.Settings
---@field allow_give boolean Whether players may give items to a player nearby.
---@field allow_drop boolean Whether players may throw items away.
---@field allow_cash boolean Whether players may hand cash to a player nearby.
---@field cash_account string The account cash is handed from and into.
---@field reach number How near, in metres, another player must be to be given anything.
---@field beside_framework "stand_aside"|"run" Beside a framework (Qbox's ox_inventory): stand aside for its own screens, or show what RPF still can (the money).
rpf_inventory.DEFAULTS = {
  allow_give = true,
  allow_drop = true,
  allow_cash = true,
  cash_account = "wallet",
  reach = 3,
  beside_framework = "stand_aside",
}

rpf_inventory.MANIFEST = {
  namespace = "rpf_inventory",
  version = "1.0.0",
  api = 1,
  title = "Inventory",
  types = {
    -- One record, which staff create when they want other than the
    -- defaults; `limit` keeps it to one, so there is never a question of
    -- which applies.
    settings = {
      schema = 1,
      authority = "config",
      title = "Inventory settings",
      limit = 1,
      fields = {
        allow_give = {
          type = "boolean",
          default = true,
          title = "Players may give items",
          help = "To a player standing near them",
          group = "What players may do",
          order = 1,
        },
        allow_drop = {
          type = "boolean",
          default = true,
          title = "Players may throw items away",
          help = "The items are gone: nothing is left for another player to pick up",
          group = "What players may do",
          order = 2,
        },
        allow_cash = {
          type = "boolean",
          default = true,
          title = "Players may hand cash over",
          group = "What players may do",
          order = 3,
        },
        cash_account = {
          type = "string",
          max_len = 32,
          charset = "identifier",
          default = "wallet",
          title = "Cash account",
          help = "The account handed cash comes out of and goes into: one of the starting accounts",
          group = "What players may do",
          order = 4,
        },
        reach = {
          type = "number",
          min = 1,
          max = 10,
          default = 3,
          unit = "metres",
          slider = true,
          title = "How near",
          help = "How near another player must be to be given an item or cash",
          group = "What players may do",
          order = 5,
        },
        beside_framework = {
          type = "enum",
          values = { "stand_aside", "run" },
          default = "stand_aside",
          title = "Beside a framework",
          help = "Where a framework such as Qbox owns the items, stand_aside leaves its own inventory alone; run still shows the money",
          group = "Beside a framework",
          order = 1,
        },
      },
      list = { "allow_give", "allow_drop", "allow_cash", "beside_framework" },
    },
  },
}
