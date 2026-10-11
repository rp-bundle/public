-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Targets on the client (`rpf.targets`, J4): the minimal interaction UI
-- asks the server what is near, shows it as a menu and sends the pick; a
-- script can ask itself; and the server's rules are kept and announced for
-- a target resource, which asks the server which rules it offers on an
-- entity (`offered`) and keeps the answer a while. The server's checks are in
-- `conformance_targets_spec.lua`, on every engine.

local support = require("spec.support")

describe("rpf.targets on the client", function()
  local c

  before_each(function()
    support.load_core("client")
    c = support.fake_client_platform()
    rpf.start_client(c)
  end)

  ---Answers the latest request the client sent under a name.
  ---@param name string The request's name.
  ---@param reply string The answer.
  local function answer(name, reply)
    for i = #c.asked, 1, -1 do
      if c.asked[i].name == name then
        c.asked[i].callback(reply)
        return
      end
    end
    error("nothing asked under " .. name)
  end

  ---The server's nearby answer.
  ---@param options table[] The options.
  ---@return string reply It, encoded.
  local function nearby_reply(options)
    local json = rpf.json
    local marked = {}
    for i, option in ipairs(options) do
      marked[i] = json.object(option)
    end
    return rpf.handoff.encode("rpf:targets_result", { options = json.array(marked) })
  end

  local OPTION = { name = "acme_npcs.talk", label = "Talk", type = "acme_npcs.greeter", id = "0000000a-0000-4000-8000-00000000000a", distance = 1 }

  it("opens a menu of what is near, and sends the pick with its target", function()
    rpf.api.interactions.open()
    answer("rpf:targets", nearby_reply({ OPTION }))
    local menu = c.shown[#c.shown]
    assert.are.equal("menu", menu.kind)
    assert.are.equal("Talk", menu.spec.options[1].label)
    menu.done(1)
    local sent = c.asked[#c.asked]
    assert.are.equal("rpf:interact", sent.name)
    local request = rpf.json.decode(sent.payload)
    assert.are.equal("acme_npcs.talk", request.name)
    assert.are.equal(OPTION.id, request.payload.target.id)
    answer("rpf:interact", rpf.handoff.encode("rpf:interaction_result", { ok = false, reason = "too_far" }))
    local told = c.shown[#c.shown]
    assert.are.equal("notify", told.kind)
    assert.are.equal("too_far", told.spec.text)
  end)

  it("says there is nothing to do when nothing is near, and sends nothing", function()
    rpf.api.interactions.open()
    answer("rpf:targets", nearby_reply({}))
    assert.are.equal("notify", c.shown[#c.shown].kind)
    assert.are.equal("Nothing to do here.", c.shown[#c.shown].spec.text)
    assert.are.equal("rpf:targets", c.asked[#c.asked].name)
  end)

  it("hands a script the options, once, and a timeout when no answer comes", function()
    local heard = {}
    assert.is_true(rpf.api.interactions.nearby(function(options, err)
      heard[#heard + 1] = { options, err }
    end))
    answer("rpf:targets", nearby_reply({ OPTION }))
    assert.are.same({ { { OPTION }, nil } }, heard)
    assert.is_true(rpf.api.interactions.nearby(function(options, err)
      heard[#heard + 1] = { options, err }
    end))
    c.advance(rpf.targets.TIMEOUT_MS)
    assert.are.same({ nil, "timeout" }, heard[2])
    ---@diagnostic disable-next-line: param-type-mismatch
    assert.are.same({ nil, "invalid" }, { rpf.api.interactions.nearby("not a function") })
  end)

  ---The server's answer about an entity.
  ---@param names string[] The names offered.
  ---@return string reply It, encoded.
  local function offers_reply(names)
    return rpf.handoff.encode("rpf:target_offers_result", { names = rpf.json.array(names) })
  end

  ---Every `rpf:target_offers` request the client sent, decoded.
  ---@return table[] requests `{ ref, names }` each, with its callback.
  local function offer_requests()
    local out = {}
    for _, asked in ipairs(c.asked) do
      if asked.name == "rpf:target_offers" then
        local request = rpf.json.decode(asked.payload)
        out[#out + 1] = { ref = request.ref, names = request.names, callback = asked.callback }
      end
    end
    return out
  end

  it("asks the server once per entity for every rule looked at in one turn, and shows only what it offers", function()
    local targets = rpf.targets
    assert.is_false(targets.offered("acme_npcs.talk", 505001), "nothing shown before the server says")
    assert.is_false(targets.offered("acme_npcs.wave", 505001))
    assert.are.equal(0, #offer_requests(), "gathered until the clock turns")
    c.advance(0)
    local requests = offer_requests()
    assert.are.equal(1, #requests)
    assert.are.same({ ref = 505001, names = { "acme_npcs.talk", "acme_npcs.wave" } }, { ref = requests[1].ref, names = requests[1].names })
    requests[1].callback(offers_reply({ "acme_npcs.talk" }))
    assert.is_true(targets.offered("acme_npcs.talk", 505001))
    assert.is_false(targets.offered("acme_npcs.wave", 505001))
    c.advance(0)
    assert.are.equal(1, #offer_requests(), "a fresh answer is not asked again")
  end)

  it("keeps an answer for OFFER_TTL_MS, then asks again while showing the last one", function()
    local targets = rpf.targets
    targets.offered("acme_npcs.talk", 7)
    c.advance(0)
    offer_requests()[1].callback(offers_reply({ "acme_npcs.talk" }))
    c.advance(targets.OFFER_TTL_MS)
    assert.is_true(targets.offered("acme_npcs.talk", 7), "the last answer stands meanwhile")
    c.advance(0)
    local requests = offer_requests()
    assert.are.equal(2, #requests)
    requests[2].callback(offers_reply({}))
    assert.is_false(targets.offered("acme_npcs.talk", 7))
  end)

  it("forgets an entity's answer once a request is made there, and every answer when the rules change", function()
    local targets = rpf.targets
    targets.offered("acme_npcs.talk", 7)
    targets.offered("acme_npcs.talk", 8)
    c.advance(0)
    for _, request in ipairs(offer_requests()) do
      request.callback(offers_reply({ "acme_npcs.talk" }))
    end
    targets.recheck(7)
    assert.is_false(targets.offered("acme_npcs.talk", 7))
    assert.is_true(targets.offered("acme_npcs.talk", 8))
    c.from_server("rpf:target_rules", { rules = rpf.json.array({}) })
    assert.is_false(targets.offered("acme_npcs.talk", 8))
  end)

  it("has at most MAX_OFFERS_ASKING requests waiting, drops a late answer after the rules change, and asks again after a timeout", function()
    local targets = rpf.targets
    for ref = 1, targets.MAX_OFFERS_ASKING + 1 do
      targets.offered("acme_npcs.talk", ref)
    end
    c.advance(0)
    assert.are.equal(targets.MAX_OFFERS_ASKING, #offer_requests())
    local first = offer_requests()[1]
    c.from_server("rpf:target_rules", { rules = rpf.json.array({}) })
    first.callback(offers_reply({ "acme_npcs.talk" }))
    assert.is_false(targets.offered("acme_npcs.talk", first.ref), "an answer to the old rules")
    c.advance(targets.TIMEOUT_MS)
    local before = #offer_requests()
    targets.offered("acme_npcs.talk", 99)
    c.advance(0)
    assert.are.equal(before + 1, #offer_requests(), "the timed-out requests no longer count")
  end)

  it("keeps the server's rules and announces them for a target resource", function()
    local announced
    rpf.api.events.on("interactions.targets", function(rules)
      announced = rules
    end)
    local json = rpf.json
    c.from_server("rpf:target_rules", {
      rules = json.array({
        json.object({ name = "acme_npcs.talk", label = "Talk", type = "acme_npcs.greeter", kind = "ped", distance = 3 }),
      }),
    })
    assert.are.equal("ped", announced[1].kind)
    assert.are.same(announced, rpf.api.interactions.targets())
    c.from_server("rpf:target_rules", "not json")
    assert.are.same(announced, rpf.api.interactions.targets(), "a garbled push changes nothing")
  end)
end)
