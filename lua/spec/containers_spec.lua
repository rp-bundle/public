-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The Lua half of the shared container validation corpus. These read the same
-- cases under protocol/corpus/containers/ that
-- crates/rpf-domain/tests/containers.rs does, so `rpf.inventory.validate` and
-- the portal's `ContainerContents::validate` are each held to the cases, never
-- to each other. A case is a container's flags, its contents and the exact
-- error expected (null when valid); the catalog is catalog.json, in the
-- config snapshot's shape, unless the case carries its own.

local lfs = require("lfs")
local support = require("spec.support")

---Every case, by name, decoded through the core's own codec.
---@return table<string, table> cases The cases.
local function cases()
  local out = {}
  local dir = "protocol/corpus/containers/cases"
  for name in lfs.dir(support.path(dir)) do
    local stem = name:match("^(.+)%.json$")
    if stem then
      out[stem] = assert(rpf.json.decode(support.read(dir .. "/" .. name)), name)
    end
  end
  return out
end

---The catalog a case is checked against, built as the live one is.
---@param case table The case.
---@param shared table The decoded catalog.json.
---@return rpf.inventory.Catalog catalog The catalog.
local function catalog_for(case, shared)
  local source = case.catalog or shared
  return rpf.inventory.catalog_of(source.items, source.item_defaults, {
    max_data_bytes = source.max_data_bytes,
    max_stacks = source.max_stacks,
  })
end

describe("rpf.inventory.validate against protocol/corpus/containers", function()
  local shared

  before_each(function()
    support.load_core()
    shared = assert(rpf.json.decode(support.read("protocol/corpus/containers/catalog.json")))
  end)

  it("gives every case its verdict, naming the same first broken rule", function()
    local count = 0
    for name, case in pairs(cases()) do
      count = count + 1
      local ok, refusal = rpf.inventory.validate(case.contents, case.flags, catalog_for(case, shared))
      if case.error == rpf.json.null then
        assert.is_true(ok, name .. ": " .. tostring(refusal and rpf.json.encode(refusal)))
      else
        assert.is_nil(ok, name)
        assert.are.equal(rpf.json.encode(case.error), rpf.json.encode(refusal), name)
      end
    end
    assert.is_true(count > 0, "no cases found")
  end)

  it("has an invalid case for every rule the portal names", function()
    local covered = {}
    for _, case in pairs(cases()) do
      if case.error ~= rpf.json.null then
        covered[case.error.error] = true
      end
    end
    for _, rule in ipairs(rpf.inventory.ERRORS) do
      -- `unknown_flag` is the one rule only Lua has: the portal's flags are
      -- its own types, so a case for it could not decode there.
      if rule ~= "unknown_flag" then
        assert.is_true(covered[rule], rule .. " has no case")
      end
    end
    for rule in pairs(covered) do
      local known = false
      for _, name in ipairs(rpf.inventory.ERRORS) do
        known = known or name == rule
      end
      assert.is_true(known, rule .. " is a case's rule but not one validate names")
    end
  end)

  it("names exactly the portal's rules, read from ContentsError", function()
    local source = support.read("crates/rpf-domain/src/inventory.rs")
    local body = assert(source:match("pub enum ContentsError {(.-)\n}"))
    local rules = { malformed = true, unknown_flag = true }
    for variant in body:gmatch("\n\t(%u%w*)") do
      rules[variant:gsub("(%l)(%u)", "%1_%2"):lower()] = true
    end
    local ours = {}
    for _, rule in ipairs(rpf.inventory.ERRORS) do
      ours[rule] = true
    end
    assert.are.same(rules, ours)
  end)

  it("keeps every valid case's contents, data included, byte for byte", function()
    for name, case in pairs(cases()) do
      if case.error == rpf.json.null then
        local before = rpf.json.encode(case.contents)
        rpf.inventory.validate(case.contents, case.flags, catalog_for(case, shared))
        assert.are.equal(before, rpf.json.encode(case.contents), name)
      end
    end
  end)
end)
