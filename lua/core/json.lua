---The core's own JSON codec, in pure Lua.
---
---Bundled rather than borrowed from the engine, because the engines disagree:
---one encodes an empty table as an array and the other as an object, and they
---differ on how numbers come out. The protocol corpus is the contract, so the
---codec that reads it has to be the same one on every engine, and the corpus
---tests go through this one.
---
---Four rules make it stricter than a general-purpose codec:
---
--- - **Empty tables are ambiguous, so they are refused** unless marked with
---   `json.array` or `json.object`. Decoded tables carry the mark, so what was
---   decoded re-encodes to the same shape.
--- - **Null is a value**, `json.null`, not `nil`, so "sent as null" and "left
---   out" stay distinguishable. The protocol requires some fields to be sent as
---   null, and a missing one is a bug.
--- - **Numbers are held to what a double represents exactly.** LuaJIT numbers
---   are doubles, so an integer beyond 2^53 − 1 would silently become a
---   different integer. The decoder refuses one instead of rounding it, and the
---   encoder refuses to produce one.
--- - **Strings are UTF-8 text, both ways.** Lua strings are bytes, and game
---   code can hand the core any bytes, but the portal reads frames with
---   serde_json from websocket text frames, and both require UTF-8. A frame
---   with one bad byte would be refused every time the outbox re-sent it, so
---   the encoder refuses to produce one and the decoder refuses to accept
---   one. `json.is_utf8` lets a caller refuse such text where it is written,
---   and `json.repair_utf8` lets it keep text it only reports for display.
---@class rpf.json
---@field null table The JSON null. Compare with `==`; it is a unique table, never `nil`.
---@field MAX_SAFE_INTEGER number 2^53 − 1, the widest integer a double holds exactly, and so the widest the codec accepts.
---@field MAX_DEPTH integer How deeply arrays and objects may nest before decoding is refused, so hostile input cannot exhaust the stack.
---@field REPLACEMENT string U+FFFD, the replacement character, as UTF-8: what `json.repair_utf8` puts in place of each bad sequence.
local json = {}

json.MAX_SAFE_INTEGER = 9007199254740991
json.MAX_DEPTH = 100
json.REPLACEMENT = "\239\191\189"

---Metatable marking a table as a JSON array.
local ARRAY = { __name = "rpf.json.array" }
---Metatable marking a table as a JSON object.
local OBJECT = { __name = "rpf.json.object" }

json.null = setmetatable({}, {
  __name = "rpf.json.null",
  __tostring = function()
    return "null"
  end,
})

---Marks a table as a JSON array, so it encodes as `[]` even when empty.
---@generic T: table
---@param t T? The array, or nil for a new empty one.
---@return T array The same table, marked.
function json.array(t)
  return setmetatable(t or {}, ARRAY)
end

---Marks a table as a JSON object, so it encodes as `{}` even when empty.
---@generic T: table
---@param t T? The object, or nil for a new empty one.
---@return T object The same table, marked.
function json.object(t)
  return setmetatable(t or {}, OBJECT)
end

---Whether a value was decoded from, or marked as, a JSON array.
---@param value any Anything.
---@return boolean array True only for a marked table.
function json.is_array(value)
  return type(value) == "table" and getmetatable(value) == ARRAY
end

---Whether a value was decoded from, or marked as, a JSON object.
---@param value any Anything.
---@return boolean object True only for a marked table.
function json.is_object(value)
  return type(value) == "table" and getmetatable(value) == OBJECT
end

---A deep copy of a decoded JSON value, keeping the array and object marks so
---the copy encodes exactly as the original did. Modules that hand out what
---they hold (`rpf.config`, `rpf.records`) give copies, so a caller editing
---one cannot change what every other module reads.
---@generic T
---@param value T The value.
---@return T copy The copy. `json.null` and scalars are returned as they are.
function json.copy(value)
  if type(value) ~= "table" or value == json.null then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = json.copy(v)
  end
  return setmetatable(out, getmetatable(value))
end

-- UTF-8 ------------------------------------------------------------------

