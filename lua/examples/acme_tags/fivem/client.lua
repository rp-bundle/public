-- The FiveM entry point on a client: `/spray <text>` sprays a tag, `/tags`
-- lists the player's own, and `/scrub <n>` scrubs one of those.
local rpf = exports.rpf:api() ---@type rpf.Api

---Shows the player a line in chat.
---@param message string The line.
local function tell(message)
  TriggerEvent("chat:addMessage", { args = { "Tags", message } })
end

RegisterCommand("spray", function(_, args)
  acme_tags.ask(rpf, table.concat(args, " "), tell)
end, false)
RegisterCommand("tags", function()
  acme_tags.show_mine(rpf, tell)
end, false)
RegisterCommand("scrub", function(_, args)
  acme_tags.ask_scrub(rpf, tonumber(args[1]), tell)
end, false)
