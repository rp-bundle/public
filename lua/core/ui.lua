---Portable UI for addons (J10, #239): a notification, a menu to pick from,
---an input dialog and a progress bar, the same call on every engine.
---
---This is what an addon that runs on both engines shows a player, and it is
---deliberately small: what a cross-engine addon needs, not a port of ox_lib.
---The adapter builds each one (`platform.ui` on the client): over ox_lib on
---FiveM, in Derma on Gmod. A FiveM-only addon may call `lib.*` itself.
---
---**On the client**, `notify(opts)`, `menu(opts, callback)`,
---`input(opts, callback)` and `progress(opts, callback)` check the options
---and hand the adapter a plain, checked copy. The callback runs once, with
---the result, or nil and why: `cancelled` when the player closed it.
---
---**On the server**, the same four take the player first and show it on
---their client, through a request and its answer (`request_client`, J10's
---transport): `lib.callback` on FiveM, numbered `net` messages on Gmod.
---The client's answer is hostile input, so the server checks it against
---what it offered, which it kept: a menu choice is one of the options it
---sent, by number, and the option's `value` never leaves the server; an
---input dialog's values are each of its field's kind and within its bounds.
---A player who leaves takes their dialogs with them (`gone`), and one left
---open past `TIMEOUT_MS` is `timeout`.
---
---Nothing here throws: a call that cannot show anything returns nil and a
---reason, and a callback that throws is logged.
---@class rpf.ui
---@field KINDS string[] What can be shown, in order: the capabilities `rpf.api.capabilities()` reports for UI.
---@field FIELD_KINDS string[] The kinds of field an input dialog takes.
---@field NOTICE_KINDS string[] How a notification looks.
---@field MAX_OPTIONS integer The most options a menu offers.
---@field MAX_FIELDS integer The most fields an input dialog asks for.
---@field MAX_LABEL integer The longest title, label, description or placeholder, in bytes.
---@field MAX_NOTICE integer The longest notification text, in bytes.
---@field TEXT_MAX integer The longest text a text field takes unless it says otherwise, in bytes.
---@field TEXT_LIMIT integer The most a text field's `max` may be, in bytes, so a dialog's answer fits one message.
---@field NOTICE_MS integer How long a notification shows unless it says otherwise.
---@field NOTICE_MIN_MS integer The shortest a notification may show.
---@field NOTICE_MAX_MS integer The longest a notification may show.
---@field PROGRESS_MIN_MS integer The shortest progress bar.
---@field PROGRESS_MAX_MS integer The longest progress bar.
---@field TIMEOUT_MS integer How long the server waits for a player to answer a menu or a dialog; a progress bar's own length plus `GRACE_MS`.
---@field GRACE_MS integer How long past a progress bar's end the server waits for its answer.
local ui = {}

local rpf = rpf
local json = rpf.json
local handoff = rpf.handoff

ui.KINDS = { "notify", "menu", "input", "progress" }
ui.FIELD_KINDS = { "text", "number", "checkbox", "select" }
ui.NOTICE_KINDS = { "info", "success", "warning", "error" }
ui.MAX_OPTIONS = 32
ui.MAX_FIELDS = 12
ui.MAX_LABEL = 128
ui.MAX_NOTICE = 256
ui.TEXT_MAX = 128
ui.TEXT_LIMIT = 512
ui.NOTICE_MS = 5000
ui.NOTICE_MIN_MS = 1000
ui.NOTICE_MAX_MS = 30000
ui.PROGRESS_MIN_MS = 100
ui.PROGRESS_MAX_MS = 600000
ui.TIMEOUT_MS = 300000
ui.GRACE_MS = 30000

---@type rpf.ServerPlatform|rpf.ClientPlatform|nil
local platform = nil

---What this side has open, by kind: one menu, one dialog and one progress
---bar at a time, on the client for the player, on the server per player.
---@type table<string, true>
local open_here = {}

---What the server is waiting on, by player id and kind.
---@type table<string, table<string, fun(raw: any, reason: string?)>>
local waiting = {}

---What one checked call keeps to read its answer by: a menu's values, an
---input dialog's fields.
---@class rpf.ui.Kept
---@field values any[]? A menu's options' values, by number.
---@field disabled table<integer, true>? A menu's options that cannot be picked.
---@field fields rpf.ui.Field[]? An input dialog's fields, in order.

---One input dialog field, checked.
---@class rpf.ui.Field
---@field name string What its value is called in the result.
---@field kind "text"|"number"|"checkbox"|"select" What it takes.
---@field required boolean Whether it must be filled in.
---@field min number? A number's least value, or a text's fewest bytes.
---@field max number? A number's greatest value, or a text's most bytes.
---@field values any[]? A select's options' values, by number.

---Whether a value is one of a list.
---@param value any The value.
---@param list string[] The list.
---@return boolean found True if it is.
local function one_of(value, list)
  for _, item in ipairs(list) do
    if value == item then
      return true
    end
  end
  return false
end

---Whether a value is text of at most `n` bytes the codec can carry.
---@param value any The value.
---@param n integer The most bytes.
---@param empty boolean? Whether "" will do.
---@return boolean ok True if it is.
local function text(value, n, empty)
  return type(value) == "string" and #value <= n and (empty or value ~= "") and json.is_utf8(value)
end

---Whether a value is an optional bit of text: absent, or text of at most
---`n` bytes.
---@param value any The value.
---@param n integer The most bytes.
---@return boolean ok True if it is.
local function optional_text(value, n)
  return value == nil or text(value, n)
end

---Whether a value is a finite number.
---@param n any The value.
---@return boolean finite True if it is.
local function finite(n)
  return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

---Whether a value is a whole number in a range.
---@param n any The value.
---@param low number The least.
---@param high number The greatest.
---@return boolean ok True if it is.
local function whole(n, low, high)
  return finite(n) and n == math.floor(n) and n >= low and n <= high
end

---Checks a notification's options. A string is the text alone.
---@param opts any What the caller passed.
---@return table? spec The plain spec: `text`, `title`, `kind`, `duration_ms`.
local function notify_spec(opts)
  if type(opts) == "string" then
    opts = { text = opts }
  end
  if type(opts) ~= "table" then
    return nil
  end
  local kind = opts.kind == nil and "info" or opts.kind
  local duration = opts.duration_ms == nil and ui.NOTICE_MS or opts.duration_ms
  if
    not text(opts.text, ui.MAX_NOTICE)
    or not optional_text(opts.title, ui.MAX_LABEL)
    or not one_of(kind, ui.NOTICE_KINDS)
    or not whole(duration, ui.NOTICE_MIN_MS, ui.NOTICE_MAX_MS)
  then
    return nil
  end
  return { text = opts.text, title = opts.title, kind = kind, duration_ms = duration }
end

---Checks a menu's options. Each option's `value` is kept here and never
---shown, so it may be anything; an option with none answers its number.
---@param opts any What the caller passed.
---@return table? spec The plain spec: `title` and `options` (`label`, `description`, `disabled`).
---@return rpf.ui.Kept? kept The values and the options that cannot be picked.
local function menu_spec(opts)
  if type(opts) ~= "table" or not text(opts.title, ui.MAX_LABEL) or type(opts.options) ~= "table" then
    return nil
  end
  local count = #opts.options
  if count < 1 or count > ui.MAX_OPTIONS then
    return nil
  end
  local options, values, disabled = {}, {}, {}
  for i = 1, count do
    local option = opts.options[i]
    if
      type(option) ~= "table"
      or not text(option.label, ui.MAX_LABEL)
      or not optional_text(option.description, ui.MAX_LABEL)
      or (option.disabled ~= nil and type(option.disabled) ~= "boolean")
    then
      return nil
    end
    options[i] = { label = option.label, description = option.description, disabled = option.disabled or nil }
    if option.value == nil then
      values[i] = i
    else
      values[i] = option.value
    end
    if option.disabled then
      disabled[i] = true
    end
  end
  return { title = opts.title, options = options }, { values = values, disabled = disabled }
end

---Checks one input dialog field.
---@param field any What the caller passed.
---@return table? shown The field as the client shows it.
---@return rpf.ui.Field? kept The field as an answer is checked against it.
local function field_spec(field)
  if
    type(field) ~= "table"
    or type(field.name) ~= "string"
    or not field.name:match("^[%a_][%w_]*$")
    or #field.name > 32
    or not text(field.label, ui.MAX_LABEL)
    or not one_of(field.kind == nil and "text" or field.kind, ui.FIELD_KINDS)
    or not optional_text(field.placeholder, ui.MAX_LABEL)
    or (field.required ~= nil and type(field.required) ~= "boolean")
  then
    return nil
  end
  local kind = field.kind or "text"
  local shown = { name = field.name, label = field.label, kind = kind, required = field.required or nil, placeholder = field.placeholder }
  ---@type rpf.ui.Field
  local kept = { name = field.name, kind = kind, required = field.required == true }
  if kind == "text" then
    local low = field.min == nil and 0 or field.min
    local high = field.max == nil and ui.TEXT_MAX or field.max
    if not whole(low, 0, ui.TEXT_LIMIT) or not whole(high, 1, ui.TEXT_LIMIT) or low > high then
      return nil
    end
    if field.default ~= nil and not text(field.default, high, true) then
      return nil
    end
    shown.min, shown.max, shown.default = low, high, field.default
    kept.min, kept.max = low, high
  elseif kind == "number" then
    if (field.min ~= nil and not finite(field.min)) or (field.max ~= nil and not finite(field.max)) then
      return nil
    end
    if field.min ~= nil and field.max ~= nil and field.min > field.max then
      return nil
    end
    local default = field.default
    if default ~= nil and (not finite(default) or (field.min and default < field.min) or (field.max and default > field.max)) then
      return nil
    end
    shown.min, shown.max, shown.default = field.min, field.max, default
    kept.min, kept.max = field.min, field.max
  elseif kind == "checkbox" then
    if field.default ~= nil and type(field.default) ~= "boolean" then
      return nil
    end
    shown.default = field.default
  else
    local choices = field.options
    if type(choices) ~= "table" or #choices < 1 or #choices > ui.MAX_OPTIONS then
      return nil
    end
    local labels, values = {}, {}
    local default = nil
    for i = 1, #choices do
      local choice = choices[i]
      if type(choice) ~= "table" or not text(choice.label, ui.MAX_LABEL) then
        return nil
      end
      labels[i] = choice.label
      if choice.value == nil then
        values[i] = i
      else
        values[i] = choice.value
      end
      if field.default ~= nil and values[i] == field.default then
        default = i
      end
    end
    if field.default ~= nil and default == nil then
      return nil
    end
    shown.options, shown.default = labels, default
    kept.values = values
  end
  return shown, kept
end

---Checks an input dialog's options.
---@param opts any What the caller passed.
---@return table? spec The plain spec: `title` and `fields`.
---@return rpf.ui.Kept? kept The fields, to check an answer against.
local function input_spec(opts)
  if type(opts) ~= "table" or not text(opts.title, ui.MAX_LABEL) or type(opts.fields) ~= "table" then
    return nil
  end
  local count = #opts.fields
  if count < 1 or count > ui.MAX_FIELDS then
    return nil
  end
  local fields, kept, names = {}, {}, {}
  for i = 1, count do
    local shown, field = field_spec(opts.fields[i])
    if not shown or not field or names[field.name] then
      return nil
    end
    names[field.name] = true
    fields[i], kept[i] = shown, field
  end
  return { title = opts.title, fields = fields }, { fields = kept }
end

---Checks a progress bar's options.
---@param opts any What the caller passed.
---@return table? spec The plain spec: `label`, `duration_ms`, `cancel`.
local function progress_spec(opts)
  if type(opts) ~= "table" or not text(opts.label, ui.MAX_LABEL) then
    return nil
  end
  if not whole(opts.duration_ms, ui.PROGRESS_MIN_MS, ui.PROGRESS_MAX_MS) then
    return nil
  end
  if opts.cancel ~= nil and type(opts.cancel) ~= "boolean" then
    return nil
  end
  return { label = opts.label, duration_ms = opts.duration_ms, cancel = opts.cancel ~= false }
end

---Checks what a caller passed for one kind, and gives the plain spec an
---adapter shows and what an answer is read by.
---@param kind string The kind.
---@param opts any What the caller passed: hostile on the client when the server sent it, though the server checked it first.
---@return table? spec The spec, or nil for options that are not right.
---@return rpf.ui.Kept kept What reading an answer needs.
function ui.spec(kind, opts)
  -- `pcall`, so a table with a metatable that throws is refused, not thrown.
  local ok, spec, kept = pcall(function()
    if kind == "notify" then
      return notify_spec(opts), {}
    elseif kind == "menu" then
      return menu_spec(opts)
    elseif kind == "input" then
      return input_spec(opts)
    elseif kind == "progress" then
      return progress_spec(opts), {}
    end
    return nil
  end)
  if not ok or not spec then
    return nil, {}
  end
  return spec, kept or {}
end

---Reads an answer: from the adapter on the client, or from a client on the
---server, where it is hostile input. Only what the call offered gets
---through.
---@param kind string The kind.
---@param kept rpf.ui.Kept What the call kept.
---@param raw any The answer: a menu option's number, the dialog's values by field number, a progress bar's `true` when it ran to the end; nil (or `false` for a progress bar) when the player closed it.
---@return any result The result: the chosen option's value, the values by field name, or `true`.
---@return string? err `cancelled` when the player closed it, `invalid` for an answer the call did not offer.
function ui.read(kind, kept, raw)
  if raw == nil or raw == json.null then
    return nil, "cancelled"
  end
  if kind == "progress" then
    if raw == true then
      return true
    end
    return nil, raw == false and "cancelled" or "invalid"
  end
  if kind == "menu" then
    local values = kept.values or {}
    if not whole(raw, 1, #values) or (kept.disabled or {})[raw] then
      return nil, "invalid"
    end
    return values[raw]
  end
  if kind ~= "input" or type(raw) ~= "table" then
    return nil, "invalid"
  end
  local out = {}
  for i, field in ipairs(kept.fields or {}) do
    local value = raw[i]
    if value == json.null then
      value = nil
    end
    if field.kind == "text" then
      if value == "" then
        value = nil
      end
      if value ~= nil and not text(value, field.max) then
        return nil, "invalid"
      end
      if value ~= nil and #value < field.min then
        return nil, "invalid"
      end
    elseif field.kind == "number" then
      if value ~= nil and (not finite(value) or (field.min and value < field.min) or (field.max and value > field.max)) then
        return nil, "invalid"
      end
    elseif field.kind == "checkbox" then
      if value ~= nil and type(value) ~= "boolean" then
        return nil, "invalid"
      end
      value = value == true
    else
      if value ~= nil then
        if not whole(value, 1, #field.values) then
          return nil, "invalid"
        end
        value = field.values[value]
      end
    end
    if value == nil and field.required then
      return nil, "invalid"
    end
    out[field.name] = value
  end
  return out
end

---Calls a script's callback with a result, in the context of the code that
---asked, logging a throw.
---@param ctx rpf.addons.Context? Whose code asked, on the server.
---@param callback any The callback.
---@param result any The result.
---@param err string? Why there is none.
local function deliver(ctx, callback, result, err)
  local ran, thrown
  if rpf.addons then
    ran, thrown = rpf.addons.run(ctx, callback, result, err)
  else
    ran, thrown = pcall(callback, result, err)
  end
  if not ran then
    assert(platform).log("error", "rpf: a ui callback failed: " .. tostring(thrown))
  end
end

---A copy of a result without the codec's marks, as the API hands out.
---@param value any The value.
---@return any copy The copy.
local function plain(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in next, value do
    out[key] = plain(item)
  end
  return out
end

-- The client ----------------------------------------------------------------

---Shows something through the client's adapter, and reads the answer it
---gives once.
---@param kind string The kind.
---@param spec table The checked spec.
---@param kept rpf.ui.Kept What reading the answer needs.
---@param done fun(raw: any, result: any, err: string?)? Called once with the raw answer and what it reads as; nil for a notification.
---@return boolean? ok True once shown.
---@return string? err `unsupported` where the adapter has none, `busy` while one of the kind is open, `failed` when the adapter threw (logged).
local function show_here(kind, spec, kept, done)
  local p = platform --[[@as rpf.ClientPlatform?]]
  local adapter = p and p.ui and p.ui[kind]
  if type(adapter) ~= "function" then
    return nil, "unsupported"
  end
  ---@cast p rpf.ClientPlatform
  if kind ~= "notify" and open_here[kind] then
    return nil, "busy"
  end
  local finished = false
  ---Takes the adapter's answer, once.
  ---@param raw any What the player did.
  local function answered(raw)
    if finished then
      return
    end
    finished = true
    open_here[kind] = nil
    if done then
      done(raw, ui.read(kind, kept, raw))
    end
  end
  if kind ~= "notify" then
    open_here[kind] = true
  end
  local ok, err = pcall(adapter, spec, answered)
  if not ok then
    open_here[kind] = nil
    finished = true
    p.log("error", "rpf: the platform's ui." .. kind .. " failed: " .. tostring(err))
    return nil, "failed"
  end
  return true
end

---Client: shows something the player's own client asked for.
---@param kind string The kind.
---@param opts any The caller's options.
---@param callback any The callback, for every kind but `notify`.
---@return boolean? ok True once shown.
---@return string? err `invalid`, `unsupported`, `busy`, `failed`, or `unavailable` before the client has started.
local function show_client(kind, opts, callback)
  if not platform then
    return nil, "unavailable"
  end
  if kind ~= "notify" and not rpf.callable(callback) then
    return nil, "invalid"
  end
  local spec, kept = ui.spec(kind, opts)
  if not spec then
    return nil, "invalid"
  end
  if kind == "notify" then
    return show_here(kind, spec, kept, nil)
  end
  return show_here(kind, spec, kept, function(_, result, err)
    deliver(nil, callback, result, err)
  end)
end

---Answers the server's request to show something: shows it, and sends the
---player's raw answer back for the server to read. Anything that cannot be
---shown is answered with why.
---@param payload string The request.
---@param respond fun(reply: string) Answers it.
local function on_show(payload, respond)
  local request = handoff.decode(handoff.UI, payload)
  local kind = request and request.kind
  local spec, kept = nil, {}
  if kind ~= "notify" and request and one_of(kind, ui.KINDS) then
    spec, kept = ui.spec(kind, plain(request.spec))
  end
  if not spec then
    assert(platform).log("warn", "rpf: the server asked for a ui this client cannot read")
    respond(handoff.encode(handoff.UI_ANSWER, { ok = false, reason = "invalid" }))
    return
  end
  ---@cast kind string
  local shown, why = show_here(kind, spec, kept, function(raw)
    local fields = { ok = true }
    if kind == "menu" and type(raw) == "number" then
      fields.index = raw
    elseif kind == "input" and type(raw) == "table" then
      local values = json.array({})
      for i = 1, #(kept.fields or {}) do
        local value = raw[i]
        values[i] = value == nil and json.null or value
      end
      fields.values = values
    elseif kind == "progress" then
      fields.done = raw == true
    end
    local encoded, reply = pcall(handoff.encode, handoff.UI_ANSWER, fields)
    if not encoded then
      respond(handoff.encode(handoff.UI_ANSWER, { ok = false, reason = "invalid" }))
      return
    end
    respond(reply)
  end)
  if not shown then
    respond(handoff.encode(handoff.UI_ANSWER, { ok = false, reason = why }))
  end
end

---Shows a notification the server sent.
---@param payload string The message.
local function on_notify(payload)
  local message = handoff.decode(handoff.UI_NOTIFY, payload)
  local spec = message and ui.spec("notify", plain(message.spec))
  if not spec then
    assert(platform).log("warn", "rpf: the server sent a notification this client cannot read")
    return
  end
  show_here("notify", spec, {}, nil)
end

---Starts the client half: keeps the platform, and answers the server.
---Called by `rpf.start_client`.
---@param p rpf.ClientPlatform The platform.
function ui.start_client(p)
  platform = p
  p.on_server_request(handoff.UI, on_show)
  p.on_server(handoff.UI_NOTIFY, on_notify)
end

-- The server ----------------------------------------------------------------

---Which UI the engine's clients show, as the server's adapter declares it.
---@return table<string, boolean> supported By kind.
function ui.capabilities()
  local out = {}
  local p = platform
  for _, kind in ipairs(ui.KINDS) do
    local declared
    if p and rpf.players then
      declared = (p --[[@as rpf.ServerPlatform]]).capabilities[kind]
      out[kind] = declared == true
    else
      declared = p and (p --[[@as rpf.ClientPlatform]]).ui and (p --[[@as rpf.ClientPlatform]]).ui[kind]
      out[kind] = type(declared) == "function"
    end
  end
  return out
end

---Server: shows something on a logged-in player's client.
---@param handle any The player's engine handle.
---@param kind string The kind.
---@param opts any The caller's options.
---@param callback any The callback, for every kind but `notify`.
---@return boolean? ok True once sent.
---@return string? err `invalid`, `unsupported`, `not_found` for a player not logged in here, `busy` while one of the kind is open for them, or `unavailable` before the server has started.
local function show_server(handle, kind, opts, callback)
  local p = platform --[[@as rpf.ServerPlatform?]]
  if not p or not rpf.players then
    return nil, "unavailable"
  end
  if kind ~= "notify" and not rpf.callable(callback) then
    return nil, "invalid"
  end
  local spec, kept = ui.spec(kind, opts)
  if not spec then
    return nil, "invalid"
  end
  if p.capabilities[kind] ~= true then
    return nil, "unsupported"
  end
  local player = rpf.players.get(handle)
  if not player or not player.player_id or player.state == "dropping" then
    return nil, "not_found"
  end
  local ok, text_or_err = pcall(handoff.encode, kind == "notify" and handoff.UI_NOTIFY or handoff.UI, {
    kind = kind ~= "notify" and kind or nil,
    spec = json.object(json.copy(spec)),
  })
  if not ok then
    return nil, "invalid"
  end
  if kind == "notify" then
    p.to_client(handle, handoff.UI_NOTIFY, text_or_err)
    return true
  end
  local player_id = player.player_id --[[@as string]]
  local by_kind = waiting[player_id] or {}
  if by_kind[kind] then
    return nil, "busy"
  end
  waiting[player_id] = by_kind
  local ctx = rpf.addons and rpf.addons.context()
  ---Ends the wait, once: reads the answer, or passes on why there is none.
  ---@param raw any The client's raw answer.
  ---@param reason string? Why there is none.
  local function finish(raw, reason)
    if by_kind[kind] == nil then
      return
    end
    by_kind[kind] = nil
    if next(by_kind) == nil and waiting[player_id] == by_kind then
      waiting[player_id] = nil
    end
    if reason then
      deliver(ctx, callback, nil, reason)
      return
    end
    local result, err = ui.read(kind, kept, raw)
    if err == "invalid" then
      p.log("debug", "rpf: a client answered a ui." .. kind .. " with something it was not offered")
    end
    deliver(ctx, callback, plain(result), err)
  end
  by_kind[kind] = finish
  local timeout = kind == "progress" and spec.duration_ms + ui.GRACE_MS or ui.TIMEOUT_MS
  p.after(timeout, function()
    finish(nil, "timeout")
  end)
  p.request_client(handle, handoff.UI, text_or_err, function(reply)
    local answer = handoff.decode(handoff.UI_ANSWER, reply)
    if not answer then
      finish(nil, "invalid")
    elseif not answer.ok then
      finish(nil, type(answer.reason) == "string" and one_of(answer.reason, { "unsupported", "busy", "invalid", "failed" }) and answer.reason or "invalid")
    elseif kind == "menu" then
      finish(answer.index)
    elseif kind == "input" then
      finish(answer.values)
    else
      finish(answer.done)
    end
  end)
  return true
end

---Starts the server half: keeps the platform, and ends a leaving player's
---waits. Called by `rpf.start_server`.
---@param p rpf.ServerPlatform The platform.
function ui.serve(p)
  platform = p
  for _, kind in ipairs(ui.KINDS) do
    local declared = p.capabilities[kind]
    if declared ~= true and declared ~= false then
      p.log("warn", "rpf: the platform declares ui capability " .. kind .. " as neither true nor false; it is unsupported")
    end
  end
  rpf.events.on("players.dropping", function(player)
    local by_kind = player.player_id and waiting[player.player_id]
    if not by_kind then
      return
    end
    for _, kind in ipairs(ui.KINDS) do
      local finish = by_kind[kind]
      if finish then
        finish(nil, "gone")
      end
    end
  end)
end

-- The API --------------------------------------------------------------------

---The public `ui` table for this side: the client's four take the options
---and a callback, the server's the player first.
---@return table<string, function> members By name.
function ui.members()
  local out = {}
  for _, kind in ipairs(ui.KINDS) do
    if rpf.players then
      out[kind] = function(player, opts, callback)
        return show_server(player, kind, opts, callback)
      end
    else
      out[kind] = function(opts, callback)
        return show_client(kind, opts, callback)
      end
    end
  end
  return out
end

rpf.ui = ui
return ui
