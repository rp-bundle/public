---acme_garden on the game server: the addon's registration, its
---interactions, and the tick that grows and dries plants. Engine-neutral:
---everything goes through `rpf`, the public API, which the entry point hands
---in.
---
---**Time is kept in the record, not in a timer.** A timer ends with the
---process; a plant's `ticked_at` does not. Every tick counts what passed
---since then with `rpf.time.elapsed`, bounded by `MAX_CATCH_UP_MS`, and
---stores the moment it counted to. So a plant grows only while a server
---holds it (active time, not wall time), a restart costs it nothing but
---the bound, and a server that was down for a week does not grow a week
---in one tick.
acme_garden = acme_garden or {}

---How much a plant dries each tick, of 100: dry after 50 ticks unwatered,
---which leaves a grown plant 20 ticks to be harvested.
acme_garden.THIRST = 2

---How close to a plant a player must stand to tend it, in metres.
acme_garden.REACH_METRES = 2

---A plant's fields after some ticks of growth: pure, so it is the same on
---every engine and in every test. Each tick it drinks `THIRST` and grows
---one, while it has water; once dry it withers, grown or not, and a
---withered plant changes no more.
---@param fields table The plant's fields, as `rpf.records` gives them.
---@param ticks integer Whole ticks to grow.
---@return table? patch What changed, or nil if nothing did.
function acme_garden.grow(fields, ticks)
  if fields.stage == "withered" or ticks <= 0 then
    return nil
  end
  local water, grown = fields.water or 100, fields.grown_ticks or 0
  for _ = 1, ticks do
    if water <= 0 then
      break
    end
    water = math.max(0, water - acme_garden.THIRST)
    grown = grown + 1
  end
  local stage = "seed"
  if water <= 0 then
    stage = "withered"
  elseif grown >= acme_garden.GROWN_TICKS then
    stage = "grown"
  elseif grown >= acme_garden.SPROUT_TICKS then
    stage = "sprout"
  end
  return { water = water, grown_ticks = grown, stage = stage }
end

---Grows every plant this server holds by the time that passed since it was
---last counted. A plant it cannot write now (a staff edit landed first, so
---its revision moved on) is left for the next tick, which reads it again.
---@param rpf rpf.Api The API.
function acme_garden.tick(rpf)
  local plants, err = rpf.records.list(acme_garden.TYPE)
  if not plants then
    print("[acme_garden] could not list the plants (" .. tostring(err) .. ")")
    return
  end
  for _, plant in ipairs(plants) do
    local fields = plant.fields
    local spent, now = rpf.time.elapsed(fields.ticked_at, acme_garden.MAX_CATCH_UP_MS)
    local ticks = spent and math.floor(spent / acme_garden.TICK_MS) or 0
    if ticks > 0 and type(now) == "number" then
      local patch = acme_garden.grow(fields, ticks) or {}
      -- What was not a whole tick is kept for the next one.
      patch.ticked_at = now - (spent - ticks * acme_garden.TICK_MS)
      local done, why = rpf.records.update(acme_garden.TYPE, plant.id, patch, { revision = plant.revision })
      if not done and why ~= "stale" then
        print("[acme_garden] could not grow " .. plant.id .. " (" .. tostring(why) .. ")")
      end
    end
  end
end

---Sows a seed where the player stands. The payload is whatever their client
---sent, and nothing in it is used: where is the server's to say.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The player who asked.
---@return boolean ok Whether a seed was sown.
---@return string? reason Why not, for the player.
function acme_garden.sow(rpf, player)
  local mine, err = rpf.records.list(acme_garden.TYPE, { owner = { kind = "player", id = player.player_id } })
  if not mine then
    return false, "The garden is closed now (" .. tostring(err) .. ")."
  end
  if #mine >= acme_garden.PER_PLAYER then
    return false, "You have as many plants as you may tend."
  end
  local spot, where = rpf.world.position(player.handle)
  if not spot then
    return false, "You cannot sow here (" .. tostring(where) .. ")."
  end
  local now = rpf.time.now()
  local plant, why = rpf.records.create(acme_garden.TYPE, {
    spot = spot,
    bucket = rpf.world.bucket(player.handle) or 0,
    -- Only on the map it was sown on; none leaves it on every map.
    map = rpf.world.map(),
    planted_at = now,
    ticked_at = now,
  }, { owner = { kind = "player", id = player.player_id } })
  if not plant then
    return false, "The soil would not take it (" .. tostring(why) .. ")."
  end
  return true
