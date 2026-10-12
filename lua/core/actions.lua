---Actions (L1, #371): what an addon can be asked to do by a dialog choice
---staff wired up in the panel.
---
---The portal never sends code (Cfx.re forbids remote code loading), so a
---choice cannot say *how* to start a delivery route or open a locker. It
---names an action an installed addon declared, and fills in the action's
---parameters as data. The addon declares each action in its manifest
---(`actions`, with `title`, `help` and `params`, the parameters being field
---definitions like a type's fields) and registers its handler here, under
---the same name, while it runs:
---
---```lua
---rpf.api.actions.register("rpf_delivery.start_route", function(player, params, context)
---  if busy(player) then
---    return false, "You already have a route."
---  end
---  start(player, params.route)
---  return true
---end)
---```
---
---**Run** checks everything before the handler sees anything: the action is
---declared by an addon loaded here, the addon is running, a handler is
---registered, and the parameters pass the declaration's rules
---(`rpf.manifest.check_fields`, defaults filled in), since the declaration
---may have changed since staff saved the choice. Only then does the
---handler run, in its addon's context under `pcall`, with a plain copy of
---the parameters. A choice whose action cannot run is refused with a reason
---the dialog shows the player, never skipped.
---
---Nothing here throws: a call that cannot be made returns nil and a
---reason.
---@class rpf.actions
---@field MAX_MESSAGE integer The longest refusal a handler's message is shown as, in bytes; longer ones are cut.
local actions = {}

local rpf = rpf
local json = rpf.json

actions.MAX_MESSAGE = 256

---One registered handler.
---@class rpf.actions.Entry
---@field handler any The addon's function, or a FiveM function reference.
---@field namespace string Its addon.
---@field disown fun() Forgets the ownership, for a registration replaced by another.

---@type rpf.ServerPlatform?
local platform = nil

---Logs, once the platform is known.
---@param level string The level.
---@param message string What happened.
local function log(level, message)
  if platform then
    platform.log(level, "rpf.actions: " .. message)
  end
end

---Registered handlers, by full name.
---@type table<string, rpf.actions.Entry>
local handlers = {}

---What a handler is told about the choice that ran it.
---@class rpf.actions.Context
---@field dialog string? The dialog tree's slug, for a dialog choice.
---@field node string? The node the choice was on.
---@field target table? What the player was talking to, as `rpf.targets` resolved it, when the dialog was opened from a record in the world.

---Splits a full action name, `<namespace>.<name>`.
---@param name any The name.
---@return string? namespace Its addon, or nil if it is not one.
---@return string? short The name within the namespace.
local function split(name)
  if type(name) ~= "string" then
    return nil
  end
  local namespace, short = name:match("^([a-z][a-z0-9_]*)%.([a-z][a-z0-9_]*)$")
  if not namespace or #namespace > 32 or #short > 32 then
    return nil
  end
  return namespace, short
end

---An action's declaration in the manifest its addon registered here, which
---is the installed one whenever the addon runs.
---@param name any The action's full name.
---@return table? declaration `title`, `help` and `params`, or nil if no addon loaded here declares it.
function actions.declaration(name)
  local namespace, short = split(name)
  if not namespace then
    return nil
  end
  return rpf.addons.action(namespace, short --[[@as string]])
end

---Registers an addon's handler for an action its manifest declares.
---Registering a name again replaces it; one registered while the addon's
---code runs goes when it stops, as a timer does.
---@param name any `<namespace>.<name>`, under an addon loaded here, declared in its manifest's `actions`.
---@param handler any `handler(player, params, context)`, answering `true`, or `false` and a message for the player.
---@return boolean? ok True once registered.
---@return string? err `invalid` for a name or handler that is not one, `not_found` when no addon of that namespace is loaded, `forbidden` for another addon's namespace, `not_declared` for an action its manifest does not declare, `inactive` from code of an addon activation that has ended.
function actions.register(name, handler)
  local namespace = split(name)
  if not namespace or not rpf.callable(handler) then
    return nil, "invalid"
  end
  if rpf.addons.state(namespace) == nil then
    return nil, "not_found"
  end
  if not rpf.addons.may_use(name) then
    return nil, "forbidden"
  end
  if not actions.declaration(name) then
    return nil, "not_declared"
  end
  if rpf.addons.stale() then
    return nil, "inactive"
  end
  local previous = handlers[name]
  if previous then
    previous.disown()
  end
  ---@type rpf.actions.Entry
  local entry = { handler = handler, namespace = namespace, disown = function() end }
  handlers[name] = entry
  entry.disown = rpf.addons.own(function()
    if handlers[name] == entry then
      handlers[name] = nil
    end
  end)
  return true
end

---Whether an action can run now, and why not: what a dialog asks before it
---offers a choice as working, and again when the player picks it.
---@param name any The action's full name.
---@return boolean available True if it can.
---@return string? reason `not_declared` (no addon loaded here declares it: not installed, or its code is not on this server), `inactive` (its addon is loaded and not running: disabled, pending, mismatched, or stopped), `not_registered` (its addon runs and never registered a handler for it).
function actions.available(name)
  local declaration = actions.declaration(name)
  if not declaration then
    return false, "not_declared"
  end
  local namespace = split(name) --[[@as string]]
  if not rpf.addons.running(namespace) then
    return false, "inactive"
  end
  if not handlers[name] then
    return false, "not_registered"
  end
  return true
end

---Cuts a message to at most `MAX_MESSAGE` bytes without splitting a UTF-8
---character, or nil for anything that is not text the codec carries.
---@param message any The handler's second result.
---@return string? message The message to show.
local function message_of(message)
  if type(message) ~= "string" or message == "" or not json.is_utf8(message) then
    return nil
  end
  if #message <= actions.MAX_MESSAGE then
    return message
  end
  local at = actions.MAX_MESSAGE
  while at > 0 do
    local next_byte = message:byte(at + 1)
    if next_byte < 0x80 or next_byte >= 0xC0 then
      break
    end
    at = at - 1
  end
  return message:sub(1, at)
end

---Runs an action for a player, with the parameters a choice gave it.
---@param player rpf.PlayerView The player, as `rpf.players.get` gives them.
---@param name any The action's full name.
---@param params any The parameters, as the choice stores them.
---@param context rpf.actions.Context? What ran it.
---@return boolean ok True if the handler ran and answered `true`.
---@return string? reason When not: what `available` says, `invalid` (the parameters break the declaration's rules), `failed` (the handler threw, or did not answer `true` or `false`; logged), or `refused` (the handler answered `false`).
---@return string|table|nil detail For `refused`, the handler's message for the player, if it gave text; for `invalid`, the rule broken (`{ error, field, item }`).
function actions.run(player, name, params, context)
  local available, why = actions.available(name)
  if not available then
    return false, why
  end
  local entry = handlers[name]
  local declaration = actions.declaration(name) --[[@as table]]
  local checked, broken = rpf.manifest.check_fields({ fields = declaration.params or {} }, params == nil and {} or params)
  if not checked then
    return false, "invalid", broken
  end
  local given = rpf.data.plain(checked)
  local ctx = rpf.addons.context_of(entry.namespace)
  local ran, ok, message = rpf.addons.run(ctx, entry.handler, player, given, context and json.copy(context) or {})
  if not ran then
    log("error", "the action " .. name .. " failed: " .. tostring(ok))
    return false, "failed"
  end
  if ok == true then
    return true
  end
  if ok == false then
    return false, "refused", message_of(message)
  end
  log("error", "the action " .. name .. " answered neither true nor false; answering failed")
  return false, "failed"
end

---Starts the module on the game server.
---@param p rpf.ServerPlatform The platform, for the log.
function actions.start(p)
  platform = p
end

rpf.actions = actions
return actions
