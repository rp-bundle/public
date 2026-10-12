-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The Lua half of the shared addon corpus. These read the same cases under
-- protocol/corpus/addons/ that crates/rpf-domain/tests/addons.rs does, so
-- `rpf.manifest.check` and `Manifest::parse`, and `rpf.manifest.check_fields`
-- and `TypeDef::check_fields`, are each held to the cases, never to each
-- other.

local lfs = require("lfs")
local support = require("spec.support")

---Every case in a directory, by name, decoded through the core's own codec.
---@param dir string Relative to protocol/corpus/addons/.
---@return table<string, table> cases The cases.
local function cases(dir)
  local out = {}
  local path = "protocol/corpus/addons/" .. dir
  for name in lfs.dir(support.path(path)) do
    local stem = name:match("^(.+)%.json$")
    if stem then
      out[stem] = assert(rpf.json.decode(support.read(path .. "/" .. name)), name)
    end
  end
  return out
end

---The variants of a Rust enum, as they serialise.
---@param file string The source file, relative to the repository root.
---@param name string The enum.
---@param pending fun(message: string) The running spec's `pending`, for a checkout with no portal sources (`support.portal_source`).
---@return table<string, true> rules The variants, snake_case.
local function rules_in_source(file, name, pending)
  local source = support.portal_source(file, pending)
  local body = assert(source:match("pub enum " .. name .. " {(.-)\n}"), name)
  local rules = {}
  for variant in body:gmatch("\n\t(%u%w*)") do
    rules[variant:gsub("(%l)(%u)", "%1_%2"):lower()] = true
  end
  return rules
end

---A list as a set.
---@param list string[] The list.
---@return table<string, true> set The set.
local function set(list)
  local out = {}
  for _, k in ipairs(list) do
    out[k] = true
  end
  return out
end

describe("rpf.manifest.check against protocol/corpus/addons/manifests", function()
  before_each(function()
    support.load_core()
  end)

  it("gives every case its verdict, naming the same first broken rule and path", function()
    local count = 0
    for name, case in pairs(cases("manifests")) do
      count = count + 1
      local ok, refusal = rpf.manifest.check(case.manifest)
      if case.error == rpf.json.null then
        assert.is_table(ok, name .. ": " .. tostring(refusal and rpf.json.encode(refusal)))
      else
        assert.is_nil(ok, name)
        assert.are.equal(rpf.json.encode(case.error), rpf.json.encode(refusal), name)
      end
    end
    assert.is_true(count > 0, "no cases found")
  end)

  it("keeps a valid manifest as it was declared", function()
    for name, case in pairs(cases("manifests")) do
      if case.error == rpf.json.null then
        local before = rpf.json.encode(case.manifest)
        local checked = assert(rpf.manifest.check(case.manifest), name)
        assert.are.equal(before, rpf.json.encode(case.manifest), name .. ": the input changed")
        assert.are.equal(before, rpf.json.encode(checked), name)
      end
    end
  end)

  it("names exactly the portal's rules, read from ManifestRule, and has a case for each", function()
    local rules = rules_in_source("crates/rpf-domain/src/addons/manifest.rs", "ManifestRule", pending)
    assert.are.same(rules, set(rpf.manifest.MANIFEST_RULES))
    local covered = {}
    for _, case in pairs(cases("manifests")) do
      if case.error ~= rpf.json.null then
        covered[case.error.error] = true
      end
    end
    assert.are.same(rules, covered)
  end)

  it("reads a manifest an author wrote, empty tables and all, as JSON", function()
    local checked = assert(rpf.manifest.check({
      namespace = "acme_garden",
      version = "1.0.0",
      api = 1,
      title = "Garden",
      requires = {},
      types = {
        plant = {
          schema = 1,
          authority = "live",
          owners = { "player" },
          fields = {
            tags = { type = "list", of = "string", default = {} },
            data = { type = "json", default = {} },
          },
          list = {},
        },
      },
    }))
    assert.are.equal(
      '{"api":1,"namespace":"acme_garden","requires":{},"title":"Garden","types":{"plant":{"authority":"live",'
        .. '"fields":{"data":{"default":{},"type":"json"},"tags":{"default":[],"of":"string","type":"list"}},'
        .. '"list":[],"owners":["player"],"schema":1}},"version":"1.0.0"}',
      rpf.json.encode(checked)
    )
  end)

  it("refuses a number no frame could carry where it stands, rather than throwing", function()
    for _, bad in ipairs({ 0 / 0, math.huge, -math.huge }) do
      local ok, checked, refusal = pcall(rpf.manifest.check, {
        namespace = "acme_garden",
        version = "1.0.0",
        api = bad,
        title = "Garden",
      })
      assert.is_true(ok, tostring(checked))
      assert.is_nil(checked)
      assert.are.same({ error = "wrong_type", path = "api" }, refusal)
    end
    assert.is_nil(rpf.json.serde_bytes({ n = 0 / 0 }))
  end)

  it("refuses a table that is neither an object nor an array where it stands", function()
    local _, refusal = rpf.manifest.check({ namespace = "acme_garden", version = "1.0.0", api = 1, title = { 1, x = 2 } })
    assert.are.same({ error = "wrong_type", path = "title" }, refusal)
  end)

  it("mirrors the portal's limits", function()
    local limits = support.portal_source("crates/rpf-domain/src/limits.rs", pending)
    for _, name in ipairs({
      "MAX_MANIFEST_BYTES",
      "MAX_RECORD_BYTES",
      "MAX_ADDONS_PER_SERVER",
      "MAX_ADDON_PERMISSIONS",
      "MAX_TYPES_PER_ADDON",
      "MAX_FIELDS_PER_TYPE",
      "MAX_INDEXED_FIELDS_PER_TYPE",
      "MAX_RECORDS_PER_TYPE",
    }) do
      local expr = assert(limits:match("pub const " .. name .. ": usize = ([%d_ *]+);"), name)
      local value = 1
      for factor in expr:gmatch("[%d_]+") do
        value = value * tonumber((factor:gsub("_", "")))
      end
      assert.are.equal(value, rpf.manifest[name], name)
    end
  end)
end)

