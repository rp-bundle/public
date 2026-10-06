-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The client side of choosing a character (D5), with the test playing the
-- game server. The server decides; this half keeps its last list and passes
-- the player's choices on.

local support = require("spec.support")

local JANE = "00000003-0000-4000-8000-000000000003"

---Starts the client and records every character event.
---@return spec.FakeClient c The platform.
---@return { name: string, args: table }[] seen Events, appended as they arrive.
local function start()
  support.load_core("client")
  local c = support.fake_client_platform()
  local seen = {}
  for _, name in ipairs({ "characters.listed", "characters.result" }) do
    rpf.events.on(name, function(...)
      seen[#seen + 1] = { name = name, args = { ... } }
    end)
  end
  rpf.start_client(c)
  return c, seen
end

---The last message sent to the server, decoded.
---@param c spec.FakeClient The platform.
---@return string name Its name.
---@return table payload Its payload.
local function last_sent(c)
  local message = c.to_servers[#c.to_servers]
  return message.name, assert(rpf.json.decode(message.payload))
end

describe("rpf.picker", function()
  it("keeps the server's list and announces it", function()
    local c, seen = start()
    c.from_server(
      "rpf:characters",
      '{"characters":[{"id":"'
        .. JANE
        .. '","first_name":"Jane","last_name":"Doe","gender":{"server_specific":"x"}},{"id":5}],"selected":"'
        .. JANE
        .. '"}'
    )
    local list = rpf.picker.list()
    assert.are.equal(1, #list, "an entry that is not a character is left out")
    assert.are.equal("Jane", list[1].first_name)
    assert.are.same({ server_specific = "x" }, list[1].gender)
    assert.are.equal(JANE, rpf.picker.selected())
    assert.are.equal("characters.listed", seen[1].name)
    assert.are.equal(JANE, seen[1].args[2])

    list[1].first_name = "changed"
    assert.are.equal("Jane", rpf.picker.list()[1].first_name, "handed out as copies")
  end)

  it("ignores a list that does not fit its schema", function()
    local c, seen = start()
    c.from_server("rpf:characters", '{"characters":{"id":"x"}}')
    c.from_server("rpf:characters", "nope")
    c.from_server("rpf:characters", '{"selected":"x"}')
    assert.are.equal(0, #seen)
    assert.are.same({}, rpf.picker.list())
  end)

  it("passes a result on", function()
    local c, seen = start()
    c.from_server("rpf:character_result", { during = "create", ok = false, reason = "limit" })
    assert.are.same({ during = "create", ok = false, reason = "limit" }, seen[1].args[1])
  end)

  it("sends the player's choices to the server", function()
    local c = start()
    assert.is_true(rpf.picker.create("Ada", "Lovelace", "female"))
    local name, payload = last_sent(c)
    assert.are.equal("rpf:character_create", name)
    assert.are.same({ first_name = "Ada", last_name = "Lovelace", gender = "female" }, payload)

    assert.is_true(rpf.picker.select(JANE))
    name, payload = last_sent(c)
    assert.are.equal("rpf:character_select", name)
    assert.are.same({ id = JANE }, payload)

    assert.is_true(rpf.picker.deselect())
    assert.are.equal("rpf:character_deselect", (last_sent(c)))
    assert.is_true(rpf.picker.refresh())
    assert.are.equal("rpf:characters_request", (last_sent(c)))
  end)

  it("refuses arguments that are not strings", function()
    local c = start()
    local before = #c.to_servers
    -- Wrong on purpose: the adapter's form is not type-checked.
    ---@diagnostic disable-next-line: param-type-mismatch
    assert.are.same({ nil, "invalid" }, { rpf.picker.create("Ada", nil, "female") })
    ---@diagnostic disable-next-line: param-type-mismatch
    assert.are.same({ nil, "invalid" }, { rpf.picker.select(5) })
    assert.are.equal(before, #c.to_servers)
  end)
end)
