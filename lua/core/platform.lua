---The platform interfaces, as the list the core checks at start.
---
---The engine is reached only through a platform table: one per game (the
---adapter) and one for tests (the mock). `meta/platform_*.lua` describe each
---member for the language server, which type-checks every adapter against
---them; this file holds the same members as data, so a platform missing one
---is refused at start with the member named, not discovered at the first call
---that needs it. A test keeps the two lists in step.
---@class rpf.platform
---@field SERVER rpf.platform.Member[] What `rpf.ServerPlatform` must provide.
---@field CLIENT rpf.platform.Member[] What `rpf.ClientPlatform` must provide.
local platform = {}

---One member a platform must provide.
---@class rpf.platform.Member
---@field name string The key on the platform table.
---@field kind "string"|"function"|"table" The Lua type its value must have.

---Members that are not functions, and what they are.
---@type table<string, "string"|"table">
local KINDS = { engine = "string", capabilities = "table" }

---Builds a member list from names, all functions but those `KINDS` names.
---@param names string[] The member names, in the order the README lists them.
---@return rpf.platform.Member[] members The list.
local function members(names)
  local out = {}
  for i, name in ipairs(names) do
    out[i] = { name = name, kind = KINDS[name] or "function" }
  end
  return out
end

platform.SERVER = members({
  "engine",
  "connect",
  "disconnect",
  "send",
  "http_request",
  "now",
  "after",
  "kv_get",
  "kv_set",
  "random_hex",
  "thread",
  "identifiers",
  "name",
  "kick",
  "notify",
  "to_client",
  "on_client",
  "on_client_request",
  "log",
  "expose",
  "capabilities",
})

platform.CLIENT = members({
  "engine",
  "http_request",
  "kv_get",
  "kv_set",
  "now",
  "after",
  "to_server",
  "on_server",
  "request_server",
  "log",
  "expose",
})

---Lists what a platform table lacks for one side. `engine` must also be a
---non-empty string, since it is reported in `Hello`.
---@param candidate any The table an adapter or test supplied.
---@param side "server"|"client" Which interface to check it against.
---@return string[] missing Each missing or mistyped member as `name (kind)`, in interface order. Empty when the platform is complete.
function platform.missing(candidate, side)
  local list = side == "client" and platform.CLIENT or platform.SERVER
  local missing = {}
  if type(candidate) ~= "table" then
    for _, member in ipairs(list) do
      missing[#missing + 1] = member.name .. " (" .. member.kind .. ")"
    end
    return missing
  end
  for _, member in ipairs(list) do
    local value = candidate[member.name]
    if type(value) ~= member.kind or (member.kind == "string" and value == "") then
      missing[#missing + 1] = member.name .. " (" .. member.kind .. ")"
    end
  end
  return missing
end

---Refuses to go on with an incomplete platform, naming every missing member.
---
---This throws rather than returning, because it runs at start and there is
---nothing sensible to do with half a platform: better a loud error in the
---server console naming the adapter's gap than a nil call deep in a retry.
---@param candidate any The table an adapter or test supplied.
---@param side "server"|"client" Which interface to check it against.
function platform.check(candidate, side)
  local missing = platform.missing(candidate, side)
  if #missing > 0 then
    error("rpf: the " .. side .. " platform is missing " .. table.concat(missing, ", "), 2)
  end
end

rpf.platform = platform
return platform
