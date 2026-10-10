-- The `rpf-qbox` resource (K3): RPF's bridge to Qbox, for a server running
-- RPF beside qbx_core and ox_inventory in the companion profile. This
-- directory is the resource as it ships. `bridge.lua` is the bridge, free of
-- the engine; `fivem/` holds its FiveM entry points.
--
-- `rpf` must be running first, since the bridge registers through its
-- export, and stopping `rpf` stops this resource too: `ensure rpf-qbox`
-- again after `restart rpf`. qbx_core and ox_inventory are deliberately
-- not dependencies. FiveM would stop this resource with them and leave it
-- stopped, while the bridge's job is to report qbx_core stopping and
-- starting again (`unavailable`, then `available`).
--
-- The directives are FiveM's manifest language, not Lua globals, and no
-- definition set describes them, so the language server is told not to
-- look for them.
---@diagnostic disable: undefined-global

fx_version("cerulean")
game("gta5")
lua54("yes")

name("rpf-qbox")
description("rp-framework: the bridge to Qbox (qbx_core and ox_inventory)")
version("1.0.0")

dependency("rpf")
dependency("ox_lib")

-- ox_lib's loader, which puts `lib` in this resource's Lua state: the
-- selection's callbacks and its menus.
shared_script("@ox_lib/init.lua")

server_scripts({
  "bridge.lua",
  "fivem/server.lua",
})

client_scripts({
  "fivem/client.lua",
})
