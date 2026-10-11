---The logic behind the FiveM login and character screens (D2), apart from
---NUI, so busted runs it with no game.
---
---The screens are an NUI page (`nui/`). This module decides what the page
---shows from the core's events, turns what the player does there into core
---calls, and carries the client platform's HTTP requests to the page, which
---makes them with `fetch`: FiveM's client Lua has no HTTP of its own.
---
---**The password never reaches Lua.** The page seals each password it is
---given into a random handle and sends the handle instead; the core puts the
---handle where the password goes in its request body, and the page swaps
---the password back in just before `fetch`. So the password goes from the
---form to the portal (P1) without crossing into Lua or any event. That is a
---mitigation, not a guarantee: the server owner ships this page.
---
---**The client's half of the input lock.** From the moment the client
---starts until the login succeeds the page has focus and the player's ped is
---frozen, whatever owns characters afterwards, and the character screen does
---the same while it is up. A client is hostile, so the lock that counts is
---the server's (`lock.lua`); this one is what keeps an honest player from
---walking off mid-login.
---@class rpf.fivem.ui
---@field CALLBACKS string[] Every NUI callback name the page uses, each registered by `client.lua`.
local ui = {}

local rpf = rpf

ui.CALLBACKS = { "ready", "http", "login", "register", "change_password", "delete_account", "close_delete", "create", "select", "refresh" }

---What the screens need from the client: the core and three engine actions.
---@class rpf.fivem.ScreenDeps
---@field core rpf The core table, for `events`, `auth`, `picker` and `json`.
---@field send fun(text: string) Sends one JSON message to the page (`SendNuiMessage`).
---@field lock fun(on: boolean) Locks or releases the player's input: page focus and a frozen ped.
---@field log fun(level: string, message: string) The platform's log.

---The screens for one client.
---@class rpf.fivem.Screens
---@field deps rpf.fivem.ScreenDeps What it was built with.
---@field ready boolean Whether the page has said it is loaded. Messages wait in `queue` until it has.
---@field queue string[] Messages sent before the page was ready.
---@field screen string? The last screen message, sent again if the page reloads.
---@field locked boolean Whether input is locked.
---@field pending table<integer, fun(status: integer, body: string, headers: table<string, string>)> HTTP callbacks by request id, until the page answers.
---@field next_id integer The last HTTP request id handed out.
---@field returning { screen: string, locked: boolean }? What was up when the delete form was opened from the game (`open_delete`), to put back when the player backs out. Any other screen replaces the form and forgets it.
local Screens = {}
Screens.__index = Screens

---Builds the screens. Nothing is shown until `start`.
---@param deps rpf.fivem.ScreenDeps The client's half.
---@return rpf.fivem.Screens screens The screens.
function ui.new(deps)
  return setmetatable({
    deps = deps,
    ready = false,
    queue = {},
    locked = false,
    pending = {},
    next_id = 0,
  }, Screens)
end

