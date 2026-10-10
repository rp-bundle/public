---A fake of DarkRP (K4), for the DarkRP bridge
---(`lua/bridges/darkrp/bridge.lua`) and the shared bridge conformance suite
---(`spec/support/bridge_conformance.lua`).
---
---It is the bridge's engine (`rpf_darkrp.Engine`) and the parts of Gmod and
---DarkRP behind it, shaped as DarkRP 2.7.0 (master at `5abcf7a`) answers,
---read from its source, not vendored:
---
--- - **Hooks** answer as `hook.Call` does: the first answer that is not nil
---   wins, and the gamemode's own default runs only when none answers.
---   `preempt` stands for another addon's hook answering first, since Gmod
---   gives hook order no guarantee.
--- - **Joining** (`connect`): DarkRP's `PlayerInitialSpawn` starts loading
---   the player's data (`DarkRPUnInitialized`), puts them in the default
---   team with Gmod's `SetTeam`, and the engine spawns them. The data
---   arrives later (`restore`), which sets the wallet and then the
---   `rpname`, each through `setDarkRPVar` and so `DarkRPVarChanged`, or
---   never (`fail`): starting money, `DarkRPDataRetrievalFailed`, and
---   `DarkRPUnInitialized` left set.
--- - **Money**: `addMoney` floors its amount, answers false for one it
---   cannot read and nothing otherwise, lets `playerWalletChanged` replace
---   the total, and saves only once the data is loaded. `canAfford` is false
---   while it is not.
--- - **Death**: `KillSilent` is no death of DarkRP's. `PlayerDeathThink`
---   respawns a dead player unless a hook answers.
--- - **Teams**: `changeTeam` asks `playerCanChangeTeam` whatever `force`
---   says. A team's job is its `command`.
---
---It has no characters to unload and never stops: DarkRP is the gamemode,
---so `unload`, `stop` and `start` are not things it can do. Its database
---outlives a game server's restart, as DarkRP's does.
---@class spec.DarkRPFake: spec.FrameworkDriver
---@field running boolean Whether DarkRP is the gamemode.
---@field version string? `GM.Version`.
---@field db table<string, { wallet: integer, job: string? }> DarkRP's saved data, by key (the SteamID64 on a real server), and the job a test puts that player in once loaded.
---@field players table<any, spec.DarkRPPlayer> Players in the game, by engine handle.
---@field teams { command: string, name: string }[] The jobs, by team number. 1 is the default, `citizen`.
---@field hooks table<string, function[]> The bridge's hooks, by event.
---@field preempt table<string, any[]> Events another addon's hook answers first, with what it answers.
---@field pending fun()[] What `after` put off to the next tick.
---@field starting integer `GM.Config.startingmoney`.
---@field failing table<string, string> How the next call of a name fails, by the facade's name for it.
---@field during table<string, fun()> Run inside the next call of a name, after it changed the state.
---@field logs { level: string, message: string }[] What the bridge logged.
---@field kills table<any, integer> How many times the bridge took each player out of the world.
---@field spawns table<any, integer> How many times each player spawned.
local fake = {}
fake.__index = fake

---One player as DarkRP has them.
---@class spec.DarkRPPlayer
---@field key string? Their SteamID64, once a test said whose data they have.
---@field alive boolean Whether they are spawned and alive.
---@field team integer Their team.
---@field uninitialized boolean? `DarkRPUnInitialized`: their data is not loaded.
---@field failed boolean? `DarkRPDataRetrievalFailed`.
---@field vars table<string, any> Their DarkRPVars: `money`, `rpname`.

---A fresh DarkRP, the gamemode, with nobody in the game.
---@return spec.DarkRPFake fw The fake.
function fake.new()
  return setmetatable({
    running = true,
    version = "2.7.0",
    db = {},
    players = {},
    teams = { { command = "citizen", name = "Citizen" } },
    hooks = {},
    preempt = {},
    pending = {},
    starting = 500,
    changes = {},
    failing = {},
    during = {},
    shown = {},
    logs = {},
    kills = {},
    spawns = {},
  }, fake)
end

