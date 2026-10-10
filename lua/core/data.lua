---The record calls addons make (J3): `rpf.api.records` fronts this module.
---
---It is the public face of what J2 built: `rpf.records` keeps the live
---records this server holds and checks every write against the installed
---definition, `rpf.sync` reports them, `rpf.addons` knows which addon may
---run, and the config carries `config` types' records. This module adds
---what an addon author needs on top, and nothing the portal must know:
---
--- - **Every call names the type.** On FiveM an addon is another resource,
---   so it keeps no handle: `get(type, id)`, `update(type, id, patch)`. A
---   record of another type, one not held here and one that does not exist
---   are one answer, `not_held` for a live type and `not_found` for a config
---   one.
--- - **Plain tables in and out.** What comes back is a copy with no JSON
---   marks and no `json.null`, so it crosses a FiveM export whole; a field
---   with no value is absent. Clearing a nullable field is `opts.clear`,
---   because `nil` in a patch cannot say "clear" and a FiveM export cannot
---   carry the codec's null.
--- - **Results, not throws.** A write returns the record, or nil, a reason
---   and, for `invalid`, the rule broken as the portal names it.
--- - **Revisions.** A record's `revision` moves on every change made to it
---   here (the addon's own, another addon's, a staff edit), starting from
---   the portal's revision when it was held. An update or delete naming
---   `opts.revision` is refused `stale` if the record moved on since, so an
---   addon never writes over a change it did not see. It counts changes on
---   this server, which the portal sees in batches, so it can run ahead of
---   the portal's.
--- - **Only an active addon's calls are open.** A stopped addon's held
---   records still drain to the portal (`rpf.records`, J2), but nothing an
---   addon calls writes one: `inactive`. A `start` handler is running, and
---   may read and write; code of an activation that has ended (a callback
---   that waited across a disable or a reload) gets `inactive`.
--- - **When an addon stops, the records it held for the server go.** Every
---   held record of its types that no player's session holds is released
---   with its final state, as the contract's "Disable" says. Those a session
---   holds go when the player leaves.
---
---Events, reserved: `records.created`, `records.changed` and
---`records.deleted`, each with an `rpf.data.Change`, after any write to a
---live addon record here: an addon's, a staff edit's (`by = "staff"`), and a
---deletion the portal refused, which puts the record back (`records.changed`
---with `by = "portal"`).
---@class rpf.data
---@field OPS table<string, true> The comparisons a query's `where` may use.
local data = {}

local rpf = rpf
local json = rpf.json
local events = rpf.events
local records = rpf.records

data.OPS = { eq = true, lt = true, lte = true, gt = true, gte = true, prefix = true }

---What a `records.*` event carries.
---@class rpf.data.Change
---@field type string The record's type.
---@field id string The record's id.
---@field record table? The record now, as `get` gives it; nil for a deletion.
---@field by "addon"|"staff"|"portal" Who changed it.
---@field reason string? For a deletion the portal refused, why.

---A copy a script can hold: no JSON marks, no `json.null` (a field with no
---value is absent), nothing shared with the core.
---@param value any A decoded value.
---@return any copy The copy.
local function plain(value)
  if value == json.null then
    return nil
  end
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = plain(item)
  end
  return out
end
data.plain = plain

---A held addon record as a script sees it.
---@param entry rpf.records.Entry The held record.
---@return table record `{ id, type, owner, revision, fields }`, every default filled in.
local function view_of(entry)
  local def = rpf.addons.definition(entry.data.type)
  local fields = entry.data.fields
  if def then
    fields = rpf.manifest.with_defaults(def, fields)
  end
  return {
    id = entry.id,
    type = entry.data.type,
    owner = plain(entry.data.owner),
    revision = entry.version or entry.revision,
    fields = plain(fields),
  }
end

---A held addon record as a script sees it, by id alone: for the core's own
---announcements (a staff edit, a deletion put back).
---@param id string The record's id.
---@return table? record A copy, or nil if it is not held.
function data.view(id)
  local entry = records.entries[records.key("addon_record", id)]
  return entry and view_of(entry) or nil
end

---Whether a value is a record id as the portal writes one: a lowercase
---hyphenated uuid.
---@param id any The value.
---@return boolean ok True if it is one.
local function is_id(id)
  return type(id) == "string"
    and id:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
    and id:lower() == id
end

