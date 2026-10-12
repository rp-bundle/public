-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Conformance (J7): the walkthrough's addon, `lua/examples/acme_notes/`, run
-- as it ships on the mock platform and on the real FiveM and Gmod adapters,
-- against a fake portal (`spec/support/conformance.lua`). Every step
-- `docs/writing-addons.md`'s walkthrough promises is a case here: a note
-- pinned where the player stands and placed in the world, refused when the
-- payload is not a note, read from within reach in the engine's own units,
-- taken down by its author only, removed by linked staff holding the
-- addon's permission, a stale delete read again and retried, and every note
-- kept across the upgrades that added `colour` and `map`, and shown only on
-- the map they were pinned on.

local conformance = require("spec.support.conformance")
local support = require("spec.support")

---What `conformance.run` needs from busted.
local busted = { describe = describe, it = it, before_each = before_each, after_each = after_each }

local PLAYER = "00000002-0000-4000-8000-000000000002"
local OTHER = "00000003-0000-4000-8000-000000000003"
local TYPE = "acme_notes.note"

---How long a placement may take to arrive: FiveM makes an entity
---asynchronously.
local SETTLE_MS = 500

---Loads the example's server half as an engine entry point does, with its
---manifest as `edit` leaves it, and starts it on the world's API.
---@param world spec.ConformanceWorld The world.
---@param edit fun(notes: acme_notes)? Changes before it starts, such as an older release's manifest.
---@return acme_notes notes The example's table.
local function load_example(world, edit)
  rawset(_G, "acme_notes", nil)
  dofile(support.path("lua/examples/acme_notes/manifest.lua"))
  dofile(support.path("lua/examples/acme_notes/server.lua"))
  local notes = rawget(_G, "acme_notes")
  -- The mock engine's model, beside FiveM's and Gmod's, so a note is placed
  -- on every platform the cases run on.
  notes.MANIFEST.types.note.fields.model.default.mock = "mock_note"
  if edit then
    edit(notes)
  end
  assert(notes.start_server(world.api))
  return notes
end

---Release 1.1.0, the walkthrough's second: schema 2, before notes were on a
---map.
---@param notes acme_notes The example's table.
local function release_two(notes)
  local m = notes.MANIFEST
  m.version = "1.1.0"
  m.types.note.schema = 2
  m.types.note.fields.map = nil
  m.types.note.world.map = nil
  -- 1.1.0's code knew nothing of maps either: its notes carry none.
  local pin = notes.pin
  notes.pin = function(rpf, player, payload)
    local records = setmetatable({
      create = function(type_, fields, opts)
        fields.map = nil
        return rpf.records.create(type_, fields, opts)
      end,
    }, { __index = rpf.records })
    return pin(setmetatable({ records = records }, { __index = rpf }), player, payload)
  end
end

---Release 1.0.0, the walkthrough's first: schema 1, before notes had a colour.
---@param notes acme_notes The example's table.
local function release_one(notes)
  release_two(notes)
  local m = notes.MANIFEST
  m.version = "1.0.0"
  m.types.note.schema = 1
  m.types.note.fields.colour = nil
  m.types.note.list = { "text", "pinned_at" }
end

---Connects, starts the example, has staff install it, and logs a player in,
---in the world.
---@param world spec.ConformanceWorld The world.
---@param edit fun(notes: acme_notes)? As for `load_example`.
local function ready(world, edit)
  local notes = load_example(world, edit)
  world:connect()
  world:install({ conformance.installed(world.core, notes.MANIFEST) })
  world:pump()
  assert.are.equal("active", (world.api.addons.state("acme_notes")))
  world:activate(world:login(1, PLAYER))
  world.place(1, { x = 10, y = 20, z = 30 })
end

---How many requests the harness's clients have numbered.
local numbered = 0

---Sends an interaction from a player's client and gives the server's
---answer (as `conformance_acme_tags_spec.lua` does).
---@param world spec.ConformanceWorld The world.
---@param player integer The player.
---@param name string The interaction.
---@param payload table? Its payload.
---@return table answer The decoded answer.
local function interact(world, player, name, payload)
  local json = world.core.json
  local before = #world.to_clients
  local body = assert(json.encode(json.object({ name = name, payload = payload and json.object(payload) or nil })))
  numbered = numbered + 1
  world.from_client(player, "rpf:interact", numbered .. "\n" .. body)
  for i = before + 1, #world.to_clients do
    local sent = world.to_clients[i]
    if sent.name == "rpf:interact" then
      local _, reply = sent.payload:match("^(%d+)\n(.*)$")
      return assert(json.decode(reply))
    end
  end
  error("no answer to " .. name)
