---rpf_inventory on a player's client: what the screen asks the server, in
---the order it asks it. Engine-neutral; the FiveM entry point draws the
---result in its NUI page and the Gmod one in Derma.
---
---The client decides nothing. It asks for the view, draws it, and sends
---back what the player picked, naming each stack the way the server named
---it (`{ container, index, item, key }`) and each player by the id the
---server listed them under. The server checks all of it again.
rpf_inventory = rpf_inventory or {}

---The client's view: what `rpf_inventory.open` answered, with each
---container's stacks filled in from its pages.
---@class rpf_inventory.View
---@field items boolean Whether this server's items are RPF's, so there is anything to list.
---@field containers { id: string, name: string, layout: string, grid: table?, max_weight: number?, weight: number, count: integer, stacks: table[] }[] The character's containers.
---@field money { account: string, balance: number }[] Each account's balance.
---@field nearby { id: string, name: string }[] The players near enough to be given something, nearest first.
---@field cash_account string The account cash is handed from.
---@field allow { give: boolean, drop: boolean, cash: boolean } What staff allow.

---How many requests this client has numbered.
local numbered = 0

---A new request number: the client's own, unique while it runs, so the
---server can tell a request sent again from a new one.
---@param rpf rpf.Api The API.
---@return string request The number.
function rpf_inventory.new_request(rpf)
  numbered = numbered + 1
  return string.format("%d-%d", math.floor(rpf.time.now() or 0), numbered)
end

---Asks the server through an interaction, and sends the same payload, with
---the same request number, once more if no answer came in time: the server
---answers a repeat as it answered the first, so nothing happens twice.
---@param rpf rpf.Api The API.
---@param name string The interaction.
---@param payload table What to send.
---@param callback fun(ok: boolean, result: any) Called once with the answer.
function rpf_inventory.ask(rpf, name, payload, callback)
  ---Sends it, once more after a timeout.
  ---@param again boolean Whether this is the second try.
  local function send(again)
    local sent, err = rpf.interactions.request(name, payload, function(ok, result)
      if not ok and result == "timeout" and not again then
        send(true)
        return
      end
      callback(ok, result)
    end)
    if not sent then
      callback(false, err)
    end
  end
  send(false)
end

---Loads the whole view: the first answer, then each container's stacks a
---page at a time.
---@param rpf rpf.Api The API.
---@param callback fun(view: rpf_inventory.View?, err: string?) Called once: the view (with `err` naming a page that failed, if one did), or nil and why.
function rpf_inventory.load(rpf, callback)
  rpf_inventory.ask(rpf, "rpf_inventory.open", {}, function(ok, view)
    if not ok then
      callback(nil, tostring(view))
      return
    end
    ---@cast view rpf_inventory.View
    local waiting = #view.containers
    if waiting == 0 then
      callback(view)
      return
    end
    local failed = nil
    for _, container in ipairs(view.containers) do
      container.stacks = {}
      ---Asks for the page from a stack on, and the next while there is one.
      ---@param from integer The first stack's index.
      local function fetch(from)
        rpf_inventory.ask(rpf, "rpf_inventory.page", { container = container.id, from = from }, function(got, page)
          if got and #page.stacks > 0 then
            for _, stack in ipairs(page.stacks) do
              container.stacks[#container.stacks + 1] = stack
            end
            if page.more then
              fetch(from + #page.stacks)
              return
            end
          elseif not got then
            failed = failed or tostring(page)
          end
          waiting = waiting - 1
          if waiting == 0 then
            callback(view, failed)
          end
        end)
      end
      fetch(1)
    end
  end)
end

---How a screen names a stack back to the server: as the server named it.
---@param container string The container's id.
---@param stack table The stack, as a page carried it.
---@return rpf.InventoryStackRef ref The reference.
function rpf_inventory.ref(container, stack)
  return { container = container, index = stack.index, item = stack.item, key = stack.key }
end

---Sends one of the screen's commands, under a new request number.
---@param rpf rpf.Api The API.
---@param action string The command: `move`, `use`, `drop`, `give` or `cash`.
---@param payload table What it names: `stack`, `to`, `count`, `amount`, `position`, as the command takes them.
---@param callback fun(ok: boolean, message: string?) Called once: whether it went through, and why not.
function rpf_inventory.command(rpf, action, payload, callback)
  payload.request = rpf_inventory.new_request(rpf)
  rpf_inventory.ask(rpf, "rpf_inventory." .. action, payload, function(ok, result)
    callback(ok, not ok and tostring(result) or nil)
  end)
end

---Fetches the image of every item the view shows, each once, and hands each
---to `draw` as it arrives. An item without one is left to its name.
---@param rpf rpf.Api The API.
---@param view rpf_inventory.View The view.
---@param draw fun(item: string, src: string) Takes an item's image: a `data:` URL on FiveM, a path for `Material()` on Gmod.
function rpf_inventory.images(rpf, view, draw)
  local asked = {}
  for _, container in ipairs(view.containers) do
    for _, stack in ipairs(container.stacks or {}) do
      if not asked[stack.item] then
        asked[stack.item] = true
        rpf.items.image(stack.item, function(image)
          if image then
            draw(stack.item, image.src)
          end
        end)
      end
    end
  end
end
