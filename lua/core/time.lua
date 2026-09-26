---Reading RFC 3339 timestamps, computed rather than delegated.
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
local time = {}

local rpf = rpf

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
