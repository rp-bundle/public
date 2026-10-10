---Everything the FiveM adapter takes from ox_lib (J10, #239), in one file,
---so leaving it is one file's work: upstream has moved once already.
---
---ox_lib is a dependency of the `rpf` resource (`fxmanifest.lua`), loaded
---into this resource's Lua state by `@ox_lib/init.lua` as the `lib` global.
---FXServer starts it first, and refuses to start `rpf` without it; one that
---is too old is refused here, at start, in one line (`ox.problem`). It is
---LGPL-3.0, so a release names it as a prerequisite and never bundles it.
---
---What it carries here is a request and its answer between a client and
---the server (`request_server`, `on_client_request`): `lib.callback` pairs
---them. It is only the transport. A client reaches one fixed name per
---request kind, and what it asks for is checked by the core
---(`rpf.interactions`), never by a handler ox_lib calls directly. The login
---and character screens are RPF's own NUI and never touch ox_lib: its
---dialogs hand their values to Lua, and a password must never reach Lua.
---@class rpf.fivem.ox
---@field RESOURCE string The resource's name.
---@field MAX_UNANSWERED integer The most requests this client has open over `lib.callback` at once: ox_lib keeps each until its answer comes and never expires one sent with a callback, so past this a request is answered with nothing rather than left in its table.
---@field MINIMUM string The oldest release the adapter accepts. 3.40.0 is the first whose server checks who answers a server-to-client callback, which `rpf.api.ui` relies on.
---@field RELEASES_URL string Where an owner gets it.
local ox = {}

ox.RESOURCE = "ox_lib"
ox.MINIMUM = "3.40.0"
ox.MAX_UNANSWERED = 256
ox.RELEASES_URL = "https://github.com/overextended/ox_lib/releases"

---The three numbers of a `MAJOR.MINOR.PATCH` version, anything after them
---ignored.
---@param version any The version, as a resource's metadata gives it.
---@return integer[]? numbers The numbers, or nil for anything else.
local function numbers(version)
  if type(version) ~= "string" then
    return nil
  end
  local major, minor, patch = version:match("^v?(%d+)%.(%d+)%.(%d+)")
  if not major then
    return nil
  end
  return { tonumber(major), tonumber(minor), tonumber(patch) }
end

---Whether a version is at least another.
---@param version string? The version installed.
---@param minimum string The oldest accepted.
---@return boolean ok True if it is.
function ox.at_least(version, minimum)
  local have, want = numbers(version), assert(numbers(minimum))
  if not have then
    return false
  end
  for i = 1, 3 do
    if have[i] ~= want[i] then
      return have[i] > want[i]
    end
  end
  return true
end

---Why the adapter cannot use the ox_lib it has, as the one line an owner
---reads, or nil if it can: not started, not loaded into this resource, or
---older than `MINIMUM`. `docs/installing.md`'s troubleshooting is keyed by
---these lines.
---@return string? problem What is wrong and what to do about it.
function ox.problem()
  local state = GetResourceState(ox.RESOURCE)
  if state ~= "started" or type(rawget(_G, "lib")) ~= "table" then
    return "rpf: ox_lib is "
      .. tostring(state)
      .. ", and RPF's FiveM adapter is built on it; install "
      .. ox.MINIMUM
      .. " or newer from "
      .. ox.RELEASES_URL
      .. " and `ensure ox_lib` before `ensure rpf`; not connecting"
  end
  local version = GetResourceMetadata(ox.RESOURCE, "version", 0)
  if not ox.at_least(version, ox.MINIMUM) then
    return "rpf: ox_lib is version "
      .. tostring(version)
      .. ", and RPF needs "
      .. ox.MINIMUM
      .. " or newer; update it from "
      .. ox.RELEASES_URL
      .. "; not connecting"
  end
  return nil
end

---The server's answerer for one request name, over `lib.callback.register`.
---ox_lib names the sender (`source`), and holds the client's request open
---until the callback returns, so it waits for the core's answer, which
---always comes. A payload that is not a string, which a hostile client
---can send, is answered with nothing and never reaches the core.
---@param name string The request's name.
---@param handler fun(player: integer, payload: string, respond: fun(reply: string)) The core's answerer.
function ox.on_client_request(name, handler)
  lib.callback.register(name, function(source, payload)
    if type(payload) ~= "string" then
      return nil
    end
    local answer = promise.new()
    handler(tonumber(source) --[[@as integer]], payload, function(reply)
      answer:resolve(reply)
    end)
    return Citizen.Await(answer)
  end)
end

---How many of this client's requests ox_lib holds without an answer yet.
local unanswered = 0

---Asks the server, over `lib.callback`, with no client-side rate limit:
---the core keeps its own, and its own timeout. ox_lib keeps its own record
---of the request until the answer comes, and never expires one sent with a
---callback. The server always answers (`on_client_request`), but one that
---stops mid-request, or a handler that never returns, leaves a record for
---good, so past `MAX_UNANSWERED` of them a request is answered with
---nothing, later, rather than sent.
---@param name string The request's name.
---@param payload string The request.
---@param callback fun(reply: string?) Called with the answer.
function ox.request_server(name, payload, callback)
  if unanswered >= ox.MAX_UNANSWERED then
    Citizen.SetTimeout(0, function()
      callback(nil)
    end)
    return
  end
  unanswered = unanswered + 1
  lib.callback(name, false, function(reply)
    unanswered = unanswered - 1
    callback(type(reply) == "string" and reply or nil)
  end, payload)
end

rpf.fivem.ox = ox
return ox
