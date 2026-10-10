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

    it("sends a request by name, with its payload, and announces the answer", function()
      assert.is_true(rpf.api.interactions.send("acme_tags.spray", { text = "hi", at = { 1, 2 } }))
      local sent = c.to_servers[#c.to_servers]
      assert.are.equal("rpf:interact", sent.name)
      local request = rpf.json.decode(sent.payload)
      assert.are.equal("acme_tags.spray", request.name)
      assert.are.equal("hi", request.payload.text)
      local heard
      rpf.api.events.on("interactions.result", function(result)
        heard = result
      end)
      c.server_handlers["rpf:interaction_result"](rpf.handoff.encode("rpf:interaction_result", {
        name = "acme_tags.spray",
        ok = false,
        reason = "Write something to spray.",
      }))
      assert.are.same({ name = "acme_tags.spray", ok = false, reason = "Write something to spray." }, heard)
    end)

    it("refuses what it cannot send, sending nothing", function()
      local before = #c.to_servers
      ---@type any
      local wrong = 42
      assert.are.same({ nil, "invalid" }, { rpf.api.interactions.send(wrong) })
      wrong = "text"
      assert.are.same({ nil, "invalid" }, { rpf.api.interactions.send("acme_tags.spray", wrong) })
      assert.are.same({ nil, "invalid" }, { rpf.api.interactions.send("acme_tags.spray", { fn = print }) })
      assert.are.same({ nil, "too_large" }, { rpf.api.interactions.send("acme_tags.spray", { text = string.rep("x", 5000) }) })
      assert.are.equal(before, #c.to_servers)
    end)

    it("reserves its event: a script cannot forge an answer", function()
      assert.are.same({ nil, "reserved" }, { rpf.api.events.emit("interactions.result", {}) })
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
      p.client_handlers["rpf:interact"](7, text)
      assert.is_false(seen)
      local answer = rpf.json.decode(p.to_clients[#p.to_clients].payload)
      assert.are.same({ false, "invalid" }, { answer.ok, answer.reason })
    end)
  end)
end)
