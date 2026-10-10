---Addon manifests and the records of their types (J2): the rules that decide
---whether a manifest is valid, and whether a record's fields are valid for
---its type.
---
---**One rule set, ported.** `manifest.check` is the Lua twin of the portal's
---`Manifest::parse`, and `manifest.check_fields` of `TypeDef::check_fields`,
---rule for rule and in the same order, so the two sides give the same verdict
---and name the same first broken rule at the same path. The core checks an
---addon's manifest when it registers, before proposing it to the portal, and
---a record's fields before it changes a held record; the portal checks both
---again, because a game server is a hostile caller. Neither is tested
---against the other: both are held to the cases in `protocol/corpus/addons/`
---(`spec/manifest_spec.lua` here, `crates/rpf-domain/tests/addons.rs`
---there). The order is documented in `crates/rpf-domain/src/addons/`.
---
---**Data, never code.** A manifest only states bounds: there are no
---expressions and no patterns, so every check here is bounded and the portal
---can make the same ones without running anything an addon wrote.
---
---**Tables a script wrote are read as JSON.** A manifest or a record may come
---from a decoded frame (its tables marked by `rpf.json`) or from Lua an
---author wrote (unmarked). An unmarked table of string keys is an object, of
---keys 1 to n an array, and an empty one either, whichever the rule expects;
---anything else is not JSON and is refused where it stands. What `check` and
---`check_fields` return is a marked copy, which encodes exactly as the portal
---will read it.
---@class rpf.manifest
---@field MANIFEST_RULES string[] Every rule `check` can name: the portal's `ManifestRule`, as it serialises.
---@field FIELD_RULES string[] Every rule `check_fields` can name: the portal's `FieldRule`, as it serialises.
---@field MAX_MANIFEST_BYTES integer The largest manifest, serialised: `limits::MAX_MANIFEST_BYTES`.
---@field MAX_RECORD_BYTES integer The largest record's fields, serialised: `limits::MAX_RECORD_BYTES`.
---@field MAX_ADDONS_PER_SERVER integer `limits::MAX_ADDONS_PER_SERVER`, which also bounds `requires`.
---@field MAX_ADDON_PERMISSIONS integer `limits::MAX_ADDON_PERMISSIONS`.
---@field MAX_TYPES_PER_ADDON integer `limits::MAX_TYPES_PER_ADDON`.
---@field MAX_FIELDS_PER_TYPE integer `limits::MAX_FIELDS_PER_TYPE`.
---@field MAX_INDEXED_FIELDS_PER_TYPE integer `limits::MAX_INDEXED_FIELDS_PER_TYPE`.
---@field MAX_RECORDS_PER_TYPE integer `limits::MAX_RECORDS_PER_TYPE`.
local manifest = {}

local rpf = rpf
local json = rpf.json

manifest.MANIFEST_RULES = {
  "too_large",
  "wrong_type",
  "unknown_key",
  "missing",
  "name",
  "reserved",
  "version",
  "range",
  "bound",
  "too_many",
  "charset",
  "unknown_value",
  "duplicate",
  "unknown_field",
  "unknown_type",
  "foreign_type",
  "unknown_permission",
  "authority",
  "conflict",
  "not_indexable",
  "default",
  "requires_self",
}

manifest.FIELD_RULES = {
  "wrong_type",
  "unknown_field",
  "required",
  "not_nullable",
  "too_long",
  "too_short",
  "charset",
  "below_min",
  "above_max",
  "not_in_enum",
  "too_many_items",
  "too_large",
}

manifest.MAX_MANIFEST_BYTES = 64 * 1024
manifest.MAX_RECORD_BYTES = 16 * 1024
manifest.MAX_ADDONS_PER_SERVER = 32
manifest.MAX_ADDON_PERMISSIONS = 32
manifest.MAX_TYPES_PER_ADDON = 16
manifest.MAX_FIELDS_PER_TYPE = 64
manifest.MAX_INDEXED_FIELDS_PER_TYPE = 8
manifest.MAX_RECORDS_PER_TYPE = 50000

-- The rules' own bounds, mirroring `crates/rpf-domain/src/addons/`.
local MAX_NAME_BYTES = 32
local MAX_TITLE_BYTES = 64
local MAX_HELP_BYTES = 256
local MAX_API = 1000
local MAX_SCHEMA = 2147483647
local MAX_LIST_COLUMNS = 8
local MAX_STRING_BYTES = 1024
local MAX_TEXT_BYTES = 16 * 1024
local MAX_ENUM_VALUES = 64
local MAX_LIST_ITEMS = 64
local MAX_JSON_BYTES = 4096
local MAX_VERSION_PART = 999999
local MAX_SAFE = json.MAX_SAFE_INTEGER

---Namespaces no addon may take: `addons::RESERVED_NAMESPACES`.
local RESERVED_NAMESPACES = {
  rpf = true,
  core = true,
  addon = true,
  addons = true,
  player = true,
  config = true,
  guild = true,
  server = true,
  member = true,
  audit = true,
  players = true,
  auth = true,
  records = true,
  characters = true,
  jobs = true,
  staff = true,
  character = true,
  inventory = true,
  money = true,
  interactions = true,
}
---Field names a type may not declare: `manifest::RESERVED_FIELDS`.
local RESERVED_FIELDS = { id = true, type = true, owner = true, schema = true, revision = true }
---Permission names every addon has already: `manifest::RESERVED_PERMISSIONS`.
local RESERVED_PERMISSIONS = { view = true, edit = true }

