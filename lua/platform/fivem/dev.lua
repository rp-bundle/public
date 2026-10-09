---Development-only console commands for the real-game smoke test (layer 5 in
---`docs/testing.md`). The release leaves this file out: only
---`dev/fivem-resources --dev` copies it and names it in the manifest, after
---`server.lua`. Even then every command does nothing unless
---`set rpf_dev "true"` is in `server.cfg`, and none runs but from the server
---console.
---
--- - `rpf_dev_kv_bound [write|read]` checks resource KVP at the core's bounds:
---   one value of the frame limit plus an entry header, and nine of them at
---   once (the outbox's total plus the replies' share), each read back byte
---   for byte. `write` leaves them stored, and `read` checks them after the
---   server has been restarted or killed, which is what shows `kv_set` is
---   durable when it returns.
--- - `rpf_dev_bench <url> [frames] [bytes]` sends frames from this Lua state
---   through `rpf-ws` to a websocket echo server (`npm run echo` in
---   `ws-shim/`) and back, and prints the round trips a second: the shim
---   benchmark (`ws-shim/bench/`) under FXServer's own Lua, JS and
---   marshalling rather than emulated ones.
--- - `rpf_dev_status` prints the connection's state and the players the core
---   knows.
---@class rpf.fivem.dev
local dev = {}

local rpf = rpf
local core = rpf
local fivem = rpf.fivem
local shared = fivem.shared

---The size of the largest outbox entry: the core's frame limit plus room
---for the entry's header (about 150 bytes), as Gmod's check uses.
dev.KV_VALUE_BYTES = 1024 * 1024 + 256

---How many of them must fit at once: `max_bytes` (8 MiB) plus the replies'
---share, about 9 MiB (`lua/core/README.md`, The outbox).
dev.KV_VALUES = 9

---Frames the benchmark sends before it yields a tick, so the socket and the
---echoes run between FiveM's ticks. An idle server ticks every 50 ms, so this
---must be large enough that the ticks do not set the rate: 500 a tick capped
---the run at 10,000 a second, under what the boundary does, and 2,000 caps it
---at 40,000.
dev.BENCH_BATCH = 2000

---How long a benchmark may run before it is given up and its socket closed,
---so an echo server that accepts and never answers cannot leave every later
---run refused. A run of 100,000 frames takes about ten seconds.
dev.BENCH_TIMEOUT_MS = 60000

---Whether the dev commands may run, saying why not if they may not.
---@param source integer FiveM's `source` for the command: 0 for the server console.
---@return boolean allowed True from the console with `rpf_dev` set to `true`.
function dev.allowed(source)
  if source ~= 0 then
    return false
  end
  if GetConvar("rpf_dev", "false") ~= "true" then
    print('rpf: set rpf_dev "true" to use the rpf_dev_* commands')
    return false
  end
  return true
end