---Sends a message to the page, or keeps it until the page is ready.
---@param message table The message, encoded with `rpf.json`.
function Screens:post(message)
  local text = assert(self.deps.core.json.encode(self.deps.core.json.object(message)))
  if message.type == "screen" then
    self.screen = text
  end
  if self.ready then
    self.deps.send(text)
  else
    self.queue[#self.queue + 1] = text
  end
end

---Locks or releases input, once per change.
---@param on boolean Locked or not.
function Screens:lock(on)
  if self.locked ~= on then
    self.locked = on
    self.deps.lock(on)
  end
end

---Shows a screen.
---@param name "connecting"|"login"|"delete"|"password"|"deleted"|"characters"|"closed" Which.
---@param fields table? What it shows.
function Screens:show(name, fields)
  self.returning = nil
  local message = { type = "screen", screen = name }
  for key, value in pairs(fields or {}) do
    message[key] = value
  end
  self:post(message)
end

---Opens the delete-account form for a player who is already logged in: the
---way to it when they were resumed silently and never saw the login screen
---(H6). It is the login screen's form, with the same text, confirmation and
---sealed password, and the core refuses a deletion the same way. Input is
---locked while it is up.
---
---Back (`close_delete`) puts back the screen and lock that were up, so a
---player who was choosing a character is choosing again and one in play is
---released, rather than guessing which here.
---@return boolean opened False unless the player is logged in.
function Screens:open_delete()
  if self.deps.core.auth.state() ~= "authenticated" then
    return false
  end
  if self.returning then
    return true
  end
  local back = { screen = self.screen, locked = self.locked }
  self:lock(true)
  self:show("delete", { from = "game" })
  self.returning = back
  return true
end

---Closes the delete form opened by `open_delete`, putting back what was up.
---@return boolean closed False if the form is not up.
function Screens:close_delete()
  local back = self.returning
  if not back then
    return false
  end
  self.returning = nil
  self.screen = back.screen
  if back.screen then
    self.deps.send(back.screen)
  end
  self:lock(back.locked)
  return true
end

---Shows an error on the screen that is up. `message` is written for the
---player.
---@param message string The text.
function Screens:error(message)
  self:post({ type = "error", message = message })
end

---Words for a refusal of a character request, which the core reports as a
---code.
---@type table<string, string>
local CHARACTER_REASONS = {
  not_ready = "Your characters are still loading. Try again in a moment.",
  busy = "Still working on your last request.",
  not_found = "That character is not yours.",
  invalid = "Check the names and try again.",
  limit = "You have as many characters as this server allows.",
  forbidden = "You have as many characters as this server allows.",
  unavailable = "That did not work right now. Try again.",
}

---The character list, as the page wants it.
---@param list rpf.picker.Character[] The characters.
---@return table characters A JSON array of `{ id, name }`.
local function listing(list)
  local json = rpf.json
  local out = json.array({})
  for i, character in ipairs(list) do
    out[i] = json.object({ id = character.id, name = character.first_name .. " " .. character.last_name })
  end
  return out
end

---Shows the first screen, locks input, and follows the core's events from
---here on. Run once, as the client starts.
function Screens:start()
  local core = self.deps.core
  local events = core.events
  self:lock(true)
  self:show("connecting")
  events.on("auth.required", function(prompt)
    self:lock(true)
    self:show("login", { warning = prompt and prompt.warning or core.auth.PASSWORD_REUSE_WARNING })
  end)
  events.on("auth.failed", function(failure)
    -- A refresh or logout that failed in the background is not the form's
    -- to show, and an error on the page forgets every sealed password: a
    -- deletion still waiting for its nonce would then send its handle as is.
    if type(failure) == "table" and (failure.during == "refresh" or failure.during == "logout") then
      return
    end
    self:error(type(failure) == "table" and failure.message or "Something went wrong. Please try again.")
  end)
  events.on("auth.password_change_required", function(change)
    self:show("password", {
      username = change.username,
      message = change.message,
      warning = core.auth.PASSWORD_REUSE_WARNING,
    })
  end)
  -- The core is in `deleted` and starts nothing more, and the player is
  -- still in the game as an account that no longer exists, so input stays
  -- locked and the only way on is to reconnect.
  events.on("auth.account_deleted", function(deleted)
    self:lock(true)
    self:show("deleted", {
      message = "The account "
        .. deleted.username
        .. " was deleted. Disconnect and reconnect to this server to log in to another account or register a new one.",
    })
  end)
  -- The login lock ends here, on every server. On a native server the
  -- character list follows at once and locks again; on one whose
  -- characters are another framework's, that framework takes over.
  events.on("auth.succeeded", function()
    self:lock(false)
    self:show("closed")
  end)
  events.on("characters.listed", function(list, selected)
    if selected ~= nil then
      self:lock(false)
      self:show("closed")
      return
    end
    self:lock(true)
    self:show("characters", { characters = listing(list) })
  end)
  events.on("characters.result", function(result)
    if result.ok then
      if result.during == "select" then
        self:lock(false)
        self:show("closed")
      end
      return
    end
    -- A list that failed to load is retried only when asked, so the player
    -- gets the character screen, empty, with its refresh, rather than
    -- nothing at all.
    if result.during == "load" then
      self:lock(true)
      self:show("characters", { characters = rpf.json.array({}) })
    end
    local reason = result.reason
    self:error(CHARACTER_REASONS[reason] or ("That did not work" .. (type(reason) == "string" and (": " .. reason) or ".")))
  end)
end

---The client platform's `http_request`: the page makes the request with
---`fetch` and answers through the `http` callback.
---@param method string The method.
---@param url string The absolute url.
---@param headers table<string, string> Request headers.
---@param body string? The body.
---@param callback fun(status: integer, body: string, headers: table<string, string>) Called once.
function Screens:http_request(method, url, headers, body, callback)
  local json = self.deps.core.json
  self.next_id = self.next_id + 1
  self.pending[self.next_id] = callback
  local sent = json.object({})
  for key, value in pairs(headers or {}) do
    sent[key] = value
  end
  self:post({
    type = "http",
    id = self.next_id,
    method = method,
    url = url,
    headers = sent,
    body = body or json.null,
  })
end

---A string field from the page, or nil.
---@param data any What the page sent.
---@param key string The field.
---@return string? value The field, if it is a string.
local function text(data, key)
  local value = type(data) == "table" and data[key] or nil
  return type(value) == "string" and value or nil
end

---Whether the player asked to stay logged in on this device. Saved unless
---the page says no.
---@param data any What the page sent.
---@return rpf.AuthLoginOptions opts The options.
local function remember(data)
  return { remember = not (type(data) == "table" and data.remember == false) }
end

---Builds the answer to a page request from a core call's result.
---@param ok any What the call returned first.
---@param err any Its error, if any.
---@return table reply `{ ok = true }` or `{ ok = false, error = … }`.
local function reply(ok, err)
  if ok then
    return { ok = true }
  end
  return { ok = false, error = tostring(err or "refused") }
end

---Handles one NUI callback from the page. Everything the page sends is
---checked for type before it reaches the core.
---@param name string The callback, one of `ui.CALLBACKS`.
---@param data any What the page posted, decoded by FiveM.
---@return table reply What the page's `fetch` resolves with.
function Screens:nui(name, data)
  local core = self.deps.core
  if name == "ready" then
    self.ready = true
    local queued = self.queue
    self.queue = {}
    if #queued == 0 and self.screen then
      queued = { self.screen }
    end
    for _, message in ipairs(queued) do
      self.deps.send(message)
    end
    return { ok = true }
  elseif name == "http" then
    local id = type(data) == "table" and tonumber(data.id) or nil
    local callback = id and self.pending[id]
    if not id or not callback then
      return reply(false, "unknown request")
    end
    self.pending[id] = nil
    local headers = {}
    if type(data.headers) == "table" then
      for key, value in pairs(data.headers) do
        if type(key) == "string" and type(value) == "string" then
          headers[key] = value
        end
      end
    end
    callback(tonumber(data.status) or 0, text(data, "body") or "", headers)
    return { ok = true }
  elseif name == "login" or name == "register" then
    local username, password = text(data, "username"), text(data, "password")
    if not username or not password then
      return reply(false, "invalid")
    end
    return reply(core.auth[name](username, password, remember(data)))
  elseif name == "change_password" then
    local username, password, new_password = text(data, "username"), text(data, "password"), text(data, "new_password")
    if not username or not password or not new_password then
      return reply(false, "invalid")
    end
    return reply(core.auth.change_password(username, password, new_password, remember(data)))
  elseif name == "delete_account" then
    local username, password = text(data, "username"), text(data, "password")
    if not username or not password then
      return reply(false, "invalid")
    end
    -- The page requires the box, and a deletion cannot be undone, so one it
    -- does not say was confirmed is refused here too.
    if type(data) ~= "table" or data.confirmed ~= true then
      return reply(false, "confirm that you want to delete the account")
    end
    return reply(core.auth.delete_account(username, password))
  elseif name == "close_delete" then
    return reply(self:close_delete())
  elseif name == "create" then
    local first_name, last_name, gender = text(data, "first_name"), text(data, "last_name"), text(data, "gender")
    if not first_name or not last_name or not gender then
      return reply(false, "invalid")
    end
    return reply(core.picker.create(first_name, last_name, gender))
  elseif name == "refresh" then
    return reply(core.picker.refresh())
  elseif name == "select" then
    local id = text(data, "id")
    if not id then
      return reply(false, "invalid")
    end
    return reply(core.picker.select(id))
  end
  return reply(false, "unknown callback")
end

rpf.fivem.ui = ui
return ui
