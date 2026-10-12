-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Conformance (J10): UI an addon shows a player from the server
-- (`rpf.api.ui`), the same cases on the mock platform and on the real FiveM
-- and Gmod adapters (`spec/support/conformance.lua`). The request reaches
-- the player's client over each engine's transport (`lib.callback` on
-- FiveM, numbered `net` messages on Gmod), and the answer is hostile input:
-- only an option the server offered, and only from the player it asked.

local conformance = require("spec.support.conformance")

---What `conformance.run` needs from busted.
local busted = { describe = describe, it = it, before_each = before_each, after_each = after_each }

local PLAYER = "00000002-0000-4000-8000-000000000002"
local OTHER = "00000003-0000-4000-8000-000000000003"

---Logs two players in.
---@param world spec.ConformanceWorld The world.
---@return any handle The first player's engine handle.
local function two_players(world)
  world:connect()
  local handle = world:login(1, PLAYER)
  world:login(2, OTHER)
  return handle
end

---The last UI request the server sent player `n`'s client: its number, and
---what it asked, decoded.
---@param world spec.ConformanceWorld The world.
---@param n integer The player.
---@return string number Its number, as the transport framed it.
---@return table request The request.
local function asked(world, n)
  for i = #world.to_clients, 1, -1 do
    local sent = world.to_clients[i]
    if sent.player == n and sent.name == "rpf:ui" then
      local number, body = sent.payload:match("^(%d+)\n(.*)$")
      return number, assert(world.core.json.decode(body))
    end
  end
  error("player " .. n .. " was asked nothing")
end

---Player `from`'s client answers a request by its number.
---@param world spec.ConformanceWorld The world.
---@param from integer The player whose client answers.
---@param number string The request's number.
---@param fields table The answer's fields.
local function answer(world, from, number, fields)
  local json = world.core.json
  world.from_client(from, "rpf:ui", number .. "\n" .. assert(json.encode(json.object(fields))))
end

conformance.run(busted, "UI from the server", {
  {
    name = "shows a player a menu without its values, and reads their pick as the value",
    run = function(world)
      local handle = two_players(world)
      local got = {}
      assert.is_true(world.api.ui.menu(handle, {
        title = "Your tags",
        options = { { label = "hello", value = "tag-1", item = "spray_can" }, { label = "Close" } },
      }, function(choice, err)
        got[#got + 1] = { choice, err }
      end))
      local number, request = asked(world, 1)
      assert.are.same({ "menu", "Your tags", "hello" }, { request.kind, request.spec.title, request.spec.options[1].label })
      assert.is_nil(request.spec.options[1].value, "a value never leaves the server")
      assert.are.equal("spray_can", request.spec.options[1].item, "an item goes as its slug (P3, #361)")
      assert.is_nil(request.spec.options[1].image, "and never as an image: the client finds that")
      answer(world, 1, number, { ok = true, index = 1 })
      assert.are.same({ { "tag-1" } }, got)
    end,
  },
  {
    name = "sends a menu's text with it: what an NPC says above the choices (L1)",
    run = function(world)
      local handle = two_players(world)
      assert.is_true(world.api.ui.menu(handle, {
        title = "Courier",
        text = "Looking for work?",
        options = { { label = "Yes" }, { label = "No" } },
      }, function() end))
      local _, request = asked(world, 1)
      assert.are.same({ "Courier", "Looking for work?" }, { request.spec.title, request.spec.text })
    end,
  },
  {
    name = "takes an answer only from the player it asked, and only one it offered",
    run = function(world)
      local handle = two_players(world)
      local got = {}
      world.api.ui.menu(handle, { title = "Pick", options = { { label = "a" }, { label = "b" } } }, function(choice, err)
        got[#got + 1] = { choice, err }
      end)
      local number = asked(world, 1)
      answer(world, 2, number, { ok = true, index = 2 })
      assert.are.same({}, got, "another player cannot answer for them")
      answer(world, 1, number, { ok = true, index = 9 })
      assert.are.same({ { nil, "invalid" } }, got)
      answer(world, 1, number, { ok = true, index = 1 })
      assert.are.equal(1, #got, "one answer per request")
    end,
  },
  {
    name = "reads an input dialog's values by field name, and a progress bar's end",
    run = function(world)
      local handle = two_players(world)
      local values, done
      world.api.ui.input(handle, {
        title = "Spray",
        fields = {
          { name = "text", label = "Text", required = true, max = 24 },
          { name = "colour", label = "Colour", kind = "select", options = { { label = "Red", value = "red" } } },
        },
      }, function(result)
        values = result
      end)
      local number = asked(world, 1)
      answer(world, 1, number, { ok = true, values = world.core.json.array({ "hello", 1 }) })
      assert.are.same({ text = "hello", colour = "red" }, values)
      world.api.ui.progress(handle, { label = "Spraying", duration_ms = 2000 }, function(result, err)
        done = { result, err }
      end)
      answer(world, 1, (asked(world, 1)), { ok = true, done = true })
      assert.are.same({ true }, done)
    end,
  },
  {
    name = "sends a notification, and refuses a player who has not logged in",
    run = function(world)
      local handle = two_players(world)
      assert.is_true(world.api.ui.notify(handle, "Welcome"))
      local found = false
      for _, sent in ipairs(world.to_clients) do
        if sent.player == 1 and sent.name == "rpf:ui_notify" then
          found = world.core.json.decode(sent.payload).spec.text == "Welcome"
        end
      end
      assert.is_true(found)
      local stranger = world.join(3)
      assert.are.same({ nil, "not_found" }, { world.api.ui.notify(stranger, "x") })
      assert.is_true(world.api.capabilities().menu)
    end,
  },
})
