---Fake Garry's Mod globals, so the Gmod adapter (`lua/platform/gmod/`) runs
---unmodified with no game: `hook`, `net`, `timer`, `sql`, `HTTP`, GWSockets,
---players, convars, console commands and a little Derma.
---
---It is the mock platform's Gmod half (D8). The mock (`init.lua`) stands in
---for an adapter; this stands in for the engine *under* the adapter, so what
---it proves is the adapter's wiring: that `PlayerInitialSpawn` reaches the
---core with the identifiers in the shape the portal expects, that a frame
---crosses GWSockets byte for byte, that a payload crosses `net` whole.
---
---It takes the same host as the mock (`rpf.mock.ServerHost`,
---`rpf.mock.ClientHost`) and returns a world with the same driving functions
---(`socket_open`, `socket_message`, `socket_close`, `http_done`, `run_due`,
---`next_due`, `from_client`, `from_server`), so the fake game server in
---`crates/fake-server/` drives a Gmod server exactly as it drives the mock,
---and the busted suite (`spec/gmod_spec.lua`) drives it by hand.
---
---Behaviour follows Gmod where the adapter relies on it: `net.Start` refuses
---a name the server never pooled, `hook.Run` stops at the first hook that
---answers, an `HTTP` failure calls `failed`, GWSockets reports `onError`
---before `onDisconnected`, timers run on a later tick. Storage is the host's,
---through the three statements the adapter makes, so a restart is a fresh
---state over the same store. Time is the host's clock, through `SysTime` and
---`os.time`.
---
---It writes the globals it fakes into `_G`, and `uninstall` puts back what was
---there, so a busted run is left as it found it. It keeps to the core's Lua
---5.1/5.4 common subset, because the harness runs it under both.
---@class rpf.mock.gmod
local gmod = {}

---What a fake Gmod is installed with.
---@class rpf.mock.GmodOptions
---@field read fun(path: string): string Reads a file under the repository's `lua/` directory, like `core/init.lua`.
---@field convars table<string, string>? Convar values `server.cfg` would set, such as `rpf_ws_url`.
---@field binary_modules table<string, boolean>? Which binary modules are installed. GWSockets is, unless this says otherwise.
---@field gwsockets_load_error string? What `require("gwsockets")` raises, for a module that is installed but will not load (built for another platform).
---@field query_typed boolean? False for a Gmod build without `sql.QueryTyped`.

---One fake player entity.
---@class rpf.mock.GmodPlayer
---@field id any The harness's number for the player.
---@field nick string The in-game name.
---@field steamid64 string? The SteamID64, nil for none.
---@field valid boolean False once disconnected.
---@field locked boolean Whether `Lock` is in force.
---@field lock_calls integer How many times `Lock` was called.

---A fake Derma panel. Every method a panel has is accepted; the ones the
---tests read back are recorded.
---@class rpf.mock.GmodPanel
---@field class string The Derma class.
---@field parent rpf.mock.GmodPanel? Its parent.
---@field children rpf.mock.GmodPanel[] Its children, in creation order.
---@field text string? What `SetText` set.
---@field value any What `SetValue` set, or the text typed into a field.
---@field hidden boolean Whether `SetTextHidden(true)` was called.
---@field enabled boolean False after `SetEnabled(false)`.
---@field removed boolean Whether `Remove` was called.
---@field choices { text: string, data: any }[] A combo box's options.
---@field chosen integer? The chosen option's index.
---@field DoClick fun(self: rpf.mock.GmodPanel)? A button's click handler.
---@field OnClose fun(self: rpf.mock.GmodPanel)? A window's close handler, which `Close` calls.
---@field Close fun(self: rpf.mock.GmodPanel) Closes a window as its close button does: removed, and `OnClose` called.
---@field Think fun(self: rpf.mock.GmodPanel)? Called each frame; a test calls it.
---@field fraction number? What `SetFraction` set.
---@field tooltip string? What `SetTooltip` set.
---@field title string? What `SetTitle` set.

