-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The records a game server holds (C7): nothing is kept without a hold, what
-- is handed out is a copy, and every local change keeps to the rules the
-- portal will check again.

local support = require("spec.support")

local SERVER = "00000001-0000-4000-8000-000000000001"
local PLAYER = "00000002-0000-4000-8000-000000000002"
local CHARACTER = "00000003-0000-4000-8000-000000000003"
local WALLET = "00000004-0000-4000-8000-000000000004"
local BANK = "00000005-0000-4000-8000-000000000005"
local POCKETS = "00000006-0000-4000-8000-000000000006"

---A `held` reply's records for one character, two accounts and a container.
---@return table[] held The records, as decoded off the wire.
local function held()
  local owner = { kind = "player", id = PLAYER }
  return {
    {
      kind = "character",
      revision = 3,
      character = {
        id = CHARACTER,
        server_id = SERVER,
        owner = owner,
        first_name = "Jane",
        last_name = "Doe",
        gender = "female",
      },
    },
    {
      kind = "account",
      revision = 0,
      account = { id = WALLET, server_id = SERVER, owner = owner, name = "Wallet", flags = rpf.json.array() },
      balance = 100,
    },
    {
      kind = "account",
      revision = 7,
      account = {
        id = BANK,
        server_id = SERVER,
        owner = { kind = "server", id = SERVER },
        name = "Treasury",
        flags = rpf.json.array({ "unlimited_balance" }),
      },
      balance = 0,
    },
    {
      kind = "container",
      revision = 1,
      container = {
        id = POCKETS,
        server_id = SERVER,
        owner = owner,
        name = "Pockets",
        contents = rpf.json.object({ layout = "list", stacks = rpf.json.array() }),
        flags = rpf.json.array(),
      },
    },
  }
end

