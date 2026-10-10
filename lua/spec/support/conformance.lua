---The conformance harness (J3): one game server per platform, booted the way
---that platform boots it, behind one shape, so a single suite of public-API
---cases (`spec/conformance/`) runs unchanged on each.
---
---Three platforms, as `lua/platform/README.md` lists them:
---
--- - `mock`: the mock platform (`lua/platform/mock/init.lua`), which the fake
---   game server drives. The core is loaded as the busted suite loads it, and
---   the API is what `expose` was handed.
--- - `fivem`: the real FiveM adapter, loaded from its manifest on the FiveM
---   fake globals (`lua/platform/mock/fivem.lua`). An addon is another
---   resource: it reaches the API through the `api` export, every value it
---   passes or gets back is copied across the boundary as msgpack copies it,
---   its functions arrive as references, and every call names it as the
---   invoking resource.
--- - `gmod`: the real Gmod adapter on the Gmod fake globals
---   (`lua/platform/mock/gmod.lua`). An addon reads the `rpf` global, which
---   the adapter replaced with the public API.
---
---A case gets a `spec.ConformanceWorld` and must not reach past it into one
---platform's internals, so the same case holds on every engine. K2's bridge
---conformance suite (`spec/support/bridge_conformance.lua`) reuses it, with
---a bridge's resource beside the addon's, a companion `Welcome`, and a
---restart over the storage as it was at one moment (`snapshot`, `restart`).
---@class spec.conformance
---@field PLATFORMS string[] Every platform a case runs on.
local conformance = {}

local support = require("spec.support")

conformance.PLATFORMS = { "mock", "fivem", "gmod" }

---The portal's side, as small as the cases need: the addon records it has,
---and which this server holds. `connect` and `pump` play it.
---@class spec.FakePortal
---@field records table<string, { id: string, type: string, owner: table, revision: integer, fields: table, held: boolean }> Live addon records, by id.
---@field frames table[] Every frame the core sent that the portal read, decoded, in order.
---@field refuse table<string, string>? Frame types the portal refuses, with the code.
---@field owned table<string, { kind: string, revision: integer, data: table, balance: integer? }> Characters, accounts and containers, by id: what a hold of their owner or of them hands over.

---One booted game server, as a case sees it.
---@class spec.ConformanceWorld
---@field platform_name string Which platform: `mock`, `fivem` or `gmod`.
---@field api table The public API as the addon under test sees it: on FiveM through the export, from the resource `acme`.
---@field core rpf The core's internal table, for the harness's own steps (installing addons), never for a case's assertions about the API.
---@field logs { level: string, message: string }[] Every line the platform logged.
---@field time number The fake clock, in milliseconds since the Unix epoch.
---@field origins boolean Whether the platform names the calling code (FiveM resources), so `as` gives another caller and `unload` exists.
---@field server_platform rpf.ServerPlatform The platform the core started on.
---@field version integer? The last config version `install` applied.
---@field view fun(origin: string): table The API as code from an origin sees it.
---@field run_due fun() Runs every timer due by the fake clock.
---@field next_due fun(): number? When the next timer is due.
---@field stop_resource fun(origin: string)? Stops a resource, where there are resources.
---@field finish fun() Takes the platform's globals away again.
---@field join fun(n: integer): any Puts a player in the game, as the engine hands one over, and returns their handle.
---@field place fun(n: integer, at: { x: number, y: number, z: number }) Puts a player somewhere in the world, as the engine reports it.
---@field from_client fun(n: integer, name: string, payload: string) A player's client sent the server a message.
---@field to_clients { player: any, name: string, payload: string }[] Every message the server sent a client, by the harness's number for the player.
---@field socket_open fun(id: integer) The host's socket opened, as the platform hears it.
---@field socket_message fun(id: integer, text: string) A frame arrived on it.
---@field connects integer[] The sockets the core asked for, in order.
---@field sent { id: integer, text: string }[] Every frame the core sent, in order.
---@field answered integer How many of `sent` the fake portal has read.
---@field portal spec.FakePortal What the fake portal holds.
---@field kv table<string, string> The platform's storage: what a restart finds.
local World = {}

