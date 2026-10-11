---Loads the core into Gmod's shared Lua state, and sends the client's half to
---players.
---
---Gmod runs every addon in one Lua state per side, and finds a file by its
---path under some addon's `lua/` directory. The addon puts this repository's
---`lua/core/` at `lua/rpf/core/` and `lua/platform/gmod/` at
---`lua/rpf/platform/gmod/`, so every path here starts `rpf/` (`ROOT`), and
---`lua/platform/gmod/autorun.lua` at `lua/autorun/rpf.lua`, which Gmod runs on
---both sides at start (see `lua/platform/README.md`).
---
---The core is loaded exactly as its README says an adapter loads it:
---`init.lua`, then each file its side declares in `rpf.files`, in order,
---with `include`, which runs a file and keeps its return value. Nothing calls
---`require`, which on Gmod loads only binary modules.
---@class rpf.gmod.Load
---@field ROOT string Where the addon's files live under `lua/`.
---@field CLIENT_FILES string[] The adapter's own files a player's client runs, relative to `ROOT`.
local load = {}

load.ROOT = "rpf/"

load.CLIENT_FILES = {
  "platform/gmod/load.lua",
  "platform/gmod/shared.lua",
  "platform/gmod/messages.lua",
  "platform/gmod/addon_ui.lua",
  "platform/gmod/images.lua",
  "platform/gmod/client.lua",
  "platform/gmod/ui.lua",
}

---Loads one side of the core and returns its internal table.
---
---The table is returned rather than read from the global later, because
---publishing the public API replaces the `rpf` global, and the adapter keeps
---the internal table for the engine hooks it wires.
---@param side "server"|"client" Which side's files.
---@return rpf core The core's internal table.
function load.core(side)
  include(load.ROOT .. "core/init.lua")
  local core = rpf --[[@as rpf]]
  for _, file in ipairs(core.files[side]) do
    include(load.ROOT .. "core/" .. file)
  end
  return core
end

---Marks every file a player's client runs for download: the client's half of
---the core and the adapter's client files. Run on the server.
---@param core rpf The core, for its list of client files.
function load.send_client_files(core)
  AddCSLuaFile(load.ROOT .. "core/init.lua")
  for _, file in ipairs(core.files.client) do
    AddCSLuaFile(load.ROOT .. "core/" .. file)
  end
  for _, file in ipairs(load.CLIENT_FILES) do
    AddCSLuaFile(load.ROOT .. file)
  end
end

return load
