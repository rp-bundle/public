---Dialogs (L1, #371): a conversation with an NPC, run on the server from a
---tree staff built in the panel (`rpf.config.dialog`).
---
---**The server runs it.** Each node is a menu (`rpf.ui`) shown to the
---player: the tree's title, the NPC's line as the menu's text, and the
---choices whose conditions hold for that player, each the number of the
---choice in its node, which never leaves the server. The client answers
---only which of the options it was shown it picked; `rpf.ui` refuses any
---other. A pick is then checked again against the tree **as it is now**:
---the choice must be the one shown (`changed` otherwise, if staff edited
---the tree meanwhile), its conditions must still hold, and the player
---must still be within reach of the NPC they were talking to. Only then
---does it go to another node, end, or run its action (`rpf.actions.run`).
---
---**Conditions** read the player through the domain-neutral facade, so
---they mean the same under a bridge: `job` through `facade.current_job`,
---`item` through `facade.count`, `permission` through `rpf.staff.can`. A
---read that fails (the framework unavailable, a bridge that cannot say)
---hides the choice whether or not the condition is negated: a choice is
---offered only on what is known.
---
---**A broken choice is shown, and refused when picked.** A choice whose
---action's addon is not installed, disabled, stopped, or never registered
---the handler, or whose parameters no longer pass the declaration, is not
---hidden: the player is told it is not available, and the log says which
---dialog, node and action, for staff.
---
---**Talk.** A world type whose `world` names a `dialog` field (a `ref` to
---`dialog`) needs no code to talk: as its addon starts, the core registers
---a Talk interaction aimed at the type under the addon's namespace
---(`<namespace>.rpf_talk<n>`, a name no addon may take), owned by that
---activation like the addon's own, offered on records whose field names a
---tree this server has.
---@class rpf.dialogs
---@field TALK string What the Talk interaction is labelled.
---@field GOODBYE string The way out a node with no choices offers.
---@field MESSAGES table<string, string> What the player is told when a pick is refused, by why.
local dialogs = {}

local rpf = rpf
local json = rpf.json

dialogs.TALK = "Talk"
dialogs.GOODBYE = "Goodbye."
dialogs.MESSAGES = {
  unavailable = "That isn't available right now.",
  invalid = "That isn't set up right. Let staff know.",
  failed = "Something went wrong.",
  refused = "You can't do that.",
  conditions = "That isn't open to you any more.",
  changed = "They've changed what they have to say. Talk to them again.",
  gone = "You've walked away.",
}

---@type rpf.ServerPlatform?
local platform = nil

---Logs, once the platform is known.
---@param level string The level.
---@param message string What happened.
local function log(level, message)
  if platform then
    platform.log(level, "rpf.dialogs: " .. message)
  end
end

---One conversation, the newest for its player.
---@class rpf.dialogs.Conversation
---@field slug string The tree.
---@field node string The node on show.
---@field shown table<integer, string> Each choice offered, by its number in the node, encoded as it was shown, to tell it from one staff changed since.
---@field target rpf.targets.Target? The NPC, when the conversation was opened from it.
---@field rule { name: string, rules: rpf.targets.Rules? }? The Talk rule it was opened through, to check the player is still within reach.

---The conversation each player is in, by player id: the one whose menu is
---on their screen. A conversation becomes theirs only once its menu is
---shown, so one that could not open (`busy`) leaves the one on screen
---working, and a pick answering any other is dropped.
---@type table<string, rpf.dialogs.Conversation>
local talking = {}

---Whether a condition holds for a player, or nil when it cannot be told.
---@param handle any The player's engine handle.
---@param condition table The condition, as the tree has it.
---@return boolean? holds True or false, or nil if a read failed.
function dialogs.holds(handle, condition)
  local holds
  if condition.kind == "job" then
    local job, err = rpf.facade.current_job(handle)
    if err then
      return nil
    end
    holds = job ~= nil
      and (condition.employer == nil or job.employer == condition.employer)
      and (condition.job == nil or job.name == condition.job)
      and (condition.min_grade == nil or (type(job.grade) == "number" and job.grade >= condition.min_grade))
      and (condition.on_duty == nil or job.on_duty == condition.on_duty)
  elseif condition.kind == "item" then
    local count = rpf.facade.count(handle, condition.item)
    if type(count) ~= "number" then
      return nil
    end
    holds = count >= (condition.count or 1)
  elseif condition.kind == "permission" then
    holds = rpf.staff.can(handle, condition.permission)
  else
    -- A kind this core does not know, from a newer portal: unknown.
    return nil
  end
  if condition.negate == true then
    return not holds
  end
  return holds == true
end

---Whether every condition of a choice holds for a player.
---@param handle any The player's engine handle.
---@param choice table The choice.
---@return boolean offered True if every one holds.
local function offered(handle, choice)
  if type(choice.conditions) ~= "table" then
    return true
  end
  for _, condition in ipairs(choice.conditions) do
    if dialogs.holds(handle, condition) ~= true then
      return false
    end
  end
  return true
end

---A node of a tree, by key.
---@param dialog table The tree.
---@param key string The node's key.
---@return table? node The node.
local function node_of(dialog, key)
  for _, node in ipairs(dialog.nodes or {}) do
    if node.key == key then
      return node
    end
  end
  return nil
end

---Tells a player why their pick did nothing.
---@param handle any The player's engine handle.
---@param text string What to tell them.
local function tell(handle, text)
  rpf.ui.members().notify(handle, { text = text, kind = "error" })
end

---Shows a node, or ends the conversation if it cannot be.
local show

---Reads the player's pick against the tree as it is now, and does it.
---@param handle any The player's engine handle.
---@param conversation rpf.dialogs.Conversation The conversation the menu belongs to.
---@param choice_number any The option's value: a choice's number in the node, or `"end"`.
local function picked(handle, conversation, choice_number)
  local found = rpf.players.get(handle)
  local player_id = found and found.player_id
  if not found or not player_id or talking[player_id] ~= conversation then
    -- The player left, or is in another conversation: not this one's.
    return
  end
  local player = found --[[@as rpf.PlayerView]]
  if choice_number == "end" then
    talking[player_id] = nil
    return
  end
  local dialog = rpf.config.dialog(conversation.slug)
  local node = dialog and node_of(dialog, conversation.node)
  local choice = node and type(node.choices) == "table" and node.choices[choice_number]
  local was = conversation.shown[choice_number]
  if not node or not choice or not was or json.encode(choice) ~= was then
    talking[player_id] = nil
    tell(handle, dialogs.MESSAGES.changed)
    return
  end
  if not offered(handle, choice) then
    talking[player_id] = nil
    tell(handle, dialogs.MESSAGES.conditions)
    return
  end
  local rule = conversation.rule
  if rule and rule.rules and conversation.target then
    local again = rpf.targets.admit(rule.name, rule.rules, player, { target = { id = conversation.target.id } }, true)
    if not again then
      talking[player_id] = nil
      tell(handle, dialogs.MESSAGES.gone)
      return
    end
    conversation.target = again
  end
  local does = choice.does or {}
  if does.kind == "goto" then
    conversation.node = does.node
    show(handle, conversation)
    return
  end
  talking[player_id] = nil
  if does.kind ~= "action" then
    return
  end
  local ok, why, detail = rpf.actions.run(player, does.action, does.params, {
    dialog = conversation.slug,
    node = node.key,
    target = conversation.target,
  })
  if ok then
    return
  end
  if why == "refused" then
    tell(handle, type(detail) == "string" and detail or dialogs.MESSAGES.refused)
    return
  end
  local where = conversation.slug .. "/" .. node.key .. " runs " .. tostring(does.action)
  if why == "invalid" then
    log("warn", "a choice in " .. where .. " with parameters it does not take: " .. json.encode(detail or {}))
    tell(handle, dialogs.MESSAGES.invalid)
  elseif why == "failed" then
    tell(handle, dialogs.MESSAGES.failed)
  else
    log("warn", "a choice in " .. where .. ", which is " .. tostring(why) .. " here")
    tell(handle, dialogs.MESSAGES.unavailable)
  end
end

---Shows the conversation's node as a menu of the choices offered to the
---player now.
---@param handle any The player's engine handle.
---@param conversation rpf.dialogs.Conversation The conversation.
---@return boolean? ok True once shown.
---@return string? err Why not: what `rpf.ui`'s menu says, or `not_found` for a node the tree no longer has.
show = function(handle, conversation)
  local player = rpf.players.get(handle)
  local dialog = rpf.config.dialog(conversation.slug)
  local node = dialog and node_of(dialog, conversation.node)
  if not player or not player.player_id or not node then
    if player and player.player_id and talking[player.player_id] == conversation then
      talking[player.player_id] = nil
    end
    return nil, "not_found"
  end
  local options, shown = {}, {}
  for i, choice in ipairs(node.choices or {}) do
    if offered(handle, choice) then
      options[#options + 1] = { label = choice.label, value = i }
      shown[i] = json.encode(choice)
    end
  end
  if #options == 0 then
    options[1] = { label = dialogs.GOODBYE, value = "end" }
  end
  conversation.shown = shown
  local player_id = player.player_id --[[@as string]]
  local ok, err = rpf.ui.members().menu(handle, {
    title = (dialog --[[@as table]]).title,
    text = node.line,
    options = options,
  }, function(value)
    -- Nil when the player closed it, left, or it timed out: it ends.
    if value == nil then
      if talking[player_id] == conversation then
        talking[player_id] = nil
      end
      return
    end
    picked(handle, conversation, value)
  end)
  if not ok then
    -- The conversation that could not go on ends; one that could not open
    -- was never theirs, and the one on their screen goes on.
    if talking[player_id] == conversation then
      talking[player_id] = nil
    end
    return nil, err
  end
  talking[player_id] = conversation
  return true
end

---Options for `open`.
---@class rpf.dialogs.OpenOptions
---@field target rpf.targets.Target? The NPC the player is talking to, which actions are told about.
---@field rule { name: string, rules: rpf.targets.Rules? }? The interaction it was opened through, whose reach every pick checks again: its rules are filled in once it is registered.

---Opens a conversation with a player: the tree's start node, as a menu.
---While they have a menu open, this conversation's or another's, it is
---`busy`, and the one on their screen goes on.
---@param handle any The player's engine handle.
---@param slug any The tree's slug.
---@param opts rpf.dialogs.OpenOptions? What it was opened from.
---@return boolean? ok True once shown.
---@return string? err `not_found` for a slug this server has no tree of, `not_logged_in` for a player not logged in here, or what `rpf.ui`'s menu says (`busy`, `unsupported`, `inactive`, …).
function dialogs.open(handle, slug, opts)
  if type(slug) ~= "string" then
    return nil, "not_found"
  end
  local dialog = rpf.config.dialog(slug)
  if not dialog then
    return nil, "not_found"
  end
  local player = rpf.players.get(handle)
  if not player or not player.player_id or player.state == "dropping" then
    return nil, "not_logged_in"
  end
  opts = type(opts) == "table" and opts or {}
  ---@type rpf.dialogs.Conversation
  local conversation = {
    slug = slug,
    node = dialog.start,
    shown = {},
    target = opts.target,
    rule = opts.rule,
  }
  return show(handle, conversation)
end

---The dialog a record of a world type talks with: the slug its `dialog`
---field names, if the type has one and this server has that tree.
---@param target rpf.targets.Target? The resolved target.
---@return string? slug The tree's slug.
local function slug_of(target)
  local def = target and target.type and rpf.addons.definition(target.type)
  local field = type(def) == "table" and type(def.world) == "table" and def.world.dialog
  local record = target and target.record
  local fields = type(record) == "table" and record.fields
  local slug = type(field) == "string" and type(fields) == "table" and fields[field] or nil
  if type(slug) == "string" and rpf.config.dialog(slug) then
    return slug
  end
  return nil
end

---Registers Talk for each of an addon's world types with a `dialog` role,
---in the addon's context, so it goes when that activation stops.
---@param namespace string The addon, just started.
local function register_talk(namespace)
  local context = rpf.addons.context_of(namespace)
  if not context then
    return
  end
  for i, type_name in ipairs(rpf.addons.type_names(namespace)) do
    local def = rpf.addons.definition(type_name)
    if type(def) == "table" and type(def.world) == "table" and def.world.dialog ~= nil then
      local name = namespace .. ".rpf_talk" .. i
      ---@type { name: string, rules: rpf.targets.Rules? }
      local rule = { name = name }
      local ran, ok, err = rpf.addons.run(context, function()
        return rpf.interactions.register_reserved(name, function(player, _, target)
          local slug = slug_of(target)
          if not slug then
            return false, dialogs.MESSAGES.unavailable
          end
          local shown, why = dialogs.open(player.handle, slug, { target = target, rule = rule })
          if not shown then
            return false, why
          end
          return true
        end, {
          target = type_name,
          label = dialogs.TALK,
          check = function(_, target)
            return slug_of(target) ~= nil
          end,
        })
      end)
      if ran and ok then
        rule.rules = rpf.interactions.rules_of(name)
      else
        log("error", "could not offer Talk on " .. type_name .. ": " .. tostring(err or ok))
      end
    end
  end
end

---Starts the module on the game server: Talk follows the addons as they
---start, and a player who leaves takes their conversation with them.
---@param p rpf.ServerPlatform The platform.
function dialogs.start(p)
  platform = p
  rpf.events.on("addons.state", function(change)
    if change.state == "active" then
      register_talk(change.namespace)
    end
  end)
  rpf.events.on("players.dropping", function(player)
    if player.player_id then
      talking[player.player_id] = nil
    end
  end)
end

rpf.dialogs = dialogs
return dialogs
