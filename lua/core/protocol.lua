---The wire protocol, as the game server speaks it.
---
---This mirrors `crates/rpf-protocol/src/lib.rs`, and the two are held together by the
---same corpus: `protocol/corpus/v<VERSION>/` is decoded here and by the Rust tests,
---so neither side is tested against the other's reimplementation. Every
---frame is one flat JSON object, the envelope's `id` and `sent_at` beside the
---message's `type` and its own fields, and a decoded frame keeps that shape:
---`frame.type`, `frame.id`, `frame.re`, `frame.player_id`.
---
---Decoding follows the portal's rules exactly. Unknown fields are ignored, at
---every depth, and do not appear in the decoded frame. The one exception is a
---config snapshot, which is data rather than fields, and is kept whole so a
---section a newer portal adds is not lost on the way. An unknown `type`, a
---missing field, or a field of the wrong type is refused. A field that may be
---null must still be present, sent as null, except a character's `job`,
---which the portal leaves out for none (`optional`).
---@class rpf.protocol
---@field VERSION integer The protocol version this core speaks, sent in `Hello`. Mirrors `protocol::VERSION`.
---@field MAX_AMOUNT number 2^53 − 1, the widest money amount either side accepts. Mirrors `protocol::MAX_AMOUNT`.
---@field SERVER_TO_PORTAL "server_to_portal" The direction of frames this core sends. Also the corpus directory.
---@field PORTAL_TO_SERVER "portal_to_server" The direction of frames this core receives. Also the corpus directory.
---@field messages table<string, table<string, rpf.protocol.MessageSpec>> Every message type, by direction then `type` tag.
local protocol = {}

local json = rpf.json

protocol.VERSION = 2
protocol.MAX_AMOUNT = json.MAX_SAFE_INTEGER
protocol.SERVER_TO_PORTAL = "server_to_portal"
protocol.PORTAL_TO_SERVER = "portal_to_server"

---A frame, decoded or about to be encoded: the envelope fields plus the
---message's own, in one table, as on the wire.
---@class rpf.Frame
---@field id string The envelope id, a uuid. Reused only when resending this same frame.
---@field sent_at string When the sender sent it, RFC 3339 in UTC.
---@field type string The message type tag.
---@field re string? The id of the frame this one answers, on replies.
---@field [string] any The message's own fields.

---How one field's value is checked and converted. Decode and encode are
---separate because the two sides differ only in how null and arrays are
---represented: `json.null` and marked tables on the wire, `nil` and plain
---tables in Lua.
---@class rpf.protocol.Type
---@field decode fun(value: any, path: string): any Checks a decoded JSON value and returns it as Lua holds it. Throws the path and the problem.
---@field encode fun(value: any, path: string): any Checks a Lua value and returns it ready for `json.encode`. Throws the path and the problem.
---@field nullable boolean? True if the field may be null. It must still be present, unless `optional`.
---@field optional boolean? True if the field may also be left out, which decodes as nil, and is left out when encoding nil. Only `optional` makes one.
---@field secret boolean? True if the value is a credential, which `redact` replaces.

---One message type in one direction.
---@class rpf.protocol.MessageSpec
---@field fields rpf.protocol.Field[] The message's own fields, beside the envelope's.
---@field answered_by "reply"|"ack"|"nothing" What answers it, mirroring `Message::answered_by`: a request is answered by its reply or a `Rejected`, notices and replies by an `Ack`, and an `Ack` by nothing.
---@field reissuable boolean Whether it may be re-sent under a fresh id once the retry window is closing, mirroring `Message::reissuable`. False is the safe answer.

---One named field of a message or nested object.
---@class rpf.protocol.Field
---@field [1] string The field's name.
---@field [2] rpf.protocol.Type Its type.

-- Types -------------------------------------------------------------------

---Stops a decode or encode, naming the field.
---@param path string Where in the frame, like `character.owner.kind`.
---@param message string What was wrong.
local function fail(path, message)
  error(path .. ": " .. message, 0)
end

---Wraps a check that is the same in both directions as a type.
---@param check fun(value: any, path: string): any The check, returning the value.
---@param extra table? Flags to add, like `secret`.
---@return rpf.protocol.Type type The type.
local function same_both_ways(check, extra)
  local t = { decode = check, encode = check }
  for key, value in pairs(extra or {}) do
    t[key] = value
  end
  return t
end

---Checks a value is a string.
---@param value any The value.
---@param path string Where it is.
---@return string value The string.
local function check_string(value, path)
  if type(value) ~= "string" then
    fail(path, "expected a string, got " .. type(value))
  end
  return value
end

local STRING = same_both_ways(check_string)
local SECRET = same_both_ways(check_string, { secret = true })

local UUID_PATTERN = "^"
  .. string.rep("%x", 8)
  .. "%-"
  .. string.rep("%x", 4)
  .. "%-"
  .. string.rep("%x", 4)
  .. "%-"
  .. string.rep("%x", 4)
  .. "%-"
  .. string.rep("%x", 12)
  .. "$"

local UUID = same_both_ways(function(value, path)
  check_string(value, path)
  if not value:find(UUID_PATTERN) then
    fail(path, "expected a hyphenated uuid")
  end
  return value
end)

