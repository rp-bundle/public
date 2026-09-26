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

---Builds a read-only view of a table. Reads go through to it, writes are
---refused, and the metatable is hidden so it cannot be swapped out.
---`__pairs` lets Lua 5.4 (FiveM) iterate the view, which is how an adapter
---copies it into an export; LuaJIT ignores `__pairs`, and Gmod publishes the
---view itself.
---@param backing table The table to expose.
---@param path string Its name, for the error on a write.
---@return table view The read-only view.
local function freeze(backing, path)
  return setmetatable({}, {
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

---The members of the public API, by table, as names. `meta/api.lua`
---declares exactly these, plus the reserved `bridge`; a test holds the two
---together.
---@type table<string, string[]>
local MEMBERS = {
  [""] = { "VERSION", "engine", "events", "players", "config", "auth" },
  events = { "on", "once", "off", "emit" },
  players = { "get", "by_player_id", "list", "authenticated" },
  config = { "item", "job", "employer", "setting", "version" },
  auth = {
    "login",
    "register",
    "change_password",
    "logout",
    "state",
    "account",
    "api_token",
    "PASSWORD_REUSE_WARNING",
  },
}

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
    job = function(slug)
      return config.job(slug)
    end,
    employer = function(slug)
      return config.employer(slug)
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

---The member names of the public API and the names it reserves, for the
---test that holds `meta/api.lua` to them.
---@return table<string, string[]> members Names by table, `""` for the top level.
---@return string[] reserved Top-level names kept for later milestones.
function rpf.api_members()
  return MEMBERS, RESERVED
end

return rpf.api
