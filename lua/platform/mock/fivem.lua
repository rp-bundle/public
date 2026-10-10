---Fake FiveM globals (D2), so the real FiveM adapter (`lua/platform/fivem/`)
---runs unmodified with no game: under busted (`spec/fivem_spec.lua`), and
---in the fake game server (`crates/fake-server/`), which drives it against
---the real portal exactly as it drives the mock platform.
---
---Each fake is the least an engine does that the adapter relies on, built on
---the mock platform's host (`rpf.mock.ServerHost`, `rpf.mock.ClientHost`), so
---a harness that can drive the mock can drive the adapter: the same clock,
---storage, socket and HTTP, and a driver table with the mock's driving
---functions (`socket_open`, `run_due`, `from_client`, …) plus the engine
---events only an adapter listens for (`connect_player`, `drop_player`).
---
---What it models, because the adapter depends on it:
---
---- **Events.** `AddEventHandler` and `RegisterNetEvent`, with `source` set
---  while a handler runs. A client can only reach a name some script passed
---  to `RegisterNetEvent`; anything else it sends is dropped, as FiveM does.
---- **The `rpf-ws` shim**, behind `exports["rpf-ws"]`, called with a
---  receiver as `exports` calls are, and reporting through the three
---  `rpf-ws:` events, at most one `close` per connection.
---- **FiveM's HTTP**, whose callback carries a failure's body in its fourth
---  argument and status 0 when nothing came back.
---- **The clock as FiveM splits it**: `os.time` in whole seconds, and a
---  millisecond `GetGameTimer` that never goes back.
---
---It is not FiveM. A real server is layer 5 (`docs/testing.md`).
---@class rpf.mock.fivem
---@field mock rpf.mock The mock platform these fakes are built on, set by `bind`.
local fivem = {}

