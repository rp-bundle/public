-- The Gmod entry point, shipped as `lua/autorun/acme_garden.lua` with the
-- three files under `lua/acme_garden/`. Gmod runs autorun files in name
-- order, so `rpf` (the API the RPF addon publishes as a global) is read only
-- once every addon has loaded: at `Initialize` on the server, and when the
-- command runs on a client.
if SERVER then
  AddCSLuaFile()
  AddCSLuaFile("acme_garden/manifest.lua")
  AddCSLuaFile("acme_garden/client.lua")
  include("acme_garden/manifest.lua")
  include("acme_garden/server.lua")
  hook.Add("Initialize", "acme_garden", function()
    assert(acme_garden.start_server(rpf))
  end)
else
  include("acme_garden/manifest.lua")
  include("acme_garden/client.lua")
  ---Shows the player a line: a notification, or chat where there is none.
  ---@param message string The line.
  local function tell(message)
    acme_garden.teller(rpf, function(line)
      chat.AddText(line)
    end)(message)
  end
  -- In the console: `sow` sows a seed where the player stands. Watering,
  -- harvesting and pulling up are on `rpf_interact` at a plant.
  concommand.Add("sow", function()
    acme_garden.ask_sow(rpf, tell)
  end)
end
