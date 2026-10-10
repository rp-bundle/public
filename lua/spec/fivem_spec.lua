-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The FiveM adapter (D2), loaded unmodified from its manifest on fake FiveM
-- globals (`lua/platform/mock/fivem.lua`): the server and client platforms
-- are complete and behave as the interfaces say, the engine events reach the
-- core, the screens follow the login, a password never reaches Lua, and
-- every engine event handler is at most two lines.

local support = require("spec.support")

local MANIFEST = "lua/platform/fivem/fxmanifest.lua"

---The FiveM fakes, bound to a fresh mock platform module.
---@return rpf.mock.fivem fivem The fakes.
local function fakes()
  local mock = dofile(support.path("lua/platform/mock/init.lua"))
  return dofile(support.path("lua/platform/mock/fivem.lua")).bind(mock)
end

---A script path from the manifest, as a path in the repository.
---@param script string Relative to the resource, like `core/json.lua`.
---@return string path Relative to the repository root.
local function repository_path(script)
  local core = script:match("^core/(.+)$")
  if core then
    return "lua/core/" .. core
  end
  return "lua/platform/fivem/" .. script
end

---Every global the fakes set, so `after_each` can take them away again.
---@type table<string, true>
local installed = {}

---Remembers which globals are new, so they can be removed.
---@param before table<string, true> The names that existed before.
local function note_new_globals(before)
  for key in pairs(_G) do
    if not before[key] then
      installed[key] = true
    end
  end
end

---The names in the global table now.
---@return table<string, true> names The set.
local function global_names()
  local names = {}
  for key in pairs(_G) do
    names[key] = true
  end
  return names
end

