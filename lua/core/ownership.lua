---Ownership, access and locking for things in the world (L2, #176): doors
---first, properties too, vehicles later.
---
---**A thing is a record.** An ownable thing is a live record of a world type
---its server holds (`hold = "server"`), whose `world` names its ownership
---fields by role (`docs/architecture/addons.md`, "World definitions"):
---`locked`, `owner`, `co_owners`, `employer`, `jobs`, `departments` and
---`ranks`. So every addon that sells, shares or picks a lock works on the
---same fields, and the core needs no code of the addon's to lock one.
---
---**Access** goes to the owner, the co-owners, and anyone whose job matches
---the record's `jobs` (that job), `departments` (any job in it) or `ranks`
---(that job's rank or higher at its employer). A job door, owned by an
---`employer`, with none of the three set is open to everyone the employer
---employs. Jobs are read through the domain-neutral facade, so on a server
---whose own framework owns jobs only the owner and co-owners (players
---there) count: its jobs are not RPF's employers.
---
---**Lock and unlock.** As an addon becomes active, the core registers Lock
---and Unlock on each of its types with a `locked` role, under the addon's
---namespace (`<namespace>.rpf_lock<n>` and `rpf_unlock<n>`, names no addon
---may take), in the addon's context, so they go with that activation. Each
---is offered only to a player with access, Lock on an unlocked record and
---Unlock on a locked one, and the server checks both again when it is
---picked. The record changes as the holder changes any record: the field is
---written here and reported to the portal.
---
---**For addons**, `rpf.api.ownership`: `lock`, `unlock`, `locked`,
---`has_access` and `mode`. A lockpick unlocks with no player after its own
---checks; a call naming a player checks that player's access first. A
---refusal is `false`, a reason an addon can branch on, and a sentence it can
---show the player.
---
---**The mode** (`world.ownership`, a server setting) is `persistent`,
---`session` or `off`. Off, the core offers no Lock or Unlock and refuses
---every lock and unlock (`off`), leaving the server's doors to another
---system; the fields stay as they are.
---@class rpf.ownership
---@field SETTING string The server setting naming the mode.
---@field MODES table<string, true> The modes, by name.
---@field DEFAULT_MODE string The mode while the config names none.
---@field LOCK string What the Lock interaction is labelled.
---@field UNLOCK string What the Unlock interaction is labelled.
---@field MESSAGES table<string, string> What a player is told for each refusal, by reason.
local ownership = {}

local rpf = rpf

ownership.SETTING = "world.ownership"
ownership.MODES = { persistent = true, session = true, off = true }
ownership.DEFAULT_MODE = "persistent"
ownership.LOCK = "Lock"
ownership.UNLOCK = "Unlock"
ownership.MESSAGES = {
  off = "Locks aren't in use here.",
  not_found = "That isn't here.",
  not_lockable = "That has no lock.",
  no_access = "You don't have a key to that.",
  invalid = "That can't be done.",
  inactive = "That can't be done right now.",
  failed = "The lock won't turn.",
  already_locked = "It's already locked.",
  already_unlocked = "It's already unlocked.",
}

---@type rpf.ServerPlatform?
local platform = nil

---Logs, once the platform is known.
---@param level string The level.
---@param message string What happened.
local function log(level, message)
  if platform then
    platform.log(level, "rpf.ownership: " .. message)
  end
end

---A refusal: `false`, the reason, and the sentence for a player.
---@param reason string Why.
---@return boolean ok Always false.
---@return string reason The reason.
---@return string message What a player is told.
local function refuse(reason)
  return false, reason, ownership.MESSAGES[reason] or ownership.MESSAGES.invalid
end

---The server's ownership mode: `persistent`, `session` or `off`, as staff
---set it in the panel, or the default while the config names none.
---@return string mode The mode.
function ownership.mode()
  local mode = rpf.config.setting(ownership.SETTING)
  if type(mode) == "string" and ownership.MODES[mode] then
    return mode
  end
  return ownership.DEFAULT_MODE
end

---A type's `world`, if it names any ownership role.
---@param type_name any The type.
---@return table? world Its `world`.
local function world_of(type_name)
  if type(type_name) ~= "string" then
    return nil
  end
  local def = rpf.addons.definition(type_name)
  local world = type(def) == "table" and def.world or nil
  if type(world) ~= "table" then
    return nil
  end
  for _, role in ipairs({ "locked", "owner", "co_owners", "employer", "jobs", "departments", "ranks" }) do
    if world[role] ~= nil then
      return world
    end
  end
  return nil
end

---Whether the calling code belongs to an addon activation that has ended
---(`rpf.addons.stale`): a callback that waited across a disable or a reload
---may finish, but reads and changes nothing, as `rpf.api.records` refuses it.
---@return boolean stale True to refuse with `inactive`.
local function stale()
  return rpf.addons.stale()
end

---A held record of a type, as the holder has it.
---@param type_name string The type.
---@param id any The record's id.
---@return table? record A copy: `{ id, type, fields, revision, … }`.
local function held(type_name, id)
  if type(id) ~= "string" then
    return nil
  end
  local record = rpf.data.view(id)
  if not record or record.type ~= type_name then
    return nil
  end
  return record
end

---Whether a list field holds a value.
---@param list any The field's value.
---@param match fun(item: any): boolean Whether an item is the one.
---@return boolean found True if any item matches.
local function any(list, match)
  if type(list) ~= "table" then
    return false
  end
  for _, item in ipairs(list) do
    if match(item) then
      return true
    end
  end
  return false
end

---Who a player is to an owner field of a kind: the character they play on
---a native server, or the player.
---@param player table The player, as `rpf.players` has them.
---@param kind any The field's `to`: `character` or `player`.
---@return string? id Their id of that kind, or nil.
local function identity(player, kind)
  if kind == "player" then
    return player.player_id
  end
  local character = rpf.characters.selected(player.player_id)
  return character and character.id or nil
end

---Whether a player's job, as the facade reads it, gives access through the
---record's `jobs`, `departments`, `ranks` or `employer`.
---@param handle any The player's engine handle.
---@param world table The type's `world`.
---@param fields table The record's fields.
---@return boolean access True if the job gives access.
local function job_access(handle, world, fields)
  local job = rpf.facade.current_job(handle)
  if type(job) ~= "table" or type(job.employer) ~= "string" then
    return false
  end
  local jobs, departments, ranks =
    world.jobs and fields[world.jobs], world.departments and fields[world.departments], world.ranks and fields[world.ranks]
  if any(jobs, function(entry)
    return type(entry) == "table" and entry.employer == job.employer and entry.job == job.name
  end) then
    return true
  end
  if any(departments, function(entry)
    return type(entry) == "table" and entry.employer == job.employer and entry.department == job.department
  end) then
    return true
  end
  if any(ranks, function(entry)
    if type(entry) ~= "table" or entry.employer ~= job.employer then
      return false
    end
    local def = rpf.config.job(entry.employer, entry.job)
    return type(def) == "table" and type(job.grade) == "number" and job.grade >= (def.rank or 0)
  end) then
    return true
  end
  -- A job door with no access listed is its employer's staff's.
  local employer = world.employer and fields[world.employer]
  local listed = (type(jobs) == "table" and #jobs > 0)
    or (type(departments) == "table" and #departments > 0)
    or (type(ranks) == "table" and #ranks > 0)
  return type(employer) == "string" and not listed and rpf.config.employer_slug(employer) == job.employer
end

---Whether a player has access to a record of a type: owns it, shares it,
---or has a job it lets in.
---@param handle any The player's engine handle.
---@param world table The type's `world`, with `kind_of_owner` (`with_owner_kind`).
---@param fields table The record's fields.
---@return boolean access True if they do.
local function allowed(handle, world, fields)
  local player = rpf.players.get(handle)
  if not player or not player.player_id then
    return false
  end
  local owner = world.owner and fields[world.owner]
  local kind = world.kind_of_owner
  local me = world.owner and identity(player, kind) or nil
  if me and owner == me then
    return true
  end
  if me and world.co_owners and any(fields[world.co_owners], function(item)
    return item == me
  end) then
    return true
  end
  return job_access(handle, world, fields)
end

---A type's `world` with what access checks need beside it: the kind of
---owner its `owner` field names.
---@param type_name string The type.
---@param world table Its `world`.
---@return table world A copy with `kind_of_owner` set.
local function with_owner_kind(type_name, world)
  local out = {}
  for key, value in pairs(world) do
    out[key] = value
  end
  local def = rpf.addons.definition(type_name)
  local field = world.owner and def and def.fields and def.fields[world.owner]
  out.kind_of_owner = type(field) == "table" and field.to or nil
  return out
end

---Whether a player has access to a held record: the owner, a co-owner, or
---someone its `jobs`, `departments`, `ranks` or `employer` lets in.
---@param handle any The player's engine handle.
---@param type_name any The type.
---@param id any The record's id.
---@return boolean? access True or false, or nil when it cannot be asked.
---@return string? reason For nil: `not_found` for no such record held here, `not_lockable` for a type with no ownership, `inactive` from code of an addon activation that has ended.
function ownership.has_access(handle, type_name, id)
  if stale() then
    return nil, "inactive"
  end
  local world = world_of(type_name)
  if not world then
    return nil, rpf.addons.definition(type_name) and "not_lockable" or "not_found"
  end
  local record = held(type_name --[[@as string]], id)
  if not record then
    return nil, "not_found"
  end
  return allowed(handle, with_owner_kind(type_name --[[@as string]], world), record.fields)
end

---Whether a held record is locked.
---@param type_name any The type.
---@param id any The record's id.
---@return boolean? locked True or false, or nil when it cannot be asked.
---@return string? reason For nil: `not_found`, `not_lockable` or `inactive`, as `has_access` says.
function ownership.locked(type_name, id)
  if stale() then
    return nil, "inactive"
  end
  local world = world_of(type_name)
  if not world or not world.locked then
    return nil, world and "not_lockable" or (rpf.addons.definition(type_name) and "not_lockable" or "not_found")
  end
  local record = held(type_name --[[@as string]], id)
  if not record then
    return nil, "not_found"
  end
  return record.fields[world.locked] == true
end

---Locks or unlocks a held record.
---@param type_name any The type.
---@param id any The record's id.
---@param locked boolean True to lock.
---@param opts any? `{ player = handle }`: refuse unless that player has access.
---@return boolean ok True once it is as asked (already being so counts).
---@return string? reason For a refusal: `off`, `not_found`, `not_lockable`, `no_access`, `invalid`, `inactive` or `failed`.
---@return string? message For a refusal, a sentence for the player.
local function set(type_name, id, locked, opts)
  if opts ~= nil and type(opts) ~= "table" then
    return refuse("invalid")
  end
  if stale() then
    return refuse("inactive")
  end
  if ownership.mode() == "off" then
    return refuse("off")
  end
  local world = world_of(type_name)
  if not world or not world.locked then
    return refuse(rpf.addons.definition(type_name) and "not_lockable" or "not_found")
  end
  local record = held(type_name --[[@as string]], id)
  if not record then
    return refuse("not_found")
  end
  local handle = opts and opts.player
  if handle ~= nil and not allowed(handle, with_owner_kind(type_name --[[@as string]], world), record.fields) then
    return refuse("no_access")
  end
  if (record.fields[world.locked] == true) == locked then
    return true
  end
  local done, err = rpf.records.set_addon_fields(id, { [world.locked] = locked })
  if not done then
    log("error", "could not " .. (locked and "lock " or "unlock ") .. type_name .. " " .. id .. ": " .. tostring(err))
    return refuse("failed")
  end
  local player = handle ~= nil and rpf.players.get(handle) or nil
  rpf.data.announce("records.changed", { type = type_name, id = id, record = rpf.data.view(id), by = "core" })
  rpf.events.emit("ownership.locked", {
    type = type_name,
    id = id,
    locked = locked,
    player_id = player and player.player_id or nil,
  })
  return true
end

---Locks a held record (`rpf.api.ownership.lock`).
---@param type_name any The type, one with a `locked` role.
---@param id any The record's id.
---@param opts any? `{ player = handle }` to refuse unless that player has access.
---@return boolean ok True once locked.
---@return string? reason For a refusal: `off`, `not_found`, `not_lockable`, `no_access`, `invalid`, `inactive` (from code of an addon activation that has ended) or `failed`.
---@return string? message For a refusal, a sentence for the player.
function ownership.lock(type_name, id, opts)
  return set(type_name, id, true, opts)
end

---Unlocks a held record (`rpf.api.ownership.unlock`): what a lockpick calls
---with no player, after its own checks.
---@param type_name any The type, one with a `locked` role.
---@param id any The record's id.
---@param opts any? `{ player = handle }` to refuse unless that player has access.
---@return boolean ok True once unlocked.
---@return string? reason For a refusal, as `lock` says.
---@return string? message For a refusal, a sentence for the player.
function ownership.unlock(type_name, id, opts)
  return set(type_name, id, false, opts)
end

---Registers Lock and Unlock for each of an addon's types with a `locked`
---role, in the addon's context, so they go when that activation stops.
---@param namespace string The addon, just started.
local function register_locks(namespace)
  local context = rpf.addons.context_of(namespace)
  if not context then
    return
  end
  for i, type_name in ipairs(rpf.addons.type_names(namespace)) do
    local world = world_of(type_name)
    if world and world.locked then
      for _, locking in ipairs({ true, false }) do
        local name = namespace .. (locking and ".rpf_lock" or ".rpf_unlock") .. i
        local ran, ok, err = rpf.addons.run(context, function()
          return rpf.interactions.register_reserved(name, function(player, _, target)
            local done, _, message = set(type_name, target.id, locking, { player = player.handle })
            if not done then
              return false, message
            end
            return true, { locked = locking }
          end, {
            target = type_name,
            label = locking and ownership.LOCK or ownership.UNLOCK,
            -- Refused with the sentence the player is told, as the API's
            -- refusals are; the listing only reads that it refused.
            check = function(player, target)
              if ownership.mode() == "off" then
                return false, ownership.MESSAGES.off
              end
              local fields = target and target.record and target.record.fields
              local current = world_of(type_name)
              if type(fields) ~= "table" or not current or not current.locked then
                return false, ownership.MESSAGES.not_lockable
              end
              if not allowed(player.handle, with_owner_kind(type_name, current), fields) then
                return false, ownership.MESSAGES.no_access
              end
              if (fields[current.locked] == true) == locking then
                return false, locking and ownership.MESSAGES.already_locked or ownership.MESSAGES.already_unlocked
              end
              return true
            end,
          })
        end)
        if not (ran and ok) then
          log("error", "could not offer " .. (locking and "Lock" or "Unlock") .. " on " .. type_name .. ": " .. tostring(err or ok))
        end
      end
    end
  end
end

---Starts the module on the game server: Lock and Unlock follow the addons
---as they start.
---@param p rpf.ServerPlatform The platform.
function ownership.start(p)
  platform = p
  rpf.events.on("addons.state", function(change)
    if change.state == "active" then
      register_locks(change.namespace)
    end
  end)
end

rpf.ownership = ownership
return ownership