---The length of the UTF-8 sequence a lead byte starts, and the range its
---second byte may take. The narrowed ranges after E0, ED, F0 and F4 are what
---rule out overlong forms, the UTF-16 surrogates and code points past
---U+10FFFF, exactly as Rust's `str` does. Nil for a byte that cannot start a
---multi-byte sequence: a continuation byte, C0, C1, or F5 and above.
---@param lead integer The first byte, 0x80 or above.
---@return integer? length 2, 3 or 4.
---@return integer? low The smallest second byte allowed.
---@return integer? high The largest second byte allowed.
local function sequence(lead)
  if lead >= 0xC2 and lead <= 0xDF then
    return 2, 0x80, 0xBF
  elseif lead == 0xE0 then
    return 3, 0xA0, 0xBF
  elseif (lead >= 0xE1 and lead <= 0xEC) or lead == 0xEE or lead == 0xEF then
    return 3, 0x80, 0xBF
  elseif lead == 0xED then
    return 3, 0x80, 0x9F
  elseif lead == 0xF0 then
    return 4, 0x90, 0xBF
  elseif lead >= 0xF1 and lead <= 0xF3 then
    return 4, 0x80, 0xBF
  elseif lead == 0xF4 then
    return 4, 0x80, 0x8F
  end
  return nil
end

---How many bytes of a well-formed sequence start at `i`, or nil if the bytes
---there are not one. The second number is how many bytes from `i` are the
---longest prefix of a sequence that is still valid, at least one, which is
---what `json.repair_utf8` replaces as one bad sequence.
---@param s string The string.
---@param i integer Where a byte of 0x80 or above stands.
---@return integer? length The sequence's length, or nil if it is malformed.
---@return integer bad On a malformed one, how many bytes to replace.
local function read_sequence(s, i)
  local length, low, high = sequence(s:byte(i))
  if not length then
    return nil, 1
  end
  local second = s:byte(i + 1)
  if not second or second < low or second > high then
    return nil, 1
  end
  for j = i + 2, i + length - 1 do
    local byte = s:byte(j)
    if not byte or byte < 0x80 or byte > 0xBF then
      return nil, j - i
    end
  end
  return length, 0
end

---Whether a string is well-formed UTF-8, as the portal requires of every
---string in a frame. Lua strings are bytes, so text from an engine or a
---player (a name, a typed description) may not be, and one cut to a byte
---limit may end inside a sequence. Use it to refuse such text where it is
---written, so it never reaches a frame.
---@param s string The string.
---@return boolean ok True if every byte belongs to a well-formed sequence.
function json.is_utf8(s)
  if not s:find("[\128-\255]") then
    return true
  end
  local i, n = 1, #s
  while i <= n do
    if s:byte(i) < 0x80 then
      i = i + 1
    else
      local length = read_sequence(s, i)
      if not length then
        return false
      end
      i = i + length
    end
  end
  return true
end

