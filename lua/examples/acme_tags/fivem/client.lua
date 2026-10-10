-- The FiveM entry point on a client: `/spray <text>` sprays a tag, `/tags`
-- picks one of the player's own from a menu to scrub, and `/scrub <n>`
-- scrubs one `/tags` listed where there is no menu.
local rpf = exports.rpf:api() ---@type rpf.Api

---Shows the player a line: a notification, or chat where there is none.
local tell = acme_tags.teller(rpf, function(message)
  TriggerEvent("chat:addMessage", { args = { "Tags", message } })
end)

RegisterCommand("spray", function(_, args)
  acme_tags.ask(rpf, table.concat(args, " "), tell)
end, false)
RegisterCommand("tags", function()
  acme_tags.pick_mine(rpf, tell)
end, false)
RegisterCommand("scrub", function(_, args)
  acme_tags.ask_scrub(rpf, tonumber(args[1]), tell)
end, false)