---The kinds, and which a list may hold.
local KINDS = {
  string = true,
  text = true,
  integer = true,
  number = true,
  boolean = true,
  enum = true,
  timestamp = true,
  vector3 = true,
  ref = true,
  list = true,
  json = true,
}
local LISTABLE = {
  string = true,
  integer = true,
  number = true,
  boolean = true,
  enum = true,
  timestamp = true,
  ref = true,
}
---Kinds an index cannot key: too long, or not one value.
local UNINDEXABLE = { text = true, vector3 = true, list = true, json = true }
---The bound keys each kind may set, besides the ones every field may.
local BOUNDS = {
  string = { "charset", "max_len", "min_len" },
  text = { "max_len" },
  integer = { "max", "min" },
  number = { "max", "min" },
  enum = { "values" },
  ref = { "to" },
  list = { "max_items", "of" },
  json = { "max_bytes" },
  boolean = {},
  timestamp = {},
  vector3 = {},
}
---Keys every field may set.
local COMMON = {
  "default",
  "engine",
  "help",
  "hidden",
  "index",
  "nullable",
  "read_only",
  "required",
  "title",
  "type",
  "unique",
}
---Reference targets that are not a type.
local TARGETS = { player = true, character = true, employer = true, server = true, item = true, job = true }

-- Shapes -----------------------------------------------------------------

---Whether a table is unmarked and empty, which a script writes for both an
---empty object and an empty array.
---@param value any Anything.
---@return boolean blank True for `{}` with no mark.
local function is_blank(value)
  return type(value) == "table" and getmetatable(value) == nil and next(value) == nil
end

---Whether a value reads as a JSON object here.
---@param value any Anything.
---@return boolean object True for a marked object or a blank table.
local function is_object(value)
  return json.is_object(value) or is_blank(value)
end

---Whether a value reads as a JSON array here.
---@param value any Anything.
---@return boolean array True for a marked array or a blank table.
local function is_array(value)
  return json.is_array(value) or is_blank(value)
end

---What `mark` puts in place of a table that contains itself or nests past
---`json.MAX_DEPTH`: a table no rule reads as JSON (its key is neither a
---string nor an index), so it is refused where it stands rather than
---overflowing the stack.
---@return table not_json A fresh table with a boolean key.
local function not_json()
  return { [true] = true }
end

---A deep copy with every table a script wrote marked as JSON would decode
---it: string keys an object, keys 1 to n an array. A blank table stays blank
---(the rule that reads it marks it). A table that is neither, or whose mark
---its keys contradict, becomes `not_json()`, so any rule that reads it
---refuses it rather than reading part of it.
---@param value any Anything.
---@param depth integer? How deeply it is nested; 0 at the top.
---@param seen table<table, true>? Tables on the current path, to refuse cycles.
---@return any marked The copy.
local function mark(value, depth, seen)
  if type(value) ~= "table" or value == json.null then
    return value
  end
  depth, seen = depth or 0, seen or {}
  if seen[value] or depth > json.MAX_DEPTH then
    return not_json()
  end
  seen[value] = true
  local out = {}
  local strings, indexes, count, max = 0, 0, 0, 0
  for k, v in pairs(value) do
    out[k] = mark(v, depth + 1, seen)
    count = count + 1
    if type(k) == "string" then
      strings = strings + 1
    elseif type(k) == "number" and k >= 1 and k == math.floor(k) then
      indexes = indexes + 1
      if k > max then
        max = k
      end
    end
  end
  seen[value] = nil
  -- An object has only string keys; an array only the indexes 1 to n. A
  -- mark is believed only if the keys bear it out, so a marked array with
  -- a stray key, or a table with a hole, is refused rather than read with
  -- part of it silently dropped.
  local object_shape = strings == count
  local array_shape = indexes == count and max == count
  if count == 0 and not json.is_object(value) and not json.is_array(value) then
    return out
  elseif json.is_object(value) or (object_shape and not json.is_array(value)) then
    return object_shape and json.object(out) or not_json()
  elseif json.is_array(value) or array_shape then
    return array_shape and json.array(out) or not_json()
  end
  return not_json()
end

---An object's keys in byte order.
---@param object table The object.
---@return string[] keys The keys.
local function sorted_keys(object)
  local keys = {}
  for k in pairs(object) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  return keys
end

---How many entries an object has.
---@param object table The object.
---@return integer count The count.
local function size(object)
  local n = 0
  for _ in pairs(object) do
    n = n + 1
  end
  return n
end

---Whether a string is `[a-z][a-z0-9_]*`.
---@param s string The string.
---@return boolean word True if it is.
local function is_word(s)
  return s:match("^[a-z][a-z0-9_]*$") ~= nil
end

---Whether a value is a namespace: a word of 3 to 32 bytes.
---@param s any The value.
---@return boolean namespace True if it is.
local function is_namespace(s)
  return type(s) == "string" and #s >= 3 and #s <= 32 and is_word(s)
