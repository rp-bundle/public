---A fake of qbx_core and ox_inventory (K3), for the Qbox bridge
---(`lua/bridges/qbox/bridge.lua`) and the shared bridge conformance suite
---(`spec/support/bridge_conformance.lua`).
---
---It is the bridge's engine (`rpf_qbox.Engine`) and the two resources'
---exports behind it, shaped as qbx_core v1.24.0 and ox_inventory v2.48.0
---answer, read from their source, not vendored:
---
--- - `Login` drops a player who is already loaded or asks for another
---   licence's character, and loads through `CreatePlayer`, which fires the
---   server-only `QBCore:Server:PlayerLoaded`. It fires nothing networked.
---   The client sends `QBCore:Server:OnPlayerLoaded` (`client_event`).
--- - qbx_core's own `loadCharacter` and `createCharacter` callbacks log a
---   player in for any client who asks, whatever `useExternalCharacters`
---   says (`hostile_load`, `create`).
--- - `Logout` fires `QBCore:Server:OnPlayerUnload`, then removes the player
---   about 200 ms later (`delay_logouts`, `finish_logouts`). Stopping
---   qbx_core loses its players and says nothing of them.
--- - Money: `GetMoney` is nil for an unknown type, and `RemoveMoney` and
---   `AddMoney` answer false only before they change anything. `cash` and
---   `crypto` never go below zero, but `bank` may.
--- - Items: `AddItem` and `RemoveItem` answer false, with a reason, only
---   before they change anything. `AddItem` puts what fits of an item that
---   does not stack and answers true (`slots`).
---
---What every call crosses is copied, as FiveM's msgpack copies it. It
---outlives a game server's restart, as a framework's database does.
---@class spec.QboxFake: spec.FrameworkDriver
---@field running boolean Whether qbx_core is started.
---@field inventory_running boolean Whether ox_inventory is started.
---@field version string qbx_core's `version` metadata.
---@field db table<string, table> Characters, by citizenid: `license`, `charinfo`, `money`, `items`, `job`.
---@field players table<integer, string> The citizenid qbx_core has loaded for each player, by server id.
---@field slots integer How many free slots each inventory has for items that do not stack.
---@field failing table<string, string> How the next call of a name fails, by the facade's name for it.
---@field during table<string, fun()> Run inside the next call of a name, after it changed the state.
---@field handlers table<string, function[]> Server event handlers, by event.
---@field net table<string, function[]> Networked event handlers, by event.
---@field callbacks table<string, function> `lib.callback` handlers, by name.
---@field logs { level: string, message: string }[] What the bridge logged.
---@field answers table[] What each request the driver made of the bridge answered, in order.
---@field logouts table<integer, integer> How many times `Logout` ran for each player.
---@field dropped table<integer, string> Players qbx_core dropped, and why.
---@field deferred integer[]? Players whose `Logout` waits to remove them, when logouts are delayed.
---@field searches table[] Every filter `SearchPlayers` was called with.
---@field veto boolean? Whether qbx_core's money hooks veto every change, as an owner's hook may.
---@field logging_in fun()? Runs inside the next `Login`, where the real one waits on the database, before it loads the character.
---@field searching fun()? Runs inside the next `SearchPlayers`, where the real one waits on the database: another request overlapping it.
---@field created integer? How many characters qbx_core's creation made, for their citizenids.
local fake = {}
fake.__index = fake

---Items ox_inventory knows: `money` is qbx_core's cash, `phone` does not
---stack.
local ITEMS = {
  water = { stack = true },
  bread = { stack = true },
  phone = { stack = false },
  money = { stack = true },
}

---Deep-copies a value, as a call across resources does.
---@param value any The value.
---@return any copy The copy.
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[copy(key)] = copy(item)
  end
  return out
end

---A fresh qbx_core and ox_inventory, both running, with nobody loaded.
---@return spec.QboxFake fw The fake.
function fake.new()
  return setmetatable({
    running = true,
    inventory_running = true,
    version = "1.24.0",
    db = {},
    players = {},
    slots = 40,
    changes = {},
    failing = {},
    during = {},
    handlers = {},
    net = {},
    callbacks = {},
    shown = {},
    logs = {},
    answers = {},
    logouts = {},
    dropped = {},
    searches = {},
  }, fake)
end

---Runs a server event's handlers.
---@param event string The event.
---@param ... any Its arguments.
function fake:fire(event, ...)
  for _, fn in ipairs(self.handlers[event] or {}) do
    fn(...)
  end
end

---The licence a player's characters are stored under.
---@param player integer The player's server id.
---@return string licence `license2:<id>`.
local function licence_of(player)
  return "license2:" .. tostring(player)
end

---qbx_core's `dropForExploit`: the player is dropped.
---@param player integer The player's server id.
---@param why string Why.
function fake:drop(player, why)
  self.dropped[player] = why
  self.players[player] = nil
