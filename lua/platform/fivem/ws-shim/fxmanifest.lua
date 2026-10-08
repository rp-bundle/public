-- The `rpf-ws` resource (D2): the portal websocket, in FiveM's JS runtime,
-- for the `rpf` resource's Lua (`../transport.lua` is the contract).
-- `npm run build` writes `dist/rpf-ws.js`, the whole shim with `ws` bundled
-- in, so a server owner never runs `npm install`.
--
-- The directives are FiveM's manifest language, not Lua globals.
---@diagnostic disable: undefined-global

fx_version "cerulean"
game "gta5"

name "rpf-ws"
description "rp-framework: the portal websocket for the rpf resource"

server_script("dist/rpf-ws.js")