World.__index = World

---The API as another addon's code sees it: on FiveM, through the export from
---another resource; elsewhere the same table, since there is no other.
---@param origin string The resource's name.
---@return table api The API.
function World:as(origin)
  return self.view(origin)
end

---Applies a config whose `addons` section is `entries`, as if the portal
---had pushed it, with any other sections `extra` gives.
---@param entries table[] The section, built with `conformance.installed`.
---@param extra table? More sections, by name (`settings`, `paying_accounts`, `new_character`, …).
function World:install(entries, extra)
  self.version = (self.version or 0) + 1
  local json = self.core.json
  local sections = { settings = json.object({}), addons = json.array(entries) }
  for name, section in pairs(extra or {}) do
    sections[name] = section
  end
  local snapshot = assert(json.decode(assert(json.encode(sections))))
  assert(self.core.config.apply(self.server_platform, self.version, "h" .. self.version, snapshot))
end

---A portal frame for the core: encoded, with a fresh id.
---@param world spec.ConformanceWorld The world.
---@param tag string The type.
---@param fields table The fields.
---@return string text The frame.
local function portal_frame(world, tag, fields)
  support.core = world.core
  local protocol = world.core.protocol
  return assert(protocol.encode(protocol.PORTAL_TO_SERVER, support.portal_frame(tag, fields)))
end

