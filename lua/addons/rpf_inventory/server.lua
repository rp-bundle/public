---rpf_inventory on the game server: the addon's registration and its
---interactions. Engine-neutral: everything goes through `rpf`, the public
---API, which the entry point hands in.
---
---**Every payload is hostile.** A player's client may send anything, so
---each interaction passes the stack it names to `rpf.inventory`, which
---resolves it among the player's own containers, and resolves the player
---it names among those standing near them now, as the server measures it.
---A client's word decides nothing but what it asks for.
---
---**One op id per thing a player did.** The client numbers each request
---(`request`, its own string), and the server mints the op id for it the
---first time it sees that number, and hands back the same op id when the
---client sends the request again after a timeout. So a throw-away sent
---twice throws away once, and a request a client makes up is just a new
---one of its own. That memory lasts as long as this file's code runs, and
---the view names it (`session`): a command naming a session the server no
---longer remembers (the resource restarted, a Gmod Lua refresh) is refused
---before anything runs, and the client looks again, rather than getting a
---fresh op id for a request that may already have gone through.
rpf_inventory = rpf_inventory or {}

---How many stacks one page of a container carries: a screen asks for each
---container a page at a time, since an interaction's answer is capped at
---16 KiB and a container may hold hundreds of stacks. Sized for the worst
---stack the catalog allows, not the usual one: a 64-byte slug, a name of 64
---characters each escaped to six bytes (384), a 16-digit key, `u32` counts
---and `i32` cells, and every flag, come to about 630 bytes encoded, and 24
---of them to about 15 KiB.
rpf_inventory.PAGE = 24

---How long the server remembers the op id it minted for a client's
---request, in milliseconds. The client sends a request again once, after
---its ten-second timeout, so two minutes is far past the last resend.
rpf_inventory.REQUEST_MS = 2 * 60 * 1000

---The most requests the server remembers per player at once: more than the
---interaction rate (20 every 10 seconds) lets a player send in
---`REQUEST_MS`. Never one forgotten early, which would give its resend a
---new op id: past this, a new request is refused until old ones expire.
rpf_inventory.MAX_REQUESTS = 256

---The most containers the view lists, and the most nearby players: with
---names cut to `MAX_NAME_BYTES`, the view's answer stays well under the
---16 KiB an interaction may answer, however many containers a character
---has or however crowded it is (about 600 bytes a container and 330 a
---player at worst).
rpf_inventory.MAX_LISTED = 12

---The most accounts the view and the HUD list.
rpf_inventory.MAX_ACCOUNTS = 16

---The longest name the view carries, in bytes; a longer one is cut on a
---character boundary. Container names have no bound of their own.
rpf_inventory.MAX_NAME_BYTES = 64

---What a command naming a session this server does not remember is told:
---the client looks again, since the request may already have gone through.
rpf_inventory.STALE_SESSION = "The inventory changed. Look again."

---What a refusal from `rpf.inventory` or `rpf.money` tells the player.
---@type table<string, string>
rpf_inventory.REASONS = {
  not_found = "That is not there any more.",
  stale = "That moved. Look again.",
  no_space = "There is no room for it.",
  insufficient = "There are not that many.",
  insufficient_funds = "You do not have that much.",
  no_account = "There is no such account.",
  no_target = "They cannot take it now.",
  no_use = "That has no use.",
  busy = "You are already using something.",
  invalid_contents = "That container breaks its rules; ask staff to look at it.",
  unsupported = "That is not done here.",
  not_logged_in = "You are not logged in.",
  no_character = "You are not playing a character.",
  out_of_range = "That is more than an account may hold.",
  journal_full = "The server is too busy. Try again later.",
  invalid = "That is not something to ask.",
}

---Remembered requests: by player id, request number to `{ op, at }`. Kept
---across the addon's stops and starts, which do not reload this file:
---only a reload forgets them, and that changes `session`.
---@type table<string, table<string, { op: string, at: number }>>
local requests = {}

---This file's run's name for its memory of requests, minted the first time
---a view is opened. A client sends it with every command.
---@type string?
local session = nil

---The session this run's views name, minted on first use.
---@param rpf rpf.Api The API.
---@return string? session The session, or nil before the core can mint an id.
function rpf_inventory.session(rpf)
  session = session or rpf.ops.new()
  return session
end

