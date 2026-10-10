-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- The event bus: ordering, one-shot handlers, removal, and above all
-- isolation, because scripts the core did not write share it.

local support = require("spec.support")

describe("rpf.events", function()
  local events, logs

  before_each(function()
    support.load_core()
    events = rpf.events
    logs = {}
    events.bind(function(level, message)
      logs[#logs + 1] = { level = level, message = message }
    end)
  end)

  it("calls handlers in registration order with the emitted arguments", function()
    local calls = {}
    events.on("thing", function(a, b)
      calls[#calls + 1] = "first " .. a .. b
    end)
    events.on("thing", function(a, b)
      calls[#calls + 1] = "second " .. a .. b
    end)
    assert.are.equal(0, events.emit("thing", "x", "y"))
    assert.are.same({ "first xy", "second xy" }, calls)
  end)

  it("emits to nobody without complaint", function()
    assert.are.equal(0, events.emit("nobody.listens"))
    assert.are.same({}, logs)
  end)

  it("logs a handler that throws and still runs the handlers after it", function()
    local ran = {}
    events.on("thing", function()
      ran[#ran + 1] = 1
    end)
    events.on("thing", function()
      error("broken script")
    end)
    events.on("thing", function()
      ran[#ran + 1] = 3
    end)
    assert.are.equal(1, events.emit("thing"))
    assert.are.same({ 1, 3 }, ran)
    assert.are.equal(1, #logs)
    assert.are.equal("error", logs[1].level)
    assert.truthy(logs[1].message:find("a handler for thing failed", 1, true))
    assert.truthy(logs[1].message:find("broken script", 1, true))
  end)

  it("keeps log lines from before a platform is bound, and writes them once bound", function()
    support.load_core()
    rpf.events.on("thing", function()
      error("early")
    end)
    rpf.events.emit("thing")
    local lines = {}
    rpf.events.bind(function(level, message)
      lines[#lines + 1] = level .. " " .. message
    end)
    assert.are.equal(1, #lines)
    assert.truthy(lines[1]:find("^error rpf: a handler for thing failed"))
  end)

  it("runs a once handler for the next emit only", function()
    local count = 0
    events.once("thing", function()
      count = count + 1
      -- Emitting from inside it does not call it again.
      events.emit("thing")
    end)
    events.emit("thing")
    events.emit("thing")
    assert.are.equal(1, count)
    assert.are.equal(0, events.count("thing"))
  end)

  it("removes a once handler that throws", function()
    events.once("thing", function()
      error("boom")
    end)
    events.emit("thing")
    assert.are.equal(0, events.count("thing"))
  end)

  it("removes every registration of a handler, and only that handler", function()
    local calls = {}
    local function mine()
      calls[#calls + 1] = "mine"
    end
    events.on("thing", mine)
    events.on("thing", function()
      calls[#calls + 1] = "other"
    end)
    events.on("thing", mine)
    assert.is_true(events.off("thing", mine))
    assert.is_false(events.off("thing", mine))
    events.emit("thing")
    assert.are.same({ "other" }, calls)
  end)

  it("can remove a once handler before it fires", function()
    local fired = false
    local handler = events.once("thing", function()
      fired = true
    end)
    events.off("thing", handler)
    events.emit("thing")
    assert.is_false(fired)
  end)

  it("skips a handler removed during an emit, and defers one added during it", function()
    local calls = {}
    local function late()
      calls[#calls + 1] = "late"
    end
    local function second()
      calls[#calls + 1] = "second"
    end
    events.on("thing", function()
      calls[#calls + 1] = "first"
      events.off("thing", second)
      events.on("thing", late)
    end)
    events.on("thing", second)
    events.emit("thing")
    assert.are.same({ "first" }, calls)
    events.emit("thing")
    assert.are.same({ "first", "first", "late" }, calls)
  end)

  it("refuses a cycle of emits instead of overflowing the stack", function()
    events.on("ping", function()
      events.emit("ping")
    end)
    events.emit("ping")
    local refused = 0
    for _, line in ipairs(logs) do
      if line.message:find("nested " .. events.MAX_DEPTH .. " deep", 1, true) then
        refused = refused + 1
      end
    end
    assert.are.equal(1, refused)
  end)

  it("refuses a name that is not a non-empty string, and a handler that is not a function", function()
    assert.has_error(function()
      events.on("", function() end)
    end)
    assert.has_error(function()
      ---@diagnostic disable-next-line: param-type-mismatch
      events.on(nil, function() end)
    end)
    assert.has_error(function()
      ---@diagnostic disable-next-line: param-type-mismatch
      events.on("thing", "not a function")
    end)
    assert.has_error(function()
      events.emit("")
    end)
  end)

  for _, name in ipairs({ "players.active", "config.changed", "auth.succeeded", "staff.changed", "addons.state", "rpf.anything" }) do
    it("refuses a script emitting the core's " .. name, function()
      local fired = false
      events.on(name, function()
        fired = true
      end)
      local failed, err = events.emit_public(name)
      assert.is_nil(failed)
      assert.are.equal("reserved", err)
      assert.is_false(fired)
    end)
  end

  it("lets a script emit its own events", function()
    local got
    events.on("myaddon.opened", function(value)
      got = value
    end)
    assert.are.equal(0, events.emit_public("myaddon.opened", 42))
    assert.are.equal(42, got)
  end)

  it("refuses a name that is not one, without throwing", function()
    for _, name in ipairs({ "", 42, false }) do
      local failed, err = events.emit_public(name)
      assert.is_nil(failed)
      assert.are.equal("invalid", err)
    end
  end)
end)
