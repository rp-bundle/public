---What staff do to a player from the portal that needs them in the game to
---mean anything (F4): the `kick` command.
---
---A kick names the player's account, never an engine handle, and is run only
---for a player logged in to that account on this server. Anyone else is
---answered `failed` and nothing happens: the portal sends a kick only for a
---player its online list has, so this is the player who left while the
---command was on its way, and the portal never queues one for later.
---
---Warnings and bans need nothing here. A warning is a record on the portal,
---whether or not the player is online; a ban arrives as a kick for whoever
---is online, and as a refusal at the next login (F3).
---@class rpf.moderation
---@field NOT_ONLINE string The answer to a kick for a player who is not logged in here, which the portal shows to the staff member who asked.
local moderation = {}

local rpf = rpf

moderation.NOT_ONLINE = "that player is not logged in on this server"

---The platform kicks go through, once `moderation.start` has run.
---@type rpf.ServerPlatform?
local platform = nil

---Runs a `kick`: disconnects the player logged in to the account, with the
---portal's reason as the message their game shows.
---@param command { player_id: string, reason: string } The decoded command.
---@return boolean applied False if the player is not logged in here.
---@return string? reason Why not, for staff.
function moderation.kick(command)
  local player = rpf.players.by_player_id(command.player_id)
  if not platform or not player or player.state == "dropping" then
    return false, moderation.NOT_ONLINE
  end
  platform.log("info", "rpf: kicking player " .. tostring(player.handle) .. " for staff: " .. command.reason)
  platform.kick(player.handle, command.reason)
  return true
end

---Registers the moderation commands. Called by `rpf.start_server`.
---@param p rpf.ServerPlatform The platform players are kicked through.
function moderation.start(p)
  platform = p
  rpf.commands.register("kick", moderation.kick)
end

rpf.moderation = moderation
return moderation