---Runs a hook as `hook.Call` does: another addon's answer first if a test
---set one, else the bridge's hooks in order, stopping at the first answer.
---@param event string The event.
---@param ... any Its arguments.
---@return any first The first answer's first value, or nil. No hook here answers more than three.
---@return any second Its second.
---@return any third Its third.
function fake:call(event, ...)
  local preempted = self.preempt[event]
  if preempted then
    return preempted[1], preempted[2], preempted[3]
  end
  for _, fn in ipairs(self.hooks[event] or {}) do
    local first, second, third = fn(...)
    if first ~= nil then
      return first, second, third
    end
  end
  return nil
end

---Runs what the bridge put off to the next tick, as the engine does before
---anything else happens.
function fake:tick()
  while #self.pending > 0 do
    table.remove(self.pending, 1)()
  end
end

---A player as DarkRP has them; an error for one not in the game.
---@param player any The engine's handle.
---@return spec.DarkRPPlayer data Them.
function fake:player(player)
  return assert(self.players[player], "that player is not in the game")
end

---Sets a DarkRPVar, as `setDarkRPVar` does: `DarkRPVarChanged` first,
---while the var still holds its old value, and then the value.
---@param player any The engine's handle.
---@param var string The var.
---@param value any Its new value.
function fake:set_var(player, var, value)
  local data = self:player(player)
  self:call("DarkRPVarChanged", player, var, data.vars[var], value)
  data.vars[var] = value
end

---The engine spawns a player, and DarkRP's `PlayerSpawn` runs after the
---hooks.
---@param player any The engine's handle.
function fake:spawn(player)
  local data = self:player(player)
  data.alive = true
  self.spawns[player] = (self.spawns[player] or 0) + 1
  self:call("PlayerSpawn", player)
end