local TIMESTAMP = same_both_ways(function(value, path)
  check_string(value, path)
  local _, stop = value:find("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d")
  if not stop then
    fail(path, "expected an RFC 3339 timestamp")
  end
  ---@cast stop integer
  local rest = value:sub(stop + 1)
  local _, frac_end = rest:find("^%.%d+")
  if frac_end then
    rest = rest:sub(frac_end + 1)
  end
  if rest ~= "Z" and not rest:find("^[-+]%d%d:%d%d$") then
    fail(path, "expected an RFC 3339 timestamp with a zone")
  end
  return value
end)

local BOOLEAN = same_both_ways(function(value, path)
  if type(value) ~= "boolean" then
    fail(path, "expected a boolean, got " .. type(value))
  end
  return value
end)

---An integer within bounds. The JSON codec already refuses anything a double
---cannot hold, so these bounds are the protocol's own.
---@param min number The smallest allowed.
---@param max number The largest allowed.
---@return rpf.protocol.Type type The type.
local function integer(min, max)
  return same_both_ways(function(value, path)
    if type(value) ~= "number" or value ~= math.floor(value) then
      fail(path, "expected an integer")
    end
    if value < min or value > max then
      fail(path, "out of range")
    end
    return value
  end)
end

local U16 = integer(0, 65535)
local U32 = integer(0, 4294967295)
local I32 = integer(-2147483648, 2147483647)
local U64 = integer(0, json.MAX_SAFE_INTEGER)
local AMOUNT = integer(-protocol.MAX_AMOUNT, protocol.MAX_AMOUNT)

---A string from a fixed set, as a Rust unit enum serializes.
---@param values string[] The allowed strings.
---@return rpf.protocol.Type type The type.
local function enum(values)
  local allowed = {}
  for _, v in ipairs(values) do
    allowed[v] = true
  end
  return same_both_ways(function(value, path)
    check_string(value, path)
    if not allowed[value] then
      fail(path, "unknown value " .. value)
    end
    return value
  end)
end

---A value that may be null. Null is `json.null` on the wire and `nil` in Lua,
---and the field must be present either way.
---@param inner rpf.protocol.Type The type when not null.
---@return rpf.protocol.Type type The type.
local function nullable(inner)
  return {
    nullable = true,
    secret = inner.secret,
    decode = function(value, path)
      if value == json.null then
        return nil
      end
      return inner.decode(value, path)
    end,
    encode = function(value, path)
      if value == nil or value == json.null then
        return json.null
      end
      return inner.encode(value, path)
    end,
  }
end

---A field the portal leaves out when it has no value, rather than sending
---null: decoded as nil whether absent or null, and left out when encoding
---nil. A character's `job` (D7) is one, there so that frames recorded before
---the field existed still re-encode exactly; the unset fields of a definition
---in an in-game config change (E6) are others, left out exactly as the
---portal's own definitions leave them out, and so is `welcome`'s `domains`
---(K1), which the portal leaves out for the native profile. Every other
---field must be present.
---@param inner rpf.protocol.Type The type when present and not null.
---@return rpf.protocol.Type type The type.
local function optional(inner)
  local t = nullable(inner)
  t.optional = true
  return t
end

---An array of one type.
---@param inner rpf.protocol.Type The element type.
---@return rpf.protocol.Type type The type.
local function array_of(inner)
  return {
    decode = function(value, path)
      if not json.is_array(value) then
        fail(path, "expected an array")
      end
      local out = {}
      for i, item in ipairs(value) do
        out[i] = inner.decode(item, path .. "[" .. i .. "]")
      end
      return out
    end,
    encode = function(value, path)
      if type(value) ~= "table" then
        fail(path, "expected an array")
      end
      local out = json.array()
      local count = 0
      for _ in pairs(value) do
        count = count + 1
      end
      if count ~= #value then
        fail(path, "expected an array with no holes")
      end
      for i, item in ipairs(value) do
        out[i] = inner.encode(item, path .. "[" .. i .. "]")
      end
      return out
    end,
  }
end

---Decodes the named fields of an object into `out`, ignoring any others.
---@param fields rpf.protocol.Field[] The fields.
---@param value table The decoded JSON object.
---@param path string Where the object is, or "" at the top.
---@param out table Where the decoded fields go.
local function decode_fields(fields, value, path, out)
  for _, field in ipairs(fields) do
    local name, t = field[1], field[2]
    local at = path == "" and name or path .. "." .. name
    local raw = value[name]
    if raw == nil then
      if not t.optional then
        fail(at, "missing")
      end
    else
      out[name] = t.decode(raw, at)
    end
  end
end

---Encodes the named fields of a Lua table into `out`. Anything else in the
---table is not sent.
---@param fields rpf.protocol.Field[] The fields.
---@param value table The Lua table.
---@param path string Where the object is, or "" at the top.
---@param out table Where the encoded fields go.
local function encode_fields(fields, value, path, out)
  for _, field in ipairs(fields) do
    local name, t = field[1], field[2]
    local at = path == "" and name or path .. "." .. name
    local raw = value[name]
    if raw == nil and not t.nullable then
      fail(at, "missing")
    end
    if raw ~= nil or not t.optional then
      out[name] = t.encode(raw, at)
    end
  end
