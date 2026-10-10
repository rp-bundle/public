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
end)
