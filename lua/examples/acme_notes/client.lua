---acme_notes on a player's client: asking the server to pin a note, and
---telling the player how it went. Reading and taking a note down need no
---code here: they are interactions aimed at a note, which the core's
---interaction menu (`rpf_interact`) and a target resource offer whenever the
---player stands at one. Engine-neutral; the entry point binds the command.
acme_notes = acme_notes or {}

---Whether the answers to aimed interactions are being listened for yet.
local listening = false

---Asks to pin a note: with the text given, at once; without, from a dialog
---(`rpf.ui.input`) where the engine shows one. A refusal before anything
---was sent (a dialog already open, too many requests waiting) is told to
---the player too, never dropped.
---@param rpf rpf.Api The API.
---@param text string? What the note says, from the command line.
---@param tell fun(message: string) Shows the player a line.
---@return boolean? asked True once asked, or the dialog is open.
---@return string? err Why not.
function acme_notes.ask_pin(rpf, text, tell)
  if not listening then
    listening = true
    rpf.events.on("interactions.result", function(result)
      if type(result.name) == "string" and result.name:sub(1, 11) == "acme_notes." and not result.ok then
        tell(tostring(result.reason))
      end
    end)
  end
  ---Sends the note, and tells the player the answer.
  ---@param values table `{ text, colour }`.
  ---@return boolean? sent True once asked.
  ---@return string? err Why not.
  local function send(values)
    local sent, err = rpf.interactions.request("acme_notes.pin", values, function(ok, reason)
      tell(ok and "Pinned." or tostring(reason))
    end)
    if not sent then
      tell("The note was not sent (" .. tostring(err) .. ").")
    end
    return sent, err
  end
  if text and text ~= "" then
    return send({ text = text })
  end
  if not rpf.capabilities().input then
    tell("Write the note after the command.")
    return nil, "unsupported"
  end
  local shown, err = rpf.ui.input({
    title = "Pin a note",
    fields = {
      { name = "text", label = "Note", required = true, max = 120 },
      { name = "colour", label = "Colour", kind = "select", default = "white", options = {
        { label = "White", value = "white" },
        { label = "Yellow", value = "yellow" },
        { label = "Pink", value = "pink" },
      } },
    },
  }, function(values)
    if values then
      send(values)
    end
  end)
  if not shown then
    tell("No dialog now (" .. tostring(err) .. ").")
  end
  return shown, err
end

---A way to tell the player something: a notification where the engine shows
---one, the entry point's own line (chat) where it does not.
---@param rpf rpf.Api The API.
---@param fallback fun(message: string) The entry point's way.
---@return fun(message: string) tell Shows the player a line.
function acme_notes.teller(rpf, fallback)
  return function(message)
    if not rpf.capabilities().notify or not rpf.ui.notify({ text = message, title = "Notes" }) then
      fallback(message)
    end
  end
end
