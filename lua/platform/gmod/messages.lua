---Messages between the game server and its players' clients, over Gmod's
---`net` library: the platform's `to_client` / `on_client` on the server and
---`to_server` / `on_server` on the client.
---
---The core's payloads are strings it has already encoded, and this carries
---them byte for byte. One `net` message holds at most 64 KiB, and the list of
---characters the server sends may be that long by itself
---(`handoff.MAX_LIST_PAYLOAD`), so a payload travels as one or more parts,
---each its own `net` message under the payload's name:
---
---```
---part index (16 bits), part count (16 bits), byte length (32 bits), bytes
---```
---
---`net` delivers one sender's reliable messages in order, so the parts of a
---payload arrive together and in order, and the receiver joins them.
---
---**Every client is hostile.** The server takes a payload from a client only
---in a single part: nothing the core sends from a client comes near the
---limit, and a client that could send many parts could make the server hold
---them. A part whose header does not add up is dropped whole. What the
---server hands the core is still hostile input, which the core decodes as
---such; the server supplies the sender, so a client never names itself.
---@class rpf.gmod.Messages
---@field PART_BYTES integer The most bytes one part carries, under `net`'s 64 KiB with room for the header.
---@field MAX_PARTS_FROM_SERVER integer The most parts a client joins into one payload, so even its own server cannot make it hold more than a couple of megabytes.
local messages = {}

messages.PART_BYTES = 60000
messages.MAX_PARTS_FROM_SERVER = 32

---Names already pooled with `util.AddNetworkString` in this state.
---@type table<string, true>
local pooled = {}

---Payloads being joined, by sender and name.
---@type table<any, table<string, { parts: integer, got: string[] }>>
local partial = setmetatable({}, { __mode = "k" })

---Pools a message name on the server, once. `net` refuses to send a name the
---server never pooled, and a client cannot send one either.
---@param name string The message name.
function messages.pool(name)
  if not pooled[name] then
    util.AddNetworkString(name)
    pooled[name] = true
  end
end

---Writes a payload as parts, calling `send` after each to dispatch it.
---@param name string The message name.
---@param payload string The payload.
---@param send fun() Sends the message `net.Start` began.
local function write(name, payload, send)
  local size = messages.PART_BYTES
  local parts = math.max(1, math.ceil(#payload / size))
  for index = 1, parts do
    local chunk = payload:sub((index - 1) * size + 1, index * size)
    net.Start(name)
    net.WriteUInt(index, 16)
    net.WriteUInt(parts, 16)
    net.WriteUInt(#chunk, 32)
    if #chunk > 0 then
      net.WriteData(chunk, #chunk)
    end
    send()
  end
end

---Reads one part of the message being received, and returns the payload once
---its last part is in.
---@param sender any Who sent it: a player on the server, `true` on the client.
---@param name string The message name.
---@param max_parts integer The most parts this side joins.
---@return string? payload The whole payload, or nil while parts are missing or if this one was dropped.
local function read(sender, name, max_parts)
  local index = net.ReadUInt(16)
  local parts = net.ReadUInt(16)
  local size = net.ReadUInt(32)
  local left = net.BytesLeft() or 0
  local by_name = partial[sender]
  if index < 1 or parts < 1 or parts > max_parts or index > parts or size > left then
    if by_name then
      by_name[name] = nil
    end
    return nil
  end
  local chunk = size > 0 and net.ReadData(size) or ""
  if parts == 1 then
    return chunk
  end
  if not by_name then
    by_name = {}
    partial[sender] = by_name
  end
  local pending = by_name[name]
  if index == 1 then
    pending = { parts = parts, got = {} }
    by_name[name] = pending
  elseif not pending or pending.parts ~= parts or #pending.got ~= index - 1 then
    by_name[name] = nil
    return nil
  end
  pending.got[index] = chunk
  if index < parts then
    return nil
  end
  by_name[name] = nil
  return table.concat(pending.got)
end

---Sends a payload to one player's client.
---@param player Player The recipient.
---@param name string The message name, namespaced `rpf:`.
---@param payload string The payload.
function messages.to_client(player, name, payload)
  if not IsValid(player) then
    return
  end
  messages.pool(name)
  write(name, payload, function()
    net.Send(player)
  end)
end

---Registers the server's handler for one name from clients. Only a payload
---in a single part reaches it (see the module docs).
---@param name string The message name.
---@param handler fun(player: Player, payload: string) Called for each message.
function messages.on_client(name, handler)
  messages.pool(name)
  net.Receive(name, function(_, player)
    local payload = read(player, name, 1)
    if payload and IsValid(player) then
      handler(player, payload)
    end
  end)
end

---Sends a payload from this client to the game server.
---@param name string The message name.
---@param payload string The payload.
function messages.to_server(name, payload)
  write(name, payload, function()
    net.SendToServer()
  end)
end

---Registers the client's handler for one name from the server.
---@param name string The message name.
---@param handler fun(payload: string) Called for each whole payload.
function messages.on_server(name, handler)
  net.Receive(name, function()
    local payload = read(true, name, messages.MAX_PARTS_FROM_SERVER)
    if payload then
      handler(payload)
    end
  end)
end

return messages
