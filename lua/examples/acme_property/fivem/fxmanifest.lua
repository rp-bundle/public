-- acme_property as a FiveM resource: the example addon's two files, and an
-- entry point that reaches `rpf` through its export. It needs the `rpf`
-- resource started first. The release's addon kit has it laid out
-- (`fivem/[rpf-examples]/acme_property`); from the repository, copy this
-- directory's parent as a resource: `manifest.lua` and `server.lua` beside a
-- `fivem/` holding the entry point, with this file moved up beside them. It
-- has no client script of its own: the core's interaction menu
-- (`rpf_interact`, E by default) offers the lot and the doors, and the offer
-- is `rpf.ui`'s, opened from the server.
--
-- The directives are FiveM's manifest language, not Lua globals, and no
-- definition set describes them.
---@diagnostic disable: undefined-global
fx_version("cerulean")
game("gta5")
lua54("yes")

description("acme_property: an example RPF addon")
version("1.1.0")

dependency("rpf")

server_scripts({ "manifest.lua", "server.lua", "fivem/server.lua" })
