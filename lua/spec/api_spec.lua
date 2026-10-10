-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The public API table: exactly what `meta/api.lua` documents, read-only,
-- with nothing internal reachable from it, on both sides.

local support = require("spec.support")

local PLAYER = "00000002-0000-4000-8000-000000000002"

---Reads `meta/api.lua`: the fields of `rpf.Api`, and the members of each
---`rpf.api.*` class (its `---@field`s and its functions).
---@return table<string, table<string, true>> members Members by class name.
local function read_meta()
  local members, locals, current = {}, {}, nil
  for line in support.read("lua/core/meta/api.lua"):gmatch("[^\n]+") do
    local class = line:match("^%-%-%-@class ([%w_.]+)")
    if class then
      current = class
      members[class] = members[class] or {}
    end
    local field = line:match("^%-%-%-@field ([%w_]+)")
    if field and current then
      members[current][field] = true
    end
    local var = line:match("^local ([%w_]+) = {}")
    if var and current then
      locals[var] = current
    end
    local owner, fn = line:match("^function ([%w_]+)%.([%w_]+)%(")
    if owner then
      members[locals[owner]][fn] = true
    end
  end
  return members
end

---Sorted keys of a set.
---@param set table<string, true>? The set.
---@return string[] keys The keys.
local function keys(set)
  local out = {}
  for key in pairs(set or {}) do
    out[#out + 1] = key
  end
  table.sort(out)
  return out
end

---A sorted copy of a list.
---@param list string[] The list.
---@return string[] sorted The copy.
local function sorted(list)
  local out = {}
  for i, value in ipairs(list) do
    out[i] = value
  end
  table.sort(out)
  return out
end

---Parts whose members differ by side, by design: `interactions` registers a
---handler on the server and sends a request from the client. Their class in
---`meta/api.lua` documents the members of both.
---@type table<string, true>
local SIDED = { interactions = true }

---Starts the server on a fake platform.
---@return spec.FakePlatform p The platform.
local function server()
  support.load_core("server")
  local p = support.fake_platform()
  rpf.start_server(p, { url = "ws://portal", api_key = "rpf_test_secret" })
  return p
end

describe("rpf.api", function()
  it("exports exactly what meta/api.lua documents, across both sides", function()
    -- What each side really exports, read from the tables behind the views.
    local top, parts, reserved = {}, {}, nil
    server()
    local built
    built, reserved = rpf.api_members()
    for part, names in pairs(built) do
      parts[part] = names
    end
    support.load_core("client")
    rpf.start_client(support.fake_client_platform())
    built = rpf.api_members()
    for part, names in pairs(built) do
      if part == "" then
        for _, name in ipairs(names) do
          top[name] = true
        end
      elseif parts[part] and SIDED[part] then
        -- Its members are side by side: one class documents both.
        local union = {}
        for _, name in ipairs(parts[part]) do
          union[name] = true
        end
        for _, name in ipairs(names) do
          union[name] = true
        end
        parts[part] = keys(union)
      elseif parts[part] then
        assert.are.same(parts[part], names, part .. " differs between the sides")
      else
        parts[part] = names
      end
    end
    for _, name in ipairs(parts[""]) do
      top[name] = true
    end
    for _, name in ipairs(reserved) do
      top[name] = true
    end

    local meta = read_meta()
    assert.are.same(keys(meta["rpf.Api"]), keys(top))
    for part, names in pairs(parts) do
      if part ~= "" then
        local class = "rpf.api." .. part:sub(1, 1):upper() .. part:sub(2)
        assert.are.same(keys(meta[class]), names, class)
      end
    end
    assert.are.same({ "addons", "auth", "characters", "config", "events", "interactions", "inventory", "jobs", "money", "ops", "players", "records", "staff", "time", "world" }, sorted((function()
      local out = {}
      for part in pairs(parts) do
        if part ~= "" then
          out[#out + 1] = part
        end
      end
      return out
    end)()))
    assert.are.same({ "register" }, keys(meta["rpf.api.Bridge"]))
  end)
  it("reserves bridge and domain_external for Milestone 2 in the meta surface", function()
    local source = support.read("lua/core/meta/api.lua")
    assert.truthy(source:find("---@field bridge rpf.api.Bridge? **Reserved for Milestone 2 (K2", 1, true))
    assert.truthy(source:find('---| "domain_external"', 1, true))
  end)

  describe("on the server", function()
    local p

    before_each(function()
      p = server()
    end)

    it("is what the platform exposed", function()
      assert.are.equal(rpf.api, p.exposed)
    end)

    it("carries the version and the engine, read-only", function()
      assert.are.equal(rpf.VERSION, rpf.api.VERSION)
      assert.are.equal("mock", rpf.api.engine)
      assert.has_error(function()
        rpf.api.engine = "fivem"
      end)
      assert.are.equal("mock", rpf.api.engine)
    end)

    it("has players, staff and config, and no auth", function()
      assert.is_table(rpf.api.players)
      assert.is_table(rpf.api.staff)
      assert.is_table(rpf.api.config)
      assert.is_nil(rpf.api.auth)
    end)

    it("keeps bridge free: nil now, and no script can claim it", function()
      assert.is_nil(rpf.api.bridge)
      assert.has_error(function()
        rpf.api.bridge = {}
      end)
      assert.is_nil(rpf.api.bridge)
    end)

    it("refuses writes at every level, and hides its metatables", function()
      local built = rpf.api_members()
      for part in pairs(built) do
        local target = part == "" and rpf.api or rpf.api[part]
        if target then
          assert.has_error(function()
            ---@diagnostic disable-next-line: inject-field
            target.injected = true
          end)
          assert.has_error(function()
            target[built[part][1]] = function() end
          end)
          assert.are.equal(false, getmetatable(target), part)
        end
      end
      assert.has_error(function()
        setmetatable(rpf.api, {})
      end)
    end)

    it("reaches nothing internal: every member is a plain value or a function", function()
      local built = rpf.api_members()
      local internals = { rpf, p, rpf.connection, rpf.events, rpf.players, rpf.staff, rpf.config, rpf.client, rpf.join, rpf.addons, rpf.time, rpf.data, rpf.records, rpf.facade, rpf.ops, rpf.accounts, rpf.inventory, rpf.jobs, rpf.characters, rpf.world, rpf.interactions }
      for part, names in pairs(built) do
        local target = part == "" and rpf.api or rpf.api[part]
        for _, name in ipairs(target and names or {}) do
          local value = target[name]
          for _, internal in ipairs(internals) do
            assert.are_not.equal(internal, value, part .. "." .. name)
          end
          local kind = type(value)
          if part == "" and kind == "table" then
            assert.are.equal(false, getmetatable(value), name .. " is not a frozen view")
          else
            assert.truthy(
              kind == "function" or kind == "string" or kind == "number" or kind == "nil",
              part .. "." .. name .. " is a " .. kind
            )
          end
        end
      end
    end)

    it("iterates on Lua 5.4, where an adapter copies it into an export, and shows only its members", function()
      if _VERSION == "Lua 5.1" then
        return -- LuaJIT ignores __pairs; Gmod publishes the view itself.
      end
      local seen = {}
      for key in pairs(rpf.api) do
        seen[key] = true
      end
      assert.are.same(sorted({ "VERSION", "engine", "events", "players", "staff", "config", "addons", "records", "time", "characters", "money", "inventory", "jobs", "ops", "world", "interactions", "capabilities" }), keys(seen))
    end)

    it("refuses a script emitting a core event, and passes a script's own events", function()
      assert.are.same({ nil, "reserved" }, { rpf.api.events.emit("players.registered", {}) })
      local got
      rpf.api.events.on("myaddon.ping", function(value)
        got = value
      end)
      rpf.api.events.emit("myaddon.ping", 1)
      assert.are.equal(1, got)
    end)

    it("hands out copies of players", function()
      rpf.players.connected(7)
      local view = rpf.api.players.get(7)
      view.state = "active"
      assert.are.equal("connecting", rpf.api.players.get(7).state)
      assert.are.equal(1, #rpf.api.players.list())
      assert.is_false(rpf.api.players.authenticated(7))
      assert.is_nil(rpf.api.players.by_player_id(PLAYER))
    end)

    it("fronts the staff checks, and refuses a player who has not logged in", function()
      rpf.players.connected(7)
      assert.is_false(rpf.api.staff.can(7, "player.kick"))
      assert.are.same({}, rpf.api.staff.permissions(7))
      assert.are.same({ false, "not_logged_in" }, { rpf.api.staff.link(7, "7K3Q-X9ZP") })
      assert.are.same({ false, "forbidden" }, { rpf.api.staff.record(7, "player.kick", "kick") })
    end)

    it("fronts the config lookups", function()
      rpf.config.apply(p, 2, "h", assert(rpf.json.decode('{"items":[{"slug":"water","weight":1}],"settings":{"a":1}}')))
      assert.are.equal(1, rpf.api.config.item("water").weight)
      assert.are.equal(1, rpf.api.config.setting("a"))
      assert.is_nil(rpf.api.config.job("none", "none"))
      assert.is_nil(rpf.api.config.department("none", "none"))
      assert.is_nil(rpf.api.config.employer("none"))
      assert.are.equal(2, rpf.api.config.version())
      assert.is_nil(rpf.api.config.item_base("none"))
      assert.is_nil(rpf.api.config.item_defaults())
      assert.is_nil(rpf.api.config.starting_accounts())
      assert.is_nil(rpf.api.config.default_job())

      rpf.config.apply(
        p,
        3,
        "h",
        assert(rpf.json.decode('{"item_bases":[{"slug":"food","name":"Food"}],"item_defaults":{"weight":1}}'))
      )
      assert.are.equal("Food", rpf.api.config.item_base("food").name)
      assert.are.equal(1, rpf.api.config.item_defaults().weight)
    end)
  end)

  describe("on the client", function()
    it("has auth, and no players or config", function()
      support.load_core("client")
      local c = support.fake_client_platform()
      rpf.start_client(c)
      assert.are.equal(rpf.api, c.exposed)
      assert.is_table(rpf.api.auth)
      assert.is_nil(rpf.api.players)
      assert.is_nil(rpf.api.config)
      assert.are.equal(rpf.auth.PASSWORD_REUSE_WARNING, rpf.api.auth.PASSWORD_REUSE_WARNING)
      assert.are.equal("waiting", rpf.api.auth.state())
      assert.is_nil(rpf.api.auth.account())
      assert.is_nil(rpf.api.auth.api_token())
      assert.has_error(function()
        rpf.api.auth.login = function() end
      end)
    end)

    it("never exposes the session token", function()
      support.load_core("client")
      local c = support.fake_client_platform()
      rpf.start_client(c)
      c.from_server("rpf:join_nonce", {
        nonce = "rpf_jn_one",
        expires_in_ms = 120000,
        portal_url = "https://portal.example",
        server_id = "00000001-0000-4000-8000-000000000001",
      })
      rpf.api.auth.login("sam", "pw")
      c.respond(200, {
        player_id = PLAYER,
        username = "sam",
        created = false,
        ticket = "rpf_jt_t",
        ticket_expires_at = "2026-01-01T00:01:00Z",
        remember_token = "rpf_rt_r",
        remember_token_expires_at = "2026-01-31T00:00:00Z",
        session_token = "rpf_st_secret",
        session_token_expires_at = "2026-01-01T12:00:00Z",
        api_token = rpf.json.null,
        api_token_expires_at = rpf.json.null,
      })
      for _, name in ipairs((rpf.api_members()).auth) do
        local value = rpf.api.auth[name]
        if type(value) == "function" and name ~= "logout" then
          local ok, result = pcall(value)
          if ok and type(result) == "string" then
            assert.is_nil(result:find("rpf_st_", 1, true), name)
          end
        end
      end
    end)
  end)

  it("keeps the core running when the adapter replaces the global with the API, as on Gmod", function()
    support.load_core("server")
    local core = rpf
    local p = support.fake_platform()
    -- The Gmod adapter's expose: the public table becomes the global.
    p.expose = function(api)
      p.exposed = api
      -- Untyped on purpose, so the language server keeps treating the global
      -- as the core table everywhere else in the tree.
      ---@type any
      local replacement = api
      rawset(_G, "rpf", replacement)
    end
    local ok, err = pcall(function()
      core.start_server(p, { url = "ws://portal", api_key = "rpf_test_secret" })
      assert.are.equal(core.api, rpf)
      local registered
      rpf.events.on("players.registered", function(player)
        registered = player.player_id
      end)
      p.open()
      p.deliver(support.portal_frame("welcome", {
        re = p.last().id,
        protocol = core.protocol.VERSION,
        server_id = "00000001-0000-4000-8000-000000000001",
      }))
      core.players.connected(7)
      p.from_client(7, "rpf:client_ready", "{}")
      local begin = p.last()
      assert.are.equal("begin_join", begin.type)
      local challenge = support.portal_frame("join_challenge", { re = begin.id, nonce = "rpf_jn_x" })
      challenge.expires_at = challenge.sent_at
      p.deliver(challenge)
      p.from_client(7, "rpf:join_ticket", '{"ticket":"rpf_jt_x"}')
      p.deliver(support.portal_frame("player_authenticated", {
        re = p.last().id,
        player_id = PLAYER,
        username = "sam",
        created = false,
      }))
      assert.are.equal(PLAYER, registered)
      assert.are.equal("registered", rpf.players.get(7).state)
    end)
    rawset(_G, "rpf", core)
    assert.is_true(ok, tostring(err))
  end)
end)
