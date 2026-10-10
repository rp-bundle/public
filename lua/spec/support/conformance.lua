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
---conformance suite is meant to reuse this harness with a bridge in place of
---an addon.
---@class spec.conformance
---@field PLATFORMS string[] Every platform a case runs on.
local conformance = {}

local support = require("spec.support")

conformance.PLATFORMS = { "mock", "fivem", "gmod" }

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
---had pushed it.
---@param entries table[] The section, built with `conformance.installed`.
function World:install(entries)
  self.version = (self.version or 0) + 1
  local json = self.core.json
  local snapshot = assert(json.decode(assert(json.encode({
    settings = json.object({}),
    addons = json.array(entries),
  }))))
  assert(self.core.config.apply(self.server_platform, self.version, "h" .. self.version, snapshot))
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

---A host for a mock platform: a clock the world moves, storage, and a log;
---the socket and HTTP go nowhere, since the cases install addons by config.
---@param world spec.ConformanceWorld The world, whose `time` is the clock.
---@return table host The host.
local function host_for(world)
  local kv = {}
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
    connect = function() end,
    close = function() end,
    send = function()
      return true
    end,
    kick = function() end,
    notify = function() end,
    to_client = function() end,
    to_server = function() end,
    log = function(level, message)
      world.logs[#world.logs + 1] = { level = level, message = message }
    end,
  }
end

---A fresh world, not booted.
---@param name string The platform.
---@return spec.ConformanceWorld world The world.
local function new_world(name)
  return setmetatable({ platform_name = name, logs = {}, time = support.EPOCH_MS, origins = false }, World)
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
---@return spec.ConformanceWorld world The world.
local function boot_mock()
  local world = new_world("mock")
  local core = support.load_core("server")
  local mock = dofile(support.path("lua/platform/mock/init.lua"))
  local p = mock.server(host_for(world), 1)
  core.start_server(p, { url = "wss://portal.test/ws", api_key = "rpf_sk_conformance" })
  world.core, world.server_platform, world.api = core, p, assert(p.exposed)
  world.view = function()
    return world.api
  end
  world.run_due = p.run_due
  world.next_due = p.next_due
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
---@return spec.ConformanceWorld world The world.
local function boot_fivem()
  local world = new_world("fivem")
  world.origins = true
  rawset(_G, "rpf", nil)
  local before = global_names()
  local mock = dofile(support.path("lua/platform/mock/init.lua"))
  local fakes = dofile(support.path("lua/platform/mock/fivem.lua")).bind(mock)
  local host = host_for(world)
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
---@return spec.ConformanceWorld world The world.
local function boot_gmod()
  local world = new_world("gmod")
  local gmod = dofile(support.path("lua/platform/mock/gmod.lua"))
  local fake = gmod.install("server", host_for(world), {
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
  world.finish = function()
    fake:uninstall()
  end
  return world
end

---Boots a game server on a platform.
---@param name string One of `PLATFORMS`.
---@return spec.ConformanceWorld world The world, booted and started.
function conformance.boot(name)
  local world
  if name == "mock" then
    world = boot_mock()
  elseif name == "fivem" then
    world = boot_fivem()
  else
    world = boot_gmod()
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
