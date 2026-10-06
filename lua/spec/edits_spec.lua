-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Staff edits of held records (`rpf.edits`, F5): each command is applied
-- only to a record held at exactly the revision it names, through the same
-- calls a script uses, and reported before it is answered; anything else is
-- answered `failed` with nothing changed.

local support = require("spec.support")

local SERVER = "00000001-0000-4000-8000-000000000001"
local PLAYER = "00000002-0000-4000-8000-000000000002"
local JANE = "00000003-0000-4000-8000-000000000003"
local WALLET = "00000004-0000-4000-8000-000000000004"
local FUNDS = "0000000a-0000-4000-8000-00000000000a"
local BAG = "00000009-0000-4000-8000-000000000009"
local GRID = "0000000c-0000-4000-8000-00000000000c"
local MISSING = "0000000f-0000-4000-8000-00000000000f"
local CLIENT = "00000008-0000-4000-8000-000000000008"

local json

---The config's items: water stacks to 4.
---@return table snapshot A snapshot, marked as decoded.
local function snapshot()
  local size = json.object({ x = 1, y = 1 })
  return json.object({
    settings = json.object(),
    items = json.array({
      json.object({ slug = "water", name = "Water", weight = 5, size = size, stack_limit = 4 }),
    }),
    item_bases = json.array(),
    item_defaults = json.object({ weight = 1, size = size, stack_limit = 10 }),
  })
end

---The records the portal hands over: Jane, her wallet, a bag and a grid.
---@return table[] records The `held` reply's records.
local function records()
  local jane = { kind = "character", id = JANE }
  local function stack(item, count)
    return json.object({ item = item, count = count })
  end
  return {
    {
      kind = "character",
      revision = 2,
      character = {
        id = JANE,
        server_id = SERVER,
        owner = { kind = "player", id = PLAYER },
        first_name = "Jane",
        last_name = "Doe",
        gender = "female",
      },
    },
    {
      kind = "account",
      revision = 2,
      account = { id = WALLET, server_id = SERVER, owner = jane, name = "Wallet", flags = json.array() },
      balance = 100,
    },
    {
      kind = "container",
      revision = 4,
      container = {
        id = BAG,
        server_id = SERVER,
        owner = jane,
        name = "Bag",
        contents = json.object({ layout = "list", stacks = json.array({ stack("water", 3) }) }),
        flags = json.array(),
      },
    },
    {
      kind = "container",
      revision = 1,
      container = {
        id = GRID,
        server_id = SERVER,
        owner = jane,
        name = "Grid",
        contents = json.object({
          layout = "grid",
          placements = json.array({
            json.object({ stack = stack("water", 1), position = json.object({ x = 0, y = 0 }), rotated = false }),
          }),
        }),
        flags = json.array({ json.object({ flag = "grid", value = json.object({ x = 4, y = 4 }) }) }),
      },
    },
  }
end

---An `apply_command` for a command.
---@param fields table The command, `command` tag included.
---@return rpf.Frame frame The frame.
local function command(fields)
  return support.portal_frame("apply_command", { command = fields })
end

---An adjustment of the wallet.
---@param amount number The amount, signed.
---@param base number The revision it names.
---@return rpf.Frame frame The frame.
local function adjust(amount, base)
  return command({
    command = "adjust_balance",
    client_id = CLIENT,
    account_id = WALLET,
    base_revision = base,
    funds_account = FUNDS,
    amount = amount,
    description = "Refund.",
  })
end

