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
-- it stops this resource too. ox_lib (J10) carries requests between client
-- and server, and the UI addons show; it is LGPL-3.0, a prerequisite the
-- owner installs, never bundled. FXServer cannot pin a dependency's
-- version, so `ox.lua` refuses one older than its MINIMUM at start.
dependency "rpf-ws"
dependency "ox_lib"

-- ox_lib's loader, which puts `lib` in this resource's Lua state, before
-- any script of ours on either side.
shared_script "@ox_lib/init.lua"

server_scripts({
  "core/init.lua",
  "core/json.lua",
  "core/platform.lua",
  "core/events.lua",
  "core/time.lua",
  "core/protocol.lua",
  "core/domains.lua",
  "core/config.lua",
  "core/client.lua",
  "core/players.lua",
  "core/commands.lua",
  "core/moderation.lua",
  "core/staff.lua",
  "core/inventory.lua",
  "core/manifest.lua",
  "core/addons.lua",
  "core/records.lua",
  "core/sync.lua",
  "core/accounts.lua",
  "core/handoff.lua",
  "core/join.lua",
  "core/characters.lua",
  "core/jobs.lua",
  "core/edits.lua",
  "core/data.lua",
  "core/ops.lua",
  "core/bridge.lua",
  "core/facade.lua",
  "core/world.lua",
  "core/interactions.lua",
  "core/ui.lua",
  "core/api.lua",
  "shared.lua",
  "ox.lua",
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
  "core/interactions.lua",
  "core/ui.lua",
  "core/api.lua",
  "shared.lua",
  "ox.lua",
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
