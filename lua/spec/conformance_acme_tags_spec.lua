-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Conformance (J3): the worked example, `lua/examples/acme_tags/`, run as it
-- ships on the mock platform and on the real FiveM and Gmod adapters,
-- against a fake portal (`spec/support/conformance.lua`). An addon RPF has
-- never heard of declares a type, registers an interaction a player's
-- client calls, keeps its records across a restart, and fades them on a
-- timer, through the public API alone.

local conformance = require("spec.support.conformance")
local support = require("spec.support")

---What `conformance.run` needs from busted.
local busted = { describe = describe, it = it, before_each = before_each, after_each = after_each }

local PLAYER = "00000002-0000-4000-8000-000000000002"
local OLD_TAG = "0000000c-0000-4000-8000-00000000000c"

---Loads the example's server half as an engine entry point does, and
---starts it on the world's API.
---@param world spec.ConformanceWorld The world.
local function load_example(world)
  rawset(_G, "acme_tags", nil)
  dofile(support.path("lua/examples/acme_tags/manifest.lua"))
  dofile(support.path("lua/examples/acme_tags/server.lua"))
  assert(rawget(_G, "acme_tags").start_server(world.api))
end

---Connects, starts the example, has staff install it, and logs a player in
---standing at a wall.
---@param world spec.ConformanceWorld The world.
---@return integer player The harness's number for the player.
local function sprayable(world)
  load_example(world)
  world:connect()
  world:install({ conformance.installed(world.core, rawget(_G, "acme_tags").MANIFEST) })
  world:pump()
  assert.are.equal("active", (world.api.addons.state("acme_tags")))
  world:login(1, PLAYER)
  world.place(1, { x = 10, y = 20, z = 30 })
  return 1
end

---Sends an interaction from a player's client, as the client core frames
---it, and gives the server's answer.
---@param world spec.ConformanceWorld The world.
---@param player integer The player.
---@param name string The interaction.
---@param payload table? Its payload.
---@return table? answer The decoded `rpf:interaction_result`.
local function interact(world, player, name, payload)
  local json = world.core.json
  local before = #world.to_clients
  local body = json.object({ name = name, payload = payload and json.object(payload) or nil })
  world.from_client(player, "rpf:interact", assert(json.encode(body)))
  for i = before + 1, #world.to_clients do
    local sent = world.to_clients[i]
    if sent.name == "rpf:interaction_result" then
      return json.decode(sent.payload)
    end
  end
  return nil
end