end

---An object with known fields, like a Rust struct. Unknown fields are
---ignored on decode, so a newer portal can add one.
---@param fields rpf.protocol.Field[] The fields.
---@return rpf.protocol.Type type The type.
local function object(fields)
  return {
    decode = function(value, path)
      if not json.is_object(value) then
        fail(path, "expected an object")
      end
      local out = {}
      decode_fields(fields, value, path, out)
      return out
    end,
    encode = function(value, path)
      if type(value) ~= "table" then
        fail(path, "expected an object")
      end
      local out = json.object()
      encode_fields(fields, value, path, out)
      return out
    end,
  }
end

---An internally tagged enum, like `#[serde(tag = "…")]`: an object whose
---`tag` field names the variant, beside that variant's fields.
---@param tag string The tag field's name.
---@param variants table<string, rpf.protocol.Field[]> Each variant's fields.
---@return rpf.protocol.Type type The type.
local function tagged(tag, variants)
  ---Finds the variant a value names.
  ---@param value table The object.
  ---@param path string Where it is.
  ---@return string name The variant's tag.
  ---@return rpf.protocol.Field[] fields Its fields.
  local function variant(value, path)
    local name = value[tag]
    local at = path .. "." .. tag
    check_string(name, at)
    local fields = variants[name]
    if not fields then
      fail(at, "unknown variant " .. name)
    end
    return name, fields
  end
  return {
    decode = function(value, path)
      if not json.is_object(value) then
        fail(path, "expected an object")
      end
      local name, fields = variant(value, path)
      local out = { [tag] = name }
      decode_fields(fields, value, path, out)
      return out
    end,
    encode = function(value, path)
      if type(value) ~= "table" then
        fail(path, "expected an object")
      end
      local name, fields = variant(value, path)
      local out = json.object({ [tag] = name })
      encode_fields(fields, value, path, out)
      return out
    end,
  }
end

---`Gender`: `"male"`, `"female"`, or `{ "server_specific": "…" }`, the
---externally tagged form serde gives a newtype variant. That object is held
---to exactly one key, as serde holds it.
local GENDER = same_both_ways(function(value, path)
  if value == "male" or value == "female" then
    return value
  end
  if type(value) == "table" then
    local count = 0
    for _ in pairs(value) do
      count = count + 1
    end
    if count == 1 and type(value.server_specific) == "string" then
      return json.object({ server_specific = value.server_specific })
    end
  end
  fail(path, "expected male, female or { server_specific = string }")
end)

---A JSON object kept whole, unknown keys and all, for data whose keys are
---not fields: the config snapshot, whose sections a newer portal adds one at
---a time (E3–E5) and which `rpf.config` stores, compares and announces
---whether or not it can index them. Dropping what this core does not know
---would make a newer portal's config look different from what it sent.
---`config.apply` checks the sections it does know.
local OPAQUE_OBJECT = same_both_ways(function(value, path)
  if not json.is_object(value) then
    fail(path, "expected an object")
  end
  return value
end)

local OWNER_REF = object({
  { "kind", enum({ "server", "player", "character", "employer" }) },
  { "id", UUID },
})

---`JobRef`: a job by its employer's slug and its own (E4, D7), since a job
---slug is unique only within its employer. Checked for shape only: whether
---it is one of this server's jobs is `rpf.jobs`'s business, as on the
---portal's side.
local JOB_REF = object({
  { "employer", STRING },
  { "job", STRING },
})

---`CharacterJob`: a character's job as its holder reports it (D7). A
---wrapper, because the field it sits in has three states: the field null
---says nothing about the job, `{ job = null }` says the character has none,
---and `{ job = … }` names the one it has.
local EMPLOYMENT = object({
  { "job", nullable(JOB_REF) },
})

---A character as the portal hands it over. `job` (D7) is left out for none
---(see `optional`).
local CHARACTER = object({
  { "id", UUID },
  { "server_id", UUID },
  { "owner", OWNER_REF },
  { "first_name", STRING },
  { "last_name", STRING },
  { "gender", GENDER },
  { "job", optional(JOB_REF) },
})

---`IVector2`: a grid cell or a footprint.
local IVECTOR = object({
  { "x", I32 },
  { "y", I32 },
})

