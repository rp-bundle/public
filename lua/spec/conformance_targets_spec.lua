-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Conformance (J4): interactions with targets, the same cases on the mock
-- platform and on the real FiveM and Gmod adapters
-- (`spec/support/conformance.lua`). The client only names a target; the
-- server decides, from its own state, whether the player is in the world,
-- may, is past their cooldown, and is near a visible record in their bucket
-- or an entity of the right model, and only then runs the handler, with the
-- target resolved. Missing, hidden, another bucket and another type are one
-- answer.

local conformance = require("spec.support.conformance")

---What `conformance.run` needs from busted.
local busted = { describe = describe, it = it, before_each = before_each, after_each = after_each }

local PLAYER = "00000002-0000-4000-8000-000000000002"
local NEAR = "0000000a-0000-4000-8000-00000000000a"
local FAR = "0000000b-0000-4000-8000-00000000000b"
local HIDDEN = "0000000c-0000-4000-8000-00000000000c"
local ELSEWHERE = "0000000d-0000-4000-8000-00000000000d"
local AREA = "0000000e-0000-4000-8000-00000000000e"
local MISSING = "0000000f-0000-4000-8000-00000000000f"
local MODELS = { fivem = "a_m_y_business_01", gmod = "models/humans/group01/male_02.mdl", mock = "mock_greeter" }

---An addon with greeters (placed peds) and areas (zones).
---@return table manifest The manifest.
local function manifest()
  return {
    namespace = "acme_npcs",
    version = "1.0.0",
    api = 1,
    title = "NPCs",
    permissions = { boss = "Give orders to greeters" },
    types = {
      greeter = {
        schema = 1,
        authority = "config",
        fields = {
          spot = { type = "vector3", required = true },
          bucket = { type = "integer", min = 0, default = 0 },
          model = { type = "json", engine = true, required = true },
          shown = { type = "boolean", default = true },
          line = { type = "string", required = true },
        },
        world = { kind = "ped", position = "spot", bucket = "bucket", model = "model", visible = "shown" },
      },
      area = {
        schema = 1,
        authority = "config",
        fields = {
          centre = { type = "vector3", required = true },
          radius = { type = "number", required = true },
        },
        world = { kind = "zone", position = "centre", radius = "radius" },
      },
    },
  }
end

---A greeter as the config carries it.
---@param id string Its id.
---@param at { x: number, y: number, z: number } Where it stands.
---@param extra table? More fields.
---@return table record The record.
local function greeter(id, at, extra)
  local fields = { spot = at, bucket = 0, model = MODELS, shown = true, line = "Hello from " .. id:sub(1, 8) }
  for key, value in pairs(extra or {}) do
    fields[key] = value
  end
  return { id = id, type = "acme_npcs.greeter", revision = 1, fields = fields }
end