---A type a script names, and whether its addon's calls are open: not to
---code of an addon activation that has ended (`rpf.addons.stale`), which
---may finish but changes nothing.
---@param type_name any The type's full name.
---@return table? def Its installed definition.
---@return string? err `not_found` for no such installed type, `inactive` when its addon is not running here or the caller's activation has ended.
local function open_type(type_name)
  if type(type_name) ~= "string" then
    return nil, "not_found"
  end
  if rpf.addons.stale() then
    return nil, "inactive"
  end
  local namespace = type_name:match("^([^.]+)%.")
  local def = namespace and rpf.addons.definition(type_name)
  if not def then
    return nil, "not_found"
  end
  if not rpf.addons.running(namespace) then
    return nil, "inactive"
  end
  return def
end

---A held live record of a type, not being deleted.
---@param type_name string The type.
---@param id any The record's id.
---@return rpf.records.Entry? entry The record, or nil.
local function held(type_name, id)
  if type(id) ~= "string" then
    return nil
  end
  local entry = records.entries[records.key("addon_record", id)]
  if not entry or entry.deleted or entry.data.type ~= type_name then
    return nil
  end
  return entry
end

---Announces a change to a live addon record.
---@param name "records.created"|"records.changed"|"records.deleted" The event.
---@param change rpf.data.Change What changed.
function data.announce(name, change)
  events.emit(name, change)
end

-- Reading ------------------------------------------------------------------

---One record.
---@param type_name any The type.
---@param id any The record's id.
---@return table? record A copy.
---@return string? err `not_found`, `inactive`, or `not_held` for a live record this server does not hold (whether or not it exists: `query` finds one, `hold` takes it).
function data.get(type_name, id)
  local def, err = open_type(type_name)
  if not def then
    return nil, err
  end
  if def.authority == "config" then
    for _, record in ipairs(rpf.addons.config_records(type_name)) do
      if record.id == id then
        local out = plain(record)
        out.fields = plain(rpf.manifest.with_defaults(def, record.fields))
        return out
      end
    end
    return nil, "not_found"
  end
  local entry = held(type_name, id)
  if not entry then
    return nil, "not_held"
  end
  return view_of(entry)
end

---Copies a script's query, refusing anything that is not one: a bounded
---table of plain values, so a cycle or a huge table is `invalid` rather
---than a stack overflow.
---@param value any The value.
---@param depth integer How deep this is.
---@return any? copy The copy, or nil.
---@return boolean ok False if it is not plain data.
local function bounded(value, depth)
  local kind = type(value)
  if kind == "string" or kind == "number" or kind == "boolean" then
    return value, true
  end
  if kind ~= "table" or depth > 8 then
    return nil, false
  end
  local out, count = {}, 0
  for key, item in pairs(value) do
    count = count + 1
    if count > 256 or (type(key) ~= "string" and type(key) ~= "number") then
      return nil, false
    end
    local copy, ok = bounded(item, depth + 1)
    if not ok then
      return nil, false
    end
    out[key] = copy
  end
  return out, true
end