---`Command`: what staff ask of a held record (F5) or an online player (F4).
---Every edit of a record names the revision it was made on.
local COMMAND = tagged("command", {
  adjust_balance = {
    { "client_id", UUID },
    { "account_id", UUID },
    { "base_revision", U64 },
    { "funds_account", UUID },
    { "amount", AMOUNT },
    { "description", STRING },
  },
  kick = {
    { "player_id", UUID },
    { "reason", STRING },
  },
  give_item = {
    { "container_id", UUID },
    { "base_revision", U64 },
    { "item", STRING },
    { "count", U32 },
    { "position", nullable(IVECTOR) },
    { "rotated", BOOLEAN },
  },
  take_item = {
    { "container_id", UUID },
    { "base_revision", U64 },
    { "index", U32 },
    { "count", U32 },
  },
  move_item = {
    { "container_id", UUID },
    { "base_revision", U64 },
    { "index", U32 },
    { "position", IVECTOR },
    { "rotated", BOOLEAN },
  },
  edit_character = {
    { "character_id", UUID },
    { "base_revision", U64 },
    { "first_name", nullable(STRING) },
    { "last_name", nullable(STRING) },
    { "gender", nullable(GENDER) },
  },
  delete_character = {
    { "character_id", UUID },
    { "base_revision", U64 },
  },
  -- A held addon record's fields (J2): the patch is the addon's data,
  -- checked against the type's definition by `rpf.records`.
  edit_addon_record = {
    { "record_id", UUID },
    { "base_revision", U64 },
    { "patch", OPAQUE_OBJECT },
  },
  delete_addon_record = {
    { "record_id", UUID },
    { "base_revision", U64 },
  },
})

local OUTCOME = tagged("outcome", {
  applied = {},
  failed = { { "reason", STRING } },
  unknown = { { "reason", STRING } },
})

-- In-game config changes (E6) ----------------------------------------------

---A setting's value, whatever its setting holds (a number, text, an array of
---starting accounts, a job), passed through as it is: the portal checks it
---against the setting, as it checks a value typed on its settings page.
local SETTING_VALUE = same_both_ways(function(value, path)
  if value == nil or value == json.null then
    fail(path, "missing")
  end
  return value
end)

---Checks an `Inheritable` state's name.
---@param value table The object.
---@param path string Where it is.
---@return "set"|"null"|"inherit" state The state.
local function inheritable_state(value, path)
  local state = value.state
  check_string(state, path .. ".state")
  if state ~= "set" and state ~= "null" and state ~= "inherit" then
    fail(path .. ".state", "unknown value " .. state)
  end
  return state
end

---`Inheritable`: a server's own state for a setting, adjacently tagged as
---the portal writes it: `{ state = "set", value = … }` to override,
---`{ state = "null" }` to clear, `{ state = "inherit" }` to take the
---parent's. Only `set` carries a value.
local INHERITABLE = {
  decode = function(value, path)
    if not json.is_object(value) then
      fail(path, "expected an object")
    end
    local state = inheritable_state(value, path)
    if state == "set" then
      return { state = state, value = SETTING_VALUE.decode(value.value, path .. ".value") }
    end
    return { state = state }
  end,
  encode = function(value, path)
    if type(value) ~= "table" then
      fail(path, "expected an object")
    end
    local state = inheritable_state(value, path)
    if state == "set" then
      return json.object({ state = state, value = SETTING_VALUE.encode(value.value, path .. ".value") })
    end
    return json.object({ state = state })
  end,
}

---`ItemBase`: an item base as staff define it (E3). A field it leaves to
---the items and the defaults is left out.
local ITEM_BASE = object({
  { "slug", STRING },
  { "name", STRING },
  { "weight", optional(I32) },
  { "size", optional(IVECTOR) },
  { "stack_limit", optional(U32) },
})

---`ItemSpec`: an item as staff define it (E3), before its base and the
---defaults fill what it leaves out.
local ITEM_SPEC = object({
  { "slug", STRING },
  { "name", STRING },
  { "base", optional(STRING) },
  { "weight", optional(I32) },
  { "size", optional(IVECTOR) },
  { "stack_limit", optional(U32) },
})

---`EmployerDef`: a server-run employer (E4); its payroll (D7) names one of
---the server's paying accounts.
local EMPLOYER_DEF = object({
  { "slug", STRING },
  { "name", STRING },
  { "description", optional(STRING) },
  { "payroll", optional(STRING) },
})

---`DepartmentDef`: a department of a server-run employer (E4).
local DEPARTMENT_DEF = object({
  { "employer", STRING },
  { "slug", STRING },
  { "name", STRING },
  { "description", optional(STRING) },
})

---`JobDef`: a job at a server-run employer (E4), with its rank and salary
---(D7).
local JOB_DEF = object({
  { "employer", STRING },
  { "slug", STRING },
  { "name", STRING },
  { "department", optional(STRING) },
  { "description", optional(STRING) },
  { "rank", optional(U32) },
  { "salary", optional(integer(1, protocol.MAX_AMOUNT)) },
})

---`ConfigChange`: one change to this server's own config, exactly as one of
---the portal's config forms submits it, tagged by `change`. The portal checks
---each as its own form would, so this only holds them to their shape.
local CONFIG_CHANGE = tagged("change", {
  setting = { { "key", STRING }, { "value", INHERITABLE } },
  create_item_base = { { "base", ITEM_BASE } },
  update_item_base = { { "base", ITEM_BASE } },
  delete_item_base = { { "slug", STRING } },
  create_item = { { "item", ITEM_SPEC } },
  update_item = { { "item", ITEM_SPEC } },
  delete_item = { { "slug", STRING } },
  create_employer = { { "employer", EMPLOYER_DEF } },
  update_employer = { { "employer", EMPLOYER_DEF } },
  delete_employer = { { "slug", STRING } },
  create_department = { { "department", DEPARTMENT_DEF } },
  update_department = { { "department", DEPARTMENT_DEF } },
  delete_department = { { "employer", STRING }, { "slug", STRING } },
  create_job = { { "job", JOB_DEF } },
  update_job = { { "job", JOB_DEF } },
  delete_job = { { "employer", STRING }, { "slug", STRING } },
})

