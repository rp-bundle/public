---Items that equip as the engine's weapons (L3): equipping an item gives
---the character the weapon the catalog names for this engine, and taking it
---off, or losing the item, takes the weapon back.
---
---**What is equipped is part of the character**, a held record (C7): the
---slugs of the items equipped, in `records.set_weapons`, reported with the
---character as `weapons`. So equipped weapons come back after a reconnect
---and a restart: the portal hands them back with the character, and this
---module gives them again when the character goes into play. Nothing here
---keeps a copy of the list; it is read from `rpf.records` every time.
---
---**What the engine was given is memory only**: which weapon names this
---module gave which player, so it takes back exactly those and gives only
---what is missing. A respawn empties a player's hands on both engines, so
---the adapter says when one happened (`spawned`) and everything equipped is
---given again.
---
---**An equipped weapon must be carried.** The engine is given only the
---weapons of equipped items the character carries a unit of, in any of its
---held containers and whatever its data, and that is checked whenever its
---containers change (`records.contents`), records come or go, or a config
---arrives. Only an item *leaving* one of the character's containers takes
---it off the list: an equipped item that was in a container's contents
---before a write, and is in none of the character's held containers on the
---tick after it, comes off. The tick is what lets a move from the pockets to
---the backpack, which writes one and then the other, be seen whole. That is
---how dropping, giving away or selling the item takes the weapon, whoever
---moved it. A container that stops being held (the character put away, a
---record the portal took back) changes what the engine has, never the
---list, so the weapons come back with the containers.
---
---**The engine decides what a weapon is.** The catalog names one per engine
---(`rpf.ConfigItemWeapon`), and the adapter's `weapon` capability reads its
---own engine's name and says whether the engine knows it: `false` refuses
---the equip (`unknown_weapon`), and is logged once for one already equipped.
---`nil` is an engine that cannot tell from the server (FiveM, for a weapon
---outside its stock list), and the weapon is given as named. An item that is
---not a weapon on this engine is `not_a_weapon`. An item that stops being a
---weapon in config stays on the list, as a job deleted from config stays on
---the character, and is given again if it comes back.
---
---Ammo is the next step (#177): a weapon is given without any.
---@class rpf.weapons
---@field CAPABILITIES string[] The adapter's capabilities this module uses, each a function or `false`: `weapon`, `give_weapon` and `strip_weapon`.
---@field MAX_EQUIPPED integer The most weapons a character may have equipped, the portal's `limits::MAX_EQUIPPED_WEAPONS`, as `records.MAX_EQUIPPED` (the client loads this file too, without `rpf.records`).
local weapons = {}

local rpf = rpf
local events = rpf.events
local records = rpf.records
local config = rpf.config
local players = rpf.players
local characters = rpf.characters
local inventory = rpf.inventory
local handoff = rpf.handoff

weapons.CAPABILITIES = { "weapon", "give_weapon", "strip_weapon" }
weapons.MAX_EQUIPPED = 16

---@type rpf.ServerPlatform?
local platform = nil

---The adapter's capabilities, as it declared them.
---@type table?
local declared = nil

---What this module gave each player, by engine handle: the connection it
---was given on (a handle can be reused by a later connection) and the
---weapon names.
---@type table<any, { serial: integer, names: table<string, true> }>
local given = {}

---Equipped items that left one of a character's containers this tick, by
---character id, each checked on the next (`prune`).
---@type table<string, table<string, true>>
local leaving = {}

---Whether a `prune` is scheduled.
local pruning = false

---Weapon names already logged as unknown to the engine, so each is said
---once until a config makes it known.
---@type table<string, true>
local warned = {}

---Logs through the platform with the module's prefix.
---@param level string The level.
---@param message string The message.
local function log(level, message)
  if platform then
    platform.log(level, "rpf.weapons: " .. message)
  end
end

---A capability's function, if the adapter supports it.
---@param name string The capability.
---@return function? fn The function.
local function capability(name)
  local fn = declared and declared[name]
  if type(fn) ~= "function" then
    return nil
  end
  return fn
end

---Whether this engine can equip weapons: the adapter supports all three
---capabilities.
---@return boolean supported True if it does.
function weapons.supported()
  for _, name in ipairs(weapons.CAPABILITIES) do
    if not capability(name) then
      return false
    end
  end
  return true
end

---Which of the capabilities this engine supports, for `rpf.capabilities()`.
---@return table<string, boolean> supported By name.
function weapons.capabilities()
  local out = {}
  for _, name in ipairs(weapons.CAPABILITIES) do
    out[name] = capability(name) ~= nil
  end
  return out
end

---Whether equipping is this server's to do: on a companion server the
---characters or the items are the framework's (K1), and equipping goes
---through the bridge, which is the next step (#177).
---@return boolean external True if either is.
local function external()
  return rpf.domains.is_external("characters") or rpf.domains.is_external("inventory")
end

---The engine weapon an item gives here, by the adapter's reading of the
---catalog's entry.
---@param slug string The item's slug.
---@return string? name The engine's name for it.
---@return string? err `not_a_weapon`, `unknown_weapon` or `unavailable` (the adapter threw).
---@return string? unknown For `unknown_weapon`, the name the engine does not know.
local function resolve(slug)
  local def = config.item(slug)
  if type(def) ~= "table" or type(def.weapon) ~= "table" then
    return nil, "not_a_weapon"
  end
  local ok, name, known = pcall(assert(capability("weapon")), def.weapon)
  if not ok then
    log("error", "the platform's weapon capability failed for " .. slug .. ": " .. tostring(name))
    return nil, "unavailable"
  end
  if type(name) ~= "string" or name == "" then
    return nil, "not_a_weapon"
  end
  if known == false then
    return nil, "unknown_weapon", name
  end
  return name
end

---Whether a character carries at least one unit of an item, in any of its
---held containers and whatever the stack's data.
---@param character table The character.
---@param slug string The item.
---@return boolean carried True if it does.
local function carried(character, slug)
  for _, container in ipairs(rpf.facade.containers_of(character)) do
    local count = inventory.count(container.id, slug)
    if count and count > 0 then
      return true
    end
  end
  return false
end

---The engine weapons this module gave a player on their current
---connection, made fresh when it has none or a reused handle's belong to an
---earlier one.
---@param view rpf.PlayerView The player.
---@return table<string, true> names The names, to change in place.
local function given_to(view)
  local mine = given[view.handle]
  if not mine or mine.serial ~= view.serial then
    mine = { serial = view.serial, names = {} }
    given[view.handle] = mine
  end
  return mine.names
end

---Gives a player a weapon, unless the adapter throws or there is no body to
---give it to yet (the next `spawned` gives it).
---@param handle any The engine's handle.
---@param name string The engine's weapon name.
---@return boolean given True if the engine has it now.
local function give(handle, name)
  local ok, result = pcall(assert(capability("give_weapon")), handle, name)
  if not ok then
    log("error", "the platform's give_weapon failed for " .. name .. ": " .. tostring(result))
    return false
  end
  return result ~= false
end

---Takes a weapon this module gave back from a player.
---@param handle any The engine's handle.
---@param name string The engine's weapon name.
---@return boolean stripped False if the adapter threw, so the name stays on the list of what was given and the next sync tries again.
local function strip(handle, name)
  local ok, err = pcall(assert(capability("strip_weapon")), handle, name)
  if not ok then
    log("error", "the platform's strip_weapon failed for " .. name .. ": " .. tostring(err))
  end
  return ok
end

---Brings what a player in play holds in line with their character: the
---engine has the weapons of the equipped items the character carries, and
---no other weapon this module gave. Items in `gone` that are no longer
---carried also come off the list; nothing else does.
---@param view rpf.PlayerView The player, `active`.
---@param character table The character they have in play.
---@param gone table<string, true>? Equipped items that left one of the character's containers.
local function sync(view, character, gone)
  if not weapons.supported() or external() then
    return
  end
  local list = records.weapons_of(character)
  local keep, wanted, order = {}, {}, {}
  for _, slug in ipairs(list) do
    local has = carried(character, slug)
    if has or not (gone and gone[slug]) then
      keep[#keep + 1] = slug
    end
    if has then
      local name, err, unknown = resolve(slug)
      if name and not wanted[name] then
        wanted[name] = true
        order[#order + 1] = name
      elseif err == "unknown_weapon" and unknown and not warned[unknown] then
        warned[unknown] = true
        log("warn", "the item " .. slug .. " equips " .. unknown .. ", which this engine does not know; it is not given")
      end
    end
  end
  if #keep ~= #list then
    local ok, err = records.set_weapons(character.id, keep)
    if not ok then
      log("warn", "could not take an item no longer carried off a character's weapons (" .. tostring(err) .. ")")
    end
  end
  local names = given_to(view)
  for name in pairs(names) do
    if not wanted[name] and strip(view.handle, name) then
      names[name] = nil
    end
  end
  for _, name in ipairs(order) do
    if not names[name] and give(view.handle, name) then
      names[name] = true
    end
  end
end

---The players in play and the characters they have, for a sweep.
---@return { view: rpf.PlayerView, character: table }[] playing The pairs.
local function playing()
  local out = {}
  for _, view in ipairs(players.list()) do
    if view.state == "active" and view.player_id then
      local character = characters.selected(view.player_id)
      if character then
        out[#out + 1] = { view = view, character = character }
      end
    end
  end
  return out
end

---Brings every player in play in line with their character.
local function sync_all()
  for _, pair in ipairs(playing()) do
    sync(pair.view, pair.character)
  end
end

---The player in play and their character, for the engine handle an addon
---passed.
---@param handle any The engine's handle.
---@return rpf.PlayerView? view The player.
---@return table|string character The character, or why not: `not_logged_in` or `no_character`.
local function in_play(handle)
  local character, err = rpf.facade.character_of(handle)
  if not character then
    return nil, err or "not_logged_in"
  end
  local view = players.get(handle)
  if not view then
    return nil, "not_logged_in"
  end
  return view, character
end

---Equips an item a player's character carries: its weapon for this engine
---is given now, and again after every respawn, reconnect and restart,
---until it is taken off or the character stops carrying the item.
---Equipping one already equipped changes nothing and answers `true`.
---@param handle any The engine's handle of a logged-in player.
---@param item any The item's slug.
---@return boolean? ok True if it is equipped.
---@return string? status `refused`: nothing changed.
---@return string? reason `unsupported` (the engine cannot, or the server's framework owns its characters or items), `not_logged_in`, `no_character`, `not_a_weapon` (no weapon for this engine in the catalog), `unknown_weapon` (the engine does not know the one named), `no_item` (the character carries none), `too_many` (`MAX_EQUIPPED` already), or what `records.set_weapons` answered.
function weapons.equip(handle, item)
  if not weapons.supported() or external() then
    return nil, "refused", "unsupported"
  end
  local view, character = in_play(handle)
  if not view then
    return nil, "refused", character --[[@as string]]
  end
  ---@cast character table
  if type(item) ~= "string" then
    return nil, "refused", "not_a_weapon"
  end
  local _, err = resolve(item)
  if err then
    return nil, "refused", err
  end
  if not carried(character, item) then
    return nil, "refused", "no_item"
  end
  local list = records.weapons_of(character)
  for _, slug in ipairs(list) do
    if slug == item then
      sync(view, character)
      return true
    end
  end
  if #list >= weapons.MAX_EQUIPPED then
    return nil, "refused", "too_many"
  end
  list[#list + 1] = item
  local ok, why = records.set_weapons(character.id, list)
  if not ok then
    return nil, "refused", why
  end
  sync(view, records.get("character", character.id) or character)
  return true
end

---Takes an item off: its weapon is taken back, and not given again.
---Taking off one not equipped changes nothing and answers `true`.
---@param handle any The engine's handle of a logged-in player.
---@param item any The item's slug.
---@return boolean? ok True if it is not equipped now.
---@return string? status `refused`: nothing changed.
---@return string? reason `unsupported`, `not_logged_in`, `no_character`, or what `records.set_weapons` answered.
function weapons.unequip(handle, item)
  if not weapons.supported() or external() then
    return nil, "refused", "unsupported"
  end
  local view, character = in_play(handle)
  if not view then
    return nil, "refused", character --[[@as string]]
  end
  ---@cast character table
  local list, keep = records.weapons_of(character), {}
  for _, slug in ipairs(list) do
    if slug ~= item then
      keep[#keep + 1] = slug
    end
  end
  if #keep == #list then
    return true
  end
  local ok, why = records.set_weapons(character.id, keep)
  if not ok then
    return nil, "refused", why
  end
  sync(view, records.get("character", character.id) or character)
  return true
end

---The items a player's character has equipped, in the order they were.
---@param handle any The engine's handle of a logged-in player.
---@return string[]? items The slugs, a copy.
---@return string? err `unsupported`, `not_logged_in` or `no_character`.
function weapons.equipped(handle)
  if external() then
    return nil, "unsupported"
  end
  local view, character = in_play(handle)
  if not view then
    return nil, character --[[@as string]]
  end
  ---@cast character table
  return records.weapons_of(character)
end

---A player respawned, which empties their hands on both engines: the
---adapter calls this, and everything their character has equipped is
---given again. Anyone not in play is left alone, so a client claiming a
---respawn it never had gets back only what its character already has.
---@param handle any The engine's handle.
function weapons.spawned(handle)
  local view = players.get(handle)
  if not view or view.state ~= "active" or not view.player_id then
    return
  end
  local character = characters.selected(view.player_id)
  if not character then
    return
  end
  given_to(view)
  given[handle].names = {}
  sync(view, character)
end

---A character went into play: its weapons are given.
---@param view rpf.PlayerView The player.
---@param character table A copy of the character.
local function on_selected(view, character)
  if type(character) == "table" then
    sync(view, character)
  end
end

---A character was put away: what it was given is taken back, since the
---weapons are the character's and the player plays on without it. A name
---the adapter failed to take back stays, so the next sync tries again.
---@param view rpf.PlayerView The player.
local function on_deselected(view)
  local mine = given[view.handle]
  if not mine or mine.serial ~= view.serial or not weapons.supported() then
    given[view.handle] = nil
    return
  end
  for name in pairs(mine.names) do
    if strip(view.handle, name) then
      mine.names[name] = nil
    end
  end
end

---A player is leaving: nothing is taken back from someone the engine is
---removing, and nothing about them is kept.
---@param view rpf.PlayerView The player.
local function on_dropping(view)
  given[view.handle] = nil
end

---Brings each character in play that had an equipped item leave one of its
---containers in line, taking off the list each that is still not carried.
---Runs on the tick after the writes, so a move between two of the
---character's containers has written both.
local function prune()
  pruning = false
  local due = leaving
  leaving = {}
  for _, pair in ipairs(playing()) do
    local gone = due[pair.character.id]
    if gone then
      sync(pair.view, pair.character, gone)
    end
  end
end

---A held container's contents changed: if a character in play owns it, the
---engine is brought in line now, and each equipped item the container held
---before is checked on the next tick (`prune`).
---@param id string The container.
---@param before table? What it held until now.
local function on_contents(id, before)
  local container = records.get("container", id)
  local owner = container and container.owner
  if type(owner) ~= "table" or owner.kind ~= "character" then
    return
  end
  for _, pair in ipairs(playing()) do
    if pair.character.id == owner.id then
      local held = inventory.items_in(before)
      for _, slug in ipairs(records.weapons_of(pair.character)) do
        if held[slug] then
          leaving[owner.id] = leaving[owner.id] or {}
          leaving[owner.id][slug] = true
        end
      end
      sync(pair.view, pair.character)
    end
  end
  if next(leaving) and not pruning and platform then
    pruning = true
    platform.after(0, prune)
  end
end

---A config was applied: what is a weapon, and what the engine calls it,
---may have changed. Names the engine now knows may be warned about again.
local function on_config_changed()
  warned = {}
  sync_all()
end

---Starts the server half: reads the adapter's capabilities, logging one
---that is neither a function nor `false`, and listens for characters going
---into and out of play, players leaving, containers changing, records
---coming and going, config, and a client's word that its player respawned.
---Called by `rpf.start_server` after `rpf.characters`.
---@param p rpf.ServerPlatform The platform.
function weapons.start(p)
  platform = p
  declared = p.capabilities
  given = {}
  warned = {}
  leaving = {}
  pruning = false
  for _, name in ipairs(weapons.CAPABILITIES) do
    local value = declared and declared[name]
    if value ~= false and type(value) ~= "function" then
      p.log("warn", "rpf: the platform declares capability " .. name .. " as neither a function nor false; it is unsupported")
    end
  end
  events.on("characters.selected", on_selected)
  events.on("characters.deselected", on_deselected)
  events.on("players.dropping", on_dropping)
  events.on("records.contents", on_contents)
  events.on("records.held", sync_all)
  events.on("records.released", sync_all)
  events.on("records.lost", sync_all)
  events.on("config.changed", on_config_changed)
  players.on_client(handoff.SPAWNED, function(player)
    weapons.spawned(player.handle)
  end)
end

---The client half's platform, once started.
---@type rpf.ClientPlatform?
local client = nil

---Starts the client half, which only tells the server about respawns.
---Called by `rpf.start_client`.
---@param p rpf.ClientPlatform The platform.
function weapons.start_client(p)
  client = p
end

---Tells the server this player respawned, so it gives their character's
---equipped weapons again. The client adapter calls this on the engine's
---respawn where only the client sees one (FiveM's `playerSpawned`).
function weapons.respawned()
  if client then
    client.to_server(handoff.SPAWNED, handoff.encode(handoff.SPAWNED))
  end
end

rpf.weapons = weapons
return weapons
