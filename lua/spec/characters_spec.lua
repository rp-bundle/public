-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- A player's characters (D5), with the test playing the portal (frames) and
-- the player's client (handoff messages). Listing and selecting are holds
-- (C7); every client message is hostile input.

local support = require("spec.support")

local SERVER = "00000001-0000-4000-8000-000000000001"
local PLAYER = "00000002-0000-4000-8000-000000000002"
local OTHER = "00000002-0000-4000-8000-0000000000ff"
local JANE = "00000003-0000-4000-8000-000000000003"
local JOHN = "00000003-0000-4000-8000-000000000033"
local THEIRS = "00000003-0000-4000-8000-0000000000ff"
local NEW = "00000003-0000-4000-8000-000000000099"
local JANE_WALLET = "00000004-0000-4000-8000-000000000004"
local JANE_BANK = "00000004-0000-4000-8000-000000000044"
local JOHN_WALLET = "00000004-0000-4000-8000-000000000005"
local POCKETS = "00000006-0000-4000-8000-000000000006"

local CHARACTERS = "rpf:characters"
local REQUEST = "rpf:characters_request"
local CREATE = "rpf:character_create"
local SELECT = "rpf:character_select"
local DESELECT = "rpf:character_deselect"
local RESULT = "rpf:character_result"

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

