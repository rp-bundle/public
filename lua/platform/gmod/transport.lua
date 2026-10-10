---The websocket to the portal, over GWSockets: the server platform's
---`connect`, `disconnect` and `send`.
---
---Gmod has no websocket of its own, and GWSockets is the maintained binary
---module that adds one (decided in #57: required, no fallback). The adapter
---refuses to start without it (`server.lua`), so this file can assume the
---`GWSockets` global.
---
---GWSockets reports a connection through callbacks on the socket object
---(`onConnected`, `onMessage`, `onError`, `onDisconnected`), run from its own
---`Think` hook on the main thread. This turns them into the core's contract
---(`rpf.platform.Transport`):
---
--- - `open` once the socket is up, or `close` if it never comes up, never both
---   for a failed attempt. `onError` is always followed by `onDisconnected`,
---   so the error is kept as the close reason rather than reported twice.
--- - `close` exactly once per `connect`, and nothing after it, however
---   GWSockets orders its callbacks. Each connect gets its own record, so a
---   late callback from an abandoned socket reaches only that socket's
---   handlers, which the core has stopped listening to.
--- - One connection at a time: `disconnect` closes it at once (`closeNow`,
---   which drops anything still queued: the core keeps every frame in its
---   outbox until it is answered, so nothing is lost) and reports its close on
---   the next tick.
---
---A GWSockets call that raises (`open`, `write`, `closeNow`) is logged at `warn`, once
---per connection for a send, and the transport keeps its answer to the core: a
---failed send is `false`, and a failed close is still reported as a close. What
---a refused frame means is the core's to decide; this only keeps the cause,
---which is gone by the time the connection is noticed dead.
---
---The certificate is always verified. Text frames only: every frame is JSON.
---@class rpf.gmod.Transport
local transport = {}

local shared = include("rpf/platform/gmod/shared.lua") --[[@as rpf.gmod.Shared]]

---One connection attempt and what has been reported for it.
---@class rpf.gmod.Connection
---@field socket GWSocket? The GWSockets object, nil if it could not be made.
---@field handlers rpf.platform.SocketHandlers The core's handlers for this attempt.
---@field open boolean Whether `open` has been reported.
---@field closed boolean Whether `close` has been reported. Nothing is reported after it.
---@field error string? The last error GWSockets reported, kept for the close reason.
---@field send_failed boolean Whether a failed `write` has been logged, so a connection that keeps being written to says why once.

---The current connection attempt, if any.
---@type rpf.gmod.Connection?
local current = nil

---Reports a connection's close, once, and forgets it if it is current.
---@param connection rpf.gmod.Connection The connection.
---@param reason string Why it closed.
local function finish(connection, reason)
  if connection.closed then
    return
  end
  connection.closed = true
  if current == connection then
    current = nil
  end
  connection.handlers.close(reason)
end

---Opens a connection to the portal, replacing any earlier one.
---@param url string The portal's websocket url, `wss://…/ws`.
---@param handlers rpf.platform.SocketHandlers Where events go.
function transport.connect(url, handlers)
  if current then
    transport.disconnect()
  end
  ---@type rpf.gmod.Connection
  local connection = { handlers = handlers, open = false, closed = false, send_failed = false }
  current = connection
  local made, socket = pcall(GWSockets.createWebSocket, url, true)
  if not made or not socket then
    timer.Simple(0, function()
      finish(connection, "could not open a websocket: " .. tostring(socket))
    end)
    return
  end
  ---@cast socket GWSocket
  connection.socket = socket
  function socket:onConnected()
    if not connection.closed and not connection.open then
      connection.open = true
      handlers.open()
    end
  end
  function socket:onMessage(text)
    if connection.open and not connection.closed then
      handlers.message(text)
    end
  end
  function socket:onError(message)
    connection.error = tostring(message)
  end
  function socket:onDisconnected()
    finish(connection, connection.error or "the connection closed")
  end
  local opened, err = pcall(socket.open, socket)
  if not opened then
    -- The attempt never started, so GWSockets will report nothing for it: the
    -- close is ours to owe, or the core never backs off and tries again.
    shared.log("warn", "rpf: GWSockets could not open the websocket: " .. tostring(err))
    timer.Simple(0, function()
      finish(connection, "could not open a websocket: " .. tostring(err))
    end)
  end
end

---Closes the current connection, or abandons the attempt under way. Its
---`close` is reported on the next tick.
function transport.disconnect()
  local connection = current
  if not connection then
    return
  end
  current = nil
  if connection.socket then
    local ok, err = pcall(connection.socket.closeNow, connection.socket)
    if not ok then
      shared.log("warn", "rpf: GWSockets could not close the websocket: " .. tostring(err))
    end
  end
  timer.Simple(0, function()
    finish(connection, "closed by the core")
  end)
end

---Sends one text frame on the open connection.
---@param text string The frame.
---@return boolean sent False when no connection is open, or GWSockets raised on the write (logged once per connection).
function transport.send(text)
  local connection = current
  if not connection or not connection.open or connection.closed or not connection.socket then
    return false
  end
  local ok, err = pcall(connection.socket.write, connection.socket, text)
  if not ok and not connection.send_failed then
    connection.send_failed = true
    shared.log("warn", "rpf: GWSockets could not send a frame: " .. tostring(err))
  end
  return ok
end

return transport
