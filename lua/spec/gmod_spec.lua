-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The Gmod adapter (`lua/platform/gmod/`, D8), unmodified, on the mock's fake
-- Gmod globals (`lua/platform/mock/gmod.lua`). These hold the adapter's
-- wiring: the engine events it translates, the refusals at start, the
-- transport and `net` contracts, the input lock, and the login and character
-- screens. What the core does with what it is handed is the core's own
-- suite's business.

local support = require("spec.support")

local STEAMID = "76561198000000001"
local SERVER_ID = "00000001-0000-4000-8000-000000000001"

---Loads the fake Gmod module afresh.
---@return rpf.mock.gmod gmod The module.
local function load_fake()
  return dofile(support.path("lua/platform/mock/gmod.lua"))
end

---Reads a file under `lua/`, failing like a missing file does.
---@param relative string Like `core/init.lua`.
---@return string source The file.
local function read(relative)
  local file = io.open(support.path("lua/" .. relative), "rb")
  if not file then
    error("no such file: " .. relative)
  end
  local source = file:read("*a")
  file:close()
  return source
end

---A host that records what the fake hands it, with a clock the test moves.
---@return table host The host.
---@return table record What it recorded.
local function fake_host()
  local record = {
    time = support.EPOCH_MS,
    kv = {},
    sent = {},
    connects = {},
    closes = {},
    requests = {},
    to_clients = {},
    to_server = {},
    kicks = {},
    logs = {},
  }
  local host = {
    now = function()
      return record.time
    end,
    kv_get = function(key)
      return record.kv[key]
    end,
    kv_set = function(key, value)
      record.kv[key] = value
    end,
    http_request = function(id, method, url, headers, body)
      record.requests[#record.requests + 1] = { id = id, method = method, url = url, headers = headers, body = body }
    end,
    connect = function(id, url)
      record.connects[#record.connects + 1] = { id = id, url = url }
    end,
    close = function(id)
      record.closes[#record.closes + 1] = id
    end,
    send = function(id, text)
      record.sent[#record.sent + 1] = { id = id, text = text }
      return true
    end,
    kick = function(player, reason)
      record.kicks[#record.kicks + 1] = { player = player, reason = reason }
    end,
    notify = function() end,
    to_client = function(player, name, payload)
      record.to_clients[#record.to_clients + 1] = { player = player, name = name, payload = payload }
    end,
    to_server = function(name, payload)
      record.to_server[#record.to_server + 1] = { name = name, payload = payload }
    end,
    log = function(level, message)
      record.logs[#record.logs + 1] = { level = level, message = message }
    end,
  }
  return host, record
end

---The installed fake, so `after_each` can put the globals back.
---@type rpf.mock.GmodWorld?
local installed = nil

after_each(function()
  if installed then
    installed:uninstall()
    installed = nil
  end
end)

---Installs a fake Gmod side and boots the adapter on it.
---@param side "server"|"client" Which side.
---@param options table? Overrides for `gmod.install`'s options.
---@return rpf.mock.GmodWorld world The fake.
---@return table record What the host recorded.
local function boot(side, options)
  local gmod = load_fake()
  local host, record = fake_host()
  local opts = { read = read, convars = { rpf_ws_url = "wss://portal.test/ws", rpf_api_key = "rpf_sk_test" } }
  for key, value in pairs(options or {}) do
    opts[key] = value
  end
  local world = gmod.install(side, host, opts)
  installed = world
  world:boot()
  return world, record
end

---Decodes every frame the server sent the portal.
---@param world rpf.mock.GmodWorld The fake.
---@param record table The host's record.
---@return rpf.Frame[] frames The frames, in order.
local function frames(world, record)
  local out = {}
  for _, sent in ipairs(record.sent) do
    out[#out + 1] = assert(world.core.protocol.decode(world.core.protocol.SERVER_TO_PORTAL, sent.text))
  end
  return out
end

---The last frame the server sent of a type.
---@param world rpf.mock.GmodWorld The fake.
---@param record table The host's record.
---@param tag string The type.
---@return rpf.Frame? frame The frame.
local function last(world, record, tag)
  local found = nil
  for _, frame in ipairs(frames(world, record)) do
    if frame.type == tag then
      found = frame
    end
  end
  return found
end

---Opens the socket and answers `Hello` with a `Welcome`.
---@param world rpf.mock.GmodWorld The fake.
---@param record table The host's record.
local function welcome(world, record)
  local socket = record.connects[#record.connects].id
  world:socket_open(socket)
  local hello = assert(last(world, record, "hello"))
  local source = support.fake_platform({ seed = 99 })
  local frame = world.core.protocol.envelope(source, "welcome", {
    re = hello.id,
    protocol = world.core.protocol.VERSION,
    server_id = SERVER_ID,
  })
  world:socket_message(socket, assert(world.core.protocol.encode(world.core.protocol.PORTAL_TO_SERVER, frame)))
end

---Whether any log line at a level contains a text.
---@param record table The host's record.
---@param level string The level.
---@param text string The text.
---@return integer count How many lines matched.
local function logged(record, level, text)
  local count = 0
  for _, line in ipairs(record.logs) do
    if line.level == level and line.message:find(text, 1, true) then
      count = count + 1
    end
  end
  return count
end

describe("the Gmod adapter's server", function()
  it("starts the core once the map has loaded, over GWSockets, as engine gmod", function()
    local world, record = boot("server")
    assert.are.equal(1, #record.connects)
    assert.are.equal("wss://portal.test/ws", record.connects[1].url)
    world:socket_open(record.connects[1].id)
    local hello = assert(last(world, record, "hello"))
    assert.are.equal("gmod", hello.engine)
    assert.are.equal("rpf_sk_test", hello.api_key)
    -- Published as the global, and only the public API.
    assert.are.equal("gmod", rpf.engine)
    assert.is_nil(rawget(rpf, "connection"))
    -- An empty server keeps running its timers and the socket.
    assert.are.same({ "sv_hibernate_think 1" }, world.console)
  end)

  it("refuses to start without GWSockets, in one line naming the module and its instructions", function()
    local _, record = boot("server", { binary_modules = { gwsockets = false } })
    assert.are.equal(0, #record.connects)
    assert.are.equal(1, #record.logs)
    assert.are.equal("error", record.logs[1].level)
    assert.truthy(record.logs[1].message:find("GWSockets", 1, true))
    assert.truthy(record.logs[1].message:find("https://github.com/FredyH/GWSockets#usage", 1, true))
    assert.is_nil(rawget(_G, "rpf"))
  end)

  it("refuses to start on a Gmod without sql.QueryTyped", function()
    local _, record = boot("server", { query_typed = false })
    assert.are.equal(0, #record.connects)
    assert.are.equal(1, logged(record, "error", "sql.QueryTyped"))
  end)

  it("waits for server.cfg's convars, which Gmod sets after the map loads", function()
    local world, record = boot("server", { convars = {} })
    assert.are.equal(0, #record.connects)
    assert.are.equal(0, #record.logs)
    -- No engine event reaches a core that has not started.
    world:connect_player(1, "Alice", STEAMID)
    assert.are.same({}, world.core.players.list())
    -- Said once, after a while, and only once.
    for _ = 1, 30 do
      record.time = record.time + 1000
      world:run_due()
    end
    assert.are.equal(1, logged(record, "error", "rpf_ws_url and rpf_api_key"))
    assert.are.equal(0, #record.connects)
    -- Set later, it starts.
    world:set_convar("rpf_ws_url", "wss://portal.test/ws")
    world:set_convar("rpf_api_key", "rpf_sk_test")
    record.time = record.time + 1000
    world:run_due()
    assert.are.equal(1, #record.connects)
    -- Whoever joined meanwhile is handed over, and locked, at the start.
    local players = world.core.players.list()
    assert.are.equal(1, #players)
    assert.are.equal("Alice", players[1].name)
    assert.is_true(world.players[1].locked)
  end)

  it("hands a joining player to the core, and reports them as steam:<SteamID64>", function()
    local world, record = boot("server")
    welcome(world, record)
    world:connect_player(1, "Alice", STEAMID)
    local players = world.core.players.list()
    assert.are.equal(1, #players)
    assert.are.equal("connecting", players[1].state)
    assert.are.equal("Alice", players[1].name)
    world:from_client(1, "rpf:client_ready", world.core.handoff.encode("rpf:client_ready"))
    local begin = assert(last(world, record, "begin_join"))
    assert.are.same({ "steam:" .. STEAMID }, begin.identifiers)
    assert.are.equal("Alice", begin.name)
  end)

  it("reports no identifier for a player with no SteamID64", function()
    local world, record = boot("server")
    welcome(world, record)
    world:connect_player(1, "Local", nil)
    world:from_client(1, "rpf:client_ready", world.core.handoff.encode("rpf:client_ready"))
    local begin = assert(last(world, record, "begin_join"))
    assert.are.same({}, begin.identifiers)
  end)

  it("tells the core when a player leaves", function()
    local world, record = boot("server")
    welcome(world, record)
    world:connect_player(1, "Alice", STEAMID)
    world:disconnect_player(1)
    assert.are.same({}, world.core.players.list())
  end)

  it("locks a player in every state before active, and releases them there", function()
    local world, record = boot("server")
    welcome(world, record)
    local ply = world:connect_player(1, "Alice", STEAMID)
    world:run_due()
    assert.is_true(ply.locked)
    assert.are.equal(false, world:run_hook("PlayerNoClip", ply, true))
    assert.are.equal(false, world:run_hook("PlayerSpawnProp", ply, "models/props_c17/oildrum001.mdl"))
    assert.are.equal("", world:run_hook("PlayerSay", ply, "hello", false))
    -- A spawn resets the engine's flags, so the lock goes back on a tick later.
    local before = ply.lock_calls
    world:run_hook("PlayerSpawn", ply, false)
    world:run_due()
    assert.are.equal(before + 1, ply.lock_calls)

    local core = assert(world.core)
    assert(core.players.authenticating(ply))
    assert(core.players.register(ply, { player_id = "00000000-0000-4000-8000-0000000000aa", username = "alice" }))
    assert(core.players.advance(ply, "character_select"))
    assert.is_true(ply.locked)
    assert(core.players.advance(ply, "active"))
    assert.is_false(ply.locked)
    assert.is_nil(world:run_hook("PlayerNoClip", ply, true))
    assert.is_nil(world:run_hook("PlayerSay", ply, "hello", false))
    -- Back to choosing a character locks them again.
    assert(core.players.advance(ply, "character_select"))
    assert.is_true(ply.locked)
  end)

  it("sends a payload longer than one net message whole, in parts", function()
    local world, record = boot("server")
    welcome(world, record)
    local ply = world:connect_player(1, "Alice", STEAMID)
    local payload = string.rep("x", 150000)
    local platform_to_client = world.core.connection.platform.to_client
    platform_to_client(ply, "rpf:characters", payload)
    local last_message = record.to_clients[#record.to_clients]
    assert.are.equal("rpf:characters", last_message.name)
    assert.are.equal(payload, last_message.payload)
  end)

  it("takes a payload from a client only in a single part", function()
    local world, record = boot("server")
    welcome(world, record)
    world:connect_player(1, "Alice", STEAMID)
    local ready = world.core.handoff.encode("rpf:client_ready")
    -- The same payload, padded past one part: the server drops it whole.
    world:from_client(1, "rpf:client_ready", ready .. string.rep(" ", 70000))
    assert.is_nil(last(world, record, "begin_join"))
    world:from_client(1, "rpf:client_ready", ready)
    assert.truthy(last(world, record, "begin_join"))
  end)

  it("closes the socket on a map change, and reports the close once", function()
    local world, record = boot("server")
    welcome(world, record)
    local socket = record.connects[1].id
    world:run_hook("ShutDown")
    assert.are.same({ socket }, record.closes)
    world:run_due()
    -- GWSockets' own report of the close comes later, and is not a second one.
    world:socket_close(socket, "closed")
    assert.are.same({ socket }, record.closes)
  end)

  it("reconnects through the core after the portal drops the socket", function()
    local world, record = boot("server")
    welcome(world, record)
    world:socket_close(record.connects[1].id, "the portal went away")
    record.time = record.time + 120000
    world:run_due()
    assert.are.equal(2, #record.connects)
  end)

  it("keeps each engine event handler to two lines", function()
    local source = read("platform/gmod/server.lua") .. read("platform/gmod/client.lua")
    local handlers = 0
    for body in source:gmatch("hook%.Add%([^\n]-function%([^)]*%)\n(.-)\n%s*end%)") do
      handlers = handlers + 1
      local lines = select(2, body:gsub("\n", "")) + 1
      assert.is_true(lines <= 2, "a hook handler has " .. lines .. " lines:\n" .. body)
    end
    assert.is_true(handlers >= 5, "found the handlers")
  end)
end)

describe("the Gmod adapter's platform members", function()
  it("reads the wall clock with millisecond resolution", function()
    local world, record = boot("server")
    local now = world.core.connection.platform.now
    local first = now()
    record.time = record.time + 1234
    assert.are.equal(first + 1234, now())
    -- A wall clock that steps is followed.
    record.time = record.time - 600000
    assert.are.equal(record.time, now())
  end)

  it("stores and deletes values through SQLite", function()
    local world, record = boot("server")
    local platform = world.core.connection.platform
    platform.kv_set("rpf.test", "value")
    assert.are.equal("value", record.kv["rpf.test"])
    assert.are.equal("value", platform.kv_get("rpf.test"))
    platform.kv_set("rpf.test", nil)
    assert.is_nil(platform.kv_get("rpf.test"))
  end)

  it("mints lowercase hex of any length, different each time", function()
    local world = boot("server")
    local random_hex = world.core.connection.platform.random_hex
    local a, b = random_hex(32), random_hex(32)
    assert.truthy(a:find("^[0-9a-f]+$"))
    assert.are.equal(32, #a)
    assert.are_not.equal(a, b)
    assert.are.equal(100, #random_hex(100))
  end)

  it("calls an HTTP callback once, with status 0 for no response, and sends the content type as Gmod's type", function()
    local world, record = boot("server")
    local calls = {}
    world.core.connection.platform.http_request("POST", "https://portal.test/x", { ["Content-Type"] = "application/json", ["X-A"] = "b" }, "{}", function(status, body)
      calls[#calls + 1] = { status = status, body = body }
    end)
    local request = record.requests[#record.requests]
    assert.are.equal("application/json", request.headers["Content-Type"])
    assert.are.equal("b", request.headers["X-A"])
    world:http_done(request.id, 0, "", {})
    world:http_done(request.id, 200, "late", {})
    assert.are.same({ { status = 0, body = "" } }, calls)
  end)

  it("never reports a frame on a socket that is not open", function()
    local world, record = boot("server")
    local platform = world.core.connection.platform
    assert.is_false(platform.send("{}"))
    world:socket_open(record.connects[1].id)
    assert.is_true(platform.send("{}"))
  end)
end)

describe("the Gmod adapter's client", function()
  ---The text of every label on show.
  ---@param gmod rpf.mock.gmod The fake module.
  ---@param world rpf.mock.GmodWorld The fake.
  ---@return string text Every label's text, one per line.
  local function labels(gmod, world)
    local out = {}
    for _, panel in ipairs(gmod.shown(world, "DLabel")) do
      out[#out + 1] = panel.text or ""
    end
    return table.concat(out, "\n")
  end

  ---The button on show with a text.
  ---@param gmod rpf.mock.gmod The fake module.
  ---@param world rpf.mock.GmodWorld The fake.
  ---@param text string The button's text, or the start of it.
  ---@return rpf.mock.GmodPanel button The button.
  local function button(gmod, world, text)
    for _, panel in ipairs(gmod.shown(world, "DButton")) do
      if panel.text and panel.text:sub(1, #text) == text then
        return panel
      end
    end
    error("no button " .. text .. " on show")
  end

  ---Boots a client and hands it a join nonce, which shows the login form.
  ---@return rpf.mock.gmod gmod The fake module.
  ---@return rpf.mock.GmodWorld world The fake.
  ---@return table record What the host recorded.
  local function at_login()
    local gmod = load_fake()
    local host, record = fake_host()
    local world = gmod.install("client", host, { read = read })
    installed = world
    world:boot()
    world:from_server("rpf:join_nonce", world.core.handoff.encode("rpf:join_nonce", {
      nonce = "nonce-1",
      expires_in_ms = 60000,
      portal_url = "https://portal.test",
      server_id = SERVER_ID,
    }))
    return gmod, world, record
  end

  it("tells the server it is ready once the player is in the game", function()
    local gmod = load_fake()
    local host, record = fake_host()
    local world = gmod.install("client", host, { read = read })
    installed = world
    world:boot()
    assert.are.equal("rpf:client_ready", record.to_server[1].name)
    assert.are.equal("gmod", rpf.engine)
    assert.truthy(rpf.auth)
  end)

  it("shows the login form with the password reuse warning, and sends the password only to the portal", function()
    local gmod, world, record = at_login()
    assert.truthy(labels(gmod, world):find(world.core.auth.PASSWORD_REUSE_WARNING, 1, true))
    local fields = gmod.shown(world, "DTextEntry")
    assert.are.equal(2, #fields)
    assert.is_true(fields[2].hidden)
    fields[1].value = "alice"
    fields[2].value = "correct horse battery"
    button(gmod, world, "Log in"):DoClick()
    local request = record.requests[#record.requests]
    assert.are.equal("https://portal.test/api/v1/player/login", request.url)
    assert.truthy(request.body:find("correct horse battery", 1, true))
    for _, message in ipairs(record.to_server) do
      assert.falsy(message.payload:find("correct horse battery", 1, true), message.name)
    end
  end)

  it("shows the portal's refusal on the form", function()
    local gmod, world, record = at_login()
    local fields = gmod.shown(world, "DTextEntry")
    fields[1].value = "alice"
    fields[2].value = "wrong"
    button(gmod, world, "Log in"):DoClick()
    local request = record.requests[#record.requests]
    world:http_done(request.id, 401, '{"error":"invalid_credentials","message":"Wrong username or password."}', {})
    assert.truthy(labels(gmod, world):find("Wrong username or password.", 1, true))
    assert.is_true(button(gmod, world, "Log in").enabled)
  end)

  it("lists characters after login, and selects one through the server", function()
    local gmod, world, record = at_login()
    world:from_server("rpf:characters", world.core.handoff.encode("rpf:characters", {
      characters = world.core.json.array({
        { id = "00000000-0000-4000-8000-0000000000c1", first_name = "Ada", last_name = "Byron", gender = "female" },
      }),
    }))
    button(gmod, world, "Play Ada Byron"):DoClick()
    local sent = record.to_server[#record.to_server]
    assert.are.equal("rpf:character_select", sent.name)
    assert.truthy(sent.payload:find("00000000-0000-4000-8000-0000000000c1", 1, true))
    world:from_server("rpf:character_result", world.core.handoff.encode("rpf:character_result", {
      during = "select",
      ok = true,
      id = "00000000-0000-4000-8000-0000000000c1",
    }))
    assert.are.same({}, gmod.shown(world, "DFrame"))
  end)

  it("keeps a refusal on show when the server sends the list again after it", function()
    local gmod, world = at_login()
    local list = world.core.handoff.encode("rpf:characters", {
      characters = world.core.json.array({
        { id = "00000000-0000-4000-8000-0000000000c1", first_name = "Ada", last_name = "Byron", gender = "female" },
      }),
    })
    world:from_server("rpf:characters", list)
    button(gmod, world, "Play Ada Byron"):DoClick()
    world:from_server("rpf:character_result", world.core.handoff.encode("rpf:character_result", {
      during = "select",
      ok = false,
      id = "00000000-0000-4000-8000-0000000000c1",
      reason = "unavailable",
    }))
    world:from_server("rpf:characters", list)
    assert.truthy(labels(gmod, world):find("Could not select: unavailable.", 1, true))
    assert.is_true(button(gmod, world, "Play Ada Byron").enabled)
  end)

  it("creates a character from the form", function()
    local gmod, world, record = at_login()
    world:from_server("rpf:characters", world.core.handoff.encode("rpf:characters", {
      characters = world.core.json.array({}),
    }))
    local fields = gmod.shown(world, "DTextEntry")
    fields[1].value = "Grace"
    fields[2].value = "Hopper"
    button(gmod, world, "Create"):DoClick()
    local sent = record.to_server[#record.to_server]
    assert.are.equal("rpf:character_create", sent.name)
    local fields_sent = world.core.json.decode(sent.payload)
    assert.are.same({ first_name = "Grace", last_name = "Hopper", gender = "male" }, {
      first_name = fields_sent.first_name,
      last_name = fields_sent.last_name,
      gender = fields_sent.gender,
    })
  end)
end)
