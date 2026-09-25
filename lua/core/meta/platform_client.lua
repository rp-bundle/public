---@meta

-- The player client's platform interface. Separate from the server's, because
-- the two have different capabilities and different trust: the client never
-- holds the server's API key, and the server never sees a player's password.
-- This file is a definition for the language server and is never loaded.

---Messages between this client and the game server. Payloads are strings,
---for the same reason as on the server side.
---@class rpf.platform.ToServer
local ToServer = {}

---Sends a message to the game server.
---@param name string The message name, namespaced `rpf:`.
---@param payload string The message, already encoded.
function ToServer.to_server(name, payload) end

---Registers the handler for one message name from the game server.
---@param name string The message name, namespaced `rpf:`.
---@param handler fun(payload: string) Called for each message.
function ToServer.on_server(name, handler) end

---Everything the player-client half of the core needs from its engine.
---`rpf.start_client` refuses a table missing any of it.
---@class rpf.ClientPlatform: rpf.platform.Engine, rpf.platform.Http, rpf.platform.Storage, rpf.platform.Clock, rpf.platform.ToServer, rpf.platform.Log
