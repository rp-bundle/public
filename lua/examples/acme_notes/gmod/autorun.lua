-- The Gmod entry point, shipped as `lua/autorun/acme_notes.lua` with the
-- three files under `lua/acme_notes/`. Gmod runs autorun files in name
-- order, so `rpf` (the API the RPF addon publishes as a global) is read only
-- once every addon has loaded: at `Initialize` on the server, and when the
-- command runs on a client.
if SERVER then
  AddCSLuaFile()
  AddCSLuaFile("acme_notes/manifest.lua")
  AddCSLuaFile("acme_notes/client.lua")
  include("acme_notes/manifest.lua")
  include("acme_notes/server.lua")
  hook.Add("Initialize", "acme_notes", function()
    assert(acme_notes.start_server(rpf))
  end)
else
  include("acme_notes/manifest.lua")
  include("acme_notes/client.lua")
  ---Shows the player a line: a notification, or chat where there is none.
  ---@param message string The line.
  local function tell(message)
    acme_notes.teller(rpf, function(line)
      chat.AddText(line)
    end)(message)
  end
  -- In the console: `note <text>` pins a note where the player stands, and
  -- `note` alone opens a dialog for it. Reading and taking a note down are
  -- on `rpf_interact` at a note.
  concommand.Add("note", function(_, _, args)
    acme_notes.ask_pin(rpf, table.concat(args, " "), tell)
  end)
end
