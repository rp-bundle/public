-- The FiveM entry point on a client: `/sow` sows a seed where the player
-- stands. Watering, harvesting and pulling up are on the interaction key
-- (`rpf_interact`, E by default) when standing at a plant.
local rpf = exports.rpf:api() ---@type rpf.Api

---Shows the player a line: a notification, or chat where there is none.
local tell = acme_garden.teller(rpf, function(message)
  TriggerEvent("chat:addMessage", { args = { "Garden", message } })
end)

RegisterCommand("sow", function()
  acme_garden.ask_sow(rpf, tell)
end, false)