describe("rpf.manifest.check_fields against protocol/corpus/addons/records", function()
  local kit

  before_each(function()
    support.load_core()
    kit = assert(rpf.manifest.check(rpf.json.decode(support.read("protocol/corpus/addons/manifest.json"))))
  end)

  it("gives every case its verdict", function()
    local count = 0
    for name, case in pairs(cases("records")) do
      count = count + 1
      local def = assert(kit.types[case.type], name)
      local fields, refusal
      if case.fields ~= nil then
        fields, refusal = rpf.manifest.check_fields(def, case.fields)
      else
        fields, refusal = rpf.manifest.apply_patch(def, case.current, case.patch)
      end
      local actual = fields and { fields = fields } or { error = refusal }
      assert.are.equal(rpf.json.encode(case.expect), rpf.json.encode(actual), name)
    end
    assert.is_true(count > 0, "no cases found")
  end)

  it("names exactly the portal's rules, read from FieldRule, and has a case for each", function()
    local rules = rules_in_source("crates/rpf-domain/src/addons/records.rs", "FieldRule", pending)
    assert.are.same(rules, set(rpf.manifest.FIELD_RULES))
    local covered = {}
    for _, case in pairs(cases("records")) do
      if case.expect.error then
        covered[case.expect.error.error] = true
      end
    end
    assert.are.same(rules, covered)
  end)

  it("reads fields a script wrote, leaving the caller's table alone", function()
    local def = kit.types.widget
    local given = { label = "Pot", spot = { x = 1, y = 2, z = 3 }, tags = {}, meta = {} }
    local fields = assert(rpf.manifest.check_fields(def, given))
    assert.are.equal(
      '{"count":1,"label":"Pot","maybe":null,"meta":{},"spot":{"x":1,"y":2,"z":3},"tags":[]}',
      rpf.json.encode(fields)
    )
    assert.is_nil(getmetatable(given))
    assert.is_nil(given.count)
  end)

  it("refuses a JSON field holding a number the codec cannot carry", function()
    -- The corpus cannot hold one: this side would fail to read the case.
    local _, refusal = rpf.manifest.check_fields(kit.types.widget, { label = "Pot", blob = { n = 1e99 } })
    assert.are.same({ error = "wrong_type", field = "blob" }, refusal)
  end)

  it("refuses a table that contains itself instead of overflowing the stack", function()
    local cyclic = { label = "Pot" }
    cyclic.blob = { again = cyclic }
    local ok, fields, refusal = pcall(rpf.manifest.check_fields, kit.types.widget, cyclic)
    assert.is_true(ok, tostring(fields))
    assert.is_nil(fields)
    assert.are.same({ error = "wrong_type", field = "blob" }, refusal)

    local looped = { namespace = "acme_garden", version = "1.0.0", api = 1 }
    looped.title = looped
    local checked, manifest, why = pcall(rpf.manifest.check, looped)
    assert.is_true(checked, tostring(manifest))
    assert.are.same({ error = "wrong_type", path = "title" }, why)
  end)

  it("refuses a table whose keys are not an array's or an object's, marked or not", function()
    local def = kit.types.widget
    local cases = {
      { levels = { [0] = 1, [2] = 2 } },
      { levels = { 1, nil, 3 } },
      { levels = rpf.json.array({ 1, extra = 2 }) },
      { meta = rpf.json.object({ 1, a = 2 }) },
      { spot = { x = 1, y = 2, z = 3, [1] = 4 } },
    }
    for i, extra in ipairs(cases) do
      local fields = { label = "Pot" } ---@type table<string, any>
      local name = assert(next(extra))
      fields[name] = extra[name]
      local ok, checked, refusal = pcall(rpf.manifest.check_fields, def, fields)
      assert.is_true(ok, tostring(checked))
      assert.is_nil(checked, "case " .. i)
      assert.are.same({ error = "wrong_type", field = name }, refusal, "case " .. i)
    end
  end)

  it("refuses a JSON field holding an empty table it cannot tell the shape of", function()
    local _, refusal = rpf.manifest.check_fields(kit.types.widget, { label = "Pot", meta = { a = {} } })
    assert.are.same({ error = "wrong_type", field = "meta" }, refusal)
  end)
end)

describe("rpf.manifest versions", function()
  before_each(function()
    support.load_core()
  end)

  it("reads the same versions and ranges as the portal", function()
    for _, good in ipairs({ "0.0.0", "1.20.3", "999999.0.0" }) do
      assert.is_true(rpf.manifest.is_version(good), good)
    end
    for _, bad in ipairs({ "", "1", "1.2", "1.2.3.4", "01.2.3", "1.2.3-beta", "1.2.x", "1000000.0.0", "1..2" }) do
      assert.is_false(rpf.manifest.is_version(bad), bad)
    end
    for _, good in ipairs({ "*", "=1.2.3", ">=1.2.3", "^1", "^1.2", "^0.0.3", "~1", "~1.2.3" }) do
      assert.is_true(rpf.manifest.is_range(good), good)
    end
    for _, bad in ipairs({ "", "1.2.3", ">1.2.3", "<2.0.0", "=1.2", ">=1", "^", "^1.2.3.4", "^01", "**", "~1.x" }) do
      assert.is_false(rpf.manifest.is_range(bad), bad)
    end
  end)
end)