-- Authority per domain (K1) ------------------------------------------------

---Who owns one domain's records on this server: RPF, or the game server's
---own framework.
local AUTHORITY = enum({ "rpf", "external" })

---`Domains`: a profile, who owns each of the four domains. Every domain is
---named; the portal accepts only all `rpf` (native) or all `external`
---(companion) as a saved profile.
local DOMAINS = object({
  { "characters", AUTHORITY },
  { "money", AUTHORITY },
  { "inventory", AUTHORITY },
  { "jobs", AUTHORITY },
})

-- Records (C7) ------------------------------------------------------------

local RECORD_KIND = enum({ "character", "account", "container", "addon_record" })

---`RecordRef`: one held record, by kind and id.
local RECORD_REF = object({
  { "kind", RECORD_KIND },
  { "id", UUID },
})

---`RecordRevision`: a record and the revision one side holds it at.
local RECORD_REVISION = object({
  { "kind", RECORD_KIND },
  { "id", UUID },
  { "revision", U64 },
})

---`OnlinePlayer`: one logged-in player in an `online_players` resync (F2).
local ONLINE_PLAYER = object({
  { "player_id", UUID },
})

---`StaffGrant`: one linked staff member on the online list and what they
---may do on this server (F9), in `staff_permissions`. The permissions are
---plain strings, not an enum: the portal adds flags (and addons will add
---`addon.*` ones), and a name this core does not know is still one a script
---may ask `rpf.staff.can` about, so it is kept rather than refused.
local STAFF_GRANT = object({
  { "player_id", UUID },
  { "permissions", array_of(STRING) },
})

---`AccountFlags`: `"unlimited_balance"`, or `{ "server_specific": "…" }`,
---externally tagged like `Gender` and held to one key the same way.
local ACCOUNT_FLAG = same_both_ways(function(value, path)
  if value == "unlimited_balance" then
    return value
  end
  if type(value) == "table" then
    local count = 0
    for _ in pairs(value) do
      count = count + 1
    end
    if count == 1 and type(value.server_specific) == "string" then
      return json.object({ server_specific = value.server_specific })
    end
  end
  fail(path, "expected unlimited_balance or { server_specific = string }")
end)

local ACCOUNT = object({
  { "id", UUID },
  { "server_id", UUID },
  { "owner", OWNER_REF },
  { "name", STRING },
  { "flags", array_of(ACCOUNT_FLAG) },
})

---A container as the portal hands it over. Its contents and flags are kept
---whole, as the portal sent them, and `rpf.inventory` reads them. Contents
---carry each stack's `ItemData`, which must come back byte for byte, and a
---flag a newer portal adds must not make the whole `held` reply undecodable:
---`rpf.inventory` refuses to change a container with a flag it does not know
---(`unknown_flag`) instead.
local CONTAINER = object({
  { "id", UUID },
  { "server_id", UUID },
  { "owner", OWNER_REF },
  { "name", STRING },
  { "contents", OPAQUE_OBJECT },
  { "flags", array_of(OPAQUE_OBJECT) },
})

---`HeldAddonRecord`: a live addon record as the portal hands it over (J2).
---Its fields are the addon's data, kept as they are.
local ADDON_RECORD = object({
  { "id", UUID },
  { "type", STRING },
  { "owner", OWNER_REF },
  { "fields", OPAQUE_OBJECT },
})

---`QueriedRecord`: a live addon record a query found (J2), with the
---revision the portal has it at and whether this server holds it.
local QUERIED_RECORD = object({
  { "id", UUID },
  { "type", STRING },
  { "owner", OWNER_REF },
  { "revision", U64 },
  { "held", BOOLEAN },
  { "fields", OPAQUE_OBJECT },
})

---`HeldRecord`: a record as the portal hands it over in `Held`.
local HELD_RECORD = tagged("kind", {
  character = {
    { "revision", U64 },
    { "character", CHARACTER },
  },
  account = {
    { "revision", U64 },
    { "account", ACCOUNT },
    { "balance", AMOUNT },
  },
  container = {
    { "revision", U64 },
    { "container", CONTAINER },
  },
  addon_record = {
    { "revision", U64 },
    { "record", ADDON_RECORD },
  },
})

---`ReportedTransaction`: one ledger entry this server made, keyed by the
---`client_id` it minted, so a resend appends nothing.
local TRANSACTION = object({
  { "client_id", UUID },
  { "from_account", UUID },
  { "to_account", UUID },
  { "amount", integer(1, protocol.MAX_AMOUNT) },
  { "description", STRING },
})

