---@meta

-- The player client's platform interface. Separate from the server's, because
-- the two have different capabilities and different trust: the client never
-- holds the server's API key, and a player's password goes from the client to
-- the portal, not through the game server's code (a mitigation, not a
-- guarantee: the server's owner ships the client).
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

---Asks the game server something and hears its one answer: the request
---half of a request/response pair, whose other half is the server's
---`on_client_request` under the same name (J10). The platform pairs the
---answer with the request, which is all it adds to a message: on FiveM it is
---ox_lib's `lib.callback`, on Gmod a numbered `net` message. The core keeps
---its own timeout, so a platform that never answers is safe.
---@param name string The request's name, namespaced `rpf:`.
---@param payload string The request, already encoded.
---@param callback fun(reply: string?) Called at most once, with the server's answer as it sent it, or nil if the platform knows none will come. Never inside the call.
function ToServer.request_server(name, payload, callback) end

---Everything the player-client half of the core needs from its engine.
---`rpf.start_client` refuses a table missing any of it.
---@class rpf.ClientPlatform: rpf.platform.Engine, rpf.platform.Http, rpf.platform.Storage, rpf.platform.Clock, rpf.platform.ToServer, rpf.platform.Log, rpf.platform.Api