end

---Whether a value is a name: a word of at most 32 bytes.
---@param s any The value.
---@return boolean name True if it is.
local function is_name(s)
  return type(s) == "string" and #s <= MAX_NAME_BYTES and is_word(s)
end

---Whether a value is a config slug: a word of at most 64 bytes
---(`slug::is_identifier`).
---@param s any The value.
---@return boolean slug True if it is.
local function is_slug(s)
  return type(s) == "string" and #s <= 64 and is_word(s)
end

---Whether a value is a string the portal can read: valid UTF-8.
---@param s any The value.
---@return boolean text True for a UTF-8 string.
local function is_text(s)
  return type(s) == "string" and json.is_utf8(s)
end

---Whether a string holds a control character: C0, DEL or C1 (U+0080 to
---U+009F, which UTF-8 writes as C2 80 to C2 9F).
---@param s string The string.
---@param allowed string? A pattern class of C0 characters to let through, like `\t\n\r`.
---@return boolean control True if it holds one not allowed.
local function has_control(s, allowed)
  local c0 = s:gsub(allowed and ("[" .. allowed .. "]") or "^$", "")
  return c0:find("%c") ~= nil or s:find("\194[\128-\159]") ~= nil
end

---A whole number within ±(2^53 − 1), the integers both sides hold exactly.
---@param value any The value.
---@return number? integer The number, or nil.
local function integer(value)
  if type(value) == "number" and value == math.floor(value) and value >= -MAX_SAFE and value <= MAX_SAFE then
    return value
  end
  return nil
end

---A finite number within ±(2^53 − 1).
---@param value any The value.
---@return number? number The number, or nil.
local function number(value)
  if type(value) == "number" and value == value and value >= -MAX_SAFE and value <= MAX_SAFE then
    return value
  end
  return nil
end

---Whether a string is a canonical uuid: lowercase, hyphenated.
---@param s any The value.
---@return boolean uuid True if it is.
local function is_uuid(s)
  local h = "[0-9a-f]"
  return type(s) == "string"
    and s:match("^" .. h:rep(8) .. "%-" .. h:rep(4) .. "%-" .. h:rep(4) .. "%-" .. h:rep(4) .. "%-" .. h:rep(12) .. "$")
      ~= nil
end

-- Versions ---------------------------------------------------------------

---One part of a version: digits, no leading zero, at most 999999.
---@param s string The part.
---@return boolean ok True if it is one.
local function version_part(s)
  if not s:match("^%d+$") or #s > 6 or (#s > 1 and s:sub(1, 1) == "0") then
    return false
  end
  return tonumber(s) <= MAX_VERSION_PART
end

---Splits `a.b.c` into parts.
---@param s string The text.
---@return string[] parts The parts, empty ones included.
local function split_dots(s)
  local parts = {}
  for part in (s .. "."):gmatch("([^.]*)%.") do
    parts[#parts + 1] = part
  end
  return parts
end

---Whether a string is a release version, `MAJOR.MINOR.PATCH`.
---@param s string The text.
---@return boolean ok True if it is.
function manifest.is_version(s)
  local parts = split_dots(s)
  if #parts ~= 3 then
    return false
  end
  for _, part in ipairs(parts) do
    if not version_part(part) then
      return false
    end
  end
  return true
end

---Whether a string is a version range: `*`, `=X.Y.Z`, `>=X.Y.Z`, or `^`/`~`
---followed by one to three parts. Only the shape is checked here; the
---portal matches ranges at install.
---@param s string The text.
---@return boolean ok True if it is.
function manifest.is_range(s)
  if s == "*" then
    return true
  end
  local op, rest = s:match("^(>=)(.*)$")
  if not op then
    op, rest = s:match("^([=^~])(.*)$")
  end
  if not op then
    return false
  end
  local parts = split_dots(rest)
  local partial = op == "^" or op == "~"
  if #parts > 3 or (#parts < 3 and not partial) then
    return false
  end
  for _, part in ipairs(parts) do
    if not version_part(part) then
      return false
    end
  end
  return true
end

-- Manifests --------------------------------------------------------------

---A refusal: the rule and where.
---@param rule string One of `MANIFEST_RULES`.
---@param path string The path.
---@return nil
---@return table refusal `{ error, path }`.
local function refuse(rule, path)
  return nil, json.object({ error = rule, path = path })
end

---The path of a key under a path.
---@param path string The parent's path.
---@param key string|integer The key, or a list index from zero.
---@return string path The child's path.
local function at(path, key)
  if path == "" then
    return tostring(key)
  end
  return path .. "." .. tostring(key)
end

---Checks an object's keys: no key outside `allowed` (the first in byte order
---is named), then every key in `required`, in order.
---@param value any The value.
---@param path string Its path.
---@param allowed table<string, true> The keys it may have.
---@param required string[] The keys it must have, in the order they are named.
---@return table? object The object, or nil.
---@return table? refusal Why not.
local function object(value, path, allowed, required)
  if not is_object(value) then
    return refuse("wrong_type", path)
  end
  for _, key in ipairs(sorted_keys(value)) do
    if not allowed[key] then
      return refuse("unknown_key", at(path, key))
    end
  end
  for _, key in ipairs(required) do
    if value[key] == nil then
      return refuse("missing", at(path, key))
    end
  end
  return value
