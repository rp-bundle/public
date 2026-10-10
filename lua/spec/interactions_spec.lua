-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Interactions (`rpf.interactions`, J3): an addon registers a handler under
-- its own namespace on the server; a player's client sends a request by
-- name and hears the answer. The conformance suite drives the server half
-- on every engine (`conformance_acme_tags_spec.lua`); these hold the
-- client's half and the registration's refusals.

local support = require("spec.support")

describe("rpf.interactions", function()
  describe("on the client", function()
    local c

    before_each(function()
      support.load_core("client")
      c = support.fake_client_platform()
      rpf.start_client(c)
    end)

    ---Answers the latest request the client sent.
    ---@param fields table The answer's fields.
    local function answer(fields)
      local asked = c.asked[#c.asked]
      asked.callback(rpf.handoff.encode("rpf:interaction_result", fields))
    end

    it("sends a request by name, with its payload, and announces the answer", function()
      assert.is_true(rpf.api.interactions.send("acme_tags.spray", { text = "hi", at = { 1, 2 }, none = {} }))
      local sent = c.asked[#c.asked]
      assert.are.equal("rpf:interact", sent.name)
      local request = rpf.json.decode(sent.payload)
      assert.are.equal("acme_tags.spray", request.name)
      assert.are.equal("hi", request.payload.text)
      assert.are.same({ 1, 2 }, { request.payload.at[1], request.payload.at[2] })
      local heard
      rpf.api.events.on("interactions.result", function(result)
        heard = result
      end)
      answer({ ok = false, reason = "Write something to spray." })
      assert.are.same({ name = "acme_tags.spray", ok = false, reason = "Write something to spray." }, heard)
    end)

    it("hands a request's answer and data to its callback, once", function()
      local calls = {}
      assert.is_true(rpf.api.interactions.request("acme_tags.mine", nil, function(ok, result)
        calls[#calls + 1] = { ok, result }
      end))
      assert.are.same({ name = "acme_tags.mine" }, rpf.json.decode(c.asked[1].payload))
      local data = rpf.json.object({ tags = rpf.json.array({ rpf.json.object({ id = "a", text = "hi" }) }) })
      answer({ ok = true, data = data })
      answer({ ok = true })
      c.advance(rpf.interactions.TIMEOUT_MS)
      assert.are.same({ { true, { tags = { { id = "a", text = "hi" } } } } }, calls)
      assert.is_nil(getmetatable(calls[1][2]), "a plain copy, without the codec's marks")
    end)

    it("says timeout when no answer comes, and drops one that comes later", function()
      local calls = {}
      assert.is_true(rpf.api.interactions.request("acme_tags.mine", {}, function(ok, result)
        calls[#calls + 1] = { ok, result }
      end))
      c.advance(rpf.interactions.TIMEOUT_MS - 1)
      assert.are.same({}, calls)
      c.advance(1)
      assert.are.same({ { false, "timeout" } }, calls)
      answer({ ok = true })
      assert.are.same({ { false, "timeout" } }, calls)
    end)

    it("says failed for an answer it cannot read, and logs why", function()
      local calls = {}
      rpf.api.interactions.request("acme_tags.mine", {}, function(ok, result)
        calls[#calls + 1] = { ok, result }
      end)
      c.asked[1].callback("not json")
      rpf.api.interactions.request("acme_tags.mine", {}, function(ok, result)
        calls[#calls + 1] = { ok, result }
      end)
      c.asked[2].callback(nil)
      assert.are.same({ { false, "failed" }, { false, "failed" } }, calls)
      local warned = 0
      for _, line in ipairs(c.logs) do
        if line.level == "warn" and line.message:find("acme_tags.mine", 1, true) then
          warned = warned + 1
        end
      end
      assert.are.equal(2, warned)
    end)

    it("logs a callback that throws, and stays usable", function()
      rpf.api.interactions.request("acme_tags.mine", {}, function()
        error("boom")
      end)
      answer({ ok = true })
      assert.are.equal("error", c.logs[#c.logs].level)
      assert.truthy(c.logs[#c.logs].message:find("boom", 1, true))
      assert.is_true(rpf.api.interactions.send("acme_tags.spray", {}))
    end)

    it("refuses more than its waiting requests, until one is answered", function()
      for _ = 1, rpf.interactions.MAX_WAITING do
        assert.is_true(rpf.api.interactions.send("acme_tags.spray", {}))
      end
      assert.are.same({ nil, "too_many" }, { rpf.api.interactions.send("acme_tags.spray", {}) })
      answer({ ok = true })
      assert.is_true(rpf.api.interactions.send("acme_tags.spray", {}))
    end)

    it("refuses what it cannot send, sending nothing, and never throws", function()
      local before = #c.asked
      ---@type any
      local wrong = 42
      assert.are.same({ nil, "invalid" }, { rpf.api.interactions.send(wrong) })
      wrong = "text"
      assert.are.same({ nil, "invalid" }, { rpf.api.interactions.send("acme_tags.spray", wrong) })
      assert.are.same({ nil, "invalid" }, { rpf.api.interactions.send("acme_tags.spray", { fn = print }) })
      assert.are.same({ nil, "invalid" }, { rpf.api.interactions.send("spray", {}) }, "not a namespaced name")
      assert.are.same({ nil, "invalid" }, { rpf.api.interactions.send("", {}) })
      assert.are.same({ nil, "invalid" }, { rpf.api.interactions.send("acme_tags.spray", { 1, 2 }) }, "a list is not an object")
      assert.are.same({ nil, "invalid" }, { rpf.api.interactions.send("acme_tags.spray", { [1] = 1, x = 2 }) }, "mixed keys")
      assert.are.same({ nil, "too_large" }, { rpf.api.interactions.send("acme_tags.spray", { text = string.rep("x", 5000) }) })
      ---@type any
      local not_a_callback = 42
      assert.are.same({ nil, "invalid" }, { rpf.api.interactions.request("acme_tags.spray", {}, not_a_callback) }, "no callback")
      local hostile = setmetatable({}, {
        __pairs = function()
          error("a __pairs that throws")
        end,
      })
      assert.are.same({ nil, "invalid" }, { rpf.api.interactions.send("acme_tags.spray", { inner = hostile, [hostile] = 1 }) })
      local sparse = setmetatable({ [2] = "x" }, {
        __index = function()
          error("an __index that throws")
        end,
      })
      local sent, nothing, sent_why = pcall(rpf.api.interactions.send, "acme_tags.spray", { list = sparse })
      assert.is_true(sent, "no throw through the API for a sparse list either")
      assert.are.same({ nil, "invalid" }, { nothing, sent_why })
      local ok, refused, why = pcall(rpf.api.interactions.send, "acme_tags.spray", hostile)
      assert.is_true(ok, "no throw through the API")
      assert.is_true(refused or why == "invalid")
      assert.are.equal(before + (refused and 1 or 0), #c.asked)
    end)

    it("reserves its event: a script cannot forge an answer", function()
      assert.are.same({ nil, "reserved" }, { rpf.api.events.emit("interactions.result", {}) })
    end)

    it("reserves its event area as a namespace no addon may take", function()
      support.load_core("server")
      local refused, why = rpf.manifest.check({ namespace = "interactions", version = "1.0.0", api = 1, title = "x" })
      assert.is_nil(refused)
      assert.are.equal("reserved", assert(why).error)
    end)
  end)

  describe("on the server", function()
    local p

    ---A small addon manifest.
    ---@param namespace string Its namespace.
    ---@return table manifest The manifest.
    local function manifest(namespace)
      return {
        namespace = namespace,
        version = "1.0.0",
        api = 1,
        title = "Addon",
        types = { thing = { schema = 1, authority = "config", fields = { name = { type = "string" } } } },
      }
    end

    before_each(function()
      support.load_core()
      p = support.fake_platform()
      rpf.start_server(p, { url = "ws://portal", api_key = "rpf_test_secret" })
    end)

    it("refuses a name that is not an addon's own, or a handler that is not one", function()
      rpf.addons.register(manifest("acme_tags"))
      local handler = function()
        return true
      end
      assert.is_true(rpf.api.interactions.register("acme_tags.spray", handler))
      assert.are.same({ nil, "invalid" }, { rpf.api.interactions.register("spray", handler) })
      ---@type any
      local not_a_handler = 42
      assert.are.same({ nil, "invalid" }, { rpf.api.interactions.register("acme_tags.spray", not_a_handler) })
      assert.are.same({ nil, "not_found" }, { rpf.api.interactions.register("acme_none.spray", handler) })
      rpf.addons.from("vandal", function()
        assert.are.same({ nil, "forbidden" }, { rpf.api.interactions.register("acme_tags.spray", handler) })
      end)
    end)

    it("refuses a payload nested past its depth before any handler sees it", function()
      rpf.addons.register(manifest("acme_tags"))
      local seen = false
      rpf.api.interactions.register("acme_tags.spray", function()
        seen = true
        return true
      end)
      rpf.players.connected(7)
      rpf.players.authenticating(7)
      rpf.players.register(7, { player_id = "00000002-0000-4000-8000-000000000002", username = "sam" })
      local deep = { v = 1 }
      local at = deep
      for _ = 1, 12 do
        at.next = { v = 1 }
        at = at.next
      end
      local text = assert(rpf.json.encode(rpf.json.object({ name = "acme_tags.spray", payload = deep })))
      local answer = rpf.json.decode(assert(p.request_from(7, "rpf:interact", text)))
      assert.is_false(seen)
      assert.are.same({ false, "invalid" }, { answer.ok, answer.reason })
    end)

    it("forgets the ownership of a handler it replaces", function()
      rpf.addons.register(manifest("acme_tags"))
      local live = 0
      rpf.addons.own = function()
        live = live + 1
        return function()
          live = live - 1
        end
      end
      for _ = 1, 3 do
        assert.is_true(rpf.api.interactions.register("acme_tags.spray", function()
          return true
        end))
      end
      assert.are.equal(1, live, "one handler, owned once")
    end)

    it("answers a request from a player who has not logged in, running nothing", function()
      rpf.addons.register(manifest("acme_tags"))
      local seen = false
      rpf.api.interactions.register("acme_tags.spray", function()
        seen = true
        return true
      end)
      rpf.players.connected(8)
      local text = assert(rpf.json.encode(rpf.json.object({ name = "acme_tags.spray" })))
      local answer = rpf.json.decode(assert(p.request_from(8, "rpf:interact", text)))
      assert.are.same({ false, "not_logged_in" }, { answer.ok, answer.reason })
      assert.is_false(seen)
    end)
  end)

  describe("answering with data", function()
    local p

    before_each(function()
      support.load_core()
      p = support.fake_platform()
      rpf.start_server(p, { url = "ws://portal", api_key = "rpf_test_secret" })
      rpf.players.connected(7)
      rpf.players.authenticating(7)
      rpf.players.register(7, { player_id = "00000002-0000-4000-8000-000000000002", username = "sam" })
    end)

    ---What the client hears when an interaction's handler answers.
    ---@param ok boolean The handler's first result.
    ---@param extra any Its second.
    ---@return table answer The decoded answer.
    local function answering(ok, extra)
      local interactions = rpf.interactions
      -- The handler runs as the core runs any: the dispatch is what is under
      -- test, not the addon lifecycle, which the other specs hold.
      local saved = rpf.addons.running
      rpf.addons.running = function()
        return true
      end
      rpf.addons.state = function()
        return "active"
      end
      rpf.addons.may_use = function()
        return true
      end
      assert.is_true(interactions.register("acme_tags.read", function()
        return ok, extra
      end))
      local text = assert(rpf.json.encode(rpf.json.object({ name = "acme_tags.read" })))
      local reply = assert(p.request_from(7, "rpf:interact", text))
      rpf.addons.running = saved
      return assert(rpf.handoff.decode("rpf:interaction_result", reply))
    end

    it("carries plain data, nested and empty tables included", function()
      local answer = answering(true, { tags = { { id = "a" } }, none = {}, n = 1.5, yes = false })
      assert.is_true(answer.ok)
      assert.are.equal("a", answer.data.tags[1].id)
      assert.are.equal(1.5, answer.data.n)
      assert.is_false(answer.data.yes)
    end)

    it("answers failed for data that is not plain, and logs it for the addon", function()
      local sparse = setmetatable({ [2] = "x" }, {
        __index = function()
          error("an __index that throws")
        end,
      })
      for _, extra in ipairs({ { fn = print }, { [1] = 1, x = 2 }, "text", { list = sparse } }) do
        local answer = answering(true, extra)
        assert.are.same({ false, "failed" }, { answer.ok, answer.reason })
      end
      assert.are.equal(4, #p.logged("error", "acme_tags.read answered data that is not"))
    end)

    it("answers too_large for data past the limit", function()
      local answer = answering(true, { text = string.rep("x", rpf.interactions.MAX_ANSWER) })
      assert.are.same({ false, "too_large" }, { answer.ok, answer.reason })
    end)

    it("never sends data with a refusal", function()
      local answer = answering(false, { secret = true })
      assert.are.same({ false }, { answer.ok, answer.reason, answer.data })
    end)
  end)
end)
