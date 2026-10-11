-- The FiveM entry point on a client: `/note <text>` pins a note where the
-- player stands, and `/note` alone opens a dialog for it. Reading and taking
-- a note down are on the interaction key (`rpf_interact`, E by default) at a
-- note.
local rpf = exports.rpf:api() ---@type rpf.Api

---Shows the player a line: a notification, or chat where there is none.
local tell = acme_notes.teller(rpf, function(message)
  TriggerEvent("chat:addMessage", { args = { "Notes", message } })
end)

RegisterCommand("note", function(_, args)
  acme_notes.ask_pin(rpf, table.concat(args, " "), tell)
end, false)
