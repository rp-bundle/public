-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Dialogs (`rpf.dialogs`, L1): a conversation walks a tree staff built,
-- each node a menu of the choices whose conditions hold, and every pick is
-- checked again against the tree as it is now before it goes anywhere or
-- runs anything. The facade's reads are stubbed here: the conditions are
-- this module's, the reads the facade's (`facade_spec.lua`, the bridges'
-- conformance). The fake game server takes a conversation through the real
-- portal (`crates/fake-server/tests/scenarios/dialogs.rs`).

local support = require("spec.support")

local PLAYER = "00000002-0000-4000-8000-000000000002"
local ROUTE = "0000000a-0000-4000-8000-00000000000a"

---The delivery addon: an action, and an NPC type that talks.
---@param version string? Its release.
---@return table manifest The manifest.
local function delivery(version)
  return {
    namespace = "acme_delivery",
    version = version or "1.0.0",
    api = 1,
    title = "Delivery",
    types = {
      dispatcher = {
        schema = 1,
        authority = "config",
        fields = {
          spot = { type = "vector3", required = true },
          talks = { type = "ref", to = "dialog", nullable = true },
        },
        world = { kind = "point", position = "spot", dialog = "talks" },
      },
    },
    actions = {
      start_route = {
        title = "Start a route",
        params = {
          route = { type = "string", required = true },
          bonus = { type = "integer", min = 0, max = 100, default = 0 },
        },
      },
    },
  }
end

---The courier's tree: a greeting, an offer behind a job, a route behind a
---permission, a goodbye, and a node with no choices.
---@return table dialog The tree.
local function courier()
  return {
    slug = "courier",
    title = "Dispatcher",
    start = "hello",
    nodes = {
      {
        key = "hello",
        line = "Looking for work?",
        choices = {
          { label = "Yes", does = { kind = "goto", node = "offer" } },
          {
            label = "Staff route",
            conditions = { { kind = "permission", permission = "addon.acme_delivery.dispatch" } },
            does = { kind = "action", action = "acme_delivery.start_route", params = { route = "staff" } },
          },
          { label = "No", does = { kind = "end" } },
        },
      },
      {
        key = "offer",
        line = "Here's a route.",
        choices = {
          {
            label = "Take it",
            conditions = {
              { kind = "job", employer = "post", min_grade = 1 },
              { kind = "item", item = "van_keys", count = 1 },
            },
            does = { kind = "action", action = "acme_delivery.start_route", params = { route = ROUTE, bonus = 5 } },
          },
          { label = "Not hired?", conditions = { { kind = "job", employer = "post", negate = true } }, does = { kind = "goto", node = "bye" } },
        },
      },
      { key = "bye", line = "Come back when you are." },
    },
  }
end

local version = 0

---Applies a config with the addon installed (or not) and the trees.
---@param p spec.FakePlatform The platform.
---@param installed boolean|table? The installed manifest, true for the default, false for none.
---@param trees table[]? The dialogs.
---@param enabled boolean? False to disable it.
local function configure(p, installed, trees, enabled)
  version = version + 1
  local json = rpf.json
  local m = installed == true and delivery() or installed
  local addons = json.array({})
  if m then
    addons = json.array({
      {
        namespace = m.namespace,
        version = m.version,
        hash = "sha256:" .. m.version,
        enabled = enabled ~= false,
        manifest = assert(json.decode(assert(json.encode(assert(rpf.manifest.check(m)))))),
        types = json.object({}),
        records = json.array({}),
      },
    })
  end
  local snapshot = assert(json.decode(assert(json.encode({
    settings = json.object({}),
    addons = addons,
    dialogs = json.array(trees or { courier() }),
  }))))
  assert.is_true((rpf.config.apply(p, version, "h" .. version, snapshot)))
end

