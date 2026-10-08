---@meta

-- The contract between the FiveM adapter's Lua and the `rpf-ws` shim (D2),
-- for the language server. Never loaded.
--
-- FiveM's Lua runtime has no websocket client, so the `rpf-ws` resource owns
-- the portal socket in FiveM's JS runtime. Lua calls it through `exports`
-- and hears from it through server-local events; FiveM serialises every
-- argument both ways with msgpack. Frames cross as JSON strings, never as
-- tables: the shim never parses one, so `rpf.json` stays the only codec and
-- the marshalling surface is one string per frame.
--
-- This is one of two copies of the contract. The other is
-- `ws-shim/src/contract.ts`, checked by `tsc --strict`; this one is checked
-- by lua-language-server wherever the adapter uses it. The shim's
-- `test/contract.test.ts` fails when the two disagree on a name, a
-- parameter or a type, and drives the real shim from `ws.lua` across an
-- emulated boundary.

---What `rpf-ws` exports, called as `exports["rpf-ws"]:<name>(...)`. Every
---argument and result is a string, a number or a boolean, never a table, so
---msgpack has nothing to get wrong.
---@class rpf.fivem.WsShim
local WsShim = {}

---Opens a websocket. Returns at once with the connection's id; the outcome
---arrives as events naming it: `open`, any number of `message`, and exactly
---one `close`, or a `close` alone if it never opened.
---@param url string The portal's `ws://` or `wss://` url.
---@return integer id A new id, never reused while `rpf-ws` runs.
function WsShim:connect(url) end

---Sends one text frame on an open connection.
---@param id integer The connection, from `connect`.
---@param text string The frame, already encoded by `rpf.json`. Never parsed by the shim.
---@return boolean sent False when that connection is not open; the core keeps the frame in its outbox.
function WsShim:send(id, text) end

---Closes a connection, or abandons it while it opens. Its `close` event
---still arrives, once. Does nothing for an id that is closed or unknown.
---@param id integer The connection, from `connect`.
function WsShim:close(id) end

---Random lowercase hex digits from Node's cryptographic generator, the best
---randomness a FiveM server offers Lua.
---@param n integer How many digits, from 1 to 1024.
---@return string hex Exactly `n` characters from `0-9a-f`.
function WsShim:random_hex(n) end

---The events `rpf-ws` emits to this adapter, as server-local events
---(`TriggerEvent`), never network events, so no client can forge one. Each
---names its connection, so an event from one the adapter gave up on is
---recognised and ignored.
---@class rpf.fivem.WsEvents
local WsEvents = {}

---The connection is open and `send` works.
---@param id integer The connection.
WsEvents["rpf-ws:open"] = function(id) end

---One text frame arrived, verbatim.
---@param id integer The connection.
---@param text string The frame, as the portal sent it.
WsEvents["rpf-ws:message"] = function(id, text) end

---The connection ended, or never opened. Exactly once per `connect`, and
---nothing for that id follows it.
---@param id integer The connection.
---@param code integer The websocket close code, 1006 when the socket failed or never opened.
---@param reason string The peer's close reason, or a description of the failure.
WsEvents["rpf-ws:close"] = function(id, code, reason) end