---A query's conditions, as `{ field, op, value }` in field order.
---@param def table The type's definition.
---@param where any The query's `where`: by field, a value (equal) or a table of comparisons (`{ gte = 1, lt = 5 }`).
---@return table[]? filters The filters, or nil.
---@return table? refusal `{ error = "query", field = … }` if one is not a condition on a field of the type.
local function conditions(def, where)
  local out = {}
  if where == nil then
    return out
  end
  if type(where) ~= "table" then
    return nil, { error = "query", field = "where" }
  end
  local names = {}
  for name in pairs(where) do
    if type(name) ~= "string" or def.fields[name] == nil then
      return nil, { error = "query", field = tostring(name) }
    end
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local cond = where[name]
    local ops = nil
    if type(cond) == "table" then
      ops = {}
      for op in pairs(cond) do
        if not data.OPS[op] then
          ops = nil
          break
        end
        ops[#ops + 1] = op
      end
    end
    if ops and #ops > 0 then
      table.sort(ops)
      for _, op in ipairs(ops) do
        out[#out + 1] = { field = name, op = op, value = cond[op] }
      end
    else
      out[#out + 1] = { field = name, op = "eq", value = cond }
    end
  end
  return out
end

---Compares two values of an indexed kind: numbers as numbers, strings byte
---for byte (the portal's `collate "C"`), anything else not at all.
---@param a any One value.
---@param b any The other.
---@return integer? order -1, 0 or 1; nil when they do not compare.
local function compare(a, b)
  if type(a) ~= type(b) or (type(a) ~= "number" and type(a) ~= "string") then
    return nil
  end
  if a < b then
    return -1
  elseif a > b then
    return 1
  end
  return 0
end

---Whether a record's fields meet one condition.
---@param fields table The record's fields.
---@param filter table `{ field, op, value }`.
---@return boolean ok True if it holds.
local function meets(fields, filter)
  local value = fields[filter.field]
  if value == nil or value == json.null then
    return false
  end
  if filter.op == "eq" then
    return rpf.addons.same(plain(value), filter.value)
  end
  if filter.op == "prefix" then
    return type(value) == "string" and type(filter.value) == "string" and value:sub(1, #filter.value) == filter.value
  end
  local order = compare(value, filter.value)
  if order == nil then
    return false
  end
  if filter.op == "lt" then
    return order < 0
  elseif filter.op == "lte" then
    return order <= 0
  elseif filter.op == "gt" then
    return order > 0
  end
  return order >= 0
end

---The records of a type on this server, read locally: every held record of
---a live type, or every record of a config type, that meets the query.
---
---Any field may be filtered and ordered here, since every record is in
---memory; `query`, which asks the portal, takes indexed fields only.
---Records with no value for the order field come last either way, and ties
---go by id.
---@param type_name any The type.
---@param query any `{ where = { field = value or { lt = …, … } }, owner = { kind, id }, order = field, descending = bool, limit = n }`, all optional.
---@return table[]? records Copies, in order.
---@return string? err `not_found`, `inactive`, or `invalid` for a query that is not one.
---@return table? refusal For `invalid`, what was wrong: `{ error = "query", field = … }`.
function data.list(type_name, query)
  local def, err = open_type(type_name)
  if not def then
    return nil, err
  end
  local q, ok = bounded(query or {}, 0)
  if not ok or type(q) ~= "table" then
    return nil, "invalid", { error = "query", field = "" }
  end
  local filters, refusal = conditions(def, q.where)
  if not filters then
    return nil, "invalid", refusal
  end
  if q.order ~= nil and (type(q.order) ~= "string" or def.fields[q.order] == nil) then
    return nil, "invalid", { error = "query", field = "order" }
  end
  if q.limit ~= nil and (type(q.limit) ~= "number" or q.limit < 1 or q.limit ~= math.floor(q.limit)) then
    return nil, "invalid", { error = "query", field = "limit" }
  end
  if q.owner ~= nil and (type(q.owner) ~= "table" or type(q.owner.kind) ~= "string" or type(q.owner.id) ~= "string") then
    return nil, "invalid", { error = "query", field = "owner" }
  end
  local found = {}
  if def.authority == "config" then
    for _, record in ipairs(rpf.addons.config_records(type_name)) do
      local out = plain(record)
      out.fields = plain(rpf.manifest.with_defaults(def, record.fields))
      found[#found + 1] = out
    end
  else
    for _, entry in pairs(records.entries) do
      if entry.kind == "addon_record" and not entry.deleted and entry.data.type == type_name then
        found[#found + 1] = view_of(entry)
      end
    end
  end
  local out = {}
  for _, record in ipairs(found) do
    local keep = true
    for _, filter in ipairs(filters) do
      keep = keep and meets(record.fields, filter)
    end
    if keep and q.owner then
      keep = record.owner ~= nil and record.owner.kind == q.owner.kind and record.owner.id == q.owner.id
    end
    if keep then
      out[#out + 1] = record
    end
  end
  local field, descending = q.order, q.descending == true
  table.sort(out, function(a, b)
    if field then
      local x, y = a.fields[field], b.fields[field]
      if x == nil or y == nil then
        if x ~= nil or y ~= nil then
          return y == nil
        end
      else
        local order = compare(x, y)
        if order and order ~= 0 then
          return (order < 0) ~= descending
        end
      end
    end
    return a.id < b.id
  end)
  if q.limit then
    for i = #out, q.limit + 1, -1 do
      out[i] = nil
    end
  end
  return out
end

---Asks the portal for records of a live type, including those this server
---does not hold: how an addon finds a record to hold. Each comes back as the
---portal has it, with `held` saying whether this server holds it (when it
---does, `get` has the newer copy). To change one, `hold` it first.
---
---Filters, order and owner as for `list`, on indexed fields only (the
---portal checks); `limit` up to 100 a page, and `after` the `next` a page
---came back with, for the page after it.
---@param type_name any The type.
---@param query any As for `list`, plus `after`.
---@param callback any Called once with `(records, next, err)`: a page of copies and the cursor for the next (nil after the last), or nil, nil and why (`invalid`, `unavailable` when the portal could not be asked or did not answer, or the portal's code).
---@return boolean? ok True once the question is on its way.
---@return string? err `not_found`, `inactive`, `invalid` (with the refusal), or the outbox's refusal.
---@return table? refusal For `invalid`, what was wrong.
function data.query(type_name, query, callback)
  local def, err = open_type(type_name)
  if not def then
    return nil, err
  end
  if def.authority ~= "live" then
    return nil, "invalid", { error = "authority", field = "" }
  end
  if not rpf.callable(callback) then
    return nil, "invalid", { error = "callback", field = "" }
  end
  local q, ok = bounded(query or {}, 0)
  if not ok or type(q) ~= "table" then
    return nil, "invalid", { error = "query", field = "" }
  end
  local filters, refusal = conditions(def, q.where)
  if not filters then
    return nil, "invalid", refusal
  end
  local wire = json.object({ filters = json.array({}) })
  for _, filter in ipairs(filters) do
    wire.filters[#wire.filters + 1] = json.object(filter)
  end
  if q.owner ~= nil then
    wire.owner = json.object(q.owner)
  end
  for _, name in ipairs({ "order", "descending", "limit", "schema" }) do
    wire[name] = q[name]
  end
  if q.after ~= nil then
    wire.after = json.object(q.after)
  end
  local ctx = rpf.addons.context()
  local sent, why = records.query_addon_records(type_name, wire, function(found, next_page, failure)
    local page = nil
    if found then
      page = {}
      for i, record in ipairs(found) do
        page[i] = plain(record)
      end
    end
    local ran, thrown = rpf.addons.run(ctx, callback, page, plain(next_page), failure)
    if not ran then
      rpf.sync.platform.log("error", "rpf: a records.query callback failed: " .. tostring(thrown))
    end
  end)
  if not sent then
    return nil, why
  end
  return true
end

-- Holding ------------------------------------------------------------------

---Record refs for ids of a type, or nil if one is not an id.
---@param ids any The ids.
---@return table[]? refs `{ kind = "addon_record", id }` each.
local function refs_of(ids)
  if type(ids) ~= "table" or #ids == 0 or #ids > rpf.sync.options.max_records_per_frame then
    return nil
  end
  local out = {}
  for i, id in ipairs(ids) do
    if not is_id(id) then
      return nil
    end
    out[i] = { kind = "addon_record", id = id }
  end
  return out
end

---Holds live records by id, so this server may change them: they are the
---server's to write until released. The portal refuses the whole hold if
---any is not a record of this server's, or is held elsewhere.
---@param type_name any The type.
---@param ids any The records' ids, 1 to 64 of them.
---@param callback any? Called once with `(records, err)`: copies of those now held, or nil and the portal's refusal.
---@return boolean? ok True once the hold is on its way.
---@return string? err `not_found`, `inactive`, or `invalid` for ids that are not, a config type, or a callback that cannot be called.
function data.hold(type_name, ids, callback)
  local def, err = open_type(type_name)
  if not def then
    return nil, err
  end
  local refs = refs_of(ids)
  if def.authority ~= "live" or not refs or (callback ~= nil and not rpf.callable(callback)) then
    return nil, "invalid"
  end
  local ctx = rpf.addons.context()
  rpf.sync.hold({ records = refs }, nil, function(_, why)
    if callback == nil then
      return
    end
    local out = nil
    if not why then
      out = {}
      for _, ref in ipairs(refs) do
        local entry = held(type_name, ref.id)
        if entry then
          out[#out + 1] = view_of(entry)
        end
      end
    end
    local ran, thrown = rpf.addons.run(ctx, callback, out, why)
    if not ran then
      rpf.sync.platform.log("error", "rpf: a records.hold callback failed: " .. tostring(thrown))
    end
  end)
  return true
end

---Lets held records go, each reported with its final state.
---@param type_name any The type.
---@param ids any The records' ids.
---@return boolean? ok True once every one named is released.
---@return string? err `not_found`, `inactive`, `invalid`, or why some stayed held: `outbox_full`, `too_large`, `creating` (one whose create the portal has not had yet: it can go once it has).
function data.release(type_name, ids)
  local def, err = open_type(type_name)
  if not def then
    return nil, err
  end
  local refs = refs_of(ids)
  if def.authority ~= "live" or not refs then
    return nil, "invalid"
  end
  local mine = {}
  for _, ref in ipairs(refs) do
    if held(type_name, ref.id) then
      mine[#mine + 1] = ref
    end
  end
  if #mine == 0 then
    return true
  end
  return rpf.sync.release(mine)
end

-- Writing ------------------------------------------------------------------

---Whether a held record is at the revision a write names.
---@param entry rpf.records.Entry The record.
---@param opts table? The write's options.
---@return boolean current True if it names none, or the record's.
local function at_revision(entry, opts)
  if opts == nil or opts.revision == nil then
    return true
  end
  return opts.revision == (entry.version or entry.revision)
end

---Checks a create without making it.
---@param def table The type.
---@param type_name string Its name.
---@param fields any The fields.
---@param opts any The options: `owner`, and `id` if the addon minted one.
---@param taken table<string, true>? Ids already used in this batch.
---@return table? plan `{ owner, id, fields }` to create with.
---@return string? err Why not.
---@return table? refusal For `invalid`, the rule.
local function plan_create(def, type_name, fields, opts, taken)
  if def.authority ~= "live" then
    return nil, "invalid", { error = "authority", field = "" }
  end
  if type(opts) ~= "table" then
    return nil, "invalid", { error = "owner", field = "" }
  end
  local owner = opts.owner
  if type(owner) ~= "table" or type(owner.kind) ~= "string" or not is_id(owner.id) then
    return nil, "invalid", { error = "owner", field = "" }
  end
  local allowed = false
  for _, kind in ipairs(def.owners or {}) do
    allowed = allowed or kind == owner.kind
  end
  if not allowed then
    return nil, "invalid", { error = "owner", field = "" }
  end
  if opts.id ~= nil and not is_id(opts.id) then
    return nil, "invalid", { error = "id", field = "" }
  end
  if opts.id and (records.entries[records.key("addon_record", opts.id)] or (taken and taken[opts.id])) then
    return nil, "conflict"
  end
  if def.limit then
    local count = 0
    for _, entry in pairs(records.entries) do
      if entry.kind == "addon_record" and not entry.deleted and entry.data.type == type_name then
        count = count + 1
      end
    end
    if count >= def.limit then
      return nil, "limit"
    end
  end
  local checked, refusal = rpf.manifest.check_fields(def, fields)
  if not checked then
    return nil, "invalid", refusal
  end
  return { owner = { kind = owner.kind, id = owner.id }, id = opts.id, fields = fields }
end

---Makes a live record of an active addon's type, held by this server from
---the start; the portal has it once the next report carries it. Its fields
---are checked whole against the installed definition first.
---@param type_name any The type.
---@param fields any Its fields.
---@param opts any `owner` (`{ kind, id }`, a kind the type allows; required), and `id` (a lowercase uuid) to choose one, minted here otherwise.
---@return table? record A copy of the new record.
---@return string? err `not_found`, `inactive`, `invalid` (with the rule), `conflict` (that id is held here already) or `limit` (the type's `limit` of records is held here).
---@return table? refusal For `invalid`, the rule broken, as the portal names it.
function data.create(type_name, fields, opts)
  local def, err = open_type(type_name)
  if not def then
    return nil, err
  end
  local plan, why, refusal = plan_create(def, type_name, fields, opts)
  if not plan then
    return nil, why, refusal
  end
  local made, failed, rule = records.create_addon_record(type_name, plan.owner, plan.fields, plan.id)
  if not made then
    return nil, failed, rule
  end
  local record = assert(data.get(type_name, made.id))
  data.announce("records.created", { type = type_name, id = made.id, record = record, by = "addon" })
  return plain(record)
end

---A patch as `rpf.records` takes one: the fields given, and `json.null` for
---each `opts.clear` names.
---@param patch any The fields to set.
---@param opts any The options.
---@return table? patch The patch, or nil if it is not one.
local function patch_of(patch, opts)
  if patch ~= nil and type(patch) ~= "table" then
    return nil
  end
  local out = {}
  for name, value in pairs(patch or {}) do
    out[name] = value
  end
  local clear = type(opts) == "table" and opts.clear or nil
  if clear ~= nil then
    if type(clear) ~= "table" then
      return nil
    end
    for _, name in ipairs(clear) do
      if type(name) ~= "string" or out[name] ~= nil then
        return nil
      end
      out[name] = json.null
    end
  end
  return out
end

---Checks an update without making it.
---@param def table The type.
---@param type_name string Its name.
---@param id any The record.
---@param patch any The fields to set.
---@param opts any The options.
---@return table? plan `{ entry, patch }`.
---@return string? err Why not.
---@return table? refusal For `invalid`, the rule.
local function plan_update(def, type_name, id, patch, opts)
  local entry = held(type_name, id)
  if not entry then
    return nil, "not_held"
  end
  if not at_revision(entry, opts) then
    return nil, "stale"
  end
  local changes = patch_of(patch, opts)
  if not changes then
    return nil, "invalid", { error = "wrong_type", field = "" }
  end
  local fields, refusal = rpf.manifest.apply_patch(def, entry.data.fields, changes)
  if not fields then
    return nil, "invalid", refusal
  end
  return { entry = entry, patch = changes }
end

---Changes fields of a held record: only what the patch names, checked whole
---against the installed definition.
---@param type_name any The type.
---@param id any The record's id.
---@param patch any The fields to set, by name.
---@param opts any? `revision`: refuse as `stale` unless the record is still at it. `clear`: names of nullable fields to clear.
---@return table? record A copy of the record now, with its new revision.
---@return string? err `not_found`, `inactive`, `not_held`, `stale` or `invalid` (with the rule).
---@return table? refusal For `invalid`, the rule broken.
function data.update(type_name, id, patch, opts)
  local def, err = open_type(type_name)
  if not def then
    return nil, err
  end
  local plan, why, refusal = plan_update(def, type_name, id, patch, opts)
  if not plan then
    return nil, why, refusal
  end
  local done, failed, rule = records.set_addon_fields(plan.entry.id, plan.patch)
  if not done then
    return nil, failed, rule
  end
  local record = view_of(plan.entry)
  data.announce("records.changed", { type = type_name, id = plan.entry.id, record = record, by = "addon" })
  return plain(record)
end

---Checks a deletion without making it.
---@param type_name string The type.
---@param id any The record.
---@param opts any The options.
---@return rpf.records.Entry? entry The record.
---@return string? err Why not.
local function plan_delete(type_name, id, opts)
  local entry = held(type_name, id)
  if not entry then
    return nil, "not_held"
  end
  if not at_revision(entry, opts) then
    return nil, "stale"
  end
  return entry
end

---Deletes a held record. The portal deletes it with the next report; if
---another live record refers to it, the portal refuses, the record is put
---back, and `records.changed` says so (`by = "portal"`).
---@param type_name any The type.
---@param id any The record's id.
---@param opts any? `revision`, as for `update`.
---@return boolean? ok True once it is gone here.
---@return string? err `not_found`, `inactive`, `not_held` or `stale`.
function data.delete(type_name, id, opts)
  local _, err = open_type(type_name)
  if err then
    return nil, err
  end
  local entry, why = plan_delete(type_name --[[@as string]], id, opts)
  if not entry then
    return nil, why
  end
  records.delete_addon_record(entry.id)
  data.announce("records.deleted", { type = type_name, id = entry.id, by = "addon" })
  return true
end

---One write in a batch.
---@class rpf.data.Op
---@field op "create"|"update"|"delete" What to do.
---@field type string The record's type.
---@field id string? The record's id: required to update or delete, optional to create.
---@field fields table? A create's fields.
---@field owner table? A create's owner.
---@field patch table? An update's fields.
---@field clear string[]? An update's fields to clear.
---@field revision number? The revision an update or delete was made on.

---Writes several records all or nothing: every write is checked against the
---records as they are before any is made, and if one would be refused,
---none is made. Then they go to the portal together, in one report when it
---fits one frame: what was queued before is sent first, so the batch does
---not share a frame with older changes.
---@param ops any The writes, from 1 to the records one report carries (64), each record at most once.
---@return table? results For each write in order: the record (create, update) or true (delete).
---@return string? err Why none was made: `invalid` (with the rule and the index), the first write's own refusal (with its index), `outbox_full` when what was queued before could not be sent.
---@return table? refusal `{ index = n, … }`: which write, and for `invalid` the rule.
function data.batch(ops)
  if type(ops) ~= "table" or #ops == 0 or #ops > rpf.sync.options.max_records_per_frame then
    return nil, "invalid", { index = 0, error = "batch" }
  end
  local plans, taken = {}, {}
  for i, op in ipairs(ops) do
    if type(op) ~= "table" then
      return nil, "invalid", { index = i, error = "op" }
    end
    local def, err = open_type(op.type)
    if not def then
      return nil, err, { index = i }
    end
    local plan, why, refusal
    if op.op == "create" then
      plan, why, refusal = plan_create(def, op.type, op.fields, { owner = op.owner, id = op.id }, taken)
      if plan then
        plan.id = plan.id or rpf.protocol.new_id(rpf.sync.platform)
      end
    elseif op.op == "update" then
      plan, why, refusal = plan_update(def, op.type, op.id, op.patch, { revision = op.revision, clear = op.clear })
    elseif op.op == "delete" then
      local entry
      entry, why = plan_delete(op.type, op.id, { revision = op.revision })
      plan = entry and { entry = entry } or nil
    else
      return nil, "invalid", { index = i, error = "op" }
    end
    if not plan then
      local detail = { index = i }
      for key, value in pairs(refusal or {}) do
        detail[key] = value
      end
      return nil, why, detail
    end
    local id = plan.id or plan.entry.id
    if taken[id] then
      return nil, "invalid", { index = i, error = "duplicate" }
    end
    taken[id] = true
    plan.op, plan.type = op.op, op.type
    plans[i] = plan
  end
  -- Older changes go first, so the batch's report carries only the batch.
  if not rpf.sync.flush() then
    return nil, "outbox_full", { index = 0 }
  end
  local results, changes = {}, {}
  for i, plan in ipairs(plans) do
    local id, name, by_now
    if plan.op == "create" then
      local made = records.create_addon_record(plan.type, plan.owner, plan.fields, plan.id)
      id, name = made and made.id, "records.created"
    elseif plan.op == "update" then
      by_now = records.set_addon_fields(plan.entry.id, plan.patch)
      id, name = by_now and plan.entry.id, "records.changed"
    else
      by_now = records.delete_addon_record(plan.entry.id)
      id, name = by_now and plan.entry.id, "records.deleted"
    end
    if not id then
      -- Checked a moment ago against the same state, so this cannot happen
      -- short of a bug; say so loudly rather than half-apply in silence.
      rpf.sync.platform.log("error", "rpf: a records.batch write failed after it was checked (write " .. i .. ")")
      return nil, "unknown", { index = i }
    end
    local record = name ~= "records.deleted" and data.get(plan.type, id) or nil
    results[i] = record or true
    changes[i] = { name = name, change = { type = plan.type, id = id, record = record, by = "addon" } }
  end
  rpf.sync.flush()
  for _, change in ipairs(changes) do
    data.announce(change.name, change.change)
  end
  return plain(results)
end

-- Lifecycle ----------------------------------------------------------------

---Releases the records an addon held for the server when it stops being
---active: the contract's drain, after its `stop` ran. A record a player's
---session holds stays until the player leaves; one whose create is still
---on its way stays until the portal has it, and is released by the next
---stop or at the declaration after a restart.
---@param change rpf.addons.StateChange The addon's new state.
local function on_state(change)
  if change.state == "active" or not rpf.sync.connection then
    return
  end
  local prefix = change.namespace .. "."
  local refs = {}
  for _, entry in pairs(records.entries) do
    if
      entry.kind == "addon_record"
      and entry.through == nil
      and not entry.deleted
      and entry.data.type:sub(1, #prefix) == prefix
    then
      refs[#refs + 1] = { kind = "addon_record", id = entry.id }
    end
  end
  if #refs == 0 then
    return
  end
  table.sort(refs, function(a, b)
    return a.id < b.id
  end)
  local ok, err = rpf.sync.release(refs)
  if not ok then
    rpf.sync.platform.log(
      "warn",
      "rpf: some of " .. change.namespace .. "'s records stay held now it has stopped (" .. tostring(err) .. ")"
    )
  end
end

---Wires the module up. Called by `rpf.start_server`.
function data.start()
  events.on("addons.state", on_state)
end

rpf.data = data
return data
