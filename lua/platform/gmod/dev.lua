---Development-only console commands for the real-game smoke test (layer 5 in
---`docs/testing.md`). The release leaves this file out, and `server.lua`
---loads it only if it is there. Even then every command does nothing unless
---`rpf_dev 1` is set.
---
--- - `rpf_dev_client_ready <name>` speaks for a bot's client: it hands the
---   core `rpf:client_ready` from that bot, as its client would, so a bot's
---   join reaches the portal as `BeginJoin` with the identifiers the adapter
---   reports. Bots run no client Lua, so without this a server with no human
---   on it could not show the join path at all.
--- - `rpf_dev_kv_bound` checks the store at the core's bounds: one value of
---   the frame limit plus an entry header, and nine of them at once (the
---   outbox's total plus the replies' share), each read back byte for byte.
--- - `rpf_dev_status` prints the connection's state and the players the core
---   knows.
---@param core rpf The core's internal table.
---@param platform rpf.ServerPlatform The server platform, before the core starts.
return function(core, platform)
  local enabled = CreateConVar("rpf_dev", "0", { FCVAR_DONTRECORD }, "Enables the rpf_dev_* commands. Development only.")

  ---Handlers the core registered for client messages, by name.
  ---@type table<string, fun(player: Player, payload: string)>
  local handlers = {}
  local on_client = platform.on_client
  platform.on_client = function(name, handler)
    handlers[name] = handler
    on_client(name, handler)
  end

  ---Whether the dev commands may run, saying why not if they may not.
  ---@return boolean allowed True with `rpf_dev 1`.
  local function allowed()
    if not enabled:GetBool() then
      print("rpf: set rpf_dev 1 to use the rpf_dev_* commands")
      return false
    end
    return true
  end

  concommand.Add("rpf_dev_client_ready", function(caller, _, args)
    if IsValid(caller) or not allowed() then
      return
    end
    for _, ply in ipairs(player.GetAll()) do
      if ply:Nick() == args[1] then
        handlers[core.handoff.CLIENT_READY](ply, core.handoff.encode(core.handoff.CLIENT_READY))
        print("rpf: sent client_ready for " .. ply:Nick() .. " (" .. tostring(ply:SteamID64()) .. ")")
        return
      end
    end
    print("rpf: no player named " .. tostring(args[1]))
  end)

  concommand.Add("rpf_dev_kv_bound", function(caller)
    if IsValid(caller) or not allowed() then
      return
    end
    local one = string.rep("x", 1024 * 1024 + 256)
    local ok = true
    for i = 1, 9 do
      platform.kv_set("rpf.dev.bound." .. i, one .. i)
    end
    for i = 1, 9 do
      local back = platform.kv_get("rpf.dev.bound." .. i)
      if back ~= one .. i then
        ok = false
        print("rpf: value " .. i .. " came back " .. tostring(back and #back) .. " bytes long")
      end
      platform.kv_set("rpf.dev.bound." .. i, nil)
    end
    print("rpf: kv bound " .. (ok and "held: 9 values of " .. #one .. " bytes each" or "FAILED"))
  end)

  concommand.Add("rpf_dev_status", function(caller)
    if IsValid(caller) or not allowed() then
      return
    end
    print("rpf: connection " .. tostring(core.connection and core.connection.state))
    for _, view in ipairs(core.players.list()) do
      print("rpf: player " .. tostring(view.handle) .. " " .. view.state .. " " .. tostring(view.player_id))
    end
  end)
end