end

---Pins a note for player 1 and gives it.
---@param world spec.ConformanceWorld The world.
---@param payload table? The payload; a note saying "meet here" otherwise.
---@return rpf.Record note The note.
local function pinned(world, payload)
  local answer = interact(world, 1, "acme_notes.pin", payload or { text = "meet here" })
  assert.is_true(answer.ok, tostring(answer.reason))
  local notes = assert(world.api.records.list(TYPE, { order = "pinned_at" }))
  world:settle()
  return notes[#notes]
end

---What the interaction menu offers a player where they stand, as
---`<name> <record id>`.
---@param world spec.ConformanceWorld The world.
---@param player integer The player.
---@return table<string, true> offered The options.
local function offered(world, player)
  local json = world.core.json
  local before = #world.to_clients
  numbered = numbered + 1
  world.from_client(player, "rpf:targets", numbered .. "\n{}")
  local out = {}
  for i = before + 1, #world.to_clients do
    local sent = world.to_clients[i]
    if sent.name == "rpf:targets" then
      for _, option in ipairs(json.decode((sent.payload:match("^%d+\n(.*)$"))).options) do
        out[option.name .. " " .. option.id] = true
      end
    end
  end
  return out
end

---Aims an interaction at a note.
---@param world spec.ConformanceWorld The world.
---@param player integer The player.
---@param name string The interaction.
---@param id string The note.
---@return table answer The answer.
local function at(world, player, name, id)
  return interact(world, player, name, { target = { id = id } })
end

conformance.run(busted, "the acme_notes example", {
  {
    name = "pins a note where the player stands and places it in the world; the portal keeps it",
    run = function(world)
      ready(world)
      local note = pinned(world, { text = "meet here", colour = "yellow" })
      assert.are.same({ x = 10, y = 20, z = 30 }, note.fields.spot)
      assert.are.equal("yellow", note.fields.colour)
      assert.are.same({ kind = "player", id = PLAYER }, note.owner)
      world:advance(SETTLE_MS)
      assert.is_truthy(world.api.world.placed(TYPE, note.id), "placed as an object while held")
      world:settle()
      assert.are.equal("meet here", world.portal.records[note.id].fields.text)
    end,
  },
  {
    name = "refuses what is not a note, with a reason the player can read, and makes nothing",
    run = function(world)
      ready(world)
      local empty = interact(world, 1, "acme_notes.pin", { text = "" })
      assert.are.same({ false, "Write something on the note." }, { empty.ok, empty.reason })
      local long = interact(world, 1, "acme_notes.pin", { text = string.rep("x", 121) })
      assert.are.same({ false, "Not that note (text: too_long)." }, { long.ok, long.reason })
      local colour = interact(world, 1, "acme_notes.pin", { text = "hi", colour = "plaid" })
      assert.is_false(colour.ok)
      assert.truthy(colour.reason:find("colour", 1, true), colour.reason)
      assert.are.equal(0, #world.api.records.list(TYPE))
      for i = 1, 3 do
        pinned(world, { text = "note " .. i })
      end
      local fourth = interact(world, 1, "acme_notes.pin", { text = "one too many" })
      assert.are.same({ false, "Take one of your notes down first." }, { fourth.ok, fourth.reason })
    end,
  },
  {
    name = "reads a note from a step away on every engine, in the engine's own units",
    run = function(world)
      ready(world)
      local notes = rawget(_G, "acme_notes")
      local note = pinned(world, { text = "meet here" })
      world.place(1, { x = 10 + world:units(1.5), y = 20, z = 30 })
      local read = at(world, 1, "acme_notes.read", note.id)
      assert.is_true(read.ok)
      assert.are.same({ text = "meet here", colour = "white" }, read.data)
      world.place(1, { x = 10 + world:units(3), y = 20, z = 30 })
      local far = at(world, 1, "acme_notes.read", note.id)
      assert.are.same({ false, "too_far" }, { far.ok, far.reason })
    end,
  },
  {
    name = "lets only its author take a note down, and linked staff with the permission remove anyone's",
    run = function(world)
      ready(world)
      world:activate(world:login(2, OTHER))
      world.place(2, { x = 10, y = 21, z = 30 })
      local note = pinned(world)
      assert.is_true(offered(world, 1)["acme_notes.take_down " .. note.id], "the menu offers its author to take it down")
      assert.is_nil(offered(world, 2)["acme_notes.take_down " .. note.id], "and nobody else")
      assert.is_true(offered(world, 2)["acme_notes.read " .. note.id], "who may still read it")
      local theirs = at(world, 2, "acme_notes.take_down", note.id)
      assert.are.same({ false, "That note is not yours." }, { theirs.ok, theirs.reason })
      local unlinked = at(world, 2, "acme_notes.remove", note.id)
      assert.are.same({ false, "forbidden" }, { unlinked.ok, unlinked.reason })
      local json = world.core.json
      assert(world.core.staff.apply(json.array({
        json.object({ player_id = OTHER, permissions = json.array({ "addon.acme_notes.moderate" }) }),
      })))
      assert.is_true(at(world, 2, "acme_notes.remove", note.id).ok, "a linked staff member holding the flag")
      assert.is_nil(world.api.records.get(TYPE, note.id))
      world:settle()
      assert.is_nil(world.portal.records[note.id], "the portal deleted it too")

      local own = pinned(world)
      assert.is_true(at(world, 1, "acme_notes.take_down", own.id).ok, "its author")
      assert.is_nil(world.api.records.get(TYPE, own.id))
      -- Sent again, as a client does when the first answer was lost: the
      -- note no longer resolves, so the rules refuse it before the handler.
      local again = at(world, 1, "acme_notes.take_down", own.id)
      assert.are.same({ false, "not_found" }, { again.ok, again.reason })
    end,
  },
  {
    name = "pins a note on the map the server runs, and places and offers it only there",
    run = function(world)
      ready(world)
      local here = assert(world.api.world.map())
      local note = pinned(world)
      assert.are.equal(here, note.fields.map, "the map is set in game, never by the client")
      -- A note of another map, as a server running on it left it.
      local other = assert(world.api.records.create(TYPE, {
        text = "from elsewhere",
        spot = { x = 10, y = 20, z = 30 },
        map = "rp_elsewhere",
        pinned_at = world.api.time.now(),
      }, { owner = { kind = "player", id = PLAYER } }))
      world:advance(SETTLE_MS)
      assert.is_truthy(world.api.world.placed(TYPE, note.id), "placed on its map")
      assert.is_nil(world.api.world.placed(TYPE, other.id), "not placed on another")
      local menu = offered(world, 1)
      assert.is_true(menu["acme_notes.read " .. note.id])
      assert.is_nil(menu["acme_notes.read " .. other.id], "not offered either")
      local read = at(world, 1, "acme_notes.read", other.id)
      assert.are.same({ false, "not_found" }, { read.ok, read.reason }, "nor can a client name it")
    end,
  },
  {
    name = "keeps its notes through the upgrade that added map, which an older note is on every map for",
    run = function(world)
      ready(world, release_two)
      local note = pinned(world, { text = "from 1.1.0" })
      assert.is_nil(note.fields.map, "release 1.1.0 has no map")
      -- Release 1.2.0 replaces the code, and staff install it.
      local notes = load_example(world)
      world:install({ conformance.installed(world.core, notes.MANIFEST) })
      world:pump()
      assert.are.equal("active", (world.api.addons.state("acme_notes")))
      local upgraded = assert(world.api.records.get(TYPE, note.id), "still held across the reload")
      assert.is_nil(upgraded.fields.map, "none: it stays on every map")
      assert.are.equal("from 1.1.0", upgraded.fields.text)
      world:advance(SETTLE_MS)
      assert.is_truthy(world.api.world.placed(TYPE, note.id), "and still placed")
      assert.is_true(offered(world, 1)["acme_notes.read " .. note.id])
      local newer = pinned(world, { text = "from 1.2.0" })
      assert.are.equal(world.api.world.map(), newer.fields.map, "a new one is on the map it is pinned on")
    end,
  },
  {
    name = "keeps its notes through the upgrade that added colour, which an older note reads as white",
    run = function(world)
      ready(world, release_one)
      local note = pinned(world, { text = "from 1.0.0" })
      assert.is_nil(note.fields.colour, "release 1.0.0 has no colour")
      -- Release 1.1.0 replaces the code, and staff install it.
      local notes = load_example(world)
      world:install({ conformance.installed(world.core, notes.MANIFEST) })
      world:pump()
      assert.are.equal("active", (world.api.addons.state("acme_notes")))
      local upgraded = assert(world.api.records.get(TYPE, note.id), "still held across the reload")
      assert.are.equal("white", upgraded.fields.colour, "the new field's default")
      assert.are.equal("from 1.0.0", upgraded.fields.text)
    end,
  },
})

describe("acme_notes.take_down", function()
  before_each(function()
    rawset(_G, "acme_notes", nil)
    dofile(support.path("lua/examples/acme_notes/manifest.lua"))
    dofile(support.path("lua/examples/acme_notes/server.lua"))
  end)

  local player = { player_id = PLAYER }

  ---A note at a revision.
  ---@param revision integer The revision.
  ---@param owner string? Its author.
  ---@return table note The note.
  local function note(revision, owner)
    return { id = "n1", revision = revision, owner = { kind = "player", id = owner or PLAYER }, fields = {} }
  end

  ---A fake API whose deletes answer from a list, and whose reads give `now`.
  ---@param answers table[] Each delete's answer, in turn.
  ---@param now table? What a read finds.
  ---@return table rpf The fake.
  ---@return table deletes The revisions each delete named.
  local function fake(answers, now)
    local deletes = {}
    return {
      records = {
        delete = function(_, _, opts)
          deletes[#deletes + 1] = opts.revision
          local answer = table.remove(answers, 1)
          return answer[1], answer[2]
        end,
        get = function()
          return now
        end,
      },
    },
      deletes
  end

  it("reads a note changed since again, checks it again, and deletes it at its new revision", function()
    local rpf, deletes = fake({ { nil, "stale" }, { true } }, note(5))
    assert.are.same({ true }, { rawget(_G, "acme_notes").take_down(rpf, player, note(4), false) })
    assert.are.same({ 4, 5 }, deletes)
  end)

  it("says a note that went meanwhile is gone, whether it was changed first or not", function()
    local take_down = rawget(_G, "acme_notes").take_down
    assert.are.same({ false, "That note is gone." }, { take_down(fake({ { nil, "not_held" } }, nil), player, note(4), false) })
    assert.are.same({ false, "That note is gone." }, { take_down(fake({ { nil, "stale" } }, nil), player, note(4), false) })
  end)

  it("checks again after reading: a note that changed hands is refused", function()
    local rpf, deletes = fake({ { nil, "stale" } }, note(5, OTHER))
    assert.are.same({ false, "That note is not yours." }, { rawget(_G, "acme_notes").take_down(rpf, player, note(4), false) })
    assert.are.same({ 4 }, deletes)
  end)

  it("gives up after a second stale read, and says so", function()
    local rpf = fake({ { nil, "stale" }, { nil, "stale" } }, note(5))
    assert.are.same(
      { false, "Someone is changing it; try again." },
      { rawget(_G, "acme_notes").take_down(rpf, player, note(4), false) }
    )
  end)
end)

describe("acme_notes.ask_pin", function()
  before_each(function()
    rawset(_G, "acme_notes", nil)
    dofile(support.path("lua/examples/acme_notes/client.lua"))
  end)

  ---A fake client API whose request and dialog answer as given at once.
  ---@param request table What `interactions.request` returns.
  ---@param input table? What `ui.input` returns; the engine has no dialog without it.
  ---@return table rpf The fake.
  local function fake(request, input)
    return {
      events = { on = function() end },
      capabilities = function()
        return { input = input ~= nil }
      end,
      interactions = {
        request = function()
          return request[1], request[2]
        end,
      },
      ui = {
        input = function()
          local answer = assert(input, "no dialog on this engine")
          return answer[1], answer[2]
        end,
      },
    }
  end

  it("tells the player a refusal that came before anything was sent, never drops it", function()
    local told = {}
    local function tell(line)
      told[#told + 1] = line
    end
    local ask = rawget(_G, "acme_notes").ask_pin
    assert.are.same({ nil, "too_many" }, { ask(fake({ nil, "too_many" }), "hi", tell) })
    assert.are.same({ nil, "busy" }, { ask(fake({ true }, { nil, "busy" }), nil, tell) })
    assert.are.same({ nil, "unsupported" }, { ask(fake({ true }), "", tell) })
    assert.are.same({
      "The note was not sent (too_many).",
      "No dialog now (busy).",
      "Write the note after the command.",
    }, told)
  end)
end)
