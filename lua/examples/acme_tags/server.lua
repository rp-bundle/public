---acme_tags on the game server: the addon's registration, its
---interactions, and the timer that fades old tags. Engine-neutral: everything goes
---through `rpf`, the public API, which the entry point hands in.
acme_tags = acme_tags or {}

---Deletes every held tag whose time is up. A tag it cannot delete now is
---said in the console and tried again on the next tick.
---@param rpf rpf.Api The API.
function acme_tags.fade(rpf)
  local now = rpf.time.now()
  local due, err = rpf.records.list(acme_tags.TYPE, { where = { fades_at = { lt = now } } })
  if not due then
    print("[acme_tags] could not list the tags to fade (" .. tostring(err) .. ")")
    return
  end
  for _, tag in ipairs(due) do
    local deleted, why = rpf.records.delete(acme_tags.TYPE, tag.id)
    if not deleted then
      print("[acme_tags] could not fade " .. tag.id .. " (" .. tostring(why) .. ")")
    end
  end
end

---A player's own tag, by an id their client sent: the id is hostile input,
---so it is looked up inside the player's scope. Another player's tag, a
---tag that has faded and an id that was never one are the same answer, so
---a client probing ids learns nothing.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The player who asked.
---@param id any The id, as their client sent it.
---@return rpf.Record? tag The tag, if it is theirs.
local function own_tag(rpf, player, id)
  if type(id) ~= "string" then
    return nil
  end
  local tag = rpf.records.get(acme_tags.TYPE, id)
  if not tag or not tag.owner or tag.owner.kind ~= "player" or tag.owner.id ~= player.player_id then
    return nil
  end
  return tag
end

---The tags a player has sprayed that have not faded, for their client to
---list: an interaction that answers with data (`rpf.interactions.request`).
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The player who asked.
---@return boolean ok Whether they could be listed.
---@return { tags: { id: string, text: string }[] }|string data Their tags, or why not.
function acme_tags.mine(rpf, player)
  local tags = {}
  local held, err = rpf.records.list(acme_tags.TYPE, { owner = { kind = "player", id = player.player_id } })
  if not held then
    return false, "Your tags cannot be listed now (" .. tostring(err) .. ")."
  end
  for _, tag in ipairs(held) do
    tags[#tags + 1] = { id = tag.id, text = tag.fields.text }
  end
  return true, { tags = tags }
end

---Scrubs one of the player's own tags off the wall, by its id.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The player who asked.
---@param payload table What their client sent: `{ id }`.
---@return boolean ok Whether it was scrubbed.
---@return string? reason Why not, for the player.
function acme_tags.scrub(rpf, player, payload)
  local tag = own_tag(rpf, player, payload.id)
  if not tag then
    return false, "No such tag of yours."
  end
  local deleted, why = rpf.records.delete(acme_tags.TYPE, tag.id)
  if not deleted then
    return false, "It would not come off (" .. tostring(why) .. ")."
  end
  return true
end

---Reads a tag the player stands at (J4): the interaction's rules made the
---server find the tag the client named, visible and within reach, before
---this runs, so all that is left is to show its text. It is shown to the
---player (`rpf.ui.notify`), since the menu that sent it shows only
---refusals, and answered too, for a client script of the addon's own.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The player who asked.
---@param target table The tag the rules resolved: `{ type, id, record, position, distance }`.
---@return boolean ok Always true.
---@return { text: string } data The tag's text.
function acme_tags.read(rpf, player, target)
  local text = target.record.fields.text
  rpf.ui.notify(player.handle, { title = "A tag", text = text })
  return true, { text = text }
end

---The spray can: a player's client asks, and this decides. The payload is
---whatever the client sent, so it is checked before anything is made.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The player who asked, logged in.
---@param payload table What their client sent.
---@return boolean ok Whether a tag was sprayed.
---@return string? reason Why not, for the player.
function acme_tags.spray(rpf, player, payload)
  local text = payload.text
  if type(text) ~= "string" or text == "" then
    return false, "Write something to spray."
  end
  local spot, err = rpf.world.position(player.handle)
  if not spot then
    return false, "You cannot spray from there (" .. tostring(err) .. ")."
  end
  local tag, why = rpf.records.create(acme_tags.TYPE, {
    text = text,
    spot = spot,
    fades_at = rpf.time.now() + acme_tags.DAY,
  }, { owner = { kind = "player", id = player.player_id } })
  if not tag then
    return false, "The wall would not take it (" .. tostring(why) .. ")."
  end
  return true
end

---Registers the addon. It runs once staff install it in the portal (or the
---server has `addons.auto_install` on), and everything `start` sets up is
---taken down when it stops.
---@param rpf rpf.Api The API.
---@return boolean? ok True once registered.
---@return table? refusal Why not.
function acme_tags.start_server(rpf)
  return rpf.addons.register(acme_tags.MANIFEST, {
    start = function()
      local handlers = {
        ["acme_tags.spray"] = acme_tags.spray,
        ["acme_tags.mine"] = acme_tags.mine,
        ["acme_tags.scrub"] = acme_tags.scrub,
      }
      for name, handler in pairs(handlers) do
        -- A refusal here is a bug in this file; throwing leaves the addon
        -- `failed`, with the reason in the console.
        assert(rpf.interactions.register(name, function(player, payload)
          return handler(rpf, player, payload)
        end))
      end
      assert(rpf.time.every(acme_tags.FADE_EVERY, function()
        acme_tags.fade(rpf)
      end))
      -- Aimed at a tag: the client names one, and the server checks it is
      -- a tag, near enough, before `read` runs. The menu (`rpf_interact`)
      -- lists it for any tag within reach.
      assert(rpf.interactions.register("acme_tags.read", function(player, _, target)
        return acme_tags.read(rpf, player, target)
      end, { target = acme_tags.TYPE, label = "Read the tag", distance = 3 }))
    end,
  })
end