---The fake portal's answer to one frame the core sent, or nil for none.
---@param frame table The frame, decoded.
---@return string? tag The answer's type.
---@return table? fields Its fields.
function World:answer(frame)
  local json, portal = self.core.json, self.portal
  local refused = portal.refuse and portal.refuse[frame.type]
  if refused then
    return "rejected", { re = frame.id, code = refused, reason = "refused by the test" }
  end
  if frame.type == "declare_holds" then
    return "state_applied", { re = frame.id, revisions = frame.records }
  elseif frame.type == "online_players" or frame.type == "declare_addons" then
    return "ack", { re = frame.id }
  elseif frame.type == "hold" then
    local out, held = {}, {}
    ---What a hold hands over of a character, an account or a container.
    ---@param owned table The portal's copy.
    local function hand_over(owned)
      local item = { kind = owned.kind, revision = owned.revision, [owned.kind] = owned.data }
      if owned.kind == "account" then
        item.balance = owned.balance
      end
      held[#held + 1] = item
    end
    local ids = {}
    for id in pairs(portal.owned) do
      ids[#ids + 1] = id
    end
    table.sort(ids)
    for _, owner in ipairs(frame.owners) do
      for _, id in ipairs(ids) do
        local owned = portal.owned[id]
        if owned.data.owner.kind == owner.kind and owned.data.owner.id == owner.id then
          hand_over(owned)
        end
      end
    end
    for _, ref in ipairs(frame.records) do
      local record = portal.records[ref.id]
      if ref.kind ~= "addon_record" and portal.owned[ref.id] then
        hand_over(portal.owned[ref.id])
      elseif ref.kind ~= "addon_record" or not record or record.held then
        return "rejected", { re = frame.id, code = "not_found", reason = "not this server's to hold" }
      else
        out[#out + 1] = record
      end
    end
    for _, record in ipairs(out) do
      record.held = true
      held[#held + 1] = {
        kind = "addon_record",
        revision = record.revision,
        record = { id = record.id, type = record.type, owner = record.owner, fields = json.object(record.fields) },
      }
    end
    return "held", { re = frame.id, records = held }
  elseif frame.type == "state_changed" or frame.type == "resync" or frame.type == "release" then
    local revisions = {}
    for _, change in ipairs(frame.changes or frame.records) do
      local record = portal.records[change.id]
      if change.kind == "addon_record_created" then
        local fields = {}
        for name, value in pairs(change.fields) do
          if value ~= json.null then
            fields[name] = value
          end
        end
        portal.records[change.id] = {
          id = change.id,
          type = change.type,
          owner = change.owner,
          revision = 1,
          fields = fields,
          held = true,
        }
        revisions[#revisions + 1] = { kind = "addon_record", id = change.id, revision = 1 }
      elseif change.kind == "addon_record_deleted" then
        portal.records[change.id] = nil
      elseif portal.owned[change.id] then
        local owned = portal.owned[change.id]
        owned.revision = change.revision or owned.revision + 1
        if change.contents then
          owned.data.contents = change.contents
        end
        revisions[#revisions + 1] = { kind = owned.kind, id = change.id, revision = owned.revision }
      elseif record and change.kind == "addon_record" then
        for name, value in pairs(change.patch or change.fields or {}) do
          if value == json.null then
            record.fields[name] = nil
          else
            record.fields[name] = value
          end
        end
        record.revision = change.revision or record.revision + 1
        record.held = frame.type ~= "release"
        revisions[#revisions + 1] = { kind = "addon_record", id = change.id, revision = record.revision }
      end
    end
    if frame.type == "release" then
      return "ack", { re = frame.id }
    end
    return "state_applied", { re = frame.id, revisions = revisions }
  elseif frame.type == "query_records" then
    local found = {}
    for _, record in pairs(portal.records) do
      local keep = record.type == frame.type_name
      for _, filter in ipairs(frame.query.filters or {}) do
        keep = keep and filter.op == "eq" and record.fields[filter.field] == filter.value
      end
      if keep then
        found[#found + 1] = {
          id = record.id,
          type = record.type,
          owner = record.owner,
          revision = record.revision,
          held = record.held,
          fields = json.object(record.fields),
        }
      end
    end
    table.sort(found, function(a, b)
      return a.id < b.id
    end)
    return "records_queried", { re = frame.id, records = found, next = json.null }
  end
  return nil
end

---Reads every frame the core sent since the last pump and answers each,
---until it sends nothing more.
function World:pump()
  local protocol = self.core.protocol
  while self.answered < #self.sent do
    self.answered = self.answered + 1
    local sent = self.sent[self.answered]
    local frame = assert(protocol.decode(protocol.SERVER_TO_PORTAL, sent.text))
    self.portal.frames[#self.portal.frames + 1] = frame
    local tag, fields = self:answer(frame)
    if tag and fields then
      self.socket_message(sent.id, portal_frame(self, tag, fields))
    end
  end
end

---Opens the socket the core asked for, welcomes it, and answers what
---follows, so the core is connected to the fake portal.
---@param domains table? The profile the `Welcome` names; native when nil.
function World:connect(domains)
  local id = assert(self.connects[#self.connects], "the core asked for no socket")
  self.socket_open(id)
  local protocol = self.core.protocol
  local hello = assert(protocol.decode(protocol.SERVER_TO_PORTAL, self.sent[#self.sent].text))
  assert(hello.type == "hello", "the first frame is not a hello")
  self.answered = #self.sent
  self.socket_message(id, portal_frame(self, "welcome", {
    re = hello.id,
    protocol = protocol.VERSION,
    server_id = "00000001-0000-4000-8000-000000000001",
    domains = domains,
  }))
  self:pump()
end

---What the platform's storage holds now: what a game server that died at
---this moment would find when it starts again. A copy.
---@return table<string, string> storage The copy.
function World:snapshot()
  local out = {}
  for key, value in pairs(self.kv) do
    out[key] = value
  end
  return out
end

---Restarts the game server: this process ends, and a new one boots on the
---same platform over `storage` (a `snapshot`, or what storage holds now),
---with the same fake portal and clock, not yet connected. The world is
---the new one in place, so a case's handle on it stays good.
---@param storage table<string, string>? What the new process finds.
function World:restart(storage)
  local kv = storage or self:snapshot()
  local name, portal, time = self.platform_name, self.portal, self.time
  self.finish()
  conformance.boot(name, { kv = kv, portal = portal, time = time, into = self })
end

---Puts a player in the game as the engine does, logs them in as an account
---(the harness's step, standing in for the join), and answers the hold of
---their session.
---@param n integer The harness's number for them.
---@param player_id string Their account.
---@return any handle The engine's handle for them, as the API takes it.
function World:login(n, player_id)
  local handle = self.join(n)
  local players = self.core.players
  assert(players.authenticating(handle))
  assert(players.register(handle, { player_id = player_id, username = "player" .. n }))
  self:pump()
  return handle
end

---Puts a logged-in player's character in play, as the character screen
---does, and answers the hold of its records.
---@param handle any The engine's handle.
---@param character_id string The character.
function World:select(handle, character_id)
  local selected = nil
  assert(self.core.characters.select(handle, character_id, function(_, err)
    selected = err or true
  end))
  self:pump()
  assert(selected == true, "the character was not selected: " .. tostring(selected))
end

---Lets the core report what it changed: one flush interval, and the
---portal's answers.
function World:settle()
  self:advance(1000)
  self:pump()
end

---Moves the clock on, running every timer as it comes due, in order, so a
---repeating timer runs once per period passed.
---@param ms number How far.
function World:advance(ms)
  local target = self.time + ms
  while true do
    local due = self.next_due()
    if not due or due > target then
      break
    end
    self.time = math.max(self.time, due)
    self.run_due()
  end
  self.time = target
  self.run_due()
end

---Stops a resource's code, as FiveM's `onResourceStop` does. Only on a
---platform with `origins`.
---@param origin string The resource.
function World:unload(origin)
  self.stop_resource(origin)
end

---How many log lines at a level contain a text.
---@param level string The level.
---@param text string The text.
---@return integer count The count.
function World:logged(level, text)
  local count = 0
  for _, line in ipairs(self.logs) do
    if line.level == level and line.message:find(text, 1, true) then
      count = count + 1
    end
  end
  return count
end

---What a boot carries over from a process before it (`World:restart`).
---@class spec.BootOptions
---@field kv table<string, string>? The storage it finds.
---@field portal spec.FakePortal? The fake portal, which outlives a game server.
---@field time number? The clock.
---@field into table? The world table to boot into (`World:restart`).

---A host for a mock platform: a clock the world moves, storage, and a log;
---the socket and HTTP go nowhere, since the cases install addons by config.
---@param world spec.ConformanceWorld The world, whose `time` is the clock.
---@param opts spec.BootOptions? What it carries over.
---@return table host The host.
local function host_for(world, opts)
  opts = opts or {}
  local kv = opts.kv or {}
  world.kv = kv
  world.connects, world.sent, world.answered, world.to_clients = {}, {}, 0, {}
  world.portal = opts.portal or { records = {}, frames = {}, owned = {} }
  world.time = opts.time or world.time
  return {
    now = function()
      return world.time
    end,
    kv_get = function(key)
      return kv[key]
    end,
    kv_set = function(key, value)
      kv[key] = value
    end,
    http_request = function() end,
    connect = function(id)
      world.connects[#world.connects + 1] = id
    end,
    close = function() end,
    send = function(id, text)
      world.sent[#world.sent + 1] = { id = id, text = text }
      return true
    end,
    kick = function() end,
    notify = function() end,
    to_client = function(player, name, payload)
      world.to_clients[#world.to_clients + 1] = { player = player, name = name, payload = payload }
    end,
    to_server = function() end,
    log = function(level, message)
      world.logs[#world.logs + 1] = { level = level, message = message }
    end,
  }
end

---A fresh world, not booted.
---@param name string The platform.
---@param into table? A table to make the world in, emptied first (a restart's), so whoever holds it holds the new one, and the platform's closures share its clock.
---@return spec.ConformanceWorld world The world.
local function new_world(name, into)
  local world = into or {}
  for key in pairs(world) do
    world[key] = nil
  end
  world.platform_name, world.logs, world.time, world.origins = name, {}, support.EPOCH_MS, false
  return setmetatable(world, World)
end

---The globals that exist now, to take away what a boot added.
---@return table<string, true> names The names.
local function global_names()
  local names = {}
  for key in pairs(_G) do
    names[key] = true
  end
  return names
end

---Boots the mock platform's server.
---@param opts spec.BootOptions? What it carries over.
---@return spec.ConformanceWorld world The world.
local function boot_mock(opts)
  local world = new_world("mock", opts and opts.into)
  local core = support.load_core("server")
  local mock = dofile(support.path("lua/platform/mock/init.lua"))
  local p = mock.server(host_for(world, opts), 1)
  core.start_server(p, { url = "wss://portal.test/ws", api_key = "rpf_sk_conformance" })
  world.core, world.server_platform, world.api = core, p, assert(p.exposed)
  world.view = function()
    return world.api
  end
  world.run_due = p.run_due
  world.next_due = p.next_due
  world.socket_open, world.socket_message = p.socket_open, p.socket_message
  world.join = function(n)
    p.add_player(n, "Player " .. n, { "license:" .. n })
    assert(core.players.connected(n))
    return n
  end
  world.place = function(n, at)
    p.positions[n] = at
  end
  world.from_client = p.from_client
  world.finish = function()
    rawset(_G, "rpf", nil)
  end
  return world
end

---A script path from the FiveM manifest, as a path in the repository.
---@param script string Relative to the resource.
---@return string path Relative to the repository root.
local function fivem_path(script)
  local core = script:match("^core/(.+)$")
  if core then
    return "lua/core/" .. core
  end
  return "lua/platform/fivem/" .. script
end

---Boots the real FiveM adapter's server on the FiveM fake globals.
---@param opts spec.BootOptions? What it carries over.
---@return spec.ConformanceWorld world The world.
local function boot_fivem(opts)
  local world = new_world("fivem", opts and opts.into)
  world.origins = true
  rawset(_G, "rpf", nil)
  local before = global_names()
  local mock = dofile(support.path("lua/platform/mock/init.lua"))
  local fakes = dofile(support.path("lua/platform/mock/fivem.lua")).bind(mock)
  local host = host_for(world, opts)
  local driver = fakes.server(_G, host, 1, { rpf_url = "wss://portal.test/ws", rpf_api_key = "rpf_sk_conformance" })
  for _, script in ipairs(fakes.scripts(support.read("lua/platform/fivem/fxmanifest.lua"), "server")) do
    dofile(support.path(fivem_path(script)))
  end
  driver.start()
  local core = rawget(_G, "rpf")
  support.core = core
  world.core = core
  world.server_platform = assert(core.connection, "the core did not start").platform
  world.view = function(origin)
    return driver.resource(origin)
  end
  world.api = driver.resource("acme")
  world.run_due = driver.run_due
  world.next_due = driver.next_due
  world.socket_open, world.socket_message = driver.socket_open, driver.socket_message
  world.join = function(n)
    driver.add_player(n, "Player " .. n, { "license:" .. n })
    driver.connect_player(n)
    return n
  end
  world.place = function(n, at)
    driver.positions[n] = at
  end
  world.from_client = driver.from_client
  world.stop_resource = driver.stop_resource
  world.finish = function()
    for key in pairs(_G) do
      if not before[key] then
        rawset(_G, key, nil)
      end
    end
  end
  return world
end

---Boots the real Gmod adapter's server on the Gmod fake globals.
---@param opts spec.BootOptions? What it carries over.
---@return spec.ConformanceWorld world The world.
local function boot_gmod(opts)
  local world = new_world("gmod", opts and opts.into)
  local gmod = dofile(support.path("lua/platform/mock/gmod.lua"))
  local fake = gmod.install("server", host_for(world, opts), {
    read = function(relative)
      return support.read("lua/" .. relative)
    end,
    convars = { rpf_ws_url = "wss://portal.test/ws", rpf_api_key = "rpf_sk_conformance" },
  })
  fake:boot()
  local core = fake.core
  support.core = core
  world.core = core
  world.server_platform = assert(core.connection, "the core did not start").platform
  world.api = rawget(_G, "rpf")
  world.view = function()
    return world.api
  end
  world.run_due = function()
    fake:run_due()
  end
  world.next_due = function()
    return fake:next_due()
  end
  world.socket_open = function(id)
    fake:socket_open(id)
  end
  world.socket_message = function(id, text)
    fake:socket_message(id, text)
  end
  world.join = function(n)
    return fake:connect_player(n, "Player " .. n, string.format("765611980000%05d", n))
  end
  world.place = function(n, at)
    fake.players[n].pos = at
  end
  world.from_client = function(n, name, payload)
    fake:from_client(n, name, payload)
  end
  world.finish = function()
    fake:uninstall()
  end
  return world
end

---Boots a game server on a platform.
---@param name string One of `PLATFORMS`.
---@param opts spec.BootOptions? What it carries over from a process before.
---@return spec.ConformanceWorld world The world, booted and started.
function conformance.boot(name, opts)
  local world
  if name == "mock" then
    world = boot_mock(opts)
  elseif name == "fivem" then
    world = boot_fivem(opts)
  else
    world = boot_gmod(opts)
  end
  return world
end

---One installed addon as the config's `addons` section carries it, with the
---manifest as the portal stores it (round-tripped through JSON).
---@param core rpf The core, for its rules and codec.
---@param manifest table The manifest, as the addon wrote it.
---@param enabled boolean? Whether it is enabled; true unless false.
---@return table entry The section entry.
function conformance.installed(core, manifest, enabled)
  local json = core.json
  local checked = assert(core.manifest.check(manifest))
  return {
    namespace = manifest.namespace,
    version = manifest.version,
    hash = "sha256:" .. manifest.namespace .. manifest.version,
    enabled = enabled ~= false,
    manifest = assert(json.decode(assert(json.encode(checked)))),
    types = json.object({}),
    records = json.array({}),
  }
end

---A small manifest an addon might write: one config type.
---@param namespace string Its namespace.
---@param requires table<string, string>? What it requires.
---@return table manifest The manifest.
function conformance.manifest(namespace, requires)
  return {
    namespace = namespace,
    version = "1.0.0",
    api = 1,
    title = "Addon " .. namespace,
    requires = requires,
    types = {
      thing = {
        schema = 1,
        authority = "config",
        fields = { name = { type = "string" } },
      },
    },
  }
end

---Busted's functions, which only a spec file's environment has: a module it
---requires sees the plain global table.
---@class spec.Busted
---@field describe fun(name: string, fn: fun())
---@field it fun(name: string, fn: fun())
---@field before_each fun(fn: fun())
---@field after_each fun(fn: fun())

---Runs a list of cases on every platform, a `describe` per platform.
---@param busted spec.Busted The spec file's `describe`, `it`, `before_each` and `after_each`.
---@param title string What the cases cover.
---@param cases { name: string, origins: boolean?, run: fun(world: spec.ConformanceWorld) }[] The cases. One with `origins` runs only where the platform names the calling code.
function conformance.run(busted, title, cases)
  local describe, it, before_each, after_each = busted.describe, busted.it, busted.before_each, busted.after_each
  for _, name in ipairs(conformance.PLATFORMS) do
    describe(title .. " on " .. name, function()
      local world

      before_each(function()
        world = conformance.boot(name)
      end)

      after_each(function()
        if world then
          world.finish()
        end
        world = nil
      end)

      for _, case in ipairs(cases) do
        if not case.origins or name == "fivem" then
          it(case.name, function()
            case.run(world)
          end)
        end
      end
    end)
  end
end

return conformance
