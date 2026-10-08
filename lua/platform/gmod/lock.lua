---Holds a player still until they are in play: the input lock.
---
---From the moment the engine hands a player over until they reach `active`
---(logged in, and playing a character), the player is locked: frozen in
---place and unhurt (`Player:Lock`), every sandbox action that would let them
---act on the world is refused, and their chat is dropped. The login form and
---the character select screen take the keyboard and mouse on the client too,
---but a client is hostile, so the lock that counts is this one, on the server.
---
---This is an adapter behaviour on purpose (#75): a bridge to an existing RP
---framework (K2) relies on a player being unable to act while
---`authenticating`, and gets it here instead of building its own. Whatever
---owns characters on the server moves the player to `active`, which is what
---releases them, so the lock follows the core's lifecycle and nothing else.
---@class rpf.gmod.Lock
---@field HOOKS string[] The sandbox hooks a locked player is refused by. Each is asked whether a player may do something, and `false` refuses it.
local lock = {}

lock.HOOKS = {
  "PlayerSpawnObject",
  "PlayerSpawnProp",
  "PlayerSpawnRagdoll",
  "PlayerSpawnEffect",
  "PlayerSpawnSENT",
  "PlayerSpawnSWEP",
  "PlayerGiveSWEP",
  "PlayerSpawnNPC",
  "PlayerSpawnVehicle",
  "PlayerNoClip",
  "PlayerUse",
  "PlayerCanPickupWeapon",
  "PlayerCanPickupItem",
  "CanPlayerSuicide",
  "CanTool",
  "CanProperty",
  "CanDrive",
  "PhysgunPickup",
  "GravGunPickupAllowed",
}

---Locked players. Weak keys, so a player who left is not kept alive.
---@type table<Player, true>
local locked = setmetatable({}, { __mode = "k" })

---Whether a player is locked.
---@param player Player The player.
---@return boolean locked True until they reach `active`.
function lock.locked(player)
  return locked[player] == true
end

---Applies the engine's half of the lock to a player who is locked: frozen and
---unhurt. Run again on every spawn, which resets both.
---@param player Player The player.
function lock.apply(player)
  if locked[player] and IsValid(player) then
    player:Lock()
  end
end

---Applies the lock again after a spawn, on the next tick, once the spawn and
---the gamemode's own spawn code have run, since either may reset the flags.
---@param player Player The player who spawned.
function lock.respawned(player)
  if locked[player] then
    timer.Simple(0, function()
      lock.apply(player)
    end)
  end
end

---Follows a player's move through the lifecycle: locked in every state
---before `active`, released on reaching it, forgotten once they leave.
---@param player Player The player.
---@param state string The state they moved to.
function lock.follow(player, state)
  if state == "dropping" then
    locked[player] = nil
  elseif state == "active" then
    if locked[player] then
      locked[player] = nil
      if IsValid(player) then
        player:UnLock()
      end
    end
  elseif not locked[player] then
    locked[player] = true
    lock.apply(player)
  end
end

---A sandbox hook's answer for a player: `false` refuses a locked player, and
---nil leaves the decision to every other hook.
---@param player any The player the hook asks about.
---@return boolean? allowed False if locked, nil otherwise.
function lock.refuse(player)
  if locked[player] then
    return false
  end
  return nil
end

---`PlayerSay`'s answer for a player: an empty string, which drops the line,
---for a locked player, and nil otherwise. Chat is refused separately from
---`HOOKS` because `PlayerSay` answers with the text to say, not a boolean.
---@param player any The player who spoke.
---@return string? text `""` if locked, nil otherwise.
function lock.silence(player)
  if locked[player] then
    return ""
  end
  return nil
end

return lock
