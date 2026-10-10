---A fake RP framework, for the mock bridge (`spec/support/mock_bridge.lua`)
---and the shared bridge conformance suite (`spec/support/bridge_conformance.lua`).
---
---It stands where Qbox or DarkRP stands on a real server: its own state,
---which only its own API writes, and server-side events a bridge hears. It
---outlives a game server's restart, as a framework's database does, so the
---suite can restart RPF around it. A bridge for a real framework brings a
---fake of that framework instead (K3, K4), and a driver over it with the
---same shape (`spec.FrameworkDriver`).
---@class spec.MockFramework: spec.FrameworkDriver
---@field running boolean Whether its resource is started.
---@field characters table<any, { key: string, name: string }> The character each player has loaded, by engine handle.
---@field money table<string, table<string, integer>> Balances, by character key then account.
---@field items table<string, table<string, integer>> Items, by character key then item.
---@field jobs table<string, { name: string, grade: integer, on_duty: boolean }> Jobs, by character key.
---@field changes table<string, integer> How many times each call changed the framework's state, by the facade's name for it (`money.debit`).
---@field failing table<string, string> How the next call of a name fails: `throw_after` (changes, then throws) or `unknown` (changes, then answers that it cannot say).
---@field during table<string, fun()> Run inside the next call of a name, after it changed the framework's state: where the suite's crash is.
---@field listeners table<string, function[]> Server-side event handlers, by event.
---@field shown table<any, integer> How many times its character selection was shown to each player, by engine handle.
local framework = {}
framework.__index = framework

---A fresh framework, running, with nobody loaded.
---@return spec.MockFramework fw The framework.
function framework.new()
  return setmetatable({
    running = true,
    characters = {},
    money = {},
    items = {},
    jobs = {},
    changes = {},
    failing = {},
    during = {},
    listeners = {},
    shown = {},
  }, framework)
end

-- The framework's own API, which its bridge calls ------------------------------

---Subscribes to one of its server-side events: `loaded`, `unloaded`,
---`stopped`, `started`. Server-side, so a client cannot fire them.
---@param event string The event.
---@param fn function The handler.
function framework:on(event, fn)
  self.listeners[event] = self.listeners[event] or {}
  table.insert(self.listeners[event], fn)
end

---Fires an event to every handler.
---@param event string The event.
---@param ... any Its arguments.
function framework:fire(event, ...)
  for _, fn in ipairs(self.listeners[event] or {}) do
    fn(...)
  end
end

---Shows a player the framework's character selection: on a real server,
---its own UI, from which the player picks the character that `load`s.
---@param player any The engine's handle.
function framework:show_selection(player)
  self.shown[player] = (self.shown[player] or 0) + 1
end

---The character a player has loaded.
---@param player any The engine's handle.
---@return { key: string, name: string }? character The character.
function framework:player(player)
  return self.characters[player]
end

---Runs one state-changing call: fails as the test asked, after the change,
---since a real framework export can fail part way.
---@param name string The call.
---@param change fun() The change.
---@return boolean? ok True once changed.
---@return string? status `unknown` when it cannot say.
function framework:mutate(name, change)
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
    return nil, "unknown"
  end
  return true
end

---A character's balance.
---@param key string The character.
---@param account string The account.
---@return integer? balance Nil for no such account.
function framework:balance(key, account)
  return (self.money[key] or {})[account]
end

---Removes money: refuses a shortfall before changing anything.
---@param key string The character.
---@param account string The account.
---@param amount integer The amount.
---@return boolean? ok True once removed.
---@return string? why `insufficient_funds`, `no_account` or `unknown`.
function framework:remove_money(key, account, amount)
  local balance = self:balance(key, account)
  if balance == nil then
    return nil, "no_account"
  end
  if balance < amount then
    return nil, "insufficient_funds"
  end
  local ok, status = self:mutate("money.debit", function()
    self.money[key][account] = balance - amount
  end)
  return ok, status
end

---Adds money.
---@param key string The character.
---@param account string The account.
---@param amount integer The amount.
---@return boolean? ok True once added.
---@return string? why `no_account` or `unknown`.
function framework:add_money(key, account, amount)
  local balance = self:balance(key, account)
  if balance == nil then
    return nil, "no_account"
  end
  return self:mutate("money.credit", function()
    self.money[key][account] = balance + amount
  end)
end

---How many of an item a character has.
---@param key string The character.
---@param item string The item.
---@return integer count The count.
function framework:count(key, item)
  return (self.items[key] or {})[item] or 0
end

---Gives items.
---@param key string The character.
---@param item string The item.
---@param count integer How many.
---@return boolean? ok True once given.
---@return string? why `unknown`.
function framework:add_item(key, item, count)
  return self:mutate("inventory.give", function()
    self.items[key] = self.items[key] or {}
    self.items[key][item] = self:count(key, item) + count
  end)
end

---Takes items: refuses a shortfall before changing anything.
---@param key string The character.
---@param item string The item.
---@param count integer How many.
---@return boolean? ok True once taken.
---@return string? why `insufficient` or `unknown`.
function framework:remove_item(key, item, count)
  if self:count(key, item) < count then
    return nil, "insufficient"
  end
  return self:mutate("inventory.take", function()
    self.items[key][item] = self:count(key, item) - count
  end)
end

-- The driver: what the test does to the framework ------------------------------

---A character the framework has, with its money and items.
---@param key string Its key.
---@param money table<string, integer>? Its accounts.
---@param items table<string, integer>? Its items.
---@param job { name: string, grade: integer, on_duty: boolean }? Its job.
function framework:seed(key, money, items, job)
  self.money[key] = money or { cash = 0, bank = 0 }
  self.items[key] = items or {}
  self.jobs[key] = job
end

---The player picks a character in the framework's own selection, and it
---loads: the framework fires `loaded`, as its own login does.
---@param player any The engine's handle.
---@param key string The character.
---@param name string Its name.
function framework:load(player, key, name)
  self.characters[player] = { key = key, name = name }
  self:fire("loaded", player, key, name)
end

---The player's character unloads (they log out of it).
---@param player any The engine's handle.
function framework:unload(player)
  if self.characters[player] then
    self.characters[player] = nil
    self:fire("unloaded", player)
  end
end

---The framework's resource stops: every character unloads, then `stopped`.
function framework:stop()
  for player in pairs(self.characters) do
    self:unload(player)
  end
  self.running = false
  self:fire("stopped")
end

---The framework's resource starts again.
function framework:start()
  self.running = true
  self:fire("started")
end

---Makes the next call of a name fail, after it changed the state.
---@param name string The facade's name for the call: `money.debit`, `money.credit`, `inventory.give`, `inventory.take`.
---@param how "throw_after"|"unknown" How.
function framework:fail_next(name, how)
  self.failing[name] = how
end

---The bridge's resource restarted (or RPF's, which takes the bridge's
---with it): the handlers its old code subscribed go, as an engine drops a
---stopped resource's.
function framework:forget_listeners()
  self.listeners = {}
end

---Runs `fn` inside the next call of a name, after it changed the state.
---@param name string The call.
---@param fn fun() What runs there.
function framework:inside_next(name, fn)
  self.during[name] = fn
end

return framework
