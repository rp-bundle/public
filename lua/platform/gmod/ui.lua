---The in-game login form and character select screen, in Derma.
---
---Both are thin: every decision is the core's. The login form calls
---`rpf.auth` (`login`, `register`, `change_password`) and shows what its
---events say; the silent login from a saved remember token is the core's own
---and needs no screen. The character screen calls `rpf.picker` (`create`,
---`select`, `deselect`, `refresh`) and shows the list the server sends. A
---player can therefore reach `active` on a fresh install with no script of
---the server owner's. Styling and appearance are left to server owners
---(H8 checks the whole journey on a released addon).
---
---Each screen is a popup that takes the keyboard and mouse, so a player
---cannot move while it is open. That is a courtesy: the server's input lock
---(`lock.lua`) is what holds a player still, because a client is hostile.
---
---Wherever a player chooses a password (the register button and the
---password change) the form shows `PASSWORD_REUSE_WARNING`, and nothing here
---claims the server cannot see the password: the server sends this file.
---
---`rpf_characters` in the console opens the character screen again, to switch
---or put away the character in play.
---@class rpf.gmod.Ui
---@field WIDTH number Every screen's width, in pixels.
---@field GENDERS string[] The genders the create form offers. The core also accepts a server's own, which a server owner's screen can offer.
local ui = {}

ui.WIDTH = 440
ui.GENDERS = { "male", "female" }

---The core's internal table, from `install`.
---@type rpf
local core

---The screen on show, if any.
---@type DFrame?
local frame = nil

---The status line on the screen on show, if it has one.
---@type DLabel?
local status = nil

---The buttons that start a request, disabled while one is in flight.
---@type DButton[]
local actions = {}

---Whether the player opened the character screen themselves, so a list that
---names a character in play does not close it.
local browsing = false

---A failure that arrived with no form to show it in, shown by the next one.
---@type string?
local pending_message = nil

---Closes the screen on show.
local function close()
  local open = frame
  if open and IsValid(open) then
    open:Remove()
  end
  frame, status, actions = nil, nil, {}
end

---Opens a new screen, replacing any on show.
---@param title string Its title.
---@param height number Its height, in pixels.
---@return DFrame frame The screen.
local function window(title, height)
  close()
  local f = vgui.Create("DFrame") --[[@as DFrame]]
  f:SetTitle(title)
  f:SetSize(ui.WIDTH, height)
  f:Center()
  f:ShowCloseButton(false)
  f:SetDraggable(false)
  f:MakePopup()
  frame = f
  return f
end

---Adds a line of wrapped text.
---@param parent Panel Where.
---@param text string What it says.
---@return DLabel label The label.
local function label(parent, text)
  local l = vgui.Create("DLabel", parent) --[[@as DLabel]]
  l:Dock(TOP)
  l:DockMargin(0, 4, 0, 4)
  l:SetWrap(true)
  l:SetAutoStretchVertical(true)
  l:SetText(text)
  return l
end

---Adds a text field.
---@param parent Panel Where.
---@param placeholder string What it asks for.
---@param hidden boolean? Whether it is a password, shown as `*`.
---@return DTextEntry entry The field.
local function field(parent, placeholder, hidden)
  local e = vgui.Create("DTextEntry", parent) --[[@as DTextEntry]]
  e:Dock(TOP)
  e:DockMargin(0, 4, 0, 4)
  e:SetPlaceholderText(placeholder)
  if hidden then
    e:SetTextHidden(true)
  end
  return e
end

---A Derma button, with the click handler Derma calls but the Gmod
---annotations leave out.
---@class rpf.gmod.Button: DButton
---@field DoClick fun(self: DButton) Called when the button is clicked.

