-- The Gmod entry point, shipped as `lua/autorun/rpf_inventory.lua` with the
-- addon's files under `lua/rpf_inventory/` (`derma.lua` beside the three
-- engine-neutral ones). Gmod runs autorun files in name order, so `rpf`
-- (the API the RPF addon publishes as a global) is read only once every
-- addon has loaded: at `Initialize` on the server, and when the command
-- runs on a client.
if SERVER then
  AddCSLuaFile()
  AddCSLuaFile("rpf_inventory/manifest.lua")
  AddCSLuaFile("rpf_inventory/client.lua")
  AddCSLuaFile("rpf_inventory/derma.lua")
  include("rpf_inventory/manifest.lua")
  include("rpf_inventory/server.lua")
  hook.Add("Initialize", "rpf_inventory", function()
    assert(rpf_inventory.start_server(rpf))
  end)
else
  include("rpf_inventory/manifest.lua")
  include("rpf_inventory/client.lua")
  include("rpf_inventory/derma.lua")
  -- `rpf_inventory` in the console, or bound to a key
  -- (`bind i rpf_inventory`), opens the inventory.
  concommand.Add("rpf_inventory", function()
    rpf_inventory.open_derma(rpf)
  end)
end