---A string with every malformed sequence replaced by U+FFFD, as Rust's
---`String::from_utf8_lossy` does it (one replacement for each longest
---invalid prefix), so the portal would show the same text had it been sent
---the raw bytes. Only for text the core reports for display, an engine's
---player name or a drop reason, where refusing it would lose a join or a
---drop. Text that is data (a record's field, a password) is refused instead,
---because a silent change to it is worse.
---@param s string The string.
---@return string text The string, unchanged if it was already UTF-8.
function json.repair_utf8(s)
  if json.is_utf8(s) then
    return s
  end
  local parts, i, n, start = {}, 1, #s, 1
  while i <= n do
    if s:byte(i) < 0x80 then
      i = i + 1
    else
      local length, bad = read_sequence(s, i)
      if length then
        i = i + length
      else
        parts[#parts + 1] = s:sub(start, i - 1)
        parts[#parts + 1] = json.REPLACEMENT
        i = i + bad
        start = i
      end
    end
  end
  parts[#parts + 1] = s:sub(start)
  return table.concat(parts)
end

-- Encoding ---------------------------------------------------------------

---The escape for each character a JSON string may not hold raw.
---@type table<string, string>
local ESCAPES = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

---Escapes one character for a JSON string.
---@param char string A single character matched by the escape pattern.
---@return string escaped Its JSON escape.
local function escape_char(char)
  return ESCAPES[char] or string.format("\\u%04x", string.byte(char))
end

---Encodes a string, leaving UTF-8 as it is. A string that is not UTF-8 is
---refused, because the portal could not decode the frame. The error does not
---quote it: it may be a secret, or bytes no log should carry.
---@param s string The string.
---@return string encoded The quoted JSON string.
local function encode_string(s)
  if not json.is_utf8(s) then
    error("cannot encode a string that is not valid UTF-8 (" .. #s .. " bytes)", 0)
  end
  return '"' .. s:gsub('[%c"\\]', escape_char) .. '"'
end

---Encodes a number. Integers are written without a fraction on every Lua, so
---5.4's integer subtype and LuaJIT's doubles produce the same text.
---@param n number The number.
---@return string encoded Its JSON text.
local function encode_number(n)
  if n ~= n or n == math.huge or n == -math.huge then
    error("cannot encode " .. tostring(n) .. ": JSON has no such number", 0)
  end
  if n == math.floor(n) then
    if n > json.MAX_SAFE_INTEGER or n < -json.MAX_SAFE_INTEGER then
      error("cannot encode " .. string.format("%.0f", n) .. ": beyond 2^53 - 1, a double cannot hold it exactly", 0)
    end
    if n == 0 then
      return "0"
    end
    return string.format("%.0f", n)
  end
  -- The shortest form that reads back as the same double.
  for precision = 14, 17 do
    local text = string.format("%." .. precision .. "g", n)
    if tonumber(text) == n then
      return text
    end
  end
  return string.format("%.17g", n)
end

local encode_value

---Encodes a table as an array or an object: by its mark if it has one,
---otherwise by its keys. An unmarked empty table, or one mixing kinds of key,
---is refused rather than guessed at.
---@param t table The table.
---@param depth integer How deeply it is nested.
---@param seen table<table, true> Tables on the current path, to refuse cycles.
---@return string encoded Its JSON text.
local function encode_table(t, depth, seen)
  if seen[t] then
    error("cannot encode a table that contains itself", 0)
  end
  if depth > json.MAX_DEPTH then
    error("cannot encode: nested deeper than " .. json.MAX_DEPTH, 0)
  end

  local mark = getmetatable(t)
  local count, strings, max_index = 0, 0, 0
  for key in pairs(t) do
    count = count + 1
    if type(key) == "string" then
      strings = strings + 1
    elseif type(key) == "number" and key >= 1 and key == math.floor(key) then
      if key > max_index then
        max_index = key
      end
    else
      error("cannot encode a table key of type " .. type(key), 0)
    end
  end

  local as_array
  if mark == ARRAY then
    as_array = true
  elseif mark == OBJECT then
    as_array = false
  elseif count == 0 then
    error("cannot encode an empty table: mark it with json.array or json.object", 0)
  else
    as_array = strings == 0
  end

  seen[t] = true
  local parts = {}
  if as_array then
    if strings > 0 or max_index ~= count then
      error("cannot encode an array with holes or string keys", 0)
    end
    for i = 1, count do
      parts[i] = encode_value(t[i], depth + 1, seen)
    end
    seen[t] = nil
    return "[" .. table.concat(parts, ",") .. "]"
  end

  if strings ~= count then
    error("cannot encode an object with non-string keys", 0)
  end
  local keys = {}
  for key in pairs(t) do
    keys[#keys + 1] = key
  end
  -- Sorted, so the same table always encodes to the same text.
  table.sort(keys)
  for i, key in ipairs(keys) do
    parts[i] = encode_string(key) .. ":" .. encode_value(t[key], depth + 1, seen)
  end
  seen[t] = nil
  return "{" .. table.concat(parts, ",") .. "}"
end

---Encodes any encodable value.
---@param value any The value.
---@param depth integer How deeply it is nested.
---@param seen table<table, true> Tables on the current path.
---@return string encoded Its JSON text.
encode_value = function(value, depth, seen)
  local kind = type(value)
  if value == json.null then
    return "null"
  elseif kind == "string" then
    return encode_string(value)
  elseif kind == "number" then
    return encode_number(value)
  elseif kind == "boolean" then
    return value and "true" or "false"
  elseif kind == "table" then
    return encode_table(value, depth, seen)
  end
  error("cannot encode a value of type " .. kind, 0)
end

---Encodes a value as compact JSON, with object keys sorted.
---@param value any A string, number, boolean, `json.null`, or a table of those.
---@return string? text The JSON, or nil if the value cannot be encoded.
---@return string? err Why it cannot, naming the offending value.
function json.encode(value)
  local ok, result = pcall(encode_value, value, 0, {})
  if ok then
    return result, nil
  end
  return nil, tostring(result)
end

-- Decoding ---------------------------------------------------------------

---Parser state for one decode.
---@class rpf.json.Reader
---@field text string The input.
---@field pos integer The next byte to read.
---@field depth integer How deeply the current value is nested.

---Stops decoding with a message that says where.
---@param r rpf.json.Reader The reader.
---@param message string What was wrong.
local function fail(r, message)
  error("invalid JSON at byte " .. r.pos .. ": " .. message, 0)
end

---Skips JSON whitespace, which is exactly space, tab, newline and return.
---@param r rpf.json.Reader The reader.
local function skip_space(r)
  local _, stop = r.text:find("^[ \t\n\r]*", r.pos)
  r.pos = stop + 1
end

---Converts a code point to UTF-8, with arithmetic because 5.1 has no bitwise
---operators and no `utf8` library.
---@param cp integer A code point, 0 to 0x10FFFF.
---@return string utf8 Its UTF-8 bytes.
local function utf8_char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(
    0xF0 + math.floor(cp / 0x40000),
    0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40,
    0x80 + cp % 0x40
  )
end

---Reads four hex digits of a `\u` escape.
---@param r rpf.json.Reader The reader, positioned after the `u`.
---@return integer unit The UTF-16 code unit.
local function read_hex4(r)
  local hex = r.text:match("^%x%x%x%x", r.pos)
  if not hex then
    fail(r, "a \\u escape needs four hex digits")
  end
  r.pos = r.pos + 4
  return tonumber(hex, 16) --[[@as integer]]
end

---The character each single-letter escape stands for.
---@type table<string, string>
local UNESCAPES = {
  ['"'] = '"',
  ["\\"] = "\\",
  ["/"] = "/",
  b = "\b",
  f = "\f",
  n = "\n",
  r = "\r",
  t = "\t",
}

---Reads a string, positioned on its opening quote.
---@param r rpf.json.Reader The reader.
---@return string value The decoded string.
local function read_string(r)
  local text = r.text
  r.pos = r.pos + 1
  local parts = {}
  while true do
    local stop = text:find('["\\]', r.pos)
    if not stop then
      fail(r, "unterminated string")
    end
    ---@cast stop integer
    local chunk = text:sub(r.pos, stop - 1)
    if chunk:find("[\1-\31]") or chunk:find("\0", 1, true) then
      fail(r, "a raw control character in a string")
    end
    -- Chunks end at `"` or `\`, which never fall inside a sequence, so
    -- checking each one checks the whole string.
    if not json.is_utf8(chunk) then
      fail(r, "a string that is not valid UTF-8")
    end
    parts[#parts + 1] = chunk
    r.pos = stop + 1
    if text:sub(stop, stop) == '"' then
      return table.concat(parts)
    end

    local escape = text:sub(r.pos, r.pos)
    r.pos = r.pos + 1
    if escape == "u" then
      local unit = read_hex4(r)
      if unit >= 0xD800 and unit <= 0xDBFF then
        if text:sub(r.pos, r.pos + 1) ~= "\\u" then
          fail(r, "a lone high surrogate")
        end
        r.pos = r.pos + 2
        local low = read_hex4(r)
        if low < 0xDC00 or low > 0xDFFF then
          fail(r, "a high surrogate not followed by a low one")
        end
        unit = 0x10000 + (unit - 0xD800) * 0x400 + (low - 0xDC00)
      elseif unit >= 0xDC00 and unit <= 0xDFFF then
        fail(r, "a lone low surrogate")
      end
      parts[#parts + 1] = utf8_char(unit)
    elseif UNESCAPES[escape] then
      parts[#parts + 1] = UNESCAPES[escape]
    else
      fail(r, "an unknown escape \\" .. escape)
    end
  end
end

---The widest integer literal accepted, as digits, compared as text so the
---check happens before the double has rounded anything.
local MAX_DIGITS = "9007199254740991"

---Reads a number. An integer literal is checked digit by digit against
---2^53 − 1; anything with a fraction or exponent is checked as the double it
---parses to, and refused if its magnitude reaches 2^53.
---@param r rpf.json.Reader The reader.
---@return number value The number.
local function read_number(r)
  local text = r.text
  local start = r.pos
  local _, int_end, minus, digits = text:find("^(-?)(%d+)", start)
  if not int_end then
    fail(r, "expected a value")
  end
  ---@cast int_end integer
  if #digits > 1 and digits:sub(1, 1) == "0" then
    fail(r, "a number with a leading zero")
  end
  local stop = int_end
  local _, frac_end = text:find("^%.%d+", stop + 1)
  if frac_end then
    stop = frac_end
  elseif text:sub(stop + 1, stop + 1) == "." then
    fail(r, "a fraction needs digits")
  end
  local _, exp_end = text:find("^[eE][-+]?%d+", stop + 1)
  if exp_end then
    stop = exp_end
  elseif text:find("^[eE]", stop + 1) then
    fail(r, "an exponent needs digits")
  end

  local literal = text:sub(start, stop)
  local value = tonumber(literal) --[[@as number]]
  if stop == int_end then
    if #digits > #MAX_DIGITS or (#digits == #MAX_DIGITS and digits > MAX_DIGITS) then
      fail(r, "the integer " .. literal .. " is beyond 2^53 - 1, and would be rounded")
    end
    if minus == "-" and value == 0 then
      value = 0
    end
  elseif value >= 2 ^ 53 or value <= -(2 ^ 53) then
    fail(r, "the number " .. literal .. " is beyond 2^53, and would be rounded")
  end
  r.pos = stop + 1
  return value
end

local read_value

---Reads an array, positioned on its `[`.
---@param r rpf.json.Reader The reader.
---@return table array The decoded array, marked.
local function read_array(r)
  r.pos = r.pos + 1
  local out = json.array()
  skip_space(r)
  if r.text:sub(r.pos, r.pos) == "]" then
    r.pos = r.pos + 1
    return out
  end
  while true do
    out[#out + 1] = read_value(r)
    skip_space(r)
    local c = r.text:sub(r.pos, r.pos)
    r.pos = r.pos + 1
    if c == "]" then
      return out
    elseif c ~= "," then
      r.pos = r.pos - 1
      fail(r, "expected , or ] in an array")
    end
  end
end

---Reads an object, positioned on its `{`. A repeated key is refused, as the
---portal refuses one, rather than letting the last one silently win.
---@param r rpf.json.Reader The reader.
---@return table object The decoded object, marked.
local function read_object(r)
  r.pos = r.pos + 1
  local out = json.object()
  skip_space(r)
  if r.text:sub(r.pos, r.pos) == "}" then
    r.pos = r.pos + 1
    return out
  end
  while true do
    skip_space(r)
    if r.text:sub(r.pos, r.pos) ~= '"' then
      fail(r, "an object key must be a string")
    end
    local key = read_string(r)
    if out[key] ~= nil then
      fail(r, "the key " .. key .. " appears twice")
    end
    skip_space(r)
    if r.text:sub(r.pos, r.pos) ~= ":" then
      fail(r, "expected : after an object key")
    end
    r.pos = r.pos + 1
    out[key] = read_value(r)
    skip_space(r)
    local c = r.text:sub(r.pos, r.pos)
    r.pos = r.pos + 1
    if c == "}" then
      return out
    elseif c ~= "," then
      r.pos = r.pos - 1
      fail(r, "expected , or } in an object")
    end
  end
end

---Reads any value.
---@param r rpf.json.Reader The reader.
---@return any value The decoded value.
read_value = function(r)
  skip_space(r)
  local c = r.text:sub(r.pos, r.pos)
  if c == "{" or c == "[" then
    r.depth = r.depth + 1
    if r.depth > json.MAX_DEPTH then
      fail(r, "nested deeper than " .. json.MAX_DEPTH)
    end
    local value
    if c == "{" then
      value = read_object(r)
    else
      value = read_array(r)
    end
    r.depth = r.depth - 1
    return value
  elseif c == '"' then
    return read_string(r)
  elseif c == "n" and r.text:sub(r.pos, r.pos + 3) == "null" then
    r.pos = r.pos + 4
    return json.null
  elseif c == "t" and r.text:sub(r.pos, r.pos + 3) == "true" then
    r.pos = r.pos + 4
    return true
  elseif c == "f" and r.text:sub(r.pos, r.pos + 4) == "false" then
    r.pos = r.pos + 5
    return false
  elseif c == "" then
    fail(r, "unexpected end of input")
  end
  return read_number(r)
end

---Decodes one JSON document. Arrays and objects come back marked, null comes
---back as `json.null`, and anything after the document is refused.
---@param text string The JSON text. Hostile input is expected: every failure is a return value, never a thrown error.
---@return any value The decoded value, or nil on failure.
---@return string? err Why the text was refused.
function json.decode(text)
  if type(text) ~= "string" then
    return nil, "cannot decode a " .. type(text) .. ", only a string"
  end
  ---@type rpf.json.Reader
  local r = { text = text, pos = 1, depth = 0 }
  local ok, result = pcall(function()
    local value = read_value(r)
    skip_space(r)
    if r.pos <= #text then
      fail(r, "trailing characters after the document")
    end
    return value
  end)
  if ok then
    return result, nil
  end
  return nil, tostring(result)
end

rpf.json = json
return json