---Loads a resource manifest and lists the scripts it names for one side,
---as FiveM reads it. The manifest is Lua that calls directives, so it runs
---here with each directive recording what it was given.
---@param source string The manifest's text.
---@param side "server"|"client" Which scripts.
---@return string[] scripts Paths relative to the resource, in load order.
function fivem.scripts(source, side)
  local found = { server = {}, client = {} }
  local env = {}
  local function record(kind)
    return function(list)
      if type(list) == "string" then
        list = { list }
      end
      for _, path in ipairs(list) do
        found[kind][#found[kind] + 1] = path
      end
    end
  end
  env.server_scripts, env.server_script = record("server"), record("server")
  env.client_scripts, env.client_script = record("client"), record("client")
  setmetatable(env, {
    __index = function()
      return function() end
    end,
  })
  -- Lua 5.1 binds a chunk's globals with `setfenv`; LuaJIT and 5.4 take
  -- them as `load`'s fourth argument.
  local chunk
  if rawget(_G, "setfenv") then
    chunk = assert(loadstring(source, "=fxmanifest.lua"))
    setfenv(chunk, env)
  else
    chunk = assert(load(source, "=fxmanifest.lua", "t", env))
  end
  chunk()
  return found[side]
end

---The parts both sides share: events, timers, storage, convars, exports.
---@param env table The global table the adapter runs in.
---@param host rpf.mock.ServerHost|rpf.mock.ClientHost The harness's half.
---@param p rpf.mock.Common A mock platform over the same host, for its timers and HTTP.
---@param convars table<string, string> The convars `GetConvar` answers with.
---@return table events Handlers by event name.
---@return fun(name: string, from: any, ...): boolean fire Runs an event's handlers with `source` set, and says whether one cancelled it.
local function common(env, host, p, convars)
  local handlers = {}
  local cancelled = false

  local function fire(name, from, ...)
    local saved, was = env.source, cancelled
    cancelled = false
    for _, handler in ipairs(handlers[name] or {}) do
      env.source = from
      handler(...)
    end
    env.source = saved
    local result = cancelled
    cancelled = was
    return result
  end

  env.CancelEvent = function()
    cancelled = true
  end

  env.AddEventHandler = function(name, handler)
    handlers[name] = handlers[name] or {}
    handlers[name][#handlers[name] + 1] = handler
    return { name = name, key = #handlers[name] }
  end

  env.Citizen = {
    SetTimeout = function(delay, callback)
      p.after(delay, callback)
    end,
  }

  -- Monotonic, as FiveM's is, even when the host's wall clock is set back.
  local boot, highest = host.now(), 0
  env.GetGameTimer = function()
    highest = math.max(highest, host.now() - boot)
    return highest
  end

  env.GetResourceKvpString = function(key)
    return host.kv_get(key)
  end
  env.SetResourceKvp = function(key, value)
    host.kv_set(key, value)
  end
  env.DeleteResourceKvp = function(key)
    host.kv_set(key, nil)
  end

  env.GetConvar = function(name, default)
    local value = convars[name]
    if value == nil then
      return default
    end
    return value
  end

  env.GetCurrentResourceName = function()
    return "rpf"
  end

  -- What the adapter logs arrives as `[rpf] <level>: <message>`.
  env.print = function(line)
    local level, message = tostring(line):match("^%[rpf%] (%a+): (.*)$")
    host.log(level or "info", message or tostring(line))
  end

  return handlers, fire
end

---Fake FiveM server globals, with the `rpf-ws` shim, over a mock host.
---@param env table The global table the adapter will run in. Written to.
---@param host rpf.mock.ServerHost The harness's half, as for `mock.server`.
---@param seed integer The random seed, as for `mock.server`.
---@param convars table<string, string> The server's convars (`rpf_url`, `rpf_api_key`, …). `onesync` is `on` unless given, as on a current FXServer.
---@return rpf.mock.FivemServer driver What the harness drives it with.
function fivem.server(env, host, seed, convars)
  local p = fivem.mock.server(host, seed)
  local with_defaults = { onesync = "on" }
  for name, value in pairs(convars) do
    with_defaults[name] = value
  end
  local _, fire = common(env, host, p, with_defaults)
  local net = {}
  local own_exports = {}
  local open = {}

  ---The driver: the mock server's driving functions, over these globals.
  ---@class rpf.mock.FivemServer
  ---@field exported table<string, function> What the adapter exported, by name.
  ---@field socket_open fun(id: integer) The host's socket opened.
  ---@field socket_message fun(id: integer, text: string) A frame arrived on it.
  ---@field socket_close fun(id: integer, reason: string) It closed, or never opened.
  ---@field from_client fun(player: integer, name: string, payload: any) A client triggered a net event.
  ---@field add_player fun(player: integer, name: string, identifiers: string[]) The engine knows a player.
  ---@field remove_player fun(player: integer) The engine forgot them.
  ---@field connect_player fun(player: integer) `playerJoining`, for a player `add_player` told it about.
  ---@field drop_player fun(player: integer, reason: string) `playerDropped`.
  ---@field chat fun(player: integer, message: string): boolean The `chat` resource's `chatMessage`, and whether a handler cancelled it.
  ---@field bucket fun(player: integer): integer The routing bucket a player is in.
  ---@field lockdown table<integer, string> Each routing bucket's entity lockdown mode, as set.
  ---@field start fun() `onResourceStart` for this resource, which is when the adapter starts the core.
  ---@field stop fun() `onResourceStop` for this resource, as `restart rpf` sends before the state goes.
  ---@field run_due fun() Runs every timer due.
  ---@field next_due fun(): number? When the next timer is due.
  ---@field http_done fun(id: integer, status: integer, body: string, headers: table<string, string>?) Answers a request.
  ---@field resources table<string, string> Each resource's state as `GetResourceState` reports it: `rpf` and `rpf-ws` started. Anything else is `missing`.
  local driver = { exported = own_exports, lockdown = {}, resources = { rpf = "started", ["rpf-ws"] = "started" } }
  local buckets = {}

  env.os = setmetatable({
    time = function()
      return math.floor(host.now() / 1000)
    end,
  }, { __index = os })

  env.RegisterNetEvent = function(name, handler)
    net[name] = true
    if handler then
      env.AddEventHandler(name, handler)
    end
  end

  env.TriggerClientEvent = function(name, player, payload)
    if name == "rpf:notify" then
      host.notify(player, payload)
    else
      host.to_client(player, name, payload)
    end
  end

  env.GetPlayerIdentifiers = function(player)
    return p.identifiers(tonumber(player))
  end
  env.GetPlayerName = function(player)
    local known = p.players[tonumber(player)]
    return known and known.name or nil
  end
  env.GetPlayers = function()
    local out = {}
    for player in pairs(p.players) do
      out[#out + 1] = tostring(player)
    end
    table.sort(out)
    return out
  end
  env.GetPlayerRoutingBucket = function(player)
    return buckets[tonumber(player)] or 0
  end
  env.SetPlayerRoutingBucket = function(player, bucket)
    buckets[tonumber(player)] = bucket
  end
  env.SetRoutingBucketEntityLockdownMode = function(bucket, mode)
    driver.lockdown[bucket] = mode
  end
  env.GetResourceState = function(name)
    return driver.resources[name] or "missing"
  end
  env.DropPlayer = function(player, reason)
    host.kick(tonumber(player), reason)
  end

  -- FiveM's shape: a success's body second, a failure's in `errorData`,
  -- and status 0 with no body when nothing came back.
  env.PerformHttpRequest = function(url, callback, method, data, headers)
    p.http_request(method or "GET", url, headers or {}, data ~= "" and data or nil, function(status, body, received)
      if status == 0 then
        callback(0, nil, {}, "the request failed")
      elseif status >= 200 and status < 300 then
        callback(status, body, received)
      else
        callback(status, nil, received, body)
      end
    end)
  end

  local shim = {
    connect = function(_, url)
      p.seq = p.seq + 1
      open[p.seq] = "opening"
      host.connect(p.seq, url)
      return p.seq
    end,
    send = function(_, id, text)
      if open[id] ~= "open" then
        return false
      end
      return host.send(id, text)
    end,
    close = function(_, id)
      if open[id] then
        host.close(id)
      end
    end,
    random_hex = function(_, n)
      return p.random_hex(n)
    end,
  }
  env.exports = setmetatable({}, {
    __call = function(_, name, fn)
      own_exports[name] = fn
    end,
    __index = function(_, resource)
      if resource == "rpf-ws" then
        return shim
      end
      return nil
    end,
  })

  function driver.socket_open(id)
    if open[id] == "opening" then
      open[id] = "open"
      fire("rpf-ws:open", "", id)
    end
  end

  function driver.socket_message(id, text)
    if open[id] == "open" then
      fire("rpf-ws:message", "", id, text)
    end
  end

  function driver.socket_close(id, reason)
    if open[id] then
      open[id] = nil
      fire("rpf-ws:close", "", id, 1006, reason)
    end
  end

  function driver.from_client(player, name, payload)
    if net[name] then
      fire(name, player, payload)
    end
  end

  driver.add_player = p.add_player
  driver.remove_player = p.remove_player

  function driver.connect_player(player)
    fire("playerJoining", player, player)
  end

  function driver.drop_player(player, reason)
    fire("playerDropped", player, reason)
  end

  function driver.chat(player, message)
    return fire("chatMessage", player, player, "name", message)
  end

  function driver.bucket(player)
    return buckets[player] or 0
  end

  function driver.start()
    fire("onResourceStart", "", "rpf")
  end

  function driver.stop()
    fire("onResourceStop", "", "rpf")
  end

  driver.run_due = p.run_due
  driver.next_due = p.next_due
  driver.http_done = p.http_done
  return driver
end

---Fake FiveM client globals, NUI included, over a mock host.
---@param env table The global table the adapter will run in. Written to.
---@param host rpf.mock.ClientHost The harness's half, as for `mock.client`.
---@param seed integer The random seed, as for `mock.client`.
---@param convars table<string, string>? The convars the client sees.
---@return rpf.mock.FivemClient driver What the test drives it with.
function fivem.client(env, host, seed, convars)
  local p = fivem.mock.client(host, seed)
  local _, fire = common(env, host, p, convars or {})
  local nui = {}

  ---The driver for a client.
  ---@class rpf.mock.FivemClient
  ---@field exported table<string, function> What the adapter exported, by name.
  ---@field nui_sent string[] Every message sent to the page, as JSON text.
  ---@field focus boolean Whether the page has focus.
  ---@field frozen boolean Whether the ped is frozen.
  ---@field feed string[] Every notification shown.
  ---@field nui fun(name: string, data: any): any Calls an NUI callback as the page does, and returns its answer.
  ---@field from_server fun(name: string, payload: any) The server triggered a net event.
  ---@field start fun() `onClientResourceStart` for this resource.
  ---@field stop fun() `onClientResourceStop` for this resource.
  ---@field run_due fun() Runs every timer due.
  ---@field next_due fun(): number? When the next timer is due.
  local driver = { exported = {}, nui_sent = {}, focus = false, frozen = false, feed = {} }
  local net = {}
  local text = {}

  env.GetCloudTimeAsInt = function()
    return math.floor(host.now() / 1000)
  end
  env.RegisterNetEvent = function(name, handler)
    net[name] = true
    if handler then
      env.AddEventHandler(name, handler)
    end
  end
  env.TriggerServerEvent = function(name, payload)
    host.to_server(name, payload)
  end
  env.RegisterNUICallback = function(name, handler)
    nui[name] = handler
  end
  env.SendNuiMessage = function(json)
    driver.nui_sent[#driver.nui_sent + 1] = json
  end
  env.SetNuiFocus = function(focus)
    driver.focus = focus
  end
  env.PlayerPedId = function()
    return 1
  end
  env.FreezeEntityPosition = function(_, frozen)
    driver.frozen = frozen
  end
  env.BeginTextCommandThefeedPost = function()
    text = {}
  end
  env.AddTextComponentSubstringPlayerName = function(part)
    text[#text + 1] = part
  end
  env.EndTextCommandThefeedPostTicker = function()
    driver.feed[#driver.feed + 1] = table.concat(text)
  end
  env.exports = setmetatable({}, {
    __call = function(_, name, fn)
      driver.exported[name] = fn
    end,
  })

  function driver.nui(name, data)
    local answer
    local handler = nui[name]
    if handler then
      handler(data, function(reply)
        answer = reply
      end)
    end
    return answer
  end

  function driver.from_server(name, payload)
    if net[name] then
      fire(name, "", payload)
    end
  end

  function driver.start()
    fire("onClientResourceStart", "", "rpf")
  end

  function driver.stop()
    fire("onClientResourceStop", "", "rpf")
  end

  driver.run_due = p.run_due
  driver.next_due = p.next_due
  return driver
end

---Builds the fakes over a loaded mock platform module: `fivem.lua` needs
---the mock's timers, storage and sockets, and is loaded beside it, as
---`dofile` loads any file, so it is handed the module rather than finding it.
---@param mock rpf.mock The mock platform module (`lua/platform/mock/init.lua`).
---@return rpf.mock.fivem fivem This module, bound to it.
function fivem.bind(mock)
  fivem.mock = mock
  return fivem
end

return fivem
