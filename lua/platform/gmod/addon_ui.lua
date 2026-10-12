---The UI an addon shows a player on Gmod (J10, #239): the client
---platform's `ui`, in Derma and Gmod's own notifications, as FiveM's is on
---ox_lib.
---
---`rpf.ui` hands each function a spec it has already checked and reads
---what comes back, so this only draws and reports: a notification with
---`notification.AddLegacy`; a menu of buttons; an input dialog that will not
---submit until its required fields are filled and within their bounds, as
---ox_lib's will not; and a progress bar that the player cancels with X when
---the spec allows it. Every window but the progress bar takes the keyboard
---and mouse while it is open, as the login screens do (`ui.lua`).
---@class rpf.gmod.AddonUi
---@field WIDTH number Every window's width, in pixels.
---@field ICON number The side of an item's image beside a menu option, in pixels.
---@field CANCEL_KEY integer The key that cancels a progress bar: X, as on ox_lib.
---@field MAX_SCREEN number The most of the screen's height a window takes; a longer menu or dialog scrolls.
---@field TEXT_CHARS integer About how many bytes of a menu's text fit one line of the window, to size it before Derma wraps the text.
---@field ui rpf.ClientUi What the client platform's `ui` is.
local addon_ui = {}

addon_ui.WIDTH = 360
addon_ui.ICON = 16
addon_ui.CANCEL_KEY = KEY_X
addon_ui.MAX_SCREEN = 0.8
addon_ui.TEXT_CHARS = 48

---How each kind of notification shows: Gmod has its own icons for a hint
---and an error.
---@type table<string, integer>
local NOTICE_TYPES = {
  info = NOTIFY_GENERIC,
  success = NOTIFY_HINT,
  warning = NOTIFY_ERROR,
  error = NOTIFY_ERROR,
}

---A Derma button, with the click handler Derma calls but the Gmod
---annotations leave out.
---@class rpf.gmod.AddonButton: DButton
---@field DoClick fun(self: DButton) Called when the button is clicked.

---A Derma window, with the handlers Derma calls but the Gmod annotations
---leave out.
---@class rpf.gmod.AddonFrame: DFrame
---@field OnClose fun(self: DFrame) Called when the window closes.
---@field Think fun(self: DFrame) Called every frame.

---The window on show for each kind, so `close` can take it away.
---@type table<string, Panel>
local open = {}

---Calls `done` once, whatever calls it first.
---@param done function The callback.
---@return function once The same callback, which runs once.
local function once(done)
  local called = false
  return function(...)
    if not called then
      called = true
      done(...)
    end
  end
end

---Opens a window that takes the keyboard and mouse, no taller than
---`MAX_SCREEN` of the screen, and the panel its contents go in, which
---scrolls when they are taller: 32 options do not fit a 720p screen.
---@param title string Its title.
---@param height number The height its contents want, in pixels.
---@return rpf.gmod.AddonFrame frame The window.
---@return DScrollPanel body Where its contents go.
local function window(title, height)
  local frame = vgui.Create("DFrame") --[[@as rpf.gmod.AddonFrame]]
  frame:SetTitle(title)
  frame:SetSize(addon_ui.WIDTH, math.min(height, ScrH() * addon_ui.MAX_SCREEN))
  frame:Center()
  frame:MakePopup()
  local body = vgui.Create("DScrollPanel", frame) --[[@as DScrollPanel]]
  body:Dock(FILL)
  return frame, body
end

---Adds a button.
---@param parent Panel Where.
---@param text string Its text.
---@param click fun() What it does.
---@return rpf.gmod.AddonButton button The button.
local function button(parent, text, click)
  local b = vgui.Create("DButton", parent) --[[@as rpf.gmod.AddonButton]]
  b:Dock(TOP)
  b:DockMargin(0, 4, 0, 4)
  b:SetText(text)
  b.DoClick = function()
    click()
  end
  return b
end

---Adds a line of text.
---@param parent Panel Where.
---@param text string What it says.
---@return DLabel label The label.
local function label(parent, text)
  local l = vgui.Create("DLabel", parent) --[[@as DLabel]]
  l:Dock(TOP)
  l:DockMargin(0, 4, 0, 0)
  l:SetWrap(true)
  l:SetAutoStretchVertical(true)
  l:SetText(text)
  return l
end

---A notification, in Gmod's own.
---@param spec rpf.ui.NoticeSpec The notification.
---@param done fun() Called once it is shown.
local function show_notice(spec, done)
  local text = spec.title and (spec.title .. ": " .. spec.text) or spec.text
  notification.AddLegacy(text, NOTICE_TYPES[spec.kind] or NOTIFY_GENERIC, spec.duration_ms / 1000)
  done()
end

---A menu: one button per option, a disabled option's greyed out, and an
---option's item image (P3, #361) a `DImage` at the left of its button, from
---the `Material()` path `rpf.items` keeps (`images.lua`), its text moved
---over to make room. A menu's `text` (an NPC's line, L1) is a wrapped
---label above the buttons. Closing the window is closing the menu.
---@param spec rpf.ui.MenuSpec The menu.
---@param done fun(index: integer?) Called once.
local function show_menu(spec, done)
  local finish = once(done)
  local lines = spec.text and math.ceil(#spec.text / addon_ui.TEXT_CHARS) + select(2, spec.text:gsub("\n", "")) or 0
  local frame, body = window(spec.title, 64 + #spec.options * 34 + lines * 18)
  open.menu = frame
  if spec.text then
    label(body, spec.text)
  end
  for i, option in ipairs(spec.options) do
    local b = button(body, option.label, function()
      finish(i)
      frame:Remove()
    end)
    if option.description then
      b:SetTooltip(option.description)
    end
    if option.disabled then
      b:SetEnabled(false)
    end
    if option.image then
      local icon = vgui.Create("DImage", b) --[[@as DImage]]
      icon:Dock(LEFT)
      icon:DockMargin(4, 3, 4, 3)
      icon:SetWide(addon_ui.ICON)
      icon:SetImage(option.image)
      b:SetTextInset(addon_ui.ICON + 8, 0)
    end
  end
  frame.OnClose = function()
    finish(nil)
  end
end

---One field's control, and how to read it.
---@param frame Panel Where it goes.
---@param field rpf.ui.FieldSpec The field.
---@return fun(): any read Its value as the player left it: text, a number, a boolean, a select's option number, or nil for nothing.
local function control(frame, field)
  if field.kind == "checkbox" then
    local box = vgui.Create("DCheckBoxLabel", frame) --[[@as DCheckBoxLabel]]
    box:Dock(TOP)
    box:DockMargin(0, 6, 0, 0)
    box:SetText(field.label)
    box:SetValue(field.default == true)
    return function()
      return box:GetChecked()
    end
  end
  label(frame, field.label .. (field.required and " *" or ""))
  if field.kind == "select" then
    local combo = vgui.Create("DComboBox", frame) --[[@as DComboBox]]
    combo:Dock(TOP)
    for i, option in ipairs(field.options or {}) do
      combo:AddChoice(option, i, field.default == i)
    end
    return function()
      local _, data = combo:GetSelected()
      return data
    end
  end
  local entry = vgui.Create("DTextEntry", frame) --[[@as DTextEntry]]
  entry:Dock(TOP)
  if field.placeholder then
    entry:SetPlaceholderText(field.placeholder)
  end
  if field.default ~= nil then
    entry:SetValue(tostring(field.default))
  end
  if field.kind == "number" then
    entry:SetNumeric(true)
    return function()
      local value = entry:GetValue()
      if value == "" then
        return nil
      end
      return tonumber(value) or value
    end
  end
  return function()
    local value = entry:GetValue()
    return value ~= "" and value or nil
  end
end

---What is wrong with one field's value, for the line under the form, or
---nil if nothing is: the checks `rpf.ui` makes of the answer, made first
---so the player can put it right.
---@param field rpf.ui.FieldSpec The field.
---@param value any Its value.
---@return string? problem What to fix.
local function problem(field, value)
  if field.kind == "checkbox" then
    return (field.required and value ~= true) and (field.label .. " must be ticked.") or nil
  end
  if value == nil then
    return field.required and (field.label .. " is required.") or nil
  end
  if field.kind == "number" then
    if type(value) ~= "number" then
      return field.label .. " must be a number."
    end
    if (field.min and value < field.min) or (field.max and value > field.max) then
      return field.label .. " must be between " .. tostring(field.min or "any") .. " and " .. tostring(field.max or "any") .. "."
    end
  elseif field.kind == "text" then
    if #value < (field.min or 0) then
      return field.label .. " is too short."
    end
    if field.max and #value > field.max then
      return field.label .. " is too long."
    end
  end
  return nil
end

---An input dialog: a control per field, and Submit and Cancel. Submit
---says what is wrong rather than answering with something the server would
---refuse.
---@param spec rpf.ui.InputSpec The dialog.
---@param done fun(values: table?) Called once.
local function show_input(spec, done)
  local finish = once(done)
  local frame, body = window(spec.title, 120 + #spec.fields * 52)
  open.input = frame
  local readers = {}
  for i, field in ipairs(spec.fields) do
    readers[i] = control(body, field)
  end
  local status = label(body, "")
  button(body, "Submit", function()
    local values = {}
    for i, field in ipairs(spec.fields) do
      local value = readers[i]()
      local wrong = problem(field, value)
      if wrong then
        status:SetText(wrong)
        return
      end
      values[i] = value
    end
    finish(values)
    frame:Remove()
  end)
  button(body, "Cancel", function()
    finish(nil)
    frame:Remove()
  end)
  frame.OnClose = function()
    finish(nil)
  end
end

---A progress bar along the bottom of the screen, which leaves the player
---their keyboard and mouse: it fills over its duration, and X cancels it
---when the spec allows it.
---@param spec rpf.ui.ProgressSpec The bar.
---@param done fun(completed: boolean) Called once.
local function show_progress(spec, done)
  local finish = once(done)
  local frame = vgui.Create("DFrame") --[[@as rpf.gmod.AddonFrame]]
  frame:SetTitle(spec.cancel and (spec.label .. " (X to cancel)") or spec.label)
  frame:SetSize(addon_ui.WIDTH, 56)
  frame:ShowCloseButton(false)
  frame:SetDraggable(false)
  frame:SetPos((ScrW() - addon_ui.WIDTH) / 2, ScrH() - 120)
  open.progress = frame
  local bar = vgui.Create("DProgress", frame) --[[@as DProgress]]
  bar:Dock(FILL)
  bar:SetFraction(0)
  local started = SysTime()
  frame.Think = function()
    local fraction = (SysTime() - started) * 1000 / spec.duration_ms
    if fraction >= 1 then
      finish(true)
      frame:Remove()
      return
    end
    if spec.cancel and input.IsKeyDown(addon_ui.CANCEL_KEY) then
      finish(false)
      frame:Remove()
      return
    end
    bar:SetFraction(fraction)
  end
end

---Takes away the window of a kind, because the addon that asked for it
---stopped. The core has counted it as closed already.
---@param kind string Which.
local function close(kind)
  local frame = open[kind]
  open[kind] = nil
  if frame and IsValid(frame) then
    frame:Remove()
  end
end

addon_ui.ui = { notify = show_notice, menu = show_menu, input = show_input, progress = show_progress, close = close }

return addon_ui
