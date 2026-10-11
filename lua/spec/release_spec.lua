-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- A release's zips, unpacked (H7): the files a server owner installs, booted
-- on the same fake engine globals the adapters' own suites use, so what
-- ships is proved to load and to say `Hello` as the release, not only to
-- exist. The adapters' suites run the repository's tree; this runs the
-- packaged one, which is where a file the packaging forgot, or one it
-- should never ship (`dev.lua`), would show.
--
-- `dev/verify-addon-release` unpacks the zips and runs this with
-- `RPF_RELEASE_DIR` naming where, and `RPF_RELEASE_VERSION` the version
-- the release is. Without them, as in the ordinary suite, it is pending.

local support = require("spec.support")

local DIR = os.getenv("RPF_RELEASE_DIR")
local VERSION = os.getenv("RPF_RELEASE_VERSION")

if not DIR or not VERSION then
  pending("a release's zips (dev/verify-addon-release sets RPF_RELEASE_DIR and RPF_RELEASE_VERSION)", function() end)
  return
end

local RESOURCES = DIR .. "/fivem/[rpf]/"
local ADDON = DIR .. "/gmod/rpf/"
local BRIDGE = DIR .. "/gmod/rpf_darkrp/"
local KIT = DIR .. "/kit/"

---Reads a whole file, failing like a missing file does.
---@param path string The file.
---@return string contents Its contents.
local function read_file(path)
  local file = io.open(path, "rb")
  if not file then
    error("no such file: " .. path)
  end
  local contents = file:read("*a")
  file:close()
  return contents
end

---Every file in one of the zips, as the zip names them, directories left
---out. `dev/verify-addon-release` writes the listing beside the unpacked
---tree, because Lua cannot list a directory.
---@param zip "fivem"|"gmod"|"kit" Which zip.
---@return table<string, true> files The set.
local function shipped(zip)
  local files = {}
  for line in read_file(DIR .. "/" .. zip .. ".files"):gmatch("[^\n]+") do
    if line:sub(-1) ~= "/" then
      files[line] = true
    end
  end
  return files
end

---The keys of a set, sorted, so two sets compare as lists with a readable
---difference.
---@param set table<string, true> The set.
---@return string[] keys The keys.
local function sorted(set)
  local keys = {}
  for key in pairs(set) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

