-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Conformance (J3): the worked example, `lua/examples/acme_tags/`, run as it
-- ships on the mock platform and on the real FiveM and Gmod adapters,
-- against a fake portal (`spec/support/conformance.lua`). An addon RPF has
-- never heard of declares a type, registers an interaction a player's
-- client calls, keeps its records across a restart, and fades them on a
-- timer, through the public API alone. Its `mine` and `scrub` interactions
-- answer with data and resolve a client's id inside the player's scope
-- (J10), which a hostile client probes here on every engine. A tag is on the
-- map it was sprayed on (#369), and the upgrade that added that keeps every
-- older tag, which stays on every map.

local conformance = require("spec.support.conformance")
local support = require("spec.support")

---What `conformance.run` needs from busted.
local busted = { describe = describe, it = it, before_each = before_each, after_each = after_each }

local PLAYER = "00000002-0000-4000-8000-000000000002"
local OTHER = "00000003-0000-4000-8000-000000000003"
local OLD_TAG = "0000000c-0000-4000-8000-00000000000c"

---Loads the example's server half as an engine entry point does, and
---starts it on the world's API.
---@param world spec.ConformanceWorld The world.
---@param edit fun(tags: acme_tags)? Changes before it starts, such as an older release's manifest.
local function load_example(world, edit)
  rawset(_G, "acme_tags", nil)
  dofile(support.path("lua/examples/acme_tags/manifest.lua"))
  dofile(support.path("lua/examples/acme_tags/server.lua"))
  local tags = rawget(_G, "acme_tags")
  if edit then
    edit(tags)
  end
  assert(tags.start_server(world.api))
end

---Release 1.0.0: schema 1, before tags were on a map.
---@param tags acme_tags The example's table.
local function release_one(tags)
  local m = tags.MANIFEST
  m.version = "1.0.0"
  m.types.tag.schema = 1
  m.types.tag.fields.map = nil
  m.types.tag.world.map = nil
  -- 1.0.0's code knew nothing of maps either: its tags carry none.
  local spray = tags.spray
  tags.spray = function(rpf, player, payload)
    local records = setmetatable({
      create = function(type_, fields, opts)
        fields.map = nil
        return rpf.records.create(type_, fields, opts)
      end,
    }, { __index = rpf.records })
    return spray(setmetatable({ records = records }, { __index = rpf }), player, payload)
  end
end

---Connects, starts the example, has staff install it, and logs a player in
---standing at a wall.
---@param world spec.ConformanceWorld The world.
---@param edit fun(tags: acme_tags)? As for `load_example`.
---@return integer player The harness's number for the player.
local function sprayable(world, edit)
  load_example(world, edit)
  world:connect()
  world:install({ conformance.installed(world.core, rawget(_G, "acme_tags").MANIFEST) })
  world:pump()
  assert.are.equal("active", (world.api.addons.state("acme_tags")))
  world:login(1, PLAYER)
  world.place(1, { x = 10, y = 20, z = 30 })
  return 1
end

---How many requests the harness's clients have numbered.
local numbered = 0

---Sends an interaction from a player's client, as the client core encodes
---it and the platform frames a request (`<number>\n<body>`, which the mock,
---the FiveM fakes' `lib.callback` and the Gmod adapter share), and gives
---the server's answer.
---@param world spec.ConformanceWorld The world.
---@param player integer The player.
---@param name string? The interaction; nil with `raw`.
---@param payload table? Its payload.
---@param raw string? A body to send instead, as a hostile client might.
---@return table? answer The decoded answer, or nil if none came.
local function interact(world, player, name, payload, raw)
  local json = world.core.json
  local before = #world.to_clients
  local body = raw or assert(json.encode(json.object({ name = name, payload = payload and json.object(payload) or nil })))
  numbered = numbered + 1
  world.from_client(player, "rpf:interact", numbered .. "\n" .. body)
  for i = before + 1, #world.to_clients do
    local sent = world.to_clients[i]
    if sent.name == "rpf:interact" then
      local id, reply = sent.payload:match("^(%d+)\n(.*)$")
      assert.are.equal(tostring(numbered), id, "answered under the number it was asked with")
      return json.decode(reply)
    end
  end
  return nil
end

---Runs a function with `records.list` failing or `ui.notify` refusing, and
---`print` captured. The real API is frozen, so a table stands in front of it.
---@param world spec.ConformanceWorld The world.
---@param refuse { list: boolean?, notify: boolean? } What fails.
---@param fn fun(api: table, printed: string[]) The body: the API to hand the example, and what it printed.
local function failing(world, refuse, fn)
  local printed = {}
  local real = world.api
  local api = setmetatable({
    records = setmetatable({
      list = function(...)
        if refuse.list then
          return nil, "stopped"
        end
        return real.records.list(...)
      end,
    }, { __index = real.records }),
    ui = setmetatable({
      notify = function(handle, spec)
        if refuse.notify then
          return nil, "unavailable"
        end
        return real.ui.notify(handle, spec)
      end,
    }, { __index = real.ui }),
  }, { __index = real })
  local print_was = rawget(_G, "print")
  rawset(_G, "print", function(...)
    printed[#printed + 1] = table.concat({ ... }, " ")
  end)
  local ok, err = pcall(fn, api, printed)
  rawset(_G, "print", print_was)
  if not ok then
    error(err, 0)
  end
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
      assert.are.equal(world.api.world.map(), tags[1].fields.map, "on the map it was sprayed on")
      world:settle()
      assert.are.equal("hello", world.portal.records[tags[1].id].fields.text)
    end,
  },
  {
    name = "reads a tag on its map or on every map, and refuses one of another map as it refuses a missing one (#369)",
    run = function(world)
      local player = sprayable(world)
      world:activate(world.core.players.by_player_id(PLAYER).handle)
      local function tag(text, map)
        return assert(world.api.records.create("acme_tags.tag", {
          text = text,
          spot = { x = 10, y = 20, z = 30 },
          map = map,
          fades_at = world.api.time.now() + 60000,
        }, { owner = { kind = "player", id = PLAYER } }))
      end
      local here = tag("here", world.api.world.map())
      local everywhere = tag("everywhere", nil)
      local elsewhere = tag("elsewhere", "rp_elsewhere")
      for _, case in ipairs({ { here, true }, { everywhere, true }, { elsewhere, false } }) do
        local read = assert(interact(world, player, "acme_tags.read", { target = { id = case[1].id } }))
        if case[2] then
          assert.is_true(read.ok, case[1].fields.text .. ": " .. tostring(read.reason))
        else
          assert.are.same({ false, "not_found" }, { read.ok, read.reason }, case[1].fields.text)
        end
      end
    end,
  },
  {
    name = "keeps its tags through the upgrade that added map, which an older tag is on every map for",
    run = function(world)
      local player = sprayable(world, release_one)
      assert.is_true(assert(interact(world, player, "acme_tags.spray", { text = "from 1.0.0" })).ok)
      local old = world.api.records.list("acme_tags.tag")[1]
      assert.is_nil(old.fields.map, "release 1.0.0 has no map")
      -- Release 1.1.0 replaces the code, and staff install it.
      load_example(world)
      world:install({ conformance.installed(world.core, rawget(_G, "acme_tags").MANIFEST) })
      world:pump()
      assert.are.equal("active", (world.api.addons.state("acme_tags")))
      local upgraded = assert(world.api.records.get("acme_tags.tag", old.id), "still held across the reload")
      assert.is_nil(upgraded.fields.map, "none: it stays on every map")
      assert.are.equal("from 1.0.0", upgraded.fields.text)
      world:activate(world.core.players.by_player_id(PLAYER).handle)
      local read = assert(interact(world, player, "acme_tags.read", { target = { id = old.id } }))
      assert.is_true(read.ok, tostring(read.reason))
      assert.is_true(assert(interact(world, player, "acme_tags.spray", { text = "from 1.1.0" })).ok)
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
    name = "refuses a client that has not logged in, and one that sends too many, running nothing",
    run = function(world)
      local player = sprayable(world)
      world.join(2)
      local early = assert(interact(world, 2, "acme_tags.spray", { text = "hi" }))
      assert.are.same({ false, "not_logged_in" }, { early.ok, early.reason })
      for _ = 1, 20 do
        interact(world, player, "acme_tags.paint", {})
      end
      local flood = assert(interact(world, player, "acme_tags.spray", { text = "hi" }))
      assert.are.same({ false, "too_many" }, { flood.ok, flood.reason })
      assert.are.equal(0, #world.api.records.list("acme_tags.tag"))
      world:advance(10000)
      assert.is_true(assert(interact(world, player, "acme_tags.spray", { text = "hi" })).ok)
    end,
  },
  {
    name = "reads a tag the player stands at, aimed by its id, and refuses one out of reach (J4)",
    run = function(world)
      local player = sprayable(world)
      world:activate(world.core.players.by_player_id(PLAYER).handle)
      assert.is_true(assert(interact(world, player, "acme_tags.spray", { text = "hello" })).ok)
      local id = assert(interact(world, player, "acme_tags.mine")).data.tags[1].id
      local read = assert(interact(world, player, "acme_tags.read", { target = { id = id } }))
      assert.is_true(read.ok, tostring(read.reason))
      assert.are.equal("hello", read.data.text)
      local shown = false
      for _, sent in ipairs(world.to_clients) do
        if sent.name == "rpf:ui_notify" and sent.payload:find("hello", 1, true) then
          shown = true
        end
      end
      assert.is_true(shown, "the text is shown to the player")
      world.place(1, { x = 10 + world:units(40), y = 20, z = 30 })
      local far = assert(interact(world, player, "acme_tags.read", { target = { id = id } }))
      assert.are.same({ false, "too_far" }, { far.ok, far.reason })
    end,
  },
  {
    name = "reads a tag two metres off, since its reach is metres on every engine (J3)",
    run = function(world)
      local player = sprayable(world)
      world:activate(world.core.players.by_player_id(PLAYER).handle)
      assert.is_true(assert(interact(world, player, "acme_tags.spray", { text = "near" })).ok)
      local id = assert(interact(world, player, "acme_tags.mine")).data.tags[1].id
      world.place(1, { x = 10 + world:units(2), y = 20, z = 30 })
      local read = assert(interact(world, player, "acme_tags.read", { target = { id = id } }))
      assert.is_true(read.ok, tostring(read.reason))
    end,
  },
  {
    name = "tells a player whose tags cannot be listed why, and logs the error (J3)",
    run = function(world)
      sprayable(world)
      failing(world, { list = true }, function(api, printed)
        ---@diagnostic disable-next-line: missing-fields
        local ok, reason = rawget(_G, "acme_tags").mine(api, { player_id = PLAYER })
        assert.are.same({ false, "Your tags cannot be listed now (stopped)." }, { ok, reason })
        assert.is_truthy(printed[#printed] and printed[#printed]:find("could not list", 1, true), "the lost list is logged")
      end)
    end,
  },
  {
    name = "logs a read whose notice the engine refused, and still answers the text (J3)",
    run = function(world)
      sprayable(world)
      failing(world, { notify = true }, function(api, printed)
        ---@diagnostic disable-next-line: missing-fields
        local ok, data = rawget(_G, "acme_tags").read(api, { player_id = PLAYER, handle = 1 }, { record = { fields = { text = "hello" } } })
        assert.are.same({ true, { text = "hello" } }, { ok, data })
        assert.is_truthy(printed[#printed] and printed[#printed]:find("could not show", 1, true), "the lost notice is logged")
      end)
    end,
  },
  {
    name = "answers a player's own tags as data, and refuses another's id as it refuses a missing one",
    run = function(world)
      local player = sprayable(world)
      world:login(2, OTHER)
      local other = 2
      world.place(other, { x = 1, y = 2, z = 3 })
      assert.is_true(assert(interact(world, player, "acme_tags.spray", { text = "mine" })).ok)
      assert.is_true(assert(interact(world, other, "acme_tags.spray", { text = "theirs" })).ok)
      local listed = assert(interact(world, player, "acme_tags.mine"))
      assert.is_true(listed.ok)
      assert.are.equal(1, #listed.data.tags)
      assert.are.equal("mine", listed.data.tags[1].text)
      local mine = listed.data.tags[1].id
      local theirs = assert(interact(world, other, "acme_tags.mine")).data.tags[1].id
      world:settle()
      local before = #world.portal.frames

      local refusals = {}
      for _, id in ipairs({ theirs, "00000000-0000-4000-8000-0000000000ff", 42 }) do
        local answer = assert(interact(world, player, "acme_tags.scrub", { id = id }))
        assert.is_false(answer.ok)
        refusals[#refusals + 1] = answer.reason
      end
      assert.are.same({ "No such tag of yours.", "No such tag of yours.", "No such tag of yours." }, refusals, "another's, missing and garbage alike")
      world:settle()
      assert.are.equal(2, #world.api.records.list("acme_tags.tag"), "nothing deleted")
      assert.are.equal(before, #world.portal.frames, "nothing reported")

      assert.is_true(assert(interact(world, player, "acme_tags.scrub", { id = mine })).ok)
      local again = assert(interact(world, player, "acme_tags.scrub", { id = mine }))
      assert.are.same({ false, "No such tag of yours." }, { again.ok, again.reason }, "a deleted tag is not there")
      assert.are.same({ "theirs" }, { world.api.records.list("acme_tags.tag")[1].fields.text })
    end,
  },
  {
    name = "has the core claim its tags again a minute later when the portal refused the claim at start",
    run = function(world)
      world.portal.records[OLD_TAG] = {
        id = OLD_TAG,
        type = "acme_tags.tag",
        owner = { kind = "player", id = PLAYER },
        revision = 3,
        fields = { text = "old", spot = { x = 0, y = 0, z = 0 }, fades_at = 10 * 24 * 60 * 60 * 1000 },
        held = false,
      }
      world.portal.refuse = { hold = "retry" }
      sprayable(world)
      assert.are.equal(0, #world.api.records.list("acme_tags.tag"))
      world.portal.refuse = nil
      world:advance(world.core.holding.CLAIM_MS)
      world:pump()
      assert.are.equal(1, #world.api.records.list("acme_tags.tag"), "held by the next claim")
      local claims = 0
      for _, frame in ipairs(world.portal.frames) do
        if frame.type == "hold" and frame.types then
          claims = claims + 1
          assert.are.same({ "acme_tags.tag" }, frame.types)
        end
      end
      assert.is_true(claims >= 2, "claimed at start and again")
    end,
  },
  {
    name = "answers a long reason whole characters at a time, and a name no addon could have as unknown",
    run = function(world)
      local player = sprayable(world)
      world.api.interactions.register("acme_tags.euros", function()
        return false, string.rep("€", 50)
      end)
      local answer = assert(interact(world, player, "acme_tags.euros", {}))
      assert.is_false(answer.ok)
      assert.are.equal(string.rep("€", 42), answer.reason, "128 bytes is 42 whole euro signs")
      for _, name in ipairs({ "Acme Tags!", string.rep("a", 60) .. "." .. string.rep("b", 10) }) do
        local answer_to = assert(interact(world, player, name, {}))
        assert.are.same({ false, "unknown" }, { answer_to.ok, answer_to.reason }, name)
      end
      local garbled = assert(interact(world, player, nil, nil, "not json"))
      assert.are.same({ false, "invalid" }, { garbled.ok, garbled.reason })
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
