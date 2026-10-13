-- The FiveM entry point on a client: `I` (or `/rpf_inventory`) opens the
-- inventory in this resource's NUI page, which draws what the server
-- answered and posts back what the player picked. The page decides
-- nothing; every command goes to the server as an interaction.
local rpf = exports.rpf:api() ---@type rpf.Api

---Whether the page is open, with the mouse given to it.
local shown = false

---The commands the page may post, and nothing else.
local COMMANDS = { move = true, use = true, drop = true, give = true, cash = true }

---Loads the view and hands it to the page, then each item's image as it
---arrives.
local function refresh()
  rpf_inventory.load(rpf, function(view, err)
    if not view then
      SendNUIMessage({ type = "error", message = err })
      return
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
  SetNuiFocus(true, true)
  SendNUIMessage({ type = "open" })
  refresh()
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
      refresh()
    end
  end)
end)