end

---A player object as `GetPlayer` hands it over: its `PlayerData`, copied.
---@param player integer The player's server id.
---@return table? object The object, or nil.
function fake:object(player)
  local citizenid = self.players[player]
  local data = citizenid and self.db[citizenid]
  if not data then
    return nil
  end
  local out = copy(data)
  out.source = player
  out.citizenid = citizenid
  return { PlayerData = out }
end

---Runs one state-changing call: fails as the test asked, after the change,
---since a real export can fail part way.
---@param name string The facade's name for the call.
---@param change fun() The change.
---@param answer any What the export answers once it changed the state.
---@return any answer The answer, or nil for `unknown`.
function fake:mutate(name, change, answer)
  change()
  self.changes[name] = (self.changes[name] or 0) + 1
  local during = self.during[name]
  self.during[name] = nil
  if during then
    during()
  end
  local how = self.failing[name]
  self.failing[name] = nil
  if how == "throw_after" then
    error("the framework failed part way through " .. name)
  elseif how == "unknown" then
    return nil
  end
  return answer
end

---The loaded character of a player, as an export resolves its identifier.
---@param id any A server id.
---@return table? data The character.
function fake:resolve(id)
  local citizenid = type(id) == "number" and self.players[id] or nil
  return citizenid and self.db[citizenid] or nil
end

---Logs a player in, as qbx_core's `Login` does.
---@param player integer The player's server id.
---@param citizenid string? An existing character.
---@param new table? A new character's data.
---@return boolean ok True once loaded.
function fake:login(player, citizenid, new)
  if self.players[player] then
    self:drop(player, "logged in twice")
    return false
  end
  if citizenid then
    local data = self.db[citizenid]
    if not data or data.license ~= licence_of(player) then
      self:drop(player, "character joining exploit")
      return false
    end
  else
    self.created = (self.created or 0) + 1
    citizenid = "NEW" .. self.created
    self.db[citizenid] = {
      license = licence_of(player),
      charinfo = copy(assert(new, "Login with neither a citizenid nor new data").charinfo),
      money = { cash = 500, bank = 5000, crypto = 0 },
      items = {},
      job = { name = "unemployed", grade = { level = 0 }, onduty = false },
    }
  end
  local logging_in = self.logging_in
  self.logging_in = nil
  if logging_in then
    logging_in()
  end
  self.players[player] = citizenid
  -- `CreatePlayer`, once the player is in qbx_core's table.
  self:fire("QBCore:Server:PlayerLoaded", self:object(player))
  return true
end

---Removes a player `Logout` is logging out.
---@param player integer The player's server id.
function fake:remove(player)
  self.players[player] = nil
end

