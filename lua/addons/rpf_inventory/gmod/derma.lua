---rpf_inventory's screen on a Gmod client, in Derma: a frame with the
---character's money, and each container's stacks as tiles with their
---images. Clicking a tile opens a menu of what the player may do with it.
---It draws what the server answered and sends back what the player
---picked, through `client.lua`; the server checks all of it again. Shipped
---as `lua/rpf_inventory/derma.lua`.
rpf_inventory = rpf_inventory or {}

---A Derma button, with the click handler Derma calls but the Gmod
---annotations leave out.
---@class rpf_inventory.Button: DButton
---@field DoClick fun(self: DButton) Called when the button is clicked.

---The open frame, so a second command brings it forward rather than opening
---another.
---@type DFrame?
local frame = nil

---The panel inside the frame that holds what is drawn, cleared and drawn
---again on each load. Never the frame itself: clearing a `DFrame` would
---take its title bar and close button with it.
---@type Panel?
local content = nil

---The view drawn last: what an image that arrives late draws again, never
---the view of the load that asked for it, which a command may have
---replaced since.
---@type rpf_inventory.View?
local latest = nil

---Item images that have arrived, by item: paths for `DImage:SetImage`.
---@type table<string, string>
local images = {}

---Shows the player a line in chat: what a command answered.
---@param message string The line.
local function tell(message)
  chat.AddText(Color(150, 190, 255), "[Inventory] ", Color(230, 230, 230), message)
end

---Asks the player for a whole number, then calls `done` with it.
---@param title string What is asked.
---@param most integer The most it may be.
---@param done fun(n: integer) Takes the number.
local function ask_count(title, most, done)
  Derma_StringRequest(title, "How many? (1 to " .. most .. ")", tostring(most), function(text)
    local n = tonumber(text)
    if n and n >= 1 and n <= most and n % 1 == 0 then
      done(n)
    else
      tell("That is not a number from 1 to " .. most .. ".")
    end
  end)
end

---Sends a command, says how it went, and draws the view again.
---@param rpf rpf.Api The API.
---@param action string The command: `move`, `use`, `drop`, `give` or `cash`.
---@param payload table What it names.
local function send(rpf, action, payload)
  rpf_inventory.command(rpf, action, payload, function(ok, message)
    tell(ok and "Done." or tostring(message))
    rpf_inventory.refresh_hud(rpf, rpf_inventory.draw_hud)
    if IsValid(frame) then
      rpf_inventory.open_derma(rpf)
    end
  end)
end

---The menu of what the player may do with a stack.
---@param rpf rpf.Api The API.
---@param view rpf_inventory.View The view.
---@param container table The stack's container.
---@param stack table The stack.
local function stack_menu(rpf, view, container, stack)
  local ref = rpf_inventory.ref(container.id, stack)
  local menu = DermaMenu()
  if stack.usable then
    menu:AddOption("Use", function()
      send(rpf, "use", { stack = ref })
    end)
  end
  for _, other in ipairs(view.containers) do
    if other.id ~= container.id then
      menu:AddOption("Move to " .. other.name, function()
        ask_count("Move to " .. other.name, stack.count, function(n)
          send(rpf, "move", { stack = ref, to = other.id, count = n })
        end)
      end)
    end
  end
  if view.allow.give and #view.nearby > 0 then
    local give = menu:AddSubMenu("Give to")
    for _, player in ipairs(view.nearby) do
      give:AddOption(player.name, function()
        ask_count("Give to " .. player.name, stack.count, function(n)
          send(rpf, "give", { stack = ref, to = player.id, count = n })
        end)
      end)
    end
  end
  if view.allow.drop then
    menu:AddOption("Throw away", function()
      ask_count("Throw away", stack.count, function(n)
        send(rpf, "drop", { stack = ref, count = n })
      end)
    end)
  end
  menu:Open()
end

---The menu for handing cash to a player nearby.
---@param rpf rpf.Api The API.
---@param view rpf_inventory.View The view.
local function cash_menu(rpf, view)
  local menu = DermaMenu()
  for _, player in ipairs(view.nearby) do
    menu:AddOption(player.name, function()
      Derma_StringRequest("Hand over " .. view.cash_account, "How much?", "", function(text)
        local amount = tonumber(text)
        if amount and amount >= 1 and amount % 1 == 0 then
          send(rpf, "cash", { amount = amount, to = player.id })
        else
          tell("That is not an amount.")
        end
      end)
    end)
  end
  menu:Open()
