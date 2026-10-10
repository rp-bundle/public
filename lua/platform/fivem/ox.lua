---Everything the FiveM adapter takes from ox_lib (J10, #239), in one file,
---so leaving it is one file's work: upstream has moved once already.
---
---ox_lib is a dependency of the `rpf` resource (`fxmanifest.lua`), loaded
---into this resource's Lua state by `@ox_lib/init.lua` as the `lib` global.
---FXServer starts it first, and refuses to start `rpf` without it; one that
---is too old is refused here, at start, in one line (`ox.problem`). It is
---LGPL-3.0, so a release names it as a prerequisite and never bundles it.
---
---It carries a request and its answer between a client and the server, both
---ways (`request_server` and `on_client_request`, `request_client` and
---`on_server_request`): `lib.callback` pairs them. It is only the transport. A client reaches one fixed name per
---request kind, and what it asks for is checked by the core
---(`rpf.interactions`), never by a handler ox_lib calls directly. The login
---and character screens are RPF's own NUI and never touch ox_lib: its
---dialogs hand their values to Lua, and a password must never reach Lua.
---
---And it builds the UI an addon shows a player (`ox.ui`, the client
---platform's `ui`): a notification over `lib.notify`, a menu over
---`lib.registerContext` and `lib.showContext`, an input dialog over
---`lib.inputDialog`, a progress bar over `lib.progressBar`. `rpf.ui` hands
---each a spec it has checked, and reads what comes back.
---@class rpf.fivem.ox
---@field RESOURCE string The resource's name.
---@field MAX_UNANSWERED integer The most requests a client has open to the server over `lib.callback` at once: ox_lib keeps each until its answer comes and never expires one sent with a callback, so past this a request is answered with nothing rather than left in its table.
---@field MAX_ASKING integer The same bound for the server's requests to one player's client. Per player, so players who leave with a menu open (whose requests ox_lib keeps) never stop anyone else's.
---@field MINIMUM string The oldest release the adapter accepts. 3.40.0 is the first whose server checks who answers a server-to-client callback, which `rpf.api.ui` relies on.
---@field RELEASES_URL string Where an owner gets it.
---@field MENU_ID string The context menu id addons' menus are registered under: one at a time, as `rpf.ui` allows.
---@field WATCH_MS integer How often an open menu checks it is still the one on show, since ox_lib says nothing when another resource's menu replaces it.
---@field ui rpf.ClientUi The UI an addon shows, for the client platform.
local ox = {}

ox.RESOURCE = "ox_lib"
ox.MINIMUM = "3.40.0"
ox.MAX_UNANSWERED = 256
ox.MAX_ASKING = 16
ox.RELEASES_URL = "https://github.com/overextended/ox_lib/releases"
ox.MENU_ID = "rpf_menu"
ox.WATCH_MS = 1000

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

---How many of the server's requests to each player's client ox_lib holds
---without an answer yet, by player; a player with none has no entry. Each
---entry is the player's for one connection: `forget` drops it when they
---leave, so a later player given the same id starts at nothing, and an
---answer to a request from before counts against nobody.
---@type table<integer, { count: integer }>
local asking = {}

---Forgets a player's outstanding requests when they leave: they will never
---answer them, and FiveM may give their id to someone else.
---@param player integer The player.
function ox.forget(player)
  asking[player] = nil
end

---Asks a player's client, over `lib.callback` with their id: from 3.40.0,
---ox_lib takes the answer only from that player. ox_lib raises for a player
---who is gone, and a request past `MAX_ASKING` for one player is not sent
---(the core has at most one menu, dialog and bar open per player, and a
---player who leaves never answers, which ox_lib keeps for good); both are
---answered with nothing, later, as the interface asks.
---@param player integer The player.
---@param name string The request's name.
---@param payload string The request.
---@param callback fun(reply: string?) Called with the answer.
function ox.request_client(player, name, payload, callback)
  local entry = asking[player] or { count = 0 }
  local sent = false
  if entry.count < ox.MAX_ASKING then
    sent = pcall(lib.callback --[[@as function]], name, player, function(reply)
      if asking[player] == entry then
        entry.count = entry.count - 1
        if entry.count == 0 then
          asking[player] = nil
        end
      end
      callback(type(reply) == "string" and reply or nil)
    end, payload)
  end
  if sent then
    entry.count = entry.count + 1
    asking[player] = entry
    return
  end
  Citizen.SetTimeout(0, function()
    callback(nil)
  end)
end

---The client's answerer for one request name from the server, over
---`lib.callback.register`. ox_lib holds the server's request open until the
---callback returns, so it waits on its thread for the core's answer, which
---for a menu comes when the player picks.
---@param name string The request's name.
---@param handler fun(payload: string, respond: fun(reply: string)) The core's answerer.
function ox.on_server_request(name, handler)
  lib.callback.register(name, function(payload)
    if type(payload) ~= "string" then
      return nil
    end
    local answer = promise.new()
    handler(payload, function(reply)
      answer:resolve(reply)
    end)
    return Citizen.Await(answer)
  end)
end

---A notification, over `lib.notify`.
---@param spec rpf.ui.NoticeSpec The notification.
---@param done fun() Called once it is shown.
local function notify(spec, done)
  lib.notify({ title = spec.title, description = spec.text, type = spec.kind, duration = spec.duration_ms })
  done()
end

---A menu, over ox_lib's context menu. Picking an option closes it without
---`onExit`; closing it runs `onExit`. Another resource's menu can replace
---it with no word to anyone, so while it waits it checks every `WATCH_MS`
---that it is still the one on show, and counts one replaced as closed.
---@param spec rpf.ui.MenuSpec The menu.
---@param done fun(index: integer?) Called once.
local function menu(spec, done)
  local over = false
  ---Ends this menu, once; its watch stops with it.
  ---@param index integer? The option picked, or nil for closed.
  local function finish(index)
    if not over then
      over = true
      done(index)
    end
  end
  local options = {}
  for i, option in ipairs(spec.options) do
    options[i] = {
      title = option.label,
      description = option.description,
      disabled = option.disabled,
      onSelect = function()
        finish(i)
      end,
    }
  end
  lib.registerContext({
    id = ox.MENU_ID,
    title = spec.title,
    options = options,
    onExit = function()
      finish(nil)
    end,
  })
  lib.showContext(ox.MENU_ID)
  local function watch()
    if over then
      return
    end
    if lib.getOpenContextMenu() ~= ox.MENU_ID then
      finish(nil)
      return
    end
    Citizen.SetTimeout(ox.WATCH_MS, watch)
  end
  Citizen.SetTimeout(ox.WATCH_MS, watch)
end

---One input dialog row for a field.
---@param field rpf.ui.FieldSpec The field.
---@return table row The row, as `lib.inputDialog` takes it.
local function row(field)
  if field.kind == "number" then
    return { type = "number", label = field.label, placeholder = field.placeholder, default = field.default, required = field.required, min = field.min, max = field.max }
  elseif field.kind == "checkbox" then
    return { type = "checkbox", label = field.label, checked = field.default, required = field.required }
  elseif field.kind == "select" then
    local choices = {}
    for i, label in ipairs(field.options or {}) do
      choices[i] = { value = tostring(i), label = label }
    end
    return {
      type = "select",
      label = field.label,
      options = choices,
      default = field.default and tostring(field.default),
      required = field.required,
    }
  end
  -- ox_lib reads a text row's min and max as its least and greatest length.
  return { type = "input", label = field.label, placeholder = field.placeholder, default = field.default, required = field.required, min = field.min, max = field.max }
end

---An input dialog, over `lib.inputDialog`, which waits for the player on a
---thread of its own. Its answer is the values by row, a select's by the
---option number this put in its `value`; nil for a dialog cancelled, or
---not shown because another resource's is open.
---@param spec rpf.ui.InputSpec The dialog.
---@param done fun(values: table?) Called once.
local function input(spec, done)
  local rows = {}
  for i, field in ipairs(spec.fields) do
    rows[i] = row(field)
  end
  CreateThread(function()
    local values = lib.inputDialog(spec.title, rows, { allowCancel = true })
    if type(values) ~= "table" then
      done(nil)
      return
    end
    local out = {}
    for i, field in ipairs(spec.fields) do
      local value = values[i] --[[@as any]]
      if field.kind == "select" then
        value = tonumber(value)
      elseif value == "" then
        value = nil
      end
      out[i] = value
    end
    done(out)
  end)
end

---A progress bar, over `lib.progressBar`, which waits on a thread of its
---own: true when it ran to its end, anything else (cancelled, interrupted,
---or not started because another is running) is false.
---@param spec rpf.ui.ProgressSpec The bar.
---@param done fun(completed: boolean) Called once.
local function progress(spec, done)
  CreateThread(function()
    local completed = lib.progressBar({ duration = spec.duration_ms, label = spec.label, canCancel = spec.cancel, useWhileDead = false })
    done(completed == true)
  end)
end

ox.ui = { notify = notify, menu = menu, input = input, progress = progress }

rpf.fivem.ox = ox
return ox
