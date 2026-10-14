-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Conformance (#183): the starter addon `lua/addons/rpf_inventory/`, run as it
-- ships on the mock platform and on the real FiveM and Gmod adapters,
-- against a fake portal (`spec/support/conformance.lua`). Its server half
-- is driven the way a player's client drives it, through interactions: the
-- view, a page of stacks, and each command, numbered so that one sent again
-- happens once. Another player's container, a player who is not near and a
-- setting that forbids it are refused with a sentence, and nothing moves.

local conformance = require("spec.support.conformance")
local support = require("spec.support")

---What `conformance.run` needs from busted.
local busted = { describe = describe, it = it, before_each = before_each, after_each = after_each }

local SERVER = "00000001-0000-4000-8000-000000000001"
local PLAYER = "00000002-0000-4000-8000-000000000002"
local SAM_PLAYER = "00000003-0000-4000-8000-000000000003"
local JANE = "00000004-0000-4000-8000-000000000004"
local SAM = "00000005-0000-4000-8000-000000000005"
local WALLET = "00000006-0000-4000-8000-000000000006"
local SAM_WALLET = "00000007-0000-4000-8000-000000000007"
local BAG = "00000008-0000-4000-8000-000000000008"
local POCKETS = "00000009-0000-4000-8000-000000000009"
local SAM_BAG = "0000000a-0000-4000-8000-00000000000a"
local SETTINGS = "0000000b-0000-4000-8000-00000000000b"

---Loads the addon's server half as an engine entry point does, and starts
---it on the world's API.
---@param world spec.ConformanceWorld The world.
---@return rpf_inventory addon The addon's table.
local function load_addon(world)
  rawset(_G, "rpf_inventory", nil)
  dofile(support.path("lua/addons/rpf_inventory/manifest.lua"))
  dofile(support.path("lua/addons/rpf_inventory/server.lua"))
  local addon = rawget(_G, "rpf_inventory")
  assert(addon.start_server(world.api))
  return addon
end

---The portal's copies of Jane and Sam, their wallets and bags.
---@param world spec.ConformanceWorld The world.
local function seed(world)
  local json = world.core.json
  local owned = world.portal.owned
  ---A character with a wallet.
  ---@param id string Its id.
  ---@param player string Its player.
  ---@param first string Its first name.
  ---@param wallet string Its wallet's id.
  ---@param balance integer What the wallet holds.
  local function character(id, player, first, wallet, balance)
    owned[id] = {
      kind = "character",
      revision = 1,
      data = {
        id = id,
        server_id = SERVER,
        owner = { kind = "player", id = player },
        first_name = first,
        last_name = "Doe",
        gender = "female",
      },
    }
    owned[wallet] = {
      kind = "account",
      revision = 1,
      balance = balance,
      data = { id = wallet, server_id = SERVER, owner = { kind = "character", id = id }, name = "wallet", flags = json.array({}) },
    }
  end
  character(JANE, PLAYER, "Jane", WALLET, 100)
  character(SAM, SAM_PLAYER, "Sam", SAM_WALLET, 5)
  ---A bag.
  ---@param id string Its id.
  ---@param owner string Its character.
  ---@param name string Its name.
  ---@param stacks table[] What it holds.
  local function bag(id, owner, name, stacks)
    owned[id] = {
      kind = "container",
      revision = 1,
      data = {
        id = id,
        server_id = SERVER,
        owner = { kind = "character", id = owner },
        name = name,
        contents = json.object({ layout = "list", stacks = json.array(stacks) }),
        flags = json.array({}),
      },
    }
  end
  bag(BAG, JANE, "Bag", {
    json.object({ item = "water", count = 3 }),
    json.object({ item = "water", count = 1, data = json.object({ note = "for Sam" }) }),
  })
  bag(POCKETS, JANE, "Pockets", {})
  bag(SAM_BAG, SAM, "Bag", { json.object({ item = "bread", count = 1 }) })
end

---The config: a wallet for every character, and two items with names.
---@param world spec.ConformanceWorld The world.
---@return table extra The snapshot's sections.
local function config(world)
  local json = world.core.json
  local size = json.object({ x = 1, y = 1 })
  return {
    new_character = json.object({ accounts = json.array({ { name = "wallet", amount = 0 } }) }),
    items = json.array({
      json.object({ slug = "water", name = "Water", weight = 1, size = size, stack_limit = 10 }),
      json.object({ slug = "bread", name = "Bread", weight = 1, size = size, stack_limit = 10 }),
      -- The longest name the catalog allows, in characters that each take
      -- three bytes: the worst a page has to carry.
      json.object({ slug = "relic", name = string.rep("€", 64), weight = 0, size = size, stack_limit = 1 }),
    }),
    item_defaults = json.object({ weight = 1, size = size, stack_limit = 10 }),
  }
end

---Sends an interaction from a player's client (below).
local interact

---The session the server's view named, which `interact` puts on a command
---that names none, as the client does.
---@type string?
local SESSION = nil

---A world with the addon running, Jane and Sam in play a metre apart, and
---the settings record staff made, if any.
---@param world spec.ConformanceWorld The world.
---@param settings table? The settings record's fields.
---@return rpf_inventory addon The addon.
local function ready(world, settings)
  seed(world)
  local addon = load_addon(world)
  world:connect()
  local installed = conformance.installed(world.core, addon.MANIFEST)
  if settings then
    installed.records = { { id = SETTINGS, type = addon.SETTINGS, revision = 1, fields = settings } }
  end
  world:install({ installed }, config(world))
  world:pump()
  assert.are.equal("active", (world.api.addons.state("rpf_inventory")))
  world:select(world:login(1, PLAYER), JANE)
  world:select(world:login(2, SAM_PLAYER), SAM)
  world.place(1, { x = 0, y = 0, z = 0 })
  world.place(2, { x = world:units(1), y = 0, z = 0 })
  SESSION = nil
  SESSION = interact(world, 1, "rpf_inventory.open").data.session
  return addon
end

---How many requests the harness's clients have numbered.
local numbered = 0

---Sends an interaction from a player's client and gives the server's
---answer (as `conformance_acme_tags_spec.lua` does).
---@param world spec.ConformanceWorld The world.
---@param player integer The player.
---@param name string The interaction.
---@param payload table? Its payload.
---@return table answer The decoded answer: `{ ok, reason, data }`.
function interact(world, player, name, payload)
  local json = world.core.json
  if payload and payload.request ~= nil and payload.session == nil then
    payload.session = SESSION
  end
  local before = #world.to_clients
  local body = assert(json.encode(json.object({ name = name, payload = payload and json.object(payload) or nil })))
  numbered = numbered + 1
  world.from_client(player, "rpf:interact", numbered .. "\n" .. body)
  for i = before + 1, #world.to_clients do
    local sent = world.to_clients[i]
    if sent.name == "rpf:interact" then
      local _, reply = sent.payload:match("^(%d+)\n(.*)$")
      return assert(json.decode(reply))
    end
  end
  error("no answer to " .. name)
end

---Jane's view of a container, from its first page.
---@param world spec.ConformanceWorld The world.
---@param player integer The player asking.
---@param container string The container.
---@return table answer The page's answer.
local function page(world, player, container)
  return interact(world, player, "rpf_inventory.page", { container = container, from = 1 })
end

---A stack as a screen names it back: from the page it was drawn from.
---@param world spec.ConformanceWorld The world.
---@param container string The container.
---@param index integer The stack's index on the page.
---@return table ref `{ container, index, item, key }`.
local function ref(world, container, index)
  local stack = assert(page(world, 1, container).data.stacks[index])
  return { container = container, index = stack.index, item = stack.item, key = stack.key }
end

---What a held container holds now, `item×count` per stack.
---@param world spec.ConformanceWorld The world.
---@param id string The container.
---@return string[] stacks The stacks.
local function holds(world, id)
  local out = {}
  for _, stack in ipairs(assert(world.core.records.get("container", id)).contents.stacks) do
    out[#out + 1] = stack.item .. "×" .. stack.count .. (stack.data and stack.data.note and (" " .. stack.data.note) or "")
  end
  return out
end

conformance.run(busted, "the rpf_inventory starter addon", {
  {
    name = "shows a player their containers, money and the players near them",
    run = function(world)
      ready(world)
      local open = interact(world, 1, "rpf_inventory.open")
      assert.is_true(open.ok, tostring(open.reason))
      local view = open.data
      assert.is_true(view.items)
      assert.are.same({ "Bag", "Pockets" }, { view.containers[1].name, view.containers[2].name })
      assert.are.same({ 2, 0 }, { view.containers[1].count, view.containers[2].count })
      assert.are.same({ { account = "wallet", balance = 100 } }, view.money)
      assert.are.same({ { id = SAM_PLAYER, name = "Sam Doe" } }, view.nearby)
      assert.are.same({ give = true, drop = true, cash = true }, view.allow)
      local first = page(world, 1, BAG)
      assert.is_true(first.ok)
      assert.is_false(first.data.more)
      assert.are.same({ "Water", 3 }, { first.data.stacks[1].name, first.data.stacks[1].count })
      assert.is_nil(first.data.stacks[1].special)
      assert.is_true(first.data.stacks[2].special, "a stack with data is marked, and its data stays on the server")
      assert.is_nil(first.data.stacks[2].data)
      world.place(2, { x = world:units(10), y = 0, z = 0 })
      assert.are.same({}, interact(world, 1, "rpf_inventory.open").data.nearby, "Sam walked away")
    end,
  },
  {
    name = "moves, throws away and gives each request once, however often it is sent",
    run = function(world)
      ready(world)
      local water = ref(world, BAG, 1)
      local move = { stack = water, to = POCKETS, count = 2, request = "move-1" }
      assert.is_true(interact(world, 1, "rpf_inventory.move", move).ok)
      assert.is_true(interact(world, 1, "rpf_inventory.move", move).ok, "sent again after a timeout")
      assert.are.same({ "water×1", "water×1 for Sam" }, holds(world, BAG), "and moved once")
      assert.are.same({ "water×2" }, holds(world, POCKETS))
      local drop = { stack = ref(world, POCKETS, 1), count = 1, request = "drop-1" }
      assert.is_true(interact(world, 1, "rpf_inventory.drop", drop).ok)
      assert.is_true(interact(world, 1, "rpf_inventory.drop", drop).ok)
      assert.are.same({ "water×1" }, holds(world, POCKETS), "thrown away once")
      local give = { stack = ref(world, BAG, 2), count = 1, to = SAM_PLAYER, request = "give-1" }
      assert.is_true(interact(world, 1, "rpf_inventory.give", give).ok)
      assert.is_true(interact(world, 1, "rpf_inventory.give", give).ok)
      assert.are.same({ "bread×1", "water×1 for Sam" }, holds(world, SAM_BAG), "the bottle went to Sam, once")
      local cash = { amount = 30, to = SAM_PLAYER, request = "cash-1" }
      assert.is_true(interact(world, 1, "rpf_inventory.cash", cash).ok)
      assert.is_true(interact(world, 1, "rpf_inventory.cash", cash).ok)
      assert.are.same({ 70, 35 }, { world.core.accounts.balance(WALLET), world.core.accounts.balance(SAM_WALLET) })
      world:settle()
      assert.are.equal(1, #world.portal.owned[POCKETS].data.contents.stacks, "the portal has the pockets")
    end,
  },
  {
    name = "answers a request sent again as it went, though the other player has walked off since",
    run = function(world)
      ready(world)
      local cash = { amount = 30, to = SAM_PLAYER, request = "cash-1" }
      assert.is_true(interact(world, 1, "rpf_inventory.cash", cash).ok)
      world.place(2, { x = world:units(10), y = 0, z = 0 })
      local again = interact(world, 1, "rpf_inventory.cash", cash)
      assert.are.same({ true }, { again.ok }, tostring(again.reason))
      assert.are.same({ 70, 35 }, { world.core.accounts.balance(WALLET), world.core.accounts.balance(SAM_WALLET) })
      local new = interact(world, 1, "rpf_inventory.cash", { amount = 30, to = SAM_PLAYER, request = "cash-2" })
      assert.are.same({ false, "They are not near enough." }, { new.ok, new.reason }, "a new one is checked")
    end,
  },
  {
    name = "refuses another player's container, and a player who is not near, moving nothing",
    run = function(world)
      ready(world)
      local before = { holds(world, BAG), holds(world, SAM_BAG) }
      -- Sam's client names Jane's bag by its real id, as a modified client could.
      local janes = ref(world, BAG, 1)
      for _, action in ipairs({ "move", "drop", "give" }) do
        local answer = interact(world, 2, "rpf_inventory." .. action, {
          stack = janes,
          to = action == "give" and PLAYER or SAM_BAG,
          count = 1,
          request = "steal-" .. action,
        })
        assert.are.same({ false, "That is not there any more." }, { answer.ok, answer.reason }, action)
      end
      assert.are.same({ false, "That is not there any more." }, {
        page(world, 2, BAG).ok,
        page(world, 2, BAG).reason,
      }, "nor read it")
      world.place(2, { x = world:units(10), y = 0, z = 0 })
      local far = interact(world, 1, "rpf_inventory.give", { stack = janes, count = 1, to = SAM_PLAYER, request = "far" })
      assert.are.same({ false, "They are not near enough." }, { far.ok, far.reason })
      local nobody = interact(world, 1, "rpf_inventory.cash", { amount = 1, to = PLAYER, request = "self" })
      assert.are.same({ false, "They are not near enough." }, { nobody.ok, nobody.reason }, "nor herself")
      local unnumbered = interact(world, 1, "rpf_inventory.drop", { stack = janes, count = 1 })
      assert.are.same({ false, "That is not something to ask." }, { unnumbered.ok, unnumbered.reason })
      assert.are.same(before, { holds(world, BAG), holds(world, SAM_BAG) }, "nothing moved")
    end,
  },
  {
    name = "pages a container of the longest names within what an answer may carry",
    run = function(world)
      ready(world)
      local json = world.core.json
      for i = 1, 60 do
        assert(world.core.inventory.add(POCKETS, "relic", 1, { data = json.object({ n = i }) }))
      end
      local seen, from, pages = 0, 1, 0
      repeat
        local answer = interact(world, 1, "rpf_inventory.page", { container = POCKETS, from = from })
        assert.is_true(answer.ok, tostring(answer.reason))
        seen = seen + #answer.data.stacks
        from = from + #answer.data.stacks
        pages = pages + 1
      until not answer.data.more
      assert.are.equal(60, seen, "every stack, a page at a time")
      assert.is_true(pages > 1)
    end,
  },
  {
    name = "refuses a command from a view the server no longer remembers, running nothing",
    run = function(world)
      ready(world)
      local drop = { stack = ref(world, BAG, 1), count = 1, request = "drop-1", session = "not-this-one" }
      local answer = interact(world, 1, "rpf_inventory.drop", drop)
      assert.are.same({ false, "The inventory changed. Look again." }, { answer.ok, answer.reason })
      -- The addon stopped and started again: its memory, and its session, stay.
      world:install({}, config(world))
      world:pump()
      world:install({ conformance.installed(world.core, rpf_inventory.MANIFEST) }, config(world))
      world:pump()
      assert.are.equal("active", (world.api.addons.state("rpf_inventory")))
      assert.are.equal(SESSION, interact(world, 1, "rpf_inventory.open").data.session)
      assert.is_true(interact(world, 1, "rpf_inventory.drop", { stack = ref(world, BAG, 1), count = 1, request = "d" }).ok)
      assert.is_true(interact(world, 1, "rpf_inventory.drop", { stack = ref(world, BAG, 1), count = 1, request = "d" }).ok)
      assert.are.same({ "water×2", "water×1 for Sam" }, holds(world, BAG), "sent twice across a restart, thrown once")
      -- Its code loaded again (a resource restart): a request from before is
      -- refused rather than given a new op id.
      load_addon(world)
      world:pump()
      local again = interact(world, 1, "rpf_inventory.drop", { stack = ref(world, BAG, 1), count = 1, request = "d" })
      assert.are.same({ false, "The inventory changed. Look again." }, { again.ok, again.reason })
      assert.are.same({ "water×2", "water×1 for Sam" }, holds(world, BAG))
    end,
  },
  {
    name = "lists ten containers at most, so the view always fits an answer",
    run = function(world)
      seed(world)
      local json = world.core.json
      for i = 1, 20 do
        local id = string.format("000000%02x-0000-4000-8000-0000000000%02x", 0x40 + i, 0x40 + i)
        world.portal.owned[id] = {
          kind = "container",
          revision = 1,
          data = {
            id = id,
            server_id = SERVER,
            owner = { kind = "character", id = JANE },
            name = string.rep("€", 100),
            contents = json.object({ layout = "list", stacks = json.array({}) }),
            flags = json.array({}),
          },
        }
      end
      local addon = load_addon(world)
      world:connect()
      world:install({ conformance.installed(world.core, addon.MANIFEST) }, config(world))
      world:pump()
      world:select(world:login(1, PLAYER), JANE)
      local open = interact(world, 1, "rpf_inventory.open")
      assert.is_true(open.ok, tostring(open.reason))
      assert.are.equal(addon.MAX_CONTAINERS, #open.data.containers)
      for _, container in ipairs(open.data.containers) do
        assert.is_true(#container.name <= addon.MAX_NAME_BYTES, "names cut")
      end
    end,
  },
  {
    name = "does only what the settings allow",
    run = function(world)
      ready(world, { allow_give = false, allow_drop = false, allow_cash = false, reach = 1 })
      local view = interact(world, 1, "rpf_inventory.open").data
      assert.are.same({ give = false, drop = false, cash = false }, view.allow)
      local water = ref(world, BAG, 1)
      for action, said in pairs({
        give = "Giving items is off on this server.",
        drop = "Throwing items away is off on this server.",
        cash = "Handing cash over is off on this server.",
      }) do
        local answer = interact(world, 1, "rpf_inventory." .. action, {
          stack = water,
          count = 1,
          amount = 1,
          to = SAM_PLAYER,
          request = "off-" .. action,
        })
        assert.are.same({ false, said }, { answer.ok, answer.reason }, action)
      end
      assert.are.same({ "water×3", "water×1 for Sam" }, holds(world, BAG))
    end,
  },
})
