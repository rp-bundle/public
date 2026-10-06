---The public API: the documented, supported surface scripts build on.
---
---Everything else under `rpf` is internal and may change in any release.
---This table is what an adapter publishes (`platform.expose`): through the
---resource's export table on FiveM, where each resource has its own Lua
---state, and as the `rpf` global on Gmod, where every addon shares one.
---`meta/api.lua` describes it for server owners' language servers, and
---`spec/api_spec.lua` holds that file to exactly the members built here.
---
---Two properties make it a boundary rather than a convention:
---
--- - **Nothing internal is reachable from it.** Every member is a function
---   that closes over the module it fronts, or a plain value, never a module
---   table, the connection, or the platform. What the functions return are
---   copies. So even a script that walks the table cannot reach the API key,
---   the outbox, a session token or a player's live record.
--- - **It is read-only.** Every table in it refuses writes, so one script
---   cannot replace `rpf.events.on` for every other script sharing the Lua
---   state, or claim a name the API reserves (`bridge`, K2). That stops
---   accidents, not attackers: `rawset` and the debug library still reach
---   past it, and on Gmod it is all the server owner's own code anyway.
---
---What a side gets follows what it loaded: `players` and `config` on the
---server, `auth` on the client, and `events`, `engine` and `VERSION` on both.
local rpf = rpf
local events = rpf.events

---Each read-only view's backing table, so `rpf.api_members` can list what
---is really exported (LuaJIT cannot iterate a view). Weak keys, so this
---holds nothing alive.
---@type table<table, table>
local backings = setmetatable({}, { __mode = "k" })

---Builds a read-only view of a table. Reads go through to it, writes are
---refused, and the metatable is hidden so it cannot be swapped out.
---`__pairs` lets Lua 5.4 (FiveM) iterate the view, which is how an adapter
---copies it into an export; LuaJIT ignores `__pairs`, and Gmod publishes the
---view itself.
---@param backing table The table to expose.
---@param path string Its name, for the error on a write.
---@return table view The read-only view.
local function freeze(backing, path)
  local view = {}
  backings[view] = backing
  return setmetatable(view, {
    __index = backing,
    __newindex = function(_, key)
      error("rpf: " .. path .. " is read-only (tried to set " .. tostring(key) .. ")", 2)
    end,
    __pairs = function()
      return next, backing, nil
    end,
    __metatable = false,
  })
end

---Names the public API keeps for later milestones. They are absent (nil)
---now, and the frozen table stops a script from claiming them first, so a
---later release can fill them without breaking anyone.
---@type string[]
local RESERVED = { "bridge" }

---The top-level table behind `rpf.api`. `engine` is filled in at start.
local surface = {
  VERSION = rpf.VERSION,
  events = freeze({
    on = function(name, handler)
      return events.on(name, handler)
    end,
    once = function(name, handler)
      return events.once(name, handler)
    end,
    off = function(name, handler)
      return events.off(name, handler)
    end,
    emit = function(name, ...)
      return events.emit_public(name, ...)
    end,
  }, "rpf.events"),
}

local players = rpf.players
if players then
  surface.players = freeze({
    get = function(handle)
      return players.get(handle)
    end,
    by_player_id = function(player_id)
      return players.by_player_id(player_id)
    end,
    list = function()
      return players.list()
    end,
    authenticated = function(handle)
      return players.authenticated(handle)
    end,
  }, "rpf.players")
end

local config = rpf.config
if config then
  surface.config = freeze({
    item = function(slug)
      return config.item(slug)
    end,
    item_base = function(slug)
      return config.item_base(slug)
    end,
    item_defaults = function()
      return config.item_defaults()
    end,
    employer = function(slug)
      return config.employer(slug)
    end,
    department = function(employer, slug)
      return config.department(employer, slug)
    end,
    job = function(employer, slug)
      return config.job(employer, slug)
    end,
    starting_accounts = function()
      return config.starting_accounts()
    end,
    default_job = function()
      return config.default_job()
    end,
    setting = function(key)
      return config.setting(key)
    end,
    version = function()
      return config.version()
    end,
  }, "rpf.config")
end

local auth = rpf.auth
if auth then
  surface.auth = freeze({
    login = function(username, password, opts)
      return auth.login(username, password, opts)
    end,
    register = function(username, password, opts)
      return auth.register(username, password, opts)
    end,
    change_password = function(username, password, new_password, opts)
      return auth.change_password(username, password, new_password, opts)
    end,
    logout = function()
      auth.logout()
    end,
    state = function()
      return auth.state()
    end,
    account = function()
      return auth.account()
    end,
    api_token = function()
      return auth.api_token()
    end,
    PASSWORD_REUSE_WARNING = auth.PASSWORD_REUSE_WARNING,
  }, "rpf.auth")
end

---@type rpf.Api
rpf.api = freeze(surface, "rpf")

---Fills in what is only known at start, and publishes the API through the
---platform. Called by `rpf.start_server` and `rpf.start_client`.
---@param platform rpf.ServerPlatform|rpf.ClientPlatform The platform.
function rpf.publish(platform)
  surface.engine = platform.engine
  platform.expose(rpf.api)
end

---Sorted keys of a table.
---@param t table The table.
---@return string[] keys Its keys, as strings.
local function sorted_keys(t)
  local out = {}
  for key in pairs(t) do
    out[#out + 1] = tostring(key)
  end
  table.sort(out)
  return out
end

---What the public API really exports on this side, read from the tables
---behind the views rather than from a list kept by hand, and the names it
---reserves. The test that holds `meta/api.lua` to the API uses this, so a
---member added here without its definition there fails it.
---@return table<string, string[]> members Sorted names by table, `""` for the top level. `engine` appears once the side has started.
---@return string[] reserved Top-level names kept for later milestones.
function rpf.api_members()
  local members = { [""] = sorted_keys(surface) }
  for key, value in pairs(surface) do
    if backings[value] then
      members[key] = sorted_keys(backings[value])
    end
  end
  return members, RESERVED
end

return rpf.api
