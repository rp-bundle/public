---acme_tags on a player's client: asking the server to spray, and telling
---the player how it went. Engine-neutral; the entry point binds a command.
acme_tags = acme_tags or {}

---Whether the answer is being listened for yet.
local listening = false

---Asks to spray a tag where the player stands.
---@param rpf rpf.Api The API.
---@param text string What to spray.
---@param tell fun(message: string) Shows the player a line.
---@return boolean? sent True once asked.
---@return string? err Why not.
function acme_tags.ask(rpf, text, tell)
  if not listening then
    listening = true
    rpf.events.on("interactions.result", function(result)
      if result.name == "acme_tags.spray" then
        tell(result.ok and "Sprayed." or ("No tag: " .. tostring(result.reason)))
      end
    end)
  end
  return rpf.interactions.send("acme_tags.spray", { text = text })
end
