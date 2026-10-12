-- acme_notes as a FiveM resource: the walkthrough's three files, and an
-- entry point on each side that reaches `rpf` through its export. It needs
-- the `rpf` resource started first. The release's addon kit has it laid out
-- (`fivem/[rpf-examples]/acme_notes`); from the repository, copy this
-- directory's parent as a resource: `manifest.lua`, `server.lua`,
-- `client.lua` beside a `fivem/` holding the entry points, with this file
-- moved up beside them.
--
-- The directives are FiveM's manifest language, not Lua globals, and no
-- definition set describes them.
---@diagnostic disable: undefined-global
fx_version("cerulean")
game("gta5")
lua54("yes")

description("acme_notes: the RPF addon walkthrough's example")
version("1.2.0")

dependency("rpf")

shared_script("manifest.lua")
server_scripts({ "server.lua", "fivem/server.lua" })
client_scripts({ "client.lua", "fivem/client.lua" })