end

---A set of strings.
---@param list string[] The strings.
---@return table<string, true> set The set.
local function set(list)
  local out = {}
  for _, k in ipairs(list) do
    out[k] = true
  end
  return out
end

---A map keyed by names: an object of at most `max` entries.
---@param value any The value.
---@param path string Its path.
---@param max integer The most entries.
---@return table? map The map, or nil.
---@return table? refusal Why not.
local function named_map(value, path, max)
  if not is_object(value) then
    return refuse("wrong_type", path)
  end
  if size(value) > max then
    return refuse("too_many", path)
  end
  return value
end

---A title, help text or description: 1 to `max` bytes, no control
---character.
---@param value any The value.
---@param path string Its path.
---@param max integer The most bytes.
---@return true? ok True, or nil.
---@return table? refusal Why not.
local function label(value, path, max)
  if not is_text(value) then
    return refuse("wrong_type", path)
  end
  if #value == 0 or #value > max then
    return refuse("bound", path)
  end
  if has_control(value) then
    return refuse("charset", path)
  end
  return true
end

---An integer within `low..high`.
---@param value any The value.
---@param path string Its path.
---@param low number The least.
---@param high number The greatest.
---@return number? n The integer, or nil.
---@return table? refusal Why not.
local function bounded(value, path, low, high)
  local n = integer(value)
  if not n then
    return refuse("wrong_type", path)
  end
  if n < low or n > high then
    return refuse("bound", path)
  end
  return n
end

---One of a fixed set of strings.
---@param value any The value.
---@param path string Its path.
---@param values table<string, true> The strings it may be.
---@return true? ok True, or nil.
---@return table? refusal Why not.
local function one_of(value, path, values)
  if type(value) ~= "string" then
    return refuse("wrong_type", path)
  end
  if not values[value] then
    return refuse("unknown_value", path)
  end
  return true
end

---A list of at most `max` items.
---@param value any The value.
---@param path string Its path.
---@param max integer The most items.
---@return table? list The list, marked, or nil.
---@return table? refusal Why not.
local function list(value, path, max)
  if not is_array(value) then
    return refuse("wrong_type", path)
  end
  if #value > max then
    return refuse("too_many", path)
  end
  return json.array(value)
end

---Whether a list holds a value equal to `value` before index `i`.
---@param items table The list.
---@param i integer The index, from one.
---@return boolean seen True if it does.
local function seen_before(items, i)
  for j = 1, i - 1 do
    if items[j] == items[i] then
      return true
    end
  end
  return false
end

local check_value

---What a type's fields need to know about the manifest around them.
---@class rpf.manifest.Context
---@field namespace string The manifest's namespace.
---@field types table<string, true> The names of its types.
---@field requires table<string, true> The namespaces it requires.
---@field permissions table<string, true> The permissions it declares.

---A field's `type` or `of`: present, a string, one of `kinds`.
---@param field table The field.
---@param path string Its path.
---@param key string `type` or `of`.
---@param kinds table<string, true> The kinds it may be.
---@return string? kind The kind, or nil.
---@return table? refusal Why not.
local function kind_at(field, path, key, kinds)
  local value = field[key]
  if value == nil then
    return refuse("missing", at(path, key))
  end
  if type(value) ~= "string" then
    return refuse("wrong_type", at(path, key))
  end
  if not kinds[value] then
    return refuse("unknown_value", at(path, key))
  end
  return value
end