---Registers the addon, whose `start` registers its interactions, installs
---it with greeters and an area, and logs player 1 in, in the world, beside
---the near greeter.
---@param world spec.ConformanceWorld The world.
---@param extra table<string, table>? More interactions to register in `start`: rules by name.
---@return any handle The player's engine handle.
local function ready(world, extra)
  local api = world.api
  assert(api.addons.register(manifest(), {
    start = function()
      assert(api.interactions.register("acme_npcs.talk", function(_, _, target)
        return true, { line = target.record.fields.line, id = target.id, type = target.type }
      end, { target = "acme_npcs.greeter", label = "Talk", distance = 3, cooldown = 2000 }))
      assert(api.interactions.register("acme_npcs.order", function()
        return true
      end, { target = "acme_npcs.greeter", label = "Give an order", permission = "boss" }))
      assert(api.interactions.register("acme_npcs.wave", function()
        return true
      end, {
        target = "acme_npcs.greeter",
        label = "Wave",
        check = function(_, target)
          if target.id == NEAR then
            return false, "They look away."
          end
          return true
        end,
      }))
      assert(api.interactions.register("acme_npcs.rest", function(_, _, target)
        return true, { id = target.id }
      end, { target = "acme_npcs.area", label = "Rest" }))
      assert(api.interactions.register("acme_npcs.bow", function(_, _, target)
        return true, { id = target.id, ref = target.ref }
      end, { target = { models = { MODELS[api.engine] } }, label = "Bow", distance = 3 }))
      for name, rules in pairs(extra or {}) do
        assert(api.interactions.register(name, function()
          return true
        end, rules))
      end
    end,
  }))
  world:connect()
  local json = world.core.json
  local entry = conformance.installed(world.core, manifest())
  local records = {
    greeter(NEAR, { x = 11, y = 20, z = 30 }),
    greeter(FAR, { x = 100, y = 20, z = 30 }),
    greeter(HIDDEN, { x = 10, y = 21, z = 30 }, { shown = false }),
    greeter(ELSEWHERE, { x = 10, y = 19, z = 30 }, { bucket = 5 }),
    { id = AREA, type = "acme_npcs.area", revision = 1, fields = { centre = { x = 10, y = 20, z = 25 }, radius = 6 } },
  }
  entry.records = assert(json.decode(assert(json.encode(json.array(records)))))
  world:install({ entry })
  world:pump()
  -- FiveM makes a placed entity asynchronously; the adapter looks every 50 ms.
  world:advance(500)
  local handle = world:login(1, PLAYER)
  world:activate(handle)
  world.place(1, { x = 10, y = 20, z = 30 })
  return handle
end

---How many requests the harness's clients have numbered.
local numbered = 0

---Sends a request from player 1's client, as the platform frames one, and
---gives the server's answer, decoded.
---@param world spec.ConformanceWorld The world.
---@param name string The request's message name.
---@param body table The request's fields.
---@return table answer The answer.
local function ask(world, name, body)
  local json = world.core.json
  local before = #world.to_clients
  numbered = numbered + 1
  world.from_client(1, name, numbered .. "\n" .. assert(json.encode(body)))
  for i = before + 1, #world.to_clients do
    local sent = world.to_clients[i]
    if sent.name == name then
      local _, reply = sent.payload:match("^(%d+)\n(.*)$")
      return assert(json.decode(reply))
    end
  end
  error("no answer to " .. name)
end

---Runs an interaction with a target from player 1's client.
---@param world spec.ConformanceWorld The world.
---@param name string The interaction.
---@param target table? What the client names.
---@return table answer `{ ok, reason, data }`.
local function interact(world, name, target)
  local json = world.core.json
  local payload = json.object({ target = target and json.object(target) or nil })
  return ask(world, "rpf:interact", json.object({ name = name, payload = payload }))
end

