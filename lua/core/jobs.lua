---Characters' jobs, duty and salaries (D7): the game side of the employers,
---departments and jobs staff define in the portal (E4). The default job a
---new character starts in (E5) is given by the portal when it creates the
---character; this module only says why a character got none.
---
---**A character's job is part of the character**, a held record (C7), so it
---changes only through `records.set_job` and reaches the portal with the
---character's next report, as `employment`. Nothing here keeps a copy:
---every call reads the character from `rpf.records`, so a character this
---server does not hold has no job here, whatever the portal says.
---
---**Hiring is not staff-only.** A player can run a business (an employer
---whose owner is a player), so `set_job` is a plain script call, and
---deciding who may hire whom is the script's. What this module holds to is
---that the job is one of the server's jobs in the applied config.
---
---**A job is only as real as the config.** Staff can delete a job a
---character holds. The character keeps it, because staff may put it back
---and the portal would only have to be told twice, but while the config
---lacks it the character is treated as having no job: no rank, no duty, no
---salary. Applying a config that drops a held job logs it once, naming the
---job, and takes whoever is on duty in it off duty.
---
---**Duty is memory only.** It is never stored or reported: it is a fact
---about the character in play now, so it ends when that ends. A character
---goes on duty only while some player has it in play and its job is in the
---config, and goes off duty, with the event, when it is put away, when its
---player leaves, when the record is released or lost, when its job changes,
---and when the config drops its job.
---
---**Salaries are paid for time on duty**, one payment per pay period
---(`economy.salary_interval_minutes`, measured from going on duty), from the
---employer's payroll account (one of the server's paying accounts, #169) to
---the character's account named by `economy.salary_account`, through
---`rpf.accounts.pay`, so each is a ledger entry the portal appends once.
---The platform clock drives it (`platform.after`), so the mock runs a shift
---without waiting. Everything is read again at each payment: a job, salary
---or payroll changed mid-shift pays what the config says then, and one that
---cannot be paid is logged and skipped, with the shift going on.
---
---Events, reserved to the core, each with copies:
---`jobs.changed(character_id, job, previous)` (`{ employer, job }` or nil
---each), `jobs.duty(character_id, on_duty)` and
---`jobs.paid(character_id, amount, client_id)`.
---@class rpf.jobs
---@field INTERVAL_SETTING string The setting naming how many minutes on duty one salary payment is for.
---@field ACCOUNT_SETTING string The setting naming the character account salaries are paid into.
---@field DEFAULT_JOB_SETTING string The setting naming the default job (E5). Read only to say why a new character got none.
---@field DEFAULT_INTERVAL_MINUTES integer The pay period without a usable setting, the portal's default.
---@field MAX_INTERVAL_MINUTES integer The longest pay period the portal allows, a day.
---@field DEFAULT_ACCOUNT string The salary account without a usable setting, the portal's default: one of the default starting accounts, so every character has it.
local jobs = {}

local rpf = rpf
local json = rpf.json
local events = rpf.events
local records = rpf.records
local config = rpf.config
local accounts = rpf.accounts
local characters = rpf.characters

jobs.INTERVAL_SETTING = "economy.salary_interval_minutes"
jobs.ACCOUNT_SETTING = "economy.salary_account"
jobs.DEFAULT_JOB_SETTING = "economy.default_job"
jobs.DEFAULT_INTERVAL_MINUTES = 15
jobs.MAX_INTERVAL_MINUTES = 1440
jobs.DEFAULT_ACCOUNT = "bank"

---One character's time on duty.
---@class rpf.jobs.Duty
---@field token integer This shift's own number. A pay timer carries the shift it was set for, and one from an earlier shift finds a different token (or none) and does nothing, since `platform.after` cannot be cancelled.
---@field since number When the shift began, by the platform clock.

---Characters on duty, by id.
---@type table<string, rpf.jobs.Duty>
local duty = {}

---The last shift number handed out.
local shifts = 0

---Jobs already logged as missing from the config, by `employer/job`, so a
---config change logs each once rather than once per character or payment.
---@type table<string, true>
local warned = {}

---@type rpf.ServerPlatform?
local platform = nil

---Logs through the platform with the module's prefix.
---@param level string The level.
---@param message string The message.
local function log(level, message)
  if platform then
    platform.log(level, "rpf.jobs: " .. message)
  end
end

