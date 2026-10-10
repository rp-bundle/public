-- The FiveM entry point on the server: the API is the `rpf` resource's export.
local rpf = exports.rpf:api() ---@type rpf.Api
assert(acme_tags.start_server(rpf))