---One field: the order is `manifest::check_field`'s.
---@param field any The field.
---@param path string Its path.
---@param context rpf.manifest.Context The manifest around it.
---@return table? field The field, normalised, or nil.
---@return table? refusal Why not.
local function check_field(field, path, context)
  if not is_object(field) then
    return refuse("wrong_type", path)
  end
  local kind, err = kind_at(field, path, "type", KINDS)
  if not kind then
    return nil, err
  end
  local item_kind = kind
  if kind == "list" then
    local of, why = kind_at(field, path, "of", LISTABLE)
    if not of then
      return nil, why
    end
    item_kind = of
  end

  local allowed = set(COMMON)
  for _, key in ipairs(BOUNDS[kind]) do
    allowed[key] = true
  end
  if kind == "list" then
    for _, key in ipairs(BOUNDS[item_kind]) do
      allowed[key] = true
    end
  end
  for _, key in ipairs(sorted_keys(field)) do
    if not allowed[key] then
      return refuse("unknown_key", at(path, key))
    end
  end
  local needed = (item_kind == "enum" and "values") or (item_kind == "ref" and "to") or nil
  if needed and field[needed] == nil then
    return refuse("missing", at(path, needed))
  end

  local out = json.copy(field)
  setmetatable(out, getmetatable(json.object()))
  for _, key in ipairs({ "required", "nullable", "index", "unique", "hidden", "read_only", "engine" }) do
    if field[key] ~= nil and type(field[key]) ~= "boolean" then
      return refuse("wrong_type", at(path, key))
    end
  end
  if field.title ~= nil then
    local ok, refusal = label(field.title, at(path, "title"), MAX_TITLE_BYTES)
    if not ok then
      return nil, refusal
    end
  end
  if field.help ~= nil then
    local ok, refusal = label(field.help, at(path, "help"), MAX_HELP_BYTES)
    if not ok then
      return nil, refusal
    end
  end

  if item_kind == "string" then
    local max = MAX_STRING_BYTES
    if field.max_len ~= nil then
      local n, refusal = bounded(field.max_len, at(path, "max_len"), 1, MAX_STRING_BYTES)
      if not n then
        return nil, refusal
      end
      max = n
    end
    if field.min_len ~= nil then
      local n, refusal = bounded(field.min_len, at(path, "min_len"), 0, max)
      if not n then
        return nil, refusal
      end
    end
    if field.charset ~= nil then
      local ok, refusal = one_of(field.charset, at(path, "charset"), set({ "identifier", "printable", "any" }))
      if not ok then
        return nil, refusal
      end
    end
  elseif item_kind == "text" then
    if field.max_len ~= nil then
      local n, refusal = bounded(field.max_len, at(path, "max_len"), 1, MAX_TEXT_BYTES)
      if not n then
        return nil, refusal
      end
    end
  elseif item_kind == "integer" then
    local bounds = {}
    for _, key in ipairs({ "min", "max" }) do
      if field[key] ~= nil then
        local n, refusal = bounded(field[key], at(path, key), -MAX_SAFE, MAX_SAFE)
        if not n then
          return nil, refusal
        end
        bounds[key] = n
      end
    end
    if bounds.min and bounds.max and bounds.min > bounds.max then
      return refuse("bound", at(path, "min"))
    end
  elseif item_kind == "number" then
    local bounds = {}
    for _, key in ipairs({ "min", "max" }) do
      if field[key] ~= nil then
        local n = number(field[key])
        if not n then
          return refuse(type(field[key]) == "number" and "bound" or "wrong_type", at(path, key))
        end
        bounds[key] = n
      end
    end
    if bounds.min and bounds.max and bounds.min > bounds.max then
      return refuse("bound", at(path, "min"))
    end
  elseif item_kind == "enum" then
    local values, refusal = list(field.values, at(path, "values"), MAX_ENUM_VALUES)
    if not values then
      return nil, refusal
    end
    if #values == 0 then
      return refuse("bound", at(path, "values"))
    end
    for i, value in ipairs(values) do
      local item = at(at(path, "values"), i - 1)
      if type(value) ~= "string" then
        return refuse("wrong_type", item)
      end
      if not is_name(value) then
        return refuse("name", item)
      end
      if seen_before(values, i) then
        return refuse("duplicate", item)
      end
    end
    out.values = json.array(json.copy(values))
  elseif item_kind == "ref" then
    local to_path = at(path, "to")
    local to = field.to
    if type(to) ~= "string" then
      return refuse("wrong_type", to_path)
    end
    if not TARGETS[to] then
      local namespace, name = to:match("^([^.]*)%.([^.]*)$")
      if not namespace or not is_namespace(namespace) or not is_name(name) then
        return refuse("unknown_value", to_path)
      end
      if namespace == context.namespace then
        if not context.types[name] then
          return refuse("unknown_type", to_path)
        end
      elseif not context.requires[namespace] then
        return refuse("foreign_type", to_path)
      end
    end
  end
  if kind == "list" and field.max_items ~= nil then
    local n, refusal = bounded(field.max_items, at(path, "max_items"), 1, MAX_LIST_ITEMS)
    if not n then
      return nil, refusal
    end
  elseif kind == "json" and field.max_bytes ~= nil then
    local n, refusal = bounded(field.max_bytes, at(path, "max_bytes"), 1, MAX_JSON_BYTES)
    if not n then
      return nil, refusal
    end
  end

  if field.required == true and field.nullable == true then
    return refuse("conflict", at(path, "nullable"))
  end
  if field.index == true and UNINDEXABLE[kind] then
    return refuse("not_indexable", at(path, "index"))
  end
  if field.unique == true and field.index ~= true then
    return refuse("conflict", at(path, "unique"))
  end

  if field.default ~= nil then
    local default_path = at(path, "default")
    if item_kind == "ref" then
      return refuse("default", default_path)
    end
    if field.default == json.null then
      if field.nullable ~= true then
        return refuse("default", default_path)
      end
    else
      local value = check_value(out, field.default)
      if value == nil then
        return refuse("default", default_path)
      end
      out.default = value
    end
  end
  return out
end