---The settings in force: the record staff made, over the defaults.
---@param rpf rpf.Api The API.
---@return rpf_inventory.Settings settings A fresh table.
function rpf_inventory.settings(rpf)
  local out = {}
  for key, value in pairs(rpf_inventory.DEFAULTS) do
    out[key] = value
  end
  local records = rpf.records.list(rpf_inventory.SETTINGS, { limit = 1 })
  local record = records and records[1]
  if record then
    for key in pairs(rpf_inventory.DEFAULTS) do
      if record.fields[key] ~= nil then
        out[key] = record.fields[key]
      end
    end
  end
  return out
end

---Whether this server's items are RPF's, so the screen has something to
---show: false where a framework owns them (ox_inventory on Qbox).
---@param rpf rpf.Api The API.
---@return boolean ours True if they are.
function rpf_inventory.items_here(rpf)
  return rpf.inventory.supports("containers")
end

---Whether the addon stands aside: a framework owns the items, and staff
---left the setting at `stand_aside`.
---@param rpf rpf.Api The API.
---@param settings rpf_inventory.Settings The settings.
---@return boolean aside True if it does.
function rpf_inventory.standing_aside(rpf, settings)
  return not rpf_inventory.items_here(rpf) and settings.beside_framework ~= "run"
end

---Whether a client's request number is one: 1 to 64 letters, digits,
---`_` and `-`.
---@param request any The number.
---@return boolean ok True if it is.
function rpf_inventory.request_ok(request)
  return type(request) == "string" and #request > 0 and #request <= 64 and request:find("^[%w_%-]+$") ~= nil
end

---The op id for a client's request: the one minted the first time the
---server saw it, or a new one. Nil for a request number that is not one,
---and for a new one while the player has `MAX_REQUESTS` remembered.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The player.
---@param request any The client's number for the request.
---@return string? op The op id.
function rpf_inventory.op_for(rpf, player, request)
  if not rpf_inventory.request_ok(request) then
    return nil
  end
  local now = rpf.time.now()
  local mine = requests[player.player_id]
  if not mine then
    mine = {}
    requests[player.player_id] = mine
  end
  local count = 0
  for key, kept in pairs(mine) do
    if now - kept.at > rpf_inventory.REQUEST_MS then
      mine[key] = nil
    else
      count = count + 1
    end
  end
  local kept = mine[request]
  if kept then
    return kept.op
  end
  if count >= rpf_inventory.MAX_REQUESTS then
    return nil
  end
  local op = rpf.ops.new()
  if not op then
    return nil
  end
  mine[request] = { op = op, at = now }
  return op
end

---Text cut to at most `bytes` bytes without splitting a UTF-8 character.
---@param text any The text.
---@param bytes integer The most bytes.
---@return string text The text, cut.
function rpf_inventory.cut(text, bytes)
  text = tostring(text)
  if #text <= bytes then
    return text
  end
  local at = bytes
  while at > 0 do
    local next_byte = text:byte(at + 1)
    if next_byte < 0x80 or next_byte >= 0xC0 then
      break
    end
    at = at - 1
  end
  return text:sub(1, at)
end

