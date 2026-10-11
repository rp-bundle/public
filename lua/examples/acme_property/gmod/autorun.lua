-- The Gmod entry point, shipped as `lua/autorun/server/acme_property.lua`
-- with the two files under `lua/acme_property/`. Server only: the addon has
-- no client script of its own, since the lot and the doors are offered by
-- the core's interaction menu (`rpf_interact`) and the offer is `rpf.ui`'s,
-- opened from the server. Gmod runs autorun files in name order, so `rpf`
-- (the API the RPF addon publishes as a global) is read at `Initialize`, by
-- when the RPF adapter has published it.
include("acme_property/manifest.lua")
include("acme_property/server.lua")
hook.Add("Initialize", "acme_property", function()
  assert(acme_property.start_server(rpf))
end)
