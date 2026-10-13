-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Conformance (L2, #176): ownership, access and locking, the same cases on
-- the mock platform and on the real FiveM and Gmod adapters
-- (`spec/support/conformance.lua`). A world type with a `locked` role gets
-- Lock and Unlock from the core, offered only to whoever has access and
-- checked again on the server when picked; an addon locks and unlocks
-- through `rpf.api.ownership`; and a door this server does not hold, another
-- type's record and a missing one are one answer. The fake game server
-- takes a lock, an unlock and a refusal through the real portal
-- (`crates/fake-server/tests/scenarios/ownership.rs`).

local conformance = require("spec.support.conformance")

---What `conformance.run` needs from busted.
local busted = { describe = describe, it = it, before_each = before_each, after_each = after_each }

local DOOR = "acme_doors.door"
local SIGN = "acme_doors.sign"
local SERVER = "00000001-0000-4000-8000-000000000001"
local OWNER = "00000002-0000-4000-8000-000000000002"
local FRIEND = "00000003-0000-4000-8000-000000000003"
local STRANGER = "00000004-0000-4000-8000-000000000004"
local LSPD = "0000000e-0000-4000-8000-00000000000e"
local MISSING = "0000000f-0000-4000-8000-00000000000f"

---An addon with doors players own and share, which may be job doors, and
---signs, which are in the world but have no lock.
---@return table manifest The manifest.
local function manifest()
  return {
    namespace = "acme_doors",
    version = "1.0.0",
    api = 1,
    title = "Doors",
    types = {
      door = {
        schema = 1,
        authority = "live",
        owners = { "server" },
        hold = "server",
        fields = {
          spot = { type = "vector3", required = true },
          locked = { type = "boolean", default = true },
          holder = { type = "ref", to = "player", index = true, nullable = true },
          keys = { type = "list", of = "ref", to = "player" },
          employer = { type = "ref", to = "employer", index = true, nullable = true },
          jobs = { type = "list", of = "ref", to = "job" },
          departments = { type = "list", of = "ref", to = "department" },
          ranks = { type = "list", of = "ref", to = "job" },
        },
        world = {
          kind = "point",
          position = "spot",
          locked = "locked",
          owner = "holder",
          co_owners = "keys",
          employer = "employer",
          jobs = "jobs",
          departments = "departments",
          ranks = "ranks",
        },
      },
      sign = {
        schema = 1,
        authority = "live",
        owners = { "server" },
        hold = "server",
        fields = { spot = { type = "vector3", required = true } },
        world = { kind = "point", position = "spot" },
      },
    },
  }
end

---A point given in metres from the origin, in the engine's units.
---@param world spec.ConformanceWorld The world.
---@param x number Metres.
---@param y number Metres.
---@param z number Metres.
---@return { x: number, y: number, z: number } point The point.
local function point(world, x, y, z)
  return { x = world:units(x), y = world:units(y), z = world:units(z) }
end

---The police's config: an employer with a department and two ranked jobs,
---and its id, for a job door's `employer`.
---@param world spec.ConformanceWorld The world.
---@return table sections The snapshot's employment sections.
local function police(world)
  local json = world.core.json
  return {
    employers = json.array({ { slug = "lspd", name = "Police", description = "" } }),
    employer_departments = json.array({ { employer = "lspd", slug = "patrol", name = "Patrol", description = "" } }),
    employer_jobs = json.array({
      { employer = "lspd", slug = "cadet", name = "Cadet", description = "", rank = 1 },
      { employer = "lspd", slug = "sergeant", name = "Sergeant", description = "", rank = 5, department = "patrol" },
    }),
    employer_ids = json.object({ lspd = LSPD }),
  }
end

---Registers the addon, installs it with the police's config and `settings`,
---logs player 1 in as `player_id`, and puts them a metre from where doors
---stand.
---@param world spec.ConformanceWorld The world.
---@param player_id string? Who player 1 is: the owner unless given.
---@param settings table? Settings.
---@return any handle Player 1's engine handle.
local function ready(world, player_id, settings)
  assert(world.api.addons.register(manifest()))
  world:connect()
  local extra = police(world)
  extra.settings = world.core.json.object(settings or {})
  world:install({ conformance.installed(world.core, manifest()) }, extra)
  world:pump()
  local handle = world:login(1, player_id or OWNER)
  world:activate(handle)
  world.place(1, point(world, 10, 20, 30))
  return handle
end

---A door a metre from the player, created by the addon and so held here.
---@param world spec.ConformanceWorld The world.
---@param fields table? Its fields beside the spot.
---@return string id Its id.
local function door(world, fields)
  local all = { spot = point(world, 11, 20, 30) }
  for key, value in pairs(fields or {}) do
    all[key] = value
  end
  return assert(world.api.records.create(DOOR, all, { owner = { kind = "server", id = SERVER } })).id
end

---How many requests the harness's clients have numbered.
local numbered = 0

---Sends a request from player 1's client and gives the server's answer.
---@param world spec.ConformanceWorld The world.
---@param name string The request's message name.
---@param body table The request's fields.
---@return table answer The answer, decoded.
local function ask(world, name, body)
  local json = world.core.json
  local before = #world.to_clients
  numbered = numbered + 1
  local number = numbered
  world.from_client(1, name, number .. "\n" .. assert(json.encode(body)))
  for i = before + 1, #world.to_clients do
    local sent = world.to_clients[i]
    local id, reply = sent.payload:match("^(%d+)\n(.*)$")
    if sent.name == name and tonumber(id) == number then
      return assert(json.decode(reply))
    end
  end
  error("no answer to " .. name)
end

---Picks Lock or Unlock on a door from player 1's client.
---@param world spec.ConformanceWorld The world.
---@param name string `lock` or `unlock`.
---@param id string The door.
---@return table answer `{ ok, reason, data }`.
local function pick(world, name, id)
  local json = world.core.json
  local payload = json.object({ target = json.object({ id = id }) })
  return ask(world, "rpf:interact", json.object({ name = "acme_doors.rpf_" .. name .. "1", payload = payload }))
end

---What player 1 is offered near them, as `<label> <first 8 of the id>`.
---@param world spec.ConformanceWorld The world.
---@return string[] options The options.
local function offered(world)
  local answer = ask(world, "rpf:targets", world.core.json.object({}))
  local out = {}
  for _, option in ipairs(answer.options) do
    out[#out + 1] = option.label .. " " .. option.id:sub(1, 8)
  end
  return out
end

---Whether the door is locked, as this server and the portal have it.
---@param world spec.ConformanceWorld The world.
---@param id string The door.
---@return boolean here Locked on the game server.
---@return boolean? portal Locked as the portal last heard.
local function locked(world, id)
  local record = world.portal.records[id]
  local here = world.api.ownership.locked(DOOR, id)
  assert(here ~= nil, "the door is held here")
  return here, record and record.fields.locked
end

conformance.run(busted, "Ownership and locks", {
  {
    name = "lets the owner unlock and lock their door, and reports each to the portal",
    run = function(world)
      ready(world)
      local id = door(world, { holder = OWNER })
      world:settle()
      assert.are.same({ "Unlock " .. id:sub(1, 8) }, offered(world), "only Unlock, on a locked door")
      local answer = pick(world, "unlock", id)
      assert.is_true(answer.ok, world.core.json.encode(answer))
      assert.are.same({ locked = false }, answer.data)
      world:settle()
      assert.are.same({ false, false }, { locked(world, id) })
      assert.are.same({ "Lock " .. id:sub(1, 8) }, offered(world))
      assert.is_true(pick(world, "lock", id).ok)
      world:settle()
      assert.are.same({ true, true }, { locked(world, id) })
    end,
  },
  {
    name = "lets a co-owner in, offers nothing to a stranger, and refuses one who asks anyway, changing nothing",
    run = function(world)
      ready(world, STRANGER)
      local shared = door(world, { holder = OWNER, keys = { FRIEND, STRANGER } })
      local theirs = door(world, { holder = OWNER, keys = { FRIEND } })
      world:settle()
      assert.is_true(pick(world, "unlock", shared).ok, "a co-owner")
      assert.are.same({ "Lock " .. shared:sub(1, 8) }, offered(world), "nothing on the door they have no key to")
      local refused = pick(world, "unlock", theirs)
      assert.is_false(refused.ok, world.core.json.encode(refused))
      assert.are.equal("You don't have a key to that.", refused.reason)
      world:settle()
      assert.are.same({ true, true }, { locked(world, theirs) })
    end,
  },
  {
    name = "refuses a missing door, another type's record and a malformed id as one, through a player's pick",
    run = function(world)
      ready(world)
      local sign = assert(world.api.records.create(SIGN, { spot = point(world, 11, 20, 30) }, {
        owner = { kind = "server", id = SERVER },
      })).id
      for _, id in ipairs({ MISSING, sign, "not-a-uuid" }) do
        local answer = pick(world, "unlock", id)
        assert.is_false(answer.ok, id)
        assert.are.equal("not_found", answer.reason, id)
      end
    end,
  },
  {
    name = "locks and unlocks for an addon, a lockpick's way with no player, and checks a player's access when asked to",
    run = function(world)
      local handle = ready(world, STRANGER)
      local id = door(world, { holder = OWNER })
      local api = world.api.ownership
      assert.are.same({ false, "no_access", "You don't have a key to that." }, { api.unlock(DOOR, id, { player = handle }) })
      assert.is_false((api.has_access(handle, DOOR, id)))
      assert.is_true(api.unlock(DOOR, id))
      assert.is_true(api.unlock(DOOR, id), "already unlocked is done")
      assert.is_false((api.locked(DOOR, id)))
      assert.is_true(api.lock(DOOR, id))
      assert.are.same({ false, "not_found", "That isn't here." }, { api.lock(DOOR, MISSING) })
      assert.are.same({ false, "not_lockable", "That has no lock." }, { api.lock(SIGN, id) })
      assert.are.same({ false, "not_found", "That isn't here." }, { api.lock("acme_other.door", id) })
      assert.are.same({ nil, "not_found" }, { api.has_access(handle, DOOR, MISSING) })
      assert.are.equal("persistent", api.mode())
    end,
  },
  {
    name = "lets in a job its door lists, a department's job, a rank or higher, and its employer's staff when it lists none",
    run = function(world)
      local handle = ready(world, STRANGER)
      local job
      world.core.facade.current_job = function()
        return job
      end
      local by_job = door(world, { jobs = { { employer = "lspd", job = "cadet" } } })
      local by_department = door(world, { departments = { { employer = "lspd", department = "patrol" } } })
      local by_rank = door(world, { ranks = { { employer = "lspd", job = "sergeant" } } })
      local station = door(world, { employer = LSPD })
      local listed = door(world, { employer = LSPD, jobs = { { employer = "lspd", job = "sergeant" } } })
      local function access(id)
        return (world.api.ownership.has_access(handle, DOOR, id))
      end

      job = { employer = "lspd", name = "cadet", grade = 1 }
      assert.are.same({ true, false, false, true, false }, {
        access(by_job),
        access(by_department),
        access(by_rank),
        access(station),
        access(listed),
      }, "a cadet")
      job = { employer = "lspd", name = "sergeant", department = "patrol", grade = 5 }
      assert.are.same({ false, true, true, true, true }, {
        access(by_job),
        access(by_department),
        access(by_rank),
        access(station),
        access(listed),
      }, "a sergeant on patrol")
      job = { employer = "ems", name = "cadet", grade = 9 }
      assert.are.same({ false, false, false, false, false }, {
        access(by_job),
        access(by_department),
        access(by_rank),
        access(station),
        access(listed),
      }, "another employer's job of the same name")
      job = nil
      assert.is_false(access(station), "no job")
    end,
  },
  {
    name = "offers no lock and refuses every one while the server's ownership is off",
    run = function(world)
      local handle = ready(world, OWNER, { ["world.ownership"] = "off" })
      local id = door(world, { holder = OWNER })
      assert.are.same({}, offered(world))
      assert.are.equal("Locks aren't in use here.", pick(world, "unlock", id).reason)
      assert.are.same({ false, "off", "Locks aren't in use here." }, { world.api.ownership.unlock(DOOR, id) })
      assert.is_true((world.api.ownership.has_access(handle, DOOR, id)), "who has access is still known")
      assert.are.equal("off", world.api.ownership.mode())
    end,
  },
})