---Logs a player out, as qbx_core's `Logout` does.
---@param player integer The player's server id.
function fake:logout(player)
  if not self.players[player] then
    return
  end
  self.logouts[player] = (self.logouts[player] or 0) + 1
  self:fire("QBCore:Server:OnPlayerUnload", player)
  if self.deferred then
    self.deferred[#self.deferred + 1] = player
  else
    self:remove(player)
  end
end

---qbx_core's `emitMoneyEvents`, after a balance changed: an account
---ox_inventory keeps as an item (`cash`, as `money`) is set there through
---its export, which throws while ox_inventory is stopped.
---@param answer any What the change answered.
---@param kind string The money type.
---@return any answer The answer, once the item is set.
function fake:sync_money(answer, kind)
  if kind == "cash" and not self.inventory_running then
    error("No such export SetItem in resource ox_inventory")
  end
  return answer
end

---qbx_core's exports, as `exports.qbx_core` hands them to another resource.
---@return table exports The exports, called with `:`.
function fake:qbx()
  local fw = self
  return {
    GetPlayer = function(_, player)
      return fw:object(player)
    end,
    GetMoney = function(_, id, kind)
      if not kind then
        return false
      end
      local data = fw:resolve(id)
      if not data then
        return false
      end
      return data.money[kind]
    end,
    RemoveMoney = function(_, id, kind, amount)
      local data = fw:resolve(id)
      if not data or type(amount) ~= "number" or amount < 0 or data.money[kind] == nil then
        return false
      end
      if fw.veto then
        return false
      end
      if (kind == "cash" or kind == "crypto") and data.money[kind] - amount < 0 then
        return false
      end
      return fw:sync_money(fw:mutate("money.debit", function()
        data.money[kind] = data.money[kind] - amount
      end, true), kind)
    end,
    AddMoney = function(_, id, kind, amount)
      local data = fw:resolve(id)
      if not data or type(amount) ~= "number" or amount < 0 or data.money[kind] == nil then
        return false
      end
      if fw.veto then
        return false
      end
      return fw:sync_money(fw:mutate("money.credit", function()
        data.money[kind] = data.money[kind] + amount
      end, true), kind)
    end,
    Login = function(_, player, citizenid, new)
      return fw:login(player, citizenid, new)
    end,
    Logout = function(_, player)
      fw:logout(player)
    end,
    SearchPlayers = function(_, filters)
      fw.searches[#fw.searches + 1] = copy(filters)
      -- qbx_core searches every character when no filter is given.
      assert(type(filters) == "table" and type(filters.license) == "string", "searched without a licence")
      local searching = fw.searching
      fw.searching = nil
      if searching then
        searching()
      end
      local out = {}
      for citizenid, data in pairs(fw.db) do
        if data.license == filters.license then
          local row = copy(data)
          row.citizenid = citizenid
          out[#out + 1] = { PlayerData = row }
        end
      end
      return out
    end,
  }
end

---ox_inventory's exports, as `exports.ox_inventory` hands them over.
---@return table exports The exports, called with `:`.
function fake:inventory()
  local fw = self
  return {
    Items = function(_, name)
      return copy(ITEMS[name])
    end,
    GetItemCount = function(_, id, name)
      local data = fw:resolve(id)
      return data and data.items[name] or 0
    end,
    CanCarryItem = function(_, id, name, count)
      local data, item = fw:resolve(id), ITEMS[name]
      if not data or not item then
        return nil
      end
      return item.stack or fw.slots >= count
    end,
    AddItem = function(_, id, name, count)
      local data, item = fw:resolve(id), ITEMS[name]
      if not item then
        return false, "invalid_item"
      end
      if not data then
        return false, "invalid_inventory"
      end
      local added = count
      if not item.stack then
        if fw.slots == 0 then
          return false, "inventory_full"
        end
        added = math.min(count, fw.slots)
        fw.slots = fw.slots - added
      end
      return fw:mutate("inventory.give", function()
        data.items[name] = (data.items[name] or 0) + added
      end, true)
    end,
    RemoveItem = function(_, id, name, count)
      local data = fw:resolve(id)
      if not ITEMS[name] then
        return false, "invalid_item"
      end
      if not data then
        return false, "invalid_inventory"
      end
      if (data.items[name] or 0) < count then
        return false, "not_enough_items"
      end
      return fw:mutate("inventory.take", function()
        data.items[name] = data.items[name] - count
      end, true)
    end,
  }
end

---The bridge's engine, over this fake.
---@return rpf_qbox.Engine engine The engine.
function fake:engine()
  local fw = self
  return {
    qbx = fw:qbx(),
    inventory = fw:inventory(),
    on = function(event, fn)
      fw.handlers[event] = fw.handlers[event] or {}
      table.insert(fw.handlers[event], fn)
    end,
    on_net = function(event, fn)
      fw.net[event] = fw.net[event] or {}
      table.insert(fw.net[event], fn)
    end,
    callback = function(name, fn)
      fw.callbacks[name] = fn
    end,
    to_client = function(event, player)
      if event == "rpf-qbox:select" then
        fw.shown[player] = (fw.shown[player] or 0) + 1
      end
    end,
    state = function(resource)
      if resource == "qbx_core" then
        return fw.running and "started" or "stopped"
      elseif resource == "ox_inventory" then
        return fw.inventory_running and "started" or "stopped"
      end
      return "missing"
    end,
    version = function(resource)
      return resource == "qbx_core" and fw.version or nil
    end,
    identifiers = function(player)
      return { licence_of(player), "license:" .. tostring(player) }
    end,
    account_items = function()
      return { "money" }
    end,
    thread = function(fn)
      fn()
    end,
    log = function(level, message)
      fw.logs[#fw.logs + 1] = { level = level, message = message }
    end,
  }
end

---Loads the bridge's code afresh, as its resource starting does, and
---registers it over this fake through the API as its resource sees it.
---The bridge's file sets the `rpf_qbox` global, as a FiveM resource's
---scripts share theirs; the global table is left as it was.
---@param api table `rpf.api` as the bridge's resource sees it.
---@param fw spec.QboxFake The fake.
---@return boolean? ok What `register` answered.
---@return string? err Why not.
function fake.register(api, fw)
  local support = require("spec.support")
  local saved = rawget(_G, "rpf_qbox")
  local bridge = dofile(support.path("lua/bridges/qbox/bridge.lua"))
  rawset(_G, "rpf_qbox", saved)
  return bridge.register(api, fw:engine())
end

-- The driver: what the test does to the two resources -----------------------

---A character qbx_core has, with its money, items and job. It belongs to
---whichever player `load`s it.
---@param key string Its citizenid.
---@param money table<string, integer>? Its money, by type; the others are 0.
---@param items table<string, integer>? Its items.
---@param job { name: string, grade: integer, on_duty: boolean }? Its job; unemployed if nil.
function fake:seed(key, money, items, job)
  local all = { cash = 0, bank = 0, crypto = 0 }
  for kind, amount in pairs(money or {}) do
    all[kind] = amount
  end
  self.db[key] = {
    charinfo = { firstname = "Unnamed", lastname = "", cid = 1 },
    money = all,
    items = copy(items or {}),
    job = job and { name = job.name, grade = { level = job.grade }, onduty = job.on_duty }
      or { name = "unemployed", grade = { level = 0 }, onduty = false },
  }
end

---Asks the bridge, as a player's client does through `lib.callback`.
---@param player integer The player's server id.
---@param name string The callback.
---@param payload any What the client sent.
---@return any answer The bridge's answer, or nil if nothing answers that name.
function fake:request(player, name, payload)
  local fn = self.callbacks[name]
  local answer = fn and fn(player, copy(payload)) or nil
  self.answers[#self.answers + 1] = copy(answer)
  return answer
end

---The player picks a character of theirs in the bridge's selection, and
---their client asks the bridge to load it.
---@param player integer The player's server id.
---@param key string The citizenid.
---@param name string Its name, "First Last".
function fake:load(player, key, name)
  local data = assert(self.db[key], "no such character")
  data.license = licence_of(player)
  local first, last = name:match("^(%S+)%s+(.+)$")
  data.charinfo.firstname, data.charinfo.lastname = first or name, last or ""
  self:request(player, "rpf-qbox:load", key)
end

---The key of the character qbx_core has loaded for a player.
---@param player any The player's server id.
---@return string? key The citizenid, or nil.
function fake:loaded(player)
  return self.players[player]
end

---The player's character unloads: qbx_core's `Logout`.
---@param player integer The player's server id.
function fake:unload(player)
  self:logout(player)
end

---qbx_core stops: its players go with its state, unannounced, then
---`onResourceStop`.
function fake:stop()
  self.players = {}
  self.running = false
  self:fire("onResourceStop", "qbx_core")
end

---qbx_core starts again.
function fake:start()
  self.running = true
  self:fire("onResourceStart", "qbx_core")
end

---ox_inventory stops.
function fake:stop_inventory()
  self.inventory_running = false
  self:fire("onResourceStop", "ox_inventory")
end

---ox_inventory starts again.
function fake:start_inventory()
  self.inventory_running = true
  self:fire("onResourceStart", "ox_inventory")
end

---A character's balance, as qbx_core holds it.
---@param key string The citizenid.
---@param account string The money type.
---@return integer? balance The balance.
function fake:balance(key, account)
  return self.db[key] and self.db[key].money[account]
end

---A character's count of an item, as ox_inventory holds it.
---@param key string The citizenid.
---@param item string The item.
---@return integer count The count.
function fake:count(key, item)
  return self.db[key] and self.db[key].items[item] or 0
end

---Makes the next call of a name fail, after it changed the state.
---@param name string The facade's name for the call.
---@param how "throw_after"|"unknown" How: throws, or answers nil.
function fake:fail_next(name, how)
  self.failing[name] = how
end

---Runs `fn` inside the next call of a name, after it changed the state.
---@param name string The call.
---@param fn fun() What runs there.
function fake:inside_next(name, fn)
  self.during[name] = fn
end

---The bridge's resource restarted: what its old code subscribed goes.
function fake:forget_listeners()
  self.handlers, self.net, self.callbacks = {}, {}, {}
end

---A client calls qbx_core's own `qbx_core:server:loadCharacter`, which
---logs it in whatever RPF says.
---@param player integer The player's server id.
---@param key string A character of theirs.
---@return boolean ok What `Login` answered.
function fake:hostile_load(player, key)
  self.db[key].license = licence_of(player)
  return self:login(player, key)
end

---A client calls qbx_core's own `qbx_core:server:createCharacter`, which
---creates a character and logs it in.
---@param player integer The player's server id.
---@param first string Its first name.
---@param last string Its last name.
---@return string? key The new citizenid, once loaded.
function fake:create(player, first, last)
  if self:login(player, nil, { charinfo = { firstname = first, lastname = last, cid = 1 } }) then
    return self.players[player]
  end
  return nil
end

---A client sends a networked event.
---@param player integer The player's server id.
---@param event string The event.
---@param ... any Its arguments.
function fake:client_event(player, event, ...)
  for _, fn in ipairs(self.net[event] or {}) do
    fn(player, ...)
  end
end

---From now on `Logout` removes its player only at `finish_logouts`, as
---the real one waits 200 ms.
function fake:delay_logouts()
  self.deferred = {}
end

---Removes the players `Logout` is waiting on.
function fake:finish_logouts()
  for _, player in ipairs(self.deferred or {}) do
    self:remove(player)
  end
  self.deferred = {}
end

return fake
