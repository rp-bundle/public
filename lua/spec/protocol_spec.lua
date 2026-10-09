-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The Lua half of the conformance corpus. These read the same files under
-- protocol/corpus/v<VERSION>/ that crates/rpf-protocol/tests/protocol.rs does, so the Lua decoder and the
-- Rust types are each held to the corpus, never to each other.
--
-- The Lua side's ratchet: when a variant is added in Rust and its sample
-- committed, `every corpus file has a decoder` fails until protocol.lua
-- learns the type, and `every decoder has a corpus file` fails if a type is
-- added here that the portal does not know.

local lfs = require("lfs")
local support = require("spec.support")

local DIRECTIONS = { "server_to_portal", "portal_to_server" }

---The corpus files for a direction, by type tag.
---@param direction string The direction, which is also the directory.
---@return table<string, string> files Raw file contents by tag.
local function corpus(direction)
  local dir = support.path(support.corpus(direction))
  local files = {}
  for name in lfs.dir(dir) do
    local tag = name:match("^(.+)%.json$")
    if tag then
      files[tag] = support.read(support.corpus(direction .. "/" .. name))
    end
  end
  return files
end

---Sorted keys of a table.
---@param t table The table.
---@return string[] keys The keys.
local function keys(t)
  local out = {}
  for key in pairs(t) do
    out[#out + 1] = key
  end
  table.sort(out)
  return out
end

---Values kept whole rather than decoded field by field, by their path in a
---frame: what is added there is data the receiver keeps, not an unknown
---field it ignores. A config snapshot is one, so a section a newer portal
---adds is not lost (crates/rpf-protocol/tests/protocol.rs exempts its settings map likewise).
---So are a container's contents and flags (C7), which `rpf.inventory` reads
---and validates as they are, so a stack's data comes back byte for byte.
local OPAQUE = {
  snapshot = true,
  ["records.contents"] = true,
  ["changes.contents"] = true,
  ["records.container.contents"] = true,
  ["records.container.flags"] = true,
}

---Adds a field to every object at every depth, as crates/rpf-protocol/tests/protocol.rs does,
---leaving the `OPAQUE` values alone.
---@param value any A decoded JSON value.
---@param json rpf.json The codec, for telling objects from arrays.
---@param path string? Where `value` is in the frame, nil at the top.
local function add_field_everywhere(value, json, path)
  if path and OPAQUE[path] then
    return
  end
  if json.is_object(value) then
    for key, child in pairs(value) do
      add_field_everywhere(child, json, path and path .. "." .. key or key)
    end
    value.added_later = "from a later version"
  elseif json.is_array(value) then
    for _, item in ipairs(value) do
      add_field_everywhere(item, json, path)
    end
  end
end

describe("rpf.protocol against the corpus of the version it speaks", function()
  local rpf_, protocol, json

  before_each(function()
    rpf_ = support.load_core()
    protocol, json = rpf_.protocol, rpf_.json
  end)

  for _, direction in ipairs(DIRECTIONS) do
    describe(direction, function()
      it("has a decoder for every corpus file", function()
        local files = corpus(direction)
        assert.is_true(#keys(files) > 0, "no corpus files found")
        for _, tag in ipairs(keys(files)) do
          assert.is_not_nil(
            protocol.messages[direction][tag],
            direction .. "/" .. tag .. ".json has no decoder in lua/core/protocol.lua"
          )
        end
      end)

      it("has a corpus file for every decoder", function()
        local files = corpus(direction)
        for _, tag in ipairs(keys(protocol.messages[direction])) do
          assert.is_not_nil(files[tag], tag .. " is decoded here but has no corpus file")
        end
      end)

      it("decodes every corpus file, and re-encodes it to the same JSON", function()
        for tag, raw in pairs(corpus(direction)) do
          local frame, err = protocol.decode(direction, raw)
          assert.is_nil(err, tag)
          assert.are.equal(tag, frame.type)

          local text, encode_err = protocol.encode(direction, frame)
          assert.is_nil(encode_err, tag)
          -- Structural, because the file is pretty-printed and the codec is
          -- compact: the same JSON, field for field and number for number.
          assert.are.same(json.decode(raw), json.decode(text), tag)
          assert.are.equal(json.encode(json.decode(raw)), text, tag)
        end
      end)

      it("ignores unknown fields at every depth", function()
        for tag, raw in pairs(corpus(direction)) do
          local extended = json.decode(raw)
          add_field_everywhere(extended, json)
          local original = protocol.decode(direction, raw)
          local parsed, err = protocol.decode(direction, assert(json.encode(extended)))
          assert.is_nil(err, tag)
          assert.are.same(original, parsed, tag)
        end
      end)

      it("rejects an unknown message type", function()
        local unknown = '{"id":"00000005-0000-4000-8000-000000000005",'
          .. '"sent_at":"2026-01-01T00:00:00Z","type":"teleport_everyone"}'
        local frame, err = protocol.decode(direction, unknown)
        assert.is_nil(frame)
        assert.truthy(err:find("unknown message type", 1, true))
        assert.is_nil(protocol.encode(direction, { id = "x", sent_at = "x", type = "teleport_everyone" }))
      end)

      it("rejects a frame missing any of its fields", function()
        for tag, raw in pairs(corpus(direction)) do
          for _, field in ipairs(keys(json.decode(raw))) do
            local frame = json.decode(raw)
            frame[field] = nil
            local decoded, err = protocol.decode(direction, assert(json.encode(frame)))
            assert.is_nil(decoded, tag .. " without " .. field .. " was accepted")
            assert.is_string(err)
          end
        end
      end)
    end)
  end

  it("holds Hello's config fields to being sent as null, not left out", function()
    local raw = corpus("server_to_portal").hello
    local frame = json.decode(raw)
    frame.config_version = json.null
    frame.config_hash = json.null
    local decoded = assert(protocol.decode("server_to_portal", assert(json.encode(frame))))
    assert.is_nil(decoded.config_version)
    local text = assert(protocol.encode("server_to_portal", decoded))
    assert.are.equal(json.null, json.decode(text).config_version)
    assert.are.equal(json.null, json.decode(text).config_hash)
  end)

  it("holds a staff action's target to being sent as null, not left out", function()
    local frame = json.decode(corpus("server_to_portal").staff_action)
    frame.target_player_id = json.null
    local decoded = assert(protocol.decode("server_to_portal", assert(json.encode(frame))))
    assert.is_nil(decoded.target_player_id)
    local text = assert(protocol.encode("server_to_portal", decoded))
    assert.are.equal(json.null, json.decode(text).target_player_id)
  end)

  it("keeps permission names it does not know, and refuses a grant that is not strings", function()
    local frame = json.decode(corpus("portal_to_server").staff_permissions)
    frame.staff[1].permissions = json.array({ "player.kick", "addon.radio.broadcast" })
    local decoded = assert(protocol.decode("portal_to_server", assert(json.encode(frame))))
    assert.are.same({ "player.kick", "addon.radio.broadcast" }, decoded.staff[1].permissions)

    frame.staff[1].permissions = json.array({ "player.kick", 7 })
    assert.is_nil(protocol.decode("portal_to_server", assert(json.encode(frame))))
    frame.staff[1].permissions = json.object({ kick = true })
    assert.is_nil(protocol.decode("portal_to_server", assert(json.encode(frame))))
    frame.staff[1].permissions = json.array()
    frame.staff[1].player_id = "sam"
    assert.is_nil(protocol.decode("portal_to_server", assert(json.encode(frame))))
  end)

  it("keeps a config snapshot whole, sections it does not know included", function()
    local frame = json.decode(corpus("portal_to_server").config)
    frame.snapshot.items = json.array({ json.object({ slug = "water", weight = 500 }) })
    frame.snapshot.settings["economy.added_later"] = 10
    local decoded = assert(protocol.decode("portal_to_server", assert(json.encode(frame))))
    assert.are.same(frame.snapshot, decoded.snapshot)
    assert.are.equal(json.encode(frame.snapshot), json.encode(decoded.snapshot))

    frame.snapshot = json.array({})
    assert.is_nil(protocol.decode("portal_to_server", assert(json.encode(frame))))
  end)

  it("refuses a field of the wrong type", function()
    local raw = corpus("portal_to_server").apply_command
    local cases = {
      function(f)
        f.command.amount = "250"
      end,
      function(f)
        f.command.amount = 1.5
      end,
      function(f)
        f.command.command = "delete_everything"
      end,
      function(f)
        f.id = "not-a-uuid"
      end,
      function(f)
        f.sent_at = "yesterday"
      end,
    }
    for i, mutate in ipairs(cases) do
      local frame = json.decode(raw)
      mutate(frame)
      assert.is_nil(protocol.decode("portal_to_server", assert(json.encode(frame))), "case " .. i)
    end
  end)

  it("bounds money to ±MAX_AMOUNT, the widest amount a double holds exactly", function()
    local raw = corpus("portal_to_server").apply_command
    for _, amount in ipairs({ protocol.MAX_AMOUNT, -protocol.MAX_AMOUNT }) do
      local frame = json.decode(raw)
      frame.command.amount = amount
      assert.is_not_nil(protocol.decode("portal_to_server", assert(json.encode(frame))))
    end
    local beyond = raw:gsub("%-250", "-9007199254740992")
    assert.is_nil(protocol.decode("portal_to_server", beyond))
  end)

  -- `command_outcomes.json` in the corpus holds one sample of every
  -- `CommandOutcome`, which `crates/rpf-protocol/tests/protocol.rs` checks against the Rust type.
  it("round-trips every command outcome in the corpus inside a command_applied", function()
    local outcomes = assert(json.decode(support.read(support.corpus("command_outcomes.json"))))
    assert.is_true(#outcomes >= 3)
    local seen = {}
    for _, outcome in ipairs(outcomes) do
      local frame = assert(json.decode(corpus("server_to_portal").command_applied))
      frame.outcome = outcome
      local wire = assert(json.encode(outcome))
      local decoded = assert(protocol.decode("server_to_portal", assert(json.encode(frame))), wire)
      local encoded = json.decode(assert(protocol.encode("server_to_portal", decoded)))
      assert.are.equal(wire, assert(json.encode(encoded.outcome)))
      seen[outcome.outcome] = true
    end
    assert.is_true(seen.unknown, "the outcome a game server sends when it cannot vouch for one")
    local bad = assert(json.decode(corpus("server_to_portal").command_applied))
    bad.outcome = json.object({ outcome = "maybe" })
    assert.is_nil(protocol.decode("server_to_portal", assert(json.encode(bad))))
  end)

  -- `commands.json` in the corpus holds one sample of every `Command`,
  -- which `crates/rpf-protocol/tests/protocol.rs` checks against the Rust type. A
  -- command this decoder refuses is one the server can never answer.
  it("decodes every command in the corpus inside an apply_command", function()
    local commands = assert(json.decode(support.read(support.corpus("commands.json"))))
    local seen = {}
    for _, command in ipairs(commands) do
      local frame = assert(json.decode(corpus("portal_to_server").apply_command))
      frame.command = command
      local wire = assert(json.encode(command))
      local decoded = assert(protocol.decode("portal_to_server", assert(json.encode(frame))), wire)
      local encoded = json.decode(assert(protocol.encode("portal_to_server", decoded)))
      assert.are.equal(wire, assert(json.encode(encoded.command)))
      seen[command.command] = true
    end
    assert.is_true(seen.adjust_balance)
    assert.is_true(seen.kick)

    local kick = assert(json.decode(corpus("portal_to_server").apply_command))
    kick.command = json.object({ command = "kick", player_id = "not-a-uuid", reason = "x" })
    assert.is_nil(protocol.decode("portal_to_server", assert(json.encode(kick))))
  end)

  -- `config_changes.json` in the corpus holds one sample of every
  -- `ConfigChange` (E6), which `crates/rpf-protocol/tests/protocol.rs` checks
  -- against the Rust type. The core only ever encodes one, and a change it
  -- encodes in another shape is one the portal refuses.
  it("encodes every config change in the corpus inside a config_changed exactly as the portal reads it", function()
    local changes = assert(json.decode(support.read(support.corpus("config_changes.json"))))
    local seen = {}
    for _, change in ipairs(changes) do
      local frame = assert(json.decode(corpus("server_to_portal").config_changed))
      frame.changes = json.array({ change })
      local wire = assert(json.encode(change))
      local decoded = assert(protocol.decode("server_to_portal", assert(json.encode(frame))), wire)
      local encoded = json.decode(assert(protocol.encode("server_to_portal", decoded)))
      assert.are.equal(wire, assert(json.encode(encoded.changes[1])))
      seen[change.change] = true
    end
    assert.is_true(seen.setting)
    assert.is_true(seen.delete_job)
    assert.are.equal(16, #changes)

    -- An unknown kind of change, and a set setting with no value, are refused.
    local unknown = assert(json.decode(corpus("server_to_portal").config_changed))
    unknown.changes[1] = json.object({ change = "delete_guild" })
    assert.is_nil(protocol.decode("server_to_portal", assert(json.encode(unknown))))
    assert.is_nil(protocol.encode("server_to_portal", {
      id = "00000005-0000-4000-8000-000000000005",
      sent_at = "2026-01-01T00:00:00Z",
      type = "config_changed",
      player_id = "00000002-0000-4000-8000-000000000002",
      base_version = 7,
      changes = { { change = "setting", key = "server.welcome_message", value = { state = "set" } } },
    }))
  end)

  it("decodes every gender the portal can send", function()
    local raw = corpus("portal_to_server").character_created
    for _, gender in ipairs({ '"male"', '"female"', '{"server_specific":"Nonbinary"}' }) do
      local text = raw:gsub('"female"', gender)
      local frame = assert(protocol.decode("portal_to_server", text))
      assert.is_not_nil(frame.character.gender)
    end
    local bad = raw:gsub('"female"', '"other"')
    assert.is_nil(protocol.decode("portal_to_server", bad))
  end)

  -- D7's corpus assertion: a character's job, and the three states of a
  -- reported `employment`.
  it("decodes a character's job, and refuses one that is not two strings", function()
    local held = assert(protocol.decode("portal_to_server", corpus("portal_to_server").held))
    assert.are.same({ employer = "lspd", job = "officer" }, held.records[1].character.job)
    local raw = corpus("portal_to_server").character_created
    assert.is_nil(raw:find('"job"', 1, true), "left out for none")
    local created = assert(protocol.decode("portal_to_server", raw))
    assert.is_nil(created.character.job, "absent is no job")
    local with = function(job)
      return (raw:gsub('"gender": "female"', '"gender": "female", "job": ' .. job))
    end
    assert.is_nil(assert(protocol.decode("portal_to_server", with("null"))).character.job, "and so is null")
    assert.is_nil(protocol.decode("portal_to_server", with('{ "employer": "lspd" }')))
    assert.is_nil(protocol.decode("portal_to_server", with('"lspd/officer"')))
    -- Encoded back without one, so a recorded frame re-encodes exactly.
    local text = assert(protocol.encode("portal_to_server", created))
    assert.is_nil(text:find('"job"', 1, true))

    local changed = assert(protocol.decode("server_to_portal", corpus("server_to_portal").state_changed))
    assert.are.same({ job = { employer = "lspd", job = "officer" } }, changed.changes[1].employment)
    local resync = assert(protocol.decode("server_to_portal", corpus("server_to_portal").resync))
    assert.are.same({}, resync.records[1].employment, "{ job = null }: no job")
  end)

  describe("classification, mirroring Message::answered_by and Message::reissuable", function()
    -- These are the values crates/rpf-protocol/src/lib.rs gives. Nothing but review
    -- keeps the two in step, so they are pinned here, where a change has to
    -- be made deliberately.
    local ANSWERED_BY = {
      server_to_portal = {
        hello = "reply",
        begin_join = "reply",
        redeem_ticket = "reply",
        create_character = "reply",
        player_dropped = "ack",
        online_players = "ack",
        command_applied = "ack",
        config_applied = "ack",
        hold = "reply",
        release = "ack",
        state_changed = "reply",
        resync = "reply",
        declare_holds = "reply",
        link_player = "reply",
        staff_action = "ack",
        config_changed = "reply",
        ack = "nothing",
      },
      portal_to_server = {
        apply_command = "reply",
        config = "reply",
        welcome = "ack",
        rejected = "ack",
        join_challenge = "ack",
        player_authenticated = "ack",
        character_created = "ack",
        held = "ack",
        state_applied = "ack",
        resync_required = "ack",
        player_linked = "ack",
        config_change_applied = "ack",
        config_change_discarded = "ack",
        staff_permissions = "ack",
        restarting = "nothing",
        ack = "nothing",
      },
    }

    for _, direction in ipairs(DIRECTIONS) do
      it(direction .. " answers match the Rust classification", function()
        for tag, spec in pairs(protocol.messages[direction]) do
          assert.are.equal(ANSWERED_BY[direction][tag], spec.answered_by, tag)
        end
      end)

      -- The same rules as answers_are_coherent in crates/rpf-protocol/tests/protocol.rs.
      it(direction .. " is coherent: a request has no re, and only an ack or a restart notice goes unanswered", function()
        for tag, spec in pairs(protocol.messages[direction]) do
          local has_re = false
          for _, field in ipairs(spec.fields) do
            has_re = has_re or field[1] == "re"
          end
          if spec.answered_by == "reply" then
            assert.is_false(has_re, tag .. ": a request carries no re")
          end
          assert.are.equal(tag == "ack" or tag == "restarting", spec.answered_by == "nothing", tag)
          if tag == "restarting" then
            assert.is_false(has_re, "restarting: a notice names no frame")
          end
          if tag == "ack" then
            assert.is_true(has_re, "ack: must name what it acknowledges")
            assert.is_false(spec.reissuable, "ack: never sits in an outbox")
          end
        end
      end)
    end

    it("reissues only state reports, holds and presence", function()
      local reissuable = {}
      for _, direction in ipairs(DIRECTIONS) do
        for tag, spec in pairs(protocol.messages[direction]) do
          if spec.reissuable then
            reissuable[#reissuable + 1] = direction .. "/" .. tag
          end
        end
      end
      table.sort(reissuable)
      assert.are.same({
        "server_to_portal/command_applied",
        "server_to_portal/config_applied",
        "server_to_portal/hold",
        "server_to_portal/player_dropped",
        "server_to_portal/release",
        "server_to_portal/resync",
        "server_to_portal/state_changed",
      }, reissuable)
    end)

    -- `reject_codes.json` in the corpus lists every `RejectCode`, which
    -- `crates/rpf-protocol/tests/protocol.rs` checks against the Rust type.
    it("decodes a rejected frame with every reject code in the corpus, and no other", function()
      local codes = assert(json.decode(support.read(support.corpus("reject_codes.json"))))
      assert.is_true(#codes >= 9)
      local seen = {}
      for _, code in ipairs(codes) do
        local frame = assert(json.decode(corpus("portal_to_server").rejected))
        frame.code = code
        local decoded = assert(protocol.decode("portal_to_server", assert(json.encode(frame))), code)
        assert.are.equal(code, decoded.code)
        seen[code] = true
      end
      assert.is_true(seen.suspended, "H5: a suspended community's Hello")
      local bad = assert(json.decode(corpus("portal_to_server").rejected))
      bad.code = "upgrade_required"
      assert.is_nil(protocol.decode("portal_to_server", assert(json.encode(bad))))
    end)

    it("retries only retry and rate_limited", function()
      local codes = assert(json.decode(support.read(support.corpus("reject_codes.json"))))
      local retryable = {}
      for _, code in ipairs(codes) do
        if protocol.may_retry(code) then
          retryable[#retryable + 1] = code
        end
      end
      assert.are.same({ "retry", "rate_limited" }, retryable)
    end)
  end)

  describe("envelopes", function()
    it("mints version 4 uuids", function()
      local p = support.fake_platform()
      for _ = 1, 50 do
        local id = protocol.new_id(p)
        assert.truthy(id:find("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"), id)
      end
    end)

    it("formats sent_at as the portal does", function()
      assert.are.equal("2026-01-01T00:00:00Z", protocol.timestamp(support.EPOCH_MS))
      assert.are.equal("2026-01-01T00:02:00Z", protocol.timestamp(support.EPOCH_MS + 120000))
      assert.are.equal("1970-01-01T00:00:00Z", protocol.timestamp(0))
      assert.are.equal("2024-02-29T23:59:59.999Z", protocol.timestamp(1709251199999))
      assert.are.equal("2000-03-01T00:00:00Z", protocol.timestamp(951868800000))
    end)

    it("redacts credentials for logging, and nothing else", function()
      local hello = assert(protocol.decode("server_to_portal", corpus("server_to_portal").hello))
      local redacted = protocol.redact("server_to_portal", hello)
      assert.are.equal("<redacted>", redacted.api_key)
      assert.are.equal(hello.instance_id, redacted.instance_id)
      assert.are.equal("rpf_sample_0000000000000000", hello.api_key)

      -- A staff link code is a credential until it is redeemed (F9).
      local link = assert(protocol.decode("server_to_portal", corpus("server_to_portal").link_player))
      local hidden = protocol.redact("server_to_portal", link)
      assert.are.equal("<redacted>", hidden.link_code)
      assert.are.equal(link.player_id, hidden.player_id)
    end)
  end)
end)
