-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The starter addon `rpf_inventory`'s own logic, on a stub of `rpf.api`:
-- what the conformance spec cannot reach cheaply. Beside a framework that
-- owns the items it stands aside and says so once, unless staff say run;
-- a request number gets one op id however often it is sent, for a while,
-- and a player's numbers are capped; nearby players are measured in metres
-- and only in the player's bucket.

local support = require("spec.support")

---A stub of the API the addon reads: settings records, what this server
---supports, the clock, op ids, players and their positions.
---@param opts { containers: boolean?, settings: table?, players: table[]? }? The stub's state.
---@return table rpf The stub.
---@return table state What the stub recorded: `registered`, `printed`, `minted`.
local function stub(opts)
  opts = opts or {}
  local state = { registered = {}, minted = 0, now = 1000 }
  local players = opts.players or {}
  local rpf = {
    records = {
      list = function()
        return opts.settings and { { fields = opts.settings } } or {}
      end,
    },
    inventory = {
      supports = function(call)
        return call ~= "containers" or opts.containers ~= false
      end,
    },
    money = { supports = function() return true end },
    time = {
      now = function()
        return state.now
      end,
    },
    ops = {
      new = function()
        state.minted = state.minted + 1
        return "op-" .. state.minted
      end,
    },
    players = {
      list = function()
        return players
      end,
    },
    characters = {
      current = function(handle)
        return { name = "Player " .. tostring(handle) }
      end,
    },
    world = {
      position = function(handle)
        for _, p in ipairs(players) do
          if p.handle == handle then
            return p.at
          end
        end
        return nil
      end,
      bucket = function(handle)
        for _, p in ipairs(players) do
          if p.handle == handle then
            return p.bucket or 0
          end
        end
        return nil
      end,
      metres = function(units)
        return units / 2
      end,
    },
    interactions = {
      register = function(name)
        state.registered[#state.registered + 1] = name
        return true
      end,
    },
    addons = {
      register = function(_, handlers)
        handlers.start()
        return true
      end,
    },
  }
  return rpf, state
end

---Loads the addon's files fresh.
---@return rpf_inventory addon The addon's table.
local function load_addon()
  rawset(_G, "rpf_inventory", nil)
  dofile(support.path("lua/addons/rpf_inventory/manifest.lua"))
  dofile(support.path("lua/addons/rpf_inventory/server.lua"))
  return rawget(_G, "rpf_inventory")
end

describe("rpf_inventory", function()
  local addon, printed, print_

  before_each(function()
    addon = load_addon()
    printed = {}
    print_ = rawget(_G, "print")
    rawset(_G, "print", function(line)
      printed[#printed + 1] = line
    end)
  end)

  after_each(function()
    rawset(_G, "print", print_)
  end)

  describe("beside a framework", function()
    it("stands aside where a framework owns the items, and says so once", function()
      local rpf, state = stub({ containers = false })
      assert.is_true(addon.start_server(rpf))
      assert.is_true(addon.standing_aside(rpf, addon.settings(rpf)))
      assert.are.equal(1, #printed)
      assert.truthy(printed[1]:find("standing aside", 1, true))
      local ok, said = addon.open(rpf, { handle = 1, player_id = "p1" })
      assert.are.same({ false, "This server's own inventory is in charge here." }, { ok, said })
      assert.are.equal(7, #state.registered, "registered all the same, to answer that")
    end)

    it("runs beside one when staff say so, showing the money without the items", function()
      local rpf = stub({ containers = false, settings = { beside_framework = "run" } })
      assert.is_true(addon.start_server(rpf))
      assert.is_false(addon.standing_aside(rpf, addon.settings(rpf)))
      assert.are.equal(0, #printed)
    end)

    it("never stands aside on a server whose items are RPF's", function()
      local rpf = stub()
      assert.is_false(addon.standing_aside(rpf, addon.settings(rpf)))
    end)
  end)

  describe("settings", function()
    it("are the record staff made over the defaults", function()
      local rpf = stub({ settings = { allow_drop = false, reach = 5 } })
      local settings = addon.settings(rpf)
      assert.is_false(settings.allow_drop)
      assert.are.equal(5, settings.reach)
      assert.is_true(settings.allow_give, "a field staff left alone keeps its default")
      assert.are.same(addon.DEFAULTS, addon.settings(stub()), "and with no record, the defaults")
    end)
  end)

  describe("request numbers", function()
    local player = { player_id = "p1" }

    it("get one op id however often they are sent, for a while", function()
      local rpf, state = stub()
      local op = addon.op_for(rpf, player, "r-1")
      assert.are.equal(op, addon.op_for(rpf, player, "r-1"))
      assert.are_not.equal(op, addon.op_for(rpf, player, "r-2"))
      assert.are_not.equal(op, addon.op_for(rpf, { player_id = "p2" }, "r-1"), "another player's are their own")
      state.now = state.now + addon.REQUEST_MS + 1
      assert.are_not.equal(op, addon.op_for(rpf, player, "r-1"), "forgotten after a while")
    end)

    it("are refused when they are not one", function()
      local rpf = stub()
      for _, request in ipairs({ 7, "", "has space", string.rep("x", 65), {} }) do
        assert.is_nil(addon.op_for(rpf, player, request), tostring(request))
      end
    end)

    it("are capped per player, the oldest forgotten first", function()
      local rpf, state = stub()
      local first = addon.op_for(rpf, player, "r-0")
      for i = 1, addon.MAX_REQUESTS do
        state.now = state.now + 1
        addon.op_for(rpf, player, "r-" .. i)
      end
      assert.are_not.equal(first, addon.op_for(rpf, player, "r-0"))
    end)
  end)

  describe("nearby players", function()
    it("are those in the player's bucket within reach, in metres, nearest first", function()
      local players = {
        { handle = 1, player_id = "me", state = "active", at = { x = 0, y = 0, z = 0 } },
        { handle = 2, player_id = "far", state = "active", at = { x = 8, y = 0, z = 0 } },
        { handle = 3, player_id = "near", state = "active", at = { x = 2, y = 0, z = 0 } },
        { handle = 4, player_id = "nearer", state = "active", at = { x = 0, y = 1, z = 0 } },
        { handle = 5, player_id = "elsewhere", state = "active", at = { x = 1, y = 0, z = 0 }, bucket = 3 },
        { handle = 6, player_id = "loading", state = "character_select", at = { x = 1, y = 0, z = 0 } },
        { handle = 7, state = "active", at = { x = 1, y = 0, z = 0 } },
      }
      local rpf = stub({ players = players })
      local ids = {}
      for _, other in ipairs(addon.nearby(rpf, players[1], 3)) do
        ids[#ids + 1] = other.player_id
      end
      assert.are.same({ "nearer", "near" }, ids)
    end)
  end)

  describe("loading on the client", function()
    it("asks for one page at a time, and waits its turn when told too many", function()
      dofile(support.path("lua/addons/rpf_inventory/client.lua"))
      local asked, waiting = {}, 0
      local pages = {
        ["a:1"] = { stacks = { { index = 1 }, { index = 2 } }, more = true },
        ["a:3"] = { stacks = { { index = 3 } }, more = false },
        ["b:1"] = { stacks = {}, more = false },
      }
      local refused_once = false
      local rpf = {
        time = {
          now = function()
            return 0
          end,
          after = function(_, fn)
            waiting = waiting + 1
            fn()
          end,
        },
        interactions = {
          request = function(name, payload, callback)
            if name == "rpf_inventory.open" then
              callback(true, { containers = { { id = "a" }, { id = "b" } } })
              return true
            end
            local key = payload.container .. ":" .. payload.from
            asked[#asked + 1] = key
            if key == "a:3" and not refused_once then
              refused_once = true
              callback(false, "too_many")
              return true
            end
            callback(true, pages[key])
            return true
          end,
        },
      }
      local view, err
      addon.load(rpf, function(v, e)
        view, err = v, e
      end)
      assert.is_nil(err)
      assert.are.same({ "a:1", "a:3", "a:3", "b:1" }, asked, "in order, the refused page asked again")
      assert.are.equal(1, waiting, "after a wait")
      assert.are.equal(3, #view.containers[1].stacks)
      assert.are.same({}, view.containers[2].stacks)
    end)
  end)

  describe("refusals", function()
    it("tell the player what happened in a sentence", function()
      assert.are.same({ true }, { addon.told(true) })
      assert.are.same({ false, addon.REASONS.stale }, { addon.told(nil, "refused", "stale") })
      assert.are.same({ false, "Not thirsty." }, { addon.told(nil, "refused", "declined", "Not thirsty.") })
      assert.truthy(select(2, addon.told(nil, "unknown")):find("Staff", 1, true))
      assert.truthy(select(2, addon.told(nil, "refused", "brand_new")):find("brand_new", 1, true))
    end)
  end)
end)
