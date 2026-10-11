-- The Gmod entry point, shipped as `lua/autorun/server/acme_shop.lua` with the
-- two files under `lua/acme_shop/`. Server only: the shop has no client
-- script of its own, since the counter is offered by the core's interaction
-- menu (`rpf_interact`) and its menu and dialog are `rpf.ui`'s, opened from
-- the server. Gmod runs autorun files in name order, so `rpf` (the API the
-- RPF addon publishes as a global) is read at `Initialize`, by when the RPF
-- adapter has published it.
include("acme_shop/manifest.lua")
include("acme_shop/server.lua")
hook.Add("Initialize", "acme_shop", function()
  assert(acme_shop.start_server(rpf))
end)
