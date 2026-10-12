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
    local source = support.portal_source("crates/rpf-domain/src/inventory.rs", pending)
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

-- The staff edits (F5) have cases of their own under edits/: a container,
-- one edit as the portal's `ContentsEdit` serialises it, and the contents it
-- must come to or the exact refusal. The portal works an edit out before it
-- sends it here, so `rpf.inventory.edit` and `ContentsEdit::apply` must put
-- every unit in the same place; both are held to these cases.
describe("rpf.inventory.edit against protocol/corpus/containers/edits", function()
  local shared

  before_each(function()
    support.load_core()
    shared = assert(rpf.json.decode(support.read("protocol/corpus/containers/catalog.json")))
  end)

  ---Every edit case, by name.
  ---@return table<string, table> cases The cases.
  local function edit_cases()
    local out = {}
    local dir = "protocol/corpus/containers/edits"
    for name in lfs.dir(support.path(dir)) do
      local stem = name:match("^(.+)%.json$")
      if stem then
        out[stem] = assert(rpf.json.decode(support.read(dir .. "/" .. name)), name)
      end
    end
    return out
  end

  it("makes every edit as the portal makes it, or refuses it the same way", function()
    local ops = {}
    for name, case in pairs(edit_cases()) do
      ops[case.edit.op] = true
      local before = rpf.json.encode(case.contents)
      local contents, err, refusal = rpf.inventory.edit(case.contents, case.flags, catalog_for(case, shared), case.edit)
      assert.are.equal(before, rpf.json.encode(case.contents), name .. ": the input is not changed")
      if case.expect.contents ~= nil then
        assert.is_not_nil(contents, name .. ": " .. tostring(err) .. " " .. tostring(refusal and rpf.json.encode(refusal)))
        assert.are.equal(rpf.json.encode(case.expect.contents), rpf.json.encode(contents), name)
      else
        assert.is_nil(contents, name)
        local got = rpf.json.object({ error = err })
        if refusal ~= nil then
          got.refusal = refusal
        end
        assert.are.equal(rpf.json.encode(case.expect.error), rpf.json.encode(got), name)
      end
    end
    assert.are.same({ give = true, take = true, move = true }, ops)
  end)
end)
