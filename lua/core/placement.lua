---Linked staff's placement menu (L4). Choices carry only server-kept values;
---positions, facing, bucket and map come from the server adapter. The portal
---owns the records: confirming sends E6 compare-and-set and never edits the
---local snapshot. The client half shows only a temporary model preview.
---@class rpf.placement
---@field PREVIEW string The server-to-client preview message name.
local placement = { PREVIEW = "rpf:placement_preview" }
local rpf = rpf
---@type rpf.ServerPlatform?
local platform = nil

---Tell a staff member why an action could not be opened or sent.
---@param handle any The engine player.
---@param reason string The refusal.
local function tell(handle, reason)
  rpf.api.ui.notify(handle, { text = reason })
end

---Whether the last pushed grants offer this installed type's action.
---@param handle any The player.
---@param name string The full type name.
---@param def table The installed definition.
---@param action string The action.
---@return boolean allowed Whether it is offered.
local function allowed(handle, name, def, action)
  local grant = def.actions and def.actions[action]
  if grant == nil then grant = action == "view" and "view" or "edit" end
  local namespace = name:match("^([^.]+)%.")
  return type(grant) == "string" and rpf.staff.can(handle, "addon." .. namespace .. "." .. grant)
end

---A bounded menu over any number of installed types or records, with pages.
---@param handle any The player.
---@param title string The title.
---@param choices table[] The server-kept choices.
---@param done fun(value: any) The selected value.
---@param offset integer? First option, one unless specified.
---@return boolean? opened Whether offered.
---@return string? err A portable UI refusal.
local function choose(handle, title, choices, done, offset)
  offset = offset or 1
  local options = {}
  for i = offset, math.min(#choices, offset + 29) do options[#options + 1] = choices[i] end
  if offset > 1 then options[#options + 1] = { label = "Previous page", value = { page = offset - 30 } } end
  if offset + 30 <= #choices then options[#options + 1] = { label = "Next page", value = { page = offset + 30 } } end
  if #options == 0 then tell(handle, "There are no permitted records on this map."); return nil, "forbidden" end
  local ok, err = rpf.api.ui.menu(handle, { title = title:sub(1, 128), options = options }, function(value)
    if value == nil then return end
    if type(value) == "table" and value.page then choose(handle, title, choices, done, value.page) else done(value) end
  end)
  if not ok then tell(handle, "Placement menu: " .. tostring(err)) end
  return ok, err
end

---Copy the server's current transform into the type's world fields.
---@param handle any The player.
---@param def table The definition.
---@param fields table The fields to fill, in place.
---@return boolean ok Whether the server knows the transform.
local function transform(handle, def, fields)
  local at = rpf.world.position(handle)
  if not at then tell(handle, "The server cannot read your position."); return false end
  local world = def.world
  fields[world.position] = at
  if world.heading then
    local caps = platform and platform.capabilities
    local heading = caps and caps.heading
    local value = nil
    if type(heading) == "function" then
      local ok, result = pcall(heading, handle)
      if ok then value = result else assert(platform).log("error", "rpf: placement heading failed: " .. tostring(result)) end
    end
    if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
      tell(handle, "The server cannot read your facing direction."); return false
    end
    fields[world.heading] = value
  end
  if world.bucket then fields[world.bucket] = rpf.world.bucket(handle) end
  if world.map then fields[world.map] = rpf.world.map() end
  return true
end

---Confirm one server-built change, showing a temporary client model first.
---@param handle any The player.
---@param player_id string The account that opened the edit.
---@param version number The config version first seen.
---@param name string The type.
---@param def table Its definition.
---@param change table The E6 change.
---@param fields table? Whole fields, for a preview.
local function confirm(handle, player_id, version, name, def, change, fields)
  local p = platform
  local current = rpf.players.get(handle)
  if not p or not current or current.player_id ~= player_id then return end
  if fields and def.world.model then
    local model = fields[def.world.model]
    if model == nil then model = def.fields[def.world.model].default end
    if type(model) == "table" then model = model[p.engine] end
    if type(model) == "string" then
      p.to_client(handle, placement.PREVIEW, assert(rpf.json.encode({ model = model, position = fields[def.world.position], heading = fields[def.world.heading] or 0, kind = def.world.kind })))
    end
  end
  local ok, err = rpf.api.ui.menu(handle, { title = "Confirm placement", options = {
    { label = change.change == "delete_world_record" and "Remove record" or "Save placement", value = true },
    { label = "Cancel", value = false },
  } }, function(yes)
    p.to_client(handle, placement.PREVIEW, "{}")
    local player = rpf.players.get(handle)
    if yes ~= true or not player or player.player_id ~= player_id then return end
    local sent, refusal = rpf.config.edit(handle, version, { change })
    if not sent then tell(handle, "Placement was not sent: " .. tostring(refusal)) end
  end)
  if not ok then p.to_client(handle, placement.PREVIEW, "{}"); tell(handle, "Placement confirmation: " .. tostring(err)) end
end

---Collect required fields without exposing world coordinates as input. A
---complex field uses JSON, like the panel, so every manifest kind is usable.
---@param handle any The player.
---@param def table The definition.
---@param fields table Collected fields.
---@param done fun() Continues once complete.
local function required_fields(handle, def, fields, done)
  local names = {}
  for name, field in pairs(def.fields) do
    if fields[name] == nil and field.required and field.default == nil and not field.hidden and not field.read_only then names[#names + 1] = name end
  end
  table.sort(names)
  local name = names[1]
  if not name then done(); return end
  local field = def.fields[name]
  if field.type == "enum" then
    local choices = {}
    for _, value in ipairs(field.values) do choices[#choices + 1] = { label = value:sub(1, 128), value = value } end
    choose(handle, (field.label or name):sub(1, 128), choices, function(value)
      fields[name] = value
      required_fields(handle, def, fields, done)
    end)
    return
  end
  local kind = (field.type == "integer" or field.type == "number" or field.type == "timestamp") and "number" or field.type == "boolean" and "checkbox" or "text"
  local complex = kind == "text" and field.type ~= "string" and field.type ~= "text" and field.type ~= "enum" and (field.type ~= "ref" or field.to == "job")
  local ok, err = rpf.api.ui.input(handle, { title = "New placement", fields = {
    { name = "value", label = (field.label or name):sub(1, 110) .. (complex and " (JSON)" or ""), kind = kind, required = kind ~= "checkbox" },
  } }, function(answer)
    if not answer then return end
    local value = answer.value
    if complex then
      local decoded, decode_error = rpf.json.decode(value)
      if decode_error then tell(handle, "Enter valid JSON for " .. name); required_fields(handle, def, fields, done); return end
      value = decoded
    end
    fields[name] = value
    required_fields(handle, def, fields, done)
  end)
  if not ok then tell(handle, "Placement fields: " .. tostring(err)) end
end

---Open the installed world config types the linked staff member may view
---and change. Each asynchronous edit keeps its original config version.
---@param handle any The engine player handle.
---@return boolean? opened True if a menu was offered.
---@return string? err `not_found`, `unavailable` or `forbidden`.
function placement.open(handle)
  local player = rpf.players.get(handle)
  local version = rpf.config.version()
  if not player or not player.player_id then return nil, "not_found" end
  if not platform or not version then return nil, "unavailable" end
  local choices = {}
  for _, namespace in ipairs(rpf.addons.active()) do
    for _, name in ipairs(rpf.addons.type_names(namespace)) do
      local def = rpf.addons.definition(name)
      if def and def.authority == "config" and def.world and allowed(handle, name, def, "view") and
        (allowed(handle, name, def, "create") or allowed(handle, name, def, "edit") or allowed(handle, name, def, "delete")) then
        choices[#choices + 1] = { label = (def.title or name):sub(1, 128), value = name }
      end
    end
  end
  if #choices == 0 then return nil, "forbidden" end
  return choose(handle, "Place world records", choices, function(name)
    local def = rpf.addons.definition(name)
    if not def then return end
    local actions = {}
    for _, action in ipairs({ "create", "edit", "delete" }) do
      if allowed(handle, name, def, action) then actions[#actions + 1] = { label = ({ create = "Create here", edit = "Move here", delete = "Remove" })[action], value = action } end
    end
    choose(handle, name, actions, function(action)
      local base = version
      if not base then return end
      if action == "create" then
        local fields = {}
        if not transform(handle, def, fields) then return end
        required_fields(handle, def, fields, function()
          -- Read again before the preview; never take coordinates from UI.
          if not transform(handle, def, fields) then return end
          confirm(handle, player.player_id, base, name, def, { change = "create_world_record", type_name = name, fields = fields }, fields)
        end)
        return
      end
      local records = {}
      for _, record in ipairs(rpf.addons.config_records(name)) do
        if rpf.world.on_map(name, record.fields) then
          local label = record.id
          for _, key in ipairs({ "name", "title" }) do
            local field = def.fields[key]
            if field and not field.hidden and record.fields[key] ~= nil then label = record.fields[key]; break end
          end
          records[#records + 1] = { label = tostring(label):sub(1, 128), value = record }
        end
      end
      choose(handle, "Choose a record", records, function(record)
        local change = { change = action == "edit" and "update_world_record" or "delete_world_record", type_name = name, record_id = record.id, base_revision = record.revision }
        local fields = nil
        if action == "edit" then
          change.patch = {}
          if not transform(handle, def, change.patch) then return end
          fields = rpf.json.copy(record.fields)
          for key, value in pairs(change.patch) do fields[key] = value end
        end
        confirm(handle, player.player_id, base, name, def, change, fields)
      end)
    end)
  end)
end

---Install the built-in command on the server; the same entry is public for
---a staff menu to call. Console callers and unlinked players are refused.
---@param p rpf.ServerPlatform The server adapter.
function placement.start(p)
  platform = p
  p.on_command("rpfplace", function(handle)
    local ok, err = placement.open(handle)
    if not ok and handle ~= nil then tell(handle, "Placement: " .. tostring(err)) end
  end)
end

---Show the server's preview for at most one menu timeout. The adapter owns
---the local ghost and returns a disposer; no client value returns to server.
---@param p rpf.ClientPlatform The client adapter.
function placement.start_client(p)
  local clear = nil
  local generation = 0
  ---Dispose an adapter ghost without dropping an engine failure.
  local function finish()
    if clear then
      local dispose = clear
      clear = nil
      local ok, err = pcall(dispose)
      if not ok then p.log("error", "rpf: placement preview cleanup failed: " .. tostring(err)) end
    end
  end
  p.on_server(placement.PREVIEW, function(text)
    if type(text) ~= "string" or #text > 4096 then return end
    local spec = rpf.json.decode(text)
    if type(spec) ~= "table" then return end
    generation = generation + 1
    finish()
    if spec.model and p.ui.preview then
      local at = spec.position
      if type(spec.model) ~= "string" or type(at) ~= "table" or (spec.kind ~= "ped" and spec.kind ~= "object") then return end
      for _, value in ipairs({ at.x, at.y, at.z, spec.heading }) do
        if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then return end
      end
      if at.x == nil or at.y == nil or at.z == nil or spec.heading == nil then return end
      local ok, result = pcall(p.ui.preview, spec)
      if not ok then p.log("error", "rpf: placement preview failed: " .. tostring(result)); return end
      if rpf.callable(result) then clear = result end
      local opened = generation
      p.after(60000, function() if generation == opened then finish() end end)
    end
  end)
end

rpf.placement = placement
return placement
