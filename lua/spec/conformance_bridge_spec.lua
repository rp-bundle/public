-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Conformance (K2): the mock bridge, over the fake framework, passes the
-- shared bridge conformance suite on the mock platform and on the real
-- FiveM and Gmod adapters. K3's Qbox bridge and K4's DarkRP bridge run the
-- same suite, with fakes of their own frameworks.

local suite = require("spec.support.bridge_conformance")
local mock_framework = require("spec.support.mock_framework")
local mock_bridge = require("spec.support.mock_bridge")

---What `conformance.run` needs from busted.
local busted = { describe = describe, it = it, before_each = before_each, after_each = after_each }

suite.run(busted, {
  name = "mock",
  origin = "mockfw_bridge",
  framework = mock_framework.new,
  register = mock_bridge.register,
  accounts = { "cash", "bank" },
  item = "water",
  job = true,
})

-- A framework with one account and no items (DarkRP's shape): the suite
-- holds without a second account, and the item calls are unsupported.
suite.run(busted, {
  name = "single-account mock",
  origin = "mockfw_bridge",
  framework = mock_framework.new,
  register = function(api, fw)
    return mock_bridge.register(api, fw --[[@as spec.MockFramework]], { accounts = { "wallet" }, items = false })
  end,
  accounts = { "wallet" },
  job = true,
})
