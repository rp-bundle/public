-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- D3's mock platform (`lua/platform/mock/`), which the fake game server in
-- `fake-server/` drives. The harness exercises it end to end; these hold it
-- to the platform interfaces the core checks at start, so a member the core
-- gains cannot be missing from the mock until the harness happens to call it.

local support = require("spec.support")

---Loads the mock module afresh.
---@return rpf.mock mock The module.
local function load_mock()
  return dofile(support.path("lua/platform/mock/init.lua"))
end

---A host that records what the mock hands it, with a clock the test moves.
---@return table host The host.
---@return table record What it recorded.
local function fake_host()
  local record = { time = 1000, kv = {}, sent = {}, connects = {}, closes = {}, requests = {}, to_clients = {}, to_server = {} }
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
    http_request = function(id, method, url)
      record.requests[#record.requests + 1] = { id = id, method = method, url = url }
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
    kick = function() end,
    notify = function() end,
    to_client = function(player, name, payload)
      record.to_clients[#record.to_clients + 1] = { player = player, name = name, payload = payload }
    end,
    to_server = function(name, payload)
      record.to_server[#record.to_server + 1] = { name = name, payload = payload }
    end,
    log = function() end,
  }
  return host, record
end

describe("the mock platform", function()
  before_each(function()
    support.load_core()
  end)

  it("implements the whole server and client interfaces", function()
    local mock = load_mock()
    local host = fake_host()
    assert.are.same({}, rpf.platform.missing(mock.server(host, 1), "server"))
    assert.are.same({}, rpf.platform.missing(mock.client(host, 1), "client"))
    assert.are.equal("mock", mock.server(host, 1).engine)
  end)

  it("runs timers by the host's clock, earliest first, ties in the order scheduled", function()
    local host, record = fake_host()
    local p = load_mock().server(host, 1)
    local ran = {}
    p.after(20, function()
      ran[#ran + 1] = "b"
    end)
    p.after(10, function()
      ran[#ran + 1] = "a"
      p.after(0, function()
        ran[#ran + 1] = "a2"
      end)
    end)
    p.after(20, function()
      ran[#ran + 1] = "c"
    end)
    assert.are.equal(1010, p.next_due())
    p.run_due()
    assert.are.same({}, ran, "nothing is due before the clock moves")
    -- "a2" is scheduled while the clock reads 1020, so it is due then too,
    -- and was scheduled after "b" and "c".
    record.time = 1020
    p.run_due()
    assert.are.same({ "a", "b", "c", "a2" }, ran)
    assert.is_nil(p.next_due())
  end)

  it("repeats its random digits from a seed, and differs between seeds", function()
    local mock = load_mock()
    local host = fake_host()
    local a, b, c = mock.server(host, 1), mock.server(host, 1), mock.server(host, 2)
    local first = a.random_hex(32)
    assert.are.equal(32, #first)
    assert.is_truthy(first:match("^[0-9a-f]+$"))
    assert.are.equal(first, b.random_hex(32))
    assert.are_not.equal(first, c.random_hex(32))
  end)

  it("reports a socket's close once, and sends only on the latest one", function()
    local host, record = fake_host()
    local p = load_mock().server(host, 1)
    local closes = 0
    p.connect("ws://portal/ws", {
      open = function() end,
      message = function() end,
      close = function()
        closes = closes + 1
      end,
    })
    local id = record.connects[1].id
    assert.is_true(p.send("hello"))
    assert.are.equal(id, record.sent[1].id)
    p.socket_close(id, "gone")
    p.socket_close(id, "gone again")
    assert.are.equal(1, closes)
    assert.is_false(p.send("after close"))
  end)

  it("hands a disconnect to the host, and still reports the close once", function()
    local host, record = fake_host()
    local p = load_mock().server(host, 1)
    local closes = 0
    p.connect("ws://portal/ws", {
      open = function() end,
      message = function() end,
      close = function()
        closes = closes + 1
      end,
    })
    local id = record.connects[1].id
    p.disconnect()
    assert.are.same({ id }, record.closes)
    assert.is_false(p.send("after disconnect"))
    assert.are.equal(0, #record.sent)
    p.socket_close(id, "closed by the core")
    assert.are.equal(1, closes)
    p.disconnect()
    assert.are.same({ id }, record.closes, "nothing left to close")
  end)

  it("answers each HTTP request once, by id", function()
    local host, record = fake_host()
    local p = load_mock().client(host, 1)
    local answers = {}
    p.http_request("POST", "http://portal/api/v1/player/login", {}, "{}", function(status, body)
      answers[#answers + 1] = { status = status, body = body }
    end)
    local id = record.requests[1].id
    p.http_done(id, 200, "{}")
    p.http_done(id, 500, "late")
    assert.are.same({ { status = 200, body = "{}" } }, answers)
  end)

  it("hands players' identifiers back as copies", function()
    local host = fake_host()
    local p = load_mock().server(host, 1)
    p.add_player(7, "Sam", { "license:abc" })
    local ids = p.identifiers(7)
    ids[1] = "changed"
    assert.are.same({ "license:abc" }, p.identifiers(7))
    assert.are.equal("Sam", p.name(7))
    p.remove_player(7)
    assert.are.same({}, p.identifiers(7))
  end)
end)