describe("rpf.dialogs", function()
  local p
  ---What the facade and the staff grants answer, as the test sets them.
  local job, keys, granted
  ---The action's runs.
  local runs
  ---What the action answers.
  local answer_with

  ---The latest menu the server sent the player, decoded.
  ---@return table spec The menu's spec.
  local function menu()
    local request = p.client_requests[#p.client_requests]
    assert.are.equal("rpf:ui", request.name)
    return assert(rpf.json.decode(request.payload:match("^.-(%{.*)$") or request.payload)).spec
  end

  ---The player picks the `n`th option they were shown.
  ---@param n integer The option.
  local function pick(n)
    local request = p.client_requests[#p.client_requests]
    request.callback(rpf.handoff.encode("rpf:ui_answer", { ok = true, index = n }))
  end

  ---The labels of the latest menu.
  ---@return string[] labels The labels.
  local function labels()
    local out = {}
    for _, option in ipairs(menu().options) do
      out[#out + 1] = option.label
    end
    return out
  end

  ---The notifications the player was sent, by text.
  ---@return string[] texts The texts.
  local function told()
    local out = {}
    for _, sent in ipairs(p.to_clients) do
      if sent.name == "rpf:ui_notify" then
        out[#out + 1] = rpf.json.decode(sent.payload).spec.text
      end
    end
    return out
  end

  before_each(function()
    support.load_core("server")
    p = support.fake_platform()
    rpf.start_server(p, { url = "ws://portal", api_key = "rpf_test_secret" })
    job, keys, granted = nil, 0, {}
    rpf.facade.current_job = function()
      return job
    end
    rpf.facade.count = function()
      return keys
    end
    rpf.staff.can = function(_, permission)
      return granted[permission] == true
    end
    runs, answer_with = {}, { true }
    rpf.addons.register(delivery(), {
      start = function()
        assert(rpf.api.actions.register("acme_delivery.start_route", function(player, params, context)
          runs[#runs + 1] = { player = player.player_id, params = params, context = context }
          return answer_with[1], answer_with[2]
        end))
      end,
    })
    support.connected(p)
    configure(p, true)
    -- After the connection, which starts with no one logged in.
    rpf.players.connected(7)
    rpf.players.authenticating(7)
    assert(rpf.players.register(7, { player_id = PLAYER, username = "sam" }))
  end)

  it("shows a node as a menu of the choices offered, and walks the tree by the pick", function()
    assert.is_true(rpf.api.dialogs.open(7, "courier"))
    local shown = menu()
    assert.are.same({ "Dispatcher", "Looking for work?" }, { shown.title, shown.text })
    assert.are.same({ "Yes", "No" }, labels(), "the staff route's permission is not held")
    assert.is_nil(p.client_requests[#p.client_requests].payload:find("start_route", 1, true), "what a choice does never leaves the server")

    pick(1)
    assert.are.equal("Here's a route.", menu().text)
    assert.are.same({ "Not hired?" }, labels(), "no job: only the negated condition holds")
    pick(1)
    pick(1) -- Goodbye: the conversation is over, so another may open

    job, keys = { name = "courier", employer = "post", grade = 2, on_duty = true }, 1
    rpf.api.dialogs.open(7, "courier")
    pick(1)
    assert.are.same({ "Take it" }, labels())
    pick(1)
    assert.are.equal(1, #runs)
    assert.are.same({ route = ROUTE, bonus = 5 }, runs[1].params)
    assert.are.same({ "courier", "offer", PLAYER }, { runs[1].context.dialog, runs[1].context.node, runs[1].player })
    assert.are.same({}, told(), "it went through: nothing to tell")
  end)

  it("hides a choice whose condition cannot be read, negated or not", function()
    job = { name = "courier", employer = "post", grade = 2 }
    rpf.facade.count = function()
      return nil, "unavailable"
    end
    rpf.api.dialogs.open(7, "courier")
    pick(1)
    assert.are.same({ "Goodbye." }, labels(), "an unread item hides Take it; the job hides Not hired?")
    rpf.facade.current_job = function()
      return nil, "unsupported"
    end
    assert.is_nil(rpf.dialogs.holds(7, { kind = "job", employer = "post", negate = true }))
    assert.is_nil(rpf.dialogs.holds(7, { kind = "sight" }), "a kind this core does not know")
  end)

  it("offers a way out of a node with no choices", function()
    job = nil
    rpf.api.dialogs.open(7, "courier")
    pick(1)
    pick(1)
    assert.are.equal("Come back when you are.", menu().text)
    assert.are.same({ "Goodbye." }, labels())
    pick(1)
    assert.are.equal(0, #runs)
  end)

  it("refuses a pick it never offered: a hidden choice's number is not an option", function()
    rpf.api.dialogs.open(7, "courier")
    local requests = #p.client_requests
    pick(3) -- two options were shown; the third choice, the staff route, was hidden
    assert.are.equal(0, #runs)
    assert.are.equal(requests, #p.client_requests, "the conversation ended")
    pick(2)
    assert.are.equal(0, #runs, "an answer to a request already answered is dropped")
  end)

  it("checks a pick against the tree as it is now: changed, or no longer open to the player", function()
    granted["addon.acme_delivery.dispatch"] = true
    rpf.api.dialogs.open(7, "courier")
    assert.are.same({ "Yes", "Staff route", "No" }, labels())
    local edited = courier()
    edited.nodes[1].choices[2].does.params.route = "night"
    configure(p, true, { edited })
    pick(2)
    assert.are.equal(0, #runs)
    assert.are.same({ rpf.dialogs.MESSAGES.changed }, told())

    rpf.api.dialogs.open(7, "courier")
    granted["addon.acme_delivery.dispatch"] = nil
    pick(2)
    assert.are.equal(0, #runs)
    assert.are.equal(rpf.dialogs.MESSAGES.conditions, told()[2])
  end)

  it("shows a broken choice and refuses it with a message: disabled, gone, bad parameters", function()
    granted["addon.acme_delivery.dispatch"] = true
    configure(p, true, nil, false)
    rpf.api.dialogs.open(7, "courier")
    assert.are.same({ "Yes", "Staff route", "No" }, labels(), "not hidden")
    pick(2)
    assert.are.same({ rpf.dialogs.MESSAGES.unavailable }, told())
    assert.are.equal(1, #p.logged("warn", "courier/hello runs acme_delivery.start_route, which is inactive here"))

    local bad = courier()
    bad.nodes[1].choices[2].does.params = { route = "staff", bonus = 500 }
    configure(p, true, { bad })
    rpf.api.dialogs.open(7, "courier")
    pick(2)
    assert.are.equal(rpf.dialogs.MESSAGES.invalid, told()[2])
    assert.are.equal(0, #runs)
  end)

  it("tells the player an action's refusal in its own words", function()
    granted["addon.acme_delivery.dispatch"] = true
    answer_with = { false, "You already have a route." }
    rpf.api.dialogs.open(7, "courier")
    pick(2)
    assert.are.equal(1, #runs)
    assert.are.same({ "You already have a route." }, told())
  end)

  it("leaves the conversation on screen working when another cannot open", function()
    rpf.api.dialogs.open(7, "courier")
    local requests = #p.client_requests
    assert.are.same({ nil, "busy" }, { rpf.api.dialogs.open(7, "courier") })
    assert.are.equal(requests, #p.client_requests, "nothing new shown")
    pick(1)
    assert.are.equal("Here's a route.", menu().text, "the first goes on")
  end)

  it("refuses a tree it does not have and a player who is not logged in", function()
    assert.are.same({ nil, "not_found" }, { rpf.api.dialogs.open(7, "postman") })
    rpf.players.connected(8)
    assert.are.same({ nil, "not_logged_in" }, { rpf.api.dialogs.open(8, "courier") })
    assert.are.same({ nil, "busy" }, { (function()
      rpf.api.dialogs.open(7, "courier")
      return rpf.api.ui.menu(7, { title = "x", options = { { label = "a" } } }, function() end)
    end)() })
  end)

  it("offers Talk on the addon's NPC type while it runs, under a name no addon may take", function()
    local name = "acme_delivery.rpf_talk1"
    local rules = assert(rpf.interactions.rules_of(name))
    assert.are.same({ "acme_delivery.dispatcher", rpf.dialogs.TALK }, { rules.type, rules.label })
    configure(p, true, nil, false)
    assert.is_nil(rpf.interactions.rules_of(name), "taken down with the activation")
    configure(p, true)
    assert.is_not_nil(rpf.interactions.rules_of(name), "and offered again as it starts again")
    assert.are.same({ nil, "reserved" }, { rpf.api.interactions.register("acme_delivery.rpf_talk2", function()
      return true
    end) })
  end)
end)
