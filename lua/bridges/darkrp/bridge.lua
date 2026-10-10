---The DarkRP bridge (K4, #94): RPF beside DarkRP on Gmod, in the companion
---profile. DarkRP owns money and jobs, and has no characters and no item
---inventory; this bridge reaches it only through its public functions and
---hooks, by the rules of `lua/bridges/README.md`, and registers with RPF
---through `rpf.bridge`.
---
---The engine is passed in (`rpf_darkrp.Engine`), never reached as globals,
---so this file runs unchanged under busted against a fake of DarkRP
---(`spec/support/darkrp_fake.lua`), on every platform the conformance
---harness boots it on. `gmod/autorun.lua` builds the real engine from Gmod's
---and DarkRP's functions and calls `register`.
---
--- - **One implicit character per player.** DarkRP sets a player up on
---   join, so there is no selection: the character is the player's DarkRP
---   data, keyed by their SteamID64, reported once DarkRP has loaded it and
---   the player has reached `character_select`. Only DarkRP taking the
---   load back unloads it while they are connected; the core forgets it
---   when they leave.
--- - **The gate is a hold.** There is no character load to defer, so every
---   player RPF does not have `active` is kept out of DarkRP's play on the
---   server: unspawned, with team changes, DarkRP's commands, votes, salary
---   and voice refused, and other players' commands that name them refused
---   too.
---   It holds from registration on whatever the profile, and DarkRP's own
---   spawn puts a player in once RPF has them `active`.
--- - **Classified by when.** `addMoney` answers nothing, and a
---   `playerWalletChanged` hook may replace the total it sets, so the wallet
---   is read before and after: moved by exactly the amount is `true`,
---   anything else `unknown`. Nothing is retried.
---@class rpf_darkrp
---@field NAME string The bridge's name, in RPF's log.
---@field VERSION string The bridge's own version.
---@field TESTED_WITH string[] The DarkRP versions it was tested against.
---@field ACCOUNT string The one account it lists: DarkRP's wallet.
---@field HOOK string The identifier every Gmod and DarkRP hook it adds goes under.
---@field SWEEP_MS integer How often held players are checked, and players choosing are looked at again.
---@field REFUSED string What a held player is told when DarkRP refuses them something.
---@field ABSENT string What another player is told when their command names a held player.
local darkrp = {}

darkrp.NAME = "darkrp"
darkrp.VERSION = "1.0.0"
darkrp.TESTED_WITH = { "2.7" }
darkrp.ACCOUNT = "wallet"
darkrp.HOOK = "rpf_darkrp"
darkrp.SWEEP_MS = 1000
darkrp.REFUSED = "Log in first."
darkrp.ABSENT = "That player is not playing yet."

---The most bytes of a character's name RPF takes (`rpf.bridge.MAX_NAME_BYTES`).
local MAX_NAME_BYTES = 128

---What the bridge reaches of Gmod and DarkRP. On Gmod, `gmod/autorun.lua`
---builds it from the engine's and DarkRP's functions; under busted, the
---fake (`spec/support/darkrp_fake.lua`) is it. Every `player` is the
---engine's handle, as RPF has it.
---@class rpf_darkrp.Engine
---@field hook fun(event: string, fn: function) Adds a Gmod or DarkRP hook (`hook.Add`, under `rpf_darkrp.HOOK`). Its first answer that is not nil is the answer, as `hook.Call` takes it.
---@field after fun(fn: fun()) Runs a function on the next tick (`timer.Simple(0, …)`).
---@field players fun(): any[] Every player in the game (`player.GetAll`).
---@field valid fun(player: any): boolean Whether a hook's argument is a player still in the game (`IsValid`, `IsPlayer`): never the server console.
---@field alive fun(player: any): boolean Whether the player is spawned and alive (`Alive`).
---@field kill fun(player: any) Takes the player out of the world without a death of DarkRP's (`KillSilent`): no drops, no demotion.
---@field spawn fun(player: any) Spawns the player (`Spawn`), through DarkRP's own `PlayerSpawn`: their team's model and loadout.
---@field key fun(player: any): string? The player's SteamID64, which DarkRP keys their data by; nil for none.
---@field rpname fun(player: any): any The player's roleplay name (`getDarkRPVar("rpname")`, or `Nick`).
---@field wallet fun(player: any): any The player's wallet (`getDarkRPVar("money")`): nil until DarkRP has set it.
---@field loaded fun(player: any): boolean Whether DarkRP has loaded the player's data: the wallet set, and `DarkRPUnInitialized` clear.
---@field failed fun(player: any): boolean Whether DarkRP gave up loading the player's data (`DarkRPDataRetrievalFailed`).
---@field can_afford fun(player: any, amount: integer): boolean `canAfford`.
---@field add_money fun(player: any, amount: integer): any `addMoney`, which answers `false` for an amount it cannot read, and nothing otherwise.
---@field job fun(player: any): { command: string, name: string }? The player's team's job (`getJobTable`), or nil for a team that is none.
---@field running fun(): boolean, string? Whether DarkRP is the gamemode, and its version.
---@field log fun(level: string, message: string) Writes a line to the server's console.

---Cuts a name to at most `MAX_NAME_BYTES` bytes without splitting a
---UTF-8 sequence.
---@param name string The name.
---@return string name The name, cut.
local function clip(name)
  if #name <= MAX_NAME_BYTES then
    return name
  end
  local cut = MAX_NAME_BYTES
  -- Step back over continuation bytes to the start of the sequence the
  -- cut fell in, and leave that sequence out.
  while cut > 0 and name:byte(cut + 1) >= 0x80 and name:byte(cut + 1) < 0xC0 do
    cut = cut - 1
  end
  return name:sub(1, cut)
end

---The name DarkRP shows for a player: their roleplay name.
---@param rpname any What `rpname` read.
---@return string name The name, or `Unnamed` when it has none.
local function name_of(rpname)
  local name = type(rpname) == "string" and rpname:gsub("^%s+", ""):gsub("%s+$", "") or ""
  if name == "" then
    return "Unnamed"
  end
  return clip(name)
end

---Registers the DarkRP bridge with RPF: holds every player RPF does not
---have `active` out of DarkRP's play, follows DarkRP's data loads, and
---offers RPF the bridge. Called once, when Gmod has loaded every addon and
---the gamemode.
---@param api rpf.Api `rpf.api`: the `rpf` global on Gmod.
---@param fx rpf_darkrp.Engine The engine.
---@return boolean? ok What `rpf.bridge.register` answered.
---@return string? err Why not.
---@return string? field For `invalid`, which field.
function darkrp.register(api, fx)
  local bridge = api.bridge

  ---Whether RPF activated the bridge, on a server where DarkRP is the
  ---gamemode: the server's profile is companion. Until then no character
  ---is reported, though the hold holds.
  local active = false

  ---Players the bridge took out of the world, whom DarkRP's spawn puts back
  ---once RPF has them `active`.
  ---@type table<any, true>
  local held = {}

  ---Players whose failed data load was logged, so it is said once a
  ---connection.
  ---@type table<any, true>
  local said = {}

  ---Players RPF has `active`, kept from the lifecycle's moves. A set, since
  ---some hooks ask it for every pair of players many times a second
  ---(`PlayerCanHearPlayersVoice`).
  ---@type table<any, true>
  local in_play = {}
  for _, player in ipairs(api.players.list()) do
    if player.state == "active" then
      in_play[player.handle] = true
    end
  end

  ---Whether RPF has a player in play: logged in and `active`. Everyone
  ---else, a player RPF does not know included, is held.
  ---@param handle any The player.
  ---@return boolean playing True if they are.
  local function playing(handle)
    return in_play[handle] == true
  end

  ---Whether a hook's player is one the hold refuses: a player in the game
  ---who is not playing. The server console, which DarkRP's commands also
  ---pass, never is.
  ---@param handle any The hook's argument.
  ---@return boolean refused True if it is.
  local function refused(handle)
    return fx.valid(handle) and not playing(handle)
  end

  ---Takes a held player out of the world, if they are in it. One leaving
  ---is left alone.
  ---@param handle any The player.
  local function hold(handle)
    if not fx.valid(handle) or playing(handle) then
      return
    end
    local player = api.players.get(handle)
    if player and player.state == "dropping" then
      return
    end
    if fx.alive(handle) then
      held[handle] = true
      fx.kill(handle)
    end
  end

  ---The character DarkRP has for a player: their data, once it is loaded.
  ---@param handle any The player.
  ---@return rpf.BridgeCharacter? character Nil until DarkRP has loaded it.
  local function character(handle)
    if not fx.loaded(handle) then
      return nil
    end
    local key = fx.key(handle)
    if type(key) ~= "string" or key == "" then
      return nil
    end
    return { key = key, name = name_of(fx.rpname(handle)) }
  end

  ---Tells RPF a player's character is loaded, or renamed.
  ---@param handle any The player.
  ---@param loaded rpf.BridgeCharacter The character.
  local function report(handle, loaded)
    local ok, err = bridge.character_loaded(handle, loaded)
    if not ok and err ~= "superseded" then
      fx.log("warn", "RPF did not take " .. tostring(handle) .. "'s character: " .. tostring(err))
    end
  end

  ---Looks at a player's DarkRP data on any cue: reports it for a player
  ---choosing, and again for one playing whose roleplay name changed, and
  ---takes one playing back to `character_select` (and so the hold) if
  ---DarkRP no longer has it loaded. Says once a connection that DarkRP
  ---could not load it.
  ---@param handle any The player, as the cue gave it.
  local function observe(handle)
    if not active or not fx.valid(handle) then
      return
    end
    local player = api.players.get(handle)
    local state = player and player.state
    if state ~= "character_select" and state ~= "active" then
      return
    end
    local loaded = character(handle)
    if not loaded then
      if fx.failed(handle) and not said[handle] then
        said[handle] = true
        fx.log(
          "error",
          "DarkRP could not load "
            .. tostring(handle)
            .. "'s data, so they stay out of play: DarkRP itself saves nothing for them until they rejoin. Check DarkRP's"
            .. " database connection"
        )
      end
      -- DarkRP took back what it had loaded (a new player's first save
      -- failed after their wallet was set): what they play with now is
      -- money DarkRP will not keep.
      if state == "active" then
        local ok, err = bridge.character_unloaded(handle)
        if not ok then
          fx.log("warn", "RPF did not take " .. tostring(handle) .. "'s character unloading: " .. tostring(err))
        end
      end
      return
    end
    if state == "active" then
      local current = api.characters.current(handle)
      if current and current.key == loaded.key and current.name == loaded.name then
        return
      end
    end
    report(handle, loaded)
  end

  ---Holds every player who is not playing, and looks again at every player
  ---choosing: what a hook another addon answered first kept from the
  ---bridge.
  local function sweep()
    for _, handle in ipairs(fx.players()) do
      hold(handle)
    end
    if active then
      for _, player in ipairs(api.players.list()) do
        if player.state == "character_select" then
          observe(player.handle)
        end
      end
    end
  end

  ---Why a money or job call cannot be asked for a player now, if it cannot:
  ---DarkRP has not loaded their data, or it is not the character RPF has
  ---in play.
  ---@param handle any The player.
  ---@return "unavailable"|"no_character"|nil problem Nil when it can be asked.
  local function problem(handle)
    local loaded = character(handle)
    if not loaded then
      return "unavailable"
    end
    local current = api.characters.current(handle)
    if not current or current.key ~= loaded.key then
      return "no_character"
    end
    return nil
  end

  ---Moves a player's wallet by an amount and says whether it moved by
  ---exactly that.
  ---@param handle any The player.
  ---@param delta integer The amount, negative for a debit.
  ---@return boolean? ok True if it did.
  ---@return string? status `refused` or `unknown`.
  ---@return string? reason For `refused`, why.
  local function move(handle, delta)
    local before = fx.wallet(handle)
    local done = fx.add_money(handle, delta)
    if done == false then
      -- `addMoney` answers false only for an amount it cannot read, before
      -- it changes anything.
      return nil, "refused", "framework"
    end
    if fx.wallet(handle) == before + delta then
      return true
    end
    -- A `playerWalletChanged` hook replaced the total, or something else
    -- moved the wallet meanwhile: what this call did cannot be told apart.
    return nil, "unknown"
  end

  -- What a held player cannot do. Each hook answers only for a held
  -- player, and leaves every other to DarkRP and the hooks after it.

  fx.hook("PlayerSpawn", function(handle)
    -- DarkRP's own spawn runs after the hooks: take them out once it has.
    if refused(handle) then
      fx.after(function()
        hold(handle)
      end)
    end
  end)
  fx.hook("PlayerDeathThink", function(handle)
    if refused(handle) then
      return false
    end
  end)
  -- `force` does not skip this hook, so an admin's or DarkRP's own forced
  -- change is refused too.
  fx.hook("playerCanChangeTeam", function(handle)
    if refused(handle) then
      return false, darkrp.REFUSED
    end
  end)
  -- Every DarkRP command asks this, typed in chat or sent as `darkrp
  -- <command>` from the console (the F4 menu's job changes and purchases).
  fx.hook("canChatCommand", function(handle)
    if refused(handle) then
      return false
    end
  end)
  -- No salary, and no payday message: as DarkRP's AFK module does it.
  fx.hook("playerGetSalary", function(handle)
    if refused(handle) then
      return true, "", 0
    end
  end)
  -- DarkRP lets the dead talk (`deadvoice`), and a held player is dead.
  fx.hook("PlayerCanHearPlayersVoice", function(_, talker)
    if refused(talker) then
      return false, false
    end
  end)
  -- DarkRP's `vote` console command asks only this, not `canChatCommand`.
  fx.hook("canVote", function(handle)
    if refused(handle) then
      return false, darkrp.REFUSED
    end
  end)
  fx.hook("canDemote", function(_, target)
    if refused(target) then
      return false, darkrp.ABSENT
    end
  end)
  fx.hook("canWanted", function(target)
    if refused(target) then
      return false, darkrp.ABSENT
    end
  end)
  fx.hook("canRequestWarrant", function(target)
    if refused(target) then
      return false, darkrp.ABSENT
    end
  end)
  fx.hook("canRequestHit", function(_, _, target)
    if refused(target) then
      return false, darkrp.ABSENT
    end
  end)
  -- DarkRP sets the wallet once it has loaded a player's data, and has no
  -- hook of its own for that: the wallet's first value is the cue. A
  -- changed `rpname` is a rename. `setDarkRPVar` runs this hook before it
  -- stores the value, so the player is looked at on the next tick, once it
  -- has.
  fx.hook("DarkRPVarChanged", function(handle, var)
    if var == "money" or var == "rpname" then
      fx.after(function()
        observe(handle)
      end)
    end
  end)

  api.events.on("players.character_select", function(player)
    observe(player.handle)
  end)
  api.events.on("players.active", function(player)
    local handle = player.handle
    if held[handle] then
      held[handle] = nil
      if fx.valid(handle) and not fx.alive(handle) then
        fx.spawn(handle)
      end
    end
  end)
  -- Before `players.active`, so a spawn that handler makes is in play.
  api.events.on("players.state_changed", function(player, from)
    in_play[player.handle] = player.state == "active" or nil
    if from == "active" and player.state ~= "dropping" then
      hold(player.handle)
    end
  end)
  api.events.on("players.dropping", function(player)
    held[player.handle] = nil
    said[player.handle] = nil
  end)
  api.time.every(darkrp.SWEEP_MS, sweep)
  -- Anyone in the world already, as after the bridge's own file reloads.
  sweep()

  return bridge.register({
    name = darkrp.NAME,
    version = darkrp.VERSION,
    contract = { major = 1, minor = 0 },
    -- DarkRP owns money and jobs, and has no characters or items of its
    -- own, but RPF must not own either beside it.
    provides = { "characters", "money", "inventory", "jobs" },
    -- The pocket is a store of world entities, not an item inventory: no
    -- inventory call is supported, and the bridge never touches it.
    supports = { "money.accounts", "money.balance", "money.debit", "money.credit", "jobs.current" },
    tested_with = darkrp.TESTED_WITH,
    running = function()
      return fx.running()
    end,
    start = function(selecting)
      -- Without DarkRP there is no data to look at, and its functions are
      -- not there to call: the bridge stays quiet, and RPF answers addons
      -- that DarkRP is unavailable.
      if not fx.running() then
        local ok, err = bridge.unavailable("DarkRP is not the gamemode")
        if not ok then
          fx.log("warn", "RPF did not take DarkRP being unavailable: " .. tostring(err))
        end
        return
      end
      active = true
      for _, handle in ipairs(selecting) do
        observe(handle)
      end
    end,
    stop = function()
      active = false
    end,
    money = {
      accounts = function()
        return { darkrp.ACCOUNT }
      end,
      balance = function(handle, account)
        if account ~= darkrp.ACCOUNT then
          return nil, "not_found"
        end
        local why = problem(handle)
        if why then
          return nil, why
        end
        return fx.wallet(handle)
      end,
      debit = function(handle, account, amount)
        if account ~= darkrp.ACCOUNT then
          return nil, "refused", "no_account"
        end
        local why = problem(handle)
        if why == "unavailable" then
          return nil, "unavailable"
        elseif why then
          return nil, "refused", why
        end
        -- Never below zero: `addMoney` itself takes any amount.
        local wallet = fx.wallet(handle)
        if type(wallet) ~= "number" or wallet < amount or not fx.can_afford(handle, amount) then
          return nil, "refused", "insufficient_funds"
        end
        return move(handle, -amount)
      end,
      credit = function(handle, account, amount)
        if account ~= darkrp.ACCOUNT then
          return nil, "refused", "no_account"
        end
        local why = problem(handle)
        if why == "unavailable" then
          return nil, "unavailable"
        elseif why then
          return nil, "refused", why
        end
        if type(fx.wallet(handle)) ~= "number" then
          return nil, "unavailable"
        end
        return move(handle, amount)
      end,
    },
    jobs = {
      current = function(handle)
        local why = problem(handle)
        if why then
          return nil, why
        end
        local job = fx.job(handle)
        if type(job) ~= "table" or type(job.command) ~= "string" or job.command == "" then
          return nil
        end
        -- A team is the job: DarkRP has no grades and no duty.
        return { name = job.command, grade = 0, on_duty = true }
      end,
    },
  })
end

return darkrp
