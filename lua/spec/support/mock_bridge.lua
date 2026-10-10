---The mock bridge (K2): a bridge to the fake framework
---(`spec/support/mock_framework.lua`), written as a bridge to a real one is,
---through the framework's own API and `rpf.api.bridge` only, by the rules
---of `lua/bridges/README.md`. It passes the shared conformance suite
---(`spec/support/bridge_conformance.lua`), which is what K3 and K4's bridges
---run too.
---
--- - **Selection on RPF's cue.** A player reaching `character_select` (they
---   logged in to RPF) is shown the framework's selection; nobody sees it
---   before. Players already there when the bridge starts are handed to
---   `start`.
--- - **Lifecycle from the framework's server-side events**, never from
---   anything a client sent: `loaded` reports `character_loaded` (after
---   asking the framework who is loaded, rather than trusting the event's
---   arguments alone), `unloaded` reports `character_unloaded`, `stopped`
---   and `started` report the outage.
--- - **Classified by when.** A refusal it checked before calling the
---   framework is `refused`; once the framework was called, its answer is
---   passed on, and a throw is left to the core, which reads it `unknown`.
---   It never retries a framework call.
---@class spec.mock_bridge
local mock_bridge = {}

---The calls it implements.
mock_bridge.SUPPORTS = {
  "money.accounts",
  "money.balance",
  "money.debit",
  "money.credit",
  "inventory.count",
  "inventory.give",
  "inventory.take",
  "jobs.current",
}

---Registers the mock bridge over a framework, through the API as the
---bridge's own code sees it.
---@param api table `rpf.api` as the bridge's resource sees it.
---@param fw spec.MockFramework The framework.
---@return boolean? ok What `register` answered.
---@return string? err Why not.
function mock_bridge.register(api, fw)
  ---The loaded character's key, or nil.
  ---@param player any The engine's handle.
  ---@return string? key The key.
  local function key_of(player)
    local character = fw:player(player)
    return character and character.key or nil
  end

  ---Reports a character the framework says is loaded.
  ---@param player any The engine's handle.
  local function report_loaded(player)
    local character = fw:player(player)
    if character then
      api.bridge.character_loaded(player, { key = character.key, name = character.name })
    end
  end

  -- Registered once, outside `start`: an engine's events are subscribed
  -- once per resource, and the core activates the bridge when it fits.
  fw:on("loaded", function(player)
    report_loaded(player)
  end)
  fw:on("unloaded", function(player)
    api.bridge.character_unloaded(player)
  end)
  fw:on("stopped", function()
    api.bridge.unavailable("mockfw stopped")
  end)
  fw:on("started", function()
    api.bridge.available()
  end)
  api.events.on("players.character_select", function(player)
    fw:show_selection(player.handle)
  end)

  return api.bridge.register({
    name = "mockfw",
    version = "1.0.0",
    contract = { major = api.bridge.CONTRACT_MAJOR, minor = api.bridge.CONTRACT_MINOR },
    provides = { "characters", "money", "inventory", "jobs" },
    supports = mock_bridge.SUPPORTS,
    tested_with = { "1.0" },
    running = function()
      return fw.running, "1.0.3"
    end,
    start = function(selecting)
      if not fw.running then
        api.bridge.unavailable("mockfw is not started")
      end
      for player in pairs(fw.characters) do
        report_loaded(player)
      end
      for _, player in ipairs(selecting) do
        if not fw:player(player) then
          fw:show_selection(player)
        end
      end
    end,
    money = {
      accounts = function()
        return { "cash", "bank" }
      end,
      balance = function(player, account)
        local key = key_of(player)
        if not key then
          return nil, "no_character"
        end
        local balance = fw:balance(key, account)
        if balance == nil then
          return nil, "not_found"
        end
        return balance
      end,
      debit = function(player, account, amount)
        local key = key_of(player)
        if not key then
          return nil, "refused", "no_character"
        end
        local ok, why = fw:remove_money(key, account, amount)
        if ok then
          return true
        end
        if why == "unknown" then
          return nil, "unknown"
        end
        -- The framework checked before it changed anything.
        return nil, "refused", why
      end,
      credit = function(player, account, amount)
        local key = key_of(player)
        if not key then
          return nil, "refused", "no_character"
        end
        local ok, why = fw:add_money(key, account, amount)
        if ok then
          return true
        end
        if why == "unknown" then
          return nil, "unknown"
        end
        return nil, "refused", why
      end,
    },
    inventory = {
      count = function(player, item)
        local key = key_of(player)
        if not key then
          return nil, "no_character"
        end
        return fw:count(key, item)
      end,
      give = function(player, item, count)
        local key = key_of(player)
        if not key then
          return nil, "refused", "no_character"
        end
        local ok, why = fw:add_item(key, item, count)
        if ok then
          return true
        end
        return nil, "unknown", why
      end,
      take = function(player, item, count)
        local key = key_of(player)
        if not key then
          return nil, "refused", "no_character"
        end
        local ok, why = fw:remove_item(key, item, count)
        if ok then
          return true
        end
        if why == "unknown" then
          return nil, "unknown"
        end
        return nil, "refused", why
      end,
    },
    jobs = {
      current = function(player)
        local key = key_of(player)
        if not key then
          return nil, "no_character"
        end
        local job = fw.jobs[key]
        if not job then
          return nil
        end
        return { name = job.name, grade = job.grade, on_duty = job.on_duty }
      end,
    },
  })
end

return mock_bridge
