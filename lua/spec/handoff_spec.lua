-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The two small pieces the login flow stands on: the handoff messages, which
-- the server decodes as hostile input, and RFC 3339 parsing, which both
-- halves use to turn the portal's timestamps into durations.

local support = require("spec.support")

describe("rpf.handoff", function()
  before_each(function()
    support.load_core("client")
  end)

  it("round-trips a message and drops fields it does not know", function()
    local payload = rpf.handoff.encode(rpf.handoff.TICKET, { ticket = "rpf_jt_x" })
    assert.are.same({ ticket = "t" }, (rpf.handoff.decode(rpf.handoff.TICKET, '{"ticket":"t","extra":1}')))
    assert.are.same({ ticket = "rpf_jt_x" }, (rpf.handoff.decode(rpf.handoff.TICKET, payload)))
  end)

  for _, case in ipairs({
    { "a payload that is not a string", 42 },
    { "a payload that is too long", '{"ticket":"' .. string.rep("x", 5000) .. '"}' },
    { "text that is not JSON", "{" },
    { "JSON that is not an object", "[1]" },
    { "a missing field", "{}" },
    { "a field of the wrong type", '{"ticket":true}' },
    { "a field that is too long", '{"ticket":"' .. string.rep("x", 600) .. '"}' },
  }) do
    it("refuses " .. case[1] .. " without throwing", function()
      local fields, err = rpf.handoff.decode(rpf.handoff.TICKET, case[2])
      assert.is_nil(fields)
      assert.is_string(err)
    end)
  end

  it("refuses to encode a message that breaks its own schema, because that is a core bug", function()
    assert.has_error(function()
      rpf.handoff.encode(rpf.handoff.TICKET, {})
    end)
    assert.has_error(function()
      rpf.handoff.encode("rpf:unknown", {})
    end)
  end)

  it("names every message under rpf:", function()
    for name in pairs(rpf.handoff.schemas) do
      assert.are.equal("rpf:", name:sub(1, 4), name)
    end
  end)
end)

describe("rpf.time", function()
  before_each(function()
    support.load_core("client")
  end)

  it("reads the portal's timestamps to the millisecond", function()
    assert.are.equal(support.EPOCH_MS, rpf.time.parse("2026-01-01T00:00:00Z"))
    assert.are.equal(support.EPOCH_MS + 500, rpf.time.parse("2026-01-01T00:00:00.5Z"))
    assert.are.equal(support.EPOCH_MS + 123, rpf.time.parse("2026-01-01T00:00:00.123456789Z"))
    assert.are.equal(0, rpf.time.parse("1970-01-01T00:00:00Z"))
    assert.are.equal(951782400000, rpf.time.parse("2000-02-29T00:00:00Z"))
  end)

  it("applies a zone offset", function()
    assert.are.equal(support.EPOCH_MS, rpf.time.parse("2026-01-01T01:00:00+01:00"))
    assert.are.equal(support.EPOCH_MS, rpf.time.parse("2025-12-31T19:30:00-04:30"))
  end)

  it("accepts the largest valid zone offset in either direction", function()
    assert.are.equal(support.EPOCH_MS, rpf.time.parse("2026-01-01T23:59:00+23:59"))
    assert.are.equal(support.EPOCH_MS, rpf.time.parse("2025-12-31T00:01:00-23:59"))
  end)

  it("agrees with the protocol's own formatting", function()
    support.load_core("server")
    for _, ms in ipairs({ 0, support.EPOCH_MS, support.EPOCH_MS + 1, 4102444799999 }) do
      assert.are.equal(ms, rpf.time.parse(rpf.protocol.timestamp(ms)), tostring(ms))
    end
  end)

  for _, text in ipairs({
    "2026-01-01T00:00:00",
    "2026-01-01 00:00:00Z",
    "2026-13-01T00:00:00Z",
    "2026-02-29T00:00:00Z",
    "2026-04-31T00:00:00Z",
    "2026-01-01T24:00:00Z",
    "2026-01-01T00:00:00+1:00",
    "2026-01-01T00:00:00+24:00",
    "2026-01-01T00:00:00-24:00",
    "2026-01-01T00:00:00+00:60",
    "2026-01-01T00:00:00-00:60",
    "2026-01-01T00:00:00+99:99",
    "2026-01-01T00:00:00-99:99",
    "yesterday",
  }) do
    it("refuses " .. text, function()
      assert.is_nil(rpf.time.parse(text))
    end)
  end

  it("refuses what is not a string", function()
    assert.is_nil(rpf.time.parse(nil))
    assert.is_nil(rpf.time.parse(5))
  end)
end)
