---The platform members the Gmod adapter's two sides share: the clock,
---storage, HTTP, the log, and how the public API is published.
---
---Everything here is one Gmod library call wide. The rules for each member
---are the core's (`lua/core/meta/platform_shared.lua`); what this file adds
---is only what Gmod needs to keep them:
---
--- - **The clock** has millisecond resolution. `os.time` counts whole seconds,
---   so `now` reads the wall clock through `SysTime`, Gmod's high-resolution
---   timer, from an anchor it re-takes whenever the two disagree by more than
---   `CLOCK_SLACK_MS`. A host whose clock is corrected therefore still moves
---   `now` with it, as the core's clock-step handling expects of a wall clock.
--- - **Storage** is SQLite (`sv.db` on the server, `cl.db` on the client)
---   through `sql.QueryTyped`, one row per key. One `INSERT OR REPLACE` is one
---   SQLite statement, so a key holds the old value or the new one after a
---   crash, never part of either, and the value is bound rather than quoted,
---   so a value of a megabyte never meets SQLite's limit on the length of a
---   statement's text. A failed write raises rather than returning, because
---   the core's at-most-once rule rests on a write that returned being stored.
---   `cl.db` is readable by every server's client Lua, so the only secret the
---   core keeps there is the remember token, which the portal binds to the
---   player's SteamID64 (P1).
--- - **HTTP** is `HTTP`, whose callback is made to run exactly once, with
---   status 0 when no response came. Gmod refuses requests to private
---   addresses unless the game runs with `-allowlocalhttp`, which only matters
---   for a portal on the same machine.
---@class rpf.gmod.Shared
---@field CLOCK_SLACK_MS number How far `SysTime`'s reading may drift from `os.time` before `now` re-anchors to the wall clock. More than a second, because `os.time` is only ever up to a second behind.
---@field TABLE string The SQLite table both sides keep their keys in.
local shared = {}

shared.CLOCK_SLACK_MS = 2000
shared.TABLE = "rpf_kv"

---The wall-clock time `now` last anchored to, in milliseconds.
---@type number?
local anchor_ms = nil

---`SysTime()` at that anchor, in seconds.
---@type number
local anchor_sys = 0

---The current wall-clock time, with millisecond resolution.
---@return number ms Milliseconds since the Unix epoch, a whole number.
function shared.now()
  local sys = SysTime()
  local wall = os.time() * 1000
  if anchor_ms then
    local estimate = anchor_ms + (sys - anchor_sys) * 1000
    if math.abs(estimate - wall) < shared.CLOCK_SLACK_MS then
      return math.floor(estimate)
    end
  end
  anchor_ms, anchor_sys = wall, sys
  return wall
end

---Runs a callback once, later, on a Gmod timer. A delay of 0 still runs it on
---a later tick, outside the caller's stack, as the interface requires.
---@param delay_ms number How long to wait, in milliseconds.
---@param callback fun() What to run.
function shared.after(delay_ms, callback)
  timer.Simple(math.max(delay_ms, 0) / 1000, callback)
end

---Whether the storage table has been made in this Lua state.
local table_ready = false

---Runs one statement, raising with SQLite's own error if it fails, so a
---broken store is a loud error rather than a value quietly lost.
---@param query string The statement, with `?` placeholders.
---@param ... any The values to bind.
---@return table[] rows The rows, empty for none.
local function query(query, ...)
  local rows = sql.QueryTyped(query, ...)
  if rows == false then
    error("rpf: the key-value store failed: " .. tostring(sql.LastError()), 3)
  end
  return rows or {}
end

---Makes the storage table, once per Lua state.
local function ensure_table()
  if not table_ready then
    query("CREATE TABLE IF NOT EXISTS " .. shared.TABLE .. " (k TEXT PRIMARY KEY NOT NULL, v TEXT NOT NULL)")
    table_ready = true
  end
end

---Reads a stored value.
---@param key string The key, always prefixed `rpf.`.
---@return string? value The value, or nil if none.
function shared.kv_get(key)
  ensure_table()
  local row = query("SELECT v FROM " .. shared.TABLE .. " WHERE k = ?", key)[1]
  if row == nil or row.v == nil then
    return nil
  end
  return tostring(row.v)
end

---Stores a value, or deletes it, in one statement.
---@param key string The key, always prefixed `rpf.`.
---@param value string? The value, or nil to delete it.
function shared.kv_set(key, value)
  ensure_table()
  if value == nil then
    query("DELETE FROM " .. shared.TABLE .. " WHERE k = ?", key)
  else
    query("INSERT OR REPLACE INTO " .. shared.TABLE .. " (k, v) VALUES (?, ?)", key, value)
  end
end

---Sends one HTTP request through Gmod's `HTTP`.
---
---Gmod takes the body's content type as a field of its own rather than a
---header, so a `Content-Type` header is moved there. `HTTP` refusing to queue
---the request at all is reported as status 0 on a later tick, so the
---callback never runs inside the caller.
---@param method string `"GET"`, `"POST"` and so on.
---@param url string The absolute url.
---@param headers table<string, string> Request headers.
---@param body string? The encoded body, or nil.
---@param callback fun(status: integer, body: string, headers: table<string, string>) Called exactly once.
function shared.http_request(method, url, headers, body, callback)
  local done = false
  local function finish(status, text, response_headers)
    if done then
      return
    end
    done = true
    callback(status, text, response_headers)
  end
  local sent = {}
  local content_type = nil
  for name, value in pairs(headers or {}) do
    if string.lower(name) == "content-type" then
      content_type = value
    else
      sent[name] = value
    end
  end
  local queued = HTTP({
    url = url,
    method = method,
    headers = sent,
    body = body,
    type = content_type,
    success = function(code, text, response_headers)
      finish(math.floor(tonumber(code) or 0), text or "", response_headers or {})
    end,
    failed = function()
      finish(0, "", {})
    end,
  })
  if not queued then
    timer.Simple(0, function()
      finish(0, "", {})
    end)
  end
end

---The console colour for each log level.
---@type table<string, Color>
local COLOURS = {
  debug = Color(150, 150, 150),
  info = Color(210, 210, 210),
  warn = Color(255, 200, 80),
  error = Color(255, 90, 90),
}

---Writes one line to the console, coloured by level. The core never passes a
---secret here.
---@param level "debug"|"info"|"warn"|"error" How much it matters.
---@param message string The line.
function shared.log(level, message)
  MsgC(COLOURS[level] or COLOURS.info, "[" .. tostring(level) .. "] " .. message .. "\n")
end

---Publishes the public API as the `rpf` global, which every addon in the
---shared Lua state reads. The core and this adapter keep their own reference
---to the internal table, so replacing the global takes nothing from them.
---@param api rpf.Api The public API, read-only.
function shared.expose(api)
  _G.rpf = api
end

return shared
