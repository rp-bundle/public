---The Gmod adapter's entry point, run by Gmod on both sides at start.
---
---The addon ships this file as `lua/autorun/rpf.lua`. It only picks the
---side: everything else is in `server.lua` and `client.lua`, which the
---addon ships under `lua/rpf/platform/gmod/` (see `load.lua`). A client
---has the client's files only if the server sent them, which a server that
---refused to start does not, so a client without them starts nothing.
if SERVER then
  AddCSLuaFile()
  include("rpf/platform/gmod/server.lua")
elseif file.Exists("rpf/platform/gmod/client.lua", "LUA") then
  include("rpf/platform/gmod/client.lua")
end
