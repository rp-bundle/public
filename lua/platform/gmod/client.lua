---The Gmod adapter's player-client side: the client platform, the login
---form and the character select screen.
---
---It loads the client's half of the core, publishes the public API as the
---`rpf` global, and starts the core once the player is in the game
---(`InitPostEntity`). Starting is what sends the server `rpf:client_ready`,
---and by then the server has handed the player to its core
---(`PlayerInitialSpawn` runs first), and `HTTP` works.
---
---The password goes from the form straight to the portal over this client's
---`HTTP` (`rpf.auth`), and never over `net` to the game server. That is a
---mitigation, not a guarantee: the server sends this client its Lua, so a
---server owner can change what the form does, which is why every form where
---a player chooses a password shows the core's `PASSWORD_REUSE_WARNING`. The
---join nonce reaches the client over `net`, from the server (C6).
---@class rpf.gmod.Client
local client = {}

local load = include("rpf/platform/gmod/load.lua") --[[@as rpf.gmod.Load]]
local shared = include("rpf/platform/gmod/shared.lua") --[[@as rpf.gmod.Shared]]
local messages = include("rpf/platform/gmod/messages.lua") --[[@as rpf.gmod.Messages]]

local core = load.core("client")

---The player client's platform: every member of `rpf.ClientPlatform`.
---@type rpf.ClientPlatform
local platform = {
  engine = "gmod",
  http_request = shared.http_request,
  kv_get = shared.kv_get,
  kv_set = shared.kv_set,
  now = shared.now,
  after = shared.after,
  to_server = messages.to_server,
  on_server = messages.on_server,
  log = shared.log,
  expose = shared.expose,
}

core.publish(platform)

-- The screens listen before the core starts, so they hear its first event.
local ui = include("rpf/platform/gmod/ui.lua") --[[@as rpf.gmod.Ui]]
ui.install(core)

hook.Add("InitPostEntity", "rpf", function()
  core.start_client(platform)
end)

return client
