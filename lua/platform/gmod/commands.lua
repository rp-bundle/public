---The commands players run (`platform.on_command`), the Gmod way: a console
---command and a chat line.
---
---A command is reachable two ways, and both end in the same handler:
---
--- - **The console**, `rpflink <code>`, through `concommand.Add`. It is the
---   way that never touches chat, so nothing else on the server (a chat
---   logger, another addon's `PlayerSay` hook) ever sees what was typed, and
---   it is registered unlogged (`FCVAR_UNLOGGED`).
--- - **Chat**, `/rpflink <code>`, through `PlayerSay`. The line is dropped
---   (the hook answers `""`), so other players never read it and the engine
---   never says it. Another addon's hook may still run before this one, which
---   is why the console is the safe way to type a credential.
---
---The console of the server itself runs no command: the handlers act for a
---player. What was typed is never logged here, and a handler that fails is
---logged by name and message only.
---@class rpf.gmod.Commands
---@field PREFIX string What a chat line starts with to be a command.
local commands = {}

commands.PREFIX = "/"

local shared = include("rpf/platform/gmod/shared.lua") --[[@as rpf.gmod.Shared]]

---The registered handlers, by command name.
---@type table<string, fun(player: Player, args: string[])>
local handlers = {}

---Splits what was typed after a command's name into its words.
---@param text string The rest of the line.
---@return string[] words The words, in order.
local function words_of(text)
  local words = {}
  for word in string.gmatch(text, "%S+") do
    words[#words + 1] = word
  end
  return words
end

---Runs a handler for a player, and holds it to the platform's promise: a
---handler that raises is logged by name and message, never by what was typed.
---@param name string The command.
---@param player Player The player who ran it.
---@param args string[] The words after the name.
local function run(name, player, args)
  local handler = handlers[name]
  if not handler then
    return
  end
  local ok, err = pcall(handler, player, args)
  if not ok then
    shared.log("error", "rpf: the " .. name .. " command failed: " .. tostring(err))
  end
end

---The console command's callback: a player's run of it, with the words as
---the engine split them. The server console (no player) runs nothing.
---@param name string The command.
---@param player any The player, or an invalid one for the server console.
---@param args string[] The words after the name.
local function console(name, player, args)
  if not IsValid(player) or not player:IsPlayer() then
    return
  end
  local copy = {}
  for i, word in ipairs(args) do
    copy[i] = tostring(word)
  end
  run(name, player, copy)
end

---Registers a command players run (`platform.on_command`).
---@param name string The command's name, without a prefix.
---@param handler fun(player: Player, args: string[]) Called for each run.
function commands.on_command(name, handler)
  local known = handlers[name] ~= nil
  handlers[name] = handler
  if not known then
    concommand.Add(name, function(player, _, args)
      console(name, player, args)
    end, nil, nil, FCVAR_UNLOGGED)
  end
end

---`PlayerSay`'s answer for a line: `""` when it is a registered command, so
---it is run and never said, and nil for any other line.
---@param player any The player who spoke.
---@param text any What they said.
---@return string? answer `""` for a command's line, nil otherwise.
function commands.say(player, text)
  if type(text) ~= "string" or text:sub(1, #commands.PREFIX) ~= commands.PREFIX then
    return nil
  end
  local name, rest = string.match(text, "^" .. commands.PREFIX .. "(%S+)%s*(.*)$")
  name = name and string.lower(name)
  if not name or not handlers[name] then
    return nil
  end
  run(name, player, words_of(rest))
  return ""
end

return commands
