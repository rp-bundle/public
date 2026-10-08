---@meta

-- The part of GWSockets (https://github.com/FredyH/GWSockets) the adapter
-- uses, for the language server. GWSockets is a binary module and ships no
-- annotations, so these follow its README. This file is a definition and is
-- never loaded; `require("gwsockets")` is what defines the global.

---The GWSockets library, defined by `require("gwsockets")`.
---@class GWSockets
GWSockets = {}

---Makes a websocket object. Nothing connects until `open`.
---@param url string The url, with its `ws://` or `wss://` scheme.
---@param verify_certificate boolean? Whether to verify the server's certificate. True unless given false.
---@return GWSocket socket The socket.
function GWSockets.createWebSocket(url, verify_certificate) end

---One websocket. Its callbacks are fields the caller assigns, run on the main
---thread from GWSockets' own `Think` hook.
---@class GWSocket
local GWSocket = {}

---Starts connecting.
---@param clear_queue boolean? Whether to drop messages queued before the connection opened. True unless given false.
function GWSocket:open(clear_queue) end

---Queues a message, sent once the connection is open.
---@param message string The message.
---@param binary boolean? Send a binary frame rather than text.
function GWSocket:write(message, binary) end

---Closes the connection after the queued messages are sent.
function GWSocket:close() end

---Closes the connection at once, dropping queued messages.
function GWSocket:closeNow() end

---Whether the connection is open. GWSockets advises the callbacks instead.
---@return boolean connected True while open.
function GWSocket:isConnected() end

---Called with each message from the peer.
---@param message string The message.
function GWSocket:onMessage(message) end

---Called when anything goes wrong. Always followed by `onDisconnected`.
---@param message string What went wrong.
function GWSocket:onError(message) end

---Called once the connection is open.
function GWSocket:onConnected() end

---Called once the connection has closed, for whatever reason, including a
---connection that never opened.
function GWSocket:onDisconnected() end
