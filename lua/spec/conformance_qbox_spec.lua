-- Conformance (K3): the Qbox bridge (`lua/bridges/qbox/bridge.lua`), over a
-- fake of qbx_core and ox_inventory (`spec/support/qbox_fake.lua`), passes
-- the shared bridge conformance suite on the real FiveM adapter, and on the
-- mock platform, whose players are numbers as FiveM's server ids are. Not
-- on Gmod: Qbox is FiveM's, and a Gmod player is a `Player`. What is
-- particular to Qbox is `qbox_spec.lua`.

local suite = require("spec.support.bridge_conformance")
local qbox_fake = require("spec.support.qbox_fake")

---What `conformance.run` needs from busted.
local busted = { describe = describe, it = it, before_each = before_each, after_each = after_each }

suite.run(busted, {
  name = "qbox",
  origin = "rpf-qbox",
  framework = qbox_fake.new,
  register = function(api, fw)
    return qbox_fake.register(api, fw --[[@as spec.QboxFake]])
  end,
  accounts = { "cash", "bank", "crypto" },
  item = "water",
  job = true,
  platforms = { "mock", "fivem" },
})
