---@meta

-- The parts of the platform interface both sides implement. An adapter never
-- implements these alone: see `rpf.ServerPlatform` and `rpf.ClientPlatform`.
-- This file is a definition for the language server and is never loaded.

---Which engine is running, for `Hello`, logs and server owners' scripts.
---
---The core never branches on it. An engine difference is a platform function,
---so a comparison against `engine` inside the core is a missing function.
---@class rpf.platform.Engine
---@field engine string `"fivem"`, `"gmod"` or `"mock"`. A free string, so a new adapter needs no portal release.

---Outbound HTTP, through whatever the engine offers. The core calls this and
---never learns which implementation ran.
---@class rpf.platform.Http
local Http = {}

---Sends one HTTP request and calls back once with the result.
---@param method string `"GET"`, `"POST"` and so on.
---@param url string The absolute url.
---@param headers table<string, string> Request headers. Never logged by the core, because they may carry a credential.
---@param body string? The request body, already encoded, or nil for none.
---@param callback fun(status: integer, body: string, headers: table<string, string>) Called exactly once. `status` is 0 when no response arrived at all.
function Http.http_request(method, url, headers, body, callback) end

---The clock. Every timer in the core goes through it, so the mock can run
---retry and backoff tests instantly and deterministically.
---@class rpf.platform.Clock
local Clock = {}

---The current wall-clock time. Wall clock rather than monotonic, because it
---stamps `sent_at` and ages outbox entries across a restart.
---@return number ms Milliseconds since the Unix epoch.
function Clock.now() end

---Runs a callback once, later. There is no cancel: the core ignores a timer
---it no longer wants, so the platform does not have to track handles.
---@param delay_ms number How long to wait, in milliseconds. May be 0.
---@param callback fun() What to run. The platform runs it outside the caller's stack.
function Clock.after(delay_ms, callback) end

---Persistence that survives a process restart: the outbox and the config
---version on the server, the remember token on the client.
---@class rpf.platform.Storage
local Storage = {}

---Reads a stored value.
---@param key string A key the core chose, always prefixed `rpf.`.
---@return string? value The value last stored, or nil if none.
function Storage.kv_get(key) end

---Stores a value, replacing any earlier one. Strings only, so every engine
---stores the same bytes and the core owns the encoding.
---
---It must be **atomic per key and durable when it returns**: after a crash
---the key holds the old value or the new one, never part of either, and a
---value `kv_set` returned from is not lost. The outbox's at-most-once rule
---for portal requests rests on this (see `lua/core/README.md`). On FiveM that
---means the synchronous KVP setter, not the no-sync one. Values reach a little
---over 1 MiB, the portal's frame limit plus a header, and about 9 MiB in
---total under the default outbox bounds.
---@param key string A key the core chose, always prefixed `rpf.`.
---@param value string? The value, or nil to delete it.
function Storage.kv_set(key, value) end

---Logging, through the engine's console or log file.
---@class rpf.platform.Log
local Log = {}

---Writes one log line. The core never passes a secret here: API keys,
---tickets and nonces are redacted first.
---@param level "debug"|"info"|"warn"|"error" How much it matters.
---@param message string The line, without a trailing newline.
function Log.log(level, message) end
