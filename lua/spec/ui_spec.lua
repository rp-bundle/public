-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Portable UI (`rpf.ui`, J10): what an addon shows a player, checked before
-- an adapter sees it, and on the server read back against what was offered.
-- The adapters' own builds are held by `fivem_spec.lua` and `gmod_spec.lua`,
-- and the server's half on every engine by `conformance_ui_spec.lua`.

local support = require("spec.support")

---A menu with a value, a disabled option, and one with no value.
---@return table opts The menu.
local function menu()
  return {
    title = "Your tags",
    options = {
      { label = "hello", value = "tag-1", description = "on the wall" },
      { label = "gone", value = "tag-2", disabled = true },
      { label = "Close" },
    },
  }
end

---An input dialog with one field of each kind.
---@return table opts The dialog.
local function dialog()
  return {
    title = "Spray",
    fields = {
      { name = "text", label = "Text", required = true, max = 24 },
      { name = "size", label = "Size", kind = "number", min = 1, max = 3, default = 2 },
      { name = "glow", label = "Glow", kind = "checkbox" },
      { name = "colour", label = "Colour", kind = "select", options = { { label = "Red", value = "red" }, { label = "Blue" } } },
    },
  }
end

describe("rpf.ui", function()
  describe("checking options", function()
    before_each(function()
      support.load_core("client")
    end)

    it("takes a string as a notification's text, with defaults for the rest", function()
      assert.are.same({ text = "Saved.", kind = "info", duration_ms = 5000 }, (rpf.ui.spec("notify", "Saved.")))
    end)

    it("keeps a menu's values to itself, and shows only labels", function()
      local spec, kept = rpf.ui.spec("menu", menu())
      assert.are.same({
        title = "Your tags",
        options = {
          { label = "hello", description = "on the wall" },
          { label = "gone", disabled = true },
          { label = "Close" },
        },
      }, spec)
      assert.are.same({ "tag-1", "tag-2", 3 }, kept.values)
    end)

    it("shows a select's labels and its default by number", function()
      local spec = assert(rpf.ui.spec("input", {
        title = "x",
        fields = { { name = "c", label = "C", kind = "select", default = "blue", options = { { label = "Red", value = "red" }, { label = "Blue", value = "blue" } } } },
      }))
      assert.are.same({ "Red", "Blue" }, spec.fields[1].options)
      assert.are.equal(2, spec.fields[1].default)
    end)

    it("refuses what it cannot show, never throwing", function()
      local hostile = setmetatable({}, {
        __index = function()
          error("an __index that throws")
        end,
      })
      local cases = {
        { "notify", {} },
        { "notify", { text = "x", kind = "loud" } },
        { "notify", { text = "x", duration_ms = 10 } },
        { "notify", { text = string.rep("x", 300) } },
        { "notify", { text = "\255" } },
        { "menu", { title = "x", options = {} } },
        { "menu", { title = "x", options = { { label = "" } } } },
        { "menu", { options = { { label = "a" } } } },
        { "input", { title = "x", fields = { { name = "a b", label = "A" } } } },
        { "input", { title = "x", fields = { { name = "a", label = "A" }, { name = "a", label = "B" } } } },
        { "input", { title = "x", fields = { { name = "a", label = "A", kind = "colour" } } } },
        { "input", { title = "x", fields = { { name = "a", label = "A", max = 9999 } } } },
        { "input", { title = "x", fields = { { name = "a", label = "A", kind = "number", min = 3, max = 1 } } } },
        { "input", { title = "x", fields = { { name = "a", label = "A", kind = "select", options = { { label = "x" } }, default = "y" } } } },
        { "progress", { label = "x", duration_ms = 1 } },
        { "progress", { label = "x" } },
        { "progress", hostile },
        { "menu", hostile },
        { "teleport", { title = "x" } },
      }
      for i, case in ipairs(cases) do
        local ok, spec = pcall(rpf.ui.spec, case[1], case[2])
        assert.is_true(ok, "case " .. i .. " threw")
        assert.is_nil(spec, "case " .. i)
      end
    end)
  end)

  describe("reading an answer", function()
    before_each(function()
      support.load_core("client")
    end)

    it("reads a menu's choice as its value, and refuses one it did not offer", function()
      local _, kept = rpf.ui.spec("menu", menu())
      assert.are.same({ "tag-1" }, { rpf.ui.read("menu", kept, 1) })
      assert.are.same({ 3 }, { rpf.ui.read("menu", kept, 3) })
      assert.are.same({ nil, "cancelled" }, { rpf.ui.read("menu", kept, nil) })
      for _, raw in ipairs({ 2, 4, 0, 1.5, "1", {} }) do
        assert.are.same({ nil, "invalid" }, { rpf.ui.read("menu", kept, raw) }, tostring(raw))
      end
    end)

    it("reads a dialog's values by field name, and refuses any out of bounds", function()
      local _, kept = rpf.ui.spec("input", dialog())
      assert.are.same({ text = "hi", size = 3, glow = true, colour = "red" }, (rpf.ui.read("input", kept, { "hi", 3, true, 1 })))
      assert.are.same({ text = "hi", glow = false, colour = 2 }, (rpf.ui.read("input", kept, { "hi", nil, nil, 2 })))
      local bad = {
        { nil, 2, false, 1 },
        { "", 2, false, 1 },
        { string.rep("x", 25), 2, false, 1 },
        { "hi", 4, false, 1 },
        { "hi", "2", false, 1 },
        { "hi", 2, "yes", 1 },
        { "hi", 2, false, 3 },
        { "hi", 2, false, "red" },
        "hi",
      }
      for i, raw in ipairs(bad) do
        assert.are.same({ nil, "invalid" }, { rpf.ui.read("input", kept, raw) }, "case " .. i)
      end
    end)

    it("takes a required checkbox only ticked, as ox_lib does", function()
      local _, kept = rpf.ui.spec("input", { title = "Agree", fields = { { name = "ok", label = "I agree", kind = "checkbox", required = true } } })
      assert.are.same({ ok = true }, (rpf.ui.read("input", kept, { true })))
      assert.are.same({ nil, "invalid" }, { rpf.ui.read("input", kept, { false }) })
      assert.are.same({ nil, "invalid" }, { rpf.ui.read("input", kept, {}) })
    end)

    it("reads a progress bar's true as done, and false as cancelled", function()
      assert.are.same({ true }, { rpf.ui.read("progress", {}, true) })
      assert.are.same({ nil, "cancelled" }, { rpf.ui.read("progress", {}, false) })
      assert.are.same({ nil, "invalid" }, { rpf.ui.read("progress", {}, 1) })
    end)
  end)

  describe("on the client", function()
    local c

    before_each(function()
      support.load_core("client")
      c = support.fake_client_platform()
      rpf.start_client(c)
    end)

    it("shows what the player's own client asks for, and hands back the result once", function()
      assert.is_true(rpf.api.ui.notify("Sprayed."))
      assert.are.same({ kind = "notify", text = "Sprayed." }, { kind = c.shown[1].kind, text = c.shown[1].spec.text })
      local got = {}
      assert.is_true(rpf.api.ui.menu(menu(), function(choice, err)
        got[#got + 1] = { choice, err }
      end))
      c.shown[2].done(1)
      c.shown[2].done(3)
      assert.are.same({ { "tag-1" } }, got)
    end)

    it("says cancelled when the player closes it, and refuses one already open", function()
      local got = {}
      local keep = function(result, err)
        got[#got + 1] = { result, err }
      end
      assert.is_true(rpf.api.ui.input(dialog(), keep))
      assert.are.same({ nil, "busy" }, { rpf.api.ui.input(dialog(), keep) })
      assert.is_true(rpf.api.ui.progress({ label = "Spraying", duration_ms = 2000 }, keep), "another kind may be open")
      c.shown[1].done(nil)
      assert.are.same({ { nil, "cancelled" } }, got)
      assert.is_true(rpf.api.ui.input(dialog(), keep), "free again once answered")
    end)

    it("refuses what the adapter cannot show, and what is not a call", function()
      c.ui.menu = false
      assert.are.same({ nil, "unsupported" }, { rpf.api.ui.menu(menu(), function() end) })
      assert.is_false(rpf.api.capabilities().menu)
      assert.is_true(rpf.api.capabilities().input)
      ---@type any
      local not_a_callback = 42
      assert.are.same({ nil, "invalid" }, { rpf.api.ui.input(dialog(), not_a_callback) })
      ---@type any
      local no_text = {}
      assert.are.same({ nil, "invalid" }, { rpf.api.ui.notify(no_text) })
    end)

    it("logs an adapter that throws, and a callback that throws", function()
      c.ui.notify = function()
        error("no feed")
      end
      assert.are.same({ nil, "failed" }, { rpf.api.ui.notify("x") })
      rpf.api.ui.progress({ label = "x", duration_ms = 1000 }, function()
        error("boom")
      end)
      c.shown[1].done(true)
      local errors = 0
      for _, line in ipairs(c.logs) do
        if line.level == "error" then
          errors = errors + 1
        end
      end
      assert.are.equal(2, errors)
    end)

    it("shows what its server asks, and answers with what the player did, raw", function()
      local handler = assert(c.server_request_handlers["rpf:ui"])
      local replies = {}
      local spec = rpf.ui.spec("menu", menu())
      handler(rpf.handoff.encode("rpf:ui", { kind = "menu", spec = rpf.json.object(rpf.json.copy(spec)) }), function(reply)
        replies[#replies + 1] = rpf.json.decode(reply)
      end)
      assert.are.equal("Your tags", c.shown[1].spec.title)
      c.shown[1].done(1)
      assert.are.same({ true, 1 }, { replies[1].ok, replies[1].index })

      handler(rpf.handoff.encode("rpf:ui", { kind = "teleport", spec = rpf.json.object({}) }), function(reply)
        replies[#replies + 1] = rpf.json.decode(reply)
      end)
      assert.are.same({ false, "invalid" }, { replies[2].ok, replies[2].reason })
      c.ui.progress = false
      handler(rpf.handoff.encode("rpf:ui", { kind = "progress", spec = rpf.json.object({ label = "x", duration_ms = 500 }) }), function(reply)
        replies[#replies + 1] = rpf.json.decode(reply)
      end)
      assert.are.same({ false, "unsupported" }, { replies[3].ok, replies[3].reason })
    end)

    it("shows a dialog its server sends, a select's options and default included", function()
      local spec = assert(rpf.ui.spec("input", dialog()))
      local replies = {}
      c.server_request_handlers["rpf:ui"](rpf.handoff.encode("rpf:ui", { kind = "input", spec = rpf.json.object(rpf.json.copy(spec)) }), function(reply)
        replies[#replies + 1] = rpf.json.decode(reply)
      end)
      assert.are.equal(1, #c.shown, "shown, not refused")
      local colour = c.shown[1].spec.fields[4]
      assert.are.same({ "Red", "Blue" }, colour.options)
      c.shown[1].done({ "hi", 2, false, 2 })
      assert.is_true(replies[1].ok)
      assert.are.same({ "hi", 2, false, 2 }, { replies[1].values[1], replies[1].values[2], replies[1].values[3], replies[1].values[4] })
    end)

    it("takes the largest request a server may send, and gives the largest answer", function()
      local options = {}
      for i = 1, rpf.ui.MAX_OPTIONS do
        options[i] = { label = string.rep("\1", rpf.ui.MAX_LABEL), description = string.rep("\2", rpf.ui.MAX_LABEL) }
      end
      local spec = assert(rpf.ui.spec("menu", { title = "Big", options = options }))
      local request = rpf.handoff.encode("rpf:ui", { kind = "menu", spec = rpf.json.object(rpf.json.copy(spec)) })
      assert.is_true(#request > rpf.handoff.MAX_PAYLOAD, "more than an ordinary message")
      c.server_request_handlers["rpf:ui"](request, function() end)
      assert.are.equal(1, #c.shown)
      local fields = {}
      for i = 1, rpf.ui.MAX_FIELDS do
        fields[i] = { name = "f" .. i, label = "F", max = rpf.ui.TEXT_LIMIT }
      end
      local reply
      c.server_request_handlers["rpf:ui"](rpf.handoff.encode("rpf:ui", { kind = "input", spec = rpf.json.object(rpf.json.copy(assert(rpf.ui.spec("input", { title = "Long", fields = fields })))) }), function(text)
        reply = text
      end)
      local values = {}
      for i = 1, rpf.ui.MAX_FIELDS do
        values[i] = string.rep("\1", rpf.ui.TEXT_LIMIT)
      end
      c.shown[2].done(values)
      assert.truthy(rpf.handoff.decode("rpf:ui_answer", reply), "the server decodes it")
    end)

    it("shows the server's notifications", function()
      c.from_server("rpf:ui_notify", { spec = { text = "Welcome", kind = "success", duration_ms = 3000 } })
      assert.are.same({ text = "Welcome", kind = "success", duration_ms = 3000 }, c.shown[1].spec)
    end)
  end)

  describe("on the server", function()
    local p

    before_each(function()
      support.load_core("server")
      p = support.fake_platform()
      rpf.start_server(p, { url = "ws://portal", api_key = "rpf_test_secret" })
      rpf.players.connected(7)
      rpf.players.authenticating(7)
      assert(rpf.players.register(7, { player_id = "00000002-0000-4000-8000-000000000002", username = "sam" }))
    end)

    ---Answers the latest request the server sent a client.
    ---@param fields table The answer's fields.
    local function answer(fields)
      local request = p.client_requests[#p.client_requests]
      request.callback(rpf.handoff.encode("rpf:ui_answer", fields))
    end

    it("sends a menu without its values, and reads the choice back against them", function()
      local got = {}
      assert.is_true(rpf.api.ui.menu(7, menu(), function(choice, err)
        got[#got + 1] = { choice, err }
      end))
      local request = p.client_requests[1]
      assert.are.same({ 7, "rpf:ui" }, { request.player, request.name })
      assert.is_nil(request.payload:find("tag-1", 1, true), "a value never leaves the server")
      answer({ ok = true, index = 1 })
      assert.are.same({ { "tag-1" } }, got)
    end)

    it("refuses an answer it did not offer, one per kind open, and a player not logged in", function()
      local got = {}
      local keep = function(result, err)
        got[#got + 1] = { result, err }
      end
      assert.is_true(rpf.api.ui.menu(7, menu(), keep))
      assert.are.same({ nil, "busy" }, { rpf.api.ui.menu(7, menu(), keep) })
      answer({ ok = true, index = 2 })
      assert.are.same({ { nil, "invalid" } }, got, "a disabled option")
      rpf.api.ui.input(7, dialog(), keep)
      answer({ ok = true, values = rpf.json.array({ "hi", 9, false, 1 }) })
      assert.are.same({ nil, "invalid" }, got[2], "a number past its max")
      rpf.players.connected(8)
      assert.are.same({ nil, "not_found" }, { rpf.api.ui.menu(8, menu(), keep) })
      assert.are.same({ nil, "not_found" }, { rpf.api.ui.notify(9, "x") })
    end)

    it("passes on the client's refusal, and refuses one it does not know", function()
      local got = {}
      local keep = function(result, err)
        got[#got + 1] = { result, err }
      end
      rpf.api.ui.menu(7, menu(), keep)
      answer({ ok = false, reason = "unsupported" })
      rpf.api.ui.menu(7, menu(), keep)
      answer({ ok = false, reason = "a reason of the client's own" })
      rpf.api.ui.menu(7, menu(), keep)
      p.client_requests[#p.client_requests].callback("not json")
      assert.are.same({ { nil, "unsupported" }, { nil, "invalid" }, { nil, "invalid" } }, got)
    end)

    it("gives up after its timeout, and when the player leaves", function()
      local got = {}
      local keep = function(result, err)
        got[#got + 1] = { result, err }
      end
      rpf.api.ui.menu(7, menu(), keep)
      rpf.api.ui.progress(7, { label = "x", duration_ms = 1000 }, keep)
      p.advance(1000 + rpf.ui.GRACE_MS)
      assert.are.same({ { nil, "timeout" } }, got, "a progress bar waits its length and the grace")
      rpf.players.dropped(7, "quit")
      assert.are.same({ nil, "gone" }, got[2])
      p.advance(rpf.ui.TIMEOUT_MS)
      answer({ ok = true, index = 1 })
      assert.are.equal(2, #got, "nothing after the end")
    end)

    it("ends each request once, even when the next of its kind waits in its place", function()
      local got = {}
      rpf.api.ui.input(7, dialog(), function(_, err)
        got[#got + 1] = "input:" .. tostring(err)
      end)
      rpf.api.ui.menu(7, menu(), function(choice, err)
        got[#got + 1] = "first:" .. tostring(choice) .. ":" .. tostring(err)
      end)
      answer({ ok = true, index = 1 })
      p.advance(1000)
      rpf.api.ui.menu(7, menu(), function(choice, err)
        got[#got + 1] = "second:" .. tostring(choice) .. ":" .. tostring(err)
      end)
      local second = p.client_requests[#p.client_requests]
      -- The first menu's timeout falls due while the second still waits.
      p.advance(rpf.ui.TIMEOUT_MS - 1000)
      second.callback(rpf.handoff.encode("rpf:ui_answer", { ok = true, index = 3 }))
      assert.are.same({ "first:tag-1:nil", "input:timeout", "second:3:nil" }, got)
    end)

    it("refuses options each within bounds but together more than a client takes", function()
      local labels = {}
      for i = 1, rpf.ui.MAX_OPTIONS do
        labels[i] = { label = string.rep("\1", rpf.ui.MAX_LABEL) }
      end
      local fields = {}
      for i = 1, rpf.ui.MAX_FIELDS do
        fields[i] = { name = "f" .. i, label = string.rep("\1", rpf.ui.MAX_LABEL), kind = "select", options = labels }
      end
      assert.are.same({ nil, "too_large" }, { rpf.api.ui.input(7, { title = "Huge", fields = fields }, function() end) })
      assert.are.equal(0, #p.client_requests)
      assert.is_true(rpf.api.ui.menu(7, menu(), function() end), "and it held nothing open")
    end)

    it("hands back an option's own value, whatever its shape", function()
      local value = {}
      value.self = value
      local got
      assert.is_true(rpf.api.ui.menu(7, { title = "x", options = { { label = "loop", value = value } } }, function(choice)
        got = choice
      end))
      answer({ ok = true, index = 1 })
      assert.are.equal(value, got)
    end)

    it("sends a notification as a message of its own", function()
      assert.is_true(rpf.api.ui.notify(7, { text = "Welcome", kind = "success" }))
      local sent = p.messages_to(7, "rpf:ui_notify")[1]
      assert.are.same({ text = "Welcome", kind = "success", duration_ms = 5000 }, rpf.ui.spec("notify", sent.spec))
    end)

    it("reports and refuses UI its engine's clients do not show", function()
      p.capabilities.progress = false
      assert.is_false(rpf.api.capabilities().progress)
      assert.is_true(rpf.api.capabilities().menu)
      assert.is_true(rpf.api.capabilities().position ~= nil, "the world's capabilities beside them")
      assert.are.same({ nil, "unsupported" }, { rpf.api.ui.progress(7, { label = "x", duration_ms = 1000 }, function() end) })
    end)

    it("runs a callback in the context of the addon that asked, logging a throw", function()
      rpf.api.ui.menu(7, menu(), function()
        error("boom")
      end)
      answer({ ok = true, index = 1 })
      assert.are.equal(1, #p.logged("error", "a ui callback failed"))
    end)
  end)

  describe("in the example's client", function()
    local c

    before_each(function()
      support.load_core("client")
      c = support.fake_client_platform()
      rpf.start_client(c)
      rawset(_G, "acme_tags", nil)
      dofile(support.path("lua/examples/acme_tags/client.lua"))
    end)

    after_each(function()
      rawset(_G, "acme_tags", nil)
    end)

    it("shows a player's tags a page at a time, the next behind More", function()
      local told = {}
      local example = rawget(_G, "acme_tags")
      assert.is_true(example.pick_mine(rpf.api, function(line)
        told[#told + 1] = line
      end))
      local tags = rpf.json.array({})
      for i = 1, 40 do
        tags[i] = rpf.json.object({ id = "tag-" .. i, text = "t" .. i })
      end
      c.asked[1].callback(rpf.handoff.encode("rpf:interaction_result", { ok = true, data = rpf.json.object({ tags = tags }) }))
      local first = c.shown[1].spec.options
      assert.are.equal(32, #first)
      assert.are.equal("More", first[32].label)
      c.shown[1].done(32)
      local second = c.shown[2].spec.options
      assert.are.equal(9, #second, "the other nine, with no More")
      c.shown[2].done(9)
      assert.are.same({ name = "acme_tags.scrub", payload = { id = "tag-40" } }, rpf.json.decode(c.asked[2].payload))
      assert.are.same({}, told)
    end)
  end)
end)