end

---A stack's tile: its image when it has arrived, its name and count.
---@param rpf rpf.Api The API.
---@param view rpf_inventory.View The view.
---@param container table The stack's container.
---@param stack table The stack.
---@param parent DIconLayout Where it goes.
local function tile(rpf, view, container, stack, parent)
  local name = stack.name or stack.item
  local button = parent:Add("DButton") --[[@as rpf_inventory.Button]]
  button:SetSize(84, 92)
  button:SetText("")
  button:SetTooltip(stack.special and (name .. " (one of a kind)") or name)
  button.DoClick = function()
    stack_menu(rpf, view, container, stack)
  end
  local src = images[stack.item]
  if src then
    local image = vgui.Create("DImage", button)
    image:SetPos(18, 6)
    image:SetSize(48, 48)
    image:SetImage(src)
  end
  local label = vgui.Create("DLabel", button)
  label:SetText(name .. " ×" .. stack.count)
  label:SetContentAlignment(2)
  label:Dock(BOTTOM)
end

---Draws the view in the frame.
---@param rpf rpf.Api The API.
---@param view rpf_inventory.View The view.
local function draw(rpf, view)
  if not content or not IsValid(content) then
    return
  end
  content:Clear()
  local scroll = vgui.Create("DScrollPanel", content)
  scroll:Dock(FILL)
  local balances = {}
  for _, account in ipairs(view.money) do
    balances[#balances + 1] = account.account .. ": " .. account.balance
  end
  local money = scroll:Add("DLabel")
  money:SetText(#balances > 0 and table.concat(balances, "    ") or "No money to show.")
  money:Dock(TOP)
  money:SetTall(24)
  if view.allow.cash and #view.nearby > 0 then
    local cash = scroll:Add("DButton") --[[@as rpf_inventory.Button]]
    cash:SetText("Hand over cash")
    cash:Dock(TOP)
    cash.DoClick = function()
      cash_menu(rpf, view)
    end
  end
  if not view.items then
    local aside = scroll:Add("DLabel")
    aside:SetText("This server's own inventory holds your items.")
    aside:Dock(TOP)
    return
  end
  for _, container in ipairs(view.containers) do
    local heading = scroll:Add("DLabel")
    local weight = container.max_weight and (container.weight .. " / " .. container.max_weight) or tostring(container.weight)
    heading:SetText(container.name .. "   " .. weight)
    heading:SetFont("DermaDefaultBold")
    heading:Dock(TOP)
    heading:DockMargin(0, 10, 0, 4)
    local tiles = scroll:Add("DIconLayout")
    tiles:Dock(TOP)
    tiles:SetSpaceX(6)
    tiles:SetSpaceY(6)
    for _, stack in ipairs(container.stacks) do
      tile(rpf, view, container, stack, tiles)
    end
  end
end

---Opens the inventory, or draws it again when it is open: asks the server
---for the view, then fetches each item's image and draws again as one
---arrives.
---@param rpf rpf.Api The API.
function rpf_inventory.open_derma(rpf)
  if not IsValid(frame) then
    frame = vgui.Create("DFrame") --[[@as DFrame]]
    frame:SetTitle("Inventory")
    frame:SetSize(math.min(620, ScrW() * 0.5), ScrH() * 0.8)
    frame:SetPos(ScrW() - frame:GetWide() - 20, ScrH() * 0.1)
    frame:MakePopup()
    content = vgui.Create("DPanel", frame)
    content:Dock(FILL)
    content:SetPaintBackground(false)
  end
  rpf_inventory.load(rpf, function(view, err)
    if not view then
      tell(tostring(err))
      if frame and IsValid(frame) then
        frame:Close()
      end
      return
    end
    if err then
      tell(err)
    end
    latest = view
    draw(rpf, view)
    rpf_inventory.images(rpf, view, function(item, src)
      if images[item] ~= src then
        images[item] = src
        if latest then
          draw(rpf, latest)
        end
      end
    end)
  end)
end
