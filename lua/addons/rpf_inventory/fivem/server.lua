-- The FiveM entry point on the server: the API is the `rpf` resource's export.
local rpf = exports.rpf:api() ---@type rpf.Api
assert(rpf_inventory.start_server(rpf))
