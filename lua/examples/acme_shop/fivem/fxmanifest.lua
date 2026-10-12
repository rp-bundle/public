-- acme_shop as a FiveM resource: the example addon's two files, and an entry
-- point that reaches `rpf` through its export. It needs the `rpf` resource
-- started first. Copy this directory's parent as a resource: `manifest.lua`
-- and `server.lua` beside a `fivem/` holding the entry point, with this file
-- moved up beside them. The shop has no client script of its own: the core's
-- interaction menu (`rpf_interact`, E by default) and ox_target or qb-target
-- offer the counter, and its menu and dialog are `rpf.ui`'s, opened from the
-- server.
--
-- The directives are FiveM's manifest language, not Lua globals, and no
-- definition set describes them.
---@diagnostic disable: undefined-global
fx_version("cerulean")
game("gta5")
lua54("yes")

description("acme_shop: an example RPF addon")
version("1.1.0")

dependency("rpf")

server_scripts({ "manifest.lua", "server.lua", "fivem/server.lua" })