---The team with a job's command, made if DarkRP has none yet.
---@param command string The job's command.
---@return integer team Its number.
function fake:team(command)
  for number, job in ipairs(self.teams) do
    if job.command == command then
      return number
    end
  end
  self.teams[#self.teams + 1] = { command = command, name = command:sub(1, 1):upper() .. command:sub(2) }
  return #self.teams
end

---DarkRP's `addMoney`, through the failures a test asked for.
---@param player any The engine's handle.
---@param amount any The amount, signed.
---@return boolean? done False for an amount it cannot read; nothing otherwise.
function fake:add_money(player, amount)
  amount = tonumber(amount)
  if not amount then
    return false
  end
  amount = math.floor(amount)
  local data = self:player(player)
  local name = amount < 0 and "money.debit" or "money.credit"
  local how = self.failing[name]
  self.failing[name] = nil
  local before = data.vars.money
  -- `nil + amount` before the data is loaded, as DarkRP's own does.
  local total = before + amount
  total = self:call("playerWalletChanged", player, amount, before) or total
  if how == "unknown" then
    -- An owner's `playerWalletChanged` hook took a fee: the total is not
    -- what the amount alone gives.
    total = total - 1
  end
  self:set_var(player, "money", total)
  if not data.uninitialized and data.key then
    self.db[data.key].wallet = total
  end
  self.changes[name] = (self.changes[name] or 0) + 1
  local during = self.during[name]
  self.during[name] = nil
  if during then
    during()
  end
  if how == "throw_after" then
    error("the framework failed part way through " .. name)
  end
end

---The bridge's engine, over this fake. While DarkRP is not the gamemode,
---its functions are not there: calling one throws, as calling a nil
---method on a real server does.
---@return rpf_darkrp.Engine engine The engine.
function fake:engine()
  local fw = self
  ---DarkRP's own function, which throws while DarkRP is not running.
  ---@param fn function The function.
  ---@return function fn It, guarded.
  local function darkrp(fn)
    return function(...)
      if not fw.running then
        error("attempt to call a nil value (method of DarkRP's)")
      end
      return fn(...)
    end
  end
  return {
    hook = function(event, fn)
      fw.hooks[event] = fw.hooks[event] or {}
      table.insert(fw.hooks[event], fn)
    end,
    after = function(fn)
      fw.pending[#fw.pending + 1] = fn
    end,
    players = function()
      local out = {}
      for player in pairs(fw.players) do
        out[#out + 1] = player
      end
      return out
    end,
    valid = function(player)
      return player ~= nil and fw.players[player] ~= nil
    end,
    alive = function(player)
      return fw:player(player).alive
    end,
    kill = function(player)
      fw:player(player).alive = false
      fw.kills[player] = (fw.kills[player] or 0) + 1
    end,
    spawn = function(player)
      fw:spawn(player)
    end,
    key = function(player)
      return fw:player(player).key
    end,
    rpname = darkrp(function(player)
      return fw:player(player).vars.rpname or "SteamName"
    end),
    wallet = darkrp(function(player)
      return fw:player(player).vars.money
    end),
    loaded = darkrp(function(player)
      local data = fw:player(player)
      return data.vars.money ~= nil and not data.uninitialized
    end),
    failed = darkrp(function(player)
      return fw:player(player).failed == true
    end),
    can_afford = darkrp(function(player, amount)
      local data = fw:player(player)
      if not amount or data.uninitialized then
        return false
      end
      return math.floor(amount) >= 0 and (data.vars.money or 0) - math.ceil(amount) >= 0
    end),
    add_money = darkrp(function(player, amount)
      return fw:add_money(player, amount)
    end),
    job = darkrp(function(player)
      local job = fw.teams[fw:player(player).team]
      return job and { command = job.command, name = job.name } or nil
    end),
    running = function()
      return fw.running, fw.running and fw.version or nil
    end,
    log = function(level, message)
      fw.logs[#fw.logs + 1] = { level = level, message = message }
    end,
  }
end

---Loads the bridge's code afresh, as Gmod loading the addon does, and
---registers it over this fake through the API.
---@param api table `rpf.api`.
---@param fw spec.DarkRPFake The fake.
---@return boolean? ok What `register` answered.
---@return string? err Why not.
function fake.register(api, fw)
  local support = require("spec.support")
  local bridge = dofile(support.path("lua/bridges/darkrp/bridge.lua"))
  return bridge.register(api, fw:engine())
end

-- The driver: what the test does to DarkRP ---------------------------------

---A player's saved data: their wallet, and the job a test has them in.
---Belongs to whichever player `load`s it.
---@param key string The SteamID64 it is saved under.
---@param money table<string, integer>? Their money: `wallet`.
---@param _ table? Items, which DarkRP has none of.
---@param job { name: string, grade: integer, on_duty: boolean }? The job they are in once loaded; citizen if nil.
function fake:seed(key, money, _, job)
  self.db[key] = { wallet = (money or {}).wallet or self.starting, job = job and job.name or nil }
end

---A player joins: DarkRP starts loading their data and puts them in the
---default team, and the engine spawns them.
---@param player any The engine's handle.
function fake:connect(player)
  self.players[player] = { alive = false, team = 1, uninitialized = true, vars = {} }
  self:spawn(player)
  self:tick()
end

---DarkRP's data for a player arrives: the wallet, then the `rpname`.
---@param player any The engine's handle.
---@param key string Whose data: a seeded key.
---@param name string? Their roleplay name; none if nil.
function fake:restore(player, key, name)
  local data = self:player(player)
  local row = self.db[key] or { wallet = self.starting }
  self.db[key] = row
  data.key = key
  if row.job then
    data.team = self:team(row.job)
  end
  data.uninitialized = nil
  self:set_var(player, "money", row.wallet)
  if name then
    self:set_var(player, "rpname", name)
  end
  self:tick()
end

---DarkRP gives up loading a player's data, as its `onError` does.
---@param player any The engine's handle.
function fake:fail(player)
  local data = self:player(player)
  data.uninitialized = true
  data.failed = true
  self:set_var(player, "money", self.starting)
  self:tick()
end

---A player joins, if they have not, and DarkRP loads their data: the
---character the conformance suite loads.
---@param player any The engine's handle.
---@param key string The data's key.
---@param name string Their roleplay name.
function fake:load(player, key, name)
  if not self.players[player] then
    self:connect(player)
  end
  self:restore(player, key, name)
end

---A player leaves.
---@param player any The engine's handle.
function fake:disconnect(player)
  self.players[player] = nil
end

---The key of the data DarkRP has loaded for a player in its play: alive,
---with their data loaded.
---@param player any The engine's handle.
---@return string? key The key, or nil.
function fake:loaded(player)
  local data = self.players[player]
  if not data or not data.alive or data.uninitialized or data.vars.money == nil then
    return nil
  end
  return data.key
end

---DarkRP has no character to unload.
---@param _ any The player.
function fake:unload(_)
  error("DarkRP unloads a player's data only when they leave")
end

---DarkRP is the gamemode: it does not stop while the server runs.
function fake:stop()
  error("DarkRP is the gamemode, and does not stop")
end

---DarkRP is the gamemode: it does not start again.
function fake:start()
  error("DarkRP is the gamemode, and does not start again")
end

---A wallet, as DarkRP saved it.
---@param key string The key.
---@param account string The account: `wallet`.
---@return integer? balance The balance.
function fake:balance(key, account)
  return account == "wallet" and self.db[key] and self.db[key].wallet or nil
end

---DarkRP has no item inventory.
---@return integer count Always 0.
function fake:count()
  return 0
end

---Makes the next call of a name fail: after it changed the wallet, it
---throws, or a hook made the total something the amount does not give.
---@param name string The facade's name for the call.
---@param how "throw_after"|"unknown" How.
function fake:fail_next(name, how)
  self.failing[name] = how
end

---Runs `fn` inside the next call of a name, after it changed the wallet.
---@param name string The call.
---@param fn fun() What runs there.
function fake:inside_next(name, fn)
  self.during[name] = fn
end

---The game server restarted (a map change): the hooks the bridge's old
---code added go, and so does everyone's state in the game, which the next
---map's joins make again.
function fake:forget_listeners()
  self.hooks, self.pending, self.players = {}, {}, {}
end

---Another addon spawns a player (an admin mod's respawn).
---@param player any The engine's handle.
function fake:respawn(player)
  self:spawn(player)
  self:tick()
end

---A tick of a dead player's `PlayerDeathThink`: Gmod's own respawns them
---unless a hook answers.
---@param player any The engine's handle.
function fake:think(player)
  local data = self:player(player)
  if data.alive then
    return
  end
  if self:call("PlayerDeathThink", player) == nil then
    self:spawn(player)
  end
  self:tick()
end

---`changeTeam`: the team changes unless `playerCanChangeTeam` refuses,
---which `force` does not skip.
---@param player any The engine's handle.
---@param command string The job's command.
---@param force boolean? An admin's or DarkRP's own forced change.
---@return boolean changed True if it did.
---@return string? reason What the player is told if not.
function fake:change_team(player, command, force)
  local team = self:team(command)
  local allowed, reason = self:call("playerCanChangeTeam", player, team, force == true)
  if allowed == false then
    return false, reason
  end
  self:player(player).team = team
  return true
end

---Whether a DarkRP command would run for a player: `canChatCommand`, whose
---gamemode default refuses while their data is not loaded.
---@param player any The engine's handle.
---@param command string The command.
---@return boolean runs True if it would.
function fake:command(player, command)
  local answer = self:call("canChatCommand", player, command, "")
  if answer == nil then
    answer = not self:player(player).uninitialized
  end
  return answer and true or false
end

---A payday: `playerGetSalary`, then the salary into the wallet.
---@param player any The engine's handle.
---@param salary integer The team's salary.
---@return integer paid What was paid.
function fake:payday(player, salary)
  local _, _, amount = self:call("playerGetSalary", player, salary)
  amount = amount or salary
  if amount ~= 0 then
    self:add_money(player, amount)
  end
  return amount
end

---Whether one player hears another's voice: a hook's answer, or DarkRP's
---default, which lets the dead talk (`deadvoice`).
---@param listener any The listener.
---@param talker any The talker.
---@return boolean hears True if they do.
function fake:hears(listener, talker)
  local answer = self:call("PlayerCanHearPlayersVoice", listener, talker)
  if answer == nil then
    return true
  end
  return answer == true
end

---Asks one of DarkRP's refusal hooks (`canDemote`, `canWanted`, …) as its
---call site does.
---@param event string The hook.
---@param ... any Its arguments.
---@return boolean allowed False if a hook refused.
---@return string? message What the asker is told.
function fake:ask(event, ...)
  local answer, message = self:call(event, ...)
  return answer ~= false, message
end

---A player changes their roleplay name (`/rpname`).
---@param player any The engine's handle.
---@param name string The new name.
function fake:rename(player, name)
  self:set_var(player, "rpname", name)
  self:tick()
end

return fake