---One type: the order is `manifest::check_type`'s.
---@param def any The type.
---@param path string Its path.
---@param context rpf.manifest.Context The manifest around it.
---@return table? type The type, normalised, or nil.
---@return table? refusal Why not.
local function check_type(def, path, context)
  local allowed = set({ "actions", "authority", "fields", "hold", "limit", "list", "owners", "schema", "title" })
  local map, err = object(def, path, allowed, { "schema", "authority", "fields" })
  if not map then
    return nil, err
  end
  local out = json.object()
  for k, v in pairs(map) do
    out[k] = v
  end

  local ok, refusal ---@type any, table?
  ok, refusal = bounded(map.schema, at(path, "schema"), 1, MAX_SCHEMA)
  if not ok then
    return nil, refusal
  end
  ok, refusal = one_of(map.authority, at(path, "authority"), set({ "config", "live" }))
  if not ok then
    return nil, refusal
  end
  local live = map.authority == "live"

  if map.owners ~= nil and not live then
    return refuse("authority", at(path, "owners"))
  elseif map.owners == nil and live then
    return refuse("missing", at(path, "owners"))
  elseif map.owners ~= nil then
    local owners_path = at(path, "owners")
    local owners, why = list(map.owners, owners_path, 4)
    if not owners then
      return nil, why
    end
    if #owners == 0 then
      return refuse("bound", owners_path)
    end
    for i, owner in ipairs(owners) do
      local item = at(owners_path, i - 1)
      ok, refusal = one_of(owner, item, set({ "player", "character", "employer", "server" }))
      if not ok then
        return nil, refusal
      end
      if seen_before(owners, i) then
        return refuse("duplicate", item)
      end
    end
    out.owners = owners
  end

  if map.hold ~= nil then
    if not live then
      return refuse("authority", at(path, "hold"))
    end
    ok, refusal = one_of(map.hold, at(path, "hold"), set({ "owner", "server" }))
    if not ok then
      return nil, refusal
    end
  end

  if map.title ~= nil then
    ok, refusal = label(map.title, at(path, "title"), MAX_TITLE_BYTES)
    if not ok then
      return nil, refusal
    end
  end

  local fields_path = at(path, "fields")
  local fields, why = named_map(map.fields, fields_path, manifest.MAX_FIELDS_PER_TYPE)
  if not fields then
    return nil, why
  end
  if next(fields) == nil then
    return refuse("bound", fields_path)
  end
  local checked = json.object()
  local indexed = 0
  for _, key in ipairs(sorted_keys(fields)) do
    local field_path = at(fields_path, key)
    if not is_name(key) then
      return refuse("name", field_path)
    end
    if RESERVED_FIELDS[key] then
      return refuse("reserved", field_path)
    end
    local field, refused = check_field(fields[key], field_path, context)
    if not field then
      return nil, refused
    end
    if field.index == true then
      indexed = indexed + 1
    end
    checked[key] = field
  end
  if indexed > manifest.MAX_INDEXED_FIELDS_PER_TYPE then
    return refuse("too_many", fields_path)
  end
  out.fields = checked

  if map.list ~= nil then
    local list_path = at(path, "list")
    local columns, refused = list(map.list, list_path, MAX_LIST_COLUMNS)
    if not columns then
      return nil, refused
    end
    for i, column in ipairs(columns) do
      local item = at(list_path, i - 1)
      if type(column) ~= "string" then
        return refuse("wrong_type", item)
      end
      if fields[column] == nil then
        return refuse("unknown_field", item)
      end
      if seen_before(columns, i) then
        return refuse("duplicate", item)
      end
    end
    out.list = columns
  end

  if map.actions ~= nil then
    local actions_path = at(path, "actions")
    local actions, refused = object(map.actions, actions_path, set({ "create", "delete", "edit", "view" }), {})
    if not actions then
      return nil, refused
    end
    for _, action in ipairs({ "view", "create", "edit", "delete" }) do
      local grant = actions[action]
      if grant ~= nil and grant ~= false then
        local action_path = at(actions_path, action)
        if type(grant) ~= "string" then
          return refuse("wrong_type", action_path)
        end
        if not RESERVED_PERMISSIONS[grant] and not context.permissions[grant] then
          return refuse("unknown_permission", action_path)
        end
      end
    end
    out.actions = json.object(json.copy(actions))
  end

  if map.limit ~= nil then
    ok, refusal = bounded(map.limit, at(path, "limit"), 1, manifest.MAX_RECORDS_PER_TYPE)
    if not ok then
      return nil, refusal
    end
  end
  return out
end

