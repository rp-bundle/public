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
---@param zip "fivem"|"gmod" Which zip.
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
  ---them: scripts on both sides, the page and its files.
  ---@param path string The manifest.
  ---@param resource string The resource's folder in the zip, with a trailing slash.
  ---@return table<string, true> names The set, as paths in the zip.
  local function named(path, resource)
    local names = {}
    for name in read_file(path):gmatch('"([^"]+%.[%a]+)"') do
      if name:match("%.lua$") or name:match("%.js$") or name:match("%.html$") or name:match("%.css$") then
        names[resource .. name] = true
      end
    end
    return names
  end

  it("holds exactly the files the two manifests name, the manifests and the licences", function()
    local expected = named(MANIFEST, "[rpf]/rpf/")
    for name in pairs(named(SHIM_MANIFEST, "[rpf]/rpf-ws/")) do
      expected[name] = true
    end
    expected["[rpf]/rpf/fxmanifest.lua"] = true
    expected["[rpf]/rpf-ws/fxmanifest.lua"] = true
    expected["[rpf]/rpf-ws/LICENSE.ws"] = true
    local files = shipped("fivem")
    -- The project's own licence is in both resources once it has one (#190).
    for _, licence in ipairs({ "[rpf]/rpf/LICENSE", "[rpf]/rpf-ws/LICENSE" }) do
      if files[licence] then
        expected[licence] = true
      end
    end
    assert.are.same(sorted(expected), sorted(files))
    assert.is_nil(files["[rpf]/rpf/dev.lua"], "a release never carries the smoke test's commands")
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
  ---finds a file by its path under the addon's `lua/`; the fake asks for
  ---paths under `rpf/` and runs `rpf/platform/gmod/autorun.lua` first, which
  ---the addon ships as `lua/autorun/rpf.lua`.
  ---@param side "server"|"client" Which side.
  ---@param read_paths table<string, true> Filled with every file read, as a path in the zip.
  ---@return rpf.mock.GmodWorld world The fake.
  ---@return table record What the host recorded.
  local function boot(side, read_paths)
    local gmod = dofile(support.path("lua/platform/mock/gmod.lua"))
    local host, record = fake_host()
    local function read(relative)
      local path = relative == "platform/gmod/autorun.lua" and "lua/autorun/rpf.lua" or "lua/rpf/" .. relative
      local source = read_file(ADDON .. path)
      read_paths["rpf/" .. path] = true
      return source
    end
    local world = gmod.install(side, host, {
      read = read,
      convars = { rpf_ws_url = "wss://portal.example/ws", rpf_api_key = "rpf_sk_release" },
    })
    installed = world
    world:boot()
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

  it("ships exactly the files the two sides load, and the licence", function()
    local loaded = {}
    local server = boot("server", loaded)
    server:uninstall()
    installed = nil
    boot("client", loaded)
    local files = shipped("gmod")
    if files["rpf/LICENSE"] then
      loaded["rpf/LICENSE"] = true
    end
    assert.are.same(sorted(loaded), sorted(files))
    assert.is_nil(files["rpf/lua/rpf/platform/gmod/dev.lua"], "its presence alone turns the smoke test's commands on")
  end)
end)

describe("the txAdmin recipe", function()
  it("installs this release's FiveM zip, with OneSync on and both resources ensured", function()
    local recipe = read_file(DIR .. "/rpf-txadmin-recipe.yaml")
    local zip = "https://github.com/Sampleeeee/rp-framework/releases/download/v"
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
    for _, line in ipairs({ 'set rpf_url ""', 'set rpf_api_key ""', "ensure rpf-ws", "ensure rpf\n" }) do
      assert.truthy(recipe:find(line, 1, true), line)
    end
  end)
end)
