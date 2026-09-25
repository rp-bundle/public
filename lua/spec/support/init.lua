---Test support: loading the core the way an adapter does, and a fake
---platform the tests drive by hand.
---
---The fake is deliberately small, and is not D3's mock platform: it exists so
---the core's own suite can run with no game, no portal and no socket. Its
---clock only moves when a test advances it, so every retry and backoff runs
---instantly and in a fixed order.
---@class spec.support
---@field root string The repository root, with a trailing slash.
local support = {}

local here = debug.getinfo(1, "S").source:sub(2)
-- `lua/` is this file's grandparent's parent, however busted was pointed at it.
support.root = here:gsub("spec/support/init%.lua$", "") .. "../"

---A path under the repository root.
---@param relative string Relative to the root, like `lua/core/json.lua`.
---@return string path The path.
function support.path(relative)
  return support.root .. relative
end

---Reads a whole file.
---@param relative string Relative to the repository root.
---@return string contents The file's contents.
function support.read(relative)
  local file = assert(io.open(support.path(relative), "rb"))
  local contents = file:read("*a")
  file:close()
  return contents
end

---Loads the core from scratch, as an adapter would: `init.lua` first, then
---each file in the order it declares, with no `require`.
---@param side "server"|"client"? Which side's files; the server by default.
---@return rpf rpf The fresh global.
function support.load_core(side)
  rawset(_G, "rpf", nil)
  dofile(support.path("lua/core/init.lua"))
  for _, file in ipairs(rpf.files[side or "server"]) do
    dofile(support.path("lua/core/" .. file))
  end
  return rpf
end

---2026-01-01T00:00:00Z, where every fake clock starts.
support.EPOCH_MS = 1767225600000