---Whether a value is a whole number, the way JSON carries one.
---@param value any The value.
---@return boolean whole True for a number with no fractional part.
local function is_whole(value)
  return type(value) == "number" and value == math.floor(value)
end

---A job's name for the log and a salary's description.
---@param ref rpf.JobRef The job.
---@return string name `employer/job`.
local function name_of(ref)
  return ref.employer .. "/" .. ref.job
end

---A held character's job, read from the record.
---@param character_id any The character's uuid, as a caller gave it.
---@return rpf.JobRef? ref A fresh `{ employer, job }`, or nil for none or a character not held.
local function stored_job(character_id)
  if type(character_id) ~= "string" then
    return nil
  end
  local character = records.get("character", character_id)
  local job = character and character.job
  if type(job) ~= "table" or job == json.null then
    return nil
  end
  return { employer = job.employer, job = job.job }
end

---Whether some player has a character in play now: it is held, a player
---owns it, and it is that player's selected character.
---@param character_id string The character.
---@return boolean in_play True while it is.
local function in_play(character_id)
  local character = records.get("character", character_id)
  if not character or type(character.owner) ~= "table" or character.owner.kind ~= "player" then
    return false
  end
  local selected = characters.selected(character.owner.id)
  return selected ~= nil and selected.id == character_id
end

---A character's job and its definition in the applied config.
---@param character_id string The character's uuid.
---@return rpf.JobRef? ref A copy of the job it holds, or nil for none or a character this server does not hold.
---@return rpf.ConfigJob? def A copy of the job's definition, or nil when it has none or the config no longer has it, which counts as no job.
function jobs.job_of(character_id)
  local ref = stored_job(character_id)
  if not ref then
    return nil, nil
  end
  return ref, config.job(ref.employer, ref.job)
end

-- Duty -----------------------------------------------------------------------

---Ends a character's shift, if it is on one, and announces it.
---@param character_id string The character.
local function end_shift(character_id)
  if duty[character_id] then
    duty[character_id] = nil
    events.emit("jobs.duty", character_id, false)
  end
end

---Ends every shift whose character is no longer in play: after a player
---left, or a record went. Run after `rpf.characters` has heard the same
---event, which it has, being started first.
local function sweep()
  local ids = {}
  for id in pairs(duty) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    if not in_play(id) then
      end_shift(id)
    end
  end
end

---How long one pay period is: the `economy.salary_interval_minutes`
---setting, or `DEFAULT_INTERVAL_MINUTES` for anything the portal would not
---have sent (no config yet, or not a whole number of minutes in range).
---@return number ms The period, in milliseconds.
function jobs.pay_period_ms()
  local minutes = config.setting(jobs.INTERVAL_SETTING)
  if not is_whole(minutes) or minutes < 1 or minutes > jobs.MAX_INTERVAL_MINUTES then
    minutes = jobs.DEFAULT_INTERVAL_MINUTES
  end
  return minutes * 60 * 1000
end

---The name of the character account salaries are paid into: the
---`economy.salary_account` setting, or `DEFAULT_ACCOUNT` for anything that
---is not an identifier, which is all the portal accepts there.
---@return string name The account's name.
function jobs.salary_account()
  local name = config.setting(jobs.ACCOUNT_SETTING)
  if type(name) ~= "string" or #name > 64 or not name:find("^[a-z][a-z0-9_]*$") then
    return jobs.DEFAULT_ACCOUNT
  end
  return name
end

---The held account of a character's that salaries go to.
---@param character_id string The character.
---@param name string The account's name.
---@return string? id The account's uuid, or nil if this server holds none by that name.
local function salary_account_of(character_id, name)
  for _, account in ipairs(accounts.owned_by("character", character_id)) do
    if account.name == name then
      return account.id
    end
  end
  return nil
end

local schedule

