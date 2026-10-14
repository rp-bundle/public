-- The FiveM entry point on a client: `I` (or `/rpf_inventory`) opens the
-- inventory in this resource's NUI page, which draws what the server
-- answered and posts back what the player picked. The page decides
-- nothing; every command goes to the server as an interaction.
local rpf = exports.rpf:api() ---@type rpf.Api

---Whether the page is open, with the mouse given to it.
local shown = false

---The commands the page may post, and nothing else.
local COMMANDS = { move = true, use = true, drop = true, give = true, cash = true }

---Tells the player something without the page: a notification.
---@param message string What.
local function tell(message)
  rpf.ui.notify({ title = "Inventory", text = message, kind = "error" })
end

---Loads the view and hands it to the page, then each item's image as it
---arrives. On the first load the page opens, and takes the mouse, only once
---there is something to show: a server that refuses (standing aside for its
---framework's own inventory) never takes the player's controls.
---@param opening boolean Whether this load opens the page.
local function refresh(opening)
  rpf_inventory.load(rpf, function(view, err)
    if not view then
      if opening then
        shown = false
        tell(tostring(err))
      else
        SendNUIMessage({ type = "error", message = err })
      end
      return
    end
    if opening then
      if not shown then
        return
      end
      SetNuiFocus(true, true)
      SendNUIMessage({ type = "open" })
    end
    SendNUIMessage({ type = "view", view = view, error = err })
    rpf_inventory.images(rpf, view, function(item, src)
      SendNUIMessage({ type = "image", item = item, src = src })
    end)
  end)
end

RegisterCommand("rpf_inventory", function()
  if shown then
    return
  end
  shown = true
  refresh(true)
end, false)
RegisterKeyMapping("rpf_inventory", "Open the inventory", "keyboard", "I")

RegisterNUICallback("close", function(_, cb)
  shown = false
  SetNuiFocus(false, false)
  cb({})
end)

RegisterNUICallback("command", function(data, cb)
  local action = type(data) == "table" and data.action or nil
  local payload = type(data) == "table" and data.payload or nil
  if type(action) ~= "string" or not COMMANDS[action] or type(payload) ~= "table" then
    cb({ ok = false, message = "That is not something to ask." })
    return
  end
  rpf_inventory.command(rpf, action, payload, function(ok, message)
    cb({ ok = ok, message = message })
    if shown then
      refresh(false)
    end
  end)
end)
