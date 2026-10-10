---acme_tags on the game server: the addon's registration, its interaction,
---and the timer that fades old tags. Engine-neutral: everything goes
---through `rpf`, the public API, which the entry point hands in.
acme_tags = acme_tags or {}

---How long to wait before asking again when the portal could not answer.
acme_tags.RETRY_MS = 30000

---Holds every tag the server does not hold yet, a page at a time, so tags
---survive a restart and fade on time. (J6, #83, will hold a `hold = "server"`
---type's records for the addon; until then an addon holds what it needs.)
---If the portal cannot be asked, or does not answer, it tries again later:
---the timer is the addon's, so it stops with it.
---@param rpf rpf.Api The API.
---@param after table? Where the last page ended.
local function hold_all(rpf, after)
  ---Asks again, later, from the same page.
  ---@param why string? What went wrong, for the console.
  local function retry(why)
    print("[acme_tags] could not reclaim tags (" .. tostring(why) .. "); trying again")
    rpf.time.after(acme_tags.RETRY_MS, function()
      hold_all(rpf, after)
    end)
  end
  local asked, refused = rpf.records.query(acme_tags.TYPE, { limit = 64, after = after }, function(found, next_page, err)
    if not found then
      retry(err)
      return
    end
    local ids = {}
    for _, tag in ipairs(found or {}) do
      if not tag.held then
        ids[#ids + 1] = tag.id
      end
    end
    if #ids > 0 then
      rpf.records.hold(acme_tags.TYPE, ids)
    end
    if next_page then
      hold_all(rpf, next_page)
    end
  end)
  if not asked then
    retry(refused)
  end
end

---Deletes every held tag whose time is up.
---@param rpf rpf.Api The API.
function acme_tags.fade(rpf)
  local now = rpf.time.now()
  for _, tag in ipairs(rpf.records.list(acme_tags.TYPE, { where = { fades_at = { lt = now } } }) or {}) do
    rpf.records.delete(acme_tags.TYPE, tag.id)
  end
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
      rpf.interactions.register("acme_tags.spray", function(player, payload)
        return acme_tags.spray(rpf, player, payload)
      end)
      rpf.time.every(acme_tags.FADE_EVERY, function()
        acme_tags.fade(rpf)
      end)
      hold_all(rpf, nil)
    end,
  })
end
