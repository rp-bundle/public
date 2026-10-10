---Everything the FiveM adapter takes from ox_lib (J10, #239), in one file,
---so leaving it is one file's work: upstream has moved once already.
---
---ox_lib is a dependency of the `rpf` resource (`fxmanifest.lua`), loaded
---into this resource's Lua state by `@ox_lib/init.lua` as the `lib` global.
---FXServer starts it first, and refuses to start `rpf` without it; one that
---is too old is refused here, at start, in one line (`ox.problem`). It is
---LGPL-3.0, so a release names it as a prerequisite and never bundles it.
---
---It carries a client's request to the server and its answer
---(`request_server` and `on_client_request`): `lib.callback` pairs them. It
---is only the transport. The other direction, the server asking a client
---(`rpf.ui`), is the adapter's own numbered net events (`server.lua`,
---`client.lua`), because ox_lib keeps every server-to-client callback with
---no answer for good, and a player who leaves with a menu open never
---answers. A client reaches one fixed name per
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
---@field MINIMUM string The oldest release the adapter accepts: the one it is built and type-checked against (`dev/fivem-natives`), which also closes a hole in ox_lib's callbacks that let one player answer what the server asked another, for every resource on the server that uses them.
---@field RELEASES_URL string Where an owner gets it.
---@field PRECISION integer How many decimal places a number field takes: ox_lib's number input takes whole numbers unless told, and `rpf.ui` takes any number.
---@field MENU_ID string The context menu id addons' menus are registered under: one at a time, as `rpf.ui` allows.
---@field WATCH_MS integer How often an open menu checks it is still the one on show, since ox_lib says nothing when another resource's menu replaces it.
---@field ui rpf.ClientUi The UI an addon shows, for the client platform.
local ox = {}

ox.RESOURCE = "ox_lib"
ox.MINIMUM = "3.40.0"
ox.MAX_UNANSWERED = 256
ox.RELEASES_URL = "https://github.com/overextended/ox_lib/releases"
ox.MENU_ID = "rpf_menu"
ox.PRECISION = 6
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

---A notification, over `lib.notify`.
---@param spec rpf.ui.NoticeSpec The notification.
---@param done fun() Called once it is shown.
local function notify(spec, done)
  lib.notify({ title = spec.title, description = spec.text, type = spec.kind, duration = spec.duration_ms })
  done()
end

---How to end the menu of ours on show, if one is, so `close` ends it, and
---its watch, even though `lib.hideContext` runs no `onExit`.
---@type fun(index: integer?)?
local open_menu = nil

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
      if open_menu == finish then
        open_menu = nil
      end
      done(index)
    end
  end
  open_menu = finish
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
    -- ox_lib runs `onExit` in the middle of closing, before it forgets
    -- the open menu: a callback that opened another menu now would see it
    -- closed under it. So the close is told after ox_lib has finished.
    onExit = function()
      Citizen.SetTimeout(0, function()
        finish(nil)
      end)
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
    -- `precision` is read by ox_lib's page, though its annotations leave it
    -- out.
    local number_row = { type = "number", label = field.label, placeholder = field.placeholder, default = field.default, required = field.required, min = field.min, max = field.max }
    number_row.precision = ox.PRECISION
    return number_row
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
  -- ox_lib reads a text row's max as the page's maxLength, in UTF-16 code
  -- units, never more than its UTF-8 bytes, so it only cuts typing short
  -- of what is too long anyway; the bounds themselves, in bytes, are
  -- `input`'s to check. Its min would refuse text the bytes allow.
  return { type = "input", label = field.label, placeholder = field.placeholder, default = field.default, required = field.required, max = field.max }
end

---Why a text field's value is not within its bounds, which `rpf.ui` counts
---in UTF-8 bytes, or nil if it is.
---@param field rpf.ui.FieldSpec The field.
---@param value any Its value: text, or nil for empty.
---@return string? problem What to fix, for the row's description.
local function text_problem(field, value)
  if field.kind ~= "text" or type(value) ~= "string" then
    return nil
  end
  if field.max and #value > field.max then
    return "Too long: at most " .. field.max .. " bytes."
  end
  if field.min and #value < field.min then
    return "Too short: at least " .. field.min .. " bytes."
  end
  return nil
end

---An input dialog, over `lib.inputDialog`, which waits for the player on a
---thread of its own. Its answer is the values by row, a select's by the
---option number this put in its `value`; nil for a dialog cancelled, or
---not shown because another resource's is open. Text out of its bounds in
---bytes, which ox_lib cannot check, shows the dialog again, as the player
---left it, with what to fix under the field.
---@param spec rpf.ui.InputSpec The dialog.
---@param done fun(values: table?) Called once.
local function input(spec, done)
  local rows = {}
  for i, field in ipairs(spec.fields) do
    rows[i] = row(field)
  end
  CreateThread(function()
    while true do
      local values = lib.inputDialog(spec.title, rows, { allowCancel = true })
      if type(values) ~= "table" then
        done(nil)
        return
      end
      local out, wrong = {}, false
      for i, field in ipairs(spec.fields) do
        local value = values[i] --[[@as any]]
        if field.kind == "select" then
          value = tonumber(value)
        elseif value == "" then
          value = nil
        end
        out[i] = value
        local problem = text_problem(field, value)
        rows[i].description = problem
        if problem then
          wrong = true
        end
        if field.kind ~= "select" and field.kind ~= "checkbox" then
          rows[i].default = value
        elseif field.kind == "checkbox" then
          rows[i].checked = value
        elseif value then
          rows[i].default = tostring(value)
        end
      end
      if not wrong then
        done(out)
        return
      end
    end
  end)
end

---The progress bar of this adapter's on show, if one is: a token per bar,
---so `close` never cancels another resource's, and a bar that ends late
---(ox_lib finishes a cancel on its next tick) never clears the one that
---replaced it.
---@type table?
local progress_ours = nil

---A progress bar, over `lib.progressBar`, which waits on a thread of its
---own: true when it ran to its end, anything else (cancelled, interrupted)
---is false. Another resource's bar on show is false at once: ox_lib would
---queue this one behind it, past the server's wait, and the player sees
---one bar at a time anyway.
---@param spec rpf.ui.ProgressSpec The bar.
---@param done fun(completed: boolean) Called once.
local function progress(spec, done)
  CreateThread(function()
    if lib.progressActive() then
      done(false)
      return
    end
    local mine = {}
    progress_ours = mine
    local completed = lib.progressBar({ duration = spec.duration_ms, label = spec.label, canCancel = spec.cancel, useWhileDead = false })
    if progress_ours == mine then
      progress_ours = nil
    end
    done(completed == true)
  end)
end

---Takes away what the core counts as closed because the addon that asked
---for it stopped: the menu without its `onExit`, the dialog (which answers
---nil), the bar (which answers false). The core ignores those answers.
---@param kind "menu"|"input"|"progress" Which.
local function close(kind)
  if kind == "menu" then
    local ending = open_menu
    if lib.getOpenContextMenu() == ox.MENU_ID then
      lib.hideContext(false)
    end
    if ending then
      ending(nil)
    end
  elseif kind == "input" then
    lib.closeInputDialog()
  elseif kind == "progress" and progress_ours ~= nil and lib.progressActive() then
    lib.cancelProgress()
  end
end

ox.ui = { notify = notify, menu = menu, input = input, progress = progress, close = close }

rpf.fivem.ox = ox
return ox