---Adds a button.
---@param parent Panel Where.
---@param text string Its text.
---@param click fun() What it does.
---@param request boolean? Whether it starts a request, so it is disabled while one is in flight.
---@return DButton button The button.
local function button(parent, text, click, request)
  local b = vgui.Create("DButton", parent) --[[@as rpf.gmod.Button]]
  b:Dock(TOP)
  b:DockMargin(0, 4, 0, 4)
  b:SetText(text)
  b.DoClick = function()
    click()
  end
  if request then
    actions[#actions + 1] = b
  end
  return b
end

---Adds the status line, showing a failure kept for the next form.
---@param parent Panel Where.
local function status_line(parent)
  status = label(parent, pending_message or "")
  pending_message = nil
end

---Shows a line on the status line, and enables or disables the request
---buttons.
---@param text string What to say.
---@param busy boolean Whether a request is now in flight.
local function say(text, busy)
  if IsValid(status) then
    ---@cast status DLabel
    status:SetText(text)
  else
    pending_message = text
  end
  for _, b in ipairs(actions) do
    if IsValid(b) then
      b:SetEnabled(not busy)
    end
  end
end

---Runs a request the core may refuse at once, showing why if it does.
---@param working string What to say while it runs.
---@param started boolean? What the core returned.
---@param err string? Why it refused.
local function attempt(working, started, err)
  if started then
    say(working, true)
  else
    say("That did not work: " .. tostring(err) .. ".", false)
  end
end

---The login form: log in, or register a new account.
---@param warning string The password reuse warning, shown at the password.
local function login(warning)
  local f = window("Log in", 330)
  label(f, "Log in to your account for this community, or register a new one.")
  local username = field(f, "Username")
  local password = field(f, "Password", true)
  label(f, warning)
  local remember = vgui.Create("DCheckBoxLabel", f) --[[@as DCheckBoxLabel]]
  remember:Dock(TOP)
  remember:DockMargin(0, 4, 0, 4)
  remember:SetText("Keep me logged in on this computer")
  remember:SetValue(true)
  button(f, "Log in", function()
    attempt(
      "Logging in…",
      core.auth.login(username:GetValue(), password:GetValue(), { remember = remember:GetChecked() })
    )
  end, true)
  button(f, "Register", function()
    attempt(
      "Registering…",
      core.auth.register(username:GetValue(), password:GetValue(), { remember = remember:GetChecked() })
    )
  end, true)
  status_line(f)
end

---The password change form, for a password staff reset.
---@param change rpf.AuthPasswordChange Whose password, and the portal's message.
local function change_password(change)
  local f = window("Choose a new password", 330)
  label(f, change.message or "Your password was reset. Choose a new one to continue.")
  local current = field(f, "Current or temporary password", true)
  local new_password = field(f, "New password", true)
  label(f, core.auth.PASSWORD_REUSE_WARNING)
  button(f, "Change password", function()
    attempt(
      "Changing your password…",
      core.auth.change_password(change.username, current:GetValue(), new_password:GetValue())
    )
  end, true)
  status_line(f)
end

---The character select screen.
---@param list rpf.picker.Character[] The player's characters.
---@param selected string? The id of the character in play.
---@param truncated boolean Whether some characters are not shown.
local function characters(list, selected, truncated)
  local f = window("Characters", 520)
  local scroll = vgui.Create("DScrollPanel", f) --[[@as DScrollPanel]]
  scroll:Dock(FILL)
  if #list == 0 then
    label(scroll, "You have no characters yet. Create one below.")
  end
  for _, character in ipairs(list) do
    local name = character.first_name .. " " .. character.last_name
    if character.id == selected then
      label(scroll, name .. " (playing now)")
    else
      local id = character.id
      button(scroll, "Play " .. name, function()
        attempt("Loading " .. name .. "…", core.picker.select(id))
      end, true)
    end
  end
  if truncated then
    label(scroll, "You have more characters than this list can show.")
  end
  label(scroll, "New character")
  local first = field(scroll, "First name")
  local last = field(scroll, "Last name")
  local gender = vgui.Create("DComboBox", scroll) --[[@as DComboBox]]
  gender:Dock(TOP)
  gender:DockMargin(0, 4, 0, 4)
  for i, option in ipairs(ui.GENDERS) do
    gender:AddChoice(option, option, i == 1)
  end
  button(scroll, "Create", function()
    local _, value = gender:GetSelected()
    attempt("Creating your character…", core.picker.create(first:GetValue(), last:GetValue(), tostring(value)))
  end, true)
  if selected then
    button(scroll, "Put away the character in play", function()
      attempt("Putting your character away…", core.picker.deselect())
    end, true)
    button(scroll, "Back to the game", function()
      browsing = false
      close()
    end)
  end
  status_line(scroll)
end

---The screen for characters that could not be loaded, with a way to try
---again. Not retried by itself, so a portal that keeps refusing is not asked
---in a loop.
---@param reason string? Why, as the server said.
local function load_failed(reason)
  local f = window("Characters", 160)
  label(f, "Your characters could not be loaded (" .. tostring(reason or "unknown") .. ").")
  button(f, "Try again", function()
    attempt("Loading your characters…", core.picker.refresh())
  end, true)
  status_line(f)
end

---Opens the character screen from the console, once the player is logged in.
local function open_characters()
  if core.auth.state() ~= "authenticated" then
    return
  end
  browsing = true
  local selected = core.picker.selected()
  characters(core.picker.list(), type(selected) == "string" and selected or nil, false)
end

---Listens to the core's login and character events. Called before the core
---starts, so the first event is heard.
---@param internal rpf The core's internal table.
function ui.install(internal)
  core = internal
  local events = core.events
  events.on("auth.required", function(prompt)
    login(prompt.warning)
  end)
  events.on("auth.password_change_required", function(change)
    change_password(change)
  end)
  events.on("auth.failed", function(failure)
    if failure.during ~= "refresh" and failure.during ~= "logout" then
      say(failure.message, false)
    end
  end)
  -- The character screen opens when the server sends the list. Nothing is
  -- shown meanwhile: on a server whose characters something else owns, no
  -- list comes, and a screen waiting for one would hold the player's input.
  events.on("auth.succeeded", function()
    close()
  end)
  events.on("characters.listed", function(list, selected, truncated)
    if type(selected) == "string" and not browsing then
      close()
    else
      characters(list, type(selected) == "string" and selected or nil, truncated)
    end
  end)
  events.on("characters.result", function(result)
    if result.ok and result.during == "select" then
      browsing = false
      close()
    elseif result.during == "load" and not result.ok then
      load_failed(result.reason)
    elseif not result.ok then
      local text = "Could not " .. tostring(result.during) .. ": " .. tostring(result.reason or "refused") .. "."
      say(text, false)
      -- The server follows a refusal with a fresh list, which rebuilds the
      -- screen: the next status line shows the refusal again.
      pending_message = text
    else
      pending_message = nil
    end
  end)
  concommand.Add("rpf_characters", open_characters, nil, "Choose, switch or put away your character.")
end

return ui
