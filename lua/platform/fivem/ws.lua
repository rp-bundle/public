---The server platform's transport (`connect`, `disconnect`, `send`) over the
---`rpf-ws` shim (D2), whose contract is `transport.lua`.
---
---The shim names every connection by an id and reports it through events;
---this keeps the core's handlers for each id until its `close`, exactly as
---the mock platform does, so the core sees one `close` per `connect` and
---nothing after it. It never parses a frame: text in, text out.
---@class rpf.fivem.ws
local ws = {}

local rpf = rpf

---One transport: the three platform members, and the three functions the
---adapter's event handlers call when the shim reports something.
---@class rpf.fivem.Transport
---@field connect fun(url: string, handlers: rpf.platform.SocketHandlers) The platform's `connect`.
---@field disconnect fun() The platform's `disconnect`.
---@field send fun(text: string): boolean The platform's `send`.
---@field opened fun(id: any) `rpf-ws:open` arrived.
---@field received fun(id: any, text: any) `rpf-ws:message` arrived.
---@field closed fun(id: any, code: any, reason: any) `rpf-ws:close` arrived.
---@field stop fun() Closes every connection the shim still has open for this transport, because the resource is stopping: the shim outlives it, and a socket left open would keep answering the portal's pings for an instance that is gone.

---The close reason the core logs, from the shim's code and reason.
---@param code any The close code, a number from the shim.
---@param reason any The reason, a string from the shim.
---@return string reason One line.
local function describe(code, reason)
  local line = "closed (" .. tostring(code) .. ")"
  if type(reason) == "string" and reason ~= "" then
    line = line .. ": " .. reason
  end
  return line
end

---Builds a transport over the shim.
---@param shim rpf.fivem.WsShim `exports["rpf-ws"]`.
---@param after fun(delay_ms: number, callback: fun()) The platform's timer, for a close owed by a connect that never reached the shim.
---@param log fun(level: string, message: string) The platform's log.
---@return rpf.fivem.Transport transport The transport.
function ws.new(shim, after, log)
  ---Handlers for each connection the shim has not reported closed, by id.
  ---@type table<integer, rpf.platform.SocketHandlers>
  local sockets = {}
  ---The connection `send` and `disconnect` use: the latest one opened,
  ---until it closes or is given up.
  ---@type integer?
  local current = nil

  -- A shim that is missing or throws still owes the core its one `close`,
  -- later, as the interface promises, so the core backs off and tries again
  -- rather than waiting for ever.
  local function connect(url, handlers)
    local ok, id = pcall(shim.connect, shim, url)
    if not ok or type(id) ~= "number" then
      log("error", "rpf: the rpf-ws resource could not open a socket: " .. tostring(id))
      current = nil
      after(0, function()
        handlers.close("rpf-ws unavailable")
      end)
      return
    end
    sockets[id] = handlers
    current = id
  end

  -- A close the shim fails is logged, not retried: the socket may still be
  -- open in `rpf-ws`, and the log is what says why a restarted core is
  -- refused as a duplicate instance.
  local function close(id)
    local ok, err = pcall(shim.close, shim, id)
    if not ok then
      log("error", "rpf: the rpf-ws resource could not close socket " .. tostring(id) .. ": " .. tostring(err))
    end
  end

  -- The handlers stay until the shim reports the close, so `close` is still
  -- called once for this connect.
  local function disconnect()
    local id = current
    if id then
      current = nil
      close(id)
    end
  end

  local function send(text)
    local id = current
    if not id then
      return false
    end
    local ok, sent = pcall(shim.send, shim, id, text)
    return ok and sent == true
  end

  local function opened(id)
    local handlers = sockets[id]
    if handlers then
      handlers.open()
    end
  end

  local function received(id, text)
    local handlers = sockets[id]
    if handlers and type(text) == "string" then
      handlers.message(text)
    end
  end

  local function closed(id, code, reason)
    local handlers = sockets[id]
    if handlers then
      sockets[id] = nil
      if current == id then
        current = nil
      end
      handlers.close(describe(code, reason))
    end
  end

  local function stop()
    current = nil
    for id in pairs(sockets) do
      close(id)
    end
  end

  return {
    stop = stop,
    connect = connect,
    disconnect = disconnect,
    send = send,
    opened = opened,
    received = received,
    closed = closed,
  }
end

rpf.fivem.ws = ws
return ws
