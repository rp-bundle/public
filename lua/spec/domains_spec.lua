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

  it("reads a Welcome with no profile as native, and refuses a domain that is neither", function()
    local frame = support.portal_frame("welcome", {
      re = "00000006-0000-4000-8000-000000000006",
      protocol = rpf.protocol.VERSION,
      server_id = SERVER,
      domains = { characters = "rpf", money = "rpf", inventory = "rpf", jobs = "mirror" },
    })
    local text = assert(rpf.json.encode(frame))
    assert.is_nil(rpf.protocol.decode(rpf.protocol.PORTAL_TO_SERVER, text))
    frame.domains = nil
    local decoded = assert(rpf.protocol.decode(rpf.protocol.PORTAL_TO_SERVER, assert(rpf.json.encode(frame))))
    assert.is_nil(decoded.domains)

    local p = support.fake_platform()
    rpf.start_server(p, { url = "ws://portal", api_key = "rpf_test_secret" })
    p.open()
    p.deliver(support.portal_frame("welcome", {
      re = last_hello(p).id,
      protocol = rpf.protocol.VERSION,
      server_id = SERVER,
      domains = rpf.json.null,
    }))
    assert.are.same(support.NATIVE, rpf.domains.current())
  end)
end)

-- K1 part 3: RPF's own modules refuse a domain the framework owns, and a
-- companion server lets nobody past `registered` without its bridge.
describe("rpf.domains on a companion server", function()
  local PLAYER = "00000002-0000-4000-8000-000000000002"
  local ID = "00000009-0000-4000-8000-000000000009"
  local p

  ---Starts the core on `profile`, connected.
  ---@param profile rpf.Domains The profile the portal adopts.
  local function start(profile)
    support.load_core()
    p = support.fake_platform()
    rpf.start_server(p, { url = "ws://portal", api_key = "rpf_test_secret" })
    p.open()
    welcome(p, profile)
  end

  ---A player at `registered`, with an account of their own.
  ---@param handle integer The engine's handle.
  local function registered(handle)
    assert(rpf.players.connected(handle))
    assert(rpf.players.authenticating(handle))
    local player_id = string.format("00000002-0000-4000-8000-%012d", handle)
    assert(rpf.players.register(handle, { player_id = player_id, username = "sam" .. handle }))
  end

  it("refuses every one of RPF's own domain operations with domain_external", function()
    start(support.COMPANION)
    local calls = {
      characters = {
        selected = function() return rpf.characters.selected(PLAYER) end,
        deselect = function() return rpf.characters.deselect(7) end,
        select = function() return rpf.characters.select(7, ID, function() end) end,
        create = function()
          return rpf.characters.create(7, { first_name = "J", last_name = "D", gender = "female" }, function() end)
        end,
        remove = function() return rpf.characters.remove(ID) end,
        set_character = function() return rpf.records.set_character(ID, { first_name = "J" }) end,
      },
      money = {
        balance = function() return rpf.accounts.balance(ID) end,
        get = function() return rpf.accounts.get(ID) end,
        transfer = function() return rpf.accounts.transfer(ID, PLAYER, 1, "x") end,
        pay = function() return rpf.accounts.pay(ID, PLAYER, 1, "x") end,
        records_transfer = function() return rpf.records.transfer(ID, PLAYER, 1, "x") end,
        adjust = function() return rpf.records.adjust(ID, PLAYER, 1, ID, "x") end,
      },
      inventory = {
        add = function() return rpf.inventory.add(ID, "water", 1) end,
        remove = function() return rpf.inventory.remove(ID, "water", 1) end,
        plan_remove = function() return rpf.inventory.plan_remove(ID, "water", 1) end,
        move = function() return rpf.inventory.move(ID, 1, ID) end,
        split = function() return rpf.inventory.split(ID, 1, 1) end,
        apply_edit = function() return rpf.inventory.apply_edit(ID, { op = "take", index = 1, count = 1 }) end,
        count = function() return rpf.inventory.count(ID, "water") end,
        set_contents = function() return rpf.records.set_contents(ID, rpf.json.object({})) end,
      },
      jobs = {
        job_of = function()
          local ref, def, err = rpf.jobs.job_of(ID)
          return ref or def, err
        end,
        on_duty = function() return rpf.jobs.on_duty(ID) end,
        set_job = function() return rpf.jobs.set_job(ID, "lspd", "officer") end,
        rank_of = function() return rpf.jobs.rank_of(ID) end,
        set_job_record = function() return rpf.records.set_job(ID, { employer = "lspd", job = "officer" }) end,
      },
    }
    for domain, by_name in pairs(calls) do
      for name, call in pairs(by_name) do
        local value, err = call()
        assert.is_falsy(value, domain .. "." .. name)
        assert.are.equal("domain_external", err, domain .. "." .. name)
      end
    end
    -- Lists are empty, and say why; the yes/no questions say no.
    local list, why = rpf.characters.list(PLAYER)
    assert.are.same({}, list)
    assert.are.equal("domain_external", why)
    local owned, owned_why = rpf.accounts.owned_by("player", PLAYER)
    assert.are.same({}, owned)
    assert.are.equal("domain_external", owned_why)
    assert.is_false(rpf.characters.loaded(PLAYER))
    assert.is_false(rpf.jobs.has_rank(ID, "lspd", 0))
    assert.is_false(rpf.jobs.is_on_duty(ID))
    -- An addon record a character would own: that character is the framework's.
    local record, record_err = rpf.records.create_addon_record("acme.pet", { kind = "character", id = ID }, {})
    assert.is_nil(record)
    assert.are.equal("domain_external", record_err)
  end)

  it("refuses staff commands on an external domain's records, in words staff read", function()
    start(support.COMPANION)
    for name, command in pairs({
      adjust_balance = { account_id = ID, base_revision = 1, funds_account = PLAYER, amount = 1, client_id = ID, description = "x" },
      give_item = { container_id = ID, base_revision = 1, item = "water", count = 1 },
      take_item = { container_id = ID, base_revision = 1, index = 0, count = 1 },
      move_item = { container_id = ID, base_revision = 1, index = 0, position = { x = 0, y = 0 }, rotated = false },
      edit_character = { character_id = ID, base_revision = 1, first_name = "J" },
      delete_character = { character_id = ID, base_revision = 1 },
    }) do
      local applied, reason = rpf.edits[name](command)
      assert.is_false(applied, name)
      assert.are.equal(rpf.edits.REASONS.domain_external, reason, name)
    end
  end)

  it("answers the facade unavailable, and supports nothing, without a bridge", function()
    start(support.COMPANION)
    registered(7)
    for domain, calls in pairs(rpf.facade.CALLS) do
      for call in pairs(calls) do
        assert.is_false(rpf.facade.supports(domain, call), domain .. "." .. call)
      end
    end
    local op = rpf.ops.new()
    for name, call in pairs({
      current_character = function() return rpf.facade.current_character(7) end,
      balance = function() return rpf.facade.balance(7, "bank") end,
      debit = function() return rpf.facade.debit(7, "bank", 1, "x", op) end,
      credit = function() return rpf.facade.credit(7, "bank", 1, "x", op) end,
      count = function() return rpf.facade.count(7, "water") end,
      give = function() return rpf.facade.give(7, "water", 1, op) end,
      take = function() return rpf.facade.take(7, "water", 1, op) end,
      current_job = function() return rpf.facade.current_job(7) end,
    }) do
      local value, status = call()
      assert.is_nil(value, name)
      assert.are.equal("unavailable", status, name)
    end
    assert.are.same({}, rpf.facade.accounts())
  end)

  it("keeps players at registered without a bridge, and says why once", function()
    start(support.COMPANION)
    registered(7)
    registered(8)
    local moved, why = rpf.players.advance(7, "character_select")
    assert.is_false(moved)
    assert.are.equal("no_bridge", why)
    assert.is_false((rpf.players.advance(8, "character_select")))
    assert.are.equal("registered", rpf.players.get(7).state)
    assert.are.equal(1, #p.logged("error", "no bridge to that framework is registered"))
  end)

  it("lets players on once a bridge provides exactly the external domains", function()
    start(support.COMPANION)
    registered(7)
    assert.is_true((rpf.domains.accept_bridge("qbox", { "characters", "money", "inventory", "jobs" })))
    assert.are.equal("qbox", rpf.domains.bridge())
    assert.is_true((rpf.players.advance(7, "character_select")))
    assert.is_false((rpf.domains.accept_bridge("esx", { "money" })), "at most one")
  end)

  it("refuses a bridge that provides other domains, naming both", function()
    support.load_core()
    p = support.fake_platform()
    -- Offered when its resource starts, before the portal is reached.
    assert.is_true((rpf.domains.accept_bridge("darkrp", { "money", "jobs" })))
    rpf.start_server(p, { url = "ws://portal", api_key = "rpf_test_secret" })
    p.open()
    welcome(p, support.COMPANION)
    registered(7)
    assert.is_nil(rpf.domains.bridge())
    assert.is_false((rpf.players.advance(7, "character_select")))
    assert.are.equal(1, #p.logged("error", "the darkrp bridge provides money, jobs"))
  end)

  it("lets a native server's players on with no bridge", function()
    start(support.NATIVE)
    registered(7)
    assert.is_true((rpf.players.advance(7, "character_select")))
    assert.is_nil(rpf.domains.bridge())
  end)
end)