describe("rpf.records", function()
  local p

  before_each(function()
    support.load_core()
    p = support.fake_platform()
    support.connected(p)
  end)

  it("holds nothing until the portal hands it over", function()
    assert.is_nil(rpf.records.get("character", CHARACTER))
    assert.is_false(rpf.records.is_held("account", WALLET))
    assert.are.same({}, rpf.records.held())

    rpf.records.take(held())

    assert.are.equal("Jane", rpf.records.get("character", CHARACTER).first_name)
    assert.are.equal(100, rpf.records.get("account", WALLET).balance)
    assert.are.equal(3, rpf.records.revision("character", CHARACTER))
    assert.are.equal(4, #rpf.records.held())
  end)

  it("hands out copies, so a caller cannot change what is held", function()
    rpf.records.take(held())
    local character = rpf.records.get("character", CHARACTER)
    character.first_name = "Mallory"
    local wallet = rpf.records.get("account", WALLET)
    wallet.balance = 1e9

    assert.are.equal("Jane", rpf.records.get("character", CHARACTER).first_name)
    assert.are.equal(100, rpf.records.get("account", WALLET).balance)
  end)

  it("keeps its own state when the portal hands over a record it already holds", function()
    rpf.records.take(held())
    assert.is_true(rpf.records.set_character(CHARACTER, { first_name = "Janet" }))

    rpf.records.take(held())

    assert.are.equal("Janet", rpf.records.get("character", CHARACTER).first_name)
  end)

  it("forgets a record for good once it is released or lost", function()
    rpf.records.take(held())
    local lost = {}
    rpf.events.on("records.lost", function(refs, reason)
      lost[#lost + 1] = { refs = refs, reason = reason }
    end)

    rpf.records.forget({ { kind = "account", id = WALLET } })
    rpf.records.lose({ { kind = "container", id = POCKETS }, { kind = "account", id = WALLET } }, "gone")

    assert.is_nil(rpf.records.get("account", WALLET))
    assert.is_nil(rpf.records.get("container", POCKETS))
    assert.are.same({ { refs = { { kind = "container", id = POCKETS } }, reason = "gone" } }, lost)
    -- And a change to one is refused, not cached for later.
    assert.are.same({ nil, "not_held" }, { rpf.records.set_contents(POCKETS, rpf.json.object({ layout = "list" })) })
  end)

  it("refuses its events to scripts", function()
    assert.has_error(function()
      rpf.api.events.emit("records.lost", {}, "forged")
    end)
  end)

  describe("characters", function()
    before_each(function()
      rpf.records.take(held())
    end)

    it("changes only the fields given, trimmed", function()
      assert.is_true(rpf.records.set_character(CHARACTER, { last_name = "  Roe " }))
      local character = assert(rpf.records.get("character", CHARACTER))
      assert.are.equal("Jane", character.first_name)
      assert.are.equal("Roe", character.last_name)
    end)

    it("refuses an empty name or an unknown gender and changes nothing", function()
      for _, fields in ipairs({
        { first_name = "   " },
        { last_name = 7 },
        { first_name = "Ok", gender = "robot" },
        { gender = { server_specific = "x", extra = true } },
      }) do
        assert.are.same({ nil, "invalid" }, { rpf.records.set_character(CHARACTER, fields) })
      end
      assert.are.equal("Jane", rpf.records.get("character", CHARACTER).first_name)
      assert.is_nil(next(rpf.records.entries["character:" .. CHARACTER].changed))
    end)

    it("takes a server-specific gender", function()
      assert.is_true(rpf.records.set_character(CHARACTER, { gender = { server_specific = "nonbinary" } }))
      assert.are.equal("nonbinary", rpf.records.get("character", CHARACTER).gender.server_specific)
    end)
  end)

  describe("containers", function()
    local json

    before_each(function()
      json = rpf.json
      rpf.records.take(held())
    end)

    it("takes list and grid contents shaped as the protocol's", function()
      local stack = json.object({ item = "water_bottle", count = 2, data = json.object({ fill = 3 }) })
      assert.is_true(rpf.records.set_contents(POCKETS, json.object({ layout = "list", stacks = json.array({ stack }) })))
      assert.is_true(rpf.records.set_contents(POCKETS, json.object({
        layout = "grid",
        placements = json.array({
          json.object({ stack = stack, position = json.object({ x = 0, y = 1 }), rotated = true }),
        }),
      })))
      assert.are.equal("grid", rpf.records.get("container", POCKETS).contents.layout)
    end)

    -- Contents the portal cannot decode would fail every later report and
    -- release carrying them, so a release would end nothing while this server
    -- forgot the container.
    it("refuses contents the portal could not decode and changes nothing", function()
      local function stacks(...)
        return json.object({ layout = "list", stacks = json.array({ ... }) })
      end
      local function placed(position, rotated)
        return json.object({
          layout = "grid",
          placements = json.array({
            json.object({ stack = json.object({ item = "a", count = 1 }), position = position, rotated = rotated }),
          }),
        })
      end
      for i, contents in ipairs({
        json.object({ layout = "list" }),
        json.object({ layout = "grid", stacks = json.array() }),
        json.object({ layout = "pile", stacks = json.array() }),
        json.object({ layout = "list", stacks = json.object() }),
        json.object({ layout = "list", stacks = json.array({ [2] = json.object({ item = "a", count = 1 }) }) }),
        stacks(json.object({ count = 1 })),
        stacks(json.object({ item = "a", count = -1 })),
        stacks(json.object({ item = "a", count = 1.5 })),
        stacks(json.object({ item = "a", count = 4294967296 })),
        stacks(json.object({ item = "a", count = 1, data = json.array() })),
        stacks(json.object({ item = "a", count = 1, data = json.null })),
        placed(json.object({ x = 0 })),
        placed(json.object({ x = 0, y = 2147483648 })),
        placed(json.object({ x = 0, y = 0 }), "yes"),
      }) do
        assert.are.same({ nil, "invalid" }, { rpf.records.set_contents(POCKETS, contents) }, tostring(i))
      end
      assert.is_nil(next(rpf.records.entries["container:" .. POCKETS].changed))
    end)
  end)

  describe("money", function()
    before_each(function()
      rpf.records.take(held())
    end)

    it("moves money between two held accounts as one ledger entry", function()
      local client_id = rpf.records.transfer(WALLET, BANK, 40, "Fine")

      assert.is_string(client_id)
      assert.are.equal(60, rpf.records.get("account", WALLET).balance)
      assert.are.equal(40, rpf.records.get("account", BANK).balance)
      local entry = rpf.records.entries["account:" .. WALLET]
      assert.are.equal(1, #entry.transactions)
      assert.are.equal(client_id, entry.transactions[1].client_id)
      assert.are.equal(0, #rpf.records.entries["account:" .. BANK].transactions)
    end)

    it("refuses an account it does not hold", function()
      local elsewhere = "00000009-0000-4000-8000-000000000009"
      assert.are.same({ nil, "not_held" }, { rpf.records.transfer(WALLET, elsewhere, 1, "x") })
      assert.are.same({ nil, "not_held" }, { rpf.records.transfer(elsewhere, WALLET, 1, "x") })
    end)

    it("refuses amounts outside the ledger's bounds, and paying oneself", function()
      for _, amount in ipairs({ 0, -5, 1.5, rpf.protocol.MAX_AMOUNT + 1 }) do
        assert.are.same({ nil, "invalid" }, { rpf.records.transfer(BANK, WALLET, amount, "x") }, tostring(amount))
      end
      assert.are.same({ nil, "invalid" }, { rpf.records.transfer(WALLET, WALLET, 1, "x") })
      ---@diagnostic disable-next-line: param-type-mismatch
      assert.are.same({ nil, "invalid" }, { rpf.records.transfer(WALLET, BANK, 1, nil) })
      local long = string.rep("x", rpf.records.MAX_DESCRIPTION_BYTES)
      assert.are.same({ nil, "invalid" }, { rpf.records.transfer(BANK, WALLET, 1, long .. "x") })
      assert.is_string(rpf.records.transfer(BANK, WALLET, 1, long))
    end)

    it("refuses to overdraw an account unless its balance is unlimited", function()
      assert.are.same({ nil, "insufficient_funds" }, { rpf.records.transfer(WALLET, BANK, 101, "x") })
      assert.is_string(rpf.records.transfer(BANK, WALLET, 500, "Grant"))
      assert.are.equal(-500, rpf.records.get("account", BANK).balance)
    end)

    it("keeps every balance within what both sides hold exactly", function()
      local max = rpf.protocol.MAX_AMOUNT
      assert.is_string(rpf.records.transfer(BANK, WALLET, max - 100, "Grant"))
      assert.are.same({ nil, "out_of_range" }, { rpf.records.transfer(BANK, WALLET, 1, "x") })
    end)
  end)
end)
