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
-- target resolved. Missing, hidden, another bucket, another map (#369) and
-- another type are one answer.

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
local ABROAD = "00000010-0000-4000-8000-000000000010"
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
          map = { type = "string", index = true, nullable = true },
        },
        world = { kind = "zone", position = "centre", radius = "radius", map = "map" },
      },
    },
  }
end

---A point given in metres from the origin, as the engine's positions have it:
---the engine's units differ (Gmod's are 39.37 to the metre), so a case that
---means "one metre east" says so with this on every engine.
---@param world spec.ConformanceWorld The world.
---@param x number Metres.
---@param y number Metres.
---@param z number Metres.
---@return { x: number, y: number, z: number } point The point, in the engine's units.
local function point(world, x, y, z)
  return { x = world:units(x), y = world:units(y), z = world:units(z) }
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
    greeter(NEAR, point(world, 11, 20, 30)),
    greeter(FAR, point(world, 100, 20, 30)),
    greeter(HIDDEN, point(world, 10, 21, 30), { shown = false }),
    greeter(ELSEWHERE, point(world, 10, 19, 30), { bucket = 5 }),
    -- Six metres across, on every engine.
    { id = AREA, type = "acme_npcs.area", revision = 1, fields = { centre = point(world, 10, 20, 25), radius = 6 } },
    -- The same area, on a map this server does not run: never in reach.
    {
      id = ABROAD,
      type = "acme_npcs.area",
      revision = 1,
      fields = { centre = point(world, 10, 20, 25), radius = 6, map = "rp_elsewhere" },
    },
  }
  entry.records = assert(json.decode(assert(json.encode(json.array(records)))))
  world:install({ entry })
  world:pump()
  -- FiveM makes a placed entity asynchronously; the adapter looks every 50 ms.
  world:advance(500)
  local handle = world:login(1, PLAYER)
  world:activate(handle)
  world.place(1, point(world, 10, 20, 30))
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
  local number = numbered
  world.from_client(1, name, number .. "\n" .. assert(json.encode(body)))
  -- Its own answer: one to a request made while this one ran may come first.
  for i = before + 1, #world.to_clients do
    local sent = world.to_clients[i]
    local id, reply = sent.payload:match("^(%d+)\n(.*)$")
    if sent.name == name and tonumber(id) == number then
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