---The example addons the repository has, by name (`lua/examples/<name>/`),
---which the addon kit must hold every one of. `dev/verify-addon-release`
---lists them, because Lua cannot list a directory.
---@return string[] names The names, sorted.
local function examples()
  local names = {}
  for line in read_file(DIR .. "/examples.list"):gmatch("[^\n]+") do
    names[#names + 1] = line
  end
  table.sort(names)
  return names
end

---A host that records what the fakes hand it.
---@return table host The host.
---@return table record What it recorded.
local function fake_host()
  local record = { time = support.EPOCH_MS, kv = {}, sent = {}, connects = {}, to_server = {}, logs = {} }
  local host = {
    now = function()
      return record.time
    end,
    kv_get = function(key)
      return record.kv[key]
    end,
    kv_set = function(key, value)
      record.kv[key] = value
    end,
    http_request = function() end,
    connect = function(id, url)
      record.connects[#record.connects + 1] = { id = id, url = url }
    end,
    close = function() end,
    send = function(id, text)
      record.sent[#record.sent + 1] = { id = id, text = text }
      return true
    end,
    kick = function() end,
    notify = function() end,
    to_client = function() end,
    to_server = function(name, payload)
      record.to_server[#record.to_server + 1] = { name = name, payload = payload }
    end,
    log = function(level, message)
      record.logs[#record.logs + 1] = { level = level, message = message }
    end,
  }
  return host, record
end

---The `Hello` a server sent, decoded with the core it loaded.
---@param record table What the host recorded.
---@return table hello The frame.
local function hello(record)
  for _, sent in ipairs(record.sent) do
    local frame = support.core.json.decode(sent.text)
    if frame and frame.type == "hello" then
      return frame
    end
  end
  error("the server sent no hello")
end

describe("the FiveM zip", function()
  local MANIFEST = RESOURCES .. "rpf/fxmanifest.lua"
  local SHIM_MANIFEST = RESOURCES .. "rpf-ws/fxmanifest.lua"
  local QBOX_MANIFEST = RESOURCES .. "rpf-qbox/fxmanifest.lua"

  ---Every global the fakes and the resource set, taken away after each test.
  ---@type table<string, true>
  local before = {}

  before_each(function()
    before = {}
    for key in pairs(_G) do
      before[key] = true
    end
  end)

  after_each(function()
    for key in pairs(_G) do
      if not before[key] then
        rawset(_G, key, nil)
      end
    end
  end)

  ---Loads one side of the packaged `rpf` resource as FiveM would: the fakes,
  ---then every script its manifest names, from the unpacked zip.
  ---@param side "server"|"client" Which side.
  ---@param convars table<string, string>? The convars.
  ---@return table driver The fakes' driver.
  ---@return table record What the host recorded.
  local function load_side(side, convars)
    rawset(_G, "rpf", nil)
    local mock = dofile(support.path("lua/platform/mock/init.lua"))
    local fakes = dofile(support.path("lua/platform/mock/fivem.lua")).bind(mock)
    local host, record = fake_host()
    local driver = fakes[side](_G, host, 1, convars or {})
    for _, script in ipairs(fakes.scripts(read_file(MANIFEST), side)) do
      dofile(RESOURCES .. "rpf/" .. script)
    end
    support.core = rpf
    return driver, record
  end

  ---Every quoted file name in a manifest, as `dev/fivem-resources` reads
  ---them: scripts on both sides, the page and its files. A script in
  ---another resource (`@ox_lib/init.lua`) is that resource's, never copied.
  ---@param path string The manifest.
  ---@param resource string The resource's folder in the zip, with a trailing slash.
  ---@return table<string, true> names The set, as paths in the zip.
  local function named(path, resource)
    local names = {}
    for name in read_file(path):gmatch('"([^"@][^"]*%.[%a]+)"') do
      if name:match("%.lua$") or name:match("%.js$") or name:match("%.html$") or name:match("%.css$") then
        names[resource .. name] = true
      end
    end
    return names
  end

  it("holds exactly the files the three manifests name, the manifests and the licences", function()
    local expected = named(MANIFEST, "[rpf]/rpf/")
    for name in pairs(named(SHIM_MANIFEST, "[rpf]/rpf-ws/")) do
      expected[name] = true
    end
    for name in pairs(named(QBOX_MANIFEST, "[rpf]/rpf-qbox/")) do
      expected[name] = true
    end
    expected["[rpf]/rpf/fxmanifest.lua"] = true
    expected["[rpf]/rpf-ws/fxmanifest.lua"] = true
    expected["[rpf]/rpf-qbox/fxmanifest.lua"] = true
    expected["[rpf]/rpf-ws/THIRD-PARTY-NOTICES"] = true
    -- The project's own licence is in every resource (#190).
    for _, licence in ipairs({ "[rpf]/rpf/LICENSE", "[rpf]/rpf-ws/LICENSE", "[rpf]/rpf-qbox/LICENSE" }) do
      expected[licence] = true
    end
    local files = shipped("fivem")
    assert.are.same(sorted(expected), sorted(files))
    assert.is_nil(files["[rpf]/rpf/dev.lua"], "a release never carries the smoke test's commands")
    for name in pairs(files) do
      assert.is_nil(name:find("ox_lib", 1, true), "ox_lib is a prerequisite, never bundled: " .. name)
    end
  end)

  it("carries the MIT licence in every resource, and the notice of what the shim bundles", function()
    for _, resource in ipairs({ "rpf", "rpf-ws", "rpf-qbox" }) do
      local licence = read_file(RESOURCES .. resource .. "/LICENSE")
      assert.is_truthy(licence:find("^MIT License"), resource .. " is licensed MIT")
      assert.is_truthy(licence:find("Permission is hereby granted, free of charge", 1, true), resource)
    end
    -- ws is bundled into rpf-ws.js and MIT requires its notice to travel with the copy.
    local notices = read_file(RESOURCES .. "rpf-ws/THIRD-PARTY-NOTICES")
    assert.is_truthy(notices:find("\nws 8%.[%d%.]+ %(MIT%)\n"), "names ws, its version and licence")
    assert.is_truthy(notices:find("Permission is hereby granted, free of charge", 1, true), "carries ws's licence text")
  end)

  it("starts the server from the packaged files and says Hello as this release", function()
    local driver, record = load_side("server", { rpf_url = "wss://portal.example/ws", rpf_api_key = "rpf_sk_release" })
    driver.start()
    assert.are.equal(1, #record.connects, "the core connects")
    assert.are.equal("wss://portal.example/ws", record.connects[1].url)
    driver.socket_open(record.connects[1].id)
    local frame = hello(record)
    assert.are.equal(VERSION, frame.core_version)
    assert.are.equal("fivem", frame.engine)
    assert.are.equal(rpf.protocol.VERSION, frame.protocol)
  end)

  it("starts the client from the packaged files", function()
    local driver, record = load_side("client")
    driver.start()
    assert.are.equal("rpf:client_ready", record.to_server[1].name)
  end)

  it("starts every example in the addon kit from its packaged files, beside the packaged core", function()
    local driver = load_side("server", { rpf_url = "wss://portal.example/ws", rpf_api_key = "rpf_sk_release" })
    driver.start()
    local scripts = dofile(support.path("lua/platform/mock/fivem.lua")).scripts
    for _, name in ipairs(examples()) do
      local folder = KIT .. "fivem/[rpf-examples]/" .. name .. "/"
      -- Each resource is a Lua state of its own, reaching `rpf` through its
      -- export as itself.
      local env = setmetatable({
        exports = { rpf = { api = function()
          return driver.resource(name)
        end } },
      }, { __index = _G })
      for _, script in ipairs(scripts(read_file(folder .. "fxmanifest.lua"), "server")) do
        local source = read_file(folder .. script)
        local chunk
        if rawget(_G, "setfenv") then
          chunk = assert(loadstring(source, "=" .. script))
          setfenv(chunk, env)
        else
          chunk = assert(load(source, "=" .. script, "t", env))
        end
        chunk()
      end
      assert.is_table(rawget(env, name), name .. " loaded, in its own state")
      -- Registered and waiting for staff: nothing installs an example.
      local state = driver.resource(name).addons.state(name)
      assert.are.equal("not_installed", state, name)
    end
  end)

  it("starts the Qbox bridge's server from the packaged files, beside the packaged core", function()
    local driver = load_side("server", { rpf_url = "wss://portal.example/ws", rpf_api_key = "rpf_sk_release" })
    driver.start()
    -- Another resource's Lua state: its own globals, the engine's natives,
    -- and `exports` reaching `rpf`'s API as `rpf-qbox` and the two
    -- resources it bridges, which are not started.
    local env = setmetatable({
      exports = { rpf = { api = function()
        return driver.resource("rpf-qbox")
      end }, qbx_core = {}, ox_inventory = {} },
    }, { __index = _G })
    for _, script in ipairs(dofile(support.path("lua/platform/mock/fivem.lua")).scripts(read_file(QBOX_MANIFEST), "server")) do
      local source = read_file(RESOURCES .. "rpf-qbox/" .. script)
      local chunk
      if rawget(_G, "setfenv") then
        chunk = assert(loadstring(source, "=" .. script))
        setfenv(chunk, env)
      else
        chunk = assert(load(source, "=" .. script, "t", env))
      end
      chunk()
    end
    assert.is_table(rawget(env, "rpf_qbox"), "bridge.lua loaded, in the bridge's own state")
    assert.is_nil(rawget(_G, "rpf_qbox"))
    -- The core took it: a second bridge is refused as one already is.
    local again = {
      rpf.api.bridge.register({
        name = "other",
        version = "1",
        contract = { major = 1, minor = 0 },
        provides = {},
        running = function()
          return false
        end,
      }),
    }
    assert.are.same({ nil, "registered" }, again)
  end)
end)

describe("the Gmod zip", function()
  ---The installed fake, so `after_each` can put the globals back.
  ---@type rpf.mock.GmodWorld?
  local installed = nil

  after_each(function()
    if installed then
      installed:uninstall()
      installed = nil
    end
  end)

  ---Boots one side of the packaged addon on the fake Gmod globals. Gmod
  ---finds a file by its path under some addon's `lua/`; the fake asks for
  ---paths under `rpf/` and runs `rpf/platform/gmod/autorun.lua` first, which
  ---the addon ships as `lua/autorun/rpf.lua`. With `bridge`, the packaged
  ---`rpf_darkrp` addon is installed beside it, and Gmod runs its server
  ---autorun file too before `Initialize`.
  ---@param side "server"|"client" Which side.
  ---@param read_paths table<string, true> Filled with every file read, as a path in the zip.
  ---@param bridge boolean? Whether `rpf_darkrp` is installed too.
  ---@param kit string[]? Example addons from the addon kit installed beside it, on the server.
  ---@return rpf.mock.GmodWorld world The fake.
  ---@return table record What the host recorded.
  local function boot(side, read_paths, bridge, kit)
    local gmod = dofile(support.path("lua/platform/mock/gmod.lua"))
    local host, record = fake_host()
    local function read(relative)
      local root, path = ADDON, "lua/rpf/" .. relative
      if relative == "platform/gmod/autorun.lua" then
        path = "lua/autorun/rpf.lua"
      elseif bridge and relative == "autorun/server/rpf_darkrp.lua" then
        root, path = BRIDGE, "lua/" .. relative
      elseif bridge and relative:match("^rpf_darkrp/") then
        root, path = BRIDGE, "lua/" .. relative
      end
      local owner = root == BRIDGE and "rpf_darkrp/" or "rpf/"
      for _, name in ipairs(kit or {}) do
        local autorun = relative:match("^autorun/[%w_/]*%.lua$") and relative:match("([%w_]+)%.lua$")
        if relative:match("^" .. name .. "/") or autorun == name then
          root, path, owner = KIT .. "gmod/" .. name .. "/", "lua/" .. relative, "gmod/" .. name .. "/"
        end
      end
      local source = read_file(root .. path)
      read_paths[owner .. path] = true
      return source
    end
    local world = gmod.install(side, host, {
      read = read,
      convars = { rpf_ws_url = "wss://portal.example/ws", rpf_api_key = "rpf_sk_release" },
    })
    installed = world
    if kit then
      -- Gmod runs every addon's autorun files, then `Initialize`.
      world.include("rpf/platform/gmod/autorun.lua")
      for _, name in ipairs(kit) do
        local server_only = KIT .. "gmod/" .. name .. "/lua/autorun/server/" .. name .. ".lua"
        local found = io.open(server_only, "rb")
        if found then
          found:close()
        end
        world.include(found and "autorun/server/" .. name .. ".lua" or "autorun/" .. name .. ".lua")
      end
      world:run_hook("Initialize")
      world:run_hook("InitPostEntity")
    elseif bridge then
      world.include("rpf/platform/gmod/autorun.lua")
      world.include("autorun/server/rpf_darkrp.lua")
      world:run_hook("Initialize")
      world:run_hook("InitPostEntity")
    else
      world:boot()
    end
    support.core = world.core
    return world, record
  end

  it("starts the server from the packaged files and says Hello as this release", function()
    local world, record = boot("server", {})
    assert.are.equal(1, #record.connects, "the core connects")
    world:socket_open(record.connects[1].id)
    local frame = hello(record)
    assert.are.equal(VERSION, frame.core_version)
    assert.are.equal("gmod", frame.engine)
    assert.are.equal(world.core.protocol.VERSION, frame.protocol)
  end)

  it("starts the client from the packaged files", function()
    local _, record = boot("client", {})
    assert.are.equal("rpf:client_ready", record.to_server[1].name)
  end)

  it("starts the DarkRP bridge from the packaged files, beside the packaged addon", function()
    local _, record = boot("server", {}, true)
    -- No DarkRP here: the bridge says so, and registers all the same.
    local said = 0
    for _, line in ipairs(record.logs) do
      if line.level == "error" and line.message:find("rpf_darkrp: DarkRP is not the gamemode", 1, true) then
        said = said + 1
      end
    end
    assert.are.equal(1, said)
    local again = {
      rawget(_G, "rpf").bridge.register({
        name = "other",
        version = "1",
        contract = { major = 1, minor = 0 },
        provides = {},
        running = function()
          return false
        end,
      }),
    }
    assert.are.same({ nil, "registered" }, again, "the core took it")
  end)

  it("starts every example in the addon kit from its packaged files, beside the packaged addon", function()
    local read = {}
    boot("server", read, false, examples())
    local api = rawget(_G, "rpf")
    for _, name in ipairs(examples()) do
      assert.are.equal("not_installed", (api.addons.state(name)), name .. " registered, and waits for staff")
      assert.is_truthy(read["gmod/" .. name .. "/lua/" .. name .. "/manifest.lua"], name .. "'s manifest came from the kit")
    end
  end)

  it("ships exactly the files the two sides load, the bridge's, and the licences", function()
    local loaded = {}
    local server = boot("server", loaded, true)
    server:uninstall()
    installed = nil
    boot("client", loaded)
    local files = shipped("gmod")
    for _, licence in ipairs({ "rpf/LICENSE", "rpf_darkrp/LICENSE" }) do
      loaded[licence] = true
    end
    assert.are.same(sorted(loaded), sorted(files))
    assert.is_nil(files["rpf/lua/rpf/platform/gmod/dev.lua"], "its presence alone turns the smoke test's commands on")
  end)
end)

describe("the addon kit", function()
  it("holds the API's annotations and every example, each laid out as its engine loads it, and nothing else", function()
    local expected = {}
    for _, file in ipairs({ "api.lua", "platform_client.lua", "platform_server.lua", "platform_shared.lua" }) do
      expected["meta/" .. file] = true
    end
    local licensed = { "meta/" }
    for _, name in ipairs(examples()) do
      local resource = "fivem/[rpf-examples]/" .. name .. "/"
      local addon = "gmod/" .. name .. "/"
      local manifest = read_file(KIT .. resource .. "fxmanifest.lua")
      expected[resource .. "fxmanifest.lua"] = true
      local client = false
      for file in manifest:gmatch('"([^"@][^"]*%.lua)"') do
        expected[resource .. file] = true
        -- The engine-neutral files are the Gmod addon's too; the FiveM entry
        -- points are not.
        if not file:match("^fivem/") then
          expected[addon .. "lua/" .. name .. "/" .. file] = true
          client = client or file == "client.lua"
        end
      end
      -- With a client file, Gmod runs the entry point on both sides.
      expected[addon .. "lua/autorun/" .. (client and "" or "server/") .. name .. ".lua"] = true
      licensed[#licensed + 1] = resource
      licensed[#licensed + 1] = addon
    end
    local files = shipped("kit")
    for _, folder in ipairs(licensed) do
      expected[folder .. "LICENSE"] = true
    end
    assert.are.same(sorted(expected), sorted(files))
  end)

  it("installs nothing for a server: no RPF resource or addon, and no credential", function()
    for name in pairs(shipped("kit")) do
      assert.is_nil(name:find("[rpf]/", 1, true), name)
      assert.is_nil(name:find("^gmod/rpf"), name)
      if name:match("%.lua$") then
        local source = read_file(KIT .. name)
        assert.is_nil(source:find("rpf_[a-z]+_[%w]+"), name .. " carries something shaped like a key")
        assert.is_nil(source:find("wss?://"), name .. " names a portal")
      end
    end
  end)
end)

describe("every Gmod addon", function()
  -- Gmod mounts every addon's `lua/` over one tree, so two addons shipping
  -- the same path collide and only one file loads; under `lua/autorun/`,
  -- that is one addon silently not starting. Each addon keeps its files
  -- under `lua/<name>/` and its one entry point at
  -- `lua/autorun/[server/]<name>.lua`.
  it("ships one autorun file, named after the addon, and no lua/ path another addon ships", function()
    local addons = {}
    for name in pairs(shipped("gmod")) do
      local addon, path = name:match("^([^/]+)/(lua/.+)$")
      if addon then
        addons[#addons + 1] = { addon = addon, path = path }
      end
    end
    for name in pairs(shipped("kit")) do
      local addon, path = name:match("^gmod/([^/]+)/(lua/.+)$")
      if addon then
        addons[#addons + 1] = { addon = addon, path = path }
      end
    end
    local owner, autoruns = {}, {}
    for _, file in ipairs(addons) do
      assert.is_nil(owner[file.path], file.path .. " ships in both " .. tostring(owner[file.path]) .. " and " .. file.addon)
      owner[file.path] = file.addon
      if file.path:match("^lua/autorun/") then
        assert.is_nil(autoruns[file.addon], file.addon .. " ships a second autorun file, " .. file.path)
        autoruns[file.addon] = file.path
        assert.truthy(
          file.path == "lua/autorun/" .. file.addon .. ".lua" or file.path == "lua/autorun/server/" .. file.addon .. ".lua",
          file.path .. " is named after " .. file.addon
        )
      else
        assert.truthy(file.path:find("lua/" .. file.addon .. "/", 1, true) == 1, file.path .. " is under lua/" .. file.addon .. "/")
      end
    end
    for _, name in ipairs({ "rpf", "rpf_darkrp" }) do
      assert.is_truthy(autoruns[name], name .. " ships an autorun file")
    end
    for _, name in ipairs(examples()) do
      assert.is_truthy(autoruns[name], name .. " ships an autorun file")
    end
  end)
end)

describe("the txAdmin recipe", function()
  it("installs this release's FiveM zip, with OneSync on and both resources ensured", function()
    local recipe = read_file(DIR .. "/rpf-txadmin-recipe.yaml")
    local zip = "https://github.com/Sampleeeee/rpf/releases/download/v"
      .. VERSION
      .. "/rpf-fivem-"
      .. VERSION
      .. ".zip"
    assert.truthy(recipe:find(zip, 1, true), "it downloads " .. zip)
    assert.is_falsy(recipe:find("@VERSION@", 1, true), "every placeholder is filled in")
    assert.truthy(recipe:find("\n$onesync: on\n", 1, true))
    -- The zip's one folder lands in resources/, as an owner unzipping it by
    -- hand puts it.
    assert.truthy(recipe:find("dest: ./resources\n", 1, true))
    assert.is_truthy(shipped("fivem")["[rpf]/rpf/fxmanifest.lua"])
    for _, line in ipairs({ 'set rpf_url ""', 'set rpf_api_key ""', "ensure ox_lib", "ensure rpf-ws", "ensure rpf\n" }) do
      assert.truthy(recipe:find(line, 1, true), line)
    end
    assert.truthy(recipe:find("ensure ox_lib\n      ensure rpf-ws\n      ensure rpf\n", 1, true), "ox_lib first")
  end)

  it("installs the ox_lib release the adapter names as its minimum, from ox_lib's own release", function()
    local recipe = read_file(DIR .. "/rpf-txadmin-recipe.yaml")
    local minimum = assert(support.read("lua/platform/fivem/ox.lua"):match('ox%.MINIMUM = "([%d.]+)"'))
    local zip = "https://github.com/overextended/ox_lib/releases/download/v" .. minimum .. "/ox_lib.zip"
    assert.truthy(recipe:find(zip, 1, true), "it downloads " .. zip)
  end)
end)