---`RecordReport`: a record's whole state as its holder has it, in a
---`resync` or a `release`. This core always sends a character's
---`employment`; the portal defaults it for a core from before D7.
local RECORD_REPORT = tagged("kind", {
  character = {
    { "id", UUID },
    { "revision", U64 },
    { "first_name", STRING },
    { "last_name", STRING },
    { "gender", GENDER },
    { "employment", nullable(EMPLOYMENT) },
  },
  account = {
    { "id", UUID },
    { "revision", U64 },
    { "transactions", array_of(TRANSACTION) },
  },
  container = {
    { "id", UUID },
    { "revision", U64 },
    { "contents", OPAQUE_OBJECT },
  },
  addon_record = {
    { "id", UUID },
    { "revision", U64 },
    { "fields", OPAQUE_OBJECT },
  },
})

---`StateChange`: what changed in one record since `base_revision`. A
---character field left null is unchanged, `employment` included: no job is
---`{ job = null }`.
local STATE_CHANGE = tagged("kind", {
  character = {
    { "id", UUID },
    { "base_revision", U64 },
    { "first_name", nullable(STRING) },
    { "last_name", nullable(STRING) },
    { "gender", nullable(GENDER) },
    { "employment", nullable(EMPLOYMENT) },
  },
  account = {
    { "id", UUID },
    { "base_revision", U64 },
    { "transactions", array_of(TRANSACTION) },
  },
  container = {
    { "id", UUID },
    { "base_revision", U64 },
    { "contents", OPAQUE_OBJECT },
  },
  addon_record = {
    { "id", UUID },
    { "base_revision", U64 },
    { "patch", OPAQUE_OBJECT },
  },
  addon_record_created = {
    { "id", UUID },
    { "type", STRING },
    { "owner", OWNER_REF },
    { "fields", OPAQUE_OBJECT },
  },
  addon_record_deleted = {
    { "id", UUID },
    { "base_revision", U64 },
  },
})

---Every `RejectCode`, as its wire string.
local REJECT_CODES = {
  "unauthorised",
  "forbidden",
  "malformed",
  "not_found",
  "retry",
  "duplicate_instance",
  "expired",
  "rate_limited",
  "suspended",
}

-- Messages ----------------------------------------------------------------

---Builds a message spec.
---@param answered_by "reply"|"ack"|"nothing" What answers it.
---@param reissuable boolean Whether it may be reissued under a fresh id.
---@param fields rpf.protocol.Field[] Its fields.
---@return rpf.protocol.MessageSpec spec The spec.
local function message(answered_by, reissuable, fields)
  return { answered_by = answered_by, reissuable = reissuable, fields = fields }
end