conformance.run(busted, "the acme_tags example", {
  {
    name = "sprays a tag where the player stands, through the interaction, and the portal keeps it",
    run = function(world)
      local player = sprayable(world)
      local answer = assert(interact(world, player, "acme_tags.spray", { text = "hello" }))
      assert.is_true(answer.ok)
      local tags = assert(world.api.records.list("acme_tags.tag"))
      assert.are.equal(1, #tags)
      assert.are.equal("hello", tags[1].fields.text)
      assert.are.same({ x = 10, y = 20, z = 30 }, tags[1].fields.spot)
      assert.are.same({ kind = "player", id = PLAYER }, tags[1].owner)
      world:settle()
      assert.are.equal("hello", world.portal.records[tags[1].id].fields.text)
    end,
  },
  {
    name = "refuses what the client should not send, with a reason it can show",
    run = function(world)
      local player = sprayable(world)
      local empty = assert(interact(world, player, "acme_tags.spray", { text = "" }))
      assert.is_false(empty.ok)
      assert.are.equal("Write something to spray.", empty.reason)
      local long = assert(interact(world, player, "acme_tags.spray", { text = string.rep("x", 40) }))
      assert.is_false(long.ok)
      assert.truthy(long.reason:find("invalid", 1, true))
      local unknown = assert(interact(world, player, "acme_tags.paint", { text = "x" }))
      assert.are.same({ false, "unknown" }, { unknown.ok, unknown.reason })
      local forged = assert(interact(world, player, "players.kick", {}))
      assert.are.same({ false, "unknown" }, { forged.ok, forged.reason }, "no client-named event, ever")
      assert.are.equal(0, #world.api.records.list("acme_tags.tag"))
    end,
  },
  {
    name = "ignores a client that has not logged in, and one that sends too many",
    run = function(world)
      local player = sprayable(world)
      world.join(2)
      assert.is_nil(interact(world, 2, "acme_tags.spray", { text = "hi" }), "not logged in: no answer")
      for _ = 1, 20 do
        interact(world, player, "acme_tags.paint", {})
      end
      assert.is_nil(interact(world, player, "acme_tags.spray", { text = "hi" }), "past the rate: dropped")
      world:advance(10000)
      assert.is_true(assert(interact(world, player, "acme_tags.spray", { text = "hi" })).ok)
    end,
  },
  {
    name = "keeps trying to reclaim the portal's tags when it could not answer at start",
    run = function(world)
      world.portal.records[OLD_TAG] = {
        id = OLD_TAG,
        type = "acme_tags.tag",
        owner = { kind = "player", id = PLAYER },
        revision = 3,
        fields = { text = "old", spot = { x = 0, y = 0, z = 0 }, fades_at = 1 },
        held = false,
      }
      world.portal.refuse = { query_records = "forbidden" }
      sprayable(world)
      assert.are.equal(0, #world.api.records.list("acme_tags.tag"))
      world.portal.refuse = nil
      world:advance(30000)
      world:pump()
      assert.are.equal(1, #world.api.records.list("acme_tags.tag"), "held on the retry")
    end,
  },
  {
    name = "answers a long reason whole characters at a time, and drops a name no addon could have",
    run = function(world)
      local player = sprayable(world)
      world.api.interactions.register("acme_tags.euros", function()
        return false, string.rep("€", 50)
      end)
      local answer = assert(interact(world, player, "acme_tags.euros", {}))
      assert.is_false(answer.ok)
      assert.are.equal(string.rep("€", 42), answer.reason, "128 bytes is 42 whole euro signs")
      assert.is_nil(interact(world, player, "Acme Tags!", {}))
      assert.is_nil(interact(world, player, string.rep("a", 60) .. "." .. string.rep("b", 10), {}))
    end,
  },
  {
    name = "fades a tag once its day is up",
    run = function(world)
      local player = sprayable(world)
      assert.is_true(assert(interact(world, player, "acme_tags.spray", { text = "fading" })).ok)
      world:settle()
      local id = world.api.records.list("acme_tags.tag")[1].id
      world:advance(24 * 60 * 60 * 1000 + 60000)
      assert.are.equal(0, #world.api.records.list("acme_tags.tag"))
      world:settle()
      assert.is_nil(world.portal.records[id], "the portal deleted it too")
    end,
  },
  {
    name = "holds the tags the portal already has when it starts, so they fade after a restart",
    run = function(world)
      world.portal.records[OLD_TAG] = {
        id = OLD_TAG,
        type = "acme_tags.tag",
        owner = { kind = "player", id = PLAYER },
        revision = 3,
        fields = { text = "old", spot = { x = 0, y = 0, z = 0 }, fades_at = 1 },
        held = false,
      }
      sprayable(world)
      local tags = world.api.records.list("acme_tags.tag")
      assert.are.equal(1, #tags)
      assert.are.equal(OLD_TAG, tags[1].id)
      world:advance(60000)
      world:settle()
      assert.is_nil(world.portal.records[OLD_TAG], "faded on the first tick")
    end,
  },
  {
    name = "stops spraying when staff disable it, and lets its tags go",
    run = function(world)
      local player = sprayable(world)
      assert.is_true(assert(interact(world, player, "acme_tags.spray", { text = "kept" })).ok)
      world:settle()
      local id = world.api.records.list("acme_tags.tag")[1].id
      world:install({ conformance.installed(world.core, rawget(_G, "acme_tags").MANIFEST, false) })
      world:pump()
      local answer = assert(interact(world, player, "acme_tags.spray", { text = "no" }))
      assert.are.same({ false, "unknown" }, { answer.ok, answer.reason }, "its interaction went with it")
      assert.is_false(world.portal.records[id].held, "released with its final state")
      assert.are.equal("kept", world.portal.records[id].fields.text)
    end,
  },
})
