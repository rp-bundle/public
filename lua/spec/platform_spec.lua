-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

local support = require("spec.support")

---Collects the members each class in the meta files declares, and each
---class's parents, by reading the annotations. This is what keeps the
---language server's picture of the interface and the start-up check in step.
---@return table<string, table<string, true>> members Members by class.
---@return table<string, string[]> parents Parent classes by class.
local function read_meta()
  local members, parents, locals = {}, {}, {}
  for _, file in ipairs({ "platform_shared.lua", "platform_server.lua", "platform_client.lua" }) do
    local current
    for line in support.read("lua/core/meta/" .. file):gmatch("[^\n]+") do
      local class, rest = line:match("^%-%-%-@class ([%w_.]+):?%s*(.*)$")
      if class then
        current = class
        members[class] = members[class] or {}
        parents[class] = {}
        for parent in rest:gmatch("[%w_.]+") do
          parents[class][#parents[class] + 1] = parent
        end
      end
      local field = line:match("^%-%-%-@field ([%w_]+)")
      if field and current then
        members[current][field] = true
      end
      local var = line:match("^local ([%w_]+) = {}")
      if var and current then
        locals[var] = current
      end
      local owner, fn = line:match("^function ([%w_]+)%.([%w_]+)%(")
      if owner then
        members[locals[owner]][fn] = true
      end
    end
  end
  return members, parents
end

---Every member of a class, following its parents.
---@param class string The class.
---@return string[] names Sorted member names.
local function flatten(class)
  local members, parents = read_meta()
  local names = {}
  local function walk(c)
    for name in pairs(members[c] or {}) do
      names[name] = true
    end
    for _, parent in ipairs(parents[c] or {}) do
      walk(parent)
    end
  end
  walk(class)
  local out = {}
  for name in pairs(names) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

---Sorted names from a member list.
---@param list rpf.platform.Member[] The list.
---@return string[] names The names.
local function names(list)
  local out = {}
  for i, member in ipairs(list) do
    out[i] = member.name
  end
  table.sort(out)
  return out
end

describe("rpf.platform", function()
  before_each(function()
    support.load_core()
  end)

  it("checks the same server members the meta file declares", function()
    assert.are.same(flatten("rpf.ServerPlatform"), names(rpf.platform.SERVER))
  end)

  it("checks the same client members the meta file declares", function()
    assert.are.same(flatten("rpf.ClientPlatform"), names(rpf.platform.CLIENT))
  end)

  it("covers every capability issue D1 names for the server, and the thread J3 needs", function()
    assert.are.same({
      "after",
      "connect",
      "disconnect",
      "engine",
      "expose",
      "http_request",
      "identifiers",
      "kick",
      "kv_get",
      "kv_set",
      "log",
      "name",
      "notify",
      "now",
      "on_client",
      "random_hex",
      "send",
      "thread",
      "to_client",
    }, names(rpf.platform.SERVER))
  end)

  it("keeps the API key's transport off the client", function()
    local client = names(rpf.platform.CLIENT)
    for _, name in ipairs({ "connect", "disconnect", "send", "random_hex", "kick" }) do
      for _, member in ipairs(client) do
        assert.are_not.equal(name, member)
      end
    end
  end)

  for _, member in ipairs({ "connect", "log", "engine", "expose" }) do
    it("refuses to start the server without " .. member .. ", and names it", function()
      local p = support.fake_platform()
      p[member] = nil
      local ok, err = pcall(rpf.start_server, p, { url = "ws://portal", api_key = "k" })
      assert.is_false(ok)
      assert.truthy(tostring(err):find(member, 1, true), tostring(err))
      assert.is_nil(rpf.connection)
    end)
  end

  it("names every missing member at once", function()
    local p = support.fake_platform()
    p.kv_get, p.random_hex = nil, nil
    local _, err = pcall(rpf.start_server, p, { url = "ws://portal", api_key = "k" })
    assert.truthy(tostring(err):find("kv_get (function), random_hex (function)", 1, true), tostring(err))
  end)

  it("refuses an engine that is not a non-empty string", function()
    local p = support.fake_platform()
    p.engine = ""
    assert.is_false(pcall(rpf.start_server, p, { url = "ws://portal", api_key = "k" }))
    -- Deliberately the wrong type: this is what an adapter bug looks like.
    ---@diagnostic disable-next-line: assign-type-mismatch
    p.engine = 1
    assert.is_false(pcall(rpf.start_server, p, { url = "ws://portal", api_key = "k" }))
  end)

  for _, member in ipairs({ "to_server", "kv_set", "after" }) do
    it("refuses to start the client without " .. member .. ", and names it", function()
      support.load_core("client")
      local p = support.fake_client_platform()
      p[member] = nil
      local ok, err = pcall(rpf.start_client, p)
      assert.is_false(ok)
      assert.truthy(tostring(err):find(member, 1, true), tostring(err))
    end)
  end

  it("starts the client with a complete platform", function()
    support.load_core("client")
    local p = support.fake_client_platform()
    assert.are.equal(p, rpf.start_client(p))
  end)

  it("exposes the public API table through the platform, and only that", function()
    local p = support.fake_platform()
    rpf.start_server(p, { url = "ws://portal", api_key = "k" })
    assert.are.equal(rpf.api, p.exposed)
    assert.are_not.equal(rpf, p.exposed)
  end)
end)
