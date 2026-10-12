---@diagnostic disable: redundant-parameter
local support = require("spec.support")
local PLAYER = "00000002-0000-4000-8000-000000000002"
local ID = "00000003-0000-4000-8000-000000000003"

---An installed world config type with a name staff must provide.
---@return table manifest The manifest.
local function manifest()
  return { namespace = "acme_props", version = "1.0.0", api = 1, title = "Props", types = {
    prop = { schema = 1, authority = "config", fields = {
      name = { type = "string", required = true }, spot = { type = "vector3", required = true },
      facing = { type = "number", default = 0 }, map = { type = "string", index = true },
      model = { type = "json", engine = true },
    }, world = { kind = "object", position = "spot", heading = "facing", map = "map", model = "model" } },
  } }
end

describe("staff placement", function()
  local p
  ---Answer the latest menu without client-supplied coordinates.
  ---@param index integer The offered choice number.
  local function menu(index)
    p.client_requests[#p.client_requests].callback(rpf.handoff.encode("rpf:ui_answer", { ok = true, index = index }))
  end
  ---Every placement edit sent to the portal.
  ---@return table[] frames The edits.
  local function edits()
    local out = {}
    for _, frame in ipairs(p.frames()) do if frame.type == "config_changed" then out[#out + 1] = frame end end
    return out
  end
  before_each(function()
    support.load_core()
    p = support.fake_platform({ map = "gm_construct" })
    p.capabilities.heading = function() return 37 end
    support.connected(p)
    rpf.players.connected(7)
    assert(rpf.players.authenticating(7))
    assert(rpf.players.register(7, { player_id = PLAYER, username = "sam" }))
    p.positions[7] = { x = 10, y = 20, z = 30 }
    p.deliver(support.portal_frame("staff_permissions", { staff = { { player_id = PLAYER, permissions = { "addon.acme_props.view", "addon.acme_props.edit" } } } }))
    assert(rpf.addons.register(manifest(), {}))
    local m = assert(rpf.manifest.check(manifest()))
    local entry = { namespace = "acme_props", version = "1.0.0", enabled = true, manifest = m, hash = "sha256:props", types = rpf.json.object({}),
      records = rpf.json.array({ { id = ID, type = "acme_props.prop", revision = 2, fields = { name = "Crate", spot = { x = 1, y = 2, z = 3 }, map = "gm_construct", model = "crate" } } }),
    }
    local snapshot = assert(rpf.json.decode(assert(rpf.json.encode({ addons = rpf.json.array({ entry }) }))))
    assert(rpf.config.apply(p, 5, "h5", snapshot))
  end)
  it("creates only after confirmation with server transform and the first config version", function()
    assert(rpf.api.placement.open(7)); menu(1); menu(1)
    assert.are.equal("input", rpf.json.decode(p.client_requests[#p.client_requests].payload).kind)
    p.client_requests[#p.client_requests].callback(rpf.handoff.encode("rpf:ui_answer", { ok = true, values = { "New crate" } }))
    assert.are.equal(0, #edits())
    assert.are.equal("Confirm placement", rpf.json.decode(p.client_requests[#p.client_requests].payload).spec.title)
    menu(1)
    local edit = assert(edits()[1], rpf.json.encode(p.to_clients))
    assert.are.equal(5, edit.base_version)
    assert.are.same({ spot = { x = 10, y = 20, z = 30 }, facing = 37, map = "gm_construct", name = "New crate" }, edit.changes[1].fields)
    assert.are.equal("create_world_record", edit.changes[1].change)
    assert.are.equal(1, #rpf.addons.config_records("acme_props.prop"), "awaits portal snapshot")
  end)
  it("moves and removes only the record offered, at its original revision", function()
    assert(rpf.api.placement.open(7)); menu(1); menu(2); menu(1); menu(1)
    local change = assert(edits()[1], rpf.json.encode(p.to_clients)).changes[1]
    assert.are.equal("update_world_record", change.change)
    assert.are.equal(ID, change.record_id)
    assert.are.equal(2, change.base_revision)
    assert.are.same({ spot = { x = 10, y = 20, z = 30 }, facing = 37, map = "gm_construct" }, change.patch)
    assert(rpf.api.placement.open(7)); menu(1); menu(3); menu(1); menu(1)
    assert.are.equal("delete_world_record", edits()[2].changes[1].change)
  end)
  it("cancels without sending and refuses unlinked staff", function()
    assert(rpf.api.placement.open(7)); menu(1); menu(2); menu(1); menu(2)
    assert.are.equal(0, #edits())
    p.deliver(support.portal_frame("staff_permissions", { staff = {} }))
    assert.are.same({ nil, "forbidden" }, { rpf.api.placement.open(7) })
  end)
  it("never sends a forged record menu answer", function()
    assert(rpf.api.placement.open(7)); menu(1); menu(2); menu(99)
    assert.are.equal(0, #edits())
  end)
  it("does not submit an open edit after staff permission is revoked", function()
    assert(rpf.api.placement.open(7)); menu(1); menu(2); menu(1)
    p.deliver(support.portal_frame("staff_permissions", { staff = {} }))
    menu(1)
    assert.are.equal(0, #edits())
  end)
end)

describe("placement previews on the client", function()
  it("replaces a ghost, clears on cancellation, and bounds its lifetime", function()
    support.load_core("client")
    local p = support.fake_client_platform()
    local shown, removed = 0, 0
    p.ui.preview = function()
      shown = shown + 1
      return function() removed = removed + 1 end
    end
    rpf.start_client(p)
    local message = assert(rpf.json.encode({ model = "crate", position = { x = 1, y = 2, z = 3 }, heading = 0, kind = "object" }))
    p.server_handlers["rpf:placement_preview"](message)
    p.server_handlers["rpf:placement_preview"](message)
    assert.are.same({ 2, 1 }, { shown, removed })
    p.server_handlers["rpf:placement_preview"]("{}")
    assert.are.equal(2, removed)
    p.server_handlers["rpf:placement_preview"](message)
    p.advance(60000)
    assert.are.same({ 3, 3 }, { shown, removed })
  end)
end)
