-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The addon registry (`rpf.addons`, J2): manifests checked as they register,
-- declared to the portal after every `Welcome`, and each addon run only while
-- the config installs and enables exactly the manifest it registered.

local support = require("spec.support")

---A small valid manifest.
---@param namespace string Its namespace.
---@param version string? Its release.
---@param requires table<string, string>? What it requires.
---@return table manifest The manifest, as an author writes it.
local function manifest(namespace, version, requires)
  return {
    namespace = namespace,
    version = version or "1.0.0",
    api = 1,
    title = "Addon " .. namespace,
    requires = requires,
    types = {
      thing = {
        schema = 1,
        authority = "config",
        fields = { name = { type = "string" }, size = { type = "number", default = 2 } },
      },
    },
  }
end

---Handlers that record what the core ran, in one shared log.
---@param namespace string The addon.
---@param ran string[] The log.
---@param fail boolean? Whether `start` throws.
---@return rpf.addons.Handlers handlers The handlers.
local function recording(namespace, ran, fail)
  return {
    start = function()
      ran[#ran + 1] = "start " .. namespace
      if fail then
        error("boom")
      end
    end,
    stop = function()
      ran[#ran + 1] = "stop " .. namespace
    end,
  }
end

---One installed addon as the config's `addons` section carries it, with the
---manifest as the portal stores it (round-tripped through JSON).
---@param m table The manifest.
---@param enabled boolean? Whether it is enabled; true unless false.
---@return table entry The section entry.
local function installed(m, enabled)
  local json = rpf.json
  local checked = assert(rpf.manifest.check(m))
  return {
    namespace = m.namespace,
    version = m.version,
    hash = "sha256:" .. m.namespace .. m.version,
    enabled = enabled ~= false,
    manifest = assert(json.decode(assert(json.encode(checked)))),
    types = json.object({}),
    records = json.array({
      { id = "0000000d-0000-4000-8000-00000000000d", type = m.namespace .. ".thing", revision = 1, fields = { name = "a", size = 2 } },
    }),
  }
end

local version = 0

---Applies a config whose `addons` section is `entries`.
---@param p spec.FakePlatform The platform.
---@param entries table[] The section.
local function configure(p, entries)
  version = version + 1
  local json = rpf.json
  local snapshot = assert(json.decode(assert(json.encode({
    settings = json.object({}),
    addons = json.array(entries),
  }))))
  assert.is_true((rpf.config.apply(p, version, "h" .. version, snapshot)))
end

---The `declare_addons` frames sent, in order, those `support.connected`
---answered included.
---@param p spec.FakePlatform The platform.
---@return rpf.Frame[] frames The frames.
local function declarations(p)
  local out = {}
  for _, text in ipairs(p.sent) do
    local frame = assert(rpf.protocol.decode(rpf.protocol.SERVER_TO_PORTAL, text))
    if frame.type == "declare_addons" then
      out[#out + 1] = frame
    end
  end
  return out
end

describe("rpf.addons", function()
  local p

  before_each(function()
    support.load_core()
    p = support.fake_platform()
  end)

  describe("registering", function()
    it("refuses a manifest the shared rules refuse, naming the rule, and keeps nothing", function()
      local bad = manifest("acme_kit")
      bad.version = "1"
      local ok, refusal = rpf.addons.register(bad)
      assert.is_nil(ok)
      assert.are.same({ error = "version", path = "version" }, refusal)
      assert.is_nil(rpf.addons.state("acme_kit"))
    end)

    it("refuses one addon more than a server may install", function()
      for i = 1, rpf.manifest.MAX_ADDONS_PER_SERVER do
        assert.is_true(rpf.addons.register(manifest(string.format("acme_%02d", i))))
      end
      local ok, refusal = rpf.addons.register(manifest("acme_more"))
      assert.is_nil(ok)
      assert.are.equal("too_many", assert(refusal).error)
      -- Registering one already loaded again is not one more.
      assert.is_true(rpf.addons.register(manifest("acme_01")))
    end)
  end)

  describe("declaring", function()
    it("declares every loaded manifest after each Welcome, as the portal reads it", function()
      rpf.addons.register(manifest("acme_kit"))
      support.connected(p)
      local sent = declarations(p)
      assert.are.equal(1, #sent)
      assert.are.same({ "acme_kit" }, sent[1].loaded)
      assert.are.same(assert(rpf.manifest.check(manifest("acme_kit"))), sent[1].manifests[1])
    end)

    it("tells the portal when none are loaded, so it forgets their proposals", function()
      support.connected(p)
      local sent = declarations(p)
      assert.are.equal(1, #sent)
      assert.are.same({}, sent[1].loaded)
      assert.are.same({}, sent[1].manifests)
    end)

    it("splits many manifests across frames, each naming every loaded addon", function()
      for i = 1, 9 do
        rpf.addons.register(manifest(string.format("acme_%02d", i)))
      end
      support.connected(p)
      local sent = declarations(p)
      assert.are.equal(2, #sent)
      assert.are.equal(rpf.addons.MAX_MANIFESTS_PER_DECLARE, #sent[1].manifests)
      assert.are.equal(1, #sent[2].manifests)
      assert.are.equal(9, #sent[1].loaded)
      assert.are.same(sent[1].loaded, sent[2].loaded)
    end)

    it("declares again when an addon registers once connected, and is pending once acknowledged", function()
      support.connected(p)
      rpf.addons.register(manifest("acme_kit"))
      local sent = declarations(p)
      assert.are.equal(2, #sent)
      assert.are.equal("not_installed", (rpf.addons.state("acme_kit")))
      p.deliver(support.portal_frame("ack", { re = sent[2].id }))
      assert.are.equal("pending", (rpf.addons.state("acme_kit")))
    end)
  end)

  describe("running", function()
    it("starts an addon installed and enabled at its manifest, and stops it when that changes", function()
      local ran, heard = {}, {}
      rpf.events.on("addons.state", function(change)
        heard[#heard + 1] = change.state
      end)
      rpf.addons.register(manifest("acme_kit"), recording("acme_kit", ran))
      support.connected(p)

      configure(p, { installed(manifest("acme_kit")) })
      assert.are.equal("active", (rpf.addons.state("acme_kit")))
      assert.are.same({ "start acme_kit" }, ran)

      configure(p, { installed(manifest("acme_kit"), false) })
      assert.are.equal("disabled", (rpf.addons.state("acme_kit")))
      assert.are.same({ "start acme_kit", "stop acme_kit" }, ran)

      -- Another release installed than the one loaded: the files and the
      -- portal disagree.
      configure(p, { installed(manifest("acme_kit", "1.1.0")) })
      local state, reason = rpf.addons.state("acme_kit")
      assert.are.equal("mismatch", state)
      assert.truthy(assert(reason):find("1.1.0", 1, true))

      -- Uninstalled: the server declared it, so it is a proposal again.
      configure(p, {})
      assert.are.equal("pending", (rpf.addons.state("acme_kit")))
      assert.are.same({ "not_installed", "pending", "active", "disabled", "mismatch", "pending" }, heard)
    end)

    it("tells an empty array from an empty object, as the portal's hash does", function()
      local json = rpf.json
      assert.is_false(rpf.addons.same(json.array({}), json.object({})))
      assert.is_true(rpf.addons.same(json.array({}), json.array({})))
      assert.is_true(rpf.addons.same({ a = json.object({}) }, { a = json.object({}) }))
      assert.is_false(rpf.addons.same({ a = json.array({}) }, { a = json.object({}) }))
    end)

    it("reads a whole double the portal sends back as the integer the addon wrote", function()
      rpf.addons.register(manifest("acme_kit"))
      support.connected(p)
      local entry = installed(manifest("acme_kit"))
      entry.manifest.api = 1.0
      configure(p, { entry })
      assert.are.equal("active", (rpf.addons.state("acme_kit")))
    end)

    it("does not run an addon for an API major the core does not serve", function()
      local m = manifest("acme_kit")
      m.api = 2
      rpf.addons.register(m)
      support.connected(p)
      configure(p, { installed(m) })
      assert.are.equal("api", (rpf.addons.state("acme_kit")))
    end)

    it("starts requirements first, holds back what requires an inactive addon, and stops dependents first", function()
      local ran = {}
      rpf.addons.register(manifest("acme_zoo", nil, { acme_base = "^1.0.0" }), recording("acme_zoo", ran))
      rpf.addons.register(manifest("acme_base"), recording("acme_base", ran))
      support.connected(p)

      configure(p, { installed(manifest("acme_zoo", nil, { acme_base = "^1.0.0" })) })
      assert.are.equal("requires", (rpf.addons.state("acme_zoo")))
      assert.are.same({}, ran)

      configure(p, {
        installed(manifest("acme_base")),
        installed(manifest("acme_zoo", nil, { acme_base = "^1.0.0" })),
      })
      assert.are.same({ "start acme_base", "start acme_zoo" }, ran)

      configure(p, {
        installed(manifest("acme_base"), false),
        installed(manifest("acme_zoo", nil, { acme_base = "^1.0.0" })),
      })
      assert.are.same({ "start acme_base", "start acme_zoo", "stop acme_zoo", "stop acme_base" }, ran)
      assert.are.equal("requires", (rpf.addons.state("acme_zoo")))
    end)

    it("keeps an addon whose start throws inactive, and starts the rest", function()
      local ran = {}
      rpf.addons.register(manifest("acme_bad"), recording("acme_bad", ran, true))
      rpf.addons.register(manifest("acme_good"), recording("acme_good", ran))
      support.connected(p)
      configure(p, { installed(manifest("acme_bad")), installed(manifest("acme_good")) })
      assert.are.equal("failed", (rpf.addons.state("acme_bad")))
      assert.are.equal("active", (rpf.addons.state("acme_good")))
      assert.are.equal(1, #p.logged("error", "the start handler of acme_bad failed"))
      -- A declaration being acknowledged is no reason to try again.
      local sent = declarations(p)
      p.deliver(support.portal_frame("ack", { re = sent[#sent].id }))
      assert.are.equal("failed", (rpf.addons.state("acme_bad")))
    end)

    it("starts an addon once when its start handler registers another", function()
      local starts = 0
      rpf.addons.register(manifest("acme_kit"), {
        start = function()
          starts = starts + 1
          rpf.addons.register(manifest("acme_late"))
        end,
      })
      support.connected(p)
      configure(p, { installed(manifest("acme_kit")), installed(manifest("acme_late")) })
      assert.are.equal(1, starts)
      assert.are.equal("active", (rpf.addons.state("acme_kit")))
      assert.are.equal("active", (rpf.addons.state("acme_late")))
    end)

    it("replaces an active addon a start handler registers again only once its old registration stopped", function()
      local ran = {}
      rpf.addons.register(manifest("acme_base"), recording("acme_base", ran))
      rpf.addons.register(manifest("acme_kit"), {
        start = function()
          ran[#ran + 1] = "start acme_kit"
          rpf.addons.register(manifest("acme_base", "1.1.0"), recording("acme_base new", ran))
        end,
      })
      support.connected(p)
      configure(p, { installed(manifest("acme_base")), installed(manifest("acme_kit")) })
      -- The old registration started and stopped; the new one never ran,
      -- being a release the portal did not install.
      assert.are.same({ "start acme_base", "start acme_kit", "stop acme_base" }, ran)
      assert.are.equal("mismatch", (rpf.addons.state("acme_base")))
    end)

    it("lets a start handler read its config records", function()
      local seen = nil
      rpf.addons.register(manifest("acme_kit"), {
        start = function()
          seen = #rpf.addons.config_records("acme_kit.thing")
        end,
      })
      support.connected(p)
      configure(p, { installed(manifest("acme_kit")) })
      assert.are.equal(1, seen)
    end)

    it("stops what requires an addon before the addon, when it registers another manifest", function()
      local ran = {}
      rpf.addons.register(manifest("acme_zoo", nil, { acme_base = "^1.0.0" }), recording("acme_zoo", ran))
      rpf.addons.register(manifest("acme_base"), recording("acme_base", ran))
      support.connected(p)
      configure(p, {
        installed(manifest("acme_base")),
        installed(manifest("acme_zoo", nil, { acme_base = "^1.0.0" })),
      })
      rpf.addons.register(manifest("acme_base", "1.1.0"), recording("acme_base", ran))
      assert.are.same({ "start acme_base", "start acme_zoo", "stop acme_zoo", "stop acme_base" }, ran)
      assert.are.equal("mismatch", (rpf.addons.state("acme_base")))
      assert.are.equal("requires", (rpf.addons.state("acme_zoo")))
    end)

    it("restarts what requires an addon after the addon reloads with the same manifest", function()
      local ran = {}
      rpf.addons.register(manifest("acme_zoo", nil, { acme_base = "^1.0.0" }), recording("acme_zoo", ran))
      rpf.addons.register(manifest("acme_base"), recording("acme_base", ran))
      support.connected(p)
      configure(p, {
        installed(manifest("acme_base")),
        installed(manifest("acme_zoo", nil, { acme_base = "^1.0.0" })),
      })
      rpf.addons.register(manifest("acme_base"), recording("acme_base again", ran))
      assert.are.same({
        "start acme_base",
        "start acme_zoo",
        "stop acme_zoo",
        "stop acme_base",
        "start acme_base again",
        "start acme_zoo",
      }, ran)
      assert.are.equal("active", (rpf.addons.state("acme_zoo")))
      assert.are.equal(1, #declarations(p) - 1, "a reload of the same manifest is declared again, once")
    end)

    it("calls a FiveM function reference as a handler, and never skips one", function()
      local started = 0
      local reference = setmetatable({ __cfx_functionReference = "other:1" }, {
        __call = function()
          started = started + 1
        end,
      })
      assert.is_true(rpf.addons.register(manifest("acme_kit"), { start = reference --[[@as fun()]] }))
      support.connected(p)
      configure(p, { installed(manifest("acme_kit")) })
      assert.are.equal(1, started)
    end)

    it("keeps a refusal logged before the core started, and writes it out at start", function()
      support.load_core()
      local bad = manifest("acme_kit")
      bad.version = "1"
      assert.is_nil(rpf.addons.register(bad))
      local fresh = support.fake_platform()
      rpf.start_server(fresh, { url = "ws://portal", api_key = "rpf_test_secret" })
      local found = false
      for _, line in ipairs(fresh.logs) do
        found = found or (line.level == "error" and line.message:find("manifest was refused", 1, true) ~= nil)
      end
      assert.is_true(found)
    end)

    it("keeps the origin of a registration a handler makes, and unloads it with the origin", function()
      rpf.addons.from("acme_res", function()
        rpf.addons.register(manifest("acme_kit"), {
          start = function()
            rpf.addons.register(manifest("acme_late"))
          end,
        })
      end)
      support.connected(p)
      configure(p, { installed(manifest("acme_kit")), installed(manifest("acme_late")) })
      assert.are.equal("active", (rpf.addons.state("acme_late")))
      rpf.addons.unload_origin("acme_res")
      assert.is_nil(rpf.addons.state("acme_kit"))
      assert.is_nil(rpf.addons.state("acme_late"))
      local last = declarations(p)[#declarations(p)]
      assert.are.same({}, last.loaded, "the portal is told they are gone")
    end)

    it("lets code nobody can name act under any namespace, and an addon's code only under its own", function()
      rpf.addons.register(manifest("acme_kit"))
      assert.is_true(rpf.addons.may_use("acme_kit.ping"))
      assert.is_true(rpf.addons.may_use("scripts.ping"))
      rpf.addons.from("acme_other", function()
        assert.is_false(rpf.addons.may_use("acme_kit.ping"))
        assert.is_true(rpf.addons.may_use("acme_free.ping"), "not a loaded addon's")
      end)
    end)

    it("gives an active addon's types and config records, and nothing while it is not", function()
      rpf.addons.register(manifest("acme_kit"))
      support.connected(p)
      assert.are.same({}, rpf.addons.config_records("acme_kit.thing"))
      local entry = installed(manifest("acme_kit"))
      entry.types = { ["acme_kit.old"] = { schema = 3, authority = "config", fields = rpf.json.object({}) } }
      configure(p, { entry })
      local records = rpf.addons.config_records("acme_kit.thing")
      assert.are.equal(1, #records)
      assert.are.equal("a", records[1].fields.name)
      assert.are.equal(1, rpf.addons.definition("acme_kit.thing").schema)
      assert.are.equal(3, rpf.addons.definition("acme_kit.old").schema)
      assert.is_nil(rpf.addons.definition("acme_kit.none"))
      assert.is_nil(rpf.addons.definition("acme_other.thing"))
    end)
  end)
end)
