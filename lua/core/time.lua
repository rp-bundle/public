---The clock and timers scripts use, and reading RFC 3339 timestamps.
---
---**Timers (J3).** `now`, `after`, `every` and `cancel` run on the
---platform's clock (`platform.now`, `platform.after`), so a script's timer
---behaves the same on every engine and runs instantly in the tests. A
---timer an addon starts while its code runs belongs to it
---(`rpf.addons.own`) and is cancelled when it stops, so an addon that starts
---`every` in its `start` handler gets exactly one, however often it is
---restarted. Its callback runs in the addon's context, under `pcall`: one
---that throws is logged, and an `every` keeps going. Ids are strings, so
---they cross a FiveM export unchanged. `elapsed` (J6) is how a record keeps
---time across a restart, which ends every timer.
---
---The portal writes every time as RFC 3339, and both halves of the core need
---to read them: the server to turn a join nonce's `expires_at` into a
---lifetime, the client to schedule an API-token refresh. The standard
---library's clock is off limits (it reads the host's time zone, and Gmod and
---FiveM leave different parts of it in), so this is plain arithmetic after
---Howard Hinnant's civil-date algorithms, exact for every date the portal
---can send. Writing one is `rpf.protocol.timestamp`, which only the server
---needs.
---@class rpf.time
---@field MIN_INTERVAL_MS integer The shortest period `every` takes, so a mistake cannot spin the server's thread.
---@field MAX_DELAY_MS integer The longest delay or period a timer takes: about 24.8 days, which every engine's timers hold.
local time = {}

local rpf = rpf

time.MIN_INTERVAL_MS = 10
time.MAX_DELAY_MS = 2147483647

---What timers need of a platform: either side's has it.
---@class rpf.time.Clock
---@field now fun(): number Wall-clock milliseconds.
---@field after fun(delay_ms: number, callback: fun()) Runs a callback once, later.
---@field log fun(level: string, message: string) Logs a line.

---The platform whose clock timers run on, once bound.
---@type rpf.time.Clock?
local clock = nil

---Live timers by id; a cancelled one is removed, and its scheduled run then
---does nothing.
---@type table<string, { fn: any, period: number?, context: table?, disown: fun() }>
local timers = {}

---How many timers have been made, for their ids.
local made = 0

---Binds the clock timers run on. Called when the public API is published,
---which on Gmod is as the adapter loads, before the core starts, so addons
---loading then can already set timers.
---@param platform rpf.time.Clock The platform.
function time.bind(platform)
  clock = platform
end

---The wall clock, in milliseconds since the Unix epoch.
---@return number? now Nil before a platform is bound.
function time.now()
  return clock and clock.now()
end

---How much time has passed since a moment a record stored, for keeping
---time across restarts (J6). Timers end with the process; a timestamp in a
---record's fields does not, so a timed record keeps the moment it last
---counted and works out what passed from it.
---
---`max_ms` bounds the catch-up: after an outage, a restart or a long time
---unheld, at most that much is counted, so a plant does not grow a week in
---one tick, and what a server does with it stays bounded. A clock that
---stepped back counts as no time passing, never as negative time. Store
---`now` (or `now` less what was not used) as the new moment.
---@param since any The moment last counted, milliseconds since the Unix epoch.
---@param max_ms any? The most to count, a whole number of milliseconds; no bound if nil.
---@return number? elapsed Milliseconds passed, from 0 to `max_ms`.
---@return number|string now The clock it was measured on, or why not: `invalid` for a moment or bound that is not a whole number of milliseconds (a negative bound included), `unavailable` before a platform is bound.
function time.elapsed(since, max_ms)
  local now = time.now()
  if not now then
    return nil, "unavailable"
  end
  if type(since) ~= "number" or since ~= math.floor(since) then
    return nil, "invalid"
  end
  if max_ms ~= nil and (type(max_ms) ~= "number" or max_ms ~= math.floor(max_ms) or max_ms < 0) then
    return nil, "invalid"
  end
  local elapsed = math.max(0, now - since)
  if max_ms and elapsed > max_ms then
    elapsed = max_ms
  end
  return elapsed, now
end

---Whether a delay or period is one a timer takes.
---@param ms any The value.
---@param least number The smallest allowed.
---@return boolean ok True if it is a whole number from `least` to `MAX_DELAY_MS`.
local function in_range(ms, least)
  return type(ms) == "number" and ms == math.floor(ms) and ms >= least and ms <= time.MAX_DELAY_MS
end

---Runs a timer that came due, if it is still live, and schedules the next
---run of an `every`.
---@param id string The timer.
local function fire(id)
  local entry, c = timers[id], clock
  if not entry or not c then
    return
  end
  if entry.period then
    c.after(entry.period, function()
      fire(id)
    end)
  else
    timers[id] = nil
    entry.disown()
  end
  local ok, err
  if rpf.addons then
    ok, err = rpf.addons.run(entry.context, entry.fn)
  else
    ok, err = pcall(entry.fn)
  end
  if not ok then
    c.log("error", "rpf: a timer failed: " .. tostring(err))
  end