protocol.messages = {
  server_to_portal = {
    hello = message("reply", false, {
      { "protocol", U16 },
      { "api_key", SECRET },
      { "instance_id", UUID },
      { "engine", STRING },
      { "core_version", STRING },
      { "config_version", nullable(U64) },
      { "config_hash", nullable(STRING) },
      { "domains", nullable(DOMAINS) },
    }),
    begin_join = message("reply", false, {
      { "identifiers", array_of(STRING) },
      { "name", STRING },
    }),
    redeem_ticket = message("reply", false, {
      { "ticket", SECRET },
    }),
    player_dropped = message("ack", true, {
      { "player_id", UUID },
      { "reason", STRING },
    }),
    online_players = message("ack", false, {
      { "players", array_of(ONLINE_PLAYER) },
    }),
    create_character = message("reply", false, {
      { "owner", OWNER_REF },
      { "first_name", STRING },
      { "last_name", STRING },
      { "gender", GENDER },
    }),
    command_applied = message("ack", true, {
      { "re", UUID },
      { "outcome", OUTCOME },
    }),
    config_applied = message("ack", true, {
      { "re", UUID },
      { "outcome", OUTCOME },
    }),
    hold = message("reply", true, {
      { "owners", array_of(OWNER_REF) },
      { "records", array_of(RECORD_REF) },
    }),
    release = message("ack", true, {
      { "records", array_of(RECORD_REPORT) },
    }),
    state_changed = message("reply", true, {
      { "changes", array_of(STATE_CHANGE) },
    }),
    resync = message("reply", true, {
      { "records", array_of(RECORD_REPORT) },
    }),
    declare_holds = message("reply", false, {
      { "records", array_of(RECORD_REVISION) },
    }),
    -- Not reissuable: a link code is single-use and lives five minutes, so a
    -- reissue could only be refused, and would count as a failed guess.
    link_player = message("reply", false, {
      { "player_id", UUID },
      { "link_code", SECRET },
    }),
    -- Not reissuable: one sent again under a fresh id would be a second
    -- entry in the guild's audit log for one action.
    staff_action = message("ack", false, {
      { "player_id", UUID },
      { "permission", STRING },
      { "action", STRING },
      { "target_player_id", nullable(UUID) },
    }),
    -- Not reissuable: a change sent again under a fresh id would be a second
    -- change, against a version that has moved since (E6).
    config_changed = message("reply", false, {
      { "player_id", UUID },
      { "base_version", U64 },
      { "changes", array_of(CONFIG_CHANGE) },
    }),
    -- Not reissuable: it says which addons are loaded when it is sent, and
    -- every `Welcome` sends a fresh one (J2).
    declare_addons = message("ack", false, {
      { "loaded", array_of(STRING) },
      { "manifests", array_of(OPAQUE_OBJECT) },
    }),
    -- A read (J2): not reissuable, as an answer days later is of no use.
    query_records = message("reply", false, {
      { "type_name", STRING },
      { "query", OPAQUE_OBJECT },
    }),
    ack = message("nothing", false, {
      { "re", UUID },
    }),
  },
  portal_to_server = {
    welcome = message("ack", false, {
      { "re", UUID },
      { "protocol", U16 },
      { "server_id", UUID },
      { "domains", optional(DOMAINS) },
    }),
    rejected = message("ack", false, {
      { "re", UUID },
      { "code", enum(REJECT_CODES) },
      { "reason", STRING },
    }),
    join_challenge = message("ack", false, {
      { "re", UUID },
      { "nonce", SECRET },
      { "expires_at", TIMESTAMP },
    }),
    player_authenticated = message("ack", false, {
      { "re", UUID },
      { "player_id", UUID },
      { "username", STRING },
      { "created", BOOLEAN },
    }),
    character_created = message("ack", false, {
      { "re", UUID },
      { "character", CHARACTER },
    }),
    apply_command = message("reply", false, {
      { "command", COMMAND },
    }),
    config = message("reply", false, {
      { "version", U64 },
      { "hash", STRING },
      { "snapshot", OPAQUE_OBJECT },
    }),
    held = message("ack", false, {
      { "re", UUID },
      { "records", array_of(HELD_RECORD) },
    }),
    state_applied = message("ack", false, {
      { "re", UUID },
      { "revisions", array_of(RECORD_REVISION) },
    }),
    resync_required = message("ack", false, {
      { "re", UUID },
      { "stale", array_of(RECORD_REVISION) },
      { "released", array_of(RECORD_REF) },
    }),
    player_linked = message("ack", false, {
      { "re", UUID },
      { "staff_name", STRING },
    }),
    -- The answers to a `config_changed` (E6): applied, with the version it
    -- made, or discarded because the version had moved past the one it named.
    config_change_applied = message("ack", false, {
      { "re", UUID },
      { "version", U64 },
    }),
    config_change_discarded = message("ack", false, {
      { "re", UUID },
      { "version", U64 },
    }),
    -- A notice: the whole list of linked staff on this server's online list,
    -- which `rpf.staff` replaces its grants with (F9).
    staff_permissions = message("ack", false, {
      { "staff", array_of(STAFF_GRANT) },
    }),
    -- Never answered: the portal closes the socket right after sending it
    -- (protocol 2, H1).
    restarting = message("nothing", false, {
      { "retry_after_ms", U64 },
    }),
    -- The answer to `query_records` (J2): replicas to decide on, never to
    -- write.
    records_queried = message("ack", false, {
      { "re", UUID },
      { "records", array_of(QUERIED_RECORD) },
      { "next", nullable(OPAQUE_OBJECT) },
    }),
    ack = message("nothing", false, {
      { "re", UUID },
    }),
  },
}

---The envelope's own fields, decoded and encoded before the message's.
---@type rpf.protocol.Field[]
local ENVELOPE = {
  { "id", UUID },
  { "sent_at", TIMESTAMP },
}

---Looks up a message spec, refusing an unknown direction or type.
---@param direction string `server_to_portal` or `portal_to_server`.
---@param tag any The frame's `type`.
---@return rpf.protocol.MessageSpec spec The spec.
local function spec_for(direction, tag)
  local specs = protocol.messages[direction]
  if not specs then
    fail("direction", "unknown direction " .. tostring(direction))
  end
  check_string(tag, "type")
  local spec = specs[tag]
  if not spec then
    fail("type", "unknown message type " .. tag)
  end
  return spec
end

---Decodes one frame. The frame is hostile input, so every failure is a
---return value naming the offending field, never a thrown error.
---@param direction string Which direction it travelled, which decides what types are known.
---@param text string The raw frame.
---@return rpf.Frame? frame The frame with only known fields, or nil if refused.
---@return string? err Why it was refused.
function protocol.decode(direction, text)
  local value, json_err = json.decode(text)
  if json_err then
    return nil, json_err
  end
  local ok, result = pcall(function()
    if not json.is_object(value) then
      fail("frame", "expected an object")
    end
    local spec = spec_for(direction, value.type)
    local frame = { type = value.type }
    decode_fields(ENVELOPE, value, "", frame)
    decode_fields(spec.fields, value, "", frame)
    return frame
  end)
  if ok then
    return result, nil
  end
  return nil, tostring(result)
end

---Encodes one frame, checking it as strictly as the portal will, so a bug
---here fails loudly on this side rather than as a `Malformed` from the portal.
---@param direction string Which direction it will travel.
---@param frame rpf.Frame The frame: envelope fields and message fields in one table.
---@return string? text The JSON frame, or nil if the frame is not valid.
---@return string? err Why it is not.
function protocol.encode(direction, frame)
  local ok, result = pcall(function()
    if type(frame) ~= "table" then
      fail("frame", "expected a table")
    end
    local spec = spec_for(direction, frame.type)
    local out = json.object({ type = frame.type })
    encode_fields(ENVELOPE, frame, "", out)
    encode_fields(spec.fields, frame, "", out)
    local text, err = json.encode(out)
    if not text then
      fail("frame", err or "cannot encode")
    end
    return text
  end)
  if ok then
    return result, nil
  end
  return nil, tostring(result)