---An answer's options, as `<name> <first 8 of the id>`.
---@param answer table The `rpf:targets` answer.
---@return string[] options Them, in order.
local function listed(answer)
  local seen = {}
  for _, option in ipairs(answer.options) do
    seen[#seen + 1] = option.name .. " " .. option.id:sub(1, 8)
  end
  return seen
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
      -- A zone on another map is not there, however close its centre.
      assert.is_true(interact(world, "acme_npcs.rest", { id = AREA }).ok)
      assert.are.equal("not_found", interact(world, "acme_npcs.rest", { id = ABROAD }).reason)
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
      world.place(1, point(world, 10, 20, 40))
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
    name = "lists what is near the player, nearest first, offered to them, and nothing hidden, elsewhere or on another map",
    run = function(world)
      ready(world)
      local answer = ask(world, "rpf:targets", world.core.json.object({}))
      -- `wave` is left out: its check refuses the near greeter.
      assert.are.same({ "acme_npcs.talk 0000000a", "acme_npcs.rest 0000000e" }, listed(answer))
      assert.are.equal("Talk", answer.options[1].label)
      -- Reported in metres, whatever the engine measures in: the near
      -- greeter is a metre from the player.
      assert.is_true(math.abs(answer.options[1].distance - 1) < 1e-9, tostring(answer.options[1].distance))
    end,
  },
  {
    name = "measures a rule's distance, and reports a target's, in metres on every engine",
    run = function(world)
      ready(world)
      local seen
      assert(world.api.interactions.register("acme_npcs.measure", function(_, _, target)
        seen = target.distance
        return true
      end, { target = "acme_npcs.greeter", distance = 2.5 }))
      -- The near greeter is one metre east of the player: well inside.
      assert.is_true(interact(world, "acme_npcs.measure", { id = NEAR }).ok)
      assert.is_true(math.abs(seen - 1) < 1e-9, tostring(seen))
      world.place(1, point(world, 12.4, 20, 30))
      assert.is_true(interact(world, "acme_npcs.measure", { id = NEAR }).ok, "1.4 m away, inside 2.5 m")
      assert.is_true(math.abs(seen - 1.4) < 1e-9, tostring(seen))
      world.place(1, point(world, 13.6, 20, 30))
      assert.are.equal("too_far", interact(world, "acme_npcs.measure", { id = NEAR }).reason, "2.6 m away, outside 2.5 m")
    end,
  },
  {
    name = "reads a zone's radius, and the default distance, in metres on every engine",
    run = function(world)
      ready(world)
      -- The area is six metres across; the default distance is three.
      world.place(1, point(world, 10, 20, 30.9))
      assert.is_true(interact(world, "acme_npcs.rest", { id = AREA }).ok, "5.9 m from the middle")
      world.place(1, point(world, 10, 20, 31.1))
      assert.are.equal("too_far", interact(world, "acme_npcs.rest", { id = AREA }).reason, "6.1 m from the middle")
      -- `wave` has no distance of its own, and its check refuses the near
      -- greeter, so what it answers says whether the target was in reach.
      world.place(1, point(world, 13.9, 20, 30))
      assert.are.equal("They look away.", interact(world, "acme_npcs.wave", { id = NEAR }).reason, "2.9 m is inside the default")
      world.place(1, point(world, 14.1, 20, 30))
      assert.are.equal("too_far", interact(world, "acme_npcs.wave", { id = NEAR }).reason, "3.1 m is outside it")
    end,
  },
  {
    name = "lists only what the addon's own check passes, run as a request runs it, and not what is cooling down",
    run = function(world)
      ready(world)
      local seen = {}
      assert(world.api.interactions.register("acme_npcs.nod", function()
        return true
      end, {
        target = "acme_npcs.greeter",
        cooldown = 5000,
        check = function(player, target)
          seen[#seen + 1] = { player.player_id, target.id, target.record.fields.line, world.core.addons.context().namespace }
          target.record.fields.line = "changed by the check"
          return true
        end,
      }))
      local answer = ask(world, "rpf:targets", world.core.json.object({}))
      assert.are.same({ "acme_npcs.nod 0000000a", "acme_npcs.talk 0000000a", "acme_npcs.rest 0000000e" }, listed(answer))
      assert.are.same({ { PLAYER, NEAR, "Hello from 0000000a", "acme_npcs" } }, seen, "in the addon's context, with the record")
      assert.is_true(interact(world, "acme_npcs.nod", { id = NEAR }).ok)
      assert.are.equal("Hello from 0000000a", seen[2][3], "the listing's copy was its own")
      answer = ask(world, "rpf:targets", world.core.json.object({}))
      assert.are.same({ "acme_npcs.talk 0000000a", "acme_npcs.rest 0000000e" }, listed(answer), "cooling down")
      assert.are.equal(2, #seen, "and its check not run for it")
    end,
  },
  {
    name = "lists nothing for a type whose records cannot be read, logging it once however often it is asked",
    run = function(world)
      ready(world)
      local data = world.core.data
      local list = data.list
      data.list = function()
        return nil, "inactive"
      end
      local first = ask(world, "rpf:targets", world.core.json.object({}))
      local second = ask(world, "rpf:targets", world.core.json.object({}))
      data.list = list
      assert.are.same({}, first.options)
      assert.are.same({}, second.options)
      local count = 0
      for _, line in ipairs(world.logs) do
        if line.level == "error" and line.message:find("could not read the records of acme_npcs.greeter (inactive)", 1, true) then
          count = count + 1
        end
      end
      assert.are.equal(1, count)
      assert.are.same({ "acme_npcs.talk 0000000a", "acme_npcs.rest 0000000e" }, listed(ask(world, "rpf:targets", world.core.json.object({}))), "listed again once they can")
    end,
  },
  {
    name = "leaves out an option whose check throws or answers anything but true, and lists the rest",
    run = function(world)
      ready(world, {
        ["acme_npcs.boom"] = { target = "acme_npcs.greeter", check = function()
          error("broken")
        end },
        ["acme_npcs.maybe"] = { target = "acme_npcs.greeter", check = function()
          return "yes"
        end },
      })
      local answer = ask(world, "rpf:targets", world.core.json.object({}))
      assert.are.same({ "acme_npcs.talk 0000000a", "acme_npcs.rest 0000000e" }, listed(answer))
      local logged = false
      for _, line in ipairs(world.logs) do
        if line.level == "error" and line.message:find("acme_npcs.boom failed while listing", 1, true) then
          logged = true
        end
      end
      assert.is_true(logged, "the throw is logged")
    end,
  },
  {
    name = "runs at most MAX_CHECKS checks in one listing, nearest first, and lists none it did not run",
    run = function(world)
      ready(world)
      local runs = 0
      assert(world.api.interactions.register("acme_npcs.nod", function()
        return true
      end, { target = "acme_npcs.greeter", check = function()
        runs = runs + 1
        return true
      end }))
      local targets = world.core.targets
      local cap = targets.MAX_CHECKS
      targets.MAX_CHECKS = 1
      local answer = ask(world, "rpf:targets", world.core.json.object({}))
      targets.MAX_CHECKS = cap
      -- `nod` sorts before `wave` on the same greeter, so it is the one run.
      assert.are.same({ "acme_npcs.nod 0000000a", "acme_npcs.talk 0000000a", "acme_npcs.rest 0000000e" }, listed(answer))
      assert.are.equal(1, runs)
    end,
  },
  {
    name = "starts no check once a listing has taken CHECK_BUDGET_MS, as after a check that yielded",
    run = function(world)
      ready(world)
      local waved = false
      assert(world.api.interactions.register("acme_npcs.nod", function()
        return true
      end, { target = "acme_npcs.greeter", check = function()
        -- As a check that yields might resume: the budget has gone by.
        world:advance(world.core.targets.CHECK_BUDGET_MS)
        return true
      end }))
      assert(world.api.interactions.register("acme_npcs.wave", function()
        return true
      end, { target = "acme_npcs.greeter", label = "Wave", check = function()
        waved = true
        return true
      end }))
      local answer = ask(world, "rpf:targets", world.core.json.object({}))
      assert.are.same({ "acme_npcs.nod 0000000a", "acme_npcs.talk 0000000a", "acme_npcs.rest 0000000e" }, listed(answer))
      assert.is_false(waved)
    end,
  },
  {
    name = "checks everything again after a check that may have yielded, and every later option as things are then",
    run = function(world)
      ready(world)
      local json = world.core.json
      local ref = assert(world.api.world.placed("acme_npcs.greeter", NEAR))
      assert(world.api.interactions.register("acme_npcs.nod", function()
        return true
      end, { target = "acme_npcs.greeter", check = function()
        -- As a check that yields might resume: the player walked away.
        world.place(1, { x = 500, y = 20, z = 30 })
        return true
      end }))
      local answer = ask(world, "rpf:targets", json.object({}))
      assert.are.same({}, listed(answer), "nod's target is out of reach now, and so are talk and rest")
      world.place(1, { x = 10, y = 20, z = 30 })
      local offered = ask(world, "rpf:target_offers", json.object({ ref = ref, names = json.array({ "acme_npcs.nod", "acme_npcs.bow" }) }))
      assert.are.same({}, offered.names)
    end,
  },
  {
    name = "offers nothing whose addon reloaded while its check ran",
    run = function(world)
      ready(world)
      assert(world.api.interactions.register("acme_npcs.nod", function()
        return true
      end, { target = "acme_npcs.greeter", check = function()
        -- As a check that yields might resume: the addon reloaded meanwhile.
        assert(world.api.addons.register(manifest(), {}))
        return true
      end }))
      local answer = ask(world, "rpf:targets", world.core.json.object({}))
      assert.are.same({}, listed(answer))
    end,
  },
  {
    name = "lets a player have at most MAX_LISTING listings running, as checks that yield would leave them",
    run = function(world)
      ready(world)
      local targets = world.core.targets
      local most = targets.MAX_LISTING
      targets.MAX_LISTING = 1
      local inner
      assert(world.api.interactions.register("acme_npcs.nod", function()
        return true
      end, { target = "acme_npcs.greeter", check = function()
        -- The same player's next listing, while this one's check runs.
        inner = inner or ask(world, "rpf:targets", world.core.json.object({}))
        return true
      end }))
      local answer = ask(world, "rpf:targets", world.core.json.object({}))
      targets.MAX_LISTING = most
      assert.are.equal(0, #inner.options)
      assert.are.equal(3, #answer.options)
      answer = ask(world, "rpf:targets", world.core.json.object({}))
      assert.are.equal(3, #answer.options, "and the count came back down")
    end,
  },
  {
    name = "answers which rules it offers on an entity for a target resource: every rule, the check included",
    run = function(world)
      ready(world)
      local json = world.core.json
      local ref = assert(world.api.world.placed("acme_npcs.greeter", NEAR))
      ---Asks which of the names are offered on an entity.
      ---@param on any The entity's ref.
      ---@param names string[] The names.
      ---@return string[] offered What the server answered.
      local function offers(on, names)
        return ask(world, "rpf:target_offers", json.object({ ref = on, names = json.array(names) })).names
      end
      local all = { "acme_npcs.talk", "acme_npcs.wave", "acme_npcs.order", "acme_npcs.bow", "acme_npcs.rest", "acme_npcs.nope", "acme_npcs.talk" }
      -- `wave`'s check refuses the near greeter, `order` needs a permission,
      -- `rest` is an area's, `nope` nobody registered; `talk` is offered once.
      assert.are.same({ "acme_npcs.talk", "acme_npcs.bow" }, offers(ref, all))
      local far = assert(world.api.world.placed("acme_npcs.greeter", FAR))
      assert.are.same({}, offers(far, all), "out of reach")
      assert.are.same({}, offers(ref + 4242, all), "no such entity")
      assert.are.same({}, offers(ref, { "acme_npcs.talk", "not a name" }), "a name no addon could register refuses the lot")
      assert.is_true(interact(world, "acme_npcs.talk", { ref = ref }).ok)
      assert.are.same({ "acme_npcs.bow" }, offers(ref, all), "talk is cooling down")
      local many = {}
      for i = 1, world.core.targets.MAX_OFFER_NAMES + 1 do
        many[i] = "acme_npcs.bow"
      end
      assert.are.same({}, offers(ref, many), "too many names")
    end,
  },
  {
    name = "answers a target resource nothing offered past MAX_OFFERS_PER_WINDOW, counted apart from interactions",
    run = function(world)
      ready(world)
      local json = world.core.json
      local ref = assert(world.api.world.placed("acme_npcs.greeter", NEAR))
      local body = json.object({ ref = ref, names = json.array({ "acme_npcs.bow" }) })
      for _ = 1, world.core.interactions.MAX_OFFERS_PER_WINDOW do
        assert.are.same({ "acme_npcs.bow" }, ask(world, "rpf:target_offers", body).names)
      end
      assert.are.same({}, ask(world, "rpf:target_offers", body).names)
      assert.is_true(interact(world, "acme_npcs.bow", { ref = ref }).ok, "interactions are counted apart")
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
      -- A target resource measures in the engine's units, so the rule's
      -- three metres arrive converted.
      assert.is_true(math.abs(world:units(3) - by_name["acme_npcs.talk"].distance) < 1e-9)
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
      world.place(1, point(world, 0, 0, 0))
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
    name = "refuses inactive, and runs no handler, when the addon reloaded while its check ran",
    run = function(world)
      ready(world)
      local ran = false
      assert(world.api.interactions.register("acme_npcs.slowcheck", function()
        ran = true
        return true
      end, {
        target = "acme_npcs.greeter",
        check = function()
          -- As a check that yields might resume: the addon reloaded meanwhile.
          assert(world.api.addons.register(manifest(), {}))
          return true
        end,
      }))
      local answer = interact(world, "acme_npcs.slowcheck", { id = NEAR })
      assert.are.same({ false, "inactive" }, { answer.ok, answer.reason })
      assert.is_false(ran)
    end,
  },
  {
    name = "checks the player and target again after the addon's check, which may have yielded while they moved",
    run = function(world)
      ready(world)
      local ran = false
      assert(world.api.interactions.register("acme_npcs.wander", function()
        ran = true
        return true
      end, {
        target = "acme_npcs.greeter",
        check = function()
          -- As a check that yields might resume: the player walked away.
          world.place(1, point(world, 500, 20, 30))
          return true
        end,
      }))
      local answer = interact(world, "acme_npcs.wander", { id = NEAR })
      assert.are.same({ false, "too_far" }, { answer.ok, answer.reason })
      assert.is_false(ran)
    end,
  },
  {
    name = "refuses a rule that would make the rules too large for a client to read",
    run = function(world)
      ready(world)
      local long = string.rep("m", 250)
      local accepted, refusal = 0, nil
      for n = 1, 20 do
        local models = {}
        for i = 1, 32 do
          models[i] = long .. n .. "_" .. i
        end
        local ok, err = world.api.interactions.register("acme_npcs.many" .. n, function()
          return true
        end, { target = { models = models } })
        if not ok then
          refusal = err
          break
        end
        accepted = accepted + 1
      end
      assert.is_true(accepted > 0)
      assert.are.equal("too_large", refusal)
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
            { label = string.char(255) },
            { target = { models = { string.char(255) } } },
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
        { nil, "invalid", "label" },
        { nil, "invalid", "target.models" },
      }, refusals)
    end,
  },
})
