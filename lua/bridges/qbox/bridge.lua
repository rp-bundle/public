---The Qbox bridge (K3, #93): RPF beside Qbox on FiveM, in the companion
---profile. Qbox (`qbx_core`) owns characters, money and jobs, and
---ox_inventory owns items; this bridge reaches both only through their
---public exports and events, by the rules of `lua/bridges/README.md`, and
---registers with RPF through `rpf.api.bridge`.
---
---The engine is passed in (`rpf_qbox.Engine`), never reached as globals,
---so this file runs unchanged under busted against a fake of qbx_core and
---ox_inventory (`spec/support/qbox_fake.lua`), on every platform the
---conformance harness boots. `fivem/server.lua` builds the real engine
---from FiveM's natives and calls `register`.
---
--- - **The gate.** With `useExternalCharacters`, this bridge is the
---   character selection: it shows it on RPF's cue (`players.character_select`)
---   and logs a character in with `Login` only for a player at
---   `character_select`, and only one of their own. qbx_core still answers
---   its own character callbacks for any client, so every load qbx_core
---   makes is checked against RPF's state as it happens (`CreatePlayer`'s
---   `QBCore:Server:PlayerLoaded`), and again by a sweep every second, and
---   one made for a player who has not reached `character_select` is logged
---   out at once.
--- - **Corroborated, never trusted.** `QBCore:Server:OnPlayerLoaded` is
---   networked, so a client can send it: like every event here, it is only
---   a cue to ask qbx_core (`GetPlayer`) who is loaded.
--- - **Classified by when.** Money and items are checked before the export
---   that changes them; a `false` from qbx_core's money exports or
---   ox_inventory's item exports comes before any change in their code
---   (qbx_core 1.24, ox_inventory 2.48), so it is `refused`. Anything else
---   they answer is `unknown`, and anything they throw the core reads as
---   `unknown` too. Nothing is retried.
---@class rpf_qbox
---@field NAME string The bridge's name, in RPF's log.
---@field VERSION string The bridge's own version.
---@field TESTED_WITH string[] The qbx_core versions it was tested against.
---@field ACCOUNTS string[] The account names it lists: Qbox's money types.
---@field CORE string qbx_core's resource name.
---@field INVENTORY string ox_inventory's resource name.
---@field SWEEP_MS integer How often loaded characters are checked against RPF's state.
---@field SELECT string The client event that shows a player the selection.
---@field CHARACTERS string The callback a client lists its characters with.
---@field LOAD string The callback a client loads one of them with.
local qbox = {}

qbox.NAME = "qbox"
qbox.VERSION = "1.0.0"
qbox.TESTED_WITH = { "1.24" }
qbox.ACCOUNTS = { "cash", "bank", "crypto" }
qbox.CORE = "qbx_core"
qbox.INVENTORY = "ox_inventory"
qbox.SWEEP_MS = 1000
qbox.SELECT = "rpf-qbox:select"
qbox.CHARACTERS = "rpf-qbox:characters"
qbox.LOAD = "rpf-qbox:load"

---The most bytes of a character's name RPF takes (`rpf.bridge.MAX_NAME_BYTES`).
local MAX_NAME_BYTES = 128

---The longest citizenid a client may ask for. qbx_core's are 8 characters.
local MAX_CITIZENID_BYTES = 64

---What the bridge reaches of the engine and of the two resources. On
---FiveM, `fivem/server.lua` builds it from the natives; under busted, the
---fake (`spec/support/qbox_fake.lua`) is it.
---@class rpf_qbox.Engine
---@field qbx table `exports.qbx_core`: `GetPlayer`, `GetMoney`, `AddMoney`, `RemoveMoney`, `Login`, `Logout`, `SearchPlayers`, each called with `:`.
---@field inventory table `exports.ox_inventory`: `Items`, `GetItemCount`, `CanCarryItem`, `AddItem`, `RemoveItem`, each called with `:`.
---@field on fun(event: string, fn: function) Handles a server event (`AddEventHandler`), which a client cannot send.
---@field on_net fun(event: string, fn: fun(source: integer, ...)) Handles a networked event (`RegisterNetEvent`), with its sender.
---@field callback fun(name: string, fn: fun(source: integer, payload: any): any) Answers a client's `lib.callback` request.
---@field to_client fun(event: string, source: integer, payload: any?) Sends a client an event (`TriggerClientEvent`).
---@field state fun(resource: string): string A resource's state (`GetResourceState`): `started`, `stopped`, `missing`, ….
---@field version fun(resource: string): string? A resource's `version` metadata.
---@field identifiers fun(source: integer): string[] The player's Rockstar licences (`license2:…`, `license:…`), which qbx_core keys characters by.
---@field account_items fun(): string[] The ox_inventory items that are qbx_core money (`inventory:accounts`, `money` by default).
---@field thread fun(fn: fun()) Runs a function on a thread of its own (`CreateThread`), where it may wait.
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

