---acme_garden on a player's client: asking the server to sow, and telling
---the player how it went. Watering, harvesting and pulling a plant up need
---no code here: they are interactions aimed at a plant, which the core's
---interaction menu (`rpf_interact`) and a target resource offer whenever the
---player stands at one. Engine-neutral; the entry point binds the command.
acme_garden = acme_garden or {}

---Whether the answers are being listened for yet.
local listening = false

---Asks to sow a seed where the player stands.
---@param rpf rpf.Api The API.
---@param tell fun(message: string) Shows the player a line.
---@return boolean? sent True once asked.
---@return string? err Why not.
function acme_garden.ask_sow(rpf, tell)
  if not listening then
    listening = true
    rpf.events.on("interactions.result", function(result)
      if type(result.name) == "string" and result.name:sub(1, 12) == "acme_garden." then
        tell(result.ok and "Done." or tostring(result.reason))
      end
    end)
  end
  return rpf.interactions.send("acme_garden.sow", {})
end

---A way to tell the player something: a notification where the engine shows
---one, the entry point's own line (chat) where it does not.
---@param rpf rpf.Api The API.
---@param fallback fun(message: string) The entry point's way.
---@return fun(message: string) tell Shows the player a line.
function acme_garden.teller(rpf, fallback)
  return function(message)
    if not rpf.capabilities().notify or not rpf.ui.notify({ text = message, title = "Garden" }) then
      fallback(message)
    end
  end
end
