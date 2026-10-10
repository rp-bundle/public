-- The DarkRP bridge's Gmod entry point (K4): the engine the bridge reaches
-- (`rpf_darkrp.Engine`), built from Gmod's and DarkRP's functions, and the
-- bridge registered with RPF through the `rpf` global. Every rule is in
-- `bridge.lua`; this file only connects it to the game.
--
-- The `rpf_darkrp` addon ships this file as
-- `lua/autorun/server/rpf_darkrp.lua` and `bridge.lua` as
-- `lua/rpf_darkrp/bridge.lua`. It runs on the server only: DarkRP has no
-- character selection, so the bridge has nothing to show a client.

local darkrp = include("rpf_darkrp/bridge.lua") --[[@as rpf_darkrp]]

---The console's colour for each level, as the RPF adapter's.
---@type table<string, Color>
local COLOURS = {
  info = Color(210, 210, 210),
  warn = Color(255, 200, 80),
  error = Color(255, 90, 90),
}

---Writes a line to the server's console, as the RPF adapter writes its own.
---@param level string The level.
---@param message string The line.
local function log(level, message)
  MsgC(COLOURS[level] or COLOURS.info, "[" .. level .. "] rpf_darkrp: " .. message .. "\n")
end

---The gamemode that is DarkRP: the running one, or one it derives from.
---@return table? gamemode Its table, or nil if DarkRP is not running.
local function darkrp_gamemode()
  if type(DarkRP) ~= "table" or type(RPExtraTeams) ~= "table" then
    return nil
  end
  local gm = gmod.GetGamemode()
  while type(gm) == "table" do
    if gm.Name == "DarkRP" then
      return gm
    end
    gm = gm.BaseClass
  end
  return nil
end

---@type rpf_darkrp.Engine
local engine = {
  hook = function(event, fn)
    hook.Add(event, darkrp.HOOK, fn)
  end,
  after = function(fn)
    timer.Simple(0, fn)
  end,
  players = function()
    return player.GetAll()
  end,
  valid = function(ply)
    return IsValid(ply) and ply:IsPlayer()
  end,
  alive = function(ply)
    return ply:Alive()
  end,
  kill = function(ply)
    ply:KillSilent()
  end,
  spawn = function(ply)
    ply:Spawn()
  end,
  key = function(ply)
    local id = ply:SteamID64()
    if type(id) ~= "string" or id == "" or id == "0" then
      return nil
    end
    return id
  end,
  rpname = function(ply)
    return ply:getDarkRPVar("rpname") or ply:Nick()
  end,
  wallet = function(ply)
    return ply:getDarkRPVar("money")
  end,
  loaded = function(ply)
    -- DarkRP sets `DarkRPUnInitialized` while it loads a player's data, and
    -- leaves it set when the load failed. It has no function or hook that
    -- says so; its own `canAfford` and `canChatCommand` read the field.
    return ply:getDarkRPVar("money") ~= nil and not ply.DarkRPUnInitialized
  end,
  failed = function(ply)
    return ply.DarkRPDataRetrievalFailed == true
  end,
  can_afford = function(ply, amount)
    return ply:canAfford(amount) == true
  end,
  add_money = function(ply, amount)
    return ply:addMoney(amount)
  end,
  job = function(ply)
    local job = ply:getJobTable()
    if type(job) ~= "table" then
      return nil
    end
    return { command = job.command, name = job.name }
  end,
  running = function()
    local gm = darkrp_gamemode()
    if not gm then
      return false
    end
    return true, type(gm.Version) == "string" and gm.Version or nil
  end,
  log = log,
}

-- Once every addon and the gamemode have loaded: the RPF adapter has
-- published its API by then (it does so as it loads), and DarkRP has
-- defined its functions and jobs.
hook.Add("Initialize", darkrp.HOOK, function()
  if type(rpf) ~= "table" or type(rpf.bridge) ~= "table" then
    log("error", "RPF is not running (the rpf addon is missing, or refused to start: see its line above), so the bridge is not registered")
    return
  end
  if not engine.running() then
    log("error", "DarkRP is not the gamemode, so DarkRP's money and jobs are unavailable to RPF. Remove this addon, or run DarkRP")
  end
  local ok, err, field = darkrp.register(rpf, engine)
  if not ok then
    log("error", "RPF refused the bridge: " .. tostring(err) .. (field and (" (" .. field .. ")") or ""))
  end
end)
