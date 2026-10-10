-- Conformance (K4): the DarkRP bridge (`lua/bridges/darkrp/bridge.lua`),
-- over a fake of DarkRP (`spec/support/darkrp_fake.lua`), passes the shared
-- bridge conformance suite on the real Gmod adapter, whose players are
-- `Player` entities, and on the mock platform. Not on FiveM: DarkRP is
-- Gmod's. DarkRP has one implicit character per player and no grades, and
-- never stops while the server runs; what stands in for the steps that
-- leaves out, and what else is particular to DarkRP, is `darkrp_spec.lua`.

local suite = require("spec.support.bridge_conformance")
local darkrp_fake = require("spec.support.darkrp_fake")

---What `conformance.run` needs from busted.
local busted = { describe = describe, it = it, before_each = before_each, after_each = after_each }

suite.run(busted, {
  name = "darkrp",
  origin = "rpf_darkrp",
  framework = darkrp_fake.new,
  register = function(api, fw)
    return darkrp_fake.register(api, fw --[[@as spec.DarkRPFake]])
  end,
  accounts = { "wallet" },
  job = true,
  grades = false,
  implicit = true,
  platforms = { "mock", "gmod" },
})
