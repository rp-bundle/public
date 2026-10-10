-- The FiveM entry point on a client: `/spray <text>` sprays a tag.
local rpf = exports.rpf:api() ---@type rpf.Api
RegisterCommand("spray", function(_, args)
  acme_tags.ask(rpf, table.concat(args, " "), function(message)
    TriggerEvent("chat:addMessage", { args = { "Tags", message } })
  end)
end, false)