---Checks a manifest and returns it normalised, or names the first rule it
---breaks and where: `Manifest::parse`, rule for rule.
---
---The result is a marked copy, every empty table given the shape its rule
---expects, so it encodes as the portal reads it; the caller's table is not
---changed.
---@param value any The manifest, as an author wrote it or a frame decoded it.
---@return table? manifest The manifest, normalised, or nil.
---@return table? refusal `{ error = <rule>, path = <where> }`, the path's keys joined by `.` and list items numbered from zero.
function manifest.check(value)
  local m = mark(value)
  -- Nil only for what no frame could carry, which the walk refuses where it
  -- stands.
  local bytes = json.serde_bytes(m)
  if bytes and bytes > manifest.MAX_MANIFEST_BYTES then
    return refuse("too_large", "")
  end
  local allowed = set({ "api", "namespace", "permissions", "requires", "title", "types", "version" })
  local map, err = object(m, "", allowed, { "namespace", "version", "api", "title" })
  if not map then
    return nil, err
  end
  local out = json.object()
  for k, v in pairs(map) do
    out[k] = v
  end

  local namespace = map.namespace
  if type(namespace) ~= "string" then
    return refuse("wrong_type", "namespace")
  end
  if not is_namespace(namespace) then
    return refuse("name", "namespace")
  end
  if RESERVED_NAMESPACES[namespace] then
    return refuse("reserved", "namespace")
  end
  if type(map.version) ~= "string" then
    return refuse("wrong_type", "version")
  end
  if not manifest.is_version(map.version) then
    return refuse("version", "version")
  end
  local ok, refusal ---@type any, table?
  ok, refusal = bounded(map.api, "api", 1, MAX_API)
  if not ok then
    return nil, refusal
  end
  ok, refusal = label(map.title, "title", MAX_TITLE_BYTES)
  if not ok then
    return nil, refusal
  end

  local requires = {}
  if map.requires ~= nil then
    local entries, why = named_map(map.requires, "requires", manifest.MAX_ADDONS_PER_SERVER)
    if not entries then
      return nil, why
    end
    for _, key in ipairs(sorted_keys(entries)) do
      local path = at("requires", key)
      if not is_namespace(key) then
        return refuse("name", path)
      end
      if key == namespace then
        return refuse("requires_self", path)
      end
      if type(entries[key]) ~= "string" then
        return refuse("wrong_type", path)
      end
      if not manifest.is_range(entries[key]) then
        return refuse("range", path)
      end
      requires[key] = true
    end
    out.requires = json.object(json.copy(entries))
  end

  local permissions = {}
  if map.permissions ~= nil then
    local entries, why = named_map(map.permissions, "permissions", manifest.MAX_ADDON_PERMISSIONS)
    if not entries then
      return nil, why
    end
    for _, key in ipairs(sorted_keys(entries)) do
      local path = at("permissions", key)
      if not is_name(key) then
        return refuse("name", path)
      end
      if RESERVED_PERMISSIONS[key] then
        return refuse("reserved", path)
      end
      ok, refusal = label(entries[key], path, MAX_HELP_BYTES)
      if not ok then
        return nil, refusal
      end
      permissions[key] = true
    end
    out.permissions = json.object(json.copy(entries))
  end

  if map.types ~= nil then
    local entries, why = named_map(map.types, "types", manifest.MAX_TYPES_PER_ADDON)
    if not entries then
      return nil, why
    end
    local names = {}
    for key in pairs(entries) do
      names[key] = true
    end
    ---@type rpf.manifest.Context
    local context = { namespace = namespace, types = names, requires = requires, permissions = permissions }
    local types = json.object()
    for _, key in ipairs(sorted_keys(entries)) do
      local path = at("types", key)
      if not is_name(key) then
        return refuse("name", path)
      end
      local def, refused = check_type(entries[key], path, context)
      if not def then
        return nil, refused
      end
      types[key] = def
    end
    out.types = types
  end
  return out
end

-- Records ----------------------------------------------------------------

---How deeply a `json` field may nest, the object itself counting as one:
---`records::MAX_JSON_DEPTH`.
local MAX_JSON_DEPTH = 16

---How deeply a value nests: 0 for a scalar, 1 for a table of scalars.
---@param value any The value, already marked.
---@return integer depth The depth.
local function json_depth(value)
  if type(value) ~= "table" or value == json.null then
    return 0
  end
  local deepest = 0
  for _, v in pairs(value) do
    local d = json_depth(v)
    if d > deepest then
      deepest = d
    end
  end
  return deepest + 1
end

---A field's refusal.
---@param rule string One of `FIELD_RULES`.
---@param field string The field, or `""` for the record.
---@param item integer? A list item, from zero.
---@return nil
---@return table refusal `{ error, field, item? }`.
local function refuse_field(rule, field, item)
  return nil, json.object({ error = rule, field = field, item = item })
end

