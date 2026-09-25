-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Everything is reachable from `rpf`, and nothing else is defined globally.
-- In Gmod every addon shares one Lua state, so any other global the core left
-- behind could collide with someone else's addon.

local support = require("spec.support")

---The names currently in the real global table.
---@return table<string, true> names The set.
local function global_names()
  local names = {}
  for key in pairs(_G) do
    names[key] = true
  end
  return names
end

---Global names added between two snapshots.
---@param before table<string, true> The earlier snapshot.
---@return string[] added Sorted names.
local function added_since(before)
  local out = {}
  for key in pairs(_G) do
    if not before[key] then
      out[#out + 1] = tostring(key)
    end
  end
  table.sort(out)
  return out
end

describe("the global table", function()
  it("gains only rpf when the server side loads and runs", function()
    rawset(_G, "rpf", nil)
    local before = global_names()

    support.load_core("server")
    local p = support.fake_platform()
    support.connected(p)
    rpf.connection:send("player_dropped", {
      player_id = "00000002-0000-4000-8000-000000000002",
      reason = "left",
    })
    p.advance(10 * 60 * 1000)

    assert.are.same({ "rpf" }, added_since(before))
  end)

  it("gains only rpf when the client side loads and runs", function()
    rawset(_G, "rpf", nil)
    local before = global_names()

    support.load_core("client")
    rpf.start_client(support.fake_client_platform())

    assert.are.same({ "rpf" }, added_since(before))
  end)

  it("reaches every module from rpf", function()
    support.load_core("server")
    for _, name in ipairs({ "json", "platform", "protocol", "config", "client", "api" }) do
      assert.is_table(rpf[name], name)
    end
  end)
end)
