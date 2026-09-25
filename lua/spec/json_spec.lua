-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

local support = require("spec.support")

describe("rpf.json", function()
  local json

  before_each(function()
    json = support.load_core().json
  end)

  describe("numbers", function()
    it("accepts every integer up to 2^53 - 1 in either direction", function()
      assert.are.equal(9007199254740991, json.decode("9007199254740991"))
      assert.are.equal(-9007199254740991, json.decode("-9007199254740991"))
      assert.are.equal("9007199254740991", json.encode(9007199254740991))
      assert.are.equal("-9007199254740991", json.encode(-9007199254740991))
    end)

    -- LuaJIT numbers are doubles, so each of these would decode as a
    -- different integer from the one sent. Refused, not rounded.
    it("refuses integers beyond 2^53 - 1 on decode rather than rounding them", function()
      for _, text in ipairs({
        "9007199254740992",
        "9007199254740993",
        "-9007199254740992",
        "-9007199254740993",
        "18446744073709551615",
        "100000000000000000000",
        "1e16",
        "9.007199254740993e15",
      }) do
        local value, err = json.decode(text)
        assert.is_nil(value, text)
        assert.truthy(err:find("2^53", 1, true), text .. ": " .. tostring(err))
      end
    end)

    it("refuses to encode an integer it could not decode", function()
      local text, err = json.encode(2 ^ 53)
      assert.is_nil(text)
      assert.truthy(err:find("2^53", 1, true))
    end)

    it("writes integers without a fraction on every Lua", function()
      assert.are.equal("7", json.encode(7))
      assert.are.equal("7", json.encode(7.0))
      assert.are.equal("-250", json.encode(-250))
      assert.are.equal("0", json.encode(-0.0))
    end)

    it("round-trips fractions exactly", function()
      for _, n in ipairs({ 0.1, 1.5, -2.25, 1 / 3, 123.456 }) do
        assert.are.equal(n, json.decode(json.encode(n)))
      end
    end)

    it("refuses NaN and infinities", function()
      assert.is_nil(json.encode(0 / 0))
      assert.is_nil(json.encode(math.huge))
      assert.is_nil(json.encode(-math.huge))
    end)

    it("refuses malformed numbers", function()
      for _, text in ipairs({ "01", "-", "1.", ".5", "1e", "+1", "0x10", "1.5e+" }) do
        assert.is_nil(json.decode(text), text)
      end
    end)
  end)

  describe("empty tables", function()
    -- The engines' own codecs disagree on this, which is why the core
    -- bundles its own.
    it("refuses an unmarked empty table rather than guessing", function()
      local text, err = json.encode({})
      assert.is_nil(text)
      assert.truthy(err:find("json.array or json.object", 1, true))
    end)

    it("encodes marked empty tables as marked", function()
      assert.are.equal("[]", json.encode(json.array()))
      assert.are.equal("{}", json.encode(json.object()))
    end)

    it("keeps the shape it decoded", function()
      assert.are.equal("[]", json.encode(json.decode("[]")))
      assert.are.equal("{}", json.encode(json.decode("{}")))
      assert.are.equal('{"a":[],"b":{}}', json.encode(json.decode('{"b":{},"a":[]}')))
    end)
  end)

  describe("null", function()
    it("decodes to json.null, not nil, so present and absent differ", function()
      local value = json.decode('{"a":null}')
      assert.are.equal(json.null, value.a)
      assert.is_nil(value.b)
    end)

    it("keeps nulls in arrays", function()
      local value = json.decode("[1,null,3]")
      assert.are.equal(3, #value)
      assert.are.equal(json.null, value[2])
      assert.are.equal("[1,null,3]", json.encode(value))
    end)
  end)

  describe("strings", function()
    it("round-trips escapes", function()
      local s = 'quote " backslash \\ newline \n tab \t control \1 slash /'
      assert.are.equal(s, json.decode(json.encode(s)))
    end)

    it("decodes \\u escapes, including surrogate pairs, to UTF-8", function()
      assert.are.equal("é", json.decode('"\\u00e9"'))
      assert.are.equal("€", json.decode('"\\u20ac"'))
      assert.are.equal("😀", json.decode('"\\ud83d\\ude00"'))
      assert.are.equal("/", json.decode('"\\/"'))
    end)

    it("leaves UTF-8 alone when encoding", function()
      assert.are.equal('"é€😀"', json.encode("é€😀"))
    end)

    it("refuses lone surrogates, bad escapes and raw control characters", function()
      for _, text in ipairs({ '"\\ud83d"', '"\\ude00"', '"\\x41"', '"\\u12"', '"a\nb"', '"a\0b"', '"open' }) do
        assert.is_nil(json.decode(text), text)
      end
    end)
  end)

  describe("structure", function()
    it("sorts object keys, so the same table always encodes the same", function()
      assert.are.equal('{"a":1,"b":2,"c":3}', json.encode({ c = 3, a = 1, b = 2 }))
    end)

    it("refuses tables it cannot encode faithfully", function()
      assert.is_nil(json.encode({ 1, 2, nil, 4 }))
      assert.is_nil(json.encode({ 1, a = 2 }))
      assert.is_nil(json.encode({ [1.5] = true }))
      assert.is_nil(json.encode({ f = function() end }))
      local cycle = {}
      cycle.self = cycle
      assert.is_nil(json.encode(cycle))
    end)

    it("refuses duplicate keys, trailing data and truncated documents", function()
      for _, text in ipairs({ '{"a":1,"a":2}', "{} {}", "[1,2", '{"a":1,}', "[1,]", "", "  ", "nul", "tru" }) do
        assert.is_nil(json.decode(text), text)
      end
    end)

    it("refuses nesting deeper than MAX_DEPTH without exhausting the stack", function()
      local deep = string.rep("[", json.MAX_DEPTH + 1) .. string.rep("]", json.MAX_DEPTH + 1)
      local value, err = json.decode(deep)
      assert.is_nil(value)
      assert.truthy(err:find("nested", 1, true))
      local fine = string.rep("[", json.MAX_DEPTH) .. string.rep("]", json.MAX_DEPTH)
      assert.is_not_nil(json.decode(fine))
    end)

    it("never throws on hostile input", function()
      for _, text in ipairs({ "{", "}", "[[[", '{"a"', '{"a":}', "\255\254", '{1:2}' }) do
        local ok = pcall(json.decode, text)
        assert.is_true(ok, text)
      end
      assert.is_nil(json.decode(42))
    end)

    it("round-trips a nested document", function()
      local text = '{"a":[1,2,{"b":null}],"c":{"d":true,"e":false,"f":"g"}}'
      assert.are.equal(text, json.encode(json.decode(text)))
    end)
  end)
end)
