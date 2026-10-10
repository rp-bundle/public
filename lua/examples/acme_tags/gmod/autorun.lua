-- The Gmod entry point, shipped as `lua/autorun/acme_tags.lua` with the
-- three files under `lua/acme_tags/`. Gmod runs autorun files in name order,
-- so `rpf` (the API the RPF addon publishes as a global) is read only once
-- every addon has loaded: at `Initialize` on the server, by when the RPF
-- adapter has published the API (it does so as it loads, before it waits
-- for its convars), and when the command runs on a client.
if SERVER then
  AddCSLuaFile()
  AddCSLuaFile("acme_tags/manifest.lua")
  AddCSLuaFile("acme_tags/client.lua")
  include("acme_tags/manifest.lua")
  include("acme_tags/server.lua")
  hook.Add("Initialize", "acme_tags", function()
    assert(acme_tags.start_server(rpf))
  end)
else
  include("acme_tags/manifest.lua")
  include("acme_tags/client.lua")
  ---Shows the player a line: a notification, or chat where there is none.
  ---@param message string The line.
  local function tell(message)
    acme_tags.teller(rpf, function(line)
      chat.AddText(line)
    end)(message)
  end
  -- In the console: `spray <text>` sprays a tag, `tags` picks one of the
  -- player's own from a menu to scrub, and `scrub <n>` scrubs one `tags`
  -- listed where there is no menu.
  concommand.Add("spray", function(_, _, args)
    acme_tags.ask(rpf, table.concat(args, " "), tell)
  end)
  concommand.Add("tags", function()
    acme_tags.pick_mine(rpf, tell)
  end)
  concommand.Add("scrub", function(_, _, args)
    acme_tags.ask_scrub(rpf, tonumber(args[1]), tell)
  end)
end
