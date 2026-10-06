-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Staff commands (`rpf.commands`) and the kick (`rpf.moderation`, F4): a
-- kick disconnects only a player logged in to the named account here, and
-- every other case is answered `failed` with nothing done.

local support = require("spec.support")

local PLAYER = "00000002-0000-4000-8000-000000000002"
local STRANGER = "0000000b-0000-4000-8000-00000000000b"
local REASON = "Kicked by staff: stop spawning cars."

---A `kick` request for an account.
---@param player_id string The account.
---@return rpf.Frame frame The frame.
local function kick(player_id)
  return support.portal_frame("apply_command", {
    command = { command = "kick", player_id = player_id, reason = REASON },
  })
end

---A connected server with player 7 logged in as `PLAYER`.
---@return spec.FakePlatform p The platform.
local function server_with_player()
  support.load_core()
  local p = support.fake_platform()
  support.connected(p)
  rpf.players.connected(7)
  assert(rpf.players.authenticating(7))
  assert(rpf.players.register(7, { player_id = PLAYER, username = "sam" }))
  return p
end

describe("rpf.moderation", function()
  it("kicks the player logged in to the account, with the portal's reason, and says so", function()
    local p = server_with_player()
    local frame = kick(PLAYER)
    p.deliver(frame)

    assert.are.equal(1, #p.kicks)
    assert.are.equal(7, p.kicks[1].player)
    assert.are.equal(REASON, p.kicks[1].reason)
    local reply = p.last()
    assert.are.equal("command_applied", reply.type)
    assert.are.equal(frame.id, reply.re)
    assert.are.equal("applied", reply.outcome.outcome)
  end)

  it("kicks once however often the portal resends the request", function()
    local p = server_with_player()
    local frame = kick(PLAYER)
    p.deliver(frame)
    p.deliver(frame)

    assert.are.equal(1, #p.kicks)
  end)

  it("refuses a kick for anyone not logged in here, and kicks nobody", function()
    local p = server_with_player()
    -- Another player is connected and still logging in, under no account
    -- yet: a kick for an account nobody here is logged in to finds no one.
    rpf.players.connected(8)
    assert(rpf.players.authenticating(8))
    p.deliver(kick(STRANGER))
    local reply = p.last()
    assert.are.equal("failed", reply.outcome.outcome)
    assert.are.equal(rpf.moderation.NOT_ONLINE, reply.outcome.reason)

    -- Gone: the account left before the command arrived.
    rpf.players.dropped(7, "quit")
    p.deliver(kick(PLAYER))
    assert.are.equal("failed", p.last().outcome.outcome)
    assert.are.equal(0, #p.kicks)
  end)
end)

describe("rpf.commands", function()
  it("answers a command no module registered as failed, since nothing ran", function()
    local p = server_with_player()
    rpf.commands.handlers.kick = nil
    p.deliver(kick(PLAYER))

    local reply = p.last()
    assert.are.equal("failed", reply.outcome.outcome)
    assert.are.equal("this server has no handler for kick", reply.outcome.reason)
    assert.are.equal(0, #p.kicks)
  end)

  it("answers a handler that throws as unknown, since it may have done part of the work", function()
    local p = server_with_player()
    rpf.commands.register("kick", function()
      error("boom")
    end)
    p.deliver(kick(PLAYER))

    assert.are.equal("unknown", p.last().outcome.outcome)
  end)
end)
