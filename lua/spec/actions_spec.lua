-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Actions (`rpf.actions`, L1): an addon declares what a dialog choice can
-- make it do in its manifest, registers the handler while it runs, and the
-- core runs it with the choice's parameters, checked against the
-- declaration first. The manifest rules themselves are held to the shared
-- corpus (`manifest_spec.lua`).

local support = require("spec.support")

---The delivery addon's manifest: one action with parameters, one without.
---@param version string? Its release.
---@param params table? `start_route`'s parameters.
---@return table manifest The manifest.
local function manifest(version, params)
  return {
    namespace = "acme_delivery",
    version = version or "1.0.0",
    api = 1,
    title = "Delivery",
    types = {
      route = { schema = 1, authority = "config", fields = { label = { type = "string", required = true } } },
    },
    actions = {
      start_route = {
        title = "Start a delivery route",
        params = params or {
          route = { type = "ref", to = "acme_delivery.route", required = true },
          bonus = { type = "integer", min = 0, max = 1000, default = 0 },
        },
      },
      wave = { title = "Wave" },
    },
  }
end

local version = 0

---Applies a config with the manifest installed.
---@param p spec.FakePlatform The platform.
---@param m table? The installed manifest, or nil for none.
---@param enabled boolean? False to disable it.
local function install(p, m, enabled)
  version = version + 1
  local json = rpf.json
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
  local snapshot = assert(json.decode(assert(json.encode({ settings = json.object({}), addons = addons }))))
  assert.is_true((rpf.config.apply(p, version, "h" .. version, snapshot)))
end

local ROUTE = "0000000a-0000-4000-8000-00000000000a"
local PLAYER = { handle = 1, player_id = "00000001-0000-4000-8000-000000000001", name = "Sam" }