end

---Whether a plant is the player's own.
---@param player rpf.PlayerView The player.
---@param record rpf.Record The plant.
---@return boolean mine True if they sowed it.
local function owns(player, record)
  return record.owner ~= nil and record.owner.kind == "player" and record.owner.id == player.player_id
end

---Waters a plant the player stands at: anyone may, unless it has withered.
---@param rpf rpf.Api The API.
---@param target table The plant the rules resolved: `{ type, id, record, position, distance }`.
---@return boolean ok Whether it was watered.
---@return string? reason Why not.
function acme_garden.water(rpf, target)
  local plant = target.record
  if plant.fields.stage == "withered" then
    return false, "It is past saving."
  end
  local done, why = rpf.records.update(acme_garden.TYPE, plant.id, { water = 100 }, { revision = plant.revision })
  if not done then
    return false, "The water ran off (" .. tostring(why) .. ")."
  end
  return true
end

---Harvests the player's own grown plant: it comes out of the ground. A
---harvest that paid out an item would go through an exchange
---(`rpf.api.commerce`, J5), which gives the item and makes this deletion as
---one journaled intent, once per op id; `acme_shop` shows one.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The player who asked.
---@param target table The plant the rules resolved.
---@return boolean ok Whether it was harvested.
---@return string? reason Why not.
function acme_garden.harvest(rpf, player, target)
  local plant = target.record
  if not owns(player, plant) then
    return false, "That is someone else's to harvest."
  end
  if plant.fields.stage ~= "grown" then
    return false, "It is not ready."
  end
  local done, why = rpf.records.delete(acme_garden.TYPE, plant.id, { revision = plant.revision })
  if not done then
    return false, "It would not come up (" .. tostring(why) .. ")."
  end
  return true
end

---Pulls up the player's own plant, whatever its stage: destruction.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The player who asked.
---@param target table The plant the rules resolved.
---@return boolean ok Whether it was pulled up.
---@return string? reason Why not.
function acme_garden.uproot(rpf, player, target)
  local plant = target.record
  if not owns(player, plant) then
    return false, "That is someone else's plant."
  end
  local done, why = rpf.records.delete(acme_garden.TYPE, plant.id, { revision = plant.revision })
  if not done then
    return false, "It would not come up (" .. tostring(why) .. ")."
  end
  return true
end

---Registers the addon. It runs once staff install it in the portal, and
---everything `start` sets up is taken down when it stops. It holds nothing
---itself: the type's `hold = "server"` has RPF hold every plant, and place
---it, whether or not this code is running.
---@param rpf rpf.Api The API.
---@return boolean? ok True once registered.
---@return table? refusal Why not.
function acme_garden.start_server(rpf)
  return rpf.addons.register(acme_garden.MANIFEST, {
    start = function()
      assert(rpf.interactions.register("acme_garden.sow", function(player)
        return acme_garden.sow(rpf, player)
      end))
      local aimed = {
        ["acme_garden.water"] = { label = "Water the plant", run = function(_, target)
          return acme_garden.water(rpf, target)
        end },
        ["acme_garden.harvest"] = { label = "Harvest", run = function(player, target)
          return acme_garden.harvest(rpf, player, target)
        end },
        ["acme_garden.uproot"] = { label = "Pull it up", run = function(player, target)
          return acme_garden.uproot(rpf, player, target)
        end },
      }
      for name, interaction in pairs(aimed) do
        -- A refusal here is a bug in this file; throwing leaves the addon
        -- `failed`, with the reason in the console.
        assert(rpf.interactions.register(name, function(player, _, target)
          return interaction.run(player, target)
        end, { target = acme_garden.TYPE, label = interaction.label, distance = acme_garden.REACH_METRES }))
      end
      assert(rpf.time.every(acme_garden.TICK_MS, function()
        acme_garden.tick(rpf)
      end))
    end,
  })
end
