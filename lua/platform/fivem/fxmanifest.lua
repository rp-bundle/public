-- The `rpf` resource (D2): the Lua core, this adapter and its NUI screens.
-- `dev/fivem-resources` assembles it, copying `lua/core/` into `core/` beside
-- these files; the `rpf-ws` resource (`ws-shim/`) owns the portal socket.
--
-- The script lists are the core's load order, `rpf.files` in
-- `lua/core/init.lua`, then the adapter's files. `spec/fivem_spec.lua` holds
-- them to it, so a file the core gains cannot be missing here.
--
-- The directives are FiveM's manifest language, not Lua globals, and no
-- definition set describes them, so the language server is told not to
-- look for them.
---@diagnostic disable: undefined-global

fx_version "cerulean"
game "gta5"
lua54 "yes"

name "rpf"
description "rp-framework: the Lua core and its FiveM adapter"

-- The socket's shim must be running before the core connects, and stopping
-- it stops this resource too.
dependency "rpf-ws"

server_scripts({
  "core/init.lua",
  "core/json.lua",
  "core/platform.lua",
  "core/events.lua",
  "core/time.lua",
  "core/protocol.lua",
  "core/config.lua",
  "core/client.lua",
  "core/players.lua",
  "core/commands.lua",
  "core/moderation.lua",
  "core/staff.lua",
  "core/inventory.lua",
  "core/records.lua",
  "core/sync.lua",
  "core/accounts.lua",
  "core/handoff.lua",
  "core/join.lua",
  "core/characters.lua",
  "core/jobs.lua",
  "core/edits.lua",
  "core/api.lua",
  "shared.lua",
  "ws.lua",
  "lock.lua",
  "server.lua",
})

client_scripts({
  "core/init.lua",
  "core/json.lua",
  "core/platform.lua",
  "core/events.lua",
  "core/time.lua",
  "core/handoff.lua",
  "core/auth.lua",
  "core/picker.lua",
  "core/api.lua",
  "shared.lua",
  "ui.lua",
  "client.lua",
})

ui_page("nui/index.html")

files({
  "nui/index.html",
  "nui/app.js",
  "nui/seal.js",
  "nui/style.css",
})