---Builds a fake server platform.
---@param opts { store: table<string, string>?, seed: integer?, time: number? }? A shared store (for restarts), a random seed, a start time.
---@return spec.FakePlatform platform The platform.
function support.fake_platform(opts)
  opts = opts or {}
  ---A fake server platform. Everything the core does to it is recorded, and
  ---the test plays the portal's side of the socket.
  ---@class spec.FakePlatform: rpf.ServerPlatform
  ---@field time number The fake clock, in milliseconds.
  ---@field timers { at: number, seq: integer, fn: fun() }[] Pending `after` callbacks.
  ---@field seq integer Orders timers due at the same moment.
  ---@field store table<string, string> The fake key-value store. Pass one table to two platforms to simulate a restart.
  ---@field rng integer The deterministic random state.
  ---@field socket { handlers: rpf.platform.SocketHandlers, open: boolean }? The current connection attempt.
  ---@field connects number[] When each `connect` was called, by the fake clock.
  ---@field sent string[] Every text frame sent on an open socket, in order.
  ---@field logs { level: string, message: string }[] Every log line.
  ---@field exposed table? What `expose` was given.
  local p = {
    engine = "mock",
    time = opts.time or support.EPOCH_MS,
    timers = {},
    seq = 0,
    store = opts.store or {},
    rng = opts.seed or 12345,
    connects = {},
    sent = {},
    logs = {},
  }

  function p.now()
    return p.time
  end

  function p.after(delay_ms, fn)
    p.seq = p.seq + 1
    p.timers[#p.timers + 1] = { at = p.time + delay_ms, seq = p.seq, fn = fn }
  end

  function p.kv_get(key)
    return p.store[key]
  end

  function p.kv_set(key, value)
    p.store[key] = value
  end

  -- MINSTD: every product stays below 2^53, so it is exact on LuaJIT too.
  function p.random_hex(n)
    local digits = {}
    for i = 1, n do
      p.rng = (p.rng * 48271) % 2147483647
      digits[i] = ("0123456789abcdef"):sub(p.rng % 16 + 1, p.rng % 16 + 1)
    end
    return table.concat(digits)
  end

  function p.connect(_, handlers)
    p.connects[#p.connects + 1] = p.time
    p.socket = { handlers = handlers, open = false }
  end

  function p.send(text)
    if p.socket and p.socket.open then
      p.sent[#p.sent + 1] = text
      return true
    end
    return false
  end

  function p.http_request(_, _, _, _, callback)
    p.after(0, function()
      callback(0, "", {})
    end)
  end

  function p.identifiers()
    return {}
  end

  function p.name()
    return "player"
  end

  function p.kick() end

  function p.notify() end

  function p.to_client() end

  function p.on_client() end

  function p.log(level, message)
    p.logs[#p.logs + 1] = { level = level, message = message }
  end

  function p.expose(api)
    p.exposed = api
  end

  -- Driving it ---------------------------------------------------------------

  ---Moves the clock forward, running every timer that falls due, in order,
  ---including ones those timers schedule.
  ---@param ms number How far.
  function p.advance(ms)
    local target = p.time + ms
    while true do
      local best
      for i, timer in ipairs(p.timers) do
        if timer.at <= target then
          local b = best and p.timers[best]
          if not b or timer.at < b.at or (timer.at == b.at and timer.seq < b.seq) then
            best = i
          end
        end
      end
      if not best then
        break
      end
      local timer = table.remove(p.timers, best)
      p.time = timer.at
      timer.fn()
    end
    p.time = target
  end

  ---Completes the pending connection attempt.
  function p.open()
    assert(p.socket, "nothing is connecting")
    p.socket.open = true
    p.socket.handlers.open()
  end

  ---Ends the current connection, or fails the pending attempt.
  ---@param reason string? What the platform reports.
  function p.drop(reason)
    local socket = assert(p.socket, "nothing is connected")
    p.socket = nil
    socket.open = false
    socket.handlers.close(reason or "dropped")
  end

  ---Delivers one frame from the portal: a table (encoded here) or raw text.
  ---@param frame table|string The frame.
  function p.deliver(frame)
    local text
    if type(frame) == "table" then
      text = assert(rpf.protocol.encode(rpf.protocol.PORTAL_TO_SERVER, frame))
    else
      text = frame
    end
    assert(p.socket, "nothing is connected").handlers.message(text)
  end

  ---Every sent frame, decoded as the portal would.
  ---@return rpf.Frame[] frames The frames, in order.
  function p.frames()
    local out = {}
    for i, text in ipairs(p.sent) do
      out[i] = assert(rpf.protocol.decode(rpf.protocol.SERVER_TO_PORTAL, text))
    end
    return out
  end

  ---The last frame sent, decoded.
  ---@return rpf.Frame frame The frame.
  function p.last()
    local frames = p.frames()
    return frames[#frames]
  end

  ---Log lines at a level that contain some text.
  ---@param level string The level.
  ---@param text string Plain text to look for.
  ---@return string[] lines The matching lines.
  function p.logged(level, text)
    local out = {}
    for _, line in ipairs(p.logs) do
      if line.level == level and line.message:find(text, 1, true) then
        out[#out + 1] = line.message
      end
    end
    return out
  end

  return p
end

---A fake client platform, with only what the client interface asks for.
---@return rpf.ClientPlatform platform The platform.
function support.fake_client_platform()
  local store = {}
  return {
    engine = "mock",
    http_request = function(_, _, _, _, callback)
      callback(0, "", {})
    end,
    kv_get = function(key)
      return store[key]
    end,
    kv_set = function(key, value)
      store[key] = value
    end,
    now = function()
      return support.EPOCH_MS
    end,
    after = function() end,
    to_server = function() end,
    on_server = function() end,
    log = function() end,
  }
end

---A portal frame, with a fresh id from a fixed source.
---@param tag string The message type.
---@param fields table? Its fields.
---@return rpf.Frame frame The frame, not yet encoded.
function support.portal_frame(tag, fields)
  support.portal_rng = support.portal_rng or support.fake_platform({ seed = 777 })
  return rpf.protocol.envelope(support.portal_rng, tag, fields)
end

---Starts a connection on a fake platform and completes the handshake.
---@param p spec.FakePlatform The platform.
---@param options rpf.ClientOptions? Timing overrides.
---@return rpf.Client connection The connection, ready.
function support.connected(p, options)
  local connection = rpf.start_server(p, { url = "ws://portal", api_key = "rpf_test_secret", client = options })
  p.open()
  local hello = p.last()
  p.deliver(support.portal_frame("welcome", {
    re = hello.id,
    protocol = 1,
    server_id = "00000001-0000-4000-8000-000000000001",
  }))
  return connection
end

return support
