-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Authority per domain (K1): the profile a process fixes at its first
-- `Welcome`, reports in every later `Hello`, and keeps until it restarts,
-- whatever staff save meanwhile.

local support = require("spec.support")

local SERVER = "00000001-0000-4000-8000-000000000001"

---Frames of one type among everything sent.
---@param p spec.FakePlatform The platform.
---@param tag string The type.
---@return rpf.Frame[] frames The frames, in order.
local function sent_of(p, tag)
  local out = {}
  for _, frame in ipairs(p.frames()) do
    if frame.type == tag then
      out[#out + 1] = frame
    end
  end
  return out
end

---The newest `Hello` sent.
---@param p spec.FakePlatform The platform.
---@return rpf.Frame hello The frame.
local function last_hello(p)
  local hellos = sent_of(p, "hello")
  return hellos[#hellos]
end

---Answers the newest `Hello` with a `Welcome` naming `domains`.
---@param p spec.FakePlatform The platform, with an open socket.
---@param domains rpf.Domains The profile the portal adopted.
local function welcome(p, domains)
  p.deliver(support.portal_frame("welcome", {
    re = last_hello(p).id,
    protocol = rpf.protocol.VERSION,
    server_id = SERVER,
    domains = domains,
  }))
  support.declared(p)
end

---Drops the socket, waits out the backoff, and opens a new one.
---@param p spec.FakePlatform The platform.
local function reopen(p)
  p.drop()
  p.advance(2 * 60 * 1000)
  p.open()
end

describe("rpf.domains", function()
  before_each(function()
    support.load_core()
  end)

  it("tells the profiles apart", function()
    assert.are.equal("native", rpf.domains.kind(support.NATIVE))
    assert.are.equal("companion", rpf.domains.kind(support.COMPANION))
    assert.are.equal(
      "mixed",
      rpf.domains.kind({ characters = "rpf", money = "external", inventory = "rpf", jobs = "rpf" })
    )
    assert.is_true(rpf.domains.same(support.NATIVE, { characters = "rpf", money = "rpf", inventory = "rpf", jobs = "rpf" }))
    assert.is_false(rpf.domains.same(support.NATIVE, support.COMPANION))
  end)

  it("has no profile, and no external domain, before the first Welcome", function()
    assert.is_nil(rpf.domains.current())
    for _, name in ipairs(rpf.domains.NAMES) do
      assert.is_nil(rpf.domains.authority(name), name)
      assert.is_false(rpf.domains.is_external(name), name)
    end
  end)

  it("reports none in the first Hello, and fixes the one Welcome names", function()
    local p = support.fake_platform()
    local fixed = {}
    rpf.events.on("domains.fixed", function(profile)
      fixed[#fixed + 1] = profile
    end)
    rpf.start_server(p, { url = "ws://portal", api_key = "rpf_test_secret" })
    p.open()
    assert.is_nil(last_hello(p).domains)
    assert.is_truthy(p.sent[#p.sent]:find('"domains":null', 1, true), "sent as null, not left out")

    welcome(p, support.COMPANION)
    assert.are.same(support.COMPANION, rpf.domains.current())
    assert.are.same({ support.COMPANION }, fixed)
    for _, name in ipairs(rpf.domains.NAMES) do
      assert.is_true(rpf.domains.is_external(name), name)
    end

    -- A copy: changing what `current` gave changes nothing here.
    local copy = assert(rpf.domains.current())
    copy.money = "rpf"
    assert.is_true(rpf.domains.is_external("money"))
  end)

  it("keeps its profile for the life of the process, whatever staff save meanwhile", function()
    local p = support.fake_platform()
    rpf.start_server(p, { url = "ws://portal", api_key = "rpf_test_secret" })
    p.open()
    welcome(p, support.NATIVE)

    -- Staff save companion; the snapshot says so, and the core keeps native.
    local snapshot = assert(rpf.json.decode([[{ "settings": { "domains": {
      "characters": "external", "money": "external", "inventory": "external", "jobs": "external" } } }]]))
    assert.is_true((rpf.config.apply(p, 2, "h2", snapshot)))
    assert.are.same(support.NATIVE, rpf.domains.current())

    reopen(p)
    assert.are.same(support.NATIVE, last_hello(p).domains)
    welcome(p, support.NATIVE)
    assert.are.equal("ready", rpf.connection.state)
  end)

  it("stops for good when a later Welcome names another profile", function()
    local p = support.fake_platform()
    local connection = rpf.start_server(p, { url = "ws://portal", api_key = "rpf_test_secret" })
    p.open()
    welcome(p, support.NATIVE)

    reopen(p)
    welcome(p, support.COMPANION)
    assert.are.equal("stopped", connection.state)
    assert.are.equal(1, #p.logged("error", "runs the native profile until it restarts"))
    assert.are.same(support.NATIVE, rpf.domains.current())
  end)

  it("starts with none again after a restart, so the saved profile takes effect", function()
    local store = {}
    local p = support.fake_platform({ store = store })
    rpf.start_server(p, { url = "ws://portal", api_key = "rpf_test_secret" })
    p.open()
    welcome(p, support.NATIVE)

    support.load_core()
    local restarted = support.fake_platform({ store = store, seed = 4242 })
    rpf.start_server(restarted, { url = "ws://portal", api_key = "rpf_test_secret" })
    restarted.open()
    assert.is_nil(last_hello(restarted).domains)
    welcome(restarted, support.COMPANION)
    assert.are.same(support.COMPANION, rpf.domains.current())
  end)

  it("refuses a Welcome with no profile, or a domain that is neither rpf nor external", function()
    local frame = support.portal_frame("welcome", {
      re = "00000006-0000-4000-8000-000000000006",
      protocol = rpf.protocol.VERSION,
      server_id = SERVER,
      domains = { characters = "rpf", money = "rpf", inventory = "rpf", jobs = "mirror" },
    })
    local text = assert(rpf.json.encode(frame))
    assert.is_nil(rpf.protocol.decode(rpf.protocol.PORTAL_TO_SERVER, text))
    frame.domains = nil
    assert.is_nil(rpf.protocol.decode(rpf.protocol.PORTAL_TO_SERVER, assert(rpf.json.encode(frame))))
  end)
end)