describe("rpf.actions", function()
  local p
  ---What the handler was called with, in order.
  local calls

  ---Registers the addon, whose `start` registers `start_route`'s handler.
  ---@param handler function? The handler; one that records its call and answers `true` unless given.
  ---@param m table? The manifest it registers.
  local function register(handler, m)
    rpf.addons.register(m or manifest(), {
      start = function()
        assert(rpf.api.actions.register(
          "acme_delivery.start_route",
          handler or function(player, params, context)
            calls[#calls + 1] = { player = player, params = params, context = context, namespace = rpf.addons.context().namespace }
            return true
          end
        ))
      end,
    })
  end

  before_each(function()
    support.load_core()
    p = support.fake_platform()
    rpf.start_server(p, { url = "ws://portal", api_key = "rpf_test_secret" })
    calls = {}
  end)

  it("runs a handler with its parameters checked, defaults filled in, in its addon's context", function()
    register()
    support.connected(p)
    install(p, manifest())
    assert.are.same({ true }, { rpf.actions.available("acme_delivery.start_route") })
    local ok = rpf.actions.run(PLAYER, "acme_delivery.start_route", { route = ROUTE }, { dialog = "courier", node = "offer" })
    assert.is_true(ok)
    assert.are.equal(1, #calls)
    assert.are.same({ route = ROUTE, bonus = 0 }, calls[1].params)
    assert.is_nil(getmetatable(calls[1].params), "a plain copy, without the codec's marks")
    assert.are.same({ dialog = "courier", node = "offer" }, calls[1].context)
    assert.are.equal("Sam", calls[1].player.name)
    assert.are.equal("acme_delivery", calls[1].namespace)
  end)

  it("refuses parameters the declaration no longer takes, before the handler sees them", function()
    register()
    support.connected(p)
    install(p, manifest())
    assert.are.same(
      { false, "invalid", { error = "required", field = "route" } },
      { rpf.actions.run(PLAYER, "acme_delivery.start_route", { bonus = 5 }) }
    )
    assert.are.same(
      { false, "invalid", { error = "above_max", field = "bonus" } },
      { rpf.actions.run(PLAYER, "acme_delivery.start_route", { route = ROUTE, bonus = 5000 }) }
    )
    assert.are.same(
      { false, "invalid", { error = "unknown_field", field = "tip" } },
      { rpf.actions.run(PLAYER, "acme_delivery.start_route", { route = ROUTE, tip = 1 }) }
    )
    assert.are.equal(0, #calls)
  end)

  it("passes on a handler's refusal with its message, and turns a throw or a non-answer into failed", function()
    local answers = {
      function()
        return false, "You already have a route."
      end,
      function()
        return false, string.rep("é", 200)
      end,
      function()
        error("boom")
      end,
      function()
        return "yes"
      end,
    }
    local which = 1
    register(function(...)
      return answers[which](...)
    end)
    support.connected(p)
    install(p, manifest())
    assert.are.same({ false, "refused", "You already have a route." }, { rpf.actions.run(PLAYER, "acme_delivery.start_route", { route = ROUTE }) })
    which = 2
    local _, why, message = rpf.actions.run(PLAYER, "acme_delivery.start_route", { route = ROUTE })
    assert.are.equal("refused", why)
    assert.are.equal(rpf.actions.MAX_MESSAGE, #message, "cut to the most, on a character's boundary")
    assert.truthy(rpf.json.is_utf8(message))
    which = 3
    assert.are.same({ false, "failed" }, { rpf.actions.run(PLAYER, "acme_delivery.start_route", { route = ROUTE }) })
    assert.truthy(p.logs[#p.logs].message:find("boom", 1, true))
    which = 4
    assert.are.same({ false, "failed" }, { rpf.actions.run(PLAYER, "acme_delivery.start_route", { route = ROUTE }) })
  end)

  it("says why an action is not available: undeclared, not running, or never registered", function()
    assert.are.same({ false, "not_declared" }, { rpf.actions.available("acme_delivery.start_route") }, "nothing loaded")
    register()
    assert.are.same({ false, "inactive" }, { rpf.actions.available("acme_delivery.start_route") }, "loaded, not installed")
    support.connected(p)
    install(p, manifest())
    assert.is_true((rpf.actions.available("acme_delivery.start_route")))
    assert.are.same({ false, "not_registered" }, { rpf.actions.available("acme_delivery.wave") }, "declared, no handler")
    assert.are.same({ false, "not_declared" }, { rpf.actions.available("acme_delivery.fly") })
    assert.are.same({ false, "not_declared" }, { rpf.actions.available("not a name") })
    assert.are.same({ false, "not_registered" }, { rpf.actions.run(PLAYER, "acme_delivery.wave", {}) })

    install(p, manifest(), false)
    assert.are.same({ false, "inactive" }, { rpf.actions.run(PLAYER, "acme_delivery.start_route", { route = ROUTE }) }, "disabled")
    install(p, manifest())
    assert.is_true((rpf.actions.available("acme_delivery.start_route")), "registered again as it starts again")
    install(p, nil)
    assert.are.same({ false, "inactive" }, { rpf.actions.available("acme_delivery.start_route") }, "uninstalled")
    assert.are.equal(0, #calls)
  end)

  it("takes a handler down when its addon stops, and forgets it with the addon's code", function()
    register()
    support.connected(p)
    install(p, manifest())
    install(p, manifest(), false)
    install(p, manifest("1.0.0"))
    assert.is_true((rpf.actions.available("acme_delivery.start_route")))
    -- A release that no longer declares it: the old code stops, the new
    -- registration cannot register what it does not declare.
    local refused
    rpf.addons.register(manifest("1.1.0", {}), {
      start = function()
        refused = { rpf.api.actions.register("acme_delivery.fly", function() end) }
      end,
    })
    install(p, manifest("1.1.0", {}))
    assert.are.same({ nil, "not_declared" }, refused)
    assert.are.same({ false, "not_registered" }, { rpf.actions.available("acme_delivery.start_route") })
  end)

  it("refuses a registration that is not an addon's own, declared action", function()
    rpf.addons.register(manifest())
    local handler = function()
      return true
    end
    ---@type any
    local wrong = 42
    assert.are.same({ nil, "invalid" }, { rpf.api.actions.register("start_route", handler) })
    assert.are.same({ nil, "invalid" }, { rpf.api.actions.register(wrong, handler) })
    assert.are.same({ nil, "invalid" }, { rpf.api.actions.register("acme_delivery.start_route", wrong) })
    assert.are.same({ nil, "not_found" }, { rpf.api.actions.register("acme_none.start_route", handler) })
    assert.are.same({ nil, "not_declared" }, { rpf.api.actions.register("acme_delivery.fly", handler) })
    rpf.addons.from("vandal", function()
      assert.are.same({ nil, "forbidden" }, { rpf.api.actions.register("acme_delivery.start_route", handler) })
    end)
    assert.is_true(rpf.api.actions.register("acme_delivery.start_route", handler))
  end)
end)