---The name qbx_core shows for a character: its first and last name.
---@param charinfo any `PlayerData.charinfo`.
---@return string name The name, or `Unnamed` when it has none.
local function name_of(charinfo)
  local first = type(charinfo) == "table" and type(charinfo.firstname) == "string" and charinfo.firstname or ""
  local last = type(charinfo) == "table" and type(charinfo.lastname) == "string" and charinfo.lastname or ""
  local name = (first .. " " .. last):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then
    return "Unnamed"
  end
  return clip(name)
end

---Registers the Qbox bridge with RPF: subscribes to qbx_core's and the
---engine's events, answers the selection's requests, and offers RPF the
---bridge. Called once per load of the bridge's resource.
---@param api rpf.Api `rpf.api` as the bridge's resource sees it.
---@param fx rpf_qbox.Engine The engine.
---@return boolean? ok What `rpf.bridge.register` answered.
---@return string? err Why not.
---@return string? field For `invalid`, which field.
function qbox.register(api, fx)
  local bridge = api.bridge

  ---Whether RPF activated the bridge: the server's profile is companion.
  ---Until then nothing here acts, so a native server that runs this
  ---resource by mistake is only logged about (`running`).
  local active = false

  ---Players qbx_core is logging out, by server id: between `Logout`'s
  ---`OnPlayerUnload` and its removal of the player, `GetPlayer` still
  ---answers, and the character must not be reported loaded again.
  ---@type table<integer, true>
  local leaving = {}

  ---Whether a resource is started.
  ---@param resource string The resource.
  ---@return boolean started True if it is.
  local function started(resource)
    return fx.state(resource) == "started"
  end

  ---The character qbx_core has loaded for a player.
  ---@param handle integer The player's server id.
  ---@return rpf.BridgeCharacter? character Nil when none is.
  ---@return table? data Its `PlayerData`.
  local function loaded(handle)
    local player = fx.qbx:GetPlayer(handle)
    local data = type(player) == "table" and player.PlayerData or nil
    if type(data) ~= "table" or type(data.citizenid) ~= "string" or data.citizenid == "" then
      return nil
    end
    return { key = data.citizenid, name = name_of(data.charinfo) }, data
  end

  ---The citizenids of a player's characters, with their names, as
  ---qbx_core stores them: every character on either of their licences.
  ---@param handle integer The player's server id.
  ---@return { citizenid: string, name: string }[] characters In qbx_core's slot order.
  local function characters(handle)
    local out, seen = {}, {}
    for _, licence in ipairs(fx.identifiers(handle)) do
      -- Never search without a licence: qbx_core's search with no filter
      -- is every character on the server.
      if type(licence) == "string" and licence ~= "" then
        for _, player in ipairs(fx.qbx:SearchPlayers({ license = licence }) or {}) do
          ---@type table?
          local data = type(player) == "table" and player.PlayerData or nil
          local citizenid = data and data.citizenid or nil
          if data and type(citizenid) == "string" and not seen[citizenid] then
            seen[citizenid] = true
            local cid = type(data.charinfo) == "table" and tonumber(data.charinfo.cid) or nil
            out[#out + 1] = { citizenid = citizenid, name = name_of(data.charinfo), cid = cid or #out + 1 }
          end
        end
      end
    end
    table.sort(out, function(a, b)
      return a.cid < b.cid
    end)
    for _, character in ipairs(out) do
      character.cid = nil
    end
    return out
  end

  ---A player's state in RPF.
  ---@param handle integer The player's server id.
  ---@return string? state Nil for a player RPF does not have.
  ---@return integer? serial Their connection's serial.
  local function rpf_state(handle)
    local player = api.players.get(handle)
    if not player then
      return nil
    end
    return player.state, player.serial
  end

  ---Shows a player the character selection.
  ---@param handle integer The player's server id.
  local function show(handle)
    fx.to_client(qbox.SELECT, handle)
  end

  ---Logs a character out that qbx_core loaded before its player reached
  ---`character_select`: past RPF's gate.
  ---@param handle integer The player's server id.
  local function turn_away(handle)
    if leaving[handle] then
      return
    end
    leaving[handle] = true
    fx.log(
      "error",
      "qbx_core loaded a character for player "
        .. tostring(handle)
        .. " before they logged in to RPF, so it was logged out. Something other than this bridge logged it in: a client"
        .. " calling qbx_core's own character callbacks, qbx_core's own selection (set useExternalCharacters = true in"
        .. " qbx_core/config/client.lua), or another character resource, which must be removed"
    )
    fx.thread(function()
      fx.qbx:Logout(handle)
    end)
  end

  ---Tells RPF a player's character is loaded.
  ---@param handle integer The player's server id.
  ---@param character rpf.BridgeCharacter The character.
  ---@return boolean? ok True once RPF has them active with it.
  local function report(handle, character)
    local ok, err = bridge.character_loaded(handle, character)
    if not ok and err ~= "superseded" then
      fx.log("warn", "RPF did not take player " .. tostring(handle) .. "'s character: " .. tostring(err))
    end
    return ok
  end

  ---Looks at what qbx_core has loaded for a player, on any cue: reports a
  ---character of a player choosing or playing, and turns away one loaded
  ---before RPF's gate. Never acts on the cue's own arguments.
  ---@param handle any The player's server id, as the cue gave it.
  local function observe(handle)
    handle = tonumber(handle)
    if not active or not handle or leaving[handle] or not started(qbox.CORE) then
      return
    end
    local character = loaded(handle)
    if not character then
      return
    end
    local state = rpf_state(handle)
    if state == "character_select" or state == "active" then
      report(handle, character)
    elseif state ~= "dropping" then
      turn_away(handle)
    end
  end

  ---Checks every player RPF has who is not yet playing, and clears the
  ---players qbx_core has finished logging out.
  local function sweep()
    if not active or not started(qbox.CORE) then
      return
    end
    for _, player in ipairs(api.players.list()) do
      local handle = player.handle
      if leaving[handle] then
        if not fx.qbx:GetPlayer(handle) then
          leaving[handle] = nil
        end
      elseif player.state ~= "active" and player.state ~= "dropping" then
        observe(handle)
      end
    end
  end

  ---The character RPF has in play for a player, if qbx_core still has the
  ---same one loaded: what every money and item call acts on.
  ---@param handle integer The player's server id.
  ---@return table? data Its `PlayerData`, or nil when qbx_core has another or none.
  local function playing(handle)
    local character, data = loaded(handle)
    local current = api.characters.current(handle)
    if not character or not current or current.key ~= character.key then
      return nil
    end
    return data
  end

  ---Whether an item is qbx_core money that ox_inventory shows as an item
  ---(`money` is cash): moving it is moving money, which goes through
  ---`rpf.money` instead.
  ---@param item string The item.
  ---@return boolean money True if it is.
  local function is_money(item)
    for _, name in ipairs(fx.account_items()) do
      if name == item then
        return true
      end
    end
    return false
  end

  ---Why an item call cannot be asked now, if it cannot.
  ---@param item string The item.
  ---@return string? status `unavailable` while ox_inventory is not started.
  ---@return string? reason For a refusal, why.
  local function item_problem(item)
    if not started(qbox.INVENTORY) then
      return "unavailable"
    end
    if is_money(item) then
      return "refused", "money_item"
    end
    if fx.inventory:Items(item) == nil then
      return "refused", "unknown_item"
    end
    return nil
  end

  -- qbx_core's and the engine's events. Each one is a cue; what happened
  -- is read from qbx_core.

  -- `CreatePlayer` fires this for every character it loads for a player,
  -- whoever asked: the cue that holds the gate.
  fx.on("QBCore:Server:PlayerLoaded", function(player)
    local data = type(player) == "table" and player.PlayerData or nil
    observe(type(data) == "table" and data.source or nil)
  end)
  -- Networked: a client sends it, so only a cue to look.
  fx.on_net("QBCore:Server:OnPlayerLoaded", function(source)
    observe(source)
  end)
  fx.on("QBCore:Server:OnPlayerUnload", function(source)
    local handle = tonumber(source)
    if not active or not handle then
      return
    end
    leaving[handle] = true
    if rpf_state(handle) == "active" then
      local ok, err = bridge.character_unloaded(handle)
      if not ok then
        fx.log("warn", "RPF did not take player " .. tostring(handle) .. "'s character unloading: " .. tostring(err))
      end
    end
  end)
  fx.on("onResourceStop", function(resource)
    if not active then
      return
    elseif resource == qbox.CORE then
      -- qbx_core's players go with its state, and it says nothing of them.
      leaving = {}
      for _, player in ipairs(api.players.list()) do
        if player.state == "active" then
          bridge.character_unloaded(player.handle)
        end
      end
      bridge.unavailable("qbx_core stopped")
    elseif resource == qbox.INVENTORY then
      fx.log("warn", "ox_inventory stopped: item calls are unavailable until it starts again")
    end
  end)
  fx.on("onResourceStart", function(resource)
    if not active or resource ~= qbox.CORE then
      return
    end
    bridge.available()
    for _, player in ipairs(api.players.list()) do
      if player.state == "character_select" then
        show(player.handle)
      end
    end
  end)

  -- The selection's requests. The sender is the engine's, and everything
  -- else in a request is hostile input.

  fx.callback(qbox.CHARACTERS, function(source)
    local handle = tonumber(source)
    if not active or not handle or rpf_state(handle) ~= "character_select" then
      return { error = "not_selecting" }
    end
    if not started(qbox.CORE) then
      return { error = "unavailable" }
    end
    return { characters = characters(handle) }
  end)

  fx.callback(qbox.LOAD, function(source, citizenid)
    local handle = tonumber(source)
    if not active or not handle then
      return { error = "not_selecting" }
    end
    local state, serial = rpf_state(handle)
    if state ~= "character_select" then
      return { error = "not_selecting" }
    end
    if not started(qbox.CORE) then
      return { error = "unavailable" }
    end
    if type(citizenid) ~= "string" or citizenid == "" or #citizenid > MAX_CITIZENID_BYTES then
      return { error = "not_found" }
    end
    -- qbx_core drops a player who logs in twice, and is still removing one
    -- it is logging out.
    if fx.qbx:GetPlayer(handle) then
      return { error = "busy" }
    end
    leaving[handle] = nil
    local mine = false
    for _, character in ipairs(characters(handle)) do
      mine = mine or character.citizenid == citizenid
    end
    -- qbx_core drops a player who asks for another licence's character:
    -- refused here first, the same as one that does not exist.
    if not mine then
      return { error = "not_found" }
    end
    local ok, done = pcall(function()
      return fx.qbx:Login(handle, citizenid)
    end)
    if not ok or done ~= true then
      fx.log("warn", "qbx_core did not log player " .. tostring(handle) .. " in: " .. tostring(ok and done or "it threw"))
      return { error = "failed" }
    end
    -- `Login` waits on the database: the player may have left, and the
    -- server id gone to someone else, meanwhile.
    local now, now_serial = rpf_state(handle)
    local character = loaded(handle)
    if now ~= "character_select" and now ~= "active" or now_serial ~= serial then
      if character then
        turn_away(handle)
      end
      return { error = "not_selecting" }
    end
    if not character or character.key ~= citizenid or not report(handle, character) then
      return { error = "failed" }
    end
    return { ok = true }
  end)

  api.events.on("players.character_select", function(player)
    if not active then
      return
    end
    if loaded(player.handle) then
      observe(player.handle)
    else
      show(player.handle)
    end
  end)
  api.events.on("players.dropping", function(player)
    leaving[player.handle] = nil
  end)
  api.time.every(qbox.SWEEP_MS, sweep)

  return bridge.register({
    name = qbox.NAME,
    version = qbox.VERSION,
    contract = { major = 1, minor = 0 },
    provides = { "characters", "money", "inventory", "jobs" },
    supports = {
      "money.accounts",
      "money.balance",
      "money.debit",
      "money.credit",
      "inventory.count",
      "inventory.give",
      "inventory.take",
      "jobs.current",
    },
    tested_with = qbox.TESTED_WITH,
    running = function()
      return started(qbox.CORE), fx.version(qbox.CORE)
    end,
    start = function(selecting)
      active = true
      if not started(qbox.CORE) then
        bridge.unavailable("qbx_core is not started")
        return
      end
      -- Characters qbx_core kept while the bridge was away: reported for a
      -- player choosing, turned away for one past the gate.
      for _, player in ipairs(api.players.list()) do
        observe(player.handle)
      end
      for _, handle in ipairs(selecting) do
        if not loaded(handle) then
          show(handle)
        end
      end
    end,
    stop = function()
      active = false
    end,
    money = {
      accounts = function()
        local out = {}
        for i, name in ipairs(qbox.ACCOUNTS) do
          out[i] = name
        end
        return out
      end,
      balance = function(handle, account)
        if not playing(handle) then
          return nil, "no_character"
        end
        local balance = fx.qbx:GetMoney(handle, account)
        if type(balance) ~= "number" then
          return nil, "not_found"
        end
        return balance
      end,
      debit = function(handle, account, amount, reason, op_id)
        if not playing(handle) then
          return nil, "refused", "no_character"
        end
        local balance = fx.qbx:GetMoney(handle, account)
        if type(balance) ~= "number" then
          return nil, "refused", "no_account"
        end
        -- Never below zero, though qbx_core lets `bank` go there.
        if balance < amount then
          return nil, "refused", "insufficient_funds"
        end
        local done = fx.qbx:RemoveMoney(handle, account, amount, reason .. " (rpf " .. op_id .. ")")
        if done == true then
          return true
        elseif done == false then
          -- A hook's veto, or a check of its own: before any change.
          return nil, "refused", "framework"
        end
        return nil, "unknown"
      end,
      credit = function(handle, account, amount, reason, op_id)
        if not playing(handle) then
          return nil, "refused", "no_character"
        end
        if type(fx.qbx:GetMoney(handle, account)) ~= "number" then
          return nil, "refused", "no_account"
        end
        local done = fx.qbx:AddMoney(handle, account, amount, reason .. " (rpf " .. op_id .. ")")
        if done == true then
          return true
        elseif done == false then
          return nil, "refused", "framework"
        end
        return nil, "unknown"
      end,
    },
    inventory = {
      count = function(handle, item)
        if not started(qbox.INVENTORY) then
          return nil, "unavailable"
        end
        if not playing(handle) then
          return nil, "no_character"
        end
        if is_money(item) or fx.inventory:Items(item) == nil then
          return nil, "not_found"
        end
        return fx.inventory:GetItemCount(handle, item)
      end,
      give = function(handle, item, count)
        local status, reason = item_problem(item)
        if status then
          return nil, status, reason
        end
        if not playing(handle) then
          return nil, "refused", "no_character"
        end
        -- `AddItem` adds what fits of an item that does not stack and
        -- answers true: whether all of it fits is asked first.
        if fx.inventory:CanCarryItem(handle, item, count) ~= true then
          return nil, "refused", "no_space"
        end
        local before = fx.inventory:GetItemCount(handle, item)
        local done, why = fx.inventory:AddItem(handle, item, count)
        if done == false then
          return nil, "refused", type(why) == "string" and why or "framework"
        elseif done ~= true or fx.inventory:GetItemCount(handle, item) ~= before + count then
          return nil, "unknown"
        end
        return true
      end,
      take = function(handle, item, count)
        local status, reason = item_problem(item)
        if status then
          return nil, status, reason
        end
        if not playing(handle) then
          return nil, "refused", "no_character"
        end
        local before = fx.inventory:GetItemCount(handle, item)
        if before < count then
          return nil, "refused", "insufficient"
        end
        local done, why = fx.inventory:RemoveItem(handle, item, count)
        if done == false then
          return nil, "refused", type(why) == "string" and why or "framework"
        elseif done ~= true or fx.inventory:GetItemCount(handle, item) ~= before - count then
          return nil, "unknown"
        end
        return true
      end,
    },
    jobs = {
      current = function(handle)
        local data = playing(handle)
        if not data then
          return nil, "no_character"
        end
        local job = data.job
        if type(job) ~= "table" or type(job.name) ~= "string" then
          return nil
        end
        local grade = type(job.grade) == "table" and tonumber(job.grade.level) or 0
        return { name = job.name, grade = grade or 0, on_duty = job.onduty == true }
      end,
    },
  })
end

rpf_qbox = qbox
return qbox