---The last frame of one type sent.
---@param p spec.FakePlatform The platform.
---@param tag string The type.
---@return rpf.Frame frame The frame.
local function last_of(p, tag)
  local frames = sent_of(p, tag)
  return assert(frames[#frames], "no " .. tag .. " was sent")
end

---A character as the portal hands one over.
---@param id string Its id.
---@param first string Its first name.
---@param owner string? The player who owns it.
---@return table record The `held` record.
local function character(id, first, owner)
  return {
    kind = "character",
    revision = 1,
    character = {
      id = id,
      server_id = SERVER,
      owner = { kind = "player", id = owner or PLAYER },
      first_name = first,
      last_name = "Doe",
      gender = "female",
    },
  }
end

---An account as the portal hands one over.
---@param id string Its id.
---@param owner string The character that owns it.
---@param name string Its name.
---@param balance number Its balance.
---@return table record The `held` record.
local function account(id, owner, name, balance)
  return {
    kind = "account",
    revision = 0,
    account = {
      id = id,
      server_id = SERVER,
      owner = { kind = "character", id = owner },
      name = name,
      flags = rpf.json.array(),
    },
    balance = balance,
  }
end

---Answers the last hold with these records.
---@param p spec.FakePlatform The platform.
---@param records table[] The records.
local function held(p, records)
  p.deliver(support.portal_frame("held", { re = last_of(p, "hold").id, records = records }))
end

---Registers player 7 as `PLAYER`, which holds their session records.
local function register()
  rpf.players.connected(7)
  rpf.players.authenticating(7)
  assert(rpf.players.register(7, { player_id = PLAYER, username = "sam" }))
end

---The last message of one name sent to player 7, decoded.
---@param p spec.FakePlatform The platform.
---@param name string The message name.
---@return table payload The payload.
local function last_to(p, name)
  local messages = p.messages_to(7, name)
  return assert(messages[#messages], "no " .. name .. " was sent")
end

describe("rpf.characters", function()
  local p, seen

  before_each(function()
    support.load_core()
    p = support.fake_platform()
    support.connected(p)
    seen = {}
    for _, name in ipairs({ "characters.created", "characters.selected", "characters.deselected" }) do
      rpf.events.on(name, function(player, value)
        seen[#seen + 1] = { name = name, player = player.player_id, value = value }
      end)
    end
  end)

  ---Registers player 7 and answers their session hold with two characters.
  local function loaded()
    register()
    held(p, { character(JANE, "Jane"), character(JOHN, "John") })
  end

  describe("listing", function()
    it("holds the player's records when they register, and lists them once held", function()
      register()
      local hold = last_of(p, "hold")
      assert.are.same({ { kind = "player", id = PLAYER } }, hold.owners)
      assert.are.equal("registered", rpf.players.get(7).state)
      assert.is_false(rpf.characters.loaded(PLAYER))
      assert.are.equal(0, #p.messages_to(7, CHARACTERS))

      held(p, { character(JOHN, "John"), character(JANE, "Jane") })

      assert.are.equal("character_select", rpf.players.get(7).state)
      assert.is_true(rpf.characters.loaded(PLAYER))
      local list = last_to(p, CHARACTERS)
      assert.are.equal(2, #list.characters)
      assert.are.equal("Jane", list.characters[1].first_name, "sorted by name")
      assert.are.equal(JOHN, list.characters[2].id)
      assert.is_nil(list.selected)
      local names = {}
      for _, c in ipairs(rpf.characters.list(PLAYER)) do
        names[#names + 1] = c.first_name
      end
      assert.are.same({ "Jane", "John" }, names)
    end)

    it("lists only the player's own characters", function()
      register()
      held(p, { character(JANE, "Jane"), character(THEIRS, "Theirs", OTHER) })
      local list = rpf.characters.list(PLAYER)
      assert.are.equal(1, #list)
      assert.are.equal(JANE, list[1].id)
    end)

    it("lists a player with no characters as having none", function()
      register()
      held(p, {})
      assert.are.equal("character_select", rpf.players.get(7).state)
      assert.are.equal(0, #last_to(p, CHARACTERS).characters)
    end)

    it("sends the list again when the client asks, and tries the hold again after it failed", function()
      register()
      p.deliver(support.portal_frame("rejected", { re = last_of(p, "hold").id, code = "retry", reason = "x" }))
      -- A retryable refusal is resent by the connection, not answered here.
      p.advance(60 * 1000)
      local holds = #sent_of(p, "hold")
      p.deliver(support.portal_frame("rejected", { re = last_of(p, "hold").id, code = "not_found", reason = "x" }))
      assert.are.equal("registered", rpf.players.get(7).state)
      assert.are.same({ during = "load", ok = false, reason = "unavailable" }, last_to(p, RESULT))

      p.from_client(7, REQUEST, "{}")
      assert.are.equal(holds + 1, #sent_of(p, "hold"), "the session is held again")
      held(p, { character(JANE, "Jane") })
      assert.are.equal("character_select", rpf.players.get(7).state)
      p.from_client(7, REQUEST, "{}")
      assert.are.equal(1, #last_to(p, CHARACTERS).characters)
    end)

    it("ignores an answer meant for an earlier connection of the player's", function()
      loaded()
      rpf.records.lose({ { kind = "character", id = JOHN } }, "force-released")
      local old = last_of(p, "hold")
      rpf.players.dropped(7, "quit")
      local release = last_of(p, "release")
      register()

      -- Answered in order: the old hold, then the release, then the new hold.
      p.deliver(support.portal_frame("held", { re = old.id, records = {} }))
      assert.are.equal("registered", rpf.players.get(7).state, "not listed from the old answer")
      assert.are.same(
        { nil, "not_ready" },
        { rpf.characters.create(7, { first_name = "A", last_name = "B", gender = "male" }) }
      )
      p.deliver(support.portal_frame("ack", { re = release.id }))
      local new = last_of(p, "hold")
      assert.are_not.equal(old.id, new.id)
      assert.are.same({ { kind = "player", id = PLAYER } }, new.owners)

      p.deliver(support.portal_frame("held", { re = new.id, records = { character(JANE, "Jane"), character(JOHN, "John") } }))
      assert.are.equal("character_select", rpf.players.get(7).state)
      assert.are.equal(2, #rpf.characters.list(PLAYER))
    end)

    it("holds the session again on request after holding it again failed", function()
      loaded()
      rpf.records.lose({ { kind = "character", id = JOHN } }, "force-released")
      p.deliver(support.portal_frame("rejected", { re = last_of(p, "hold").id, code = "not_found", reason = "x" }))
      assert.are.same({ during = "load", ok = false, reason = "unavailable" }, last_to(p, RESULT))

      local holds = #sent_of(p, "hold")
      p.from_client(7, REQUEST, "{}")
      assert.are.equal(holds + 1, #sent_of(p, "hold"), "not just the list it has")
      assert.are.same({ { kind = "player", id = PLAYER } }, last_of(p, "hold").owners)
      held(p, { character(JOHN, "John") })
      assert.are.equal(2, #last_to(p, CHARACTERS).characters)
      p.from_client(7, REQUEST, "{}")
      assert.are.equal(holds + 1, #sent_of(p, "hold"), "once it is whole, the list is just sent")
    end)
  end)

  describe("selecting", function()
    it("holds the character's own records, then moves the player to active", function()
      loaded()
      p.from_client(7, SELECT, '{"id":"' .. JANE .. '"}')
      local hold = last_of(p, "hold")
      assert.are.same({ { kind = "character", id = JANE } }, hold.owners)
      assert.are.equal("character_select", rpf.players.get(7).state, "not before its money is here")

      held(p, { account(JANE_WALLET, JANE, "Wallet", 250) })

      assert.are.equal("active", rpf.players.get(7).state)
      assert.are.equal(JANE, rpf.characters.selected(PLAYER).id)
      assert.are.equal(250, rpf.accounts.balance(JANE_WALLET))
      assert.are.same({ during = "select", ok = true, id = JANE }, last_to(p, RESULT))
      assert.are.equal(JANE, last_to(p, CHARACTERS).selected)
      assert.are.equal("characters.selected", seen[#seen].name)
      assert.are.equal(JANE, seen[#seen].value.id)
    end)

    it("switches by releasing the old character's records first", function()
      loaded()
      rpf.characters.select(7, JANE)
      held(p, {
        account(JANE_WALLET, JANE, "Wallet", 250),
        account(JANE_BANK, JANE, "Bank", 1000),
        {
          kind = "container",
          revision = 0,
          container = {
            id = POCKETS,
            server_id = SERVER,
            owner = { kind = "character", id = JANE },
            name = "Pockets",
            contents = rpf.json.object({ layout = "list", stacks = rpf.json.array() }),
            flags = rpf.json.array(),
          },
        },
      })
      local states = {}
      rpf.events.on("players.state_changed", function(player)
        states[#states + 1] = player.state
      end)

      assert.is_true(rpf.characters.select(7, JOHN))

      local release = last_of(p, "release")
      local released = {}
      for _, record in ipairs(release.records) do
        released[#released + 1] = record.kind .. ":" .. record.id
      end
      table.sort(released)
      assert.are.same({ "account:" .. JANE_WALLET, "account:" .. JANE_BANK, "container:" .. POCKETS }, released)
      assert.is_false(rpf.records.is_held("account", JANE_WALLET))
      assert.is_true(rpf.records.is_held("character", JANE), "the character stays a session record")
      -- A hold never overtakes a release queued before it (C7).
      assert.are.same({ { kind = "character", id = JANE } }, last_of(p, "hold").owners)
      p.deliver(support.portal_frame("ack", { re = release.id }))
      assert.are.same({ { kind = "character", id = JOHN } }, last_of(p, "hold").owners)
      assert.are.equal("character_select", rpf.players.get(7).state)
      assert.are.equal("characters.deselected", seen[#seen].name)
      assert.are.equal(JANE, seen[#seen].value)

      held(p, { account(JOHN_WALLET, JOHN, "Wallet", 5) })
      assert.are.same({ "character_select", "active" }, states)
      assert.are.equal(JOHN, rpf.characters.selected(PLAYER).id)
    end)

    it("selecting the character in play changes nothing", function()
      loaded()
      rpf.characters.select(7, JANE)
      held(p, {})
      local holds = #sent_of(p, "hold")
      local got
      assert.is_true(rpf.characters.select(7, JANE, function(c)
        got = c
      end))
      assert.are.equal(JANE, got.id)
      assert.are.equal(holds, #sent_of(p, "hold"))
      assert.are.equal(0, #sent_of(p, "release"))
    end)

    it("refuses a character that is not the player's, as if it did not exist", function()
      loaded()
      local holds = #sent_of(p, "hold")
      assert.are.same({ nil, "not_found" }, { rpf.characters.select(7, THEIRS) })
      assert.are.same({ nil, "not_found" }, { rpf.characters.select(7, NEW) })
      p.from_client(7, SELECT, '{"id":"' .. THEIRS .. '"}')
      assert.are.same({ during = "select", ok = false, id = THEIRS, reason = "not_found" }, last_to(p, RESULT))
      assert.are.equal(holds, #sent_of(p, "hold"))
      assert.are.equal("character_select", rpf.players.get(7).state)
    end)

    it("refuses before the characters are loaded, and while a request is in flight", function()
      register()
      assert.are.same({ nil, "not_ready" }, { rpf.characters.select(7, JANE) })
      held(p, { character(JANE, "Jane"), character(JOHN, "John") })
      assert.is_true(rpf.characters.select(7, JANE))
      assert.are.same({ nil, "busy" }, { rpf.characters.select(7, JOHN) })
      assert.are.same({ nil, "busy" }, { rpf.characters.create(7, { first_name = "A", last_name = "B", gender = "male" }) })
      assert.are.same({ nil, "busy" }, { rpf.characters.deselect(7) })
    end)

    it("stays choosing when the portal refuses the hold", function()
      loaded()
      rpf.characters.select(7, JANE)
      p.deliver(support.portal_frame("rejected", { re = last_of(p, "hold").id, code = "not_found", reason = "x" }))
      assert.are.equal("character_select", rpf.players.get(7).state)
      assert.is_nil(rpf.characters.selected(PLAYER))
      assert.is_true(rpf.characters.select(7, JOHN), "no longer busy")
    end)

    it("does nothing for a player who left while their selection was in flight", function()
      loaded()
      rpf.characters.select(7, JANE)
      local hold = last_of(p, "hold")
      rpf.players.dropped(7, "quit")
      local releases = #sent_of(p, "release")
      p.deliver(support.portal_frame("held", { re = hold.id, records = { account(JANE_WALLET, JANE, "Wallet", 1) } }))
      assert.is_false(rpf.records.is_held("account", JANE_WALLET), "given straight back")
      assert.is_true(#sent_of(p, "release") > releases)
      for _, event in ipairs(seen) do
        assert.are_not.equal("characters.selected", event.name)
      end
    end)

    it("puts the character away, back to choosing", function()
      loaded()
      rpf.characters.select(7, JANE)
      held(p, { account(JANE_WALLET, JANE, "Wallet", 250) })
      p.from_client(7, DESELECT, "{}")
      assert.are.equal("character_select", rpf.players.get(7).state)
      assert.is_nil(rpf.characters.selected(PLAYER))
      assert.is_false(rpf.records.is_held("account", JANE_WALLET))
      assert.are.same({ during = "deselect", ok = true }, last_to(p, RESULT))
    end)

    it("goes back to choosing when the portal takes the character away", function()
      loaded()
      rpf.characters.select(7, JANE)
      held(p, { account(JANE_WALLET, JANE, "Wallet", 250) })
      local holds = #sent_of(p, "hold")
      local lists = #p.messages_to(7, CHARACTERS)
      rpf.records.lose({ { kind = "character", id = JANE }, { kind = "account", id = JANE_WALLET } }, "purged")
      assert.are.equal("character_select", rpf.players.get(7).state)
      assert.is_nil(rpf.characters.selected(PLAYER))
      assert.are.equal("characters.deselected", seen[#seen].name)
      assert.are.equal(holds + 1, #sent_of(p, "hold"), "the session is held again")
      assert.are.same({ { kind = "player", id = PLAYER } }, last_of(p, "hold").owners)
      assert.are.equal(lists + 1, #p.messages_to(7, CHARACTERS), "the client is told at once")
      assert.is_nil(last_to(p, CHARACTERS).selected)
    end)

    it("gives back what a character taken away still owns here", function()
      loaded()
      rpf.characters.select(7, JANE)
      held(p, { account(JANE_WALLET, JANE, "Wallet", 250) })
      rpf.records.lose({ { kind = "character", id = JANE } }, "force-released")
      assert.are.equal("character_select", rpf.players.get(7).state)
      local releases = #sent_of(p, "release")

      p.advance(0)

      assert.is_false(rpf.records.is_held("account", JANE_WALLET), "not held until the player leaves")
      assert.are.equal(releases + 1, #sent_of(p, "release"))
      assert.are.equal(JANE_WALLET, last_of(p, "release").records[1].id)
    end)

    it("gives back what a selection brings if its character went meanwhile", function()
      loaded()
      rpf.characters.select(7, JANE)
      local hold = last_of(p, "hold")
      rpf.records.lose({ { kind = "character", id = JANE } }, "purged")
      p.deliver(support.portal_frame("held", { re = hold.id, records = { account(JANE_WALLET, JANE, "Wallet", 250) } }))

      assert.are.equal("character_select", rpf.players.get(7).state)
      assert.is_false(rpf.records.is_held("account", JANE_WALLET))
      assert.are.equal(JANE_WALLET, last_of(p, "release").records[1].id)
    end)

    it("waits for the whole list before creating after a character is taken away", function()
      loaded()
      local fields = { first_name = "A", last_name = "B", gender = "male" }
      rpf.records.lose({ { kind = "character", id = JOHN } }, "force-released")
      assert.are.same({ nil, "not_ready" }, { rpf.characters.create(7, fields) }, "the list is short")
      held(p, { character(JANE, "Jane"), character(JOHN, "John") })
      assert.is_true(rpf.characters.create(7, fields))
    end)

    ---Selects Jane with her wallet, has the portal take the wallet back, and
    ---returns the hold that recovers it.
    ---@return rpf.Frame hold The recovery hold.
    local function wallet_lost()
      loaded()
      rpf.characters.select(7, JANE)
      held(p, { account(JANE_WALLET, JANE, "Wallet", 250) })
      rpf.records.lose({ { kind = "account", id = JANE_WALLET } }, "force-released")
      local recovery
      for _, frame in ipairs(sent_of(p, "hold")) do
        if frame.owners[1] and frame.owners[1].kind == "character" then
          recovery = frame
        end
      end
      return assert(recovery)
    end

    it("holds the character in play's records again, busy until they are back", function()
      local recovery = wallet_lost()
      assert.are.same({ { kind = "character", id = JANE } }, recovery.owners)
      assert.are.equal("active", rpf.players.get(7).state)
      assert.are.same({ nil, "busy" }, { rpf.characters.deselect(7) })
      assert.are.same({ nil, "busy" }, { rpf.characters.select(7, JOHN) })

      p.deliver(support.portal_frame("held", { re = recovery.id, records = { account(JANE_WALLET, JANE, "Wallet", 250) } }))

      assert.is_true(rpf.records.is_held("account", JANE_WALLET))
      assert.are.equal(JANE, rpf.characters.selected(PLAYER).id)
      assert.is_true(rpf.characters.deselect(7), "free again")
    end)

    it("gives back what a recovery brings if the character went away meanwhile", function()
      local recovery = wallet_lost()
      rpf.records.lose({ { kind = "character", id = JANE } }, "purged")
      assert.is_nil(rpf.characters.selected(PLAYER))
      local releases = #sent_of(p, "release")

      p.deliver(support.portal_frame("held", { re = recovery.id, records = { account(JANE_WALLET, JANE, "Wallet", 250) } }))

      assert.is_false(rpf.records.is_held("account", JANE_WALLET), "not left held until the player leaves")
      assert.are.equal(releases + 1, #sent_of(p, "release"))
      local released = last_of(p, "release").records
      assert.are.equal(1, #released)
      assert.are.equal(JANE_WALLET, released[1].id)
    end)

    it("goes back to choosing when the character in play's records cannot be held again", function()
      local recovery = wallet_lost()
      p.deliver(support.portal_frame("rejected", { re = recovery.id, code = "not_found", reason = "x" }))

      assert.are.equal("character_select", rpf.players.get(7).state, "never in play without its money")
      assert.is_nil(rpf.characters.selected(PLAYER))
      assert.are.equal("characters.deselected", seen[#seen].name)
      assert.are.same({ during = "select", ok = false, id = JANE, reason = "unavailable" }, last_to(p, RESULT))
      assert.is_nil(last_to(p, CHARACTERS).selected)
      assert.is_true(rpf.characters.select(7, JANE), "selecting it again tries once more")
      assert.are.same({ { kind = "character", id = JANE } }, last_of(p, "hold").owners)
    end)
  end)

  describe("creating", function()
    it("asks the portal, then holds the new character for the session", function()
      loaded()
      p.from_client(7, CREATE, '{"first_name":"  Ada ","last_name":"Lovelace","gender":"female"}')
      local create = last_of(p, "create_character")
      assert.are.same({ kind = "player", id = PLAYER }, create.owner)
      assert.are.equal("Ada", create.first_name, "trimmed")
      assert.are.equal("female", create.gender)

      p.deliver(support.portal_frame("character_created", {
        re = create.id,
        character = character(NEW, "Ada").character,
      }))
      local hold = last_of(p, "hold")
      assert.are.same({ { kind = "character", id = NEW } }, hold.records)
      held(p, { character(NEW, "Ada") })

      assert.are.same({ during = "create", ok = true, id = NEW }, last_to(p, RESULT))
      assert.are.equal(3, #last_to(p, CHARACTERS).characters)
      assert.are.equal("character_select", rpf.players.get(7).state, "created, not selected")
      assert.are.equal("characters.created", seen[#seen].name)
      assert.are.equal(NEW, seen[#seen].value.id)
    end)

    it("sends any other gender as the server's own option", function()
      loaded()
      p.from_client(7, CREATE, '{"first_name":"Ada","last_name":"L","gender":"nonbinary"}')
      assert.are.same({ server_specific = "nonbinary" }, last_of(p, "create_character").gender)
    end)

    it("refuses bad names and genders without asking the portal", function()
      loaded()
      local long = string.rep("x", rpf.characters.MAX_NAME_BYTES + 1)
      for _, fields in ipairs({
        { first_name = " ", last_name = "Doe", gender = "male" },
        { first_name = "Jo", last_name = long, gender = "male" },
        { first_name = 1, last_name = "Doe", gender = "male" },
        { first_name = "Jo", last_name = "Doe", gender = "robot" },
        { first_name = "Jo", last_name = "Doe", gender = { server_specific = long } },
      }) do
        assert.are.same({ nil, "invalid" }, { rpf.characters.create(7, fields) })
      end
      p.from_client(7, CREATE, '{"first_name":"","last_name":"Doe","gender":"male"}')
      assert.are.same({ during = "create", ok = false, reason = "invalid" }, last_to(p, RESULT))
      assert.are.equal(0, #sent_of(p, "create_character"))
    end)

    it("refuses past the character limit", function()
      support.load_core()
      p = support.fake_platform()
      rpf.start_server(p, { url = "ws://portal", api_key = "k", characters = { max_characters = 2 } })
      p.open()
      p.deliver(support.portal_frame("welcome", { re = p.last().id, protocol = 1, server_id = SERVER }))
      support.declared(p)
      loaded()
      assert.are.same(
        { nil, "limit" },
        { rpf.characters.create(7, { first_name = "A", last_name = "B", gender = "male" }) }
      )
      assert.are.equal(0, #sent_of(p, "create_character"))
    end)

    it("reports the portal's refusal and is free again", function()
      loaded()
      local result
      rpf.characters.create(7, { first_name = "A", last_name = "B", gender = "male" }, function(c, err)
        result = { c, err }
      end)
      p.deliver(support.portal_frame("rejected", {
        re = last_of(p, "create_character").id,
        code = "malformed",
        reason = "x",
      }))
      assert.are.same({ nil, "malformed" }, result)
      assert.is_true(rpf.characters.select(7, JANE), "no longer busy")
    end)

    it("holds the session again when a created character could not be held", function()
      loaded()
      local fields = { first_name = "Ada", last_name = "L", gender = "female" }
      p.from_client(7, CREATE, '{"first_name":"Ada","last_name":"L","gender":"female"}')
      p.deliver(support.portal_frame("character_created", {
        re = last_of(p, "create_character").id,
        character = character(NEW, "Ada").character,
      }))
      p.deliver(support.portal_frame("rejected", { re = last_of(p, "hold").id, code = "not_found", reason = "x" }))
      assert.are.same({ during = "create", ok = false, reason = "not_found" }, last_to(p, RESULT))

      local reload = last_of(p, "hold")
      assert.are.same({ { kind = "player", id = PLAYER } }, reload.owners, "the session is held again at once")
      assert.are.same({ nil, "not_ready" }, { rpf.characters.create(7, fields) }, "not against a short list")
      p.deliver(support.portal_frame("rejected", { re = reload.id, code = "not_found", reason = "x" }))
      assert.are.same({ nil, "not_ready" }, { rpf.characters.create(7, fields) })

      local holds = #sent_of(p, "hold")
      p.from_client(7, REQUEST, "{}")
      assert.are.equal(holds + 1, #sent_of(p, "hold"), "a refresh tries again")
      held(p, { character(JANE, "Jane"), character(JOHN, "John"), character(NEW, "Ada") })
      assert.are.equal(3, #last_to(p, CHARACTERS).characters, "the created character is back")
      assert.is_true(rpf.characters.create(7, fields))
    end)

    it("holds the session once more if a hold of it was already in flight", function()
      loaded()
      p.from_client(7, CREATE, '{"first_name":"Ada","last_name":"L","gender":"female"}')
      p.deliver(support.portal_frame("character_created", {
        re = last_of(p, "create_character").id,
        character = character(NEW, "Ada").character,
      }))
      local hold_new = last_of(p, "hold")
      rpf.records.lose({ { kind = "character", id = JOHN } }, "force-released")
      local inflight = last_of(p, "hold")
      assert.are.same({ { kind = "player", id = PLAYER } }, inflight.owners)
      p.deliver(support.portal_frame("rejected", { re = hold_new.id, code = "not_found", reason = "x" }))
      assert.are.equal(inflight.id, last_of(p, "hold").id, "not two session holds at once")

      -- Sent before the character could be held, its answer may lack it.
      p.deliver(support.portal_frame("held", { re = inflight.id, records = { character(JANE, "Jane") } }))
      local again = last_of(p, "hold")
      assert.are_not.equal(inflight.id, again.id)
      assert.are.same({ { kind = "player", id = PLAYER } }, again.owners)
      assert.are.same(
        { nil, "not_ready" },
        { rpf.characters.create(7, { first_name = "A", last_name = "B", gender = "male" }) }
      )
      held(p, { character(JANE, "Jane"), character(NEW, "Ada") })
      assert.are.equal(2, #rpf.characters.list(PLAYER), "the created character is listed")
      assert.is_true(rpf.characters.create(7, { first_name = "A", last_name = "B", gender = "male" }))
    end)

    it("leaves a character created after the player left for next time", function()
      loaded()
      local result
      rpf.characters.create(7, { first_name = "A", last_name = "B", gender = "male" }, function(c, err)
        result = { c, err }
      end)
      local create = last_of(p, "create_character")
      rpf.players.dropped(7, "quit")
      local holds = #sent_of(p, "hold")
      p.deliver(support.portal_frame("character_created", { re = create.id, character = character(NEW, "A").character }))
      assert.are.same({ nil, "gone" }, result)
      assert.are.equal(holds, #sent_of(p, "hold"))
    end)

    it("holds a rejoined player's session again when their old creation lands late", function()
      loaded()
      local result
      rpf.characters.create(7, { first_name = "A", last_name = "B", gender = "male" }, function(c, err)
        result = { c, err }
      end)
      local create = last_of(p, "create_character")
      rpf.players.dropped(7, "quit")
      local release = last_of(p, "release")
      register()
      p.deliver(support.portal_frame("ack", { re = release.id }))
      held(p, { character(JANE, "Jane"), character(JOHN, "John") })
      assert.are.equal("character_select", rpf.players.get(7).state)
      local holds = #sent_of(p, "hold")

      p.deliver(support.portal_frame("character_created", { re = create.id, character = character(NEW, "A").character }))

      assert.are.same({ nil, "gone" }, result)
      assert.are.equal(holds + 1, #sent_of(p, "hold"), "the new session is held again")
      assert.are.same({ { kind = "player", id = PLAYER } }, last_of(p, "hold").owners)
      assert.are.same(
        { nil, "not_ready" },
        { rpf.characters.create(7, { first_name = "C", last_name = "D", gender = "male" }) },
        "not against the list without it"
      )
      held(p, { character(JANE, "Jane"), character(JOHN, "John"), character(NEW, "A") })
      assert.are.equal(3, #rpf.characters.list(PLAYER))
    end)

    it("announces nothing for a creation whose player left while it was being held", function()
      loaded()
      local result
      rpf.characters.create(7, { first_name = "A", last_name = "B", gender = "male" }, function(c, err)
        result = { c, err }
      end)
      p.deliver(support.portal_frame("character_created", {
        re = last_of(p, "create_character").id,
        character = character(NEW, "A").character,
      }))
      local hold = last_of(p, "hold")
      rpf.players.dropped(7, "quit")
      register()
      p.deliver(support.portal_frame("held", { re = hold.id, records = { character(NEW, "A") } }))

      assert.are.same({ nil, "gone" }, result)
      for _, event in ipairs(seen) do
        assert.are_not.equal("characters.created", event.name, "not on their new connection")
      end
    end)
  end)

  describe("the list's size", function()
    ---A character whose names and gender are each `MAX_NAME_BYTES` of a
    ---byte JSON escapes six bytes long, the longest one can encode.
    ---@param n integer Which one, for its id.
    ---@return table record The `held` record.
    local function longest(n)
      local name = string.rep("\1", rpf.characters.MAX_NAME_BYTES)
      local record = character(string.format("00000003-0000-4000-8000-%012d", n), name)
      record.character.last_name = name
      record.character.gender = { server_specific = name }
      return record
    end

    ---The raw payload of the last list sent to player 7.
    ---@return string payload The payload.
    local function last_list()
      local raw
      for _, message in ipairs(p.to_clients) do
        if message.name == CHARACTERS then
          raw = message.payload
        end
      end
      return assert(raw)
    end

    it("fits the most characters a server may allow, at their longest, in what the client reads", function()
      register()
      local all = {}
      for n = 1, rpf.characters.MAX_CHARACTERS do
        all[n] = longest(n)
      end
      held(p, all)
      local raw = last_list()
      assert.is_true(#raw <= rpf.handoff.MAX_LIST_PAYLOAD, "the client reads it")
      local fields = assert(rpf.handoff.decode(CHARACTERS, raw))
      assert.are.equal(rpf.characters.MAX_CHARACTERS, #fields.characters)
      assert.is_nil(fields.truncated)
    end)

    it("cuts a longer list from the portal short, keeping the character in play", function()
      register()
      local all = {}
      for n = 1, 3 * rpf.characters.MAX_CHARACTERS do
        all[n] = longest(n)
      end
      held(p, all)
      local last = all[#all].character.id
      rpf.characters.select(7, last)
      held(p, {})
      p.from_client(7, REQUEST, "{}")

      local raw = last_list()
      assert.is_true(#raw <= rpf.handoff.MAX_LIST_PAYLOAD, "the client reads it")
      local fields = assert(rpf.handoff.decode(CHARACTERS, raw))
      assert.is_true(fields.truncated)
      assert.is_true(#fields.characters < #all)
      assert.are.equal(last, fields.selected)
      assert.are.equal(last, fields.characters[#fields.characters].id, "the character in play is listed")
    end)

    it("leaves out a character in play too long to fit on its own", function()
      register()
      local huge = character(JANE, string.rep("x", rpf.handoff.MAX_LIST_PAYLOAD))
      held(p, { huge, character(JOHN, "John") })
      rpf.characters.select(7, JANE)
      held(p, {})
      p.from_client(7, REQUEST, "{}")

      local raw = last_list()
      assert.is_true(#raw <= rpf.handoff.MAX_LIST_PAYLOAD, "the client reads it")
      local fields = assert(rpf.handoff.decode(CHARACTERS, raw))
      assert.is_true(fields.truncated)
      assert.are.equal(JANE, fields.selected, "still says which is in play")
      assert.are.equal(1, #fields.characters)
      assert.are.equal(JOHN, fields.characters[1].id)
    end)

    it("refuses a character limit the list could not carry", function()
      for _, max in ipairs({ 0, 1.5, rpf.characters.MAX_CHARACTERS + 1 }) do
        support.load_core()
        local q = support.fake_platform()
        local ok = pcall(rpf.start_server, q, { url = "ws://portal", api_key = "k", characters = { max_characters = max } })
        assert.is_false(ok, tostring(max))
      end
    end)
  end)

  describe("client messages", function()
    it("ignores a player who has not logged in", function()
      rpf.players.connected(7)
      rpf.players.authenticating(7)
      p.from_client(7, CREATE, '{"first_name":"A","last_name":"B","gender":"male"}')
      p.from_client(7, REQUEST, "{}")
      assert.are.equal(0, #p.to_clients)
      assert.are.equal(0, #sent_of(p, "create_character"))
    end)

    it("ignores malformed payloads", function()
      loaded()
      local before = #p.to_clients
      for _, payload in ipairs({ "nope", "[]", '{"id":5}', string.rep("x", 5000), 42 }) do
        p.from_client(7, SELECT, payload)
        p.from_client(7, CREATE, payload)
      end
      assert.are.equal(before, #p.to_clients)
      assert.are.equal(0, #sent_of(p, "create_character"))
      assert.are.equal("character_select", rpf.players.get(7).state)
    end)

    it("refuses scripts emitting the module's events", function()
      assert.has_error(function()
        rpf.events.emit_public("characters.selected", {}, {})
      end)
    end)
  end)
end)