---Every frame of one type sent so far, with each one's position in the
---order sent.
---@param p spec.FakePlatform The platform.
---@param tag string The type.
---@return rpf.Frame[] frames The frames.
---@return integer[] at Where each was sent.
local function sent_of(p, tag)
  local out, at = {}, {}
  for i, frame in ipairs(p.frames()) do
    if frame.type == tag then
      out[#out + 1] = frame
      at[#at + 1] = i
    end
  end
  return out, at
end

---The answer to the last command.
---@param p spec.FakePlatform The platform.
---@return table outcome The reply's `outcome`.
local function answer(p)
  local replies = sent_of(p, "command_applied")
  return replies[#replies].outcome
end

describe("rpf.edits", function()
  local p

  before_each(function()
    support.load_core()
    json = rpf.json
    p = support.fake_platform()
    support.connected(p)
    assert.is_true((rpf.config.apply(p, 1, "h1", snapshot())))
    rpf.sync.hold({ records = { { kind = "character", id = JANE } } })
    local hold = sent_of(p, "hold")[1]
    p.deliver(support.portal_frame("held", { re = hold.id, records = records() }))
  end)

  it("adjusts a balance as one entry against the funds account, reported before it answers", function()
    p.deliver(adjust(50, 2))

    assert.are.equal("applied", answer(p).outcome)
    assert.are.equal(150, rpf.accounts.balance(WALLET))
    local reports, at = sent_of(p, "state_changed")
    local _, answered = sent_of(p, "command_applied")
    assert.are.equal(1, #reports)
    assert.is_true(at[1] < answered[1], "the report goes first")
    local change = reports[1].changes[1]
    assert.are.equal(WALLET, change.id)
    assert.are.equal(2, change.base_revision)
    assert.are.same({
      client_id = CLIENT,
      from_account = FUNDS,
      to_account = WALLET,
      amount = 50,
      description = "Refund.",
    }, change.transactions[1])
  end)

  it("debits the other way, and never below zero for an ordinary account", function()
    p.deliver(adjust(-30, 2))
    assert.are.equal("applied", answer(p).outcome)
    assert.are.equal(70, rpf.accounts.balance(WALLET))
    local entry = sent_of(p, "state_changed")[1].changes[1].transactions[1]
    assert.are.same({ WALLET, FUNDS, 30 }, { entry.from_account, entry.to_account, entry.amount })

    -- The next adjustment names the revision the report moved it to.
    local overdraw = adjust(-71, 3)
    overdraw.command.client_id = "00000008-0000-4000-8000-0000000000ff"
    p.deliver(overdraw)
    assert.are.same({ outcome = "failed", reason = rpf.edits.REASONS.insufficient_funds }, answer(p))
    assert.are.equal(70, rpf.accounts.balance(WALLET))
    assert.are.equal(1, #sent_of(p, "state_changed"))
  end)

  it("refuses an edit made on another revision, so a retry after a landed one changes nothing", function()
    p.deliver(adjust(50, 1))
    assert.are.same({ outcome = "failed", reason = rpf.edits.REASONS.changed }, answer(p))
    assert.are.equal(100, rpf.accounts.balance(WALLET))

    -- The same adjustment again, as a staff member retries after an
    -- unknown outcome: the first moved the account on, so the second is
    -- refused, and the money moves once.
    p.deliver(adjust(50, 2))
    p.deliver(adjust(50, 2))
    assert.are.same({ outcome = "failed", reason = rpf.edits.REASONS.changed }, answer(p))
    assert.are.equal(150, rpf.accounts.balance(WALLET))
  end)

  it("refuses a record with a change of this server's own still to report", function()
    assert(rpf.inventory.add(BAG, "water", 1))
    p.deliver(command({ command = "take_item", container_id = BAG, base_revision = 4, index = 0, count = 1 }))
    assert.are.same({ outcome = "failed", reason = rpf.edits.REASONS.changed }, answer(p))
  end)

  it("refuses a record this server does not hold, and changes nothing", function()
    p.deliver(command({ command = "take_item", container_id = MISSING, base_revision = 0, index = 0, count = 1 }))
    assert.are.same({ outcome = "failed", reason = rpf.edits.REASONS.not_held }, answer(p))
    assert.are.equal(0, #sent_of(p, "state_changed"))
  end)

  it("gives, takes and moves items as the portal worked them out", function()
    p.deliver(command({
      command = "give_item",
      container_id = BAG,
      base_revision = 4,
      item = "water",
      count = 2,
      position = json.null,
      rotated = false,
    }))
    assert.are.equal("applied", answer(p).outcome)
    local stacks = rpf.records.get("container", BAG).contents.stacks
    assert.are.same({ 4, 1 }, { stacks[1].count, stacks[2].count })

    p.deliver(command({ command = "take_item", container_id = BAG, base_revision = 5, index = 1, count = 1 }))
    assert.are.equal("applied", answer(p).outcome)
    assert.are.equal(1, #rpf.records.get("container", BAG).contents.stacks)

    p.deliver(command({
      command = "move_item",
      container_id = GRID,
      base_revision = 1,
      index = 0,
      position = { x = 2, y = 3 },
      rotated = false,
    }))
    assert.are.equal("applied", answer(p).outcome)
    local placed = rpf.records.get("container", GRID).contents.placements[1]
    assert.are.same({ 2, 3 }, { placed.position.x, placed.position.y })
    assert.are.equal(3, #sent_of(p, "state_changed"))
  end)

  it("says which rule a container edit would break, and changes nothing", function()
    p.deliver(command({ command = "take_item", container_id = BAG, base_revision = 4, index = 0, count = 9 }))
    assert.are.same({ outcome = "failed", reason = rpf.edits.REASONS.insufficient }, answer(p))

    p.deliver(command({
      command = "move_item",
      container_id = GRID,
      base_revision = 1,
      index = 0,
      position = { x = 4, y = 0 },
      rotated = false,
    }))
    local outcome = answer(p)
    assert.are.equal("failed", outcome.outcome)
    assert.is_truthy(outcome.reason:find("out_of_bounds", 1, true), outcome.reason)
    assert.are.equal(0, #sent_of(p, "state_changed"))
  end)

  it("renames a character, and refuses a name that is empty once trimmed", function()
    p.deliver(command({
      command = "edit_character",
      character_id = JANE,
      base_revision = 2,
      first_name = "Janet",
      last_name = json.null,
      gender = json.null,
    }))
    assert.are.equal("applied", answer(p).outcome)
    assert.are.equal("Janet", rpf.records.get("character", JANE).first_name)
    assert.are.equal("Janet", sent_of(p, "state_changed")[1].changes[1].first_name)

    p.deliver(command({
      command = "edit_character",
      character_id = JANE,
      base_revision = 3,
      first_name = "  ",
      last_name = json.null,
      gender = json.null,
    }))
    assert.are.same({ outcome = "failed", reason = rpf.edits.REASONS.invalid }, answer(p))
  end)

  it("lets a deleted character and what it owns go before it answers", function()
    p.deliver(command({ command = "delete_character", character_id = JANE, base_revision = 2 }))

    assert.are.equal("applied", answer(p).outcome)
    assert.is_nil(rpf.records.get("character", JANE))
    assert.is_nil(rpf.records.get("account", WALLET))
    assert.is_nil(rpf.records.get("container", BAG))
    local releases, at = sent_of(p, "release")
    local _, answered = sent_of(p, "command_applied")
    assert.is_true(#releases >= 1)
    assert.is_true(at[#at] < answered[1], "the final states go first")
    local released = {}
    for _, release in ipairs(releases) do
      for _, record in ipairs(release.records) do
        released[record.id] = true
      end
    end
    assert.are.same({ [JANE] = true, [WALLET] = true, [BAG] = true, [GRID] = true }, released)
  end)
end)