end

---What answers a frame of this type, which is what tells the outbox when it
---may let go. Unknown types are answered by nothing, so they never sit in it.
---@param direction string The frame's direction.
---@param tag string The frame's `type`.
---@return "reply"|"ack"|"nothing" answered_by Mirrors `Message::answered_by`.
function protocol.answered_by(direction, tag)
  local spec = protocol.messages[direction] and protocol.messages[direction][tag]
  return spec and spec.answered_by or "nothing"
end

---Whether a frame of this type may be re-sent under a fresh id as the retry
---window closes. Unknown types are not, which is the safe answer.
---@param direction string The frame's direction.
---@param tag string The frame's `type`.
---@return boolean reissuable Mirrors `Message::reissuable`.
function protocol.reissuable(direction, tag)
  local spec = protocol.messages[direction] and protocol.messages[direction][tag]
  return spec ~= nil and spec.reissuable
end

---Whether a refused frame may be sent again under the same id, mirroring
---`RejectCode::may_retry`. Retrying anything else is an infinite loop.
---@param code string A `RejectCode`, as its wire string.
---@return boolean retry True for `retry`, and for `rate_limited` after a backoff.
function protocol.may_retry(code)
  return code == "retry" or code == "rate_limited"
end

---A copy of a frame with every credential replaced, for logging. Only the top
---level is walked, because that is the only place the protocol carries one.
---@param direction string The frame's direction.
---@param frame rpf.Frame The frame.
---@return rpf.Frame redacted A shallow copy, safe to log.
function protocol.redact(direction, frame)
  local copy = {}
  for key, value in pairs(frame) do
    copy[key] = value
  end
  local spec = protocol.messages[direction] and protocol.messages[direction][frame.type]
  if spec then
    for _, field in ipairs(spec.fields) do
      if field[2].secret and copy[field[1]] ~= nil then
        copy[field[1]] = "<redacted>"
      end
    end
  end
  return copy
end

---Mints a random (version 4) uuid from the platform's randomness. Envelope
---ids and the instance id come from here.
---@param source rpf.platform.Random The platform.
---@return string id A lowercase hyphenated uuid.
function protocol.new_id(source)
  local hex = source.random_hex(32)
  if type(hex) ~= "string" or #hex ~= 32 or hex:find("[^0-9a-f]") then
    error("rpf: random_hex(32) must return 32 lowercase hex digits", 2)
  end
  -- The version nibble is 4, and the variant's top two bits are 10.
  local nibble = tonumber(hex:sub(17, 17), 16) % 4 + 1
  local variant = ("89ab"):sub(nibble, nibble)
  return hex:sub(1, 8)
    .. "-"
    .. hex:sub(9, 12)
    .. "-4"
    .. hex:sub(14, 16)
    .. "-"
    .. variant
    .. hex:sub(18, 20)
    .. "-"
    .. hex:sub(21, 32)
end

---Formats a time as RFC 3339 in UTC, the way the portal writes timestamps:
---whole seconds, with milliseconds only when there are any. Computed rather
---than delegated to the standard library, so the output does not depend on
---the host's time zone or on which library an engine left in.
---@param ms number Milliseconds since the Unix epoch.
---@return string timestamp Like `2026-01-01T00:00:00Z`.
function protocol.timestamp(ms)
  ms = math.floor(ms)
  local seconds = math.floor(ms / 1000)
  local millis = ms - seconds * 1000
  local days = math.floor(seconds / 86400)
  local rem = seconds - days * 86400
  local hour = math.floor(rem / 3600)
  local minute = math.floor((rem - hour * 3600) / 60)
  local second = rem - hour * 3600 - minute * 60

  -- Days to a civil date, after Howard Hinnant's `civil_from_days`.
  local z = days + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local day = doy - math.floor((153 * mp + 2) / 5) + 1
  local month = mp < 10 and mp + 3 or mp - 9
  local year = yoe + era * 400 + (month <= 2 and 1 or 0)

  local text = string.format("%04d-%02d-%02dT%02d:%02d:%02d", year, month, day, hour, minute, second)
  if millis > 0 then
    text = text .. string.format(".%03d", millis)
  end
  return text .. "Z"
end

---A new frame: a fresh id, `sent_at` now, and the message's fields. Resending
---a frame reuses its old envelope instead; only a reissue calls this for old
---content.
---@param source rpf.ServerPlatform The platform, for its randomness and its clock.
---@param tag string The message type.
---@param fields table? The message's own fields.
---@return rpf.Frame frame The frame, not yet encoded.
function protocol.envelope(source, tag, fields)
  local frame = {}
  for key, value in pairs(fields or {}) do
    frame[key] = value
  end
  frame.type = tag
  frame.id = protocol.new_id(source)
  frame.sent_at = protocol.timestamp(source.now())
  return frame
end

rpf.protocol = protocol
return protocol