---Checks one scalar value (a list's item, or a field that is not a list).
---@param def table The field.
---@param kind string The kind to check it as.
---@param value any The value, not null.
---@return any? value The value as stored, or nil.
---@return string? rule The rule it breaks.
local function scalar(def, kind, value)
  if kind == "string" then
    if not is_text(value) then
      return nil, "wrong_type"
    end
    if #value > (def.max_len or MAX_STRING_BYTES) then
      return nil, "too_long"
    end
    if #value < (def.min_len or 0) then
      return nil, "too_short"
    end
    local charset = def.charset or "printable"
    local fits = not value:find("[\n\r]")
    if fits and charset == "identifier" then
      fits = is_word(value)
    elseif fits and charset == "printable" then
      fits = not has_control(value)
    end
    if not fits then
      return nil, "charset"
    end
    return value
  elseif kind == "text" then
    if not is_text(value) then
      return nil, "wrong_type"
    end
    if #value > (def.max_len or MAX_TEXT_BYTES) then
      return nil, "too_long"
    end
    if has_control(value, "\t\n\r") then
      return nil, "charset"
    end
    return value
  elseif kind == "integer" or kind == "number" then
    local n = (kind == "integer" and integer or number)(value)
    if not n then
      return nil, "wrong_type"
    end
    if def.min ~= nil and n < def.min then
      return nil, "below_min"
    end
    if def.max ~= nil and n > def.max then
      return nil, "above_max"
    end
    return n
  elseif kind == "boolean" then
    if type(value) ~= "boolean" then
      return nil, "wrong_type"
    end
    return value
  elseif kind == "enum" then
    if type(value) ~= "string" then
      return nil, "wrong_type"
    end
    for _, allowed in ipairs(def.values or {}) do
      if allowed == value then
        return value
      end
    end
    return nil, "not_in_enum"
  elseif kind == "timestamp" then
    local n = integer(value)
    if not n or n < 0 then
      return nil, "wrong_type"
    end
    return n
  elseif kind == "vector3" then
    if not json.is_object(value) or size(value) ~= 3 then
      return nil, "wrong_type"
    end
    for _, axis in ipairs({ "x", "y", "z" }) do
      if not number(value[axis]) then
        return nil, "wrong_type"
      end
    end
    local vector = json.object({ x = value.x, y = value.y, z = value.z })
    return vector
  elseif kind == "ref" then
    local fits
    if def.to == "item" then
      fits = is_slug(value)
    elseif def.to == "job" then
      fits = json.is_object(value) and size(value) == 2 and is_slug(value.employer) and is_slug(value.job)
    else
      fits = is_uuid(value)
    end
    if not fits then
      return nil, "wrong_type"
    end
    return json.copy(value)
  elseif kind == "json" then
    if not is_object(value) or json_depth(value) > MAX_JSON_DEPTH then
      return nil, "wrong_type"
    end
    local normalized
    if is_blank(value) then
      normalized = json.object()
    else
      local text = json.encode(value)
      normalized = text and json.decode(text)
    end
    if not json.is_object(normalized) then
      return nil, "wrong_type"
    end
    local bytes = json.serde_bytes(normalized)
    if not bytes then
      return nil, "wrong_type"
    end
    if bytes > (def.max_bytes or MAX_JSON_BYTES) then
      return nil, "too_large"
    end
    return normalized
  end
  return nil, "wrong_type"
end

---Checks one non-null value against a field.
---@param def table The field.
---@param value any The value.
---@return any? value The value as stored, or nil.
---@return string? rule The rule it breaks.
---@return integer? item In a list, which item, from zero.
check_value = function(def, value)
  if def.type ~= "list" then
    local out, rule = scalar(def, def.type, value)
    return out, rule
  end
  if not is_array(value) then
    return nil, "wrong_type"
  end
  if #value > (def.max_items or MAX_LIST_ITEMS) then
    return nil, "too_many_items"
  end
  local out = json.array()
  for i, item in ipairs(value) do
    if item == json.null then
      return nil, "wrong_type", i - 1
    end
    local checked, rule = scalar(def, def.of, item)
    if checked == nil then
      return nil, rule, i - 1
    end
    out[i] = checked
  end
  return out
end

---A record's fields with every absent one that has a default given it: what
---a record reads as.
---@param def table The type, from a checked manifest.
---@param fields table The fields.
---@return table fields A marked copy.
function manifest.with_defaults(def, fields)
  local out = json.object()
  for k, v in pairs(fields) do
    out[k] = json.copy(v)
  end
  for name, field in pairs(def.fields) do
    if out[name] == nil and field.default ~= nil then
      out[name] = json.copy(field.default)
    end
  end
  return out
end

---Checks a whole record's fields against its type and returns them as
---stored, or names the first rule broken: `TypeDef::check_fields`, rule for
---rule.
---@param def table The type, from a checked manifest.
---@param fields any The fields.
---@return table? fields A marked copy with defaults in place, or nil.
---@return table? refusal `{ error = <rule>, field = <name or "">, item = <index>? }`.
function manifest.check_fields(def, fields)
  local given = mark(fields)
  if not is_object(given) then
    return refuse_field("wrong_type", "")
  end
  for _, name in ipairs(sorted_keys(given)) do
    if def.fields[name] == nil then
      return refuse_field("unknown_field", name)
    end
  end
  given = manifest.with_defaults(def, given)
  local out = json.object()
  for _, name in ipairs(sorted_keys(def.fields)) do
    local field = def.fields[name]
    local value = given[name]
    if value == nil or value == json.null then
      if field.required == true then
        return refuse_field("required", name)
      elseif value == json.null and field.nullable ~= true then
        return refuse_field("not_nullable", name)
      end
      out[name] = value
    else
      local checked, rule, item = check_value(field, value)
      if checked == nil then
        return refuse_field(rule --[[@as string]], name, item)
      end
      out[name] = checked
    end
  end
  local bytes = json.serde_bytes(out)
  if not bytes or bytes > manifest.MAX_RECORD_BYTES then
    return refuse_field("too_large", "")
  end
  return out
end

---Applies a patch to a record's fields and checks the result whole:
---`TypeDef::apply_patch`. Fields the patch does not name keep their value; a
---null clears a nullable one.
---@param def table The type, from a checked manifest.
---@param current table The record's fields as they are.
---@param patch any The fields to change.
---@return table? fields The new fields, or nil.
---@return table? refusal Why not, as `check_fields` names it.
function manifest.apply_patch(def, current, patch)
  local changes = mark(patch)
  if not is_object(changes) then
    return refuse_field("wrong_type", "")
  end
  for _, name in ipairs(sorted_keys(changes)) do
    if def.fields[name] == nil then
      return refuse_field("unknown_field", name)
    end
  end
  local merged = manifest.with_defaults(def, current)
  for name, value in pairs(changes) do
    merged[name] = value
  end
  return manifest.check_fields(def, merged)
end

rpf.manifest = manifest
return manifest