---The other players near enough to be given something: logged in, with a
---character in play, in the player's routing bucket and within the reach
---staff set. Measured by the server, so a client cannot hand anything to
---a player across the map by naming them.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The player.
---@param reach number The reach, in metres.
---@return { player_id: string, name: string, handle: any, metres: number }[] nearby Nearest first.
function rpf_inventory.nearby(rpf, player, reach)
  local out = {}
  local here = rpf.world.position(player.handle)
  if not here then
    return out
  end
  local bucket = rpf.world.bucket(player.handle)
  for _, other in ipairs(rpf.players.list()) do
    if other.player_id and other.player_id ~= player.player_id and other.state == "active" then
      local there = rpf.world.position(other.handle)
      local character = rpf.characters.current(other.handle)
      if there and character and rpf.world.bucket(other.handle) == bucket then
        local dx, dy, dz = there.x - here.x, there.y - here.y, there.z - here.z
        local metres = rpf.world.metres(math.sqrt(dx * dx + dy * dy + dz * dz))
        if metres and metres <= reach then
          out[#out + 1] = { player_id = other.player_id, name = character.name, handle = other.handle, metres = metres }
        end
      end
    end
  end
  table.sort(out, function(a, b)
    return a.metres < b.metres
  end)
  return out
end

---The player a client named, among those near enough now.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The player.
---@param reach number The reach, in metres.
---@param id any The player id the client sent.
---@return any? handle Their engine handle, or nil if they are not near.
local function near(rpf, player, reach, id)
  if type(id) ~= "string" then
    return nil
  end
  for _, other in ipairs(rpf_inventory.nearby(rpf, player, reach)) do
    if other.player_id == id then
      return other.handle
    end
  end
  return nil
end

---What a command's answer tells the player: nothing when it went
---through, a sentence otherwise.
---@param ok boolean? The command's first answer.
---@param status string? Its status.
---@param why string? Its reason, for `refused`.
---@param message string? A use handler's own sentence, for `declined`.
---@return boolean ok True if it went through.
---@return string? message Why not, for the player.
function rpf_inventory.told(ok, status, why, message)
  if ok then
    return true
  end
  if status == "unknown" then
    return false, "That may or may not have happened. Staff can see it."
  end
  if status == "unavailable" then
    return false, "That cannot be done right now. Try again in a moment."
  end
  if why == "declined" then
    return false, message or "You cannot use that now."
  end
  return false, rpf_inventory.REASONS[why] or ("That was refused (" .. tostring(why) .. ").")
end

---The screen's first answer: the containers without their stacks, the
---money, the players near enough to be given something, and what the
---settings allow.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The player.
---@return boolean ok True with the view; false and why otherwise.
---@return table|string view The view, or the sentence.
function rpf_inventory.open(rpf, player)
  local settings = rpf_inventory.settings(rpf)
  if rpf_inventory.standing_aside(rpf, settings) then
    return false, "This server's own inventory is in charge here."
  end
  local items = rpf_inventory.items_here(rpf)
  local containers = {}
  if items then
    local read, err = rpf.inventory.containers(player.handle)
    if not read then
      return false, rpf_inventory.REASONS[err] or rpf_inventory.REASONS.unsupported
    end
    for _, container in ipairs(read) do
      if #containers >= rpf_inventory.MAX_LISTED then
        break
      end
      containers[#containers + 1] = {
        id = container.id,
        name = rpf_inventory.cut(container.name, rpf_inventory.MAX_NAME_BYTES),
        layout = container.layout,
        grid = container.grid,
        max_weight = container.max_weight,
        weight = container.weight,
        count = #container.stacks,
      }
    end
  end
  local money = {}
  for _, account in ipairs(rpf.money.accounts()) do
    local balance = #money < rpf_inventory.MAX_ACCOUNTS and rpf.money.balance(player.handle, account)
    if balance then
      money[#money + 1] = { account = rpf_inventory.cut(account, rpf_inventory.MAX_NAME_BYTES), balance = balance }
    end
  end
  local nearby = {}
  for _, other in ipairs(rpf_inventory.nearby(rpf, player, settings.reach)) do
    if #nearby >= rpf_inventory.MAX_LISTED then
      break
    end
    nearby[#nearby + 1] = { id = other.player_id, name = rpf_inventory.cut(other.name, 2 * rpf_inventory.MAX_NAME_BYTES) }
  end
  return true,
    {
      items = items,
      containers = containers,
      money = money,
      nearby = nearby,
      cash_account = settings.cash_account,
      session = rpf_inventory.session(rpf),
      allow = {
        give = items and settings.allow_give,
        drop = items and settings.allow_drop,
        cash = settings.allow_cash and rpf.money.supports("transfer"),
      },
    }
end

---One page of a container's stacks, from a 1-based index: the screen's
---second request, once per container.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The player.
---@param payload table `{ container, from }`.
---@return boolean ok True with the page.
---@return table|string page `{ stacks, more }`, or why not.
function rpf_inventory.page(rpf, player, payload)
  local from = payload.from == nil and 1 or payload.from
  if type(payload.container) ~= "string" or type(from) ~= "number" or from < 1 or from % 1 ~= 0 then
    return false, rpf_inventory.REASONS.invalid
  end
  local read, err = rpf.inventory.containers(player.handle)
  if not read then
    return false, rpf_inventory.REASONS[err] or rpf_inventory.REASONS.unsupported
  end
  for _, container in ipairs(read) do
    -- Only the player's own: `containers` read nothing else.
    if container.id == payload.container then
      local stacks = {}
      for i = from, math.min(#container.stacks, from + rpf_inventory.PAGE - 1) do
        local stack = container.stacks[i]
        stacks[#stacks + 1] = {
          index = stack.index,
          item = stack.item,
          name = stack.name,
          count = stack.count,
          key = stack.key,
          usable = stack.usable,
          position = stack.position,
          rotated = stack.rotated,
          -- Its data is the server's own: the screen marks the stack as one
          -- of a kind, and never reads what it carries.
          special = stack.data ~= nil or nil,
        }
      end
      return true, { stacks = stacks, more = from + rpf_inventory.PAGE <= #container.stacks }
    end
  end
  return false, rpf_inventory.REASONS.not_found
end

---Runs one of the screen's commands for a player: checks the settings,
---mints or finds the request's op id, and passes what the client named on
---to the API, which resolves it.
---@param rpf rpf.Api The API.
---@param player rpf.PlayerView The player.
---@param action "move"|"use"|"drop"|"give"|"cash" The command.
---@param payload table What the client sent.
---@return boolean ok True if it went through.
---@return string? message Why not, for the player.
function rpf_inventory.act(rpf, player, action, payload)
  local settings = rpf_inventory.settings(rpf)
  if rpf_inventory.standing_aside(rpf, settings) then
    return false, "This server's own inventory is in charge here."
  end
  if action == "give" and not settings.allow_give then
    return false, "Giving items is off on this server."
  end
  if action == "drop" and not settings.allow_drop then
    return false, "Throwing items away is off on this server."
  end
  if action == "cash" and not settings.allow_cash then
    return false, "Handing cash over is off on this server."
  end
  if not rpf_inventory.request_ok(payload.request) then
    return false, rpf_inventory.REASONS.invalid
  end
  if payload.session == nil or payload.session ~= session then
    return false, rpf_inventory.STALE_SESSION
  end
  local op = rpf_inventory.op_for(rpf, player, payload.request)
  if not op then
    return false, "You are doing too much at once. Wait a moment."
  end
  local handle = player.handle
  if action == "move" then
    local opts = { count = payload.count, position = payload.position, rotated = payload.rotated }
    return rpf_inventory.told(rpf.inventory.move(handle, payload.stack, payload.to, op, opts))
  elseif action == "use" then
    return rpf_inventory.told(rpf.inventory.use(handle, payload.stack, op))
  elseif action == "drop" then
    return rpf_inventory.told(rpf.inventory.discard(handle, payload.stack, payload.count, op))
  end
  local target = near(rpf, player, settings.reach, payload.to)
  if not target then
    return false, "They are not near enough."
  end
  if action == "give" then
    return rpf_inventory.told(rpf.inventory.hand(handle, target, payload.stack, payload.count, op))
  end
  local giver = rpf.characters.current(handle)
  local reason = "Cash from " .. (giver and giver.name or "another player")
  return rpf_inventory.told(rpf.money.transfer(handle, target, settings.cash_account, payload.amount, reason, op))
end

---Registers the addon, and its interactions once it runs. Beside a
---framework that owns the items, and with staff's setting left at
---`stand_aside`, it says so once in the console and offers nothing.
---@param rpf rpf.Api The API.
---@return boolean? ok What `rpf.addons.register` answered.
---@return table? refusal Why not.
function rpf_inventory.start_server(rpf)
  return rpf.addons.register(rpf_inventory.MANIFEST, {
    start = function()
      if rpf_inventory.standing_aside(rpf, rpf_inventory.settings(rpf)) then
        print(
          "[rpf_inventory] standing aside: this server's framework owns its items (ox_inventory on Qbox), "
            .. "so its own inventory is in charge. Set the Inventory settings' 'Beside a framework' to run to show the money."
        )
      end
      assert(rpf.interactions.register("rpf_inventory.open", function(player)
        return rpf_inventory.open(rpf, player)
      end))
      assert(rpf.interactions.register("rpf_inventory.page", function(player, payload)
        return rpf_inventory.page(rpf, player, payload)
      end))
      for _, action in ipairs({ "move", "use", "drop", "give", "cash" }) do
        assert(rpf.interactions.register("rpf_inventory." .. action, function(player, payload)
          return rpf_inventory.act(rpf, player, action, payload)
        end))
      end
    end,
  })
end
