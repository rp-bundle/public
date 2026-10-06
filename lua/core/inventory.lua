---Inventory (D6): what a held container holds, the rules it must keep, and
---the moves a server makes on it.
---
---**One validator, ported.** `inventory.validate` is the Lua twin of the
---portal's `ContainerContents::validate`, rule for rule and in the same
---order, so it gives the same verdict and names the same first broken rule.
---The game server runs it before applying any change; the portal runs its
---own before it believes the report. If the two drifted, the game would
---accept moves the portal then refused, and the container would stop
---syncing. Neither is tested against the other: both are held to the cases
---in `protocol/corpus/containers/` (`spec/containers_spec.lua` here,
---`crates/rpf-domain/tests/containers.rs` there).
---
---**Every change is validated whole, before anything moves.** A mutation
---works on a copy of the contents, validates the result against the
---container's flags and the config's catalog, and only then hands it to
---`rpf.records.set_contents`, which validates again and marks the container
---for C7's next report. A refused change leaves every container exactly as
---it was. A move between two containers validates both before writing
---either, so it never leaves one side applied.
---
---**Only held containers change.** Contents are read from `rpf.records`
---every time, never kept here, so a container this server does not hold
---cannot be changed, and one released mid-script is refused as `not_held`.
---
---**`ItemData` is the server's own.** A stack's `data` is an opaque JSON
---object: nothing here reads it, mutations copy it as it is, two stacks
---merge only when their data is identical, and it is measured the way the
---portal measures it (serialised by serde_json), so the size bound agrees
---to the byte.
---@class rpf.inventory
---@field MAX_DATA_BYTES integer The most one stack's serialised `ItemData` may take, in bytes: `ItemCatalog::default`'s `max_data_bytes`, the bound the portal applies to every server. Not in the config snapshot, so mirrored here, and `spec/inventory_spec.lua` reads the Rust default to keep the two equal.
---@field MAX_STACKS integer The most stacks (list) or placements (grid) one container may hold: `ItemCatalog::default`'s `max_stacks`, mirrored the same way.
---@field DEFAULTS rpf.inventory.ItemDef What an unknown item behaves as when the config carries no `item_defaults` (none has arrived yet): `ItemCatalog::default`'s, which is also what the portal uses then.
---@field ERRORS string[] Every rule `validate` can name, the portal's `ContentsError` tags plus the two only Lua can see: `malformed` (contents the portal could not decode) and `unknown_flag` (a flag from a newer portal, which this core cannot enforce, so it refuses rather than guess).
local inventory = {}

local rpf = rpf
local json = rpf.json

inventory.MAX_DATA_BYTES = 4096
inventory.MAX_STACKS = 500
inventory.DEFAULTS = { weight = 1, size = { x = 1, y = 1 }, stack_limit = 1 }
inventory.ERRORS = {
  "malformed",
  "unknown_flag",
  "wrong_layout",
  "too_many_stacks",
  "data_too_large",
  "empty_stack",
  "stack_too_large",
  "duplicate",
  "too_heavy",
  "out_of_bounds",
  "overlap",
}

local U32_MAX = 4294967295
local I32_MIN, I32_MAX = -2147483648, 2147483647

---How an item behaves in a container: the three fields validation reads.
---@class rpf.inventory.ItemDef
---@field weight number Weight of one unit.
---@field size { x: number, y: number } Footprint in a grid, in cells, before rotation.
---@field stack_limit number The most one stack may hold.

---What `validate` checks contents against: the item definitions, what an
---unknown item behaves as, and the two size bounds.
---@class rpf.inventory.Catalog
---@field defaults rpf.inventory.ItemDef What an item `lookup` does not know behaves as.
---@field lookup fun(slug: string): table? An item's definition by slug, or nil if the catalog has none.
---@field max_data_bytes number The most one stack's serialised data may take, in bytes.
---@field max_stacks number The most stacks or placements one container may hold.

---Why contents were refused: the portal's `ContentsError`, field for field
---as it serialises (`{ error = "too_heavy", limit = 19, actual = 20 }`), so
---a script, a log line and the shared corpus all read the same thing.
---@class rpf.inventory.Refusal
---@field error string The rule, one of `inventory.ERRORS`.

-- Shapes ----------------------------------------------------------------------

---Whether a value is an integer within a range, as serde reads `u32`/`i32`.
---@param value any The value.
---@param min number The smallest allowed.
---@param max number The largest allowed.
---@return boolean ok True for an integer from `min` to `max`.
local function integer_in(value, min, max)
  return type(value) == "number" and value == math.floor(value) and value >= min and value <= max
end

