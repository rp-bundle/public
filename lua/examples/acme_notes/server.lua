---acme_notes on the game server: the addon's registration and its
---interactions. Engine-neutral: everything goes through `rpf`, the public
---API, which the entry point hands in.
acme_notes = acme_notes or {}

---How close to a note a player must stand to read it or take it down, in
---metres.
acme_notes.REACH_METRES = 2

---Whether a note is the player's own.
---@param player rpf.PlayerView The player.
---@param note rpf.Record The note.
---@return boolean mine True if they pinned it.
local function owns(player, note)
  return note.owner ~= nil and note.owner.kind == "player" and note.owner.id == player.player_id
end

---Pins a note where the player stands. The payload is whatever their client
---sent, so it is checked before anything is made; where the note goes is
---the server's to say, never the client's.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The player who asked, logged in.
---@param payload table What their client sent: `{ text, colour }`.
---@return boolean ok Whether a note was pinned.
---@return string? reason Why not, for the player.
function acme_notes.pin(rpf, player, payload)
  if type(payload.text) ~= "string" or payload.text == "" then
    return false, "Write something on the note."
  end
  local mine, err = rpf.records.list(acme_notes.TYPE, { owner = { kind = "player", id = player.player_id } })
  if not mine then
    return false, "The board is closed now (" .. tostring(err) .. ")."
  end
  if #mine >= acme_notes.PER_PLAYER then
    return false, "Take one of your notes down first."
  end
  local spot, where = rpf.world.position(player.handle)
  if not spot then
    return false, "You cannot pin a note here (" .. tostring(where) .. ")."
  end
  local note, why, rule = rpf.records.create(acme_notes.TYPE, {
    text = payload.text,
    -- Unchecked here: the type's definition refuses a colour it lacks.
    colour = payload.colour,
    spot = spot,
    bucket = rpf.world.bucket(player.handle) or 0,
    pinned_at = rpf.time.now(),
  }, { owner = { kind = "player", id = player.player_id } })
  if not note then
    if why == "invalid" and rule then
      return false, "Not that note (" .. tostring(rule.field) .. ": " .. tostring(rule.error) .. ")."
    end
    return false, "It would not stick (" .. tostring(why) .. ")."
  end
  return true
end

---Reads a note the player stands at: the interaction's rules made the server
---find the note the client named, in the player's bucket and within reach,
---before this runs. The text is shown to the player, since the menu that
---sent it shows only refusals, and answered too, for a script of their own.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The player who asked.
---@param target table The note the rules resolved: `{ type, id, record, position, distance }`.
---@return boolean ok Always true.
---@return { text: string, colour: string } data The note.
function acme_notes.read(rpf, player, target)
  local fields = target.record.fields
  rpf.ui.notify(player.handle, { title = "A " .. fields.colour .. " note", text = fields.text })
  return true, { text = fields.text, colour = fields.colour }
end

---Takes a note down. The delete names the revision the note was read at, so
---it never removes a note changed since (a staff edit landing first); then
---it reads the note again, checks again, and tries once more. A note that
---went meanwhile (staff removed it) is said to be gone, never taken down
---twice.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The player who asked.
---@param note rpf.Record The note, as read.
---@param anyone boolean Whether they may take down anyone's (staff), or only their own.
---@return boolean ok Whether it is down.
---@return string? reason Why not, for the player.
function acme_notes.take_down(rpf, player, note, anyone)
  for _ = 1, 2 do
    if not anyone and not owns(player, note) then
      return false, "That note is not yours."
    end
    local done, why = rpf.records.delete(acme_notes.TYPE, note.id, { revision = note.revision })
    if done then
      return true
    end
    if why ~= "stale" and why ~= "not_held" then
      return false, "It would not come off (" .. tostring(why) .. ")."
    end
    -- Changed (`stale`) or gone (`not_held`: no longer here) since it was read.
    local now = rpf.records.get(acme_notes.TYPE, note.id)
    if not now then
      return false, "That note is gone."
    end
    note = now
  end
  return false, "Someone is changing it; try again."
end

---Registers the addon. It runs once staff install it in the portal, and
---everything `start` sets up is taken down when it stops. It holds nothing
---itself: the type's `hold = "server"` has RPF hold every note, and place
---it in the world.
---@param rpf rpf.Api The API.
---@return boolean? ok True once registered.
---@return table? refusal Why not.
function acme_notes.start_server(rpf)
  return rpf.addons.register(acme_notes.MANIFEST, {
    start = function()
      local reach = acme_notes.REACH_METRES
      -- A refusal here is a bug in this file; throwing leaves the addon
      -- `failed`, with the reason in the console.
      assert(rpf.interactions.register("acme_notes.pin", function(player, payload)
        return acme_notes.pin(rpf, player, payload)
      end))
      assert(rpf.interactions.register("acme_notes.read", function(player, _, target)
        return acme_notes.read(rpf, player, target)
      end, { target = acme_notes.TYPE, label = "Read the note", distance = reach }))
      -- Offered only on the player's own notes: the `check` runs when the
      -- menu or a target resource lists, and again when they pick.
      assert(rpf.interactions.register("acme_notes.take_down", function(player, _, target)
        return acme_notes.take_down(rpf, player, target.record, false)
      end, { target = acme_notes.TYPE, label = "Take your note down", distance = reach, check = function(player, target)
        return owns(player, target.record), "That note is not yours."
      end }))
      -- Staff in game: offered only to a linked staff member holding
      -- `addon.acme_notes.moderate` here, which the server checks before this runs.
      assert(rpf.interactions.register("acme_notes.remove", function(player, _, target)
        return acme_notes.take_down(rpf, player, target.record, true)
      end, { target = acme_notes.TYPE, label = "Remove the note (staff)", distance = reach, permission = "moderate" }))
    end,
  })
end