---The world's driving functions without `self`, the shape the fake game
---server calls the mock's in (`crates/fake-server/src/lua.rs`).
---@class rpf.mock.GmodDriver
---@field run_due fun() `World:run_due`.
---@field next_due fun(): number? `World:next_due`.
---@field socket_open fun(id: integer) `World:socket_open`.
---@field socket_message fun(id: integer, text: string) `World:socket_message`.
---@field socket_close fun(id: integer, reason: string) `World:socket_close`.
---@field http_done fun(id: integer, status: integer, body: string, headers: table<string, string>?) `World:http_done`.
---@field connect_player fun(id: any, nick: string, steamid64: string?) `World:connect_player`.
---@field disconnect_player fun(id: any) `World:disconnect_player`.
---@field from_client fun(id: any, name: string, payload: string) `World:from_client`.
---@field from_server fun(name: string, payload: string) `World:from_server`.

---The installed fake, and how a harness drives it.
---@class rpf.mock.GmodWorld
---@field side "server"|"client" Which side it fakes.
---@field hooks table<string, { id: any, fn: function }[]> Hooks, by event, in the order added.
---@field timers { at: number, seq: integer, fn: fun() }[] Pending timers.
---@field seq integer Orders timers, sockets and requests.
---@field http table<integer, table> `HTTP` requests the host has not answered, by id.
---@field sockets table<integer, table> Fake GWSockets objects, by id.
---@field players table<any, rpf.mock.GmodPlayer> Connected players, by the harness's number.
---@field pooled table<string, true> Names `util.AddNetworkString` pooled.
---@field receivers table<string, function> `net.Receive` handlers, by name.
---@field partial table<string, string[]> Parts of a payload being joined, by player and name.
---@field convars table<string, table> Convars, by name.
---@field commands table<string, function> Console commands, by name.
---@field console string[] Every `RunConsoleCommand`, as `name value…`.
---@field panels rpf.mock.GmodPanel[] Every Derma panel made, in order.
---@field notices { text: string, kind: integer, seconds: number }[] Every `notification.AddLegacy`, in order.
---@field keys table<integer, true> Keys held down, as `input.IsKeyDown` reports them.
---@field restore table<string, any> What the globals held before.
---@field restore_os_time fun(t: table?): integer The real `os.time`, put back by `uninstall`.
---@field host rpf.mock.ServerHost|rpf.mock.ClientHost The harness's half.
---@field reading { values: any[], at: integer }? The `net` message being received.
---@field player_meta table The metatable of fake players.
---@field include fun(path: string): any The fake `include`.
---@field driver rpf.mock.GmodDriver The driving functions as plain functions, as the fake game server calls a platform's.
---@field core rpf? The core's internal table, kept when the adapter loads `init.lua`, because publishing the API replaces the global. For tests to look inside.
local World = {}
World.__index = World

---The globals this file fakes.
local GLOBALS = {
  "SERVER",
  "CLIENT",
  "include",
  "AddCSLuaFile",
  "file",
  "util",
  "sql",
  "HTTP",
  "hook",
  "timer",
  "net",
  "SysTime",
  "IsValid",
  "Color",
  "MsgC",
  "CreateConVar",
  "GetConVar",
  "RunConsoleCommand",
  "concommand",
  "player",
  "vgui",
  "GWSockets",
  "rpf",
  "FCVAR_PROTECTED",
  "FCVAR_DONTRECORD",
  "FCVAR_UNLOGGED",
  "TOP",
  "FILL",
  "notification",
  "input",
  "ScrW",
  "ScrH",
  "KEY_X",
  "NOTIFY_GENERIC",
  "NOTIFY_ERROR",
  "NOTIFY_HINT",
}

---The Gmod adapter's part framing (`lua/platform/gmod/messages.lua`): part
---index, part count, byte length, bytes. The fake reads and writes it so a
---harness can speak plain payloads to a Gmod server.
gmod.PART_BYTES = 60000