---The number of bytes serde_json writes for a string, quotes included, or
---nil if it is not valid UTF-8, which the portal cannot decode at all.
---
---serde escapes `"` and `\` and the control characters below 0x20: `\b`,
---`\f`, `\n`, `\r` and `\t` in two bytes, the rest as `\u00XX` in six. It
---writes everything else raw, DEL and non-ASCII included. That differs from
---`rpf.json`, which escapes DEL, so this counts what the portal will count
---rather than what this side sends.
---@param s string The string.
---@return number? bytes Its serialised length, or nil if it is not UTF-8.
local function string_bytes(s)
  if not s:find("[^\32-\126]") then
    -- Printable ASCII, the usual case: only quotes and backslashes grow.
    local _, escaped = s:gsub('["\\]', "")
    return #s + 2 + escaped
  end
  local bytes, i, n = 2, 1, #s
  while i <= n do
    local c = s:byte(i)
    if c < 0x80 then
      if c == 0x22 or c == 0x5C or c == 0x08 or c == 0x0C or c == 0x0A or c == 0x0D or c == 0x09 then
        bytes = bytes + 2
      elseif c < 0x20 then
        bytes = bytes + 6
      else
        bytes = bytes + 1
      end
      i = i + 1
    else
      -- A multi-byte sequence: its length, and the range its second byte
      -- may take, which is what rules out overlong forms, surrogates and
      -- code points past U+10FFFF.
      local length, low, high
      if c >= 0xC2 and c <= 0xDF then
        length, low, high = 2, 0x80, 0xBF
      elseif c == 0xE0 then
        length, low, high = 3, 0xA0, 0xBF
      elseif (c >= 0xE1 and c <= 0xEC) or c == 0xEE or c == 0xEF then
        length, low, high = 3, 0x80, 0xBF
      elseif c == 0xED then
        length, low, high = 3, 0x80, 0x9F
      elseif c == 0xF0 then
        length, low, high = 4, 0x90, 0xBF
      elseif c >= 0xF1 and c <= 0xF3 then
        length, low, high = 4, 0x80, 0xBF
      elseif c == 0xF4 then
        length, low, high = 4, 0x80, 0x8F
      else
        return nil
      end
      local second = s:byte(i + 1)
      if not second or second < low or second > high then
        return nil
      end
      for j = i + 2, i + length - 1 do
        local byte = s:byte(j)
        if not byte or byte < 0x80 or byte > 0xBF then
          return nil
        end
      end
      bytes = bytes + length
      i = i + length
    end
  end
  return bytes
end

---The number of decimal digits in a non-negative integer.
---@param n number The integer.
---@return number digits How many.
local function digits(n)
  return #string.format("%.0f", n)
end

---The number of bytes serde_json writes for a number that `rpf.json`
---encoded and the portal decoded.
---
---An integer is written as an integer on both sides. Anything else the
---portal reads as an `f64` and writes in Ryu's shortest form, which differs
---from C's `%g`: `0.00001234` rather than `1.234e-05`, `1e-7` rather than
---`1e-07`. So this finds the shortest digits that read back as the same
---double and lays them out as Ryu does.
---@param n number A finite number, as `rpf.json` would encode it.
---@return number bytes Its serialised length.
local function number_bytes(n)
  if n == math.floor(n) then
    return n == 0 and 1 or #string.format("%.0f", n)
  end
  local sign = n < 0 and 1 or 0
  local magnitude = math.abs(n)
  local text
  for precision = 0, 16 do
    text = string.format("%." .. precision .. "e", magnitude)
    if tonumber(text) == magnitude then
      break
    end
  end
  local mantissa, exponent = text:match("^([%d%.]+)e([-+]%d+)$")
  local significant = mantissa:gsub("%.", ""):gsub("0+$", "")
  local length = #significant
  -- `kk` as Ryu names it: the value is 0.<digits> × 10^kk.
  local kk = tonumber(exponent) + 1
  if kk > 0 and kk <= 16 then
    return sign + length + 1 -- 12.34
  elseif kk > -5 and kk <= 0 then
    return sign + 2 - kk + length -- 0.001234
  end
  local e = kk - 1
  local e_bytes = (e < 0 and 1 or 0) + digits(math.abs(e))
  if length == 1 then
    return sign + 1 + 1 + e_bytes -- 1e30
  end
  return sign + length + 2 + e_bytes -- 1.234e30
end

---The number of bytes serde_json writes for a decoded JSON value, or nil if
---a string in it is not valid UTF-8.
---@param value any A value as `rpf.json.decode` returns it: marked tables.
---@return number? bytes Its serialised length.
local function value_bytes(value)
  local kind = type(value)
  if value == json.null then
    return 4
  elseif kind == "boolean" then
    return value and 4 or 5
  elseif kind == "number" then
    return number_bytes(value)
  elseif kind == "string" then
    return string_bytes(value)
  end
  local bytes, count = 2, 0
  if json.is_array(value) then
    for _, item in ipairs(value) do
      local size = value_bytes(item)
      if not size then
        return nil
      end
      bytes, count = bytes + size, count + 1
    end
  else
    for key, item in pairs(value) do
      local key_size, size = string_bytes(key), value_bytes(item)
      if not key_size or not size then
        return nil
      end
      bytes, count = bytes + key_size + 1 + size, count + 1
    end
  end
  return bytes + math.max(count - 1, 0)
end

---The size of a stack's `ItemData` as the portal measures it: serialised,
---with absent data counted as the empty object it decodes to. Nil if the
---data could not be sent at all: not a JSON object, not encodable by
---`rpf.json`, or not valid UTF-8.
---@param data any The stack's `data`.
---@return number? bytes Its serialised length.
local function data_bytes(data)
  if data == nil then
    return 2
  end
  if not json.is_object(data) then
    return nil
  end
  -- Measured from what goes on the wire, so a table a script built by hand
  -- is judged by what it encodes to.
  local text = json.encode(data)
  local decoded = text and json.decode(text)
  if decoded == nil then
    return nil
  end
  return value_bytes(decoded)
end

---Whether a value has the wire shape of an `ItemStack`.
---@param stack any The value.
---@return boolean ok True if the portal can decode it.
local function stack_shape(stack)
  return json.is_object(stack)
    and type(stack.item) == "string"
    and string_bytes(stack.item) ~= nil
    and integer_in(stack.count, 0, U32_MAX)
end

---Whether a value is an `IVector2`.
---@param vector any The value.
---@return boolean ok True for an object with `i32` `x` and `y`.
local function vector_shape(vector)
  return json.is_object(vector) and integer_in(vector.x, I32_MIN, I32_MAX) and integer_in(vector.y, I32_MIN, I32_MAX)
end

---Whether a value has the wire shape of a `GridPlacement`.
---@param placement any The value.
---@return boolean ok True if the portal can decode it.
local function placement_shape(placement)
  return json.is_object(placement)
    and stack_shape(placement.stack)
    and vector_shape(placement.position)
    and (placement.rotated == nil or type(placement.rotated) == "boolean")
end

---The stacks of well-formed contents, in order, whatever the layout.
---@param contents table The contents.
---@return table[] stacks Each `ItemStack`, the live tables.
local function stacks_in(contents)
  if contents.layout == "list" then
    return contents.stacks
  end
  local out = {}
  for i, placement in ipairs(contents.placements) do
    out[i] = placement.stack
  end
  return out
end

---Whether contents have the wire shape of `ContainerContents`, so the portal
---can decode a report that carries them, and if so each stack's data size.
---This is the shape only; `validate` decides whether they fit.
---@param contents any The proposed contents.
---@return number[]? sizes Each stack's serialised data size, in order, or nil if malformed.
local function well_formed(contents)
  if not json.is_object(contents) then
    return nil
  end
  local items, check
  if contents.layout == "list" then
    items, check = contents.stacks, stack_shape
  elseif contents.layout == "grid" then
    items, check = contents.placements, placement_shape
  else
    return nil
  end
  if not json.is_array(items) then
    return nil
  end
  local count = 0
  for _ in pairs(items) do
    count = count + 1
  end
  for i = 1, count do
    if items[i] == nil or not check(items[i]) then
      return nil
    end
  end
  local sizes = {}
  for i, stack in ipairs(stacks_in(contents)) do
    sizes[i] = data_bytes(stack.data)
    if not sizes[i] then
      return nil
    end
  end
  return sizes
end

-- Flags and the catalog ---------------------------------------------------------

---A container's flags, read: the first of each kind, as the portal takes
---them.
---@class rpf.inventory.Rules
---@field grid { x: number, y: number }? The grid size, for a grid container.
---@field max_weight number? The weight limit, inclusive.
---@field unstackable boolean? Present when every stack is capped at one; false also allows only one stack per item.

---Whether a value is a grid size: `i32` `x` and `y`. Flags are never sent
---back to the portal, so unlike contents they need not be JSON-marked (the
---protocol decoder hands them over as plain tables).
---@param value any The value.
---@return boolean ok True for a table with `i32` `x` and `y`.
local function size_shape(value)
  return type(value) == "table" and integer_in(value.x, I32_MIN, I32_MAX) and integer_in(value.y, I32_MIN, I32_MAX)
end

---Reads a container's flags, refusing one this core does not know.
---@param flags any The container's `flags`, as the portal sent them: an array of `{ flag = …, value = … }`.
---@return rpf.inventory.Rules? rules The rules, or nil if refused.
---@return rpf.inventory.Refusal? refusal Why, if refused.
local function read_flags(flags)
  local rules = {}
  if type(flags) ~= "table" then
    return nil, json.object({ error = "unknown_flag", flag = "" })
  end
  for _, flag in ipairs(flags) do
    local name, value
    if type(flag) == "table" then
      name, value = flag.flag, flag.value
    end
    if name == "grid" and size_shape(value) then
      ---@cast value { x: number, y: number }
      if rules.grid == nil then
        rules.grid = { x = value.x, y = value.y }
      end
    elseif name == "max_weight" and integer_in(value, I32_MIN, I32_MAX) then
      if rules.max_weight == nil then
        rules.max_weight = value
      end
    elseif name == "unstackable" and type(value) == "boolean" then
      if rules.unstackable == nil then
        rules.unstackable = value
      end
    elseif name ~= "server_specific" then
      return nil, json.object({ error = "unknown_flag", flag = type(name) == "string" and name or "" })
    end
  end
  return rules, nil
end

---An item definition with every field a number, falling back field by field
---to `fallback` for anything missing, so a malformed config entry cannot
---throw inside validation.
---@param item table? The item, as the config or a case holds it.
---@param fallback rpf.inventory.ItemDef The definition to fill gaps from.
---@return rpf.inventory.ItemDef def The definition.
local function def_of(item, fallback)
  item = type(item) == "table" and item or {}
  local size = type(item.size) == "table" and item.size or {}
  return {
    weight = type(item.weight) == "number" and item.weight or fallback.weight,
    size = {
      x = type(size.x) == "number" and size.x or fallback.size.x,
      y = type(size.y) == "number" and size.y or fallback.size.y,
    },
    stack_limit = type(item.stack_limit) == "number" and item.stack_limit or fallback.stack_limit,
  }
end

---Builds a catalog from item definitions, as the config snapshot carries
---them: `items` resolved by the portal (E3) and `item_defaults`. The shared
---corpus builds its catalogs with this, and `inventory.catalog` builds the
---live one the same way over `rpf.config`.
---@param items table[] The items, each with `slug`, `weight`, `size` and `stack_limit`.
---@param defaults table? What an unknown item behaves as; `inventory.DEFAULTS` if nil.
---@param bounds { max_data_bytes: number?, max_stacks: number? }? The size bounds; `MAX_DATA_BYTES` and `MAX_STACKS` if absent.
---@return rpf.inventory.Catalog catalog The catalog.
function inventory.catalog_of(items, defaults, bounds)
  local by_slug = {}
  for _, item in ipairs(items) do
    by_slug[item.slug] = item
  end
  bounds = bounds or {}
  return {
    defaults = def_of(defaults, inventory.DEFAULTS),
    lookup = function(slug)
      return by_slug[slug]
    end,
    max_data_bytes = bounds.max_data_bytes or inventory.MAX_DATA_BYTES,
    max_stacks = bounds.max_stacks or inventory.MAX_STACKS,
  }
end

---The catalog the portal validates this server's contents with: the items
---and `item_defaults` of the config applied now (`rpf.config`), and the
---portal's size bounds. Built fresh each call, so it always reads the
---current config.
---@return rpf.inventory.Catalog catalog The catalog.
function inventory.catalog()
  local config = rpf.config
  return {
    defaults = def_of(config.item_defaults(), inventory.DEFAULTS),
    lookup = config.item,
    max_data_bytes = inventory.MAX_DATA_BYTES,
    max_stacks = inventory.MAX_STACKS,
  }
end

-- Validation ------------------------------------------------------------------

---Looks an item up once per validation.
---@param catalog rpf.inventory.Catalog The catalog.
---@param memo table<string, rpf.inventory.ItemDef> Definitions already looked up.
---@param slug string The item.
---@return rpf.inventory.ItemDef def Its definition, or the defaults.
local function def(catalog, memo, slug)
  local found = memo[slug]
  if not found then
    local item = catalog.lookup(slug)
    found = item and def_of(item, catalog.defaults) or catalog.defaults
    memo[slug] = found
  end
  return found
end

---An `IVector2` for a refusal.
---@param x number Column.
---@param y number Row.
---@return table vector A marked `{ x, y }`.
local function vector(x, y)
  return json.object({ x = x, y = y })
end

---Whether contents are legal for a container with these flags, by the
---portal's rules, in the portal's order, so both name the same first broken
---rule:
---
---1. The layout matches the flags (`wrong_layout`).
---2. No more stacks than `max_stacks` (`too_many_stacks`).
---3. No stack's data over `max_data_bytes` (`data_too_large`).
---4. Each stack, in order: not empty (`empty_stack`), and within its stack
---   limit, which is one in an unstackable container (`stack_too_large`).
---5. One stack per item in an `unstackable = false` container (`duplicate`).
---6. Within the weight limit, inclusive (`too_heavy`).
---7. Each placement, in order: inside the grid (`out_of_bounds`), and every
---   cell its own, walked column by column (`overlap`).
---
---Before any of them, contents the portal could not decode are `malformed`
---and a flag this core does not know is `unknown_flag`. Pure: it reads only
---its arguments, so a script can ask whether contents would fit before it
---offers a move.
---@param contents any The proposed contents: `{ layout = "list", stacks = … }` or `{ layout = "grid", placements = … }`, every array and object JSON-marked.
---@param flags any The container's `flags`, as the portal sent them.
---@param catalog rpf.inventory.Catalog The catalog, usually `inventory.catalog()`.
---@return boolean? ok True if legal.
---@return rpf.inventory.Refusal? refusal Why not.
function inventory.validate(contents, flags, catalog)
  local sizes = well_formed(contents)
  if not sizes then
    return nil, json.object({ error = "malformed" })
  end
  local rules, refusal = read_flags(flags)
  if not rules then
    return nil, refusal
  end
  local grid = rules.grid
  if contents.layout == "grid" and not grid then
    return nil, json.object({ error = "wrong_layout", grid_container = false })
  elseif contents.layout == "list" and grid then
    return nil, json.object({ error = "wrong_layout", grid_container = true })
  end

  local stacks = stacks_in(contents)
  if #stacks > catalog.max_stacks then
    return nil, json.object({ error = "too_many_stacks", count = #stacks, limit = catalog.max_stacks })
  end

  for i, stack in ipairs(stacks) do
    if sizes[i] > catalog.max_data_bytes then
      return nil,
        json.object({ error = "data_too_large", item = stack.item, bytes = sizes[i], limit = catalog.max_data_bytes })
    end
  end

  local memo = {}
  for _, stack in ipairs(stacks) do
    if stack.count == 0 then
      return nil, json.object({ error = "empty_stack", item = stack.item })
    end
    -- The container's rule wins over the item's when it is stricter, which
    -- is the only direction it is ever set.
    local limit = rules.unstackable ~= nil and 1 or def(catalog, memo, stack.item).stack_limit
    if stack.count > limit then
      return nil, json.object({ error = "stack_too_large", item = stack.item, count = stack.count, limit = limit })
    end
  end

  if rules.unstackable == false then
    local seen = {}
    for _, stack in ipairs(stacks) do
      if seen[stack.item] then
        return nil, json.object({ error = "duplicate", item = stack.item })
      end
      seen[stack.item] = true
    end
  end

  if rules.max_weight ~= nil then
    -- Every partial sum is exact below 2^53, and a sum past it is far past
    -- any `i32` limit, so a double gives the portal's `i64` answer.
    local actual = 0
    for _, stack in ipairs(stacks) do
      actual = actual + def(catalog, memo, stack.item).weight * stack.count
    end
    if actual > rules.max_weight then
      return nil, json.object({ error = "too_heavy", limit = rules.max_weight, actual = actual })
    end
  end

  if grid then
    local occupied = {}
    for _, placement in ipairs(contents.placements) do
      local size = def(catalog, memo, placement.stack.item).size
      local width, height = size.x, size.y
      if placement.rotated then
        width, height = height, width
      end
      local position = placement.position
      local px, py = position.x, position.y
      if px < 0 or py < 0 or px + width > grid.x or py + height > grid.y then
        return nil,
          json.object({
            error = "out_of_bounds",
            item = placement.stack.item,
            position = vector(px, py),
            grid = vector(grid.x, grid.y),
          })
      end
      for x = px, px + width - 1 do
        local column = occupied[x]
        if not column then
          column = {}
          occupied[x] = column
        end
        for y = py, py + height - 1 do
          if column[y] then
            return nil, json.object({ error = "overlap", position = vector(x, y) })
          end
          column[y] = true
        end
      end
    end
  end

  return true, nil
end

---Validates contents for a container record, against its own flags and the
---live catalog. What `rpf.records.set_contents` runs before it takes
---contents, so no path into a held container skips the rules.
---@param container table The container record, as `rpf.records` holds it.
---@param contents any The proposed contents.
---@return boolean? ok True if legal.
---@return rpf.inventory.Refusal? refusal Why not.
function inventory.check(container, contents)
  return inventory.validate(contents, container.flags, inventory.catalog())
end

-- Mutations -------------------------------------------------------------------

---Why a mutation was refused, before or instead of a validation refusal.
---@alias rpf.inventory.Error
---| "not_held" # This server does not hold the container (or one of the two, for a move).
---| "invalid_argument" # A count, an index, an item or a position that is not one.
---| "no_stack" # Nothing at that index.
---| "insufficient" # Fewer units than asked for.
---| "no_space" # No free spot in the grid for a new placement.
---| "invalid" # The result would break a rule; the refusal says which.

---Options for a mutation that puts units somewhere.
---@class rpf.inventory.PutOptions
---@field data table? The units' `ItemData`, a JSON object. Units merge only into stacks with identical data. `add` only: a move or split keeps the stack's own.
---@field position { x: number, y: number }? Grid only: put the units here as one placement (or onto the placement of the same item and data already exactly here). Without it they top up matching stacks, then take the first free spots, row by row.
---@field rotated boolean? Grid only: lie the new placement a quarter turn. Without a position, nil tries upright first, then turned.
---@field count number? `move` only: how many units to take from the stack; the whole stack if nil.

---The data two stacks are compared by: its canonical encoding, absent and
---empty alike.
---@param data table? The data.
---@return string? key The encoding, or nil if it cannot be encoded.
local function data_key(data)
  if data == nil or next(data) == nil then
    return "{}"
  end
  return (json.encode(data))
end

---A new stack, with its data copied, and left out when empty, as the portal
---writes it.
---@param item string The item.
---@param count number How many.
---@param data table? The data.
---@return table stack A marked `ItemStack`.
local function new_stack(item, count, data)
  local stack = json.object({ item = item, count = count })
  if data ~= nil and next(data) ~= nil then
    stack.data = json.copy(data)
  end
  return stack
end

---A held container's record, as a copy to work on.
---@param id any The container's uuid.
---@return table? container The copy, or nil if it is not held.
local function held(id)
  if type(id) ~= "string" then
    return nil
  end
  return rpf.records.get("container", id)
end

---The grid footprint an item takes, turned or not.
---@param catalog rpf.inventory.Catalog The catalog.
---@param item string The item.
---@param rotated boolean Whether it lies turned.
---@return number width Columns.
---@return number height Rows.
local function extent(catalog, item, rotated)
  local size = def(catalog, {}, item).size
  if rotated then
    return size.y, size.x
  end
  return size.x, size.y
end

---The first free spot for a footprint in a grid, row by row then column by
---column, upright before turned unless told which.
---
---Only the left and top edges of the grid and the right and bottom edges of
---placements can start one: a spot that could slide left or up and still be
---free would have been found first. So the search is over those, not over
---every cell of a grid that may be enormous.
---@param contents table The grid contents.
---@param grid { x: number, y: number } The grid's size.
---@param catalog rpf.inventory.Catalog The catalog.
---@param item string The item to place.
---@param rotated boolean? Which way it lies; nil to try both.
---@return table? position A marked `{ x, y }`, or nil if nothing fits.
---@return boolean rotated Which way it lies there.
local function free_spot(contents, grid, catalog, item, rotated)
  local rects, xs, ys = {}, { [0] = true }, { [0] = true }
  for _, placement in ipairs(contents.placements) do
    local w, h = extent(catalog, placement.stack.item, placement.rotated == true)
    local p = placement.position
    rects[#rects + 1] = { p.x, p.y, w, h }
    xs[p.x + w], ys[p.y + h] = true, true
  end
  ---The members of a set of numbers, ascending.
  ---@param set table<number, true> The set.
  ---@return number[] sorted The members.
  local function sorted(set)
    local out = {}
    for n in pairs(set) do
      out[#out + 1] = n
    end
    table.sort(out)
    return out
  end
  local ways = {}
  for _, turned in ipairs(rotated == nil and { false, true } or { rotated }) do
    local w, h = extent(catalog, item, turned)
    ways[#ways + 1] = { turned, w, h }
  end
  for _, y in ipairs(sorted(ys)) do
    for _, x in ipairs(sorted(xs)) do
      for _, way in ipairs(ways) do
        local turned, w, h = way[1], way[2], way[3]
        local free = x >= 0 and y >= 0 and x + w <= grid.x and y + h <= grid.y
        for _, r in ipairs(rects) do
          if not free then
            break
          end
          if x < r[1] + r[3] and r[1] < x + w and y < r[2] + r[4] and r[2] < y + h then
            free = false
          end
        end
        if free then
          return vector(x, y), turned
        end
      end
    end
  end
  return nil, false
end

---Puts units of an item into contents: onto the placement at `position` if
---one is given, else topping up stacks of the same item and data and then
---adding new stacks, each within the item's limit. Changes `contents` in
---place; the caller validates the result.
---@param contents table The contents, a copy.
---@param flags table The container's flags.
---@param catalog rpf.inventory.Catalog The catalog.
---@param item string The item.
---@param count number How many units.
---@param data table? Their data.
---@param opts rpf.inventory.PutOptions Where.
---@return boolean? ok True if placed.
---@return rpf.inventory.Error? err Why not.
---@return rpf.inventory.Refusal? refusal For `invalid`.
local function put(contents, flags, catalog, item, count, data, opts)
  if not well_formed(contents) then
    return nil, "invalid", json.object({ error = "malformed" })
  end
  local rules, refusal = read_flags(flags)
  if not rules then
    return nil, "invalid", refusal
  end
  local grid = contents.layout == "grid" and rules.grid
  if contents.layout == "grid" and not grid then
    return nil, "invalid", json.object({ error = "wrong_layout", grid_container = false })
  end
  local key = data_key(data)

  if opts.position ~= nil then
    if not grid then
      return nil, "invalid_argument"
    end
    local x, y, turned = opts.position.x, opts.position.y, opts.rotated == true
    for _, placement in ipairs(contents.placements) do
      local stack, p = placement.stack, placement.position
      if p.x == x and p.y == y and stack.item == item and data_key(stack.data) == key then
        -- One placement may hold only so many; validation says so if this
        -- is too many.
        stack.count = stack.count + count
        return true
      end
    end
    local placements = contents.placements
    placements[#placements + 1] =
      json.object({ stack = new_stack(item, count, data), position = vector(x, y), rotated = turned })
    return true
  end

  local limit = rules.unstackable ~= nil and 1 or def(catalog, {}, item).stack_limit
  local stacks = stacks_in(contents)
  if limit >= 1 then
    for _, stack in ipairs(stacks) do
      if count == 0 then
        break
      end
      if stack.item == item and stack.count < limit and data_key(stack.data) == key then
        local take = math.min(limit - stack.count, count)
        stack.count = stack.count + take
        count = count - take
      end
    end
  end
  if count == 0 then
    return true
  end

  -- The rest in new stacks: refused up front if there would be too many,
  -- rather than built one at a time to find out.
  local per = math.max(limit, 1)
  local needed = math.ceil(count / per)
  if #stacks + needed > catalog.max_stacks then
    return nil,
      "invalid",
      json.object({ error = "too_many_stacks", count = #stacks + needed, limit = catalog.max_stacks })
  end
  while count > 0 do
    local n = math.min(count, per)
    if grid then
      local position, turned = free_spot(contents, grid, catalog, item, opts.rotated)
      if not position then
        return nil, "no_space"
      end
      local placements = contents.placements
      placements[#placements + 1] =
        json.object({ stack = new_stack(item, n, data), position = position, rotated = turned })
    else
      contents.stacks[#contents.stacks + 1] = new_stack(item, n, data)
    end
    count = count - n
  end
  return true
end

---Removes the entry at an index of contents' stacks or placements.
---@param contents table The contents.
---@param index number The 1-based index.
local function drop(contents, index)
  table.remove(contents.layout == "grid" and contents.placements or contents.stacks, index)
end

---The stack at an index of contents.
---@param contents table The contents.
---@param index any The 1-based index of the stack (list) or placement (grid).
---@return table? stack The live `ItemStack`, or nil if there is none.
local function stack_at(contents, index)
  if not integer_in(index, 1, math.huge) then
    return nil
  end
  if contents.layout == "grid" then
    local placement = json.is_array(contents.placements) and contents.placements[index]
    return placement and placement.stack or nil
  end
  return json.is_array(contents.stacks) and contents.stacks[index] or nil
end

---Whether a value is a grid position.
---@param position any The value.
---@return boolean ok True for nil or an object with `i32` `x` and `y`.
local function position_ok(position)
  if position == nil then
    return true
  end
  return type(position) == "table" and integer_in(position.x, I32_MIN, I32_MAX) and integer_in(position.y, I32_MIN, I32_MAX)
end

---Validates new contents for a container and, if they pass, makes them its
---contents, marked for the next report.
---@param container table The container's record copy.
---@param contents table The new contents.
---@return boolean? ok True if applied.
---@return rpf.inventory.Error? err Why not.
---@return rpf.inventory.Refusal? refusal For `invalid`.
local function apply(container, contents)
  local ok, err, refusal = rpf.records.set_contents(container.id, contents)
  if not ok then
    return nil, err, refusal
  end
  return true
end

---Adds units of an item to a held container: topping up stacks of the same
---item and data first, then in new stacks, each within its limit. In a grid,
---new stacks take the first free spots unless `opts.position` says where.
---All or nothing: refused, nothing changes.
---@param id string The container's uuid.
---@param item string The item's slug. An item the config does not define is allowed, and behaves as the defaults.
---@param count number How many units, a positive integer.
---@param opts rpf.inventory.PutOptions? Their data, and where in a grid.
---@return boolean? ok True if added.
---@return rpf.inventory.Error? err Why not.
---@return rpf.inventory.Refusal? refusal The broken rule, for `invalid`.
function inventory.add(id, item, count, opts)
  opts = opts or {}
  local container = held(id)
  if not container then
    return nil, "not_held"
  end
  if
    type(item) ~= "string"
    or not integer_in(count, 1, U32_MAX)
    or (opts.data ~= nil and not json.is_object(opts.data))
    or not position_ok(opts.position)
  then
    return nil, "invalid_argument"
  end
  local contents = container.contents
  local ok, err, refusal = put(contents, container.flags, inventory.catalog(), item, count, opts.data, opts)
  if not ok then
    return nil, err, refusal
  end
  return apply(container, contents)
end

---Removes units of an item from a held container, from its last matching
---stacks first, so the oldest stacks stay where they are. Only stacks whose
---data is identical to `opts.data` count: removing plain water never takes
---the bottle with a note in it.
---@param id string The container's uuid.
---@param item string The item's slug.
---@param count number How many units, a positive integer.
---@param opts { data: table? }? Which stacks: those with this data (none by default).
---@return boolean? ok True if removed.
---@return rpf.inventory.Error? err Why not.
---@return rpf.inventory.Refusal? refusal The broken rule, for `invalid`.
function inventory.remove(id, item, count, opts)
  opts = opts or {}
  local container = held(id)
  if not container then
    return nil, "not_held"
  end
  if type(item) ~= "string" or not integer_in(count, 1, U32_MAX) or (opts.data ~= nil and not json.is_object(opts.data)) then
    return nil, "invalid_argument"
  end
  local contents = container.contents
  if not well_formed(contents) then
    return nil, "invalid", json.object({ error = "malformed" })
  end
  local key = data_key(opts.data)
  local stacks = stacks_in(contents)
  local available = 0
  for _, stack in ipairs(stacks) do
    if stack.item == item and data_key(stack.data) == key then
      available = available + stack.count
    end
  end
  if available < count then
    return nil, "insufficient"
  end
  for i = #stacks, 1, -1 do
    local stack = stacks[i]
    if count == 0 then
      break
    end
    if stack.item == item and data_key(stack.data) == key then
      local take = math.min(stack.count, count)
      stack.count = stack.count - take
      count = count - take
      if stack.count == 0 then
        drop(contents, i)
      end
    end
  end
  return apply(container, contents)
end

---Moves a stack, or some of it, from one held container to another, or
---within one (a new spot in a grid, or merging in a list). At the
---destination the units go where `add` would put them, with the stack's
---own data. Both containers are validated before either changes.
---@param from string The source container's uuid.
---@param index number The 1-based index of the stack (list) or placement (grid) to move.
---@param to string The destination container's uuid, which may be `from`.
---@param opts rpf.inventory.PutOptions? How many (`count`), and where in a grid.
---@return boolean? ok True if moved.
---@return rpf.inventory.Error? err Why not.
---@return rpf.inventory.Refusal? refusal The broken rule, for `invalid`.
---@return string? container For `invalid`, the container whose rule broke.
function inventory.move(from, index, to, opts)
  opts = opts or {}
  local source, target = held(from), held(to)
  if not source or not target then
    return nil, "not_held"
  end
  if opts.data ~= nil or not position_ok(opts.position) then
    return nil, "invalid_argument"
  end
  if not well_formed(source.contents) or not well_formed(target.contents) then
    return nil, "invalid", json.object({ error = "malformed" }), well_formed(source.contents) and to or from
  end
  local stack = stack_at(source.contents, index)
  if not stack then
    return nil, "no_stack"
  end
  local count = opts.count == nil and stack.count or opts.count
  if not integer_in(count, 1, stack.count) then
    return nil, "invalid_argument"
  end
  local item, data = stack.item, stack.data
  stack.count = stack.count - count
  if stack.count == 0 then
    drop(source.contents, index)
  end
  if from == to then
    target = source
  end
  local catalog = inventory.catalog()
  local ok, err, refusal = put(target.contents, target.flags, catalog, item, count, data, opts)
  if not ok then
    return nil, err, refusal, err == "invalid" and to or nil
  end
  if from ~= to then
    local valid, why = inventory.validate(source.contents, source.flags, catalog)
    if not valid then
      return nil, "invalid", why, from
    end
  end
  local valid, why = inventory.validate(target.contents, target.flags, catalog)
  if not valid then
    return nil, "invalid", why, to
  end
  if from ~= to then
    local applied, apply_err, apply_refusal = apply(source, source.contents)
    if not applied then
      return nil, apply_err, apply_refusal, from
    end
  end
  return apply(target, target.contents)
end

---Splits units off a stack into a new stack of their own, with the same
---data, in the same container: next to it in a list, or at `opts.position`
---(or the first free spot) in a grid. Never merges into another stack.
---@param id string The container's uuid.
---@param index number The 1-based index of the stack (list) or placement (grid).
---@param count number How many units to split off: at least one, and fewer than the stack holds.
---@param opts { position: { x: number, y: number }?, rotated: boolean? }? Where the new placement goes, in a grid.
---@return boolean? ok True if split.
---@return rpf.inventory.Error? err Why not.
---@return rpf.inventory.Refusal? refusal The broken rule, for `invalid`.
function inventory.split(id, index, count, opts)
  opts = opts or {}
  local container = held(id)
  if not container then
    return nil, "not_held"
  end
  if not position_ok(opts.position) then
    return nil, "invalid_argument"
  end
  local contents = container.contents
  if not well_formed(contents) then
    return nil, "invalid", json.object({ error = "malformed" })
  end
  local stack = stack_at(contents, index)
  if not stack then
    return nil, "no_stack"
  end
  if not integer_in(count, 1, stack.count - 1) then
    return nil, "invalid_argument"
  end
  stack.count = stack.count - count
  local fresh = new_stack(stack.item, count, stack.data)
  if contents.layout == "list" then
    table.insert(contents.stacks, index + 1, fresh)
  else
    local rules, refusal = read_flags(container.flags)
    if not rules then
      return nil, "invalid", refusal
    end
    if not rules.grid then
      return nil, "invalid", json.object({ error = "wrong_layout", grid_container = false })
    end
    local position, turned
    if opts.position then
      position, turned = vector(opts.position.x, opts.position.y), opts.rotated == true
    else
      position, turned = free_spot(contents, rules.grid, inventory.catalog(), stack.item, opts.rotated)
      if not position then
        return nil, "no_space"
      end
    end
    local placements = contents.placements
    placements[#placements + 1] = json.object({ stack = fresh, position = position, rotated = turned })
  end
  return apply(container, contents)
end

---How many units of an item a held container holds, across every stack and
---whatever their data.
---@param id string The container's uuid.
---@param item string The item's slug.
---@return number? count The total, or nil if the container is not held.
---@return rpf.inventory.Error? err `not_held`.
function inventory.count(id, item)
  local container = held(id)
  if not container then
    return nil, "not_held"
  end
  if not well_formed(container.contents) then
    return 0
  end
  local total = 0
  for _, stack in ipairs(stacks_in(container.contents)) do
    if stack.item == item then
      total = total + stack.count
    end
  end
  return total
end

rpf.inventory = inventory
return inventory