---Pays one period's salary for a shift, if it is still going, and sets the
---timer for the next. A payment that cannot be made is logged with why and
---skipped; the shift goes on, so a payroll staff fix mid-shift pays the
---next period.
---@param character_id string The character.
---@param token integer The shift the timer was set for.
local function pay(character_id, token)
  local shift = duty[character_id]
  if not shift or shift.token ~= token then
    return -- That shift ended; a new one has timers of its own.
  end
  if not in_play(character_id) then
    -- Every way out of play ends the shift, so this is only a safety net:
    -- never pay a character nobody is playing.
    end_shift(character_id)
    return
  end
  schedule(character_id, token)
  local ref, def = jobs.job_of(character_id)
  if not ref or not def then
    log("warn", "not paying a character whose job is no longer in the config")
    return
  end
  local salary = def.salary
  if salary == nil or salary == json.null then
    log("debug", "the job " .. name_of(ref) .. " is unpaid")
    return
  end
  if not is_whole(salary) or salary < 1 or salary > rpf.protocol.MAX_AMOUNT then
    log("warn", "not paying the job " .. name_of(ref) .. ": its salary is not a whole amount")
    return
  end
  local employer = config.employer(ref.employer)
  local payroll = employer and employer.payroll
  if type(payroll) ~= "string" then
    log("warn", "not paying the job " .. name_of(ref) .. ": its employer has no payroll account")
    return
  end
  local source = config.paying_account(payroll)
  if not source then
    log("warn", "not paying the job " .. name_of(ref) .. ": its payroll account " .. payroll .. " is not one of this server's paying accounts")
    return
  end
  local name = jobs.salary_account()
  local destination = salary_account_of(character_id, name)
  if not destination then
    log("warn", "not paying the job " .. name_of(ref) .. ": the character has no account named " .. name .. " held here")
    return
  end
  local client_id, err = accounts.pay(source.id, destination, salary, "Salary: " .. name_of(ref))
  if not client_id then
    log("warn", "not paying the job " .. name_of(ref) .. " (" .. tostring(err) .. ")")
    return
  end
  events.emit("jobs.paid", character_id, salary, client_id)
end

---Sets the timer for a shift's next payment, one pay period from now. The
---period is read each time, so a changed setting applies from the next one.
---@param character_id string The character.
---@param token integer The shift.
schedule = function(character_id, token)
  assert(platform).after(jobs.pay_period_ms(), function()
    pay(character_id, token)
  end)
end

---Puts a character on duty in its job, and starts paying it. Already on
---duty is a success that changes nothing, keeping the shift's pay period.
---@param character_id string The character's uuid.
---@return boolean? ok True if it is on duty.
---@return string? err `"not_in_play"` unless some player is playing it, `"no_job"` when it has none or its job is no longer in the config.
function jobs.on_duty(character_id)
  if type(character_id) ~= "string" or not in_play(character_id) then
    return nil, "not_in_play"
  end
  local _, def = jobs.job_of(character_id)
  if not def then
    return nil, "no_job"
  end
  if duty[character_id] then
    return true
  end
  shifts = shifts + 1
  duty[character_id] = { token = shifts, since = assert(platform).now() }
  schedule(character_id, shifts)
  events.emit("jobs.duty", character_id, true)
  return true
end

---Takes a character off duty. Off duty already, it changes nothing: either
---way it is off duty after the call.
---@param character_id string The character's uuid.
---@return boolean ok Always true.
function jobs.off_duty(character_id)
  if type(character_id) == "string" then
    end_shift(character_id)
  end
  return true
end

---Whether a character is on duty now.
---@param character_id string The character's uuid.
---@return boolean on_duty True during a shift.
function jobs.is_on_duty(character_id)
  return type(character_id) == "string" and duty[character_id] ~= nil
end

-- Jobs -----------------------------------------------------------------------

---Gives a held character a job, or takes its job away. A change takes the
---character off duty first, so no shift spans two jobs, then is written to
---the record, which reports it as `employment`, and announced with
---`jobs.changed`. The job it has already is a success that changes
---nothing.
---
---Not staff-only: a player can run a business, so whoever may hire is the
---calling script's rule. Clearing a job works whether or not the config
---still has it.
---@param character_id string The character's uuid.
---@param employer string? The employer's slug, nil with `job` to clear.
---@param job string? The job's slug at that employer, nil with `employer` to clear.
---@return boolean? ok True if the character has that job (or none) now.
---@return string? err `"not_held"` for a character this server does not hold, `"invalid"` unless both are strings or both nil, `"not_found"` for a job that is not in the applied config. Nothing changes on an error.
function jobs.set_job(character_id, employer, job)
  if type(character_id) ~= "string" or not records.is_held("character", character_id) then
    return nil, "not_held"
  end
  ---@type rpf.JobRef?
  local ref = nil
  if employer ~= nil or job ~= nil then
    if type(employer) ~= "string" or type(job) ~= "string" then
      return nil, "invalid"
    end
    if not config.job(employer, job) then
      return nil, "not_found"
    end
    ref = { employer = employer, job = job }
  end
  local previous = stored_job(character_id)
  if (previous == nil and ref == nil) or (previous and ref and previous.employer == ref.employer and previous.job == ref.job) then
    return true
  end
  end_shift(character_id)
  local ok, err = records.set_job(character_id, ref)
  if not ok then
    return nil, err
  end
  events.emit("jobs.changed", character_id, ref and json.copy(ref) or nil, previous)
  return true
