---Holds a player still until they are in play, server-side: the input lock.
---
---From the moment the engine hands a player over until they reach `active`
---(logged in, and playing a character), the player is held in a routing
---bucket of their own, where they see no other player and nobody sees them,
---and where clients may create no entity at all (`strict` lockdown). Their
---chat is refused. The login and character screens also take the keyboard
---and freeze the ped on the client (`client.lua`), but a client is hostile,
---so the lock that counts is this one, on the server. Routing buckets need
---OneSync, which every current FiveM server runs.
---
---This is an adapter behaviour on purpose (#75): a bridge to an existing RP
---framework (K2) relies on a player being unable to act until `active`, and
---gets it here instead of building its own. Whatever owns characters moves
---the player to `active`, which is what releases them, so the lock follows
---the core's lifecycle and nothing else.
---@class rpf.fivem.lock
---@field BUCKET_BASE integer Held players' buckets are this plus their server id, one each, well clear of the low numbers owners' scripts use.
local lock = {}

local rpf = rpf

lock.BUCKET_BASE = 1000000

---The bucket each held player was in before, by handle, to put them back.
---@type table<integer, integer>
local held = {}

---Whether a player is held.
---@param handle any The player's server id.
---@return boolean held True until they reach `active`.
function lock.locked(handle)
  return held[handle] ~= nil
end

---Follows a player's move through the lifecycle: held in every state before
---`active`, released on reaching it, forgotten once they leave.
---@param handle integer The player's server id.
---@param state string The state they moved to.
function lock.follow(handle, state)
  if state == "dropping" then
    held[handle] = nil
  elseif state == "active" then
    local previous = held[handle]
    if previous ~= nil then
      held[handle] = nil
      SetPlayerRoutingBucket(tostring(handle), previous)
    end
  elseif held[handle] == nil then
    held[handle] = tonumber(GetPlayerRoutingBucket(tostring(handle))) or 0
    local bucket = lock.BUCKET_BASE + handle
    SetRoutingBucketEntityLockdownMode(bucket, "strict")
    SetPlayerRoutingBucket(tostring(handle), bucket)
  end
end

---Refuses a held player's chat: the `chat` resource's `chatMessage` is
---cancelled, so the line goes nowhere.
---@param from any Who spoke, as `chatMessage` names them.
function lock.silence(from)
  if held[tonumber(from)] ~= nil then
    CancelEvent()
  end
end

rpf.fivem.lock = lock
return lock
