-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- What `rpf.interactions` does around `rpf.targets` (J4) that no engine
-- can stage on its own: a target that resolves to another record when it
-- is checked again after the addon's `check` (a ref reused while a check
-- yielded on FiveM). The checks themselves are in
-- `conformance_targets_spec.lua`, on every engine.

local conformance = require("spec.support.conformance")

describe("rpf.interactions with rules", function()
  it("refuses, and runs no handler, when the target checked again is another than the check approved", function()
    local world = conformance.boot("mock")
    local core = world.core
    local manifest = conformance.manifest("acme_npcs")
    assert(world.api.addons.register(manifest, {}))
    world:install({ conformance.installed(core, manifest) })
    world:connect()
    local handle = world:login(1, "00000002-0000-4000-8000-000000000002")
    world:activate(handle)
    local real = core.targets.admit
    local calls = 0
    core.targets.admit = function()
      calls = calls + 1
      return { type = "acme_npcs.thing", id = calls == 1 and "approved" or "another", position = { x = 0, y = 0, z = 0 }, distance = 0 }
    end
    local ran = false
    assert(world.api.interactions.register("acme_npcs.use", function()
      ran = true
      return true
    end, { target = "acme_npcs.thing", check = function()
      return true
    end }))
    local json = core.json
    world.from_client(1, "rpf:interact", "1\n" .. assert(json.encode(json.object({ name = "acme_npcs.use", payload = json.object({}) }))))
    core.targets.admit = real
    local answer
    for _, sent in ipairs(world.to_clients) do
      if sent.name == "rpf:interact" then
        answer = assert(json.decode(sent.payload:match("^%d+\n(.*)$")))
      end
    end
    world.finish()
    assert.are.equal(2, calls)
    assert.is_false(answer.ok)
    assert.are.equal("not_found", answer.reason)
    assert.is_false(ran)
  end)

  it("logs a check's refusal whose reason cannot be encoded, and still answers refused", function()
    local world = conformance.boot("mock")
    local core = world.core
    local json = core.json
    local manifest = conformance.manifest("acme_npcs")
    assert(world.api.addons.register(manifest, {}))
    world:install({ conformance.installed(core, manifest) })
    world:connect()
    world:activate(world:login(1, "00000002-0000-4000-8000-000000000002"))
    local real_admit, real_encode = core.targets.admit, core.handoff.encode
    core.targets.admit = function()
      return { type = "acme_npcs.thing", id = "one", position = { x = 0, y = 0, z = 0 }, distance = 0 }
    end
    assert(world.api.interactions.register("acme_npcs.use", function()
      return true
    end, { target = "acme_npcs.thing", check = function()
      -- The refusal's reason, then the answer, can be written only as the
      -- plain `refused`, as if the codec rejected anything else.
      core.handoff.encode = function(kind, fields)
        if fields.ok == false and fields.reason ~= "refused" then
          error("the codec refuses this")
        end
        return real_encode(kind, fields)
      end
      return false, "Not for you."
    end }))
    world.from_client(1, "rpf:interact", "1\n" .. assert(json.encode(json.object({ name = "acme_npcs.use", payload = json.object({}) }))))
    core.handoff.encode, core.targets.admit = real_encode, real_admit
    local answer
    for _, sent in ipairs(world.to_clients) do
      if sent.name == "rpf:interact" then
        answer = assert(json.decode(sent.payload:match("^%d+\n(.*)$")))
      end
    end
    local logged = world:logged("error", "acme_npcs.use refused with a reason that could not be read")
    world.finish()
    assert.are.equal("refused", answer.reason)
    assert.are.equal(1, logged)
  end)

  it("never gives back a newer registration's cooldown when a stale request gives its own back", function()
    local world = conformance.boot("mock")
    local core = world.core
    local json = core.json
    local manifest = conformance.manifest("acme_npcs")
    assert(world.api.addons.register(manifest, {}))
    world:install({ conformance.installed(core, manifest) })
    world:connect()
    world:activate(world:login(1, "00000002-0000-4000-8000-000000000002"))
    local real = core.targets.admit
    -- Every check but the target's own: the stub stands in for a record.
    core.targets.admit = function(...)
      local resolved, err = real(...)
      if resolved == nil and err ~= "not_found" then
        return nil, err
      end
      return { type = "acme_npcs.thing", id = "one", position = { x = 0, y = 0, z = 0 }, distance = 0 }
    end
    local sent = 0
    ---Sends `acme_npcs.use` from player 1's client and gives the answer.
    ---@return table answer The answer.
    local function use()
      sent = sent + 1
      local before = #world.to_clients
      world.from_client(1, "rpf:interact", sent .. "\n" .. assert(json.encode(json.object({ name = "acme_npcs.use", payload = json.object({}) }))))
      -- The last answer: one made while this request ran comes before it.
      for i = #world.to_clients, before + 1, -1 do
        if world.to_clients[i].name == "rpf:interact" then
          return assert(json.decode(world.to_clients[i].payload:match("^%d+\n(.*)$")))
        end
      end
      error("no answer")
    end
    ---@type table
    local replaced = {}
    local function replacement()
      return true
    end
    assert(world.api.interactions.register("acme_npcs.use", function()
      return true
    end, {
      target = "acme_npcs.thing",
      cooldown = 5000,
      check = function()
        -- As a check that yields might resume: meanwhile the interaction was
        -- replaced, and the replacement used, in the same millisecond.
        assert(world.api.interactions.register("acme_npcs.use", replacement, { target = "acme_npcs.thing", cooldown = 5000 }))
        replaced = use()
        return true
      end,
    }))
    local stale = use()
    local after = use()
    core.targets.admit = real
    world.finish()
    assert.is_true(replaced.ok)
    assert.are.equal("inactive", stale.reason)
    assert.are.equal("cooldown", after.reason, "the replacement's cooldown stands")
  end)

  it("keeps one use per player and interaction, however many there were", function()
    local world = conformance.boot("mock")
    local core = world.core
    local player = { player_id = "p", handle = 1, state = "active" }
    local rules = assert(core.targets.check_rules("acme_npcs", { cooldown = 10 }))
    for _ = 1, 3 do
      core.targets.reserve("acme_npcs.use", rules, player)
      world:advance(20)
    end
    local reservation = assert(core.targets.reserve("acme_npcs.use", rules, player))
    world.finish()
    assert.is_number(reservation.before, "a time, not the reservation before it")
  end)
end)
