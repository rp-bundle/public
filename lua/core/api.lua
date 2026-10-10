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
---   state, or claim a name the API reserves. That stops
---   accidents, not attackers: `rawset` and the debug library still reach
---   past it, and on Gmod it is all the server owner's own code anyway.
---
---What a side gets follows what it loaded: `players`, `staff`, `config`,
---`addons`, `records`, the facade (`characters`, `money`, `inventory`,
---`jobs`, `ops`), `commerce` and `bridge` on the server, `auth` on the client, and `events`, `time`,
---`ui`, `capabilities`, `engine` and `VERSION` on both.
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
---later release can fill them without breaking anyone. `bridge`, reserved
---until K2, is filled now.
---@type string[]
local RESERVED = {}

---What `events.on` and `once` registered for each handler a script passed,
---by name, so `off` with the script's handler finds them: a script's
---handler is registered wrapped, so it runs in the context of the code that
---subscribed (`rpf.addons.run`), with how to forget that its subscriber owns
---it. Weak keys, so a handler nobody holds can go.
---@type table<string, table<any, { fn: function, disown: fun() }[]>>
local wrapped = {}

---Subscribes a script's handler. A handler subscribed while an addon's
---code runs is the addon's, and is removed when it stops (`rpf.addons.own`);
---a `once` that fires, or an `off`, forgets that ownership at once, so an
---addon that subscribes and unsubscribes as it goes leaves nothing behind.
---@param name any The event name.
---@param handler any The handler: a function, or a FiveM function reference.
---@param once boolean Whether it runs once.
---@return any handler The same handler, for `off`; nil if refused.
---@return string? err `invalid` for a name that is not a non-empty string or a handler that cannot be called, `inactive` from code of an addon activation that has ended.
local function subscribe(name, handler, once)
  if type(name) ~= "string" or name == "" or not rpf.callable(handler) then
    return nil, "invalid"
  end
  local addons = rpf.addons
  if addons and addons.stale() then
    return nil, "inactive"
  end
  local ctx = addons and addons.context()
  local by_handler = wrapped[name]
  if not by_handler then
    by_handler = setmetatable({}, { __mode = "k" })
    wrapped[name] = by_handler
  end
  ---@type { fn: function, disown: fun() }
  local registration = { disown = function() end }
  ---Forgets this registration in the map `off` reads, the map itself once
  ---it is empty, and its ownership.
  local function forget()
    local list = by_handler[handler]
    for i = #(list or {}), 1, -1 do
      if list[i] == registration then
        table.remove(list, i)
      end
    end
    if list and #list == 0 then
      by_handler[handler] = nil
    end
    if next(by_handler) == nil and wrapped[name] == by_handler then
      wrapped[name] = nil
    end
    registration.disown()
  end
  ---The handler as registered: forgets itself first if it runs once, then
  ---runs the script's handler in its subscriber's context, which is none
  ---for a script that subscribed outside any addon's code: it must not run
  ---as whichever addon emitted.
  ---@param ... any The event's arguments.
  ---@return any ... The handler's results.
  registration.fn = function(...)
    if once then
      forget()
    end
    if not addons then
      return handler(...)
    end
    local ok, err = addons.run(ctx, handler, ...)
    if not ok then
      error(err, 0)
    end
  end
  by_handler[handler] = by_handler[handler] or {}
  local list = by_handler[handler]
  list[#list + 1] = registration
  if once then
    events.once(name, registration.fn)
  else
    events.on(name, registration.fn)
  end
  if addons then
    registration.disown = addons.own(function()
      forget()
      events.off(name, registration.fn)
    end)
  end
  return handler
end

---How many event names have a subscription a script made, for tests and
---diagnostics: an unsubscribed name must not stay behind.
---@return integer count The count.
function rpf.api_subscribed_names()
  local count = 0
  for _ in pairs(wrapped) do
    count = count + 1
  end
  return count
end

---The top-level table behind `rpf.api`. `engine` is filled in at start.
local surface = {
  VERSION = rpf.VERSION,
  events = freeze({
    on = function(name, handler)
      return subscribe(name, handler, false)
    end,
    once = function(name, handler)
      return subscribe(name, handler, true)
    end,
    off = function(name, handler)
      local by_handler = type(name) == "string" and wrapped[name] or nil
      ---@type { fn: function, disown: fun() }[]?
      local list = by_handler and handler ~= nil and by_handler[handler] or nil
      if not by_handler or not list or #list == 0 then
        return false
      end
      by_handler[handler] = nil
      if next(by_handler) == nil then
        wrapped[name] = nil
      end
      for _, registration in ipairs(list) do
        events.off(name, registration.fn)
        registration.disown()
      end
      return true
    end,
    emit = function(name, ...)
      return events.emit_public(name, ...)
    end,
  }, "rpf.events"),
  time = freeze({
    now = function()
      return rpf.time.now()
    end,
    after = function(delay_ms, fn)
      return rpf.time.after(delay_ms, fn)
    end,
    every = function(period_ms, fn)
      return rpf.time.every(period_ms, fn)
    end,
    cancel = function(id)
      return rpf.time.cancel(id)
    end,
  }, "rpf.time"),
}

local addons = rpf.addons
if addons then
  surface.addons = freeze({
    API = addons.API,
    API_MIN = addons.API_MIN,
    register = function(manifest, handlers)
      return addons.register(manifest, handlers)
    end,
    state = function(namespace)
      return addons.state(namespace)
    end,
    provide = function(name, fn)
      return addons.provide(name, fn)
    end,
    call = function(name, ...)
      return addons.call(name, ...)
    end,
  }, "rpf.addons")
end

local data = rpf.data
if data then
  surface.records = freeze({
    get = function(type_name, id)
      return data.get(type_name, id)
    end,
    list = function(type_name, query)
      return data.list(type_name, query)
    end,
    query = function(type_name, query, callback)
      return data.query(type_name, query, callback)
    end,
    hold = function(type_name, ids, callback)
      return data.hold(type_name, ids, callback)
    end,
    release = function(type_name, ids)
      return data.release(type_name, ids)
    end,
    create = function(type_name, fields, opts)
      return data.create(type_name, fields, opts)
    end,
    update = function(type_name, id, patch, opts)
      return data.update(type_name, id, patch, opts)
    end,
    delete = function(type_name, id, opts)
      return data.delete(type_name, id, opts)
    end,
    batch = function(ops)
      return data.batch(ops)
    end,
  }, "rpf.records")
end

local facade = rpf.facade
if facade then
  surface.characters = freeze({
    current = function(player)
      return facade.current_character(player)
    end,
    supports = function(call)
      return facade.supports("characters", call)
    end,
  }, "rpf.characters")
  surface.money = freeze({
    accounts = function()
      return facade.accounts()
    end,
    balance = function(player, account)
      return facade.balance(player, account)
    end,
    debit = function(player, account, amount, reason, op_id, apply)
      return facade.debit(player, account, amount, reason, op_id, apply)
    end,
    credit = function(player, account, amount, reason, op_id, apply)
      return facade.credit(player, account, amount, reason, op_id, apply)
    end,
    supports = function(call)
      return facade.supports("money", call)
    end,
  }, "rpf.money")
  surface.inventory = freeze({
    count = function(player, item)
      return facade.count(player, item)
    end,
    give = function(player, item, count, op_id, apply)
      return facade.give(player, item, count, op_id, apply)
    end,
    take = function(player, item, count, op_id, apply)
      return facade.take(player, item, count, op_id, apply)
    end,
    supports = function(call)
      return facade.supports("inventory", call)
    end,
  }, "rpf.inventory")
  surface.jobs = freeze({
    current = function(player)
      return facade.current_job(player)
    end,
    supports = function(call)
      return facade.supports("jobs", call)
    end,
  }, "rpf.jobs")
  surface.ops = freeze({
    new = function()
      return rpf.ops.new()
    end,
    unknown = function()
      return rpf.ops.unknown()
    end,
  }, "rpf.ops")
end

local commerce = rpf.commerce
if commerce then
  surface.commerce = freeze({
    exchange = function(player, deal, op_id, apply)
      return commerce.exchange(player, deal, op_id, apply)
    end,
    check = function(player, deal)
      return commerce.check(player, deal)
    end,
  }, "rpf.commerce")
end

local bridge = rpf.bridge
if bridge then
  surface.bridge = freeze({
    CONTRACT_MAJOR = bridge.CONTRACT.major,
    CONTRACT_MINOR = bridge.CONTRACT.minor,
    register = function(definition)
      return bridge.register(definition)
    end,
    character_loaded = function(player, character)
      return bridge.character_loaded(player, character)
    end,
    character_unloaded = function(player)
      return bridge.character_unloaded(player)
    end,
    unavailable = function(reason)
      return bridge.unavailable(reason)
    end,
    available = function()
      return bridge.available()
    end,
  }, "rpf.bridge")
end

local world = rpf.world
local ui = rpf.ui
---What this engine supports: the game world's capabilities on the server,
---and the UI an addon can show on both sides.
---@return table<string, boolean> supported By name.
surface.capabilities = function()
  local out = world and world.capabilities() or {}
  if ui then
    for name, supported in pairs(ui.capabilities()) do
      out[name] = supported
    end
  end
  return out
end
if ui then
  surface.ui = freeze(ui.members(), "rpf.ui")
end
if world then
  surface.world = freeze({
    position = function(player)
      return world.position(player)
    end,
    bucket = function(player)
      return world.bucket(player)
    end,
    model = function(name)
      return world.model(name)
    end,
    entity = function(ref)
      return world.entity(ref)
    end,
    placed = function(type_name, id)
      return world.placed(type_name, id)
    end,
  }, "rpf.world")
end

local interactions = rpf.interactions
if interactions then
  if rpf.players then
    surface.interactions = freeze({
      register = function(name, handler, rules)
        return interactions.register(name, handler, rules)
      end,
    }, "rpf.interactions")
  else
    local targets = rpf.targets
    surface.interactions = freeze({
      send = function(name, payload)
        return interactions.send(name, payload)
      end,
      request = function(name, payload, callback)
        return interactions.request(name, payload, callback)
      end,
      open = function()
        targets.open()
      end,
      nearby = function(callback)
        return targets.nearby(callback)
      end,
      targets = function()
        return targets.rules()
      end,
    }, "rpf.interactions")
  end
end

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

local staff = rpf.staff
if staff then
  surface.staff = freeze({
    can = function(handle, permission)
      return staff.can(handle, permission)
    end,
    permissions = function(handle)
      return staff.permissions(handle)
    end,
    link = function(handle, code)
      return staff.link(handle, code)
    end,
    record = function(handle, permission, action, target)
      return staff.record(handle, permission, action, target)
    end,
  }, "rpf.staff")
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
    edit = function(handle, base_version, changes)
      return config.edit(handle, base_version, changes)
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
    delete_account = function(username, password)
      return auth.delete_account(username, password)
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
  rpf.time.bind(platform --[[@as rpf.time.Clock]])
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
