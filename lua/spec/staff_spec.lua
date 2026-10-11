-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- In-game staff (`rpf.staff`, F9): grants replaced whole by each push from
-- the portal and enforced locally, account linking with a code that is never
-- logged, and staff actions reported only when the grant allows them.

local support = require("spec.support")

local PLAYER = "00000002-0000-4000-8000-000000000002"
local OTHER = "0000000b-0000-4000-8000-00000000000b"
local THIRD = "0000000c-0000-4000-8000-00000000000c"
local CODE = "7K3Q-X9ZP"
local REFUSED = "That link code is not valid. Check it, or ask the portal for a new one."

---A connected server whose `notify` is recorded, and the events `rpf.staff`
---announces.
---@param options rpf.ClientOptions? Connection overrides.
---@return spec.FakePlatform p The platform.
---@return { player: any, message: string }[] notified Every `notify`, in order.
---@return table<string, table[]> heard Every `staff.*` event's payload, by name.
local function server(options)
  support.load_core()
  local p = support.fake_platform()
  local notified = {}
  p.notify = function(player, message)
    notified[#notified + 1] = { player = player, message = message }
  end
  support.connected(p, options)
  local heard = { ["staff.changed"] = {}, ["staff.linked"] = {}, ["staff.link_failed"] = {} }
  for name, list in pairs(heard) do
    rpf.events.on(name, function(payload)
      list[#list + 1] = payload
    end)
  end
  return p, notified, heard
end

---Connects a player and logs them in to an account.
---@param handle any The engine's handle.
---@param player_id string The account.
local function login(handle, player_id)
  rpf.players.connected(handle)
  assert(rpf.players.authenticating(handle))
  assert(rpf.players.register(handle, { player_id = player_id, username = "user " .. tostring(handle) }))
end

---Delivers a `staff_permissions` from the portal.
---@param p spec.FakePlatform The platform.
---@param staff { player_id: string, permissions: string[] }[] The whole list.
local function push(p, staff)
  p.deliver(support.portal_frame("staff_permissions", { staff = staff }))
end

---Delivers a `staff_permissions` whose list is raw JSON, past the encoder's
---checks, as a hostile or broken portal could send it.
---@param p spec.FakePlatform The platform.
---@param staff any The `staff` value, as `rpf.json` would encode it.
local function push_raw(p, staff)
  local json = rpf.json
  local frame = assert(json.decode(assert(rpf.protocol.encode(
    rpf.protocol.PORTAL_TO_SERVER,
    support.portal_frame("staff_permissions", { staff = {} })
  ))))
  frame.staff = staff
  p.deliver(assert(json.encode(frame)))
end

---Frames of one type among everything sent.
---@param p spec.FakePlatform The platform.
---@param tag string The type.
---@return rpf.Frame[] frames The frames, in order.
local function sent_of(p, tag)
  local out = {}
  for _, frame in ipairs(p.frames()) do
    if frame.type == tag then
      out[#out + 1] = frame
    end
  end
  return out
end

---Fails if any log line so far contains a link code.
---@param p spec.FakePlatform The platform.
local function code_never_logged(p)
  for _, line in ipairs(p.logs) do
    assert.is_nil(line.message:find(CODE, 1, true), line.message)
  end
end

describe("rpf.staff", function()
  describe("grants", function()
    it("gives a logged-in player exactly what the last push lists, under the portal's names", function()
      local p = server()
      login(7, PLAYER)
      push(p, { { player_id = PLAYER, permissions = { "player.warn", "player.kick", "addon.radio.broadcast" } } })

      assert.is_true(rpf.staff.can(7, "player.kick"))
      assert.is_true(rpf.staff.can(7, "addon.radio.broadcast"), "a name this core does not know is kept")
      assert.is_false(rpf.staff.can(7, "player.ban"))
      assert.is_false(rpf.staff.can(7, "player"))
      assert.is_false(rpf.staff.can(7, nil))
      assert.are.same({ "addon.radio.broadcast", "player.kick", "player.warn" }, rpf.staff.permissions(7))

      local copy = rpf.staff.permissions(7)
      copy[1] = "player.ban"
      assert.is_false(rpf.staff.can(7, "player.ban"), "permissions hands out a copy")
    end)

    it("replaces every grant with each push, so a player left out may do nothing", function()
      local p, _, heard = server()
      login(7, PLAYER)
      login(8, OTHER)
      push(p, {
        { player_id = PLAYER, permissions = { "player.kick" } },
        { player_id = OTHER, permissions = { "player.warn" } },
      })
      push(p, { { player_id = OTHER, permissions = { "player.warn" } } })

      assert.is_false(rpf.staff.can(7, "player.kick"))
      assert.are.same({}, rpf.staff.permissions(7))
      assert.is_true(rpf.staff.can(8, "player.warn"))
      local changes = heard["staff.changed"]
      assert.are.same({ player_id = PLAYER, permissions = {} }, changes[#changes])

      push(p, {})
      assert.is_false(rpf.staff.can(8, "player.warn"))
    end)

    it("keeps a grant for a player not yet logged in, which applies once they register", function()
      local p = server()
      push(p, { { player_id = PLAYER, permissions = { "player.kick" } } })
      rpf.players.connected(7)
      assert.is_false(rpf.staff.can(7, "player.kick"), "connecting")
      assert(rpf.players.authenticating(7))
      assert.is_false(rpf.staff.can(7, "player.kick"), "authenticating")
      assert.are.same({}, rpf.staff.permissions(7))

      assert(rpf.players.register(7, { player_id = PLAYER, username = "sam" }))
      assert.is_true(rpf.staff.can(7, "player.kick"))
    end)

    it("forgets a player's grant as they leave, and refuses them while they do", function()
      local p, _, heard = server()
      login(7, PLAYER)
      push(p, { { player_id = PLAYER, permissions = { "player.kick" } } })
      local while_leaving
      rpf.events.on("players.dropping", function(player)
        while_leaving = rpf.staff.can(player.handle, "player.kick")
      end)

      rpf.players.dropped(7, "quit")
      assert.is_false(while_leaving)
      local changes = heard["staff.changed"]
      assert.are.same({ player_id = PLAYER, permissions = {} }, changes[#changes])

      -- Back under a new handle: nothing until the portal pushes again.
      login(9, PLAYER)
      assert.is_false(rpf.staff.can(9, "player.kick"))
    end)

    it("announces staff.changed only for players whose grant changed, in player id order", function()
      local p, _, heard = server()
      local changes = heard["staff.changed"]
      push(p, {
        { player_id = OTHER, permissions = { "player.warn" } },
        { player_id = PLAYER, permissions = { "player.kick", "player.warn" } },
      })
      assert.are.same({
        { player_id = PLAYER, permissions = { "player.kick", "player.warn" } },
        { player_id = OTHER, permissions = { "player.warn" } },
      }, changes)

      -- The same sets, in another order: nothing changed.
      push(p, {
        { player_id = PLAYER, permissions = { "player.warn", "player.kick" } },
        { player_id = OTHER, permissions = { "player.warn" } },
      })
      assert.are.equal(2, #changes)

      push(p, {
        { player_id = PLAYER, permissions = { "player.warn", "player.kick" } },
        { player_id = OTHER, permissions = { "player.warn", "player.ban" } },
        { player_id = THIRD, permissions = { "player.kick" } },
      })
      assert.are.same({
        { player_id = OTHER, permissions = { "player.ban", "player.warn" } },
        { player_id = THIRD, permissions = { "player.kick" } },
      }, { changes[3], changes[4] })
      assert.are.equal(4, #changes)
    end)

    it("refuses a malformed push and keeps the grants it would have replaced", function()
      local p, _, heard = server()
      local json = rpf.json
      login(7, PLAYER)
      push(p, { { player_id = PLAYER, permissions = { "player.kick" } } })
      local changes = #heard["staff.changed"]

      -- Shapes the decoder refuses: dropped before they reach the module.
      push_raw(p, json.array({ json.object({ player_id = "sam", permissions = json.array() }) }))
      push_raw(p, json.array({ json.object({ player_id = OTHER, permissions = json.array({ "player.kick", 7 }) }) }))
      push_raw(p, json.object({ player = PLAYER }))
      push_raw(p, json.array({ json.object({ player_id = OTHER }) }))
      assert.are.equal(4, #p.logged("warn", "dropped a frame from the portal"))

      -- A shape that decodes but has no single meaning: one player twice.
      push(p, {
        { player_id = OTHER, permissions = { "player.kick" } },
        { player_id = OTHER, permissions = {} },
      })
      assert.are.equal(1, #p.logged("warn", "refused a staff_permissions"))
      assert.are.same({ false, "the staff list is not a list" }, { rpf.staff.apply("everyone") })
      assert.is_false((rpf.staff.apply({ { player_id = PLAYER, permissions = { "player.kick", false } } })))

      assert.is_true(rpf.staff.can(7, "player.kick"))
      assert.are.equal(changes, #heard["staff.changed"])
    end)
  end)

  describe("linking", function()
    it("refuses a player who has not logged in, or a code that is not one, and sends nothing", function()
      local p = server()
      assert.are.same({ false, "not_logged_in" }, { rpf.staff.link(7, CODE) })
      rpf.players.connected(7)
      assert(rpf.players.authenticating(7))
      assert.are.same({ false, "not_logged_in" }, { rpf.staff.link(7, CODE) })

      login(8, PLAYER)
      for _, code in ipairs({ "", string.rep("A", rpf.staff.MAX_CODE_BYTES + 1), "\255\254", 1234 }) do
        assert.are.same({ false, "invalid_code" }, { rpf.staff.link(8, code) }, tostring(code))
      end
      assert.are.equal(0, #sent_of(p, "link_player"))
    end)

    it("sends the code as typed, one at a time, and tells the player whom they were linked to", function()
      local p, notified, heard = server()
      login(7, PLAYER)
      assert.are.same({ true }, { rpf.staff.link(7, CODE) })
      local sent = p.last()
      assert.are.equal("link_player", sent.type)
      assert.are.equal(PLAYER, sent.player_id)
      assert.are.equal(CODE, sent.link_code)
      assert.are.same({ false, "busy" }, { rpf.staff.link(7, CODE) })
      assert.are.equal(1, #sent_of(p, "link_player"))

      p.deliver(support.portal_frame("player_linked", { re = sent.id, staff_name = "Sam (staff)" }))
      assert.are.same({ { player = 7, message = "Linked to the staff account Sam (staff)." } }, notified)
      assert.are.same({ { player_id = PLAYER, staff_name = "Sam (staff)" } }, heard["staff.linked"])
      assert.are.equal(0, #heard["staff.link_failed"])
      -- Linking grants nothing by itself: the portal's next push does.
      assert.is_false(rpf.staff.can(7, "player.kick"))

      assert.is_true((rpf.staff.link(7, CODE)), "answered, so the player may link again")
      code_never_logged(p)
    end)

    it("tells the player the portal's reason when it refuses the code", function()
      local p, notified, heard = server()
      login(7, PLAYER)
      rpf.staff.link(7, CODE)
      p.deliver(support.portal_frame("rejected", { re = p.last().id, code = "forbidden", reason = REFUSED }))

      assert.are.same({ { player = 7, message = REFUSED } }, notified)
      assert.are.same({ { player_id = PLAYER, code = "forbidden", reason = REFUSED } }, heard["staff.link_failed"])
      assert.are.equal(0, #heard["staff.linked"])
      code_never_logged(p)
    end)

    it("tells the player when the portal could not answer at all", function()
      local p, notified, heard = server()
      login(7, PLAYER)
      rpf.connection.recovery_failed = true
      assert.are.same({ false, "outbox_unavailable" }, { rpf.staff.link(7, CODE) })
      assert.are.same({ { player = 7, message = rpf.staff.LINK_UNAVAILABLE } }, notified)
      assert.are.same(
        { { player_id = PLAYER, code = "outbox_unavailable", reason = rpf.staff.LINK_UNAVAILABLE } },
        heard["staff.link_failed"]
      )
      rpf.connection.recovery_failed = false
      assert.is_true((rpf.staff.link(7, CODE)), "nothing is left in flight")
      code_never_logged(p)
    end)

    it("tells the player when the code outlived the portal's retry window unanswered", function()
      local p, notified, heard = server({ retry_window_ms = 60 * 1000, window_margin_ms = 0, sweep_interval_ms = 1000 })
      login(7, PLAYER)
      rpf.staff.link(7, CODE)
      p.drop()
      p.advance(61 * 1000)

      assert.are.same({ { player = 7, message = rpf.staff.LINK_UNAVAILABLE } }, notified)
      assert.are.equal("expired", heard["staff.link_failed"][1].code)
      code_never_logged(p)
    end)

    it("tells nobody when the player has left, and still announces the answer", function()
      local p, notified, heard = server()
      login(7, PLAYER)
      rpf.staff.link(7, CODE)
      local id = p.last().id
      rpf.players.dropped(7, "quit")
      p.deliver(support.portal_frame("player_linked", { re = id, staff_name = "Sam (staff)" }))

      assert.are.same({}, notified)
      assert.are.same({ { player_id = PLAYER, staff_name = "Sam (staff)" } }, heard["staff.linked"])
    end)
  end)

  describe("the link command", function()
    ---Types the command as the platform hands it over.
    ---@param p spec.FakePlatform The platform.
    ---@param handle any The player.
    ---@param ... string The words after the command's name.
    local function type_command(p, handle, ...)
      assert(p.command_handlers[rpf.staff.COMMAND], "the core registered the command")(handle, { ... })
    end

    it("registers the one command the portal's page names", function()
      local p = server()
      assert.are.equal("rpflink", rpf.staff.COMMAND)
      assert.are.same({ rpflink = true }, (function()
        local names = {}
        for name in pairs(p.command_handlers) do
          names[name] = true
        end
        return names
      end)())
    end)

    it("links the player who typed it, with the code as typed", function()
      local p, notified = server()
      login(7, PLAYER)
      type_command(p, 7, CODE)
      local sent = p.last()
      assert.are.equal("link_player", sent.type)
      assert.are.equal(PLAYER, sent.player_id)
      assert.are.equal(CODE, sent.link_code)
      assert.are.same({}, notified, "the answer, not the command, tells the player")

      p.deliver(support.portal_frame("player_linked", { re = sent.id, staff_name = "Sam (staff)" }))
      assert.are.same({ { player = 7, message = "Linked to the staff account Sam (staff)." } }, notified)
      code_never_logged(p)
    end)

    it("joins a code typed in groups, which the portal reads the same", function()
      local p = server()
      login(7, PLAYER)
      type_command(p, 7, "7K3Q", "X9ZP")
      assert.are.equal("7K3QX9ZP", p.last().link_code)
    end)

    it("tells the player what to do, without sending anything, when it cannot be a code", function()
      local p, notified = server()
      login(7, PLAYER)
      type_command(p, 7)
      assert.are.same({ { player = 7, message = rpf.staff.LINK_USAGE } }, notified)

      local many = {}
      for i = 1, rpf.staff.MAX_CODE_WORDS + 1 do
        many[i] = "AAAA"
      end
      assert(p.command_handlers[rpf.staff.COMMAND])(7, many)
      type_command(p, 7, string.rep("A", rpf.staff.MAX_CODE_BYTES + 1))
      type_command(p, 7, "\255\254")
      for i = 2, 4 do
        assert.are.same({ player = 7, message = rpf.staff.LINK_INVALID }, notified[i], tostring(i))
      end
      assert.are.equal(0, #sent_of(p, "link_player"))
      code_never_logged(p)
    end)

    it("tells a player who has not logged in to, and does not send", function()
      local p, notified = server()
      rpf.players.connected(7)
      type_command(p, 7, CODE)
      type_command(p, 99, CODE)
      assert.are.same({
        { player = 7, message = rpf.staff.LINK_LOGIN_FIRST },
        { player = 99, message = rpf.staff.LINK_LOGIN_FIRST },
      }, notified)
      assert.are.equal(0, #sent_of(p, "link_player"))
    end)

    it("holds a second code until the first is answered, and tells the player", function()
      local p, notified = server()
      login(7, PLAYER)
      type_command(p, 7, CODE)
      type_command(p, 7, CODE)
      assert.are.same({ { player = 7, message = rpf.staff.LINK_BUSY } }, notified)
      assert.are.equal(1, #sent_of(p, "link_player"))
    end)

    it("does not tell the player twice when the outbox refused it", function()
      local p, notified = server()
      login(7, PLAYER)
      rpf.connection.recovery_failed = true
      type_command(p, 7, CODE)
      assert.are.same({ { player = 7, message = rpf.staff.LINK_UNAVAILABLE } }, notified)
    end)

    it("never repeats what was typed, in a message or a log, whatever the platform handed over", function()
      local p, notified = server()
      login(7, PLAYER)
      local secret = "SECRETSECRETSECRETSECRETSECRETSECRETSECRET"
      type_command(p, 7, secret)
      type_command(p, 7, "x", 5, secret)
      type_command(p, 7, { secret })
      assert(p.command_handlers[rpf.staff.COMMAND])(7, nil)
      assert(p.command_handlers[rpf.staff.COMMAND])(7, secret)
      for _, entry in ipairs(notified) do
        assert.is_nil(entry.message:find(secret, 1, true))
      end
      for _, entry in ipairs(p.logs) do
        assert.is_nil(entry.message:find(secret, 1, true))
      end
    end)
  end)

  describe("recording staff actions", function()
    it("refuses without the permission, a bad action or a target not logged in, and sends nothing", function()
      local p = server()
      login(7, PLAYER)
      assert.are.same({ false, "forbidden" }, { rpf.staff.record(7, "player.kick", "kick") }, "not linked")
      push(p, { { player_id = PLAYER, permissions = { "player.warn" } } })
      assert.are.same({ false, "forbidden" }, { rpf.staff.record(7, "player.kick", "kick") }, "not granted")
      assert.are.same({ false, "forbidden" }, { rpf.staff.record(99, "player.warn", "warn") }, "not connected")

      for _, action in ipairs({ "", "Warn", "warn-them", "1warn", string.rep("a", rpf.staff.MAX_ACTION_BYTES + 1), 7 }) do
        assert.are.same({ false, "invalid_action" }, { rpf.staff.record(7, "player.warn", action) }, tostring(action))
      end
      rpf.players.connected(8)
      assert.are.same({ false, "invalid_target" }, { rpf.staff.record(7, "player.warn", "warn", 8) }, "logging in")
      assert.are.same({ false, "invalid_target" }, { rpf.staff.record(7, "player.warn", "warn", 99) }, "not connected")
      assert.are.equal(0, #sent_of(p, "staff_action"))
    end)

    it("sends what the staff member did and to whom, or null for nobody", function()
      local p = server()
      login(7, PLAYER)
      login(8, OTHER)
      push(p, { { player_id = PLAYER, permissions = { "player.kick" } } })

      assert.are.same({ true }, { rpf.staff.record(7, "player.kick", "kick", 8) })
      local sent = p.last()
      assert.are.equal("staff_action", sent.type)
      assert.are.equal(PLAYER, sent.player_id)
      assert.are.equal("player.kick", sent.permission)
      assert.are.equal("kick", sent.action)
      assert.are.equal(OTHER, sent.target_player_id)

      assert.is_true((rpf.staff.record(7, "player.kick", "kick_all")))
      local wire = support.wire(p)
      assert.truthy(wire[#wire]:find('"target_player_id":null', 1, true), wire[#wire])
      assert.is_nil(p.last().target_player_id)
    end)

    it("logs a refusal from the portal, and tells the player nothing", function()
      local p, notified = server()
      login(7, PLAYER)
      push(p, { { player_id = PLAYER, permissions = { "player.kick" } } })
      rpf.staff.record(7, "player.kick", "kick")
      p.deliver(support.portal_frame("rejected", {
        re = p.last().id,
        code = "forbidden",
        reason = "that player may not do that here",
      }))

      assert.are.equal(1, #p.logged("warn", "did not record the staff action kick (player.kick) by player " .. PLAYER))
      assert.are.same({}, notified)
      for _, entry in ipairs(rpf.connection.outbox) do
        assert.are_not.equal("staff_action", entry.type, "a refusal is final")
      end
    end)
  end)
end)
