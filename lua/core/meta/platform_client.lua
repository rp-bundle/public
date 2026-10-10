---@meta

-- The player client's platform interface. Separate from the server's, because
-- the two have different capabilities and different trust: the client never
-- holds the server's API key, and a player's password goes from the client to
-- the portal, not through the game server's code (a mitigation, not a
-- guarantee: the server's owner ships the client).
-- This file is a definition for the language server and is never loaded.

---Messages between this client and the game server. Payloads are strings,
---for the same reason as on the server side.
---@class rpf.platform.ToServer
local ToServer = {}

---Sends a message to the game server.
---@param name string The message name, namespaced `rpf:`.
---@param payload string The message, already encoded.
function ToServer.to_server(name, payload) end

---Registers the handler for one message name from the game server.
---@param name string The message name, namespaced `rpf:`.
---@param handler fun(payload: string) Called for each message.
function ToServer.on_server(name, handler) end

---Asks the game server something and hears its one answer: the request
---half of a request/response pair, whose other half is the server's
---`on_client_request` under the same name (J10). The platform pairs the
---answer with the request, which is all it adds to a message: on FiveM it is
---ox_lib's `lib.callback`, on Gmod a numbered `net` message. The core keeps
---its own timeout, so a platform that never answers is safe.
---@param name string The request's name, namespaced `rpf:`.
---@param payload string The request, already encoded.
---@param callback fun(reply: string?) Called at most once, with the server's answer as it sent it, or nil if the platform knows none will come. Never inside the call.
function ToServer.request_server(name, payload, callback) end

---Registers the answerer for one request name from the game server: the
---other half of the server's `request_client` (J10). On FiveM it is
---ox_lib's `lib.callback.register`.
---@param name string The request's name, namespaced `rpf:`.
---@param handler fun(payload: string, respond: fun(reply: string)) Called for each request; it calls `respond` exactly once, perhaps much later (a menu waits for the player).
function ToServer.on_server_request(name, handler) end

---The UI an addon shows a player, built by the adapter (J10): each member a
---function, or `false` where the adapter has none, which `rpf.ui` refuses
---as `unsupported`. Each takes a spec `rpf.ui` has already checked, plain
---data only, and calls `done` once, later, with what the player did. Only
---`rpf.ui` calls them: they never see an addon's options as given.
---@class rpf.ClientUi
---@field notify (fun(spec: rpf.ui.NoticeSpec, done: fun()))|false Shows a notification. `done` may be ignored.
---@field menu (fun(spec: rpf.ui.MenuSpec, done: fun(index: integer?)))|false Shows a menu: `done` with the chosen option's number, or nil when the player closed it.
---@field input (fun(spec: rpf.ui.InputSpec, done: fun(values: table?)))|false Shows an input dialog: `done` with the values by field number (text, a number, a boolean, a select's option number, nil for one left empty), or nil when cancelled.
---@field progress (fun(spec: rpf.ui.ProgressSpec, done: fun(completed: boolean)))|false Shows a progress bar: `done(true)` when it ran to its end, `done(false)` when the player cancelled or something interrupted it.

---A notification, checked.
---@class rpf.ui.NoticeSpec
---@field text string The text.
---@field title string? A title above it.
---@field kind "info"|"success"|"warning"|"error" How it looks.
---@field duration_ms integer How long it shows.

---A menu, checked.
---@class rpf.ui.MenuSpec
---@field title string Its title.
---@field options { label: string, description: string?, disabled: boolean? }[] Its options, in order.

---An input dialog, checked.
---@class rpf.ui.InputSpec
---@field title string Its title.
---@field fields rpf.ui.FieldSpec[] Its fields, in order.

---One input dialog field, checked.
---@class rpf.ui.FieldSpec
---@field name string Its name.
---@field label string Its label.
---@field kind "text"|"number"|"checkbox"|"select" What it takes.
---@field required boolean? Whether it must be filled in; a checkbox, ticked.
---@field placeholder string? Shown in an empty text or number field.
---@field min number? A number's least value, or a text's fewest bytes.
---@field max number? A number's greatest value, or a text's most bytes.
---@field default any? What it starts as: text, a number, a boolean, or a select's option number.
---@field options string[]? A select's options' labels, in order.

---A progress bar, checked.
---@class rpf.ui.ProgressSpec
---@field label string What it says.
---@field duration_ms integer How long it runs.
---@field cancel boolean Whether the player may cancel it.

---The client's UI, for addons.
---@class rpf.platform.ClientUi
---@field ui rpf.ClientUi What the adapter shows.

---Everything the player-client half of the core needs from its engine.
---`rpf.start_client` refuses a table missing any of it.
---@class rpf.ClientPlatform: rpf.platform.Engine, rpf.platform.Http, rpf.platform.Storage, rpf.platform.Clock, rpf.platform.ToServer, rpf.platform.Log, rpf.platform.Api, rpf.platform.ClientUi
