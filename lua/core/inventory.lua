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
---@field stack_key fun(data: table?): string A fingerprint of a stack's data, which names the stack a screen showed among others of the same item (`rpf.facade`'s stack calls).
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
  return json.serde_bytes(decoded)
end

---Whether a value has the wire shape of an `ItemStack`.
---@param stack any The value.
---@return boolean ok True if the portal can decode it.
local function stack_shape(stack)
  return json.is_object(stack)
    and type(stack.item) == "string"
    and json.is_utf8(stack.item)
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

---How many units of an item well-formed contents hold in stacks whose
---data has a key.
---@param contents table The contents.
---@param item string The item.
---@param key string? The data's key (`data_key`): `"{}"` for plain units.
---@return number count The units.
local function units_of(contents, item, key)
  local total = 0
  for _, stack in ipairs(stacks_in(contents)) do
    if stack.item == item and data_key(stack.data) == key then
      total = total + stack.count
    end
  end
  return total
end

---Takes units of an item out of well-formed contents, in place, from the
---last matching stacks first, so the oldest stay where they are. The
---caller has counted that there are enough.
---@param contents table The contents, a copy.
---@param item string The item.
---@param count number How many.
---@param key string? The data's key of the stacks to take from.
local function take_units(contents, item, count, key)
  local stacks = stacks_in(contents)
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

---`"domain_external"` if this server's framework owns `domain` (K1), so
---RPF keeps no record of it here and its own module refuses, or nil.
---@param domain string One of `rpf.domains.NAMES`.
---@return string? err The refusal.
local function external(domain)
  return rpf.domains.is_external(domain) and "domain_external" or nil
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
  local refused = external("inventory")
  if refused then
    return nil, refused
  end
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
  local refused = external("inventory")
  if refused then
    return nil, refused
  end
  local contents, err, refusal = inventory.plan_remove(id, item, count, opts)
  if not contents then
    return nil, err, refusal
  end
  return apply(held(id) --[[@as table]], contents)
end

---What a held container would hold once `remove` took units from it,
---validated as `remove` would validate it, without changing anything: so a
---caller taking from several containers can find every refusal before it
---makes any change (`rpf.facade`).
---@param id string The container's uuid.
---@param item string The item's slug.
---@param count number How many units, a positive integer.
---@param opts { data: table? }? Which stacks: those with this data (none by default).
---@return table? contents The contents after, marked as the container's are.
---@return rpf.inventory.Error? err Why not, as `remove` answers.
---@return rpf.inventory.Refusal? refusal The broken rule, for `invalid`.
function inventory.plan_remove(id, item, count, opts)
  local refused = external("inventory")
  if refused then
    return nil, refused
  end
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
  if units_of(contents, item, key) < count then
    return nil, "insufficient"
  end
  take_units(contents, item, count, key)
  local ok, refusal = inventory.check(container, contents)
  if not ok then
    return nil, "invalid", refusal
  end
  return contents
end

---One line of `plan_moves`: an item and how many of its plain units.
---@class rpf.inventory.Line
---@field item string The item's slug.
---@field count number How many, a positive integer.