end

---Makes a timer.
---@param ms any The delay, or the period.
---@param fn any What to run.
---@param period boolean Whether it repeats.
---@return string? id The timer's id, for `cancel`.
---@return string? err Why not.
local function start(ms, fn, period)
  local c = clock
  if not c then
    return nil, "unavailable"
  end
  if not in_range(ms, period and time.MIN_INTERVAL_MS or 0) or not rpf.callable(fn) then
    return nil, "invalid"
  end
  if rpf.addons and rpf.addons.stale() then
    return nil, "inactive"
  end
  made = made + 1
  local id = "rpf-timer-" .. made
  local disown = function() end
  if rpf.addons then
    disown = rpf.addons.own(function()
      timers[id] = nil
    end)
  end
  timers[id] = {
    fn = fn,
    period = period and ms or nil,
    context = rpf.addons and rpf.addons.context() or nil,
    disown = disown,
  }
  c.after(ms, function()
    fire(id)
  end)
  return id
end

---Runs a function once, after a delay.
---@param delay_ms any Milliseconds, a whole number from 0 to `MAX_DELAY_MS`.
---@param fn any The function, or a FiveM function reference.
---@return string? id The timer, for `cancel`.
---@return string? err `invalid` for a delay or function that is not one, `unavailable` before a platform is bound, `inactive` from code of an addon activation that has ended.
function time.after(delay_ms, fn)
  return start(delay_ms, fn, false)
end

---Runs a function every period, the first time one period from now, until
---cancelled (or its addon stops).
---@param period_ms any Milliseconds, a whole number from `MIN_INTERVAL_MS` to `MAX_DELAY_MS`.
---@param fn any The function, or a FiveM function reference.
---@return string? id The timer, for `cancel`.
---@return string? err `invalid` or `unavailable`, as for `after`.
function time.every(period_ms, fn)
  return start(period_ms, fn, true)
end

---Cancels a timer. Cancelling one that has run or was cancelled is harmless.
---@param id any The timer's id.
---@return boolean cancelled True if it was live.
function time.cancel(id)
  local entry = type(id) == "string" and timers[id] or nil
  if not entry then
    return false
  end
  timers[id] = nil
  entry.disown()
  return true
end

---Days since 1970-01-01 for a civil date, after Hinnant's `days_from_civil`.
---@param year integer The year.
---@param month integer 1 to 12.
---@param day integer 1 to 31.
---@return integer days The day number, negative before 1970.
local function days_from_civil(year, month, day)
  if month <= 2 then
    year = year - 1
  end
  local era = math.floor(year / 400)
  local yoe = year - era * 400
  local mp = month > 2 and month - 3 or month + 9
  local doy = math.floor((153 * mp + 2) / 5) + day - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

---Reads an RFC 3339 timestamp with a zone into milliseconds since the epoch.
---A fraction is kept to the millisecond and the rest dropped. Anything else
---is refused rather than guessed at, because the value comes over the wire.
---@param text any The timestamp, like `2026-01-01T00:02:00.5Z` or `…+01:00`.
---@return number? ms Milliseconds since the Unix epoch, or nil if it is not a timestamp.
function time.parse(text)
  if type(text) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, s, rest = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt](%d%d):(%d%d):(%d%d)(.*)$")
  if not y then
    return nil
  end
  local year, month, day = tonumber(y), tonumber(mo), tonumber(d)
  local hour, minute, second = tonumber(h), tonumber(mi), tonumber(s)
  ---@cast year integer
  ---@cast month integer
  ---@cast day integer
  ---@cast hour integer
  ---@cast minute integer
  ---@cast second integer
  if month < 1 or month > 12 or day < 1 or hour > 23 or minute > 59 or second > 60 then
    return nil
  end
  -- The day must exist in its month: the difference to the next month's
  -- first day is the month's length.
  local next_year, next_month = year, month + 1
  if next_month > 12 then
    next_year, next_month = year + 1, 1
  end
  if day > days_from_civil(next_year, next_month, 1) - days_from_civil(year, month, 1) then
    return nil
  end
  local millis = 0
  local fraction, after = rest:match("^%.(%d+)(.*)$")
  if fraction then
    millis = tonumber((fraction .. "00"):sub(1, 3)) or 0
    rest = after
  end
  local offset
  if rest == "Z" or rest == "z" then
    offset = 0
  else
    local sign, oh, om = rest:match("^([-+])(%d%d):(%d%d)$")
    if not sign then
      return nil
    end
    offset = (tonumber(oh) * 60 + tonumber(om)) * 60 * 1000
    if sign == "-" then
      offset = -offset
    end
  end
  local days = days_from_civil(year, month, day)
  local ms = ((days * 24 + hour) * 60 + minute) * 60 * 1000 + second * 1000 + millis
  return ms - offset
end

rpf.time = time
return time