end

-- Ranks ----------------------------------------------------------------------

---A character's rank in its job: higher is more senior, and only ranks at
---the same employer compare.
---@param character_id string The character's uuid.
---@return number? rank The job's configured rank, or nil with no job, a job no longer in the config, or a character not held.
function jobs.rank_of(character_id)
  local _, def = jobs.job_of(character_id)
  if not def or not is_whole(def.rank) then
    return nil
  end
  return def.rank
end

---Whether a character works for an employer at or above a rank: the gate a
---script puts in front of what a sergeant may do and an officer may not.
---@param character_id string The character's uuid.
---@param employer string The employer's slug.
---@param minimum string|number A job slug at that employer, whose configured rank is the bar, or a whole number.
---@return boolean ranked False for a character with no job (or one no longer in the config), a job at another employer, a slug that is not a job there, or a minimum that is neither.
function jobs.has_rank(character_id, employer, minimum)
  local ref = stored_job(character_id)
  local rank = jobs.rank_of(character_id)
  if not ref or not rank or ref.employer ~= employer then
    return false
  end
  local bar = nil
  if type(minimum) == "string" then
    local def = config.job(employer, minimum)
    bar = def and is_whole(def.rank) and def.rank or nil
  elseif is_whole(minimum) then
    bar = minimum
  end
  return bar ~= nil and rank >= bar
end

-- Reacting -------------------------------------------------------------------

---A new character arrived without a job while the `economy.default_job`
---setting names one: the setting names a job this server does not have,
---and that is logged here, where the server's owner sees the character
---that got none.
---
---Giving the default job is not this module's: the portal creates every
---character in it (D7), in the same transaction as its starting accounts,
---so a character whose creation reply or first hold was lost (and which
---`rpf.characters` recovers without `characters.created`) still has it.
---@param _ rpf.PlayerView The player who created it.
---@param character table A copy of the character.
local function on_created(_, character)
  if type(character) ~= "table" or stored_job(character.id) then
    return
  end
  local named = config.setting(jobs.DEFAULT_JOB_SETTING)
  if json.is_object(named) then
    log(
      "warn",
      "the default job "
        .. tostring(named.employer)
        .. "/"
        .. tostring(named.job)
        .. " is not a job on this server; the new character starts with no job"
    )
  end
end

---A character was put away: its shift ends.
---@param _ rpf.PlayerView The player.
---@param character_id string The character.
local function on_deselected(_, character_id)
  end_shift(character_id)
end

---Records went (released, or lost to the portal): a character among them
---is no longer in play, and its shift ends.
---@param refs rpf.RecordRef[] The records.
local function on_records_gone(refs)
  for _, ref in ipairs(refs) do
    if ref.kind == "character" then
      end_shift(ref.id)
    end
  end
  sweep()
end

---A config was applied. Every job a held character has that the config no
---longer defines is logged, once until it comes back, and anyone on duty
---in one goes off duty. The job stays on the character: staff may restore
---it, and until then it counts as no job.
local function on_config_changed()
  local missing = {}
  for _, held in ipairs(records.held()) do
    if held.kind == "character" then
      local ref, def = jobs.job_of(held.id)
      if ref and not def then
        missing[name_of(ref)] = true
        end_shift(held.id)
      end
    end
  end
  local names = {}
  for name in pairs(missing) do
    if not warned[name] then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    log("warn", "the job " .. name .. " is no longer in the config; characters holding it count as having no job until it is restored")
  end
  warned = missing
end

---Starts the module: listens for new characters, characters put away,
---players leaving, records going and config changes. Called by
---`rpf.start_server` after `rpf.characters`, whose state the sweep reads.
---@param p rpf.ServerPlatform The platform.
function jobs.start(p)
  platform = p
  duty = {}
  warned = {}
  events.on("characters.created", on_created)
  events.on("characters.deselected", on_deselected)
  events.on("players.dropping", sweep)
  events.on("records.released", on_records_gone)
  events.on("records.lost", on_records_gone)
  events.on("config.changed", on_config_changed)
end

rpf.jobs = jobs
return jobs
