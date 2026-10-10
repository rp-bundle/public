---The optional target-resource adapter (J4): offers the server's interaction
---rules through ox_target or qb-target, whichever is started, so a player
---aims at a placed ped or object, or a model, and picks an option from the
---resource's own eye-target menu.
---
---It is presentation and nothing more. The rules come from the server
---(`rpf:target_rules`, announced by the core as `interactions.targets`), an
---option is shown only on an entity the core placed for the rule's type
---(its `rpf_placement` state bag), or of the rule's models, and selecting
---one sends the same request as the minimal UI, naming the entity by its
---network id, for the server to check from its own state. A resource that is
---not running costs nothing: the core's menu (`rpf_interact`) works either
---way. Points and zones have no entity, so only the menu offers them.
---@class rpf.fivem.target
---@field RESOURCES string[] The target resources it knows, in the order it prefers them.
local target = {}

local rpf = rpf
local core = rpf
local fivem = rpf.fivem
local shared = fivem.shared

target.RESOURCES = { "ox_target", "qb-target" }

---What was offered through which resource, so it can be taken back.
---@class rpf.fivem.target.Offered
---@field resource string The resource.
---@field peds string[] Option names (ox_target) or labels (qb-target) on every ped.
---@field objects string[] The same, on every object.
---@field models { models: string[], names: string[] }[] The same, per list of models.

---@type rpf.fivem.target.Offered?
local offered = nil

---The rules last given, kept so a target resource that starts later, or
---restarts, is offered them too.
---@type table[]
local rules_given = {}

---A label made unique for qb-target, which keys its options by label: the
---rule's label, then a marker no player sees, a zero-width joiner followed
---by the rule's position written in binary with zero-width spaces and
---non-joiners. Two of our rules both labelled "Talk" stay two options, and
---no other script's "Talk" is replaced or, on `clear`, taken away.
---@param label string The rule's label.
---@param i integer The rule's position in what is offered.
---@return string unique The label qb-target is given.
function target.qb_label(label, i)
  local bits = {}
  repeat
    bits[#bits + 1] = i % 2 == 0 and "\226\128\139" or "\226\128\140"
    i = math.floor(i / 2)
  until i == 0
  return label .. "\226\128\141" .. table.concat(bits)
end

---The target resource that is running, if any.
---@return string? resource Its name.
function target.resource()
  for _, name in ipairs(target.RESOURCES) do
    if GetResourceState(name) == "started" then
      return name
    end
  end
  return nil
end

---Sends a rule's interaction at the entity the player selected, by its
---network id, and tells the player if the server refuses it.
---@param name string The interaction.
---@param entity integer The entity, as the target resource hands it over.
function target.select(name, entity)
  local ref = NetworkGetNetworkIdFromEntity(entity)
  core.interactions.request(name, { target = { ref = ref } }, function(ok, reason)
    if not ok then
      core.targets.tell(tostring(reason))
    end
  end)
end

---Whether an entity is one the core placed for a type: its tag names it.
---The server checks again; this only keeps an option off other entities.
---@param entity integer The entity.
---@param type_name string The type.
---@return boolean placed True if it is.
function target.placed(entity, type_name)
  local tag = Entity(entity).state[shared.PLACEMENT]
  return type(tag) == "table" and tag.type == type_name
end

---Takes back whatever was offered, so a new set of rules starts clean and a
---stopped resource leaves nothing behind.
function target.clear()
  if not offered then
    return
  end
  if GetResourceState(offered.resource) ~= "started" then
    -- Its exports went with it, and so did what it was offered.
    offered = nil
    return
  end
  local resource = exports[offered.resource]
  if offered.resource == "ox_target" then
    resource:removeGlobalPed(offered.peds)
    resource:removeGlobalObject(offered.objects)
    for _, entry in ipairs(offered.models) do
      resource:removeModel(entry.models, entry.names)
    end
  else
    resource:RemoveGlobalPed(offered.peds)
    resource:RemoveGlobalObject(offered.objects)
    for _, entry in ipairs(offered.models) do
      resource:RemoveTargetModel(entry.models, entry.names)
    end
  end
  offered = nil
end

---Offers a set of rules through the running target resource, in place of
---what was offered before: a type's rule of kind `ped` or `object` on every
---such entity the core placed for the type, and a models rule on those
---models.
---@param rules table[] The rules, as `interactions.targets` announced them.
function target.apply(rules)
  target.clear()
  rules_given = type(rules) == "table" and rules or {}
  local resource_name = target.resource()
  if not resource_name then
    return
  end
  rules = rules_given
  local resource = exports[resource_name]
  ---@type rpf.fivem.target.Offered
  local now = { resource = resource_name, peds = {}, objects = {}, models = {} }
  local ox = resource_name == "ox_target"
  for i, rule in ipairs(rules) do
    local name, type_name = rule.name, rule.type
    local key = ox and name or target.qb_label(rule.label, i)
    local option
    if ox then
      option = {
        name = name,
        label = rule.label,
        distance = rule.distance,
        canInteract = type_name and function(entity)
          return target.placed(entity, type_name)
        end or nil,
        onSelect = function(data)
          target.select(name, data.entity)
        end,
      }
    else
      option = {
        label = key,
        canInteract = type_name and function(entity)
          return target.placed(entity, type_name)
        end or nil,
        action = function(entity)
          target.select(name, entity)
        end,
      }
    end
    if type_name and rule.kind == "ped" then
      now.peds[#now.peds + 1] = key
      if ox then
        resource:addGlobalPed({ option })
      else
        resource:AddGlobalPed({ options = { option }, distance = rule.distance })
      end
    elseif type_name and rule.kind == "object" then
      now.objects[#now.objects + 1] = key
      if ox then
        resource:addGlobalObject({ option })
      else
        resource:AddGlobalObject({ options = { option }, distance = rule.distance })
      end
    elseif type(rule.models) == "table" then
      now.models[#now.models + 1] = { models = rule.models, names = { key } }
      if ox then
        resource:addModel(rule.models, { option })
      else
        resource:AddTargetModel(rule.models, { options = { option }, distance = rule.distance })
      end
    end
  end
  offered = now
end

---A resource started: a target resource that starts (or restarts) after
---the rules came is offered them now.
---@param name string The resource.
function target.started(name)
  for _, known in ipairs(target.RESOURCES) do
    if known == name then
      -- `apply` takes back what a still-running resource was offered first.
      target.apply(rules_given)
      return
    end
  end
end

---A resource stopped: if it is the target resource the rules were offered
---through, they went with it, and are not taken back from it; another
---target resource still running is offered them instead.
---@param name string The resource.
function target.stopped(name)
  if offered and offered.resource == name then
    offered = nil
    target.apply(rules_given)
  end
end

rpf.fivem.target = target
return target
