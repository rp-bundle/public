-- rpf_inventory as a FiveM resource: the addon's three files, an entry point
-- on each side that reaches `rpf` through its export, and the NUI page the
-- client draws the inventory in. It needs the `rpf` resource started first.
-- From the repository, copy this directory's parent as a resource:
-- `manifest.lua`, `server.lua`, `client.lua` beside a `fivem/` holding the
-- entry points and `html/`, with this file moved up beside them.
--
-- The directives are FiveM's manifest language, not Lua globals, and no
-- definition set describes them.
---@diagnostic disable: undefined-global
fx_version("cerulean")
game("gta5")
lua54("yes")

description("rpf_inventory: the player's items, money and HUD")
version("1.0.0")

dependency("rpf")

shared_script("manifest.lua")
server_scripts({ "server.lua", "fivem/server.lua" })
client_scripts({ "client.lua", "fivem/client.lua" })

ui_page("fivem/html/index.html")
files({ "fivem/html/index.html", "fivem/html/app.js", "fivem/html/style.css" })