---A host recording what the adapter does, with a clock the test moves.
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
    notes = {},
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
    notify = function(player, message)
      record.notes[#record.notes + 1] = { player = player, message = message }
    end,
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

---Loads one side of the resource as FiveM would: the fakes first, then
---every script the manifest names, in order, into the global table.
---@param side "server"|"client" Which side.
---@param convars table<string, string>? The convars.
---@return table driver The fakes' driver.
---@return table record What the host recorded.
local function load_side(side, convars)
  rawset(_G, "rpf", nil)
  local before = global_names()
  local host, record = fake_host()
  local driver = fakes()[side](_G, host, 1, convars or {})
  for _, script in ipairs(fakes().scripts(support.read(MANIFEST), side)) do
    dofile(support.path(repository_path(script)))
  end
  note_new_globals(before)
  support.core = rpf
  return driver, record
end

---The convars a configured server has.
local CONVARS = { rpf_url = "wss://portal.example/ws", rpf_api_key = "rpf_sk_secret" }

---Starts a configured server and opens its socket.
---@return table driver The driver.
---@return table record What the host recorded.
local function started_server()
  local driver, record = load_side("server", CONVARS)
  driver.start()
  driver.socket_open(record.connects[1].id)
  return driver, record
end

---The frames the server sent of one type, decoded.
---@param record table What the host recorded.
---@param tag string The frame type.
---@return table[] frames The frames.
local function frames(record, tag)
  local out = {}
  for _, sent in ipairs(record.sent) do
    local frame = rpf.json.decode(sent.text)
    if frame and frame.type == tag then
      out[#out + 1] = frame
    end
  end
  return out
end

---The NUI messages sent so far, decoded.
---@param driver table The client driver.
---@return table[] messages The messages.
local function nui_messages(driver)
  local out = {}
  for i, text in ipairs(driver.nui_sent) do
    out[i] = assert(rpf.json.decode(text))
  end
  return out
end

---The last screen message sent to the page.
---@param driver table The client driver.
---@return table message The message.
local function last_screen(driver)
  local found
  for _, message in ipairs(nui_messages(driver)) do
    if message.type == "screen" then
      found = message
    end
  end
  return assert(found, "no screen was shown")
end

describe("the FiveM adapter", function()
  after_each(function()
    for key in pairs(installed) do
      rawset(_G, key, nil)
    end
    installed = {}
  end)

  describe("its manifest", function()
    it("loads the core in rpf.files order, then the adapter, on each side", function()
      support.load_core("server")
      local scripts = fakes().scripts(support.read(MANIFEST), "server")
      local expected = { "core/init.lua" }
      for _, file in ipairs(rpf.files.server) do
        expected[#expected + 1] = "core/" .. file
      end
      for _, file in ipairs({ "shared.lua", "ws.lua", "lock.lua", "server.lua" }) do
        expected[#expected + 1] = file
      end
      assert.are.same(expected, scripts)

      expected = { "core/init.lua" }
      for _, file in ipairs(rpf.files.client) do
        expected[#expected + 1] = "core/" .. file
      end
      for _, file in ipairs({ "shared.lua", "ui.lua", "client.lua" }) do
        expected[#expected + 1] = file
      end
      assert.are.same(expected, fakes().scripts(support.read(MANIFEST), "client"))
    end)

    it("names a file that exists for every script", function()
      for _, side in ipairs({ "server", "client" }) do
        for _, script in ipairs(fakes().scripts(support.read(MANIFEST), side)) do
          assert.is_truthy(io.open(support.path(repository_path(script))), script)
        end
      end
    end)
  end)

  describe("every engine event handler", function()
    for _, file in ipairs({ "server.lua", "client.lua" }) do
      it("in " .. file .. " is at most two lines", function()
        local lines = {}
        for line in support.read("lua/platform/fivem/" .. file):gmatch("([^\n]*)\n") do
          lines[#lines + 1] = line
        end
        local handlers = 0
        for i, line in ipairs(lines) do
          if line:match("AddEventHandler%(") or line:match("RegisterNetEvent%(") or line:match("RegisterNUICallback%(") then
            if line:match("function") then
              handlers = handlers + 1
              if not line:match("end%)%s*$") then
                local j = i + 1
                while lines[j] and not lines[j]:match("^%s*end%)%s*$") do
                  j = j + 1
                end
                assert.is_true(j - i - 1 <= 2, file .. ":" .. i .. " has a " .. (j - i - 1) .. "-line handler")
              end
            end
          end
        end
        assert.is_true(handlers >= 3, "found the handlers")
      end)
    end
  end)

  describe("the server", function()
    it("is a complete server platform reporting fivem", function()
      local _, record = started_server()
      local platform = rpf.connection.platform
      assert.are.same({}, rpf.platform.missing(platform, "server"))
      assert.are.equal("fivem", platform.engine)
      local hello = frames(record, "hello")[1]
      assert.are.equal("fivem", hello.engine)
    end)

    it("does not connect without its convars, and says which", function()
      local driver, record = load_side("server", { rpf_url = "wss://portal.example/ws" })
      driver.start()
      assert.are.same({}, record.connects)
      local said = false
      for _, line in ipairs(record.logs) do
        said = said or (line.level == "error" and line.message:find("rpf_api_key", 1, true) ~= nil)
      end
      assert.is_true(said)
    end)

    ---Starts a server set up as `prepare` leaves it, and returns the error
    ---lines it logged. A refusal is one line, and nothing connects.
    ---@param convars table<string, string> The convars.
    ---@param prepare fun(driver: table)? Changes the server before it starts.
    ---@return string refusal The one error line.
    ---@return table driver The driver.
    local function refused(convars, prepare)
      local driver, record = load_side("server", convars)
      if prepare then
        prepare(driver)
      end
      driver.start()
      assert.are.same({}, record.connects, "nothing connects")
      local errors = {}
      for _, line in ipairs(record.logs) do
        if line.level == "error" then
          errors[#errors + 1] = line.message
        end
      end
      assert.are.equal(1, #errors, "one line: " .. table.concat(errors, " | "))
      assert.is_falsy(errors[1]:find("rpf_sk_secret", 1, true), "the key is never logged")
      return errors[1], driver
    end

    it("refuses an address that is not a websocket's, naming rpf_url", function()
      local line = refused({ rpf_url = "https://portal.example/ws", rpf_api_key = "rpf_sk_secret" })
      assert.truthy(line:find("rpf_url is not the portal's websocket address", 1, true), line)
    end)

    it("refuses a key that is not shaped like one, naming rpf_api_key without repeating it", function()
      local line = refused({ rpf_url = "wss://portal.example/ws", rpf_api_key = "sk_secret" })
      assert.truthy(line:find("rpf_api_key does not look like a server API key", 1, true), line)
      assert.is_falsy(line:find("sk_secret", 1, true), line)
    end)

    it("refuses to start unless OneSync is on, legacy included, and says how to set it", function()
      for _, mode in ipairs({ "off", "legacy" }) do
        local convars = { onesync = mode }
        for name, value in pairs(CONVARS) do
          convars[name] = value
        end
        local line = refused(convars)
        assert.truthy(line:find("OneSync is " .. mode, 1, true), line)
        assert.truthy(line:find("set onesync on", 1, true), line)
        for key in pairs(installed) do
          rawset(_G, key, nil)
        end
        installed = {}
      end
    end)

    it("refuses to start on an artifact without routing buckets, and says to update it", function()
      local line = refused(CONVARS, function()
        rawset(_G, "SetRoutingBucketEntityLockdownMode", nil)
      end)
      assert.truthy(line:find("this FXServer artifact has no SetRoutingBucketEntityLockdownMode", 1, true), line)
      assert.truthy(line:find(rpf.fivem.server.ARTIFACTS_URL, 1, true), line)
    end)

    it("refuses to start while rpf-ws is not started, and says to ensure it first", function()
      local line = refused(CONVARS, function(driver)
        driver.resources["rpf-ws"] = "stopped"
      end)
      assert.truthy(line:find("the rpf-ws resource is stopped", 1, true), line)
      assert.truthy(line:find("`ensure rpf-ws` before `ensure rpf`", 1, true), line)
    end)

    it("hands no player to a core it refused to start", function()
      local _, driver = refused({ rpf_url = "wss://portal.example/ws" })
      driver.add_player(7, "Sam", { "license:0123" })
      driver.connect_player(7)
      assert.is_nil(rpf.players.get(7))
      driver.drop_player(7, "Exiting")
      assert.is_nil(rpf.players.get(7))
    end)

    it("hands the core players already on the server when it starts", function()
      local driver, record = load_side("server", CONVARS)
      driver.add_player(3, "Early", { "license:abc" })
      driver.start()
      assert.are.equal("connecting", rpf.players.get(3).state)
      assert.are.equal(1, #record.connects)
    end)

    it("hands joins and drops to the core with FiveM's source", function()
      local driver = started_server()
      driver.add_player(7, "Sam", { "license:0123", "ip:10.0.0.1", "steam:1100001" })
      driver.connect_player(7)
      assert.are.equal("connecting", rpf.players.get(7).state)
      driver.drop_player(7, "Exiting")
      assert.is_nil(rpf.players.get(7))
    end)

    it("holds a player in a bucket of their own, chat refused, until they are active", function()
      local driver = started_server()
      driver.add_player(7, "Sam", { "license:0123" })
      driver.connect_player(7)
      local lock = rpf.fivem.lock
      assert.are.equal(lock.BUCKET_BASE + 7, driver.bucket(7))
      assert.are.equal("strict", driver.lockdown[lock.BUCKET_BASE + 7], "clients may create nothing there")
      assert.is_true(driver.chat(7, "hello"), "chat refused")
      -- The login gate, then whatever owns characters, move the player on.
      rpf.players.authenticating(7)
      rpf.players.register(7, { player_id = "00000000-0000-4000-8000-000000000007", username = "sam" })
      assert.is_true(lock.locked(7), "still held while registered")
      rpf.players.advance(7, "character_select")
      rpf.players.advance(7, "active")
      assert.are.equal(0, driver.bucket(7), "back where they were")
      assert.is_false(driver.chat(7, "hello"))
      rpf.players.advance(7, "character_select")
      assert.is_true(lock.locked(7), "held again while choosing")
      driver.drop_player(7, "Exiting")
      assert.is_false(lock.locked(7))
    end)

    it("puts held players back in their own bucket when the resource stops", function()
      local driver = started_server()
      driver.add_player(7, "Sam", { "license:0123" })
      rawget(_G, "SetPlayerRoutingBucket")("7", 5)
      driver.connect_player(7)
      assert.are.equal(rpf.fivem.lock.BUCKET_BASE + 7, driver.bucket(7))
      driver.stop()
      assert.are.equal(5, driver.bucket(7))
    end)

    it("sends a player found in their holding bucket back to the default one", function()
      local driver = started_server()
      local lock = rpf.fivem.lock
      driver.add_player(7, "Sam", { "license:0123" })
      -- A state that crashed without stopping left them held.
      rawget(_G, "SetPlayerRoutingBucket")("7", lock.BUCKET_BASE + 7)
      driver.connect_player(7)
      rpf.players.authenticating(7)
      rpf.players.register(7, { player_id = "00000000-0000-4000-8000-000000000007", username = "sam" })
      rpf.players.advance(7, "character_select")
      rpf.players.advance(7, "active")
      assert.are.equal(0, driver.bucket(7))
    end)

    it("reports identifiers verbatim, and the core sends them without ip:", function()
      local driver, record = started_server()
      local platform = rpf.connection.platform
      driver.add_player(7, "Sam", { "license:0123", "ip:10.0.0.1", "steam:1100001" })
      assert.are.same({ "license:0123", "ip:10.0.0.1", "steam:1100001" }, platform.identifiers(7))
      assert.are.equal("Sam", platform.name(7))
      -- The portal's Welcome makes the connection ready, so the join goes out.
      local welcome = support.portal_frame("welcome", {
        re = frames(record, "hello")[1].id,
        protocol = rpf.protocol.VERSION,
        server_id = "00000000-0000-4000-8000-0000000000bb",
      })
      driver.socket_message(record.connects[1].id, assert(rpf.protocol.encode(rpf.protocol.PORTAL_TO_SERVER, welcome)))
      assert.are.equal("ready", rpf.connection.state)
      driver.connect_player(7)
      driver.from_client(7, "rpf:client_ready", "{}")
      local join = frames(record, "begin_join")[1]
      assert.is_truthy(join, "the join went out")
      assert.are.same({ "license:0123", "steam:1100001" }, join.identifiers)
    end)

    it("takes only string payloads from clients, from FiveM's source", function()
      local driver = started_server()
      local platform = rpf.connection.platform
      local heard = {}
      platform.on_client("rpf:test", function(player, payload)
        heard[#heard + 1] = { player = player, payload = payload }
      end)
      driver.from_client(4, "rpf:test", "{}")
      driver.from_client(4, "rpf:test", { not_a = "string" })
      driver.from_client(4, "rpf:unregistered", "{}")
      assert.are.same({ { player = 4, payload = "{}" } }, heard)
    end)

    it("kicks, notifies and messages a player through the engine", function()
      local _, record = started_server()
      local platform = rpf.connection.platform
      platform.kick(5, "Banned")
      platform.notify(5, "Hello")
      platform.to_client(5, "rpf:join_nonce", "{}")
      assert.are.same({ { player = 5, reason = "Banned" } }, record.kicks)
      assert.are.same({ { player = 5, message = "Hello" } }, record.notes)
      assert.are.same({ { player = 5, name = "rpf:join_nonce", payload = "{}" } }, record.to_clients)
    end)

    it("stores strings in resource KVP and deletes with nil", function()
      local _, record = started_server()
      local platform = rpf.connection.platform
      platform.kv_set("rpf.test", "value")
      assert.are.equal("value", platform.kv_get("rpf.test"))
      assert.are.equal("value", record.kv["rpf.test"])
      platform.kv_set("rpf.test", nil)
      assert.is_nil(platform.kv_get("rpf.test"))
    end)

    it("maps FiveM's HTTP callback onto the interface's, once each", function()
      local driver, record = started_server()
      local platform = rpf.connection.platform
      local answers = {}
      local function ask()
        platform.http_request("POST", "https://portal.example/x", { a = "b" }, "body", function(status, body, headers)
          answers[#answers + 1] = { status = status, body = body, headers = headers }
        end)
        return record.requests[#record.requests]
      end
      local ok, refused, lost = ask(), ask(), ask()
      assert.are.equal("POST", ok.method)
      assert.are.equal("body", ok.body)
      driver.http_done(ok.id, 200, "yes", { ["content-type"] = "text/plain" })
      driver.http_done(refused.id, 401, '{"error":"no"}', {})
      driver.http_done(lost.id, 0, "", {})
      driver.http_done(ok.id, 200, "again", {})
      assert.are.same({
        { status = 200, body = "yes", headers = { ["content-type"] = "text/plain" } },
        { status = 401, body = '{"error":"no"}', headers = {} },
        { status = 0, body = "", headers = {} },
      }, answers)
    end)

    it("mints random hex through the shim", function()
      started_server()
      local hex = rpf.connection.platform.random_hex(32)
      assert.are.equal(32, #hex)
      assert.is_truthy(hex:match("^[0-9a-f]+$"))
    end)

    it("falls back to Lua's generator, once warned, when the shim cannot answer", function()
      local _, record = started_server()
      rawget(_G, "exports")["rpf-ws"].random_hex = function()
        error("rpf-ws is not running")
      end
      local platform = rpf.connection.platform
      assert.are.equal(8, #platform.random_hex(8))
      assert.are.equal(8, #platform.random_hex(8))
      local warnings = 0
      for _, line in ipairs(record.logs) do
        if line.level == "warn" and line.message:find("random", 1, true) then
          warnings = warnings + 1
        end
      end
      assert.are.equal(1, warnings)
    end)

    it("exports the public API as plain tables", function()
      local driver = started_server()
      local api = driver.exported.api()
      assert.are.equal(nil, getmetatable(api))
      assert.are.equal("fivem", api.engine)
      assert.are.equal(rpf.VERSION, api.VERSION)
      assert.are.equal("function", type(api.events.on))
      assert.are.equal(nil, getmetatable(api.events))
      assert.are.equal("function", type(api.players.get))
      assert.are.equal("function", type(api.config.setting))
      assert.is_nil(api.auth)
    end)

    it("takes another resource's function references, and names subscriptions by id", function()
      local driver = started_server()
      local api = driver.exported.api()
      local heard = {}
      ---A function reference as FiveM hands one over: a fresh callable table,
      ---with a fresh id, each time the same function crosses.
      local made = 0
      ---@return table reference The reference.
      local function reference()
        made = made + 1
        return setmetatable({ __cfx_functionReference = "other:" .. made }, {
          __call = function(_, value)
            heard[#heard + 1] = value
          end,
        })
      end
      local id = api.events.on("scripts.ping", reference())
      assert.are.equal("string", type(id))
      api.events.emit("scripts.ping", 1)
      assert.is_false(api.events.off("scripts.ping", reference()), "a function is no key across the boundary")
      assert.is_true(api.events.off("scripts.ping", id))
      assert.is_false(api.events.off("scripts.ping", id), "and an id works once")
      api.events.emit("scripts.ping", 2)

      local once = api.events.once("scripts.ping", reference())
      api.events.emit("scripts.ping", 3)
      api.events.emit("scripts.ping", 4)
      assert.is_false(api.events.off("scripts.ping", once), "a fired once is gone")
      assert.are.same({ 1, 3 }, heard)
    end)

    it("closes once per connect, and ignores a connection it gave up", function()
      local driver, record = started_server()
      local first = record.connects[1].id
      local platform = rpf.connection.platform
      assert.is_true(platform.send("x"))
      driver.socket_close(first, "gone")
      assert.is_false(platform.send("x"), "nothing is open")
      driver.socket_close(first, "gone again")
      driver.socket_message(first, "late")
      record.time = record.time + 120000
      driver.run_due()
      assert.are.equal(2, #record.connects, "the core reconnected")
      local second = record.connects[2].id
      assert.are_not.equal(first, second)
    end)

    it("closes its sockets when the resource stops, since the shim outlives it", function()
      local driver, record = started_server()
      local first = record.connects[1].id
      -- A second attempt the core gave up on, still open in the shim.
      driver.socket_close(first, "gone")
      record.time = record.time + 120000
      driver.run_due()
      local second = record.connects[2].id
      driver.socket_open(second)
      driver.stop()
      assert.are.same({ second }, record.closes)
      assert.is_false(rpf.connection.platform.send("x"))
    end)

    it("logs a close the shim fails, rather than dropping it", function()
      local driver, record = started_server()
      local first = record.connects[1].id
      driver.socket_open(first)
      rawget(_G, "exports")["rpf-ws"].close = function()
        error("no such export")
      end
      driver.stop()
      local said = false
      for _, line in ipairs(record.logs) do
        said = said or (line.level == "error" and line.message:find("could not close socket " .. first, 1, true) ~= nil)
      end
      assert.is_true(said)
    end)

    it("logs why a send failed once per connection, and reports the frame as unsent", function()
      local driver, record = started_server()
      local first = record.connects[1].id
      driver.socket_open(first)
      rawget(_G, "exports")["rpf-ws"].send = function()
        error("rpf-ws is not running")
      end
      local platform = rpf.connection.platform
      assert.is_false(platform.send("x"))
      assert.is_false(platform.send("x"))
      local count = 0
      for _, line in ipairs(record.logs) do
        if line.level == "warn" and line.message:find("could not send a frame on socket " .. first, 1, true) then
          count = count + 1
          assert.truthy(line.message:find("rpf-ws is not running", 1, true), line.message)
        end
      end
      assert.are.equal(1, count)
    end)

    it("says nothing for a send the shim declines because the socket is not open", function()
      local driver, record = load_side("server", CONVARS)
      driver.start()
      assert.is_false(rpf.connection.platform.send("x"), "still opening")
      for _, line in ipairs(record.logs) do
        assert.is_nil(line.message:find("could not send", 1, true), line.message)
      end
    end)

    it("owes the core a close, later, when the shim cannot connect", function()
      local driver, record = load_side("server", CONVARS)
      local attempts = 0
      rawget(_G, "exports")["rpf-ws"].connect = function()
        attempts = attempts + 1
        error("no such export")
      end
      driver.start()
      assert.are.equal(1, attempts)
      for _ = 1, 3 do
        record.time = record.time + 120000
        driver.run_due()
      end
      assert.is_true(attempts > 1, "the core heard the close and tried again")
      local said = false
      for _, line in ipairs(record.logs) do
        said = said or line.message:find("could not open a socket", 1, true) ~= nil
      end
      assert.is_true(said)
    end)
  end)

  describe("the clock", function()
    it("keeps milliseconds between whole seconds, and follows a step", function()
      support.load_core("server")
      dofile(support.path("lua/platform/fivem/shared.lua"))
      local wall, ticks = 1000, 0
      local now = rpf.fivem.shared.clock(function()
        return wall
      end, function()
        return ticks
      end)
      assert.are.equal(1000000, now())
      ticks = 250
      assert.are.equal(1000250, now())
      ticks, wall = 1300, 1001
      assert.are.equal(1001300, now())
      -- The wall clock was set forward: the estimate jumps with it.
      ticks, wall = 1400, 2000
      assert.are.equal(2000000, now())
      -- And back: the estimate falls to the end of the new second.
      ticks, wall = 1500, 1500
      assert.are.equal(1500999, now())
      ticks = 1600
      assert.are.equal(1500999, now(), "never past the wall clock's second")
    end)
  end)

  describe("the client", function()
    ---Starts the client side and its screens.
    ---@return table driver The driver.
    ---@return table record What the host recorded.
    local function started_client()
      local driver, record = load_side("client")
      driver.start()
      return driver, record
    end

    ---The server hands the client a nonce.
    ---@param driver table The driver.
    local function nonce(driver)
      driver.from_server(
        "rpf:join_nonce",
        rpf.handoff.encode("rpf:join_nonce", {
          nonce = "rpf_jn_one",
          expires_in_ms = 120000,
          portal_url = "https://portal.example",
          server_id = "00000000-0000-4000-8000-0000000000bb",
        })
      )
    end

    it("is a complete client platform", function()
      local driver = load_side("client")
      local start_client = rpf.start_client
      local seen
      rpf.start_client = function(platform, options)
        seen = platform
        return start_client(platform, options)
      end
      driver.start()
      assert.are.same({}, rpf.platform.missing(seen, "client"))
      assert.are.equal("fivem", seen.engine)
    end)

    it("locks input from the start, and holds screens until the page is ready", function()
      local driver, record = started_client()
      assert.is_true(driver.focus)
      assert.is_true(driver.frozen)
      assert.are.same({}, driver.nui_sent)
      assert.are.equal("rpf:client_ready", record.to_server[1].name)
      assert.are.same({ ok = true }, driver.nui("ready", {}))
      assert.are.equal("connecting", last_screen(driver).screen)
      -- A page that reloads is shown the screen it lost.
      driver.nui("ready", {})
      assert.are.equal(2, #driver.nui_sent)
    end)

    it("shows the login with the reuse warning, and sends a sealed password, never the password", function()
      local driver, record = started_client()
      driver.nui("ready", {})
      nonce(driver)
      local login = last_screen(driver)
      assert.are.equal("login", login.screen)
      assert.are.equal(rpf.auth.PASSWORD_REUSE_WARNING, login.warning)

      local sealed = "rpf-sealed-00112233445566778899aabbccddeeff"
      assert.are.same({ ok = true }, driver.nui("login", { username = "sam", password = sealed, remember = false }))
      local request = nui_messages(driver)[#driver.nui_sent]
      assert.are.equal("http", request.type)
      assert.are.equal("POST", request.method)
      assert.are.equal("https://portal.example/api/v1/player/login", request.url)
      assert.are.equal(sealed, rpf.json.decode(request.body).password)

      -- The page answers with the portal's grant, and the ticket goes to
      -- the server.
      driver.nui("http", {
        id = request.id,
        status = 200,
        body = rpf.json.encode(rpf.json.object({
          player_id = "00000000-0000-4000-8000-000000000001",
          username = "sam",
          created = false,
          ticket = "rpf_jt_ticket",
          ticket_expires_at = "2026-01-01T00:01:00Z",
          remember_token = "rpf_rt_remember",
          remember_token_expires_at = "2026-01-31T00:00:00Z",
          session_token = "rpf_st_session",
          session_token_expires_at = "2026-01-01T12:00:00Z",
          api_token = rpf.json.null,
          api_token_expires_at = rpf.json.null,
        })),
        headers = {},
      })
      assert.are.equal("rpf:join_ticket", record.to_server[#record.to_server].name)
      for _, message in ipairs(record.to_server) do
        assert.is_nil(message.payload:find("rpf-sealed", 1, true), "no password, sealed or not, goes to the server")
      end

      driver.from_server(
        "rpf:join_result",
        rpf.handoff.encode("rpf:join_result", {
          ok = true,
          player_id = "00000000-0000-4000-8000-000000000001",
          username = "sam",
          created = false,
        })
      )
      assert.are.equal("authenticated", rpf.auth.state())
      assert.is_false(driver.focus, "the login lock ends with the login")
      assert.is_false(driver.frozen)
      assert.are.equal("closed", last_screen(driver).screen)
    end)

    it("shows a failure, and refuses what the page sends that is not text", function()
      local driver = started_client()
      driver.nui("ready", {})
      nonce(driver)
      assert.is_false(driver.nui("login", { username = 5, password = "x" }).ok)
      assert.is_false(driver.nui("select", { id = {} }).ok)
      assert.is_false(driver.nui("http", { id = 99 }).ok)
      assert.is_true(driver.nui("login", { username = "sam", password = "rpf-sealed-x" }).ok)
      local request = nui_messages(driver)[#driver.nui_sent]
      driver.nui("http", {
        id = request.id,
        status = 401,
        body = '{"error":"invalid_credentials","message":"Wrong username or password."}',
      })
      local error = nui_messages(driver)[#driver.nui_sent]
      assert.are.same({ type = "error", message = "Wrong username or password." }, error)
    end)

    it("shows the characters, locks for them, and closes once one is in play", function()
      local driver, record = started_client()
      driver.nui("ready", {})
      rpf.events.emit("auth.succeeded", { player_id = "p", username = "sam", created = false })
      assert.is_false(driver.focus)
      driver.from_server(
        "rpf:characters",
        rpf.handoff.encode("rpf:characters", {
          characters = rpf.json.array({
            rpf.json.object({ id = "c1", first_name = "Ada", last_name = "Ng", gender = "female" }),
          }),
        })
      )
      local screen = last_screen(driver)
      assert.are.equal("characters", screen.screen)
      assert.are.same({ { id = "c1", name = "Ada Ng" } }, screen.characters)
      assert.is_true(driver.focus)

      assert.is_true(driver.nui("create", { first_name = "Bo", last_name = "Li", gender = "male" }).ok)
      assert.are.equal("rpf:character_create", record.to_server[#record.to_server].name)
      assert.is_true(driver.nui("select", { id = "c1" }).ok)
      assert.are.equal("rpf:character_select", record.to_server[#record.to_server].name)

      driver.from_server(
        "rpf:character_result",
        rpf.handoff.encode("rpf:character_result", { during = "select", ok = false, reason = "busy" })
      )
      assert.are.equal("error", nui_messages(driver)[#driver.nui_sent].type)
      driver.from_server(
        "rpf:character_result",
        rpf.handoff.encode("rpf:character_result", { during = "select", ok = true, id = "c1" })
      )
      assert.are.equal("closed", last_screen(driver).screen)
      assert.is_false(driver.focus)
      assert.is_false(driver.frozen)
    end)

    it("shows a list that failed to load, and reloads it when asked", function()
      local driver, record = started_client()
      driver.nui("ready", {})
      rpf.events.emit("auth.succeeded", { player_id = "p", username = "sam", created = false })
      assert.is_false(driver.focus)
      driver.from_server(
        "rpf:character_result",
        rpf.handoff.encode("rpf:character_result", { during = "load", ok = false, reason = "unavailable" })
      )
      local screen = last_screen(driver)
      assert.are.equal("characters", screen.screen)
      assert.are.same({}, screen.characters)
      assert.is_true(driver.focus, "the character screen locks while it is up")
      assert.are.equal("error", nui_messages(driver)[#driver.nui_sent].type)
      assert.is_true(driver.nui("refresh", {}).ok)
      assert.are.equal("rpf:characters_request", record.to_server[#record.to_server].name)
    end)

    it("releases the player when the resource stops mid-login", function()
      local driver = started_client()
      assert.is_true(driver.frozen)
      driver.stop()
      assert.is_false(driver.frozen)
      assert.is_false(driver.focus)
    end)

    it("shows the server's notices", function()
      local driver = started_client()
      driver.from_server("rpf:notify", "You were warned")
      driver.from_server("rpf:notify", { "not text" })
      assert.are.same({ "You were warned" }, driver.feed)
    end)

    it("exports the client's public API", function()
      local driver = started_client()
      local api = driver.exported.api()
      assert.are.equal("function", type(api.auth.login))
      assert.are.equal(rpf.auth.PASSWORD_REUSE_WARNING, api.auth.PASSWORD_REUSE_WARNING)
      assert.is_nil(api.players)
    end)
  end)
end)
