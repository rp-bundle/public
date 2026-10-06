---Runs the portal's staff commands (`apply_command`), each by the module that
---owns what it acts on.
---
---The connection takes one handler per request type, and every command
---arrives as the one type, so this module is that handler: it looks the
---command's name up among the handlers modules registered with
---`commands.register` and answers the portal with what the handler reports.
---Adding a command is then a decoder entry in `rpf.protocol` and a
---`register` call in the module that owns it, and no two modules ever
---compete for `apply_command`.
---
---The connection already holds every command to the request rules (D1, #71):
---a handler runs at most once per request id, a resend gets the stored
---reply, and a handler that throws or never answers is reported `unknown`.
---What is left here is the honest answer for the cases a handler cannot
---give one: a command no module registered is `failed`, because nothing ran.
---@class rpf.commands
---@field handlers table<string, rpf.CommandHandler> The registered handlers, by command name (`kick`).
local commands = {}

local rpf = rpf

commands.handlers = {}

---A command handler: does what `command` asks, at once, and says how it
---went. Returning `false` means nothing changed, and `reason` says why, for
---the staff member who asked. Throwing is reported to the portal as
---`unknown`, because the handler may have done part of the work first.
---@alias rpf.CommandHandler fun(command: table): boolean, string?

---Registers the handler for one command, replacing any earlier one for the
---same name.
---@param name string The command's wire name, like `kick`.
---@param handler rpf.CommandHandler The handler.
function commands.register(name, handler)
  commands.handlers[name] = handler
end

---Answers one `apply_command` from the portal: runs the command's handler
---and replies `command_applied` with its outcome.
---@param frame rpf.Frame The request, decoded.
---@param reply fun(tag: string, fields: table?) Sends the one reply.
function commands.apply(frame, reply)
  local command = frame.command
  local handler = commands.handlers[command.command]
  if not handler then
    reply("command_applied", {
      outcome = { outcome = "failed", reason = "this server has no handler for " .. command.command },
    })
    return
  end
  local applied, reason = handler(command)
  if applied then
    reply("command_applied", { outcome = { outcome = "applied" } })
  else
    reply("command_applied", {
      outcome = { outcome = "failed", reason = type(reason) == "string" and reason or "it was not applied" },
    })
  end
end

---Takes the portal's commands on a connection. Called by `rpf.start_server`.
---@param connection rpf.Client The connection to the portal.
function commands.serve(connection)
  connection:handle("apply_command", commands.apply)
end

rpf.commands = commands
return commands