conformance.run(busted, "Interactions with targets", {
  {
    name = "runs the handler with the record a near, visible greeter in the player's bucket is",
    run = function(world)
      ready(world)
      local answer = interact(world, "acme_npcs.talk", { id = NEAR })
      assert.is_true(answer.ok, tostring(answer.reason))
      assert.are.same({ line = "Hello from 0000000a", id = NEAR, type = "acme_npcs.greeter" }, answer.data)
    end,
  },
  {
    name = "refuses a missing, hidden, other-bucket or malformed greeter as one, and a far one as too_far",
    run = function(world)
      ready(world)
      for _, id in ipairs({ MISSING, HIDDEN, ELSEWHERE, AREA, "not-a-uuid", NEAR:upper() }) do
        local answer = interact(world, "acme_npcs.talk", { id = id })
        assert.is_false(answer.ok, id)
        assert.are.equal("not_found", answer.reason, id)
      end
      local none = interact(world, "acme_npcs.talk", nil)
      assert.are.equal("not_found", none.reason)
      local far = interact(world, "acme_npcs.talk", { id = FAR })
      assert.are.equal("too_far", far.reason)
    end,
  },
  {
    name = "takes a placed greeter's entity as the greeter, and nothing else's",
    run = function(world)
      ready(world)
      local ref = assert(world.api.world.placed("acme_npcs.greeter", NEAR))
      local answer = interact(world, "acme_npcs.talk", { ref = ref })
      assert.is_true(answer.ok, tostring(answer.reason))
      assert.are.equal(NEAR, answer.data.id)
      world:advance(2000)
      local unknown = interact(world, "acme_npcs.talk", { ref = ref + 4242 })
      assert.are.equal("not_found", unknown.reason)
    end,
  },
  {
    name = "holds a player to the cooldown after the handler ran",
    run = function(world)
      ready(world)
      assert.is_true(interact(world, "acme_npcs.talk", { id = NEAR }).ok)
      assert.are.equal("cooldown", interact(world, "acme_npcs.talk", { id = NEAR }).reason)
      world:advance(2000)
      assert.is_true(interact(world, "acme_npcs.talk", { id = NEAR }).ok)
    end,
  },
  {
    name = "refuses a player who is not in the world, or lacks the rule's permission",
    run = function(world)
      local handle = ready(world)
      assert.are.equal("forbidden", interact(world, "acme_npcs.order", { id = NEAR }).reason)
      local json = world.core.json
      assert(world.core.staff.apply(json.array({
        json.object({ player_id = PLAYER, permissions = json.array({ "addon.acme_npcs.boss" }) }),
      })))
      assert.is_true(interact(world, "acme_npcs.order", { id = NEAR }).ok, "a linked staff member holding the flag")
      world.core.players.advance(handle, "character_select")
      assert.are.equal("not_active", interact(world, "acme_npcs.talk", { id = NEAR }).reason)
    end,
  },
  {
    name = "lets the addon's own check refuse, with its reason, and the handler not run",
    run = function(world)
      ready(world)
      local refused = interact(world, "acme_npcs.wave", { id = NEAR })
      assert.is_false(refused.ok)
      assert.are.equal("They look away.", refused.reason)
    end,
  },
  {
    name = "takes a zone's radius, not the rule's distance",
    run = function(world)
      ready(world)
      local answer = interact(world, "acme_npcs.rest", { id = AREA })
      assert.is_true(answer.ok, tostring(answer.reason))
      world.place(1, { x = 10, y = 20, z = 40 })
      assert.are.equal("too_far", interact(world, "acme_npcs.rest", { id = AREA }).reason)
    end,
  },
  {
    name = "matches an entity's model for a models rule, by the engine's id for the name",
    run = function(world)
      ready(world)
      local ref = assert(world.api.world.placed("acme_npcs.greeter", NEAR))
      local answer = interact(world, "acme_npcs.bow", { ref = ref })
      assert.is_true(answer.ok, tostring(answer.reason))
      assert.are.same({ id = NEAR, ref = ref }, answer.data)
      local far = assert(world.api.world.placed("acme_npcs.greeter", FAR))
      assert.are.equal("too_far", interact(world, "acme_npcs.bow", { ref = far }).reason)
      assert.are.equal("not_found", interact(world, "acme_npcs.bow", { ref = far + 999 }).reason)
    end,
  },
  {
    name = "lists what is near the player, nearest first, offered to them, and nothing hidden or elsewhere",
    run = function(world)
      ready(world)
      local answer = ask(world, "rpf:targets", world.core.json.object({}))
      local seen = {}
      for _, option in ipairs(answer.options) do
        seen[#seen + 1] = option.name .. " " .. option.id:sub(1, 8)
      end
      assert.are.same({
        "acme_npcs.talk 0000000a",
        "acme_npcs.wave 0000000a",
        "acme_npcs.rest 0000000e",
      }, seen)
      assert.are.equal("Talk", answer.options[1].label)
    end,
  },
  {
    name = "tells a player in the world which rules have a target, for a target resource",
    run = function(world)
      ready(world)
      world:advance(0)
      local rules
      for _, sent in ipairs(world.to_clients) do
        if sent.player == 1 and sent.name == "rpf:target_rules" then
          rules = assert(world.core.json.decode(sent.payload)).rules
        end
      end
      assert(rules, "the rules were sent")
      local by_name = {}
      for _, rule in ipairs(rules) do
        by_name[rule.name] = rule
      end
      assert.are.equal("ped", by_name["acme_npcs.talk"].kind)
      assert.are.equal("acme_npcs.greeter", by_name["acme_npcs.talk"].type)
      assert.are.equal(3, by_name["acme_npcs.talk"].distance)
      assert.are.equal(MODELS[world.api.engine], by_name["acme_npcs.bow"].models[1])
      assert.are.equal("zone", by_name["acme_npcs.rest"].kind)
    end,
  },
  {
    name = "sends an empty list as a list: no rules, and nothing near",
    run = function(world)
      local json = world.core.json
      world:connect()
      local handle = world:login(1, PLAYER)
      world:activate(handle)
      world.place(1, { x = 0, y = 0, z = 0 })
      world:advance(0)
      local rules
      for _, sent in ipairs(world.to_clients) do
        if sent.player == 1 and sent.name == "rpf:target_rules" then
          rules = assert(json.decode(sent.payload)).rules
        end
      end
      assert.is_true(json.is_array(rules), "rules")
      local answer = ask(world, "rpf:targets", json.object({}))
      assert.is_true(json.is_array(answer.options), "options")
      assert.are.equal(0, #answer.options)
    end,
  },
  {
    name = "holds the cooldown from the moment a request is admitted, so a request made while the handler runs is refused",
    run = function(world)
      ready(world)
      local runs = 0
      ---@type table
      local inner = {}
      assert(world.api.interactions.register("acme_npcs.slow", function()
        runs = runs + 1
        if runs == 1 then
          -- The same player's next request, while this one is still running.
          inner = interact(world, "acme_npcs.slow", { id = NEAR })
        end
        return true
      end, { target = "acme_npcs.greeter", cooldown = 5000 }))
      interact(world, "acme_npcs.slow", { id = NEAR })
      assert.are.equal(1, runs)
      assert.are.equal("cooldown", inner.reason)
    end,
  },
  {
    name = "gives the cooldown back when the addon's own check refuses",
    run = function(world)
      ready(world)
      local allow = false
      assert(world.api.interactions.register("acme_npcs.picky", function()
        return true
      end, {
        target = "acme_npcs.greeter",
        cooldown = 5000,
        check = function()
          return allow, "Not yet."
        end,
      }))
      assert.are.equal("Not yet.", interact(world, "acme_npcs.picky", { id = NEAR }).reason)
      allow = true
      assert.is_true(interact(world, "acme_npcs.picky", { id = NEAR }).ok, "not held to a cooldown it never used")
      assert.are.equal("cooldown", interact(world, "acme_npcs.picky", { id = NEAR }).reason)
    end,
  },
  {
    name = "refuses rules an author got wrong at registration, naming the rule",
    run = function(world)
      local api = world.api
      local refusals = {}
      assert(api.addons.register(manifest(), {
        start = function()
          for _, rules in ipairs({
            { target = "greeter" },
            { distance = 0 },
            { cooldown = 1.5 },
            { permisson = "boss" },
            { target = { models = {} } },
            { target = { type = "acme_npcs.greeter", models = { "x" } } },
          }) do
            local ok, err, detail = api.interactions.register("acme_npcs.bad", function() end, rules)
            refusals[#refusals + 1] = { ok, err, detail and detail.field }
          end
        end,
      }))
      world:install({ conformance.installed(world.core, manifest()) })
      assert.are.same({
        { nil, "invalid", "target.type" },
        { nil, "invalid", "distance" },
        { nil, "invalid", "cooldown" },
        { nil, "invalid", "permisson" },
        { nil, "invalid", "target.models" },
        { nil, "invalid", "target" },
      }, refusals)
    end,
  },
})
