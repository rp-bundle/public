---acme_tags on a player's client: asking the server to spray, listing the
---player's own tags and scrubbing one, and telling the player how it went.
---Engine-neutral: the UI is `rpf.ui`, which looks right on every engine
---(ox_lib on FiveM, Derma on Gmod), with chat as the fallback where an
---engine has none. The entry point binds the commands.
acme_tags = acme_tags or {}

---The ids of the tags the last `show_mine` showed, by their number.
---@type string[]?
acme_tags.listed = nil

---Whether the answer is being listened for yet.
local listening = false

---Asks to spray a tag where the player stands.
---@param rpf rpf.Api The API.
---@param text string What to spray.
---@param tell fun(message: string) Shows the player a line.
---@return boolean? sent True once asked.
---@return string? err Why not.
function acme_tags.ask(rpf, text, tell)
  if not listening then
    listening = true
    rpf.events.on("interactions.result", function(result)
      if result.name == "acme_tags.spray" then
        tell(result.ok and "Sprayed." or ("No tag: " .. tostring(result.reason)))
      end
    end)
  end
  return rpf.interactions.send("acme_tags.spray", { text = text })
end

---A way to tell the player something: a notification where the engine shows
---one, the entry point's own line (chat) where it does not.
---@param rpf rpf.Api The API.
---@param fallback fun(message: string) The entry point's way.
---@return fun(message: string) tell Shows the player a line.
function acme_tags.teller(rpf, fallback)
  return function(message)
    if not rpf.capabilities().notify or not rpf.ui.notify({ text = message, title = "Tags" }) then
      fallback(message)
    end
  end
end

---Lets the player pick one of their tags from a menu and scrubs it: the
---server's list comes as data (`rpf.interactions.request`), the menu is
---`rpf.ui.menu` with each tag's id as its option's value, and the server
---checks the pick is the player's own, whatever id this sends. Where the
---engine has no menu, it lists them numbered for `ask_scrub` instead.
---@param rpf rpf.Api The API.
---@param tell fun(message: string) Shows the player a line.
---@return boolean? sent True once asked.
---@return string? err Why not.
function acme_tags.pick_mine(rpf, tell)
  if not rpf.capabilities().menu then
    return acme_tags.show_mine(rpf, tell)
  end
  return rpf.interactions.request("acme_tags.mine", nil, function(ok, result)
    if not ok then
      tell("Could not list your tags: " .. tostring(result))
      return
    end
    if #(result.tags or {}) == 0 then
      tell("You have no tags up.")
      return
    end
    local options = {}
    for i, tag in ipairs(result.tags) do
      options[i] = { label = tostring(tag.text), description = "Scrub it off", value = tag.id }
    end
    local shown, why = rpf.ui.menu({ title = "Your tags", options = options }, function(id)
      if not id then
        return -- closed
      end
      rpf.interactions.request("acme_tags.scrub", { id = id }, function(scrubbed, reason)
        tell(scrubbed and "Scrubbed." or ("Not scrubbed: " .. tostring(reason)))
      end)
    end)
    if not shown then
      tell("Could not show your tags: " .. tostring(why))
    end
  end)
end

---Lists the player's own tags, numbered, and keeps their ids for `ask_scrub`:
---the server answers with data, through `rpf.interactions.request`.
---@param rpf rpf.Api The API.
---@param tell fun(message: string) Shows the player a line.
---@return boolean? sent True once asked.
---@return string? err Why not.
function acme_tags.show_mine(rpf, tell)
  return rpf.interactions.request("acme_tags.mine", nil, function(ok, result)
    if not ok then
      tell("Could not list your tags: " .. tostring(result))
      return
    end
    acme_tags.listed = {}
    for i, tag in ipairs(result.tags or {}) do
      acme_tags.listed[i] = tag.id
      tell(i .. ". " .. tostring(tag.text))
    end
    if #acme_tags.listed == 0 then
      tell("You have no tags up.")
    end
  end)
end

---Scrubs one of the tags `show_mine` numbered. The server checks the tag is the
---player's own, whatever id this sends.
---@param rpf rpf.Api The API.
---@param n integer? Its number in the last list.
---@param tell fun(message: string) Shows the player a line.
---@return boolean? sent True once asked.
---@return string? err Why not.
function acme_tags.ask_scrub(rpf, n, tell)
  local id = acme_tags.listed and n and acme_tags.listed[n]
  if not id then
    tell("List your tags first, then scrub one by its number.")
    return nil, "invalid"
  end
  return rpf.interactions.request("acme_tags.scrub", { id = id }, function(ok, result)
    tell(ok and "Scrubbed." or ("Not scrubbed: " .. tostring(result)))
  end)
end
