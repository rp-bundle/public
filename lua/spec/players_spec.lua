-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The player lifecycle: every allowed move emits its events, every other
-- move is refused and changes nothing, and the login gate is only the login
-- flow's to open.

local support = require("spec.support")

local PLAYER = "00000002-0000-4000-8000-000000000002"
local OTHER = "00000003-0000-4000-8000-000000000003"

-- The moves the lifecycle allows, written out here rather than read from the
-- module, so the test states the rule instead of echoing it.
local ALLOWED = {
  connecting = { "authenticating", "dropping" },
  authenticating = { "registered", "dropping" },
  registered = { "character_select", "dropping" },
  character_select = { "active", "dropping" },
  active = { "character_select", "dropping" },
}

---Whether the spec's own table allows a move.
---@param from string The state moved from.
---@param to string The state moved to.
---@return boolean allowed True if listed.
local function allowed(from, to)
  for _, target in ipairs(ALLOWED[from] or {}) do
    if target == to then
      return true
    end
  end
  return false
end

---Starts a server on a fake platform, without completing any handshake.
---@return spec.FakePlatform p The platform.
local function start()
  support.load_core()
  local p = support.fake_platform()
  rpf.start_server(p, { url = "ws://portal", api_key = "k" })
  return p
end

---Records every lifecycle event.
---@return { name: string, player: rpf.PlayerView, from: string? }[] seen Appended to as events arrive.
local function record()
  local seen = {}
  for _, state in ipairs({ "state_changed", "connecting", "authenticating", "registered", "character_select", "active", "dropping" }) do
    rpf.events.on("players." .. state, function(player, from)
      seen[#seen + 1] = { name = "players." .. state, player = player, from = from }
    end)
  end
  return seen
end

---Moves a player to a state along the shortest legal path.
---@param handle any The player.
---@param state rpf.PlayerState The target.
local function reach(handle, state)
  local path = {
    connecting = {},
    authenticating = { "authenticating" },
    registered = { "authenticating", "registered" },
    character_select = { "authenticating", "registered", "character_select" },
    active = { "authenticating", "registered", "character_select", "active" },
  }
  rpf.players.connected(handle)
  for _, step in ipairs(path[state]) do
    local ok, err
    if step == "authenticating" then
      ok, err = rpf.players.authenticating(handle)
    elseif step == "registered" then
      ok, err = rpf.players.register(handle, { player_id = PLAYER, username = "sam" })
    else
      ---@diagnostic disable-next-line: param-type-mismatch
      ok, err = rpf.players.advance(handle, step)
    end
    assert(ok, err)
  end
end

---Tries a move through whichever function makes it.
---@param handle any The player.
---@param to string The target state.
---@return boolean moved Whether it moved.
---@return string? err Why not.
local function try(handle, to)
  if to == "authenticating" then
    return rpf.players.authenticating(handle)
  elseif to == "registered" then
    return rpf.players.register(handle, { player_id = PLAYER, username = "sam" })
  elseif to == "dropping" then
    return rpf.players.dropped(handle, "left"), nil
  end
  ---@diagnostic disable-next-line: param-type-mismatch
  return rpf.players.advance(handle, to)
end

describe("rpf.players", function()
  local p

  before_each(function()
    p = start()
  end)

  it("starts a new player in connecting, and announces it", function()
    local seen = record()
    local player = assert(rpf.players.connected(7))
    assert.are.equal("connecting", player.state)
    assert.are.equal("player 7", player.name)
    assert.are.equal(support.EPOCH_MS, player.connected_at)
    assert.are.same({ "players.state_changed", "players.connecting" }, { seen[1].name, seen[2].name })
    assert.is_nil(seen[1].from)
  end)

  it("refuses a handle that is already connected, or nil", function()
    rpf.players.connected(7)
    local player, err = rpf.players.connected(7)
    assert.is_nil(player)
    assert.truthy(tostring(err):find("already connected", 1, true))
    assert.is_nil((rpf.players.connected(nil)))
  end)

  -- Every allowed move, each checked for its two events and a changed state.
  for from, targets in pairs(ALLOWED) do
    for _, to in ipairs(targets) do
      it("moves " .. from .. " → " .. to .. " and emits state_changed then players." .. to, function()
        reach(7, from)
        local seen = record()
        p.advance(1000)
        local moved, err = try(7, to)
        assert.is_true(moved, err)
        assert.are.equal(2, #seen)
        assert.are.equal("players.state_changed", seen[1].name)
        assert.are.equal("players." .. to, seen[2].name)
        for _, event in ipairs(seen) do
          assert.are.equal(to, event.player.state)
          assert.are.equal(from, event.from)
          assert.are.equal(support.EPOCH_MS + 1000, event.player.since)
        end
        if to == "dropping" then
          assert.is_nil(rpf.players.get(7))
        else
          assert.are.equal(to, rpf.players.get(7).state)
        end
      end)
    end
  end

  -- Every other move is refused, announces nothing, and changes nothing.
  for _, from in ipairs({ "connecting", "authenticating", "registered", "character_select", "active" }) do
    for _, to in ipairs({ "connecting", "authenticating", "registered", "character_select", "active", "dropping" }) do
      if not allowed(from, to) then
        it("refuses " .. from .. " → " .. to .. " and changes nothing", function()
          reach(7, from)
          local before = rpf.players.get(7)
          local seen = record()
          local moved, err = try(7, to)
          assert.is_false(moved)
          assert.is_string(err)
          assert.are.same({}, seen)
          assert.are.same(before, rpf.players.get(7))
        end)
      end
    end
  end

  it("refuses to move a player it does not know", function()
    local moved, err = rpf.players.advance(99, "active")
    assert.is_false(moved)
    assert.truthy(tostring(err):find("not connected", 1, true))
    assert.is_false(rpf.players.dropped(99))
  end)

  it("allows exactly the moves this spec lists", function()
    for _, from in ipairs(rpf.players.STATES) do
      for _, to in ipairs(rpf.players.STATES) do
        assert.are.equal(allowed(from, to), rpf.players.can(from, to), from .. " → " .. to)
      end
    end
  end)

  it("has a transition table that covers every state and nothing else", function()
    local states = {}
    for _, state in ipairs(rpf.players.STATES) do
      states[state] = true
      assert.is_table(rpf.players.TRANSITIONS[state], state)
    end
    for from, targets in pairs(rpf.players.TRANSITIONS) do
      assert.is_true(states[from], from)
      for to in pairs(targets) do
        assert.is_true(states[to], to)
      end
    end
    assert.are.same({}, rpf.players.TRANSITIONS.dropping)
  end)

  describe("the login gate", function()
    -- #75: whatever drives characters (D5, or a bridge in K2) goes through
    -- advance, and advance can never open the gate.
    for _, gate in ipairs({ "connecting", "authenticating", "registered" }) do
      it("is closed to advance: " .. gate, function()
        reach(7, "connecting")
        -- Deliberately a state advance does not take: that is the point.
        ---@diagnostic disable-next-line: param-type-mismatch
        local moved, err = rpf.players.advance(7, gate)
        assert.is_false(moved)
        assert.truthy(tostring(err):find("only the login flow", 1, true), err)
      end)
    end

    it("lets advance neither drop a player nor skip login to a character", function()
      reach(7, "authenticating")
      assert.is_false((rpf.players.advance(7, "character_select")))
      assert.is_false((rpf.players.advance(7, "active")))
      ---@diagnostic disable-next-line: param-type-mismatch
      assert.is_false((rpf.players.advance(7, "dropping")))
      assert.are.equal("authenticating", rpf.players.get(7).state)
    end)

    it("lets a caller other than D5 drive character_select ⇄ active through the same checks", function()
      -- A stand-in for a K2 bridge: it only sees events and calls advance.
      local bridge = {}
      function bridge.character_loaded(handle)
        return rpf.players.advance(handle, "active")
      end
      function bridge.character_unloaded(handle)
        return rpf.players.advance(handle, "character_select")
      end
      rpf.events.on("players.registered", function(player)
        rpf.players.advance(player.handle, "character_select")
      end)
      reach(7, "registered")
      assert.are.equal("character_select", rpf.players.get(7).state)
      assert.is_true((bridge.character_loaded(7)))
      assert.is_false((bridge.character_loaded(7)))
      assert.is_true((bridge.character_unloaded(7)))
      assert.is_false((bridge.character_unloaded(7)))
      assert.are.equal("character_select", rpf.players.get(7).state)
    end)

    it("needs a uuid and a username to register", function()
      reach(7, "authenticating")
      assert.is_false((rpf.players.register(7, { player_id = "not-a-uuid", username = "sam" })))
      ---@diagnostic disable-next-line: missing-fields
      assert.is_false((rpf.players.register(7, { player_id = PLAYER })))
      ---@diagnostic disable-next-line: param-type-mismatch
      assert.is_false((rpf.players.register(7, nil)))
      assert.are.equal("authenticating", rpf.players.get(7).state)
      assert.is_nil(rpf.players.get(7).player_id)
    end)

    it("refuses one account playing twice", function()
      reach(7, "registered")
      rpf.players.connected(8)
      rpf.players.authenticating(8)
      local moved, err = rpf.players.register(8, { player_id = PLAYER, username = "sam" })
      assert.is_false(moved)
      assert.truthy(tostring(err):find("already playing", 1, true))
      assert.are.equal(7, rpf.players.by_player_id(PLAYER).handle)
    end)

    it("frees the account when its player drops", function()
      reach(7, "registered")
      rpf.players.dropped(7, "left")
      assert.is_nil(rpf.players.by_player_id(PLAYER))
      reach(8, "registered")
      assert.are.equal(8, rpf.players.by_player_id(PLAYER).handle)
    end)
  end)

  it("announces a move a handler makes after the move that triggered it, in order", function()
    rpf.events.on("players.state_changed", function(player)
      if player.state == "registered" then
        rpf.players.advance(player.handle, "character_select")
      end
    end)
    reach(7, "authenticating")
    local seen = record()
    rpf.players.register(7, { player_id = PLAYER, username = "sam" })
    local got = {}
    for i, event in ipairs(seen) do
      got[i] = event.name .. ":" .. event.player.state .. "<" .. tostring(event.from)
    end
    assert.are.same({
      "players.state_changed:registered<authenticating",
      "players.registered:registered<authenticating",
      "players.state_changed:character_select<registered",
      "players.character_select:character_select<registered",
    }, got)
  end)

  it("leaves a departing player out of the online list, even inside the dropping handlers", function()
    reach(7, "active")
    local during
    rpf.events.on("players.dropping", function()
      during = rpf.players.online()
    end)
    rpf.players.dropped(7, "left")
    assert.are.same({}, during)
  end)

  it("hands out copies, so a handler cannot change the registry", function()
    rpf.events.on("players.connecting", function(player)
      player.state = "active"
      player.player_id = PLAYER
    end)
    local view = assert(rpf.players.connected(7))
    view.state = "active"
    assert.are.equal("connecting", rpf.players.get(7).state)
    assert.is_nil(rpf.players.get(7).player_id)
    assert.is_false(rpf.players.authenticated(7))
  end)

  it("still has the record while the dropping handlers run, then forgets it", function()
    reach(7, "active")
    local during
    rpf.events.on("players.dropping", function(player)
      during = rpf.players.get(player.handle)
    end)
    rpf.players.dropped(7, "crashed")
    assert.are.equal("dropping", during.state)
    assert.are.equal("crashed", during.reason)
    assert.is_nil(rpf.players.get(7))
    assert.are.same({}, rpf.players.list())
  end)

  it("gives each connection its own serial, even when the engine reuses a handle", function()
    local first = assert(rpf.players.connected(7))
    rpf.players.dropped(7)
    local second = assert(rpf.players.connected(7))
    assert.are_not.equal(first.serial, second.serial)
  end)

  it("lists players oldest first", function()
    rpf.players.connected("b")
    rpf.players.connected("a")
    local list = rpf.players.list()
    assert.are.equal("b", list[1].handle)
    assert.are.equal("a", list[2].handle)
  end)

  it("keeps a list OnlinePlayers can be built from: logged-in players only, by player id", function()
    reach(7, "active")
    rpf.players.connected(8)
    rpf.players.authenticating(8)
    rpf.players.register(8, { player_id = OTHER, username = "alex" })
    rpf.players.connected(9)
    assert.are.same({
      {
        player_id = PLAYER,
        username = "sam",
        name = "player 7",
        state = "active",
        connected_at = support.EPOCH_MS,
      },
      {
        player_id = OTHER,
        username = "alex",
        name = "player 8",
        state = "registered",
        connected_at = support.EPOCH_MS,
      },
    }, rpf.players.online())
  end)

  describe("on_client", function()
    it("hands on messages from logged-in players only", function()
      local got = {}
      rpf.players.on_client("rpf:test", function(player, payload)
        got[#got + 1] = tostring(player.handle) .. ":" .. payload
      end)
      rpf.players.connected(7)
      p.from_client(7, "rpf:test", "early")
      rpf.players.authenticating(7)
      p.from_client(7, "rpf:test", "logging in")
      p.from_client(99, "rpf:test", "stranger")
      rpf.players.register(7, { player_id = PLAYER, username = "sam" })
      p.from_client(7, "rpf:test", "hello")
      assert.are.same({ "7:hello" }, got)
    end)

    it("refuses registration before the server has started", function()
      support.load_core()
      assert.has_error(function()
        rpf.players.on_client("rpf:test", function() end)
      end)
    end)
  end)
end)