---Splits a payload into the values of each part's `net` message.
---@param payload string The payload.
---@return any[][] messages Each message's values, in order.
function gmod.parts(payload)
  local out = {}
  local count = math.max(1, math.ceil(#payload / gmod.PART_BYTES))
  for index = 1, count do
    local chunk = payload:sub((index - 1) * gmod.PART_BYTES + 1, index * gmod.PART_BYTES)
    out[index] = { index, count, #chunk, chunk }
  end
  return out
end

---A deterministic stand-in for `util.SHA256`: 64 hex digits from a rolling
---hash. Not a cryptographic hash, which no test of the adapter needs; only
---"same input, same output; different input, different output".
---@param text string The input.
---@return string hex 64 lowercase hex digits.
local function fake_sha256(text)
  local out = {}
  for round = 1, 8 do
    local h = round * 2654435761 % 4294967291
    for i = 1, #text do
      h = (h * 31 + text:byte(i)) % 4294967291
    end
    out[round] = string.format("%08x", h)
  end
  return table.concat(out)
end

---Runs every timer due by the host's clock, earliest first, re-reading the
---list after each because a timer may add one already due.
function World:run_due()
  while true do
    local now = self.host.now()
    local best
    for i, t in ipairs(self.timers) do
      if t.at <= now then
        local b = best and self.timers[best]
        if not b or t.at < b.at or (t.at == b.at and t.seq < b.seq) then
          best = i
        end
      end
    end
    if not best then
      return
    end
    table.remove(self.timers, best).fn()
  end
end

---When the earliest pending timer is due.
---@return number? at By the host's clock, or nil if none is pending.
function World:next_due()
  local best
  for _, t in ipairs(self.timers) do
    if not best or t.at < best then
      best = t.at
    end
  end
  return best
end

---Runs a hook event as `hook.Run` does: each hook in order, stopping at the
---first that answers.
---@param event string The event.
---@param ... any Its arguments.
---@return any answer The first answer, or nil.
---@return any second The answer's second value, if any.
---@return any third Its third value, if any.
function World:run_hook(event, ...)
  for _, entry in ipairs(self.hooks[event] or {}) do
    local a, b, c = entry.fn(...)
    if a ~= nil then
      return a, b, c
    end
  end
  return nil
end

---Starts the game: runs the addon's autorun file as Gmod does, then the
---start-up hooks.
function World:boot()
  self.include("rpf/platform/gmod/autorun.lua")
  self:run_hook("Initialize")
  self:run_hook("InitPostEntity")
end

---Hands the host's socket opening to GWSockets' callback.
---@param id integer The socket.
function World:socket_open(id)
  local socket = self.sockets[id]
  if socket and socket.onConnected then
    socket:onConnected()
  end
end

---Hands a frame from the host's socket to GWSockets' callback.
---@param id integer The socket.
---@param text string The frame.
function World:socket_message(id, text)
  local socket = self.sockets[id]
  if socket and socket.onMessage then
    socket:onMessage(text)
  end
end

---Reports the host's socket closing as GWSockets does: `onError` for a
---reason other than a requested close, then `onDisconnected`, once.
---@param id integer The socket.
---@param reason string Why.
function World:socket_close(id, reason)
  local socket = self.sockets[id]
  if not socket then
    return
  end
  self.sockets[id] = nil
  if not socket.closing and socket.onError then
    socket:onError(reason)
  end
  if socket.onDisconnected then
    socket:onDisconnected()
  end
end

---Answers an HTTP request: `success` with the response, or `failed` when no
---response came (status 0).
---@param id integer The request.
---@param status integer The status, 0 for none.
---@param body string The body.
---@param headers table<string, string>? The response's headers.
function World:http_done(id, status, body, headers)
  local request = self.http[id]
  if not request then
    return
  end
  self.http[id] = nil
  if status == 0 then
    if request.failed then
      request.failed("unsuccessful")
    end
  elseif request.success then
    request.success(status, body, headers or {})
  end
end

---A player finishes connecting: Gmod makes the entity and runs
---`PlayerInitialSpawn`, then `PlayerSpawn`.
---@param id any The harness's number for the player.
---@param nick string The in-game name.
---@param steamid64 string? The SteamID64, nil for none (singleplayer).
---@return rpf.mock.GmodPlayer player The entity.
function World:connect_player(id, nick, steamid64)
  local ply = setmetatable({ id = id, nick = nick, steamid64 = steamid64, valid = true, locked = false, lock_calls = 0 }, self.player_meta)
  self.players[id] = ply
  self:run_hook("PlayerInitialSpawn", ply, false)
  self:run_hook("PlayerSpawn", ply, false)
  return ply
end

---A player leaves: `PlayerDisconnected` runs while the entity is still
---valid, and then it is not.
---@param id any The harness's number for the player.
function World:disconnect_player(id)
  local ply = self.players[id]
  if not ply then
    return
  end
  self:run_hook("PlayerDisconnected", ply)
  ply.valid = false
  self.players[id] = nil
end

---Delivers one `net` message: sets up the reader over its values and runs
---the receiver, as the engine does.
---@param name string The message name.
---@param values any[] What was written, in order.
---@param sender rpf.mock.GmodPlayer? The sending player, on the server.
function World:deliver(name, values, sender)
  local receiver = self.receivers[name]
  if not receiver then
    return
  end
  self.reading = { values = values, at = 1 }
  local ok, err = pcall(receiver, 0, sender)
  self.reading = nil
  if not ok then
    error(err, 0)
  end
end

---A message from a player's client, as the Gmod client adapter frames it.
---@param id any The harness's number for the player.
---@param name string The message name.
---@param payload string The payload.
function World:from_client(id, name, payload)
  local ply = self.players[id]
  if not ply then
    return
  end
  if not self.pooled[name] then
    return
  end
  for _, values in ipairs(gmod.parts(payload)) do
    self:deliver(name, values, ply)
  end
end

---A message from the game server, as the Gmod server adapter frames it.
---@param name string The message name.
---@param payload string The payload.
function World:from_server(name, payload)
  for _, values in ipairs(gmod.parts(payload)) do
    self:deliver(name, values)
  end
end

---Sets a convar, as `server.cfg` or the console would.
---@param name string The convar.
---@param value string Its new value.
function World:set_convar(name, value)
  local convar = self.convars[name]
  if convar then
    convar.value = value
  end
end

---Runs a console command as the server console would.
---@param name string The command.
---@param args string[]? Its arguments.
function World:command(name, args)
  local fn = self.commands[name]
  if fn then
    fn(nil, name, args or {}, table.concat(args or {}, " "))
  end
end

---Puts back every global the fake replaced, and the real `os.time`.
function World:uninstall()
  for _, name in ipairs(GLOBALS) do
    _G[name] = self.restore[name]
  end
  rawset(os, "time", self.restore_os_time)
  package.preload.gwsockets = nil
  package.loaded.gwsockets = nil
end

---Joins the parts of a payload the adapter sent, and hands the whole payload
---on once its last part is written.
---@param world rpf.mock.GmodWorld The fake.
---@param key string Who it is for and its name.
---@param values any[] One part's values.
---@param deliver fun(payload: string) Called with the whole payload.
local function join_parts(world, key, values, deliver)
  local index, count, size, chunk = values[1], values[2], values[3], values[4] or ""
  if #chunk ~= size then
    error("fake gmod: a part's length says " .. tostring(size) .. " but it holds " .. #chunk .. " bytes", 0)
  end
  local got = world.partial[key] or {}
  got[index] = chunk
  world.partial[key] = got
  if index == count then
    world.partial[key] = nil
    deliver(table.concat(got))
  end
end

---Installs fake Gmod globals for one side.
---@param side "server"|"client" Which side.
---@param host rpf.mock.ServerHost|rpf.mock.ClientHost The harness's half: its clock, store, sockets, HTTP and messages.
---@param options rpf.mock.GmodOptions How.
---@return rpf.mock.GmodWorld world The fake, to drive.
function gmod.install(side, host, options)
  local world = setmetatable({
    side = side,
    host = host,
    hooks = {},
    timers = {},
    seq = 0,
    http = {},
    sockets = {},
    players = {},
    pooled = {},
    receivers = {},
    partial = {},
    convars = {},
    commands = {},
    console = {},
    panels = {},
    restore = {},
  }, World) --[[@as rpf.mock.GmodWorld]]
  for _, name in ipairs(GLOBALS) do
    world.restore[name] = _G[name]
  end
  world.restore_os_time = os.time
  local real_time = os.time
  local server_host = host --[[@as rpf.mock.ServerHost]]
  local modules = options.binary_modules or {}

  -- Files and logging ------------------------------------------------------

  ---Runs a file the addon ships, by its path under the addon's `lua/`.
  ---@param path string Like `rpf/core/init.lua`.
  ---@return any ... What the file returned.
  function world.include(path)
    local relative = path:match("^rpf/(.*)$") or path
    -- Lua 5.1's `load` takes only a function; its `loadstring` is gone in 5.4.
    local compile = rawget(_G, "loadstring") or load
    local chunk, err = compile(options.read(relative), "@lua/" .. relative)
    if not chunk then
      error(err, 2)
    end
    if relative ~= "core/init.lua" then
      return chunk()
    end
    local result = chunk()
    world.core = rawget(_G, "rpf")
    return result
  end

  _G.SERVER = side == "server"
  _G.CLIENT = side == "client"
  _G.include = world.include
  _G.AddCSLuaFile = function() end
  _G.file = {
    Exists = function(path)
      local relative = path:match("^rpf/(.*)$") or path
      return (pcall(options.read, relative))
    end,
  }
  _G.Color = function(r, g, b, a)
    return { r = r, g = g, b = b, a = a or 255 }
  end
  _G.MsgC = function(...)
    local parts = {}
    for _, part in ipairs({ ... }) do
      if type(part) == "string" then
        parts[#parts + 1] = part
      end
    end
    local text = table.concat(parts):gsub("\n$", "")
    local level, message = text:match("^%[(%a+)%] (.*)$")
    host.log(level or "info", message or text)
  end
  _G.IsValid = function(thing)
    if type(thing) ~= "table" then
      return false
    end
    local check = thing.IsValid
    return type(check) == "function" and check(thing) == true
  end

  -- Time and timers --------------------------------------------------------

  _G.SysTime = function()
    return host.now() / 1000
  end
  rawset(os, "time", function(t)
    if t then
      return real_time(t)
    end
    return math.floor(host.now() / 1000)
  end)
  _G.timer = {
    Simple = function(delay, fn)
      world.seq = world.seq + 1
      world.timers[#world.timers + 1] = { at = host.now() + delay * 1000, seq = world.seq, fn = fn }
    end,
  }

  -- Hooks, convars, console ------------------------------------------------

  _G.hook = {
    Add = function(event, id, fn)
      local list = world.hooks[event] or {}
      world.hooks[event] = list
      for _, entry in ipairs(list) do
        if entry.id == id then
          entry.fn = fn
          return
        end
      end
      list[#list + 1] = { id = id, fn = fn }
    end,
    Remove = function(event, id)
      local list = world.hooks[event] or {}
      for i, entry in ipairs(list) do
        if entry.id == id then
          table.remove(list, i)
          return
        end
      end
    end,
    Run = function(event, ...)
      return world:run_hook(event, ...)
    end,
  }
  _G.FCVAR_PROTECTED = 32
  _G.FCVAR_DONTRECORD = 131072
  _G.FCVAR_UNLOGGED = 2048
  _G.CreateConVar = function(name, default)
    local convar = { value = (options.convars or {})[name] or default }
    convar.GetString = function()
      return convar.value
    end
    convar.GetBool = function()
      return convar.value ~= "" and convar.value ~= "0"
    end
    world.convars[name] = convar
    return convar
  end
  _G.GetConVar = function(name)
    return world.convars[name]
  end
  _G.RunConsoleCommand = function(name, ...)
    world.console[#world.console + 1] = table.concat({ name, ... }, " ")
  end
  _G.concommand = {
    Add = function(name, fn)
      world.commands[name] = fn
    end,
  }

  -- Libraries --------------------------------------------------------------

  _G.util = {
    IsBinaryModuleInstalled = function(name)
      return modules[name] ~= false
    end,
    AddNetworkString = function(name)
      world.pooled[name] = true
      return 1
    end,
    SHA256 = fake_sha256,
  }
  local last_error = nil
  _G.sql = {
    LastError = function()
      return last_error
    end,
  }
  if options.query_typed ~= false then
    -- The three statements the adapter makes, over the host's store.
    _G.sql.QueryTyped = function(query, key, value)
      if query:find("^CREATE TABLE") then
        return {}
      elseif query:find("^SELECT v FROM") then
        local stored = host.kv_get(key)
        return stored and { { v = stored } } or {}
      elseif query:find("^INSERT OR REPLACE") then
        host.kv_set(key, value)
        return {}
      elseif query:find("^DELETE FROM") then
        host.kv_set(key, nil)
        return {}
      end
      last_error = "fake gmod: unexpected statement " .. query
      return false
    end
  end
  _G.HTTP = function(request)
    world.seq = world.seq + 1
    world.http[world.seq] = request
    local headers = {}
    for name, value in pairs(request.headers or {}) do
      headers[name] = value
    end
    if request.type then
      headers["Content-Type"] = request.type
    end
    host.http_request(world.seq, string.upper(request.method or "GET"), request.url, headers, request.body)
    return true
  end

  -- net --------------------------------------------------------------------

  ---The `net` message being written, between `net.Start` and its send.
  ---@type { name: string, values: any[] }?
  local writing = nil

  ---The message being written, which `net.Start` must have begun.
  ---@return { name: string, values: any[] } message The message.
  local function started()
    return assert(writing, "fake gmod: a net write before net.Start")
  end
  ---Reads the next value of the message being received.
  ---@return any value The value.
  local function read_next()
    local reading = world.reading
    if not reading then
      error("fake gmod: a net read outside a receiver", 2)
    end
    local value = reading.values[reading.at]
    reading.at = reading.at + 1
    return value
  end
  _G.net = {
    Start = function(name)
      if side == "server" and not world.pooled[name] then
        error("Calling net.Start with unpooled message name! [http://goo.gl/qcx0y]", 2)
      end
      writing = { name = name, values = {} }
    end,
    WriteUInt = function(value)
      local message = started()
      message.values[#message.values + 1] = value
    end,
    WriteData = function(data, length)
      local message = started()
      message.values[#message.values + 1] = data:sub(1, length)
    end,
    Send = function(target)
      local message = started()
      writing = nil
      join_parts(world, tostring(target.id) .. "\0" .. message.name, message.values, function(payload)
        server_host.to_client(target.id, message.name, payload)
      end)
    end,
    SendToServer = function()
      local message = started()
      writing = nil
      join_parts(world, message.name, message.values, function(payload)
        host.to_server(message.name, payload)
      end)
    end,
    Receive = function(name, fn)
      world.receivers[name] = fn
    end,
    ReadUInt = read_next,
    ReadData = function(length)
      local data = read_next()
      return data:sub(1, length)
    end,
    BytesLeft = function()
      local reading = world.reading
      if not reading then
        return nil
      end
      local bytes = 0
      for i = reading.at, #reading.values do
        local value = reading.values[i]
        bytes = bytes + (type(value) == "string" and #value or 4)
      end
      return bytes
    end,
  }

  -- Players ----------------------------------------------------------------

  local Player = {}
  Player.__index = Player
  Player.__tostring = function(ply)
    return "Player [" .. tostring(ply.id) .. "][" .. ply.nick .. "]"
  end
  function Player:IsValid()
    return self.valid
  end
  function Player:SteamID64()
    return self.steamid64
  end
  function Player:Nick()
    return self.nick
  end
  function Player:IsBot()
    return false
  end
  function Player:Kick(reason)
    server_host.kick(self.id, reason)
  end
  function Player:ChatPrint(message)
    server_host.notify(self.id, message)
  end
  function Player:Lock()
    self.locked = true
    self.lock_calls = self.lock_calls + 1
  end
  function Player:UnLock()
    self.locked = false
  end
  ---Where the player stands: `pos`, which the harness sets, as a Vector.
  ---@return table pos `{ x, y, z }`.
  function Player:GetPos()
    return self.pos or { x = 0, y = 0, z = 0 }
  end
  world.player_meta = Player
  _G.player = {
    GetAll = function()
      local out = {}
      for _, ply in pairs(world.players) do
        out[#out + 1] = ply
      end
      return out
    end,
  }

  -- GWSockets --------------------------------------------------------------

  package.loaded.gwsockets = nil
  package.preload.gwsockets = nil
  if modules.gwsockets ~= false then
    package.preload.gwsockets = function()
      if options.gwsockets_load_error then
        error(options.gwsockets_load_error, 0)
      end
      _G.GWSockets = {
        createWebSocket = function(url)
          world.seq = world.seq + 1
          local id = world.seq
          local socket = { id = id, url = url }
          function socket.open(self)
            world.sockets[id] = self
            server_host.connect(id, url)
          end
          function socket.write(_, text)
            return server_host.send(id, text)
          end
          function socket.closeNow(self)
            self.closing = true
            server_host.close(id)
          end
          return socket
        end,
      }
      return true
    end
  end

  -- Derma ------------------------------------------------------------------

  _G.TOP = 4
  _G.FILL = 1
  _G.KEY_X = 34
  _G.NOTIFY_GENERIC = 0
  _G.NOTIFY_ERROR = 1
  _G.NOTIFY_HINT = 3
  _G.ScrW = function()
    return 1920
  end
  _G.ScrH = function()
    return 1080
  end
  world.notices = {}
  world.keys = {}
  _G.notification = {
    AddLegacy = function(text, kind, seconds)
      world.notices[#world.notices + 1] = { text = text, kind = kind, seconds = seconds }
    end,
  }
  _G.input = {
    IsKeyDown = function(key)
      return world.keys[key] == true
    end,
  }
  local Panel = {}
  ---Any method a panel has that the fake does not record does nothing.
  local function ignore() end
  local methods = {
    SetText = function(self, text)
      self.text = text
    end,
    SetValue = function(self, value)
      self.value = value
    end,
    GetValue = function(self)
      return self.value or ""
    end,
    GetChecked = function(self)
      return self.value == true
    end,
    SetTextHidden = function(self, hidden)
      self.hidden = hidden
    end,
    SetEnabled = function(self, enabled)
      self.enabled = enabled
    end,
    Remove = function(self)
      self.removed = true
    end,
    Close = function(self)
      self.removed = true
      if self.OnClose then
        self:OnClose()
      end
    end,
    SetFraction = function(self, fraction)
      self.fraction = fraction
    end,
    SetTooltip = function(self, tooltip)
      self.tooltip = tooltip
    end,
    SetTitle = function(self, title)
      self.title = title
    end,
    IsValid = function(self)
      return not self.removed
    end,
    AddChoice = function(self, text, data, select)
      self.choices[#self.choices + 1] = { text = text, data = data }
      if select then
        self.chosen = #self.choices
      end
    end,
    GetSelected = function(self)
      local choice = self.choices[self.chosen or 0]
      if choice then
        return choice.text, choice.data
      end
      return nil
    end,
  }
  -- Methods are capitalised in Derma; anything else is a field that is unset.
  Panel.__index = function(_, key)
    if type(key) == "string" and key:find("^%u") then
      return methods[key] or ignore
    end
    return nil
  end
  _G.vgui = {
    Create = function(class, parent)
      local panel = setmetatable({
        class = class,
        parent = parent,
        children = {},
        hidden = false,
        enabled = true,
        removed = false,
        choices = {},
      }, Panel)
      if parent then
        parent.children[#parent.children + 1] = panel
      end
      world.panels[#world.panels + 1] = panel
      return panel
    end,
  }

  world.driver = {
    run_due = function()
      world:run_due()
    end,
    next_due = function()
      return world:next_due()
    end,
    socket_open = function(id)
      world:socket_open(id)
    end,
    socket_message = function(id, text)
      world:socket_message(id, text)
    end,
    socket_close = function(id, reason)
      world:socket_close(id, reason)
    end,
    http_done = function(id, status, body, headers)
      world:http_done(id, status, body, headers)
    end,
    connect_player = function(id, nick, steamid64)
      world:connect_player(id, nick, steamid64)
    end,
    disconnect_player = function(id)
      world:disconnect_player(id)
    end,
    from_client = function(id, name, payload)
      world:from_client(id, name, payload)
    end,
    from_server = function(name, payload)
      world:from_server(name, payload)
    end,
  }

  _G.rpf = nil
  return world
end

---The panels on show: made, not removed, and with no removed ancestor.
---@param world rpf.mock.GmodWorld The fake.
---@param class string? Only this Derma class.
---@return rpf.mock.GmodPanel[] panels The panels, in creation order.
function gmod.shown(world, class)
  local out = {}
  for _, panel in ipairs(world.panels) do
    local gone = false
    local at = panel
    while at do
      if at.removed then
        gone = true
      end
      at = at.parent
    end
    if not gone and (class == nil or panel.class == class) then
      out[#out + 1] = panel
    end
  end
  return out
end

return gmod
