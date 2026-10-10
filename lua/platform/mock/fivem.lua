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
---- **ox_lib, as far as the adapter uses it** (J10): `lib.callback` and
---  `lib.callback.register`, with `promise` and `Citizen.Await` to wait on
---  an answer from inside a callback, which runs on a thread of its own as
---  ox_lib's do; and on the client the UI addons show, recorded for a test
---  to answer as a player would (`notify`, the context menu, `inputDialog`
---  and `progressBar`, which wait on their thread as ox_lib's do). Its wire is not ox_lib's: a request and its answer cross
---  the host as the mock platform frames them (`mock.frame`), under the
---  request's name, so a harness plays a client of any engine alike.
---  `ox_lib` is a started resource at version 3.40.0 unless a test says
---  otherwise (`resources`, `metadata`).
---
---It is not FiveM. A real server is layer 5 (`docs/testing.md`).
---@class rpf.mock.fivem
---@field mock rpf.mock The mock platform these fakes are built on, set by `bind`.
local fivem = {}

---Loads a resource manifest and lists the scripts it names for one side,
---as FiveM reads it: its shared scripts first, then the side's own. The
---manifest is Lua that calls directives, so it runs here with each
---directive recording what it was given. A script in another resource
---(`@ox_lib/init.lua`) is left out, because the fakes stand in for what it
---does (`fivem.imports` lists them).
---@param source string The manifest's text.
---@param side "server"|"client" Which scripts.
---@return string[] scripts Paths relative to the resource, in load order.
function fivem.scripts(source, side)
  local all = fivem.manifest(source)
  local out = {}
  for _, kind in ipairs({ "shared", side }) do
    for _, path in ipairs(all[kind]) do
      if path:sub(1, 1) ~= "@" then
        out[#out + 1] = path
      end
    end
  end
  return out
end

---The scripts a manifest loads from other resources (`@<resource>/<file>`),
---which the fakes stand in for.
---@param source string The manifest's text.
---@return string[] imports The paths, as the manifest gives them.
function fivem.imports(source)
  local out = {}
  for _, kind in ipairs({ "shared", "server", "client" }) do
    for _, path in ipairs(fivem.manifest(source)[kind]) do
      if path:sub(1, 1) == "@" then
        out[#out + 1] = path
      end
    end
  end
  return out
end

---Every script a manifest names, by kind, and the resources it depends on.
---@param source string The manifest's text.
---@return { shared: string[], server: string[], client: string[], dependencies: string[] } found What it names, in order.
function fivem.manifest(source)
  local found = { shared = {}, server = {}, client = {}, dependencies = {} }
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
  env.shared_scripts, env.shared_script = record("shared"), record("shared")
  env.server_scripts, env.server_script = record("server"), record("server")
  env.client_scripts, env.client_script = record("client"), record("client")
  env.dependencies, env.dependency = record("dependencies"), record("dependencies")
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
  return found
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

  -- A promise is resolved once; `Citizen.Await` returns its value at once
  -- if it has one, and otherwise waits on the thread it runs on, as FiveM's
  -- does, so a callback that waits must be running on one (`thread`).
  env.promise = {
    new = function()
      local waiters = {}
      local promise = { resolved = false }
      function promise.resolve(self, value)
        if self.resolved then
          return
        end
        self.resolved, self.value = true, value
        for _, waiter in ipairs(waiters) do
          local ok, err = coroutine.resume(waiter)
          if not ok then
            error(err, 0)
          end
        end
      end
      promise.waiters = waiters
      return promise
    end,
  }

  env.Citizen = {
    SetTimeout = function(delay, callback)
      p.after(delay, callback)
    end,
    Await = function(promise)
      if not promise.resolved then
        local running, main = coroutine.running()
        assert(running and not main, "fake FiveM: Citizen.Await outside a thread")
        promise.waiters[#promise.waiters + 1] = running
        coroutine.yield()
      end
      return promise.value
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

---Runs a function on a thread of its own, as FiveM runs an event's
---handler, so it may wait (`Citizen.Await`). An error is raised, not
---printed, so a test sees it.
---@param fn fun() The function.
local function thread(fn)
  local ok, err = coroutine.resume(coroutine.create(fn))
  if not ok then
    error(err, 0)
  end
end

---A fake `lib.callback` for one side: `lib.callback(name, target, cb, payload)`
---asks the other side and hands `cb` its answer, and `lib.callback.register`
---answers the other side's requests, each on a thread of its own. Requests
---and answers cross the host as the mock frames them (`mock.frame`).
---@param env table The globals, with `RegisterNetEvent` and `source`.
---@param send fun(target: any, name: string, text: string) Sends a framed text to the other side: to a player from the server, to the server from a client.
---@return table callback The fake `lib.callback`.
---@return table<string, function> registered The callbacks registered, by name, for tests to call as a hostile client would.
local function fake_callback(env, send)
  local mock = fivem.mock
  local registered = {}
  local waiting = {}
  local numbered = 0
  local callback = setmetatable({
    register = function(name, fn)
      registered[name] = fn
      env.RegisterNetEvent(name, function(text)
        local id, body = mock.unframe(text)
        local from = env.source
        if not id then
          return
        end
        thread(function()
          local reply
          if from ~= "" and from ~= nil then
            reply = fn(from, body)
          else
            reply = fn(body)
          end
          if type(reply) == "string" then
            send(from, name, mock.frame(id, reply))
          end
        end)
      end)
    end,
  }, {
    __call = function(_, name, target, cb, payload)
      if not waiting[name] then
        waiting[name] = {}
        env.RegisterNetEvent(name, function(text)
          local id, body = mock.unframe(text)
          if not id then
            return
          end
          local pending = waiting[name][id]
          -- ox_lib 3.40 takes a server-to-client answer only from the
          -- player it asked.
          if pending and (pending.target == false or pending.target == env.source) then
            waiting[name][id] = nil
            pending.cb(body)
          end
        end)
      end
      numbered = numbered + 1
      waiting[name][numbered] = { cb = cb, target = type(target) == "number" and target or false }
      send(target, name, mock.frame(numbered, payload))
    end,
  })
  return callback, registered
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
  ---@field resources table<string, string> Each resource's state as `GetResourceState` reports it: `rpf`, `rpf-ws` and `ox_lib` started. Anything else is `missing`.
  ---@field metadata table<string, table<string, string>> Each resource's manifest metadata, as `GetResourceMetadata` reports it: `ox_lib`'s `version` is 3.40.0.
  ---@field callbacks table<string, function> What the adapter registered with `lib.callback.register`, by name, to call as a hostile client would.
  ---@field invoker string? The resource whose call into an export is running, as `GetInvokingResource` reports it; nil for this resource's own code.
  ---@field resource fun(name: string): table The exported `api` as another resource gets it: every value copied across the boundary, and every call naming that resource as the invoker.
  ---@field stop_resource fun(name: string) `onResourceStop` for another resource.
  ---@field positions table<integer, { x: number, y: number, z: number }> Where each player's ped stands, as `GetEntityCoords` reports it.
  local driver = {
    exported = own_exports,
    lockdown = {},
    resources = { rpf = "started", ["rpf-ws"] = "started", ox_lib = "started" },
    metadata = { ox_lib = { version = "3.40.0" } },
  }

  env.GetInvokingResource = function()
    return driver.invoker
  end
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
  -- A player's ped is their id (any non-zero handle will do), and its
  -- coordinates are the mock's `positions`, as FiveM's vector3.
  env.GetPlayerPed = function(player)
    return p.positions[tonumber(player)] and tonumber(player) or 0
  end
  env.GetEntityCoords = function(ped)
    local at = p.positions[ped]
    return { x = at.x, y = at.y, z = at.z }
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
  env.GetResourceMetadata = function(name, key)
    local metadata = driver.metadata[name]
    return metadata and metadata[key] or nil
  end
  env.lib = {}
  env.lib.callback, driver.callbacks = fake_callback(env, function(player, name, text)
    host.to_client(player, name, text)
  end)
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

  function driver.stop_resource(name)
    fire("onResourceStop", "", name)
  end

  ---How many function references have been made, for their ids.
  local references = 0

  ---Values packed with their count, so a nil in the middle survives.
  ---@param ... any The values.
  ---@return table packed `{ n = count, ... }`.
  local function pack(...)
    return { n = select("#", ...), ... }
  end

  ---The values of a pack, from `i` on.
  ---@param t table The pack.
  ---@param i integer Where to start.
  ---@return any first The value at `i`.
  ---@return any ... The ones after it.
  local function unpacked(t, i)
    if i > t.n then
      return
    end
    return t[i], unpacked(t, i + 1)
  end

  ---Copies a value across the boundary between two resources, as FiveM's
  ---msgpack does: tables are copied raw, without their metatables (so a
  ---read-only view or a JSON mark does not survive), and a function becomes a
  ---reference, a fresh callable table each time, which runs the function
  ---where it was made. A reference crossing back stays one.
  ---@param value any The value.
  ---@param depth integer? How deep the copy is, to refuse a cycle as msgpack would.
  ---@return any copy The copy.
  local function cross(value, depth)
    depth = depth or 0
    if depth > 64 then
      error("msgpack: a table nests too deep, or refers to itself")
    end
    local meta = type(value) == "table" and getmetatable(value) or nil
    if type(value) == "function" or (type(meta) == "table" and meta.__call) then
      references = references + 1
      return setmetatable({ __cfx_functionReference = "ref:" .. references }, {
        __call = function(_, ...)
          return value(...)
        end,
      })
    end
    if type(value) ~= "table" then
      return value
    end
    local copy = {}
    for key, item in pairs(value) do
      copy[cross(key, depth + 1)] = cross(item, depth + 1)
    end
    return copy
  end

  ---Each argument crossed.
  ---@param t table A pack.
  ---@return table crossed A pack of copies.
  local function cross_all(t)
    local out = { n = t.n }
    for i = 1, t.n do
      out[i] = cross(t[i])
    end
    return out
  end

  function driver.resource(name)
    ---An exported function as `name` calls it.
    ---@param fn function The export's function.
    ---@return function call The call.
    local function call_as(fn)
      return function(...)
        local saved = driver.invoker
        driver.invoker = name
        local results = pack(pcall(fn, unpacked(cross_all(pack(...)), 1)))
        driver.invoker = saved
        if not results[1] then
          error(results[2], 0)
        end
        local out = cross_all(results)
        return unpacked(out, 2)
      end
    end
    ---The export's table as `name` sees it.
    ---@param value any A member.
    ---@return any seen The member, its functions calling as `name`.
    local function view(value)
      if type(value) == "function" then
        return call_as(value)
      end
      if type(value) ~= "table" then
        return value
      end
      local out = {}
      for key, item in pairs(value) do
        out[key] = view(item)
      end
      return out
    end
    return view(own_exports.api())
  end

  driver.run_due = p.run_due
  driver.next_due = p.next_due
  driver.http_done = p.http_done
  driver.positions = p.positions
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
  ---@field callbacks table<string, function> What the adapter registered with `lib.callback.register`, by name.
  ---@field notices table[] Every `lib.notify`, as it was given.
  ---@field contexts table<string, table> Every context menu registered, by id.
  ---@field open_context string? The context menu on show, as `lib.getOpenContextMenu` reports it.
  ---@field dialog { heading: string, rows: table[], options: table?, answer: fun(values: table?) }? The input dialog on show; `answer` is the player submitting (or nil, cancelling).
  ---@field bar { data: table, finish: fun(completed: boolean?) }? The progress bar on show; `finish` is it ending.
  ---@field bar_ending { data: table, finish: fun(completed: boolean?) }? A bar cancelled, which ends on the next tick.
  ---@field pick fun(n: integer) The player picks the open context menu's `n`th option.
  ---@field timers table[] The timers pending, as the mock platform keeps them.
  ---@field close_context fun() The player closes the open context menu.
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
  env.lib = {}
  env.lib.callback, driver.callbacks = fake_callback(env, function(_, name, text)
    host.to_server(name, text)
  end)
  env.CreateThread = thread
  driver.notices, driver.contexts = {}, {}
  env.lib.notify = function(data)
    driver.notices[#driver.notices + 1] = data
  end
  env.lib.registerContext = function(context)
    driver.contexts[context.id] = context
  end
  env.lib.showContext = function(id)
    assert(driver.contexts[id], "No context menu of such id found.")
    driver.open_context = id
  end
  env.lib.getOpenContextMenu = function()
    return driver.open_context
  end
  -- As ox_lib's: a pick closes the menu without `onExit`; a close runs it.
  function driver.pick(n)
    local context = driver.contexts[assert(driver.open_context, "no context menu is open")]
    driver.open_context = nil
    local option = context.options[n]
    if option.onSelect then
      option.onSelect(option.args)
    end
  end
  -- ox_lib's order: `onExit` runs first, and only then is the open menu
  -- forgotten, whatever `onExit` opened.
  function driver.close_context()
    local context = driver.contexts[assert(driver.open_context, "no context menu is open")]
    if context.onExit then
      context.onExit()
    end
    driver.open_context = nil
  end
  env.lib.hideContext = function(on_exit)
    if on_exit then
      driver.close_context()
    else
      driver.open_context = nil
    end
  end
  env.lib.closeInputDialog = function()
    if driver.dialog then
      driver.dialog.answer(nil)
    end
  end
  env.lib.progressActive = function()
    return driver.bar and true or nil
  end
  -- As ox_lib's: a cancelled bar is no longer active at once, but ends, and
  -- lets the next start, only on the next tick.
  env.lib.cancelProgress = function()
    local bar = assert(driver.bar, "No progress bar is active")
    driver.bar = nil
    driver.bar_ending = bar
    env.Citizen.SetTimeout(0, function()
      driver.bar_ending = nil
      bar.finish(false)
    end)
  end
  -- One dialog and one bar at a time, as ox_lib's: another dialog while one
  -- is on show answers nil at once, and another bar waits for the one on
  -- show to end before it starts.
  env.lib.inputDialog = function(heading, rows, options)
    if driver.dialog then
      return nil
    end
    local answer = env.promise.new()
    driver.dialog = {
      heading = heading,
      rows = rows,
      options = options,
      answer = function(values)
        driver.dialog = nil
        answer:resolve(values)
      end,
    }
    return env.Citizen.Await(answer)
  end
  env.lib.progressBar = function(data)
    while driver.bar or driver.bar_ending do
      local before = env.promise.new()
      local running = assert(driver.bar or driver.bar_ending)
      local finish = running.finish
      running.finish = function(completed)
        finish(completed)
        before:resolve(true)
      end
      env.Citizen.Await(before)
    end
    local ended = env.promise.new()
    driver.bar = {
      data = data,
      finish = function(completed)
        driver.bar = nil
        ended:resolve(completed)
      end,
    }
    return env.Citizen.Await(ended)
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

  driver.timers = p.timers
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