---Writes the outbox's bound into resource KVP through the adapter's own
---`kv_set`, reads it back through its `kv_get`, and deletes it again.
---@param mode string? `"write"` stores the values and stops, `"read"` checks values an earlier `"write"` stored; nil does both.
---@return boolean held Whether every value came back byte for byte, or were written.
function dev.kv_bound(mode)
  local one = string.rep("x", dev.KV_VALUE_BYTES)
  local held = true
  local started = GetGameTimer()
  if mode ~= "read" then
    for i = 1, dev.KV_VALUES do
      shared.kv_set("rpf.dev.bound." .. i, one .. i)
    end
  end
  if mode == "write" then
    print(
      ("rpf: kv bound written: %d values of %d bytes each; restart or kill the server, then rpf_dev_kv_bound read"):format(
        dev.KV_VALUES,
        #one + 1
      )
    )
    return true
  end
  for i = 1, dev.KV_VALUES do
    local back = shared.kv_get("rpf.dev.bound." .. i)
    if back ~= one .. i then
      held = false
      print("rpf: value " .. i .. " came back " .. tostring(back and #back) .. " bytes long")
    end
    shared.kv_set("rpf.dev.bound." .. i, nil)
  end
  local took = GetGameTimer() - started
  if held then
    print(("rpf: kv bound held: %d values of %d bytes each, in %d ms"):format(dev.KV_VALUES, #one + 1, took))
  else
    print("rpf: kv bound FAILED")
  end
  return held
end

---The benchmark's transport: a second socket through the same shim,
---apart from the core's, so a run never touches the portal connection.
dev.transport = fivem.ws.new(exports["rpf-ws"] --[[@as rpf.fivem.WsShim]], shared.after, shared.logger(true))

---The benchmark running now, if one is, so a second is refused rather than
---sharing its socket, and a deadline knows whether its run is still going.
---@type table?
local running = nil

---Runs the benchmark: `frames` frames of about `bytes` bytes, Lua → shim →
---echo → shim → Lua, counted when the last echo arrives.
---@param url string? The echo server's `ws://` url.
---@param frames integer? How many frames to send, at least one.
---@param bytes integer? Each frame's size in bytes, at least 40.
function dev.bench(url, frames, bytes)
  if type(url) ~= "string" or not frames or frames < 1 or not bytes or bytes < 40 then
    print("rpf: usage: rpf_dev_bench <ws://echo url> [frames >= 1] [bytes >= 40]")
    return
  end
  if running then
    print("rpf: a benchmark is already running")
    return
  end
  local run = {}
  running = run
  frames, bytes = math.floor(frames), math.floor(bytes)
  local frame = '{"type":"state_changed","padding":"' .. string.rep("x", math.max(0, bytes - 40)) .. '"}'
  local transport = dev.transport
  local received, started = 0, 0
  transport.connect(url, {
    open = function()
      started = GetGameTimer()
      Citizen.CreateThread(function()
        local sent = 0
        while sent < frames do
          for _ = 1, math.min(dev.BENCH_BATCH, frames - sent) do
            if not transport.send(frame) then
              print("rpf: bench: send refused after " .. sent .. " frames")
              transport.disconnect()
              return
            end
            sent = sent + 1
          end
          Citizen.Wait(0)
        end
      end)
    end,
    message = function()
      received = received + 1
      if received == frames then
        local seconds = math.max(1, GetGameTimer() - started) / 1000
        print(
          ("rpf: bench: %d frames of %d bytes, Lua → shim → echo → shim → Lua, in %.2f s: %d round trips/s, %.1f µs each"):format(
            frames,
            #frame,
            seconds,
            math.floor(frames / seconds + 0.5),
            seconds / frames * 1e6
          )
        )
        transport.disconnect()
      end
    end,
    close = function(reason)
      running = nil
      if received < frames then
        print("rpf: bench: " .. reason .. " after " .. received .. " of " .. frames .. " echoes")
      end
    end,
  })
  shared.after(dev.BENCH_TIMEOUT_MS, function()
    if running == run then
      print(("rpf: bench: no result after %d s; closing"):format(math.floor(dev.BENCH_TIMEOUT_MS / 1000)))
      transport.disconnect()
    end
  end)
end

---Prints the connection's state and every player the core knows.
function dev.status()
  print("rpf: connection " .. tostring(core.connection and core.connection.state))
  for _, view in ipairs(core.players.list()) do
    print("rpf: player " .. tostring(view.handle) .. " " .. view.state .. " " .. tostring(view.player_id))
  end
end

-- The benchmark socket's events. The core's transport ignores an id it did
-- not open, and this one ignores the core's, so both hear every event. The
-- shim outlives this resource, so a run cut short by a restart closes its
-- socket, as `server.lua` does the core's.
AddEventHandler("rpf-ws:open", function(id) dev.transport.opened(id) end)
AddEventHandler("rpf-ws:message", function(id, text) dev.transport.received(id, text) end)
AddEventHandler("rpf-ws:close", function(id, code, reason) dev.transport.closed(id, code, reason) end)
AddEventHandler("onResourceStop", function(name)
  if name == GetCurrentResourceName() then dev.transport.stop() end
end)

RegisterCommand("rpf_dev_kv_bound", function(source, args)
  if dev.allowed(source) then dev.kv_bound(args[1]) end
end, true)
RegisterCommand("rpf_dev_bench", function(source, args)
  if dev.allowed(source) then dev.bench(args[1], tonumber(args[2]) or 20000, tonumber(args[3]) or 512) end
end, true)
RegisterCommand("rpf_dev_status", function(source)
  if dev.allowed(source) then dev.status() end
end, true)

return dev
