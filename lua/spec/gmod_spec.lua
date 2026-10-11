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
    domains = support.NATIVE,
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

describe("an addon loaded before the adapter (the example's entry point)", function()
  it("reads the public API at Initialize, registers, and runs once installed", function()
    local gmod = load_fake()
    local host = fake_host()
    rawset(_G, "acme_tags", nil)
    local world = gmod.install("server", host, {
      read = function(relative)
        if relative == "autorun/acme_tags.lua" then
          return support.read("lua/examples/acme_tags/gmod/autorun.lua")
        end
        local example = relative:match("^acme_tags/(.+)$")
        if example then
          return support.read("lua/examples/acme_tags/" .. example)
        end
        return read(relative)
      end,
      convars = { rpf_ws_url = "wss://portal.test/ws", rpf_api_key = "rpf_sk_test" },
    })
    installed = world
    -- Name order: `acme_tags.lua` runs before `rpf.lua`.
    world.include("autorun/acme_tags.lua")
    world:boot()
    local api = rawget(_G, "rpf")
    assert.are_not.equal(world.core, api, "the global is the public API")
    assert.are.equal("not_installed", (api.addons.state("acme_tags")))
    local json = world.core.json
    local checked = assert(world.core.manifest.check(rawget(_G, "acme_tags").MANIFEST))
    local snapshot = assert(json.decode(assert(json.encode({
      settings = json.object({}),
      addons = json.array({
        {
          namespace = "acme_tags",
          version = "1.0.0",
          hash = "sha256:x",
          enabled = true,
          manifest = checked,
          types = json.object({}),
          records = json.array({}),
        },
      }),
    }))))
    assert(world.core.config.apply(world.core.connection.platform, 1, "h1", snapshot))
    assert.are.equal("active", (api.addons.state("acme_tags")), "its start ran on the public API")
    rawset(_G, "acme_tags", nil)
  end)
end)

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

  it("refuses to start when GWSockets is installed but will not load, saying which build to install", function()
    local _, record = boot("server", { gwsockets_load_error = "Couldn't load module library!" })
    assert.are.equal(0, #record.connects)
    assert.are.equal(1, #record.logs)
    local line = record.logs[1].message
    assert.truthy(line:find("installed but would not load (Couldn't load module library!)", 1, true), line)
    assert.truthy(line:find("gmsv_gwsockets_win64.dll", 1, true), line)
    assert.is_nil(rawget(_G, "rpf"))
  end)

  it("says once that a convar is wrong, and starts once it is put right", function()
    local world, record = boot("server", {
      convars = { rpf_ws_url = "https://portal.test/ws", rpf_api_key = "rpf_sk_test" },
    })
    for _ = 1, 5 do
      record.time = record.time + 1000
      world:run_due()
    end
    assert.are.equal(0, #record.connects)
    assert.are.equal(1, logged(record, "error", "rpf_ws_url is not the portal's websocket address"))
    world:set_convar("rpf_api_key", "sk_test")
    world:set_convar("rpf_ws_url", "wss://portal.test/ws")
    record.time = record.time + 1000
    world:run_due()
    assert.are.equal(1, logged(record, "error", "rpf_api_key does not look like a server API key"))
    assert.are.equal(0, logged(record, "error", "sk_test"), "the key is never logged")
    world:set_convar("rpf_api_key", "rpf_sk_test")
    record.time = record.time + 1000
    world:run_due()
    assert.are.equal(1, #record.connects)
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

  it("answers a client's numbered request under its number, and drops one with none", function()
    local world, record = boot("server")
    welcome(world, record)
    world:connect_player(1, "Alice", STEAMID)
    local platform = world.core.connection.platform
    local heard = {}
    platform.on_client_request("rpf:test", function(player, payload, respond)
      heard[#heard + 1] = payload
      respond("answer to " .. payload)
      respond("a second answer, dropped")
    end)
    world:from_client(1, "rpf:test", "12\nhello\nthere")
    world:from_client(1, "rpf:test", "hello")
    world:from_client(1, "rpf:test", "x\nhello")
    assert.are.same({ "hello\nthere" }, heard)
    local answers = {}
    for _, message in ipairs(record.to_clients) do
      if message.name == "rpf:test" then
        answers[#answers + 1] = message.payload
      end
    end
    assert.are.same({ "12\nanswer to hello\nthere" }, answers)
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

describe("the Gmod adapter's placements (J4)", function()
  it("removes, as it starts, the entities a previous start placed, and leaves other addons' alone", function()
    local gmod = load_fake()
    local host = fake_host()
    local world = gmod.install("server", host, { read = read, convars = { rpf_ws_url = "wss://portal.test/ws", rpf_api_key = "rpf_sk_test" } })
    installed = world
    local left = ents.Create("prop_dynamic")
    left:SetNWString("rpf_placement", "old")
    local theirs = ents.Create("prop_physics")
    world:boot()
    assert.is_false(left:IsValid())
    assert.is_true(theirs:IsValid())
  end)

  it("places a prop_dynamic with its Gmod model, tagged, named by its index, and refuses a bucket Gmod lacks", function()
    local world = boot("server")
    local server = assert(world.core).connection.platform.capabilities
    local spec = {
      id = "rec",
      type = "acme_npcs.greeter",
      kind = "ped",
      position = { x = 1, y = 2, z = 3 },
      heading = 90,
      bucket = 0,
      model = { fivem = "a_m_y_business_01", gmod = "models/Humans/Group01/male_02.mdl" },
    }
    local answer
    server.spawn(spec, function(ref, err)
      answer = { ref, err }
    end)
    local ref = assert(answer[1])
    local entity = world.entities[ref --[[@as integer]]]
    assert.are.equal("prop_dynamic", entity.class)
    assert.is_true(entity.spawned)
    assert.are.same({ p = 0, y = 90, r = 0 }, entity.angles)
    assert.are.same(
      { position = { x = 1, y = 2, z = 3 }, model = "models/humans/group01/male_02.mdl", bucket = 0, placement = "rec" },
      server.entity(ref)
    )
    spec.bucket = 2
    server.spawn(spec, function(ref, err)
      answer = { ref, err }
    end)
    assert.are.same({ nil, "no_bucket" }, answer)
    server.despawn(ref)
    assert.is_nil(world.entities[ref])
  end)
end)

describe("the Gmod adapter's commands (F9, #198)", function()
  local CODE = "7K3Q-X9ZP"

  ---Boots a connected server with a logged-in player.
  ---@return rpf.mock.GmodWorld world The fake.
  ---@return table record What the host recorded.
  ---@return rpf.mock.GmodPlayer ply The player.
  local function linkable()
    local world, record = boot("server")
    welcome(world, record)
    local ply = world:connect_player(1, "Alice", STEAMID)
    local core = assert(world.core)
    assert(core.players.authenticating(ply))
    assert(core.players.register(ply, { player_id = "00000000-0000-4000-8000-0000000000aa", username = "alice" }))
    return world, record, ply
  end

  it("registers the link command in the console, unlogged", function()
    local world = boot("server")
    assert.is_function(world.commands.rpflink)
    assert.are.same({ FCVAR_UNLOGGED }, world.command_flags.rpflink)
  end)

  it("links the player who typed the code in the console", function()
    local world, record = linkable()
    world:player_command(1, "rpflink", { "7K3Q", "X9ZP" })
    assert.are.equal("7K3QX9ZP", last(world, record, "link_player").link_code)
    -- The server console has no player to link, and nothing is sent for it.
    local before = #record.sent
    world:command("rpflink", { CODE })
    assert.are.equal(before, #record.sent)
  end)

  it("runs a chat command and drops the line, whoever else is listening", function()
    local world, record = linkable()
    assert.are.equal("", world:say(1, "/rpflink " .. CODE))
    assert.are.equal(CODE, last(world, record, "link_player").link_code)
    for _, line in ipairs(record.logs) do
      assert.is_nil(line.message:find(CODE, 1, true), line.message)
    end
  end)

  it("takes the command's name in any case, and no other line", function()
    local world, record, ply = linkable()
    assert(world.core.players.advance(ply, "character_select"))
    assert(world.core.players.advance(ply, "active"))
    local heard = {}
    world.core.connection.platform.on_command("rpftest", function(player, args)
      heard[#heard + 1] = { player = player, args = args }
    end)
    assert.are.equal("", world:say(1, "/RpfTest  a   b "))
    assert.are.same({ { player = ply, args = { "a", "b" } } }, heard)
    for _, line in ipairs({ "hello", "rpftest a", "/rpftesta b", "/ rpftest", "/", "!rpftest a", "/unknown x" }) do
      assert.is_nil(world:say(1, line), line)
    end
    assert.are.equal(1, #heard)
    assert.is_nil(last(world, record, "link_player"))
  end)

  it("runs a command for a player the lock would silence, and still silences their chat", function()
    local world, record, ply = linkable()
    assert.is_true(ply.locked)
    assert.are.equal("", world:say(1, "hello"))
    assert.are.equal("", world:say(1, "/rpflink " .. CODE))
    assert.truthy(last(world, record, "link_player"))
  end)

  it("drops the line and logs the name only when a handler raises", function()
    local world, record = linkable()
    local platform = world.core.connection.platform
    platform.on_command("boom", function()
      error("failed")
    end)
    assert.are.equal("", world:say(1, "/boom " .. CODE))
    world:player_command(1, "boom", { CODE })
    assert.are.equal(2, logged(record, "error", "the boom command failed"))
    assert.are.equal(0, logged(record, "error", CODE))
  end)

  it("replaces a handler registered again, and registers the console command once", function()
    local world = boot("server")
    local platform = world.core.connection.platform
    local first = nil
    platform.on_command("rpftwice", function() first = "first" end)
    local added = world.commands.rpftwice
    platform.on_command("rpftwice", function() first = "second" end)
    assert.are.equal(added, world.commands.rpftwice)
    world:connect_player(1, "Alice", STEAMID)
    world:player_command(1, "rpftwice", {})
    assert.are.equal("second", first)
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

  it("logs why a write failed once per connection, and reports the frame as unsent", function()
    local world, record = boot("server")
    local platform = world.core.connection.platform
    local socket = record.connects[1].id
    world:socket_open(socket)
    world.sockets[socket].write = function()
      error("the socket is gone", 0)
    end
    assert.is_false(platform.send("{}"))
    assert.is_false(platform.send("{}"))
    assert.are.equal(1, logged(record, "warn", "GWSockets could not send a frame: the socket is gone"))

    -- The next connection is a new one, so it says why again.
    world:socket_close(socket, "gone")
    record.time = record.time + 120000
    world:run_due()
    local second = record.connects[2].id
    world:socket_open(second)
    world.sockets[second].write = function()
      error("still gone", 0)
    end
    assert.is_false(world.core.connection.platform.send("{}"))
    assert.are.equal(1, logged(record, "warn", "GWSockets could not send a frame: still gone"))
  end)

  it("gives up a connection whose Hello cannot be written, and tries again after a backoff", function()
    local world, record = boot("server")
    local socket = record.connects[1].id
    world.sockets[socket].write = function()
      error("the socket is gone", 0)
    end
    world:socket_open(socket)
    assert.are.same({ socket }, record.closes, "the core closed it at once")
    assert.are.equal(1, logged(record, "warn", "GWSockets could not send a frame: the socket is gone"))
    record.time = record.time + 120000
    world:run_due()
    assert.are.equal(2, #record.connects)
  end)

  it("reports a close, and reconnects after a backoff, when GWSockets raises on open", function()
    local world, record = boot("server")
    local create = _G.GWSockets.createWebSocket
    local raised = false
    _G.GWSockets.createWebSocket = function(...)
      local socket = create(...)
      local open = socket.open
      socket.open = function(self)
        if not raised then
          raised = true
          error("no such host", 0)
        end
        return open(self)
      end
      return socket
    end
    world:socket_close(record.connects[1].id, "gone")
    record.time = record.time + 120000
    local ran, err = pcall(world.run_due, world)
    assert.is_true(ran, tostring(err))
    assert.is_true(raised)
    assert.are.equal(1, logged(record, "warn", "GWSockets could not open the websocket: no such host"))
    assert.are.equal(1, #record.connects, "nothing reached the host for the failed attempt")
    record.time = record.time + 120000
    world:run_due()
    assert.are.equal(2, #record.connects, "the core backed off and tried again")
  end)

  it("logs why a close failed, and still reports the close once", function()
    local world, record = boot("server")
    welcome(world, record)
    local socket = record.connects[1].id
    world.sockets[socket].closeNow = function()
      error("already closed", 0)
    end
    world:run_hook("ShutDown")
    assert.are.equal(1, logged(record, "warn", "GWSockets could not close the websocket: already closed"))
    world:run_due()
    world:socket_close(socket, "closed")
    assert.are.equal(1, logged(record, "warn", "disconnected"), "the core heard one close")
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

  it("offers the minimal interaction UI as a command, which asks the server what is near", function()
    local world, record = boot("client")
    assert.is_function(world.commands.rpf_interact)
    local before = #record.to_server
    world:command("rpf_interact")
    assert.is_true(#record.to_server > before, "a request went to the server")
  end)

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

  it("numbers its requests, and hands each answer to its own callback once", function()
    local gmod = load_fake()
    local host, record = fake_host()
    local world = gmod.install("client", host, { read = read })
    installed = world
    world:boot()
    local messages = world.include("rpf/platform/gmod/messages.lua")
    local replies = {}
    for _, which in ipairs({ "first", "second" }) do
      messages.request_server("rpf:test", which, function(reply)
        replies[#replies + 1] = which .. ":" .. tostring(reply)
      end)
    end
    local asked = {}
    for _, message in ipairs(record.to_server) do
      if message.name == "rpf:test" then
        asked[#asked + 1] = message.payload
      end
    end
    local first, second = asked[1]:match("^(%d+)\n"), asked[2]:match("^(%d+)\n")
    assert.are.same({ first .. "\nfirst", second .. "\nsecond" }, asked)
    world:from_server("rpf:test", second .. "\ntwo")
    world:from_server("rpf:test", "999\nnobody asked")
    world:from_server("rpf:test", first .. "\none")
    world:from_server("rpf:test", first .. "\nagain")
    assert.are.same({ "second:two", "first:one" }, replies)
  end)

  it("forgets a request that has no answer, telling its callback none will come", function()
    local gmod = load_fake()
    local host, record = fake_host()
    local world = gmod.install("client", host, { read = read })
    installed = world
    world:boot()
    local messages = world.include("rpf/platform/gmod/messages.lua")
    local replies = {}
    messages.request_server("rpf:test", "lost", function(reply)
      replies[#replies + 1] = reply == nil and "nil" or reply
    end)
    local asked = record.to_server[#record.to_server].payload
    record.time = record.time + (messages.REQUEST_TTL - 1) * 1000
    world:run_due()
    assert.are.same({}, replies)
    record.time = record.time + 1000
    world:run_due()
    assert.are.same({ "nil" }, replies)
    world:from_server("rpf:test", asked:match("^(%d+)\n") .. "\ntoo late")
    assert.are.same({ "nil" }, replies, "a late answer finds nothing waiting")
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

  it("offers to delete the account from the login form, saying what stays, and goes back", function()
    local gmod, world = at_login()
    button(gmod, world, "Delete my account"):DoClick()
    local text = labels(gmod, world)
    assert.truthy(text:find("cannot be undone", 1, true))
    assert.truthy(text:find("Bans, warnings and game records", 1, true))
    assert.are.equal(2, #gmod.shown(world, "DTextEntry"))
    button(gmod, world, "Back"):DoClick()
    assert.truthy(labels(gmod, world):find(world.core.auth.PASSWORD_REUSE_WARNING, 1, true))
    assert.are.equal(2, #gmod.shown(world, "DTextEntry"))
  end)

  it("deletes the account only once the box is ticked, and tells the player to reconnect", function()
    local gmod, world, record = at_login()
    button(gmod, world, "Delete my account"):DoClick()
    local fields = gmod.shown(world, "DTextEntry")
    fields[1].value = "alice"
    fields[2].value = "correct horse battery"
    local requests = #record.requests
    button(gmod, world, "Delete my account"):DoClick()
    assert.are.equal(requests, #record.requests, "nothing was sent")
    assert.truthy(labels(gmod, world):find("Tick the box", 1, true))

    gmod.shown(world, "DCheckBoxLabel")[1].value = true
    button(gmod, world, "Delete my account"):DoClick()
    local request = record.requests[#record.requests]
    assert.are.equal("https://portal.test/api/v1/player/delete_account", request.url)
    assert.truthy(request.body:find("correct horse battery", 1, true))
    for _, message in ipairs(record.to_server) do
      assert.falsy(message.payload:find("correct horse battery", 1, true), message.name)
    end
    world:http_done(request.id, 204, "", {})
    assert.are.equal("deleted", world.core.auth.state())
    assert.truthy(labels(gmod, world):find("alice was deleted", 1, true))
    assert.truthy(labels(gmod, world):find("reconnect", 1, true))
    button(gmod, world, "Disconnect"):DoClick()
    assert.are.same({ "disconnect" }, world.console)
  end)

  it("shows why a deletion was refused", function()
    local gmod, world, record = at_login()
    button(gmod, world, "Delete my account"):DoClick()
    local fields = gmod.shown(world, "DTextEntry")
    fields[1].value = "alice"
    fields[2].value = "correct horse battery"
    gmod.shown(world, "DCheckBoxLabel")[1].value = true
    button(gmod, world, "Delete my account"):DoClick()
    local request = record.requests[#record.requests]
    world:http_done(
      request.id,
      401,
      '{"error":"invalid_credentials","message":"That username and password do not match."}',
      {}
    )
    assert.truthy(labels(gmod, world):find("do not match", 1, true))
    assert.is_true(button(gmod, world, "Delete my account").enabled)
    assert.are_not.equal("deleted", world.core.auth.state())
  end)

  ---Logs in through the form and the server's answer, so the player is in
  ---the game, as a resumed or returning one is.
  ---@return rpf.mock.gmod gmod The fake module.
  ---@return rpf.mock.GmodWorld world The fake.
  ---@return table record What the host recorded.
  ---@param no_characters boolean? Whether the server sends no list, as one whose characters are another framework's.
  local function in_game(no_characters)
    local gmod, world, record = at_login()
    local fields = gmod.shown(world, "DTextEntry")
    fields[1].value = "alice"
    fields[2].value = "correct horse battery"
    button(gmod, world, "Log in"):DoClick()
    local request = record.requests[#record.requests]
    world:http_done(
      request.id,
      200,
      assert(world.core.json.encode(world.core.json.object({
        player_id = "00000000-0000-4000-8000-000000000001",
        username = "alice",
        created = false,
        ticket = "rpf_jt_ticket",
        ticket_expires_at = "2026-01-01T00:01:00Z",
        remember_token = "rpf_rt_remember",
        remember_token_expires_at = "2026-01-31T00:00:00Z",
        session_token = "rpf_st_session",
        session_token_expires_at = "2026-01-01T12:00:00Z",
        api_token = world.core.json.null,
        api_token_expires_at = world.core.json.null,
      }))),
      {}
    )
    world:from_server("rpf:join_result", world.core.handoff.encode("rpf:join_result", {
      ok = true,
      player_id = "00000000-0000-4000-8000-000000000001",
      username = "alice",
      created = false,
    }))
    assert.are.equal("authenticated", world.core.auth.state())
    if not no_characters then
      world:from_server("rpf:characters", world.core.handoff.encode("rpf:characters", {
        characters = world.core.json.array({
          { id = "00000000-0000-4000-8000-0000000000c1", first_name = "Ada", last_name = "Byron", gender = "female" },
        }),
        selected = "00000000-0000-4000-8000-0000000000c1",
      }))
    end
    -- The server hands out a fresh nonce for the next thing the player does.
    world:from_server("rpf:join_nonce", world.core.handoff.encode("rpf:join_nonce", {
      nonce = "nonce-2",
      expires_in_ms = 60000,
      portal_url = "https://portal.test",
      server_id = SERVER_ID,
    }))
    return gmod, world, record
  end

  it("opens the delete form from the console for a logged-in player, and Back returns to the game", function()
    local gmod, world, record = in_game()
    assert.are.same({}, gmod.shown(world, "DFrame"))
    world:command("rpf_delete_account")
    assert.truthy(labels(gmod, world):find("cannot be undone", 1, true))
    button(gmod, world, "Back"):DoClick()
    assert.are.same({}, gmod.shown(world, "DFrame"))

    world:command("rpf_delete_account")
    local fields = gmod.shown(world, "DTextEntry")
    fields[1].value = "alice"
    fields[2].value = "correct horse battery"
    gmod.shown(world, "DCheckBoxLabel")[1].value = true
    button(gmod, world, "Delete my account"):DoClick()
    local request = record.requests[#record.requests]
    assert.are.equal("https://portal.test/api/v1/player/delete_account", request.url)
    world:http_done(request.id, 204, "", {})
    assert.are.equal("deleted", world.core.auth.state())
    assert.truthy(labels(gmod, world):find("alice was deleted", 1, true))
  end)

  it("asks for the box and shows a refusal on the form opened from the console", function()
    local gmod, world, record = in_game()
    world:command("rpf_delete_account")
    local fields = gmod.shown(world, "DTextEntry")
    fields[1].value = "alice"
    fields[2].value = "correct horse battery"
    local requests = #record.requests
    button(gmod, world, "Delete my account"):DoClick()
    assert.are.equal(requests, #record.requests)
    assert.truthy(labels(gmod, world):find("Tick the box", 1, true))
    gmod.shown(world, "DCheckBoxLabel")[1].value = true
    button(gmod, world, "Delete my account"):DoClick()
    world:http_done(
      record.requests[#record.requests].id,
      401,
      '{"error":"invalid_credentials","message":"That username and password do not match."}',
      {}
    )
    assert.truthy(labels(gmod, world):find("do not match", 1, true))
    assert.are.equal("authenticated", world.core.auth.state())
  end)

  it("returns to the game, not to an empty character screen, when characters are another framework's", function()
    local gmod, world = in_game(true)
    assert.are.same({}, gmod.shown(world, "DFrame"), "no character screen was ever up")
    world:command("rpf_delete_account")
    button(gmod, world, "Back"):DoClick()
    assert.are.same({}, gmod.shown(world, "DFrame"))
  end)

  it("sends a player who backs out while choosing a character to the character screen, and ignores the command before login", function()
    local gmod, world = at_login()
    world:command("rpf_delete_account")
    assert.are.same({ "Log in" }, { button(gmod, world, "Log in").text }, "the login form is still up")
    assert.is_nil(labels(gmod, world):find("cannot be undone", 1, true))
    gmod, world = in_game()
    world:from_server("rpf:characters", world.core.handoff.encode("rpf:characters", {
      characters = world.core.json.array({
        { id = "00000000-0000-4000-8000-0000000000c1", first_name = "Ada", last_name = "Byron", gender = "female" },
      }),
    }))
    world:command("rpf_delete_account")
    world:command("rpf_delete_account")
    button(gmod, world, "Back"):DoClick()
    assert.truthy(button(gmod, world, "Play Ada Byron"), "running it twice keeps the way back")
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

describe("the Gmod adapter's addon UI (J10)", function()
  ---The panels on show of a class.
  ---@param world rpf.mock.GmodWorld The fake.
  ---@param class string The Derma class.
  ---@return rpf.mock.GmodPanel[] panels The panels.
  local function shown(world, class)
    return load_fake().shown(world, class)
  end

  ---The button on show with a text.
  ---@param world rpf.mock.GmodWorld The fake.
  ---@param text string Its text.
  ---@return rpf.mock.GmodPanel button The button.
  local function button(world, text)
    for _, panel in ipairs(shown(world, "DButton")) do
      if panel.text == text then
        return panel
      end
    end
    error("no button " .. text .. " on show")
  end

  ---Boots a client: the global `rpf` is the public API.
  ---@return rpf.mock.GmodWorld world The fake.
  ---@return table api The public API.
  ---@return table record What the host recorded; its `time` is the clock.
  local function client()
    local world, record = boot("client")
    return world, rawget(_G, "rpf"), record
  end

  it("shows a notification in Gmod's own, by kind", function()
    local world, api = client()
    assert.is_true(api.ui.notify({ text = "Sprayed.", title = "Tags", kind = "error", duration_ms = 3000 }))
    assert.are.same({ text = "Tags: Sprayed.", kind = NOTIFY_ERROR, seconds = 3 }, world.notices[1])
  end)

  it("shows a menu of buttons, a disabled one greyed out, and closing it is cancelling", function()
    local world, api = client()
    local got = {}
    local keep = function(choice, err)
      got[#got + 1] = { choice, err }
    end
    api.ui.menu({ title = "Pick", options = { { label = "a", value = "A", description = "first" }, { label = "b", disabled = true } } }, keep)
    local frame = shown(world, "DFrame")[1]
    assert.are.equal("Pick", frame.title)
    assert.are.equal("first", button(world, "a").tooltip)
    assert.is_false(button(world, "b").enabled)
    button(world, "a"):DoClick()
    assert.are.same({ { "A" } }, got)
    assert.are.same({}, shown(world, "DFrame"), "closed once picked")
    api.ui.menu({ title = "Pick", options = { { label = "a" } } }, keep)
    shown(world, "DFrame")[1]:Close()
    assert.are.same({ nil, "cancelled" }, got[2])
  end)

  it("keeps a long menu on the screen, its options scrolling", function()
    local world, api = client()
    local options = {}
    for i = 1, 32 do
      options[i] = { label = "option " .. i }
    end
    api.ui.menu({ title = "Long", options = options }, function() end)
    local frame = shown(world, "DFrame")[1]
    assert.is_true(frame.size[2] <= ScrH() * 0.8)
    local scroll = shown(world, "DScrollPanel")[1]
    assert.are.equal(scroll, button(world, "option 32").parent, "the options are in the scrolling panel")
  end)

  it("takes away a window an addon that stopped had on show", function()
    local world = client()
    local addon_ui = world.include("rpf/platform/gmod/addon_ui.lua")
    addon_ui.ui.menu({ title = "Pick", options = { { label = "a" } } }, function() end)
    assert.are.equal(1, #shown(world, "DFrame"))
    addon_ui.ui.close("menu")
    assert.are.same({}, shown(world, "DFrame"))
    addon_ui.ui.close("menu")
  end)

  it("draws an option's item image beside its button (P3, #361)", function()
    local world = client()
    local addon_ui = world.include("rpf/platform/gmod/addon_ui.lua")
    local src = "data/rpf/images/" .. string.rep("a", 64) .. ".png"
    addon_ui.ui.menu({ title = "Shop", options = { { label = "Apple", item = "apple", image = src }, { label = "Close", item = "pear" } } }, function() end)
    local images = shown(world, "DImage")
    assert.are.equal(1, #images, "one image, for the option that has one")
    assert.are.equal(src, images[1].image)
    assert.are.equal(button(world, "Apple"), images[1].parent, "in its own button")
    assert.are.same({}, button(world, "Close").children, "none for an item whose image did not come")
    button(world, "Apple"):DoClick()
    assert.are.same({}, shown(world, "DImage"), "gone with the menu")
  end)

  it("will not submit a required checkbox left unticked", function()
    local world, api = client()
    local got
    api.ui.input({ title = "Agree", fields = { { name = "ok", label = "I agree", kind = "checkbox", required = true } } }, function(values)
      got = values
    end)
    button(world, "Submit"):DoClick()
    local status = shown(world, "DLabel")
    assert.are.equal("I agree must be ticked.", status[#status].text)
    shown(world, "DCheckBoxLabel")[1].value = true
    button(world, "Submit"):DoClick()
    assert.are.same({ ok = true }, got)
  end)

  it("shows an input dialog that will not submit until it is filled in right", function()
    local world, api = client()
    local got
    api.ui.input({
      title = "Spray",
      fields = {
        { name = "text", label = "Text", required = true, max = 4 },
        { name = "size", label = "Size", kind = "number", min = 1, max = 3 },
        { name = "glow", label = "Glow", kind = "checkbox" },
        { name = "colour", label = "Colour", kind = "select", default = "blue", options = { { label = "Red", value = "red" }, { label = "Blue", value = "blue" } } },
      },
    }, function(values, err)
      got = { values, err }
    end)
    local entries = shown(world, "DTextEntry")
    local submit = button(world, "Submit")
    submit:DoClick()
    assert.is_nil(got)
    local status = shown(world, "DLabel")
    assert.are.equal("Text is required.", status[#status].text)
    entries[1].value = "too long"
    submit:DoClick()
    assert.are.equal("Text is too long.", status[#status].text)
    entries[1].value = "hi"
    entries[2].value = "7"
    submit:DoClick()
    assert.are.equal("Size must be between 1 and 3.", status[#status].text)
    entries[2].value = "2"
    shown(world, "DCheckBoxLabel")[1].value = true
    submit:DoClick()
    assert.are.same({ { text = "hi", size = 2, glow = true, colour = "blue" } }, got)
    api.ui.input({ title = "Again", fields = { { name = "a", label = "A" } } }, function(values, err)
      got = { values, err }
    end)
    button(world, "Cancel"):DoClick()
    assert.are.same({ nil, "cancelled" }, got)
  end)

  it("fills a progress bar over its duration, and lets X cancel it when allowed", function()
    local world, api, record = client()
    local got = {}
    local keep = function(done, err)
      got[#got + 1] = { done, err }
    end
    api.ui.progress({ label = "Spraying", duration_ms = 2000 }, keep)
    local frame = shown(world, "DFrame")[1]
    assert.are.equal("Spraying (X to cancel)", frame.title)
    record.time = record.time + 1000
    frame:Think()
    assert.are.equal(0.5, shown(world, "DProgress")[1].fraction)
    world.keys[KEY_X] = true
    frame:Think()
    assert.are.same({ { nil, "cancelled" } }, got)
    world.keys[KEY_X] = nil
    api.ui.progress({ label = "Spraying", duration_ms = 500, cancel = false }, keep)
    frame = shown(world, "DFrame")[1]
    world.keys[KEY_X] = true
    frame:Think()
    assert.are.equal(1, #got, "X does nothing to one that cannot be cancelled")
    record.time = record.time + 500
    frame:Think()
    assert.are.same({ true }, got[2])
  end)

  it("answers its server's request under the number it was asked with, once the player picks", function()
    local world, _, record = client()
    local core = assert(world.core)
    local spec = core.ui.spec("menu", { title = "Pick", options = { { label = "a" }, { label = "b" } } })
    local request = core.handoff.encode("rpf:ui", { kind = "menu", spec = core.json.object(core.json.copy(spec)) })
    world:from_server("rpf:ui", "8\n" .. request)
    local before = #record.to_server
    button(world, "b"):DoClick()
    assert.are.equal(before + 1, #record.to_server)
    local sent = record.to_server[#record.to_server]
    assert.are.equal("rpf:ui", sent.name)
    local number, reply = sent.payload:match("^(%d+)\n(.*)$")
    assert.are.equal("8", number)
    assert.are.same({ true, 2 }, { core.json.decode(reply).ok, core.json.decode(reply).index })
  end)

  it("takes a server's answer only from the player it asked", function()
    local world, record = boot("server")
    welcome(world, record)
    local alice = world:connect_player(1, "Alice", STEAMID)
    world:connect_player(2, "Bob", "76561198000000002")
    local messages = world.include("rpf/platform/gmod/messages.lua")
    local replies = {}
    messages.request_client(alice, "rpf:test_ui", "{}", function(reply)
      replies[#replies + 1] = reply == nil and "nil" or reply
    end)
    local sent = record.to_clients[#record.to_clients]
    local number = sent.payload:match("^(%d+)\n")
    world:from_client(2, "rpf:test_ui", number .. "\nfrom Bob")
    assert.are.same({}, replies)
    world:from_client(1, "rpf:test_ui", number .. "\nfrom Alice")
    assert.are.same({ "from Alice" }, replies)
    messages.request_client(alice, "rpf:test_ui", "{}", function(reply)
      replies[#replies + 1] = reply == nil and "nil" or reply
    end)
    record.time = record.time + messages.ANSWER_TTL * 1000
    world:run_due()
    assert.are.same({ "from Alice", "nil" }, replies, "forgotten after ANSWER_TTL")
  end)
end)

describe("the Gmod adapter's item images (P3, #243)", function()
  local PNG = "\137PNG\r\n\26\n" .. "pixels"

  ---Boots a client and builds `item_image` over its HTTP.
  ---@return rpf.mock.GmodWorld world The fake.
  ---@return table record What the host recorded.
  ---@return table images The module (`rpf.gmod.Images`, which the main check does not load).
  ---@return fun(url: string, headers: table, hash: string, done: fun(src: string?, err: string?)) item_image The member.
  local function client()
    local world, record = boot("client")
    local images = world.include("rpf/platform/gmod/images.lua")
    local shared = world.include("rpf/platform/gmod/shared.lua")
    return world, record, images, images.item_image(shared.http_request)
  end

  ---Asks for an image, recording what came back.
  ---@param item_image function The member.
  ---@param hash string The hash.
  ---@return { src: string?, err: string?, calls: integer } got What arrived.
  local function ask(item_image, hash)
    local got = { calls = 0 }
    item_image("https://portal.test/api/v1/player/items/apple/image?v=" .. hash, { Authorization = "Bearer rpf_at_t" }, hash, function(src, err)
      got.calls = got.calls + 1
      got.src, got.err = src, err
    end)
    return got
  end

  it("fetches with the token in a header, keeps the PNG under data/ by hash, and answers with its material path", function()
    local world, record, _, item_image = client()
    local hash = util.SHA256(PNG)
    local got = ask(item_image, hash)
    local request = record.requests[#record.requests]
    assert.are.equal("GET", request.method)
    assert.are.equal("Bearer rpf_at_t", request.headers.Authorization)
    assert.is_nil(request.url:find("rpf_at_", 1, true))
    world:http_done(request.id, 200, PNG, {})
    assert.are.same({ calls = 1, src = "data/rpf/images/" .. hash .. ".png" }, got)
    assert.are.equal(PNG, world.data["rpf/images/" .. hash .. ".png"].bytes)
    assert.is_false(Material(got.src):IsError())

    local requests = #record.requests
    local again = ask(item_image, hash)
    assert.are.equal(0, again.calls, "never inside the call")
    world:run_due()
    assert.are.equal(got.src, again.src)
    assert.are.equal(requests, #record.requests, "kept: not fetched again")
  end)

  it("says not_found for a 404, unavailable for anything else, and keeps nothing that is not the hash's image", function()
    local world, record, _, item_image = client()
    local hash = util.SHA256(PNG)
    local cases = {
      { status = 404, body = "", err = "not_found" },
      { status = 500, body = "", err = "unavailable" },
      { status = 200, body = PNG .. "tampered", err = "unavailable" },
    }
    for _, case in ipairs(cases) do
      local got = ask(item_image, hash)
      world:http_done(record.requests[#record.requests].id, case.status, case.body, {})
      assert.are.same({ calls = 1, err = case.err }, got, tostring(case.status))
    end
    assert.is_nil(next(world.data), "nothing written")
    local bad = ask(item_image, "../../cfg/server")
    world:run_due()
    assert.are.equal("unavailable", bad.err)
  end)

  it("refuses bytes the engine cannot draw, and fetches again a kept file that no longer matches its hash", function()
    local world, record, _, item_image = client()
    local html = "<html></html>"
    local html_hash = util.SHA256(html)
    local got = ask(item_image, html_hash)
    world:http_done(record.requests[#record.requests].id, 200, html, {})
    assert.are.equal("unavailable", got.err)
    assert.is_nil(world.data["rpf/images/" .. html_hash .. ".png"], "removed again")

    local hash = util.SHA256(PNG)
    world.data["rpf/images/" .. hash .. ".png"] = { bytes = "\137PNG cut short", time = 0 }
    local requests = #record.requests
    got = ask(item_image, hash)
    assert.are.equal(requests + 1, #record.requests, "fetched again")
    world:http_done(record.requests[#record.requests].id, 200, PNG, {})
    assert.are.equal(PNG, world.data["rpf/images/" .. hash .. ".png"].bytes)
    assert.are.equal("data/rpf/images/" .. hash .. ".png", got.src)
  end)

  it("keeps at most MAX_KEPT images, the oldest written dropped first", function()
    local world, record, images, item_image = client()
    images.MAX_KEPT = 2
    local hashes = {}
    for i = 1, 3 do
      local bytes = PNG .. tostring(i)
      hashes[i] = util.SHA256(bytes)
      ask(item_image, hashes[i])
      world:http_done(record.requests[#record.requests].id, 200, bytes, {})
      record.time = record.time + 1000
    end
    assert.is_nil(world.data["rpf/images/" .. hashes[1] .. ".png"])
    assert.is_table(world.data["rpf/images/" .. hashes[2] .. ".png"])
    assert.is_table(world.data["rpf/images/" .. hashes[3] .. ".png"])
  end)
end)