---What a set of held containers would hold once plain units were taken
---from them and given to them, validated as each mutation validates, without
---changing anything: the items half of an exchange (`rpf.commerce`), which
---must find every refusal before it moves anything.
---
---The containers are read in the order given. Each take comes out of them in
---turn, as the facade's `take` does; then each give goes, whole, into the
---first that takes it, as the facade's `give` does, so a take can make the
---room a give needs. Every container that changes is validated whole at the
---end.
---@param ids string[] The containers, in the order units come out and go in.
---@param takes rpf.inventory.Line[] What leaves them.
---@param gives rpf.inventory.Line[] What goes into them.
---@return { id: string, contents: table }[]? changes The new contents of each container that changes, in the order given.
---@return string? err `domain_external`, `not_held`, `no_container` (units to move and no container), `insufficient` (too few plain units for a take), `no_space` (no container takes a give whole), or `invalid_contents` (a container whose contents would no longer pass its rules, as when the catalog changed under it).
---@return string? item For `insufficient` and `no_space`, the item.
function inventory.plan_moves(ids, takes, gives)
  local refused = external("inventory")
  if refused then
    return nil, refused
  end
  if #takes + #gives > 0 and #ids == 0 then
    return nil, "no_container"
  end
  local catalog = inventory.catalog()
  ---@type { container: table, contents: table, changed: boolean }[]
  local work = {}
  for i, id in ipairs(ids) do
    local container = held(id)
    if not container then
      return nil, "not_held"
    end
    work[i] = { container = container, contents = container.contents, changed = false }
  end
  for _, line in ipairs(takes) do
    local total = 0
    for _, w in ipairs(work) do
      if well_formed(w.contents) then
        total = total + units_of(w.contents, line.item, "{}")
      end
    end
    if total < line.count then
      return nil, "insufficient", line.item
    end
    local left = line.count
    for _, w in ipairs(work) do
      if left == 0 then
        break
      end
      local n = well_formed(w.contents) and math.min(left, units_of(w.contents, line.item, "{}")) or 0
      if n > 0 then
        take_units(w.contents, line.item, n, "{}")
        w.changed = true
        left = left - n
      end
    end
  end
  for _, line in ipairs(gives) do
    local placed = false
    for _, w in ipairs(work) do
      local trial = json.copy(w.contents)
      if
        put(trial, w.container.flags, catalog, line.item, line.count, nil, {})
        and inventory.validate(trial, w.container.flags, catalog)
      then
        w.contents, w.changed, placed = trial, true, true
        break
      end
    end
    if not placed then
      return nil, "no_space", line.item
    end
  end
  local out = {}
  for _, w in ipairs(work) do
    if w.changed then
      if not inventory.validate(w.contents, w.container.flags, catalog) then
        return nil, "invalid_contents"
      end
      out[#out + 1] = { id = w.container.id, contents = w.contents }
    end
  end
  return out
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
  local refused = external("inventory")
  if refused then
    return nil, refused
  end
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
  -- Defaulted by assignment, not `a and b or c`: LuaLS cannot see that the
  -- `and` arm is never nil there, so it would type `count` as `number?`.
  local count = opts.count
  if count == nil then
    count = stack.count
  end
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
  local refused = external("inventory")
  if refused then
    return nil, refused
  end
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

-- Staff edits (F5) ------------------------------------------------------------

---One staff edit, as the portal's `ContentsEdit` serialises and the shared
---cases state it. Indexes count from zero, as on the wire.
---@class rpf.inventory.Edit
---@field op "give"|"take"|"move" Which edit.
---@field item string? `give`: the item.
---@field count number? `give` and `take`: how many units.
---@field index number? `take` and `move`: the stack or placement, from zero.
---@field position { x: number, y: number }? `give` (optional) and `move`: the cell.
---@field rotated boolean? With a position, whether the placement lies turned.

---Works a staff edit out on contents and validates the result whole: the
---twin of the portal's `ContentsEdit::apply`, which the portal runs on the
---same contents before it sends the edit, so the two must put every unit in
---the same place. Both are held to the cases in
---`protocol/corpus/containers/edits/` (`spec/containers_spec.lua` here).
---Pure: the contents given are not changed.
---
---`give` adds units with no data, as `add` does; `take` takes units off the
---stack at an index, whatever its data; `move` moves a whole placement of a
---grid to a new cell, as `move` within one container does.
---@param contents any The contents.
---@param flags any The container's flags.
---@param catalog rpf.inventory.Catalog The catalog.
---@param edit rpf.inventory.Edit The edit.
---@return table? contents The new contents, or nil if refused.
---@return rpf.inventory.Error? err Why not.
---@return rpf.inventory.Refusal? refusal The broken rule, for `invalid`.
function inventory.edit(contents, flags, catalog, edit)
  if not well_formed(contents) then
    return nil, "invalid", json.object({ error = "malformed" })
  end
  if type(edit) ~= "table" or not position_ok(edit.position) then
    return nil, "invalid_argument"
  end
  local copy = json.copy(contents)
  if edit.op == "give" then
    if type(edit.item) ~= "string" or not integer_in(edit.count, 1, U32_MAX) then
      return nil, "invalid_argument"
    end
    -- Without a position, a free spot is tried upright and then turned.
    local opts = {}
    if edit.position ~= nil then
      opts.position, opts.rotated = edit.position, edit.rotated == true
    end
    local ok, err, refusal = put(copy, flags, catalog, edit.item, edit.count, nil, opts)
    if not ok then
      return nil, err, refusal
    end
  elseif edit.op == "take" then
    local index = integer_in(edit.index, 0, U32_MAX) and edit.index + 1 or nil
    local stack = stack_at(copy, index)
    if not stack then
      return nil, "no_stack"
    end
    if not integer_in(edit.count, 1, U32_MAX) then
      return nil, "invalid_argument"
    end
    if edit.count > stack.count then
      return nil, "insufficient"
    end
    stack.count = stack.count - edit.count
    if stack.count == 0 then
      drop(copy, index --[[@as number]])
    end
  elseif edit.op == "move" then
    local index = integer_in(edit.index, 0, U32_MAX) and edit.index + 1 or nil
    local stack = stack_at(copy, index)
    if not stack then
      return nil, "no_stack"
    end
    if edit.position == nil then
      return nil, "invalid_argument"
    end
    drop(copy, index --[[@as number]])
    local ok, err, refusal = put(
      copy,
      flags,
      catalog,
      stack.item,
      stack.count,
      stack.data,
      { position = edit.position, rotated = edit.rotated == true }
    )
    if not ok then
      return nil, err, refusal
    end
  else
    return nil, "invalid_argument"
  end
  local valid, why = inventory.validate(copy, flags, catalog)
  if not valid then
    return nil, "invalid", why
  end
  return copy
end

---Makes a staff edit on a held container (F5): `inventory.edit` on its
---contents and the live catalog, then `records.set_contents`, which marks it
---for the next report. Refused, nothing changes.
---@param id string The container's uuid.
---@param edit rpf.inventory.Edit The edit.
---@return boolean? ok True if made.
---@return rpf.inventory.Error? err Why not, `not_held` included.
---@return rpf.inventory.Refusal? refusal The broken rule, for `invalid`.
function inventory.apply_edit(id, edit)
  local refused = external("inventory")
  if refused then
    return nil, refused
  end
  local container = held(id)
  if not container then
    return nil, "not_held"
  end
  local contents, err, refusal = inventory.edit(container.contents, container.flags, inventory.catalog(), edit)
  if not contents then
    return nil, err, refusal
  end
  return apply(container, contents)
end

---Takes units out of the one stack at an index of a held container: the
---stack a player picked, not whichever stacks of the item `remove` would
---take from, so a bottle with a note in it goes when that bottle was
---picked. Validated whole, like every mutation.
---@param id string The container's uuid.
---@param index number The 1-based index of the stack (list) or placement (grid).
---@param count number How many units, from one to all the stack holds.
---@return boolean? ok True if taken.
---@return rpf.inventory.Error? err Why not.
---@return rpf.inventory.Refusal? refusal The broken rule, for `invalid`.
function inventory.take_stack(id, index, count)
  local refused = external("inventory")
  if refused then
    return nil, refused
  end
  local container = held(id)
  if not container then
    return nil, "not_held"
  end
  local contents = container.contents
  if not well_formed(contents) then
    return nil, "invalid", json.object({ error = "malformed" })
  end
  local stack = stack_at(contents, index)
  if not stack then
    return nil, "no_stack"
  end
  if not integer_in(count, 1, stack.count) then
    return nil, "invalid_argument"
  end
  stack.count = stack.count - count
  if stack.count == 0 then
    drop(contents, index)
  end
  local ok, refusal = inventory.check(container, contents)
  if not ok then
    return nil, "invalid", refusal
  end
  return apply(container, contents)
end

---A short fingerprint of a stack's data: two 32-bit polynomial hashes of
---its canonical encoding (`data_key`, keys sorted), as 16 hex digits. It
---names which stack a screen showed, so that another stack of the same item
---that shifted into its index since is told apart from it. A string
---survives every way a reference travels (an engine's export, a client's
---payload), where the data itself would not: an empty object can come
---back as an empty array, and the JSON null sentinel as an empty table.
---Not a security boundary: every stack it tells apart is the same
---player's, so a collision would at worst act on one of their own.
---@param data table? The data.
---@return string key The fingerprint.
local function stack_key(data)
  local text = data_key(data) or ""
  local a, b = 5381, 2166136261
  for i = 1, #text do
    local byte = text:byte(i)
    a = (a * 33 + byte) % 4294967296
    b = (b * 131 + byte + 7) % 4294967296
  end
  return string.format("%08x%08x", a, b)
end
inventory.stack_key = stack_key

---One stack of `inventory.view`.
---@class rpf.inventory.StackView
---@field index integer Its 1-based index: in the stacks of a list, the placements of a grid.
---@field item string The item's slug.
---@field name string? The item's name, from the catalog; nil for an item the catalog does not have.
---@field count integer How many units.
---@field data table? Its `ItemData`, a copy, when it carries any.
---@field key string A fingerprint of its data (`inventory.stack_key`), the same for every stack of plain units.
---@field position { x: integer, y: integer }? In a grid, its top-left cell.
---@field rotated boolean? In a grid, whether it lies a quarter turn.
---@field usable boolean? Whether its item has a use here: set by `rpf.facade.containers`, which knows the use handlers.

---A held container as a script reads it: its rules spelt out and its
---stacks numbered, with their names and the weight they add up to, so an
---inventory screen draws it without knowing the wire's shape.
---@class rpf.inventory.View
---@field id string The container's uuid.
---@field name string Its name, as staff gave it.
---@field layout "list"|"grid" How it holds its stacks.
---@field grid { x: integer, y: integer }? A grid's size, in cells.
---@field max_weight integer? Its weight limit, inclusive; nil for none.
---@field weight number What it holds weighs, by the catalog.
---@field stacks rpf.inventory.StackView[] Its stacks, in order.

---A held container, read for a screen (`rpf.inventory.View`). Contents
---that are not well formed (which validation would refuse anyway) read as
---empty, and flags this core cannot read as no rules, so a screen still
---shows the container.
---@param id string The container's uuid.
---@return rpf.inventory.View? view The view, or nil if it is not held.
function inventory.view(id)
  local container = held(id)
  if not container then
    return nil
  end
  local contents = container.contents
  local rules = read_flags(container.flags) or {}
  local catalog = inventory.catalog()
  local memo = {}
  local out = {
    id = container.id,
    name = tostring(container.name),
    layout = type(contents) == "table" and contents.layout == "grid" and "grid" or "list",
    grid = rules.grid and { x = rules.grid.x, y = rules.grid.y } or nil,
    max_weight = rules.max_weight,
    weight = 0,
    stacks = {},
  }
  if not well_formed(contents) then
    return out
  end
  local placements = contents.layout == "grid" and contents.placements or nil
  for i, stack in ipairs(stacks_in(contents)) do
    local item = catalog.lookup(stack.item)
    local entry = {
      index = i,
      item = stack.item,
      name = type(item) == "table" and type(item.name) == "string" and item.name or nil,
      count = stack.count,
      data = data_key(stack.data) ~= "{}" and json.copy(stack.data) or nil,
      key = stack_key(stack.data),
    }
    if placements then
      local p = placements[i]
      entry.position = { x = p.position.x, y = p.position.y }
      entry.rotated = p.rotated == true
    end
    out.weight = out.weight + def(catalog, memo, stack.item).weight * stack.count
    out.stacks[i] = entry
  end
  return out
end

---How many units of an item a held container holds, across every stack and
---whatever their data, or with `opts.plain` only the plain ones: units in
---stacks with no data, which is what `remove` takes by default (the facade
---counts these, J3).
---@param id string The container's uuid.
---@param item string The item's slug.
---@param opts { plain: boolean? }? Whether to count only plain units.
---@return number? count The total, or nil if the container is not held.
---@return rpf.inventory.Error? err `not_held`.
function inventory.count(id, item, opts)
  local refused = external("inventory")
  if refused then
    return nil, refused
  end
  local container = held(id)
  if not container then
    return nil, "not_held"
  end
  if not well_formed(container.contents) then
    return 0
  end
  local plain = opts ~= nil and opts.plain == true
  local total = 0
  for _, stack in ipairs(stacks_in(container.contents)) do
    if stack.item == item and (not plain or data_key(stack.data) == "{}") then
      total = total + stack.count
    end
  end
  return total
end

rpf.inventory = inventory
return inventory
