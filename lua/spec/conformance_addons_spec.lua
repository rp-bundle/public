-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Conformance (J3): the addon lifecycle through the public API, the same
-- cases on the mock platform and on the real FiveM and Gmod adapters
-- (`spec/support/conformance.lua`). An addon registers, runs only once the
-- portal installs it, is reloaded by registering again, and what its code
-- set up (timers, event handlers, exports) goes when it stops. Nothing
-- throws across the API.

local conformance = require("spec.support.conformance")

---Handlers that log what the core ran.
---@param name string Which addon, for the log.
---@param ran string[] The log.
---@return table handlers The handlers.
local function recording(name, ran)
  return {
    start = function()
      ran[#ran + 1] = "start " .. name
    end,
    stop = function(reason)
      ran[#ran + 1] = "stop " .. name .. " (" .. tostring(reason) .. ")"
    end,
  }
end

---What `conformance.run` needs from busted.
local busted = { describe = describe, it = it, before_each = before_each, after_each = after_each }

conformance.run(busted, "the addon lifecycle", {
  {
    name = "serves addon API 1 as a range",
    run = function(world)
      assert.are.equal(1, world.api.addons.API)
      assert.are.equal(1, world.api.addons.API_MIN)
    end,
  },
  {
    name = "refuses a manifest with the rule it breaks, without throwing",
    run = function(world)
      local bad = conformance.manifest("acme_tags")
      bad.version = "1"
      local ok, refusal = world.api.addons.register(bad)
      assert.is_nil(ok)
      assert.are.same({ error = "version", path = "version" }, refusal)
      ok, refusal = world.api.addons.register(nil)
      assert.is_nil(ok)
      assert.are.equal("wrong_type", refusal.error)
      assert.is_nil(world.api.addons.state("acme_tags"))
    end,
  },
  {
    name = "refuses handlers that are not handlers, naming which",
    run = function(world)
      local m = conformance.manifest("acme_tags")
      local ok, refusal = world.api.addons.register(m, { strat = function() end })
      assert.is_nil(ok)
      assert.are.same({ error = "handler", path = "handlers.strat" }, refusal)
      ok, refusal = world.api.addons.register(m, { start = 42 })
      assert.is_nil(ok)
      assert.are.same({ error = "handler", path = "handlers.start" }, refusal)
      ok, refusal = world.api.addons.register(m, "start")
      assert.is_nil(ok)
      assert.are.same({ error = "handlers", path = "handlers" }, refusal)
    end,
  },
  {
    name = "runs an addon only once the portal installs and enables exactly its manifest",
    run = function(world)
      local ran, states = {}, {}
      world.api.events.on("addons.state", function(change)
        states[#states + 1] = change.namespace .. " " .. change.state
      end)
      local m = conformance.manifest("acme_tags")
      assert.is_true(world.api.addons.register(m, recording("acme_tags", ran)))
      assert.are.equal("not_installed", (world.api.addons.state("acme_tags")))
      assert.are.same({}, ran)
      world:install({ conformance.installed(world.core, m) })
      assert.are.equal("active", (world.api.addons.state("acme_tags")))
      world:install({ conformance.installed(world.core, m, false) })
      local state, reason = world.api.addons.state("acme_tags")
      assert.are.equal("disabled", state)
      assert.are.equal("string", type(reason))
      assert.are.same({ "start acme_tags", "stop acme_tags (staff disabled it in the portal)" }, ran)
      assert.are.same({ "acme_tags not_installed", "acme_tags active", "acme_tags disabled" }, states)
    end,
  },
  {
    name = "reloads an addon registered again with the same manifest: the old code stops, the new starts",
    run = function(world)
      local ran = {}
      local m = conformance.manifest("acme_tags")
      world.api.addons.register(m, recording("old", ran))
      world:install({ conformance.installed(world.core, m) })
      world.api.addons.register(m, recording("new", ran))
      assert.are.same({ "start old", "stop old (the addon registered again)", "start new" }, ran)
      assert.are.equal("active", (world.api.addons.state("acme_tags")))
    end,
  },
  {
    name = "keeps a start handler's throw to the addon: it is failed, and the others run",
    run = function(world)
      local ran = {}
      local bad, good = conformance.manifest("acme_bad"), conformance.manifest("acme_good")
      world.api.addons.register(bad, {
        start = function()
          error("boom")
        end,
      })
      world.api.addons.register(good, recording("acme_good", ran))
      world:install({ conformance.installed(world.core, bad), conformance.installed(world.core, good) })
      assert.are.equal("failed", (world.api.addons.state("acme_bad")))
      assert.are.equal("active", (world.api.addons.state("acme_good")))
      assert.are.same({ "start acme_good" }, ran)
      assert.are.equal(1, world:logged("error", "the start handler of acme_bad failed"))
    end,
  },
  {
    name = "runs a timer an addon starts, and cancels it when the addon stops, so a restart has one",
    run = function(world)
      local ticks = 0
      local m = conformance.manifest("acme_tags")
      world.api.addons.register(m, {
        start = function()
          assert(world.api.time.every(1000, function()
            ticks = ticks + 1
          end))
        end,
      })
      world:install({ conformance.installed(world.core, m) })
      world:advance(3000)
      assert.are.equal(3, ticks)
      world:install({ conformance.installed(world.core, m, false) })
      world:advance(3000)
      assert.are.equal(3, ticks, "a disabled addon's timer is gone")
      world:install({ conformance.installed(world.core, m) })
      world:advance(2000)
      assert.are.equal(5, ticks, "one timer after the restart, not two")
    end,
  },
  {
    name = "gives timers a clock, a one-off, a cancel, and refusals rather than throws",
    run = function(world)
      local time = world.api.time
      assert.are.equal(world.time, time.now())
      local fired = 0
      local id = assert(time.after(500, function()
        fired = fired + 1
      end))
      assert.are.equal("string", type(id))
      local cancelled = assert(time.after(500, function()
        fired = fired + 100
      end))
      assert.is_true(time.cancel(cancelled))
      assert.is_false(time.cancel(cancelled))
      world:advance(500)
      assert.are.equal(1, fired)
      assert.are.same({ nil, "invalid" }, { time.after(-1, function() end) })
      assert.are.same({ nil, "invalid" }, { time.every(1, function() end) })
      assert.are.same({ nil, "invalid" }, { time.every(1000, "fade") })
      assert.are.same({ nil, "invalid" }, { time.after(1.5, function() end) })
    end,
  },
  {
    name = "measures time since a stored moment, bounded, and never backwards",
    run = function(world)
      local time = world.api.time
      local now = time.now()
      assert.are.same({ 1500, now }, { time.elapsed(now - 1500) })
      assert.are.same({ 1000, now }, { time.elapsed(now - 1500, 1000) }, "a bounded catch-up")
      assert.are.same({ 0, now }, { time.elapsed(now + 60000) }, "a clock stepped back counts as nothing")
      assert.are.same({ 0, now }, { time.elapsed(now - 1500, 0) })
      for _, bad in ipairs({ { "1" }, { 1.5 }, { now, -1 }, { now, 2.5 }, { nil } }) do
        assert.are.same({ nil, "invalid" }, { time.elapsed(bad[1], bad[2]) })
      end
    end,
  },
  {
    name = "keeps a timer that throws going, and logs it",
    run = function(world)
      local ticks = 0
      world.api.time.every(1000, function()
        ticks = ticks + 1
        error("tick")
      end)
      world:advance(2000)
      assert.are.equal(2, ticks)
      assert.are.equal(2, world:logged("error", "a timer failed"))
    end,
  },
  {
    name = "removes an event handler an addon subscribed while it ran when it stops",
    run = function(world)
      local heard = 0
      local m = conformance.manifest("acme_tags")
      world.api.addons.register(m, {
        start = function()
          world.api.events.on("scripts.ping", function()
            heard = heard + 1
          end)
        end,
      })
      world:install({ conformance.installed(world.core, m) })
      world.api.events.emit("scripts.ping")
      world:install({ conformance.installed(world.core, m, false) })
      world.api.events.emit("scripts.ping")
      world:install({ conformance.installed(world.core, m) })
      world.api.events.emit("scripts.ping")
      assert.are.equal(2, heard)
    end,
  },
  {
    name = "answers events with refusals, not throws",
    run = function(world)
      local events = world.api.events
      assert.are.same({ nil, "reserved" }, { events.emit("addons.state", {}) })
      assert.are.same({ nil, "invalid" }, { events.emit("") })
      assert.are.same({ nil, "invalid" }, { events.on("scripts.ping", 42) })
      assert.are.same({ nil, "invalid" }, { events.on(nil, function() end) })
      assert.is_false(events.off("scripts.ping", "nothing"))
    end,
  },
  {
    name = "refuses an addon's code emitting under another active addon's namespace",
    run = function(world)
      local results = {}
      local a, b = conformance.manifest("acme_alpha"), conformance.manifest("acme_beta")
      world.api.addons.register(a)
      world:as("beta").addons.register(b, {
        start = function()
          local api = world:as("beta")
          results.own = { api.events.emit("acme_beta.ready") }
          results.other = { api.events.emit("acme_alpha.ready") }
        end,
      })
      world:install({ conformance.installed(world.core, a), conformance.installed(world.core, b) })
      assert.are.same({ 0 }, results.own)
      assert.are.same({ nil, "forbidden" }, results.other)
    end,
  },
  {
    name = "shares functions between addons by namespaced name, only while the provider is active",
    run = function(world)
      local core_m = conformance.manifest("acme_core")
      local api = world.api
      api.addons.register(core_m, {
        start = function()
          assert(api.addons.provide("acme_core.double", function(n)
            return n * 2, "doubled"
          end))
          assert(api.addons.provide("acme_core.broken", function()
            error("broken")
          end))
        end,
      })
      local other = world:as("other")
      assert.are.same({ false, "not_found" }, { other.addons.call("acme_core.double", 2) })
      world:install({ conformance.installed(world.core, core_m) })
      assert.are.same({ true, 4, "doubled" }, { other.addons.call("acme_core.double", 2) })
      assert.are.same({ false, "failed" }, { other.addons.call("acme_core.broken") })
      assert.are.equal(1, world:logged("error", "the export acme_core.broken failed"))
      assert.are.same({ nil, "invalid" }, { api.addons.provide("nonsense", function() end) })
      assert.are.same({ nil, "not_found" }, { api.addons.provide("acme_none.f", function() end) })
      world:install({ conformance.installed(world.core, core_m, false) })
      assert.are.same({ false, "not_found" }, { other.addons.call("acme_core.double", 2) }, "taken down with its addon")
    end,
  },
  {
    name = "refuses an addon's code providing under another addon's namespace",
    run = function(world)
      local a, b = conformance.manifest("acme_alpha"), conformance.manifest("acme_beta")
      local got
      world.api.addons.register(a)
      world:as("beta").addons.register(b, {
        start = function()
          got = { world:as("beta").addons.provide("acme_alpha.steal", function() end) }
        end,
      })
      world:install({ conformance.installed(world.core, a), conformance.installed(world.core, b) })
      assert.are.same({ nil, "forbidden" }, got)
    end,
  },
  {
    name = "unloads a resource's addons when it stops, with everything its code set up",
    origins = true,
    run = function(world)
      local ticks, heard, ran = 0, 0, {}
      local api = world:as("acme_res")
      local m = conformance.manifest("acme_tags")
      api.addons.register(m, recording("acme_tags", ran))
      -- Set up outside any handler: owned by the resource, not the addon.
      api.time.every(1000, function()
        ticks = ticks + 1
      end)
      api.events.on("scripts.ping", function()
        heard = heard + 1
      end)
      world:install({ conformance.installed(world.core, m) })
      world:unload("acme_res")
      assert.is_nil(world.api.addons.state("acme_tags"))
      assert.are.same({ "start acme_tags" }, ran, "a stopped resource's handlers are not called")
      world:advance(5000)
      world.api.events.emit("scripts.ping")
      assert.are.equal(0, ticks)
      assert.are.equal(0, heard)
    end,
  },
  {
    name = "keeps a subscription's id when off names the wrong event, and drops it with its resource",
    origins = true,
    run = function(world)
      local api = world:as("acme_res")
      local heard = 0
      local id = assert(api.events.on("scripts.ping", function()
        heard = heard + 1
      end))
      assert.is_false(api.events.off("scripts.pong", id))
      assert.is_true(api.events.off("scripts.ping", id), "the id still works")
      local again = assert(api.events.on("scripts.ping", function()
        heard = heard + 1
      end))
      world:unload("acme_res")
      world.api.events.emit("scripts.ping")
      assert.are.equal(0, heard)
      assert.is_false(api.events.off("scripts.ping", again), "gone with its resource")
    end,
  },
  {
    name = "refuses another resource emitting under an addon's namespace, outside any handler",
    origins = true,
    run = function(world)
      local m = conformance.manifest("acme_tags")
      world:as("acme_res").addons.register(m)
      assert.are.same({ 0 }, { world:as("acme_res").events.emit("acme_tags.sprayed") })
      assert.are.same({ nil, "forbidden" }, { world:as("vandal").events.emit("acme_tags.sprayed") })
    end,
  },
})
