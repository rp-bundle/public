---The server platform's `random_hex`, from the best randomness Gmod offers.
---
---Gmod gives Lua no cryptographic random source: `math.random` is the
---engine's seeded generator, and the file library cannot read the operating
---system's. So this is SHA-256 (`util.SHA256`) in counter mode over a secret
---pool, seeded from what differs between processes and is hard to guess from
---outside (the high-resolution timer, the wall clock, table addresses, which
---move with address-space randomisation, the engine's generator, and the
---garbage collector's state), with fresh timer jitter stirred into every
---block. The core mints envelope ids, the instance id, transfer `client_id`s
---and backoff jitter from it. None of those is a credential: they must be
---unique, and the instance id must differ between two processes sharing a
---key, which this gives.
---@class rpf.gmod.Random
local random = {}

---The secret state every block is drawn from.
---@type string?
local state = nil

---Blocks drawn since the state was seeded.
local counter = 0

---Seeds the state from everything this process can see that another would
---not share.
local function seed()
  state = util.SHA256(table.concat({
    tostring({}),
    tostring(seed),
    string.format("%.9f", SysTime()),
    tostring(os.time()),
    string.format("%.9f", os.clock()),
    tostring(collectgarbage("count")),
    tostring(math.random()),
    tostring(math.random()),
    tostring(math.random()),
  }, "|"))
end

---Random lowercase hex digits.
---@param n integer How many.
---@return string hex Exactly `n` characters from `0-9a-f`.
function random.hex(n)
  if not state then
    seed()
  end
  local blocks = {}
  local have = 0
  while have < n do
    counter = counter + 1
    local block = string.lower(util.SHA256(table.concat({
      state,
      tostring(counter),
      string.format("%.9f", SysTime()),
      tostring(math.random()),
    }, "|")))
    blocks[#blocks + 1] = block
    have = have + #block
  end
  state = util.SHA256(state .. "|next|" .. tostring(counter))
  return table.concat(blocks):sub(1, n)
end

return random
