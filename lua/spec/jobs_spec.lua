-- luassert's bundled annotations allow one argument to each assertion, but
-- every assertion takes a message as its last. The message is what makes a
-- failure in a loop say which case failed, so it stays.
---@diagnostic disable: redundant-parameter

-- Characters' jobs, duty and salaries (D7), with the test playing the portal.
-- A job is part of the held character, reported as `employment`; duty is
-- memory only and needs the character in play; salaries run on the platform
-- clock, so a shift passes in an `advance`.

local support = require("spec.support")

local SERVER = "00000001-0000-4000-8000-000000000001"
local PLAYER = "00000002-0000-4000-8000-000000000002"
local JANE = "00000003-0000-4000-8000-000000000003"
local JOHN = "00000003-0000-4000-8000-000000000033"
local NEW = "00000003-0000-4000-8000-000000000099"
local ELSEWHERE = "00000003-0000-4000-8000-0000000000ff"
local JANE_WALLET = "00000004-0000-4000-8000-000000000004"
local JANE_BANK = "00000004-0000-4000-8000-000000000044"
local TREASURY = "00000005-0000-4000-8000-000000000005"
local MINUTE = 60 * 1000
local PERIOD = 15 * MINUTE

---Config versions applied so far, so each is a new one.
local version = 0

---The default jobs: the police pay from the treasury, the medics' employer
---has no payroll account.
---@return table[] jobs The jobs.
local function default_jobs()
  return {
    { employer = "lspd", slug = "officer", name = "Officer", description = "", rank = 1, salary = 250 },
    { employer = "lspd", slug = "sergeant", name = "Sergeant", description = "", rank = 5, salary = 400 },
    { employer = "lspd", slug = "chief", name = "Chief", description = "", rank = 10 },
    { employer = "ems", slug = "medic", name = "Medic", description = "", rank = 7, salary = 300 },
  }
end

---Applies a config, as the portal's `config` request would.
---@param p spec.FakePlatform The platform.
---@param opts { jobs: table[]?, settings: table?, payroll: string|false|nil, default_job: table? }? What differs from the default.
local function configure(p, opts)
  opts = opts or {}
  local json = rpf.json
  local jobs = json.array()
  for i, job in ipairs(opts.jobs or default_jobs()) do
    jobs[i] = json.object(job)
  end
  local settings = json.object({
    ["economy.salary_interval_minutes"] = 15,
    ["economy.salary_account"] = "bank",
    ["economy.default_job"] = json.null,
  })
  for key, value in pairs(opts.settings or {}) do
    settings[key] = value
  end
  local lspd = json.object({ slug = "lspd", name = "Police", description = "" })
  if opts.payroll ~= false then
    lspd.payroll = opts.payroll or "treasury"
  end
  local snapshot = json.object({
    settings = settings,
    employers = json.array({ lspd, json.object({ slug = "ems", name = "EMS", description = "" }) }),
    employer_jobs = jobs,
    paying_accounts = json.array({ json.object({ id = TREASURY, name = "treasury" }) }),
    new_character = json.object({
      accounts = json.array(),
      job = opts.default_job and json.object(opts.default_job) or json.null,
    }),
  })
  version = version + 1
  local text = assert(json.encode(snapshot))
  assert.is_true((rpf.config.apply(p, version, "h" .. version, assert(json.decode(text)))))
end

---Frames of one type among everything sent.
---@param p spec.FakePlatform The platform.
---@param tag string The type.
---@return rpf.Frame[] frames The frames, in order.
local function sent_of(p, tag)
  local out = {}
  for _, frame in ipairs(p.frames()) do
    if frame.type == tag then
      out[#out + 1] = frame
    end
  end
  return out
end

---The last frame of one type sent.
---@param p spec.FakePlatform The platform.
---@param tag string The type.
---@return rpf.Frame frame The frame.
local function last_of(p, tag)
  local frames = sent_of(p, tag)
  return assert(frames[#frames], "no " .. tag .. " was sent")
end

---Answers the last hold with these records.
---@param p spec.FakePlatform The platform.
---@param records table[] The records.
local function held(p, records)
  p.deliver(support.portal_frame("held", { re = last_of(p, "hold").id, records = records }))
end

---A character as the portal hands one over.
---@param id string Its id.
---@param job table? Its job, `{ employer, job }`.
---@return table record The `held` record.
local function character(id, job)
  return {
    kind = "character",
    revision = 1,
    character = {
      id = id,
      server_id = SERVER,
      owner = { kind = "player", id = PLAYER },
      first_name = id == JANE and "Jane" or "John",
      last_name = "Doe",
      gender = "female",
      job = job,
    },
  }
end

---An account as the portal hands one over.
---@param id string Its id.
---@param owner table Its owner.
---@param name string Its name.
---@param balance number Its balance.
---@param flags string[]? Its flags.
---@return table record The `held` record.
local function account(id, owner, name, balance, flags)
  return {
    kind = "account",
    revision = 0,
    account = { id = id, server_id = SERVER, owner = owner, name = name, flags = rpf.json.array(flags or {}) },
    balance = balance,
  }
end

describe("rpf.jobs", function()
  local p, seen

  before_each(function()
    support.load_core()
    p = support.fake_platform()
    -- The config a previous run applied, restored at start, so the paying
    -- account is held after the Welcome.
    configure(p)
    support.connected(p)
    held(p, { account(TREASURY, { kind = "server", id = SERVER }, "treasury", 0, { "unlimited_balance" }) })
    seen = {}
    for _, name in ipairs({ "jobs.changed", "jobs.duty", "jobs.paid" }) do
      rpf.events.on(name, function(...)
        seen[#seen + 1] = { name, ... }
      end)
    end
  end)

  ---Registers player 7, whose session holds Jane (an officer) and John (no job).
  local function loaded()
    rpf.players.connected(7)
    rpf.players.authenticating(7)
    assert(rpf.players.register(7, { player_id = PLAYER, username = "sam" }))
    held(p, { character(JANE, { employer = "lspd", job = "officer" }), character(JOHN) })
  end

  ---Registers player 7 and puts Jane in play, with her wallet and bank.
  local function playing()
    loaded()
    assert.is_true(rpf.characters.select(7, JANE))
    local jane = { kind = "character", id = JANE }
    held(p, { account(JANE_WALLET, jane, "wallet", 10), account(JANE_BANK, jane, "bank", 100) })
    assert.are.equal("active", rpf.players.get(7).state)
  end

  ---The events of one name seen so far.
  ---@param name string The event.
  ---@return table[] events Each `{ name, ... }`.
  local function events_of(name)
    local out = {}
    for _, event in ipairs(seen) do
      if event[1] == name then
        out[#out + 1] = event
      end
    end
    return out
  end

  describe("a character's job", function()
    it("is read from the held character, with its definition", function()
      loaded()
      local ref, def = rpf.jobs.job_of(JANE)
      assert.are.same({ employer = "lspd", job = "officer" }, ref)
      assert.are.equal(250, assert(def).salary)
      assert.are.same({ nil, nil }, { rpf.jobs.job_of(JOHN) }, "no job")
      assert.are.same({ nil, nil }, { rpf.jobs.job_of(ELSEWHERE) }, "not held")
      -- A script can pass anything: refused, not thrown.
      ---@diagnostic disable-next-line: param-type-mismatch
      assert.are.same({ nil, nil }, { rpf.jobs.job_of(42) })

      ref.job = "chief"
      assert.are.equal("officer", rpf.jobs.job_of(JANE).job, "a copy")
    end)

    it("changes, announced with the job and the one before", function()
      loaded()
      assert.is_true(rpf.jobs.set_job(JOHN, "lspd", "sergeant"))
      assert.are.same({ employer = "lspd", job = "sergeant" }, rpf.jobs.job_of(JOHN))
      assert.are.same({ { "jobs.changed", JOHN, { employer = "lspd", job = "sergeant" }, nil } }, seen)

      assert.is_true(rpf.jobs.set_job(JANE, nil, nil))
      assert.is_nil(rpf.jobs.job_of(JANE))
      assert.are.same({ "jobs.changed", JANE, nil, { employer = "lspd", job = "officer" } }, seen[2])
    end)

    it("is reported to the portal with the character, as employment", function()
      loaded()
      assert.is_true(rpf.jobs.set_job(JOHN, "ems", "medic"))
      assert.is_true(rpf.jobs.set_job(JANE, nil, nil))
      p.advance(1000)
      local changes = {}
      for _, change in ipairs(last_of(p, "state_changed").changes) do
        changes[change.id] = change.employment
      end
      assert.are.same({ job = { employer = "ems", job = "medic" } }, changes[JOHN])
      assert.are.same({}, changes[JANE], "{ job = null }: no job")
    end)

    it("is a no-op, unannounced and unreported, when it is the job it has", function()
      loaded()
      assert.is_true(rpf.jobs.set_job(JANE, "lspd", "officer"))
      assert.is_true(rpf.jobs.set_job(JOHN, nil, nil))
      p.advance(1000)
      assert.are.same({}, seen)
      assert.are.equal(0, #sent_of(p, "state_changed"))
    end)

    it("refuses a job not in the config, half a job, and a character not held, changing nothing", function()
      loaded()
      assert.are.same({ nil, "not_found" }, { rpf.jobs.set_job(JOHN, "lspd", "janitor") })
      assert.are.same({ nil, "not_found" }, { rpf.jobs.set_job(JOHN, "ems", "officer") }, "officer is the police's")
      assert.are.same({ nil, "invalid" }, { rpf.jobs.set_job(JOHN, "lspd", nil) })
      assert.are.same({ nil, "invalid" }, { rpf.jobs.set_job(JOHN, nil, "officer") })
      -- A script can pass anything: refused, not thrown.
      ---@diagnostic disable-next-line: param-type-mismatch
      assert.are.same({ nil, "invalid" }, { rpf.jobs.set_job(JOHN, "lspd", 1) })
      assert.are.same({ nil, "not_held" }, { rpf.jobs.set_job(ELSEWHERE, "lspd", "officer") })
      assert.are.same({ nil, "not_held" }, { rpf.jobs.set_job(JANE_BANK, nil, nil) }, "an account is no character")
      assert.is_nil(rpf.jobs.job_of(JOHN))
      assert.are.same({}, seen)
    end)

    it("refuses its events to scripts", function()
      for _, name in ipairs({ "jobs.changed", "jobs.duty", "jobs.paid" }) do
        assert.are.same({ nil, "reserved" }, { rpf.api.events.emit(name, JANE) }, name)
      end
    end)

    it("is internal: the public jobs calls are the facade's, which only reads a job", function()
      assert.is_nil((rpf.api.jobs --[[@as table]]).set_job)
    end)
  end)

  describe("ranks", function()
    it("are the configured job's, compared within one employer", function()
      loaded()
      assert.is_true(rpf.jobs.set_job(JOHN, "lspd", "sergeant"))
      assert.are.equal(5, rpf.jobs.rank_of(JOHN))
      assert.is_true(rpf.jobs.has_rank(JOHN, "lspd", "officer"))
      assert.is_true(rpf.jobs.has_rank(JOHN, "lspd", "sergeant"))
      assert.is_false(rpf.jobs.has_rank(JOHN, "lspd", "chief"))
      assert.is_true(rpf.jobs.has_rank(JOHN, "lspd", 5))
      assert.is_false(rpf.jobs.has_rank(JOHN, "lspd", 6))
      assert.is_false(rpf.jobs.has_rank(JOHN, "ems", 0), "another employer, whatever the number")
      assert.is_false(rpf.jobs.has_rank(JOHN, "ems", "medic"))
      assert.is_false(rpf.jobs.has_rank(JOHN, "lspd", "janitor"), "not a job there")
      assert.is_false(rpf.jobs.has_rank(JOHN, "lspd", 1.5))
      -- A script can pass anything: refused, not thrown.
      ---@diagnostic disable-next-line: param-type-mismatch
      assert.is_false(rpf.jobs.has_rank(JOHN, "lspd", nil))
    end)

    it("are nothing without a job, or with one the config no longer has", function()
      loaded()
      assert.is_nil(rpf.jobs.rank_of(JOHN))
      assert.is_false(rpf.jobs.has_rank(JOHN, "lspd", 0))
      assert.is_nil(rpf.jobs.rank_of(ELSEWHERE))

      local jobs = default_jobs()
      table.remove(jobs, 1)
      configure(p, { jobs = jobs })
      assert.is_nil(rpf.jobs.rank_of(JANE))
      assert.is_false(rpf.jobs.has_rank(JANE, "lspd", 0))
    end)
  end)

  describe("the default job", function()
    ---Player 7 creates a character, which the portal hands over with this job.
    ---@param job table? The job the portal created it with.
    local function create(job)
      assert.is_true(rpf.characters.create(7, { first_name = "Ada", last_name = "L", gender = "female" }))
      local created = last_of(p, "create_character")
      local record = character(NEW, job)
      p.deliver(support.portal_frame("character_created", { re = created.id, character = record.character }))
      held(p, { record })
    end

    it("is the portal's to give: a character created in it keeps it, and nothing is changed", function()
      configure(p, { default_job = { employer = "lspd", job = "officer" } })
      loaded()
      create({ employer = "lspd", job = "officer" })
      assert.are.same({ employer = "lspd", job = "officer" }, rpf.jobs.job_of(NEW))
      assert.are.same({}, seen)
      assert.are.same({}, p.logged("warn", "default job"))
    end)

    it("is not given by the core to a character the portal created without one", function()
      configure(p, { default_job = { employer = "lspd", job = "officer" } })
      loaded()
      create(nil)
      assert.is_nil(rpf.jobs.job_of(NEW))
      assert.are.same({}, seen)
    end)

    it("leaves a new character with no job when there is none", function()
      loaded()
      create(nil)
      assert.is_nil(rpf.jobs.job_of(NEW))
      assert.are.same({}, p.logged("warn", "default job"))
    end)

    it("is logged when the setting names a job this server does not have, and none is given", function()
      configure(p, { settings = { ["economy.default_job"] = rpf.json.object({ employer = "lspd", job = "gone" }) } })
      loaded()
      create(nil)
      assert.is_nil(rpf.jobs.job_of(NEW))
      assert.are.equal(
        1,
        #p.logged("warn", "the default job lspd/gone is not a job on this server; the new character starts with no job")
      )
    end)
  end)

  describe("duty", function()
    it("needs the character in play, with a job in the config", function()
      loaded()
      assert.are.same({ nil, "not_in_play" }, { rpf.jobs.on_duty(JANE) }, "held, but nobody is playing her")
      assert.are.same({ nil, "not_in_play" }, { rpf.jobs.on_duty(ELSEWHERE) })
      -- A script can pass anything: refused, not thrown.
      ---@diagnostic disable-next-line: param-type-mismatch
      assert.are.same({ nil, "not_in_play" }, { rpf.jobs.on_duty(nil) })

      assert.is_true(rpf.characters.select(7, JANE))
      held(p, {})
      assert.is_true(rpf.jobs.set_job(JANE, nil, nil))
      assert.are.same({ nil, "no_job" }, { rpf.jobs.on_duty(JANE) })
      assert.is_false(rpf.jobs.is_on_duty(JANE))
    end)

    it("is announced going on, once", function()
      playing()
      assert.is_true(rpf.jobs.on_duty(JANE))
      assert.is_true(rpf.jobs.on_duty(JANE), "already")
      assert.is_true(rpf.jobs.is_on_duty(JANE))
      assert.are.same({ { "jobs.duty", JANE, true } }, seen)

      assert.is_true(rpf.jobs.off_duty(JANE))
      assert.is_true(rpf.jobs.off_duty(JANE), "already")
      assert.is_false(rpf.jobs.is_on_duty(JANE))
      assert.are.same({ "jobs.duty", JANE, false }, seen[2])
      assert.are.equal(2, #seen)
    end)

    it("is never reported to the portal", function()
      playing()
      local before = #p.frames()
      assert.is_true(rpf.jobs.on_duty(JANE))
      p.advance(1000)
      assert.are.equal(before, #p.frames())
    end)

    it("ends before a job change, so no shift spans two jobs", function()
      playing()
      assert.is_true(rpf.jobs.on_duty(JANE))
      assert.is_true(rpf.jobs.set_job(JANE, "lspd", "sergeant"))
      assert.is_false(rpf.jobs.is_on_duty(JANE))
      assert.are.same({ "jobs.duty", JANE, false }, seen[2])
      assert.are.equal("jobs.changed", seen[3][1])
    end)

    it("ends when the character is put away", function()
      playing()
      assert.is_true(rpf.jobs.on_duty(JANE))
      assert.is_true(rpf.characters.deselect(7))
      assert.is_false(rpf.jobs.is_on_duty(JANE))
      assert.are.same({ "jobs.duty", JANE, false }, seen[#seen])
    end)

    it("ends when the player leaves", function()
      playing()
      assert.is_true(rpf.jobs.on_duty(JANE))
      rpf.players.dropped(7, "quit")
      assert.is_false(rpf.jobs.is_on_duty(JANE))
      assert.are.same({ { "jobs.duty", JANE, true }, { "jobs.duty", JANE, false } }, seen)
    end)

    it("ends when the character is released", function()
      playing()
      assert.is_true(rpf.jobs.on_duty(JANE))
      assert.is_true(rpf.sync.release({ { kind = "character", id = JANE } }))
      assert.is_false(rpf.jobs.is_on_duty(JANE))
    end)

    it("ends when the portal takes the character away", function()
      playing()
      assert.is_true(rpf.jobs.on_duty(JANE))
      rpf.records.lose({ { kind = "character", id = JANE } }, "force-released")
      assert.is_false(rpf.jobs.is_on_duty(JANE))
      assert.are.same({ "jobs.duty", JANE, false }, seen[#seen])
    end)
  end)

  describe("a job removed from the config", function()
    ---The default jobs without the officer.
    ---@return table[] jobs The jobs.
    local function without_officer()
      local jobs = default_jobs()
      table.remove(jobs, 1)
      return jobs
    end

    it("takes whoever is on duty in it off duty, logged once, and stays on the character", function()
      playing()
      assert.is_true(rpf.jobs.on_duty(JANE))
      configure(p, { jobs = without_officer() })

      assert.is_false(rpf.jobs.is_on_duty(JANE))
      assert.are.same({ "jobs.duty", JANE, false }, seen[#seen])
      local ref, def = rpf.jobs.job_of(JANE)
      assert.are.same({ employer = "lspd", job = "officer" }, ref, "kept, for staff to restore")
      assert.is_nil(def)
      assert.are.equal("officer", rpf.records.get("character", JANE).job.job)
      assert.are.same({ nil, "no_job" }, { rpf.jobs.on_duty(JANE) })
      local warning = "the job lspd/officer is no longer in the config"
      assert.are.equal(1, #p.logged("warn", warning))

      configure(p, { jobs = without_officer(), settings = { ["economy.salary_interval_minutes"] = 5 } })
      assert.are.equal(1, #p.logged("warn", warning), "once while it stays gone")

      configure(p)
      assert.is_true(rpf.jobs.on_duty(JANE), "restored")
      assert.are.equal(1, rpf.jobs.rank_of(JANE))
      configure(p, { jobs = without_officer() })
      assert.are.equal(2, #p.logged("warn", warning), "and again when it goes again")
    end)

    it("can still be taken away", function()
      loaded()
      configure(p, { jobs = without_officer() })
      assert.is_true(rpf.jobs.set_job(JANE, nil, nil))
      assert.is_nil(rpf.jobs.job_of(JANE))
    end)
  end)

  describe("salaries", function()
    ---The salaries paid so far: each `jobs.paid` event's character and amount.
    ---@return table[] paid Each `{ character_id, amount }`.
    local function paid()
      local out = {}
      for _, event in ipairs(events_of("jobs.paid")) do
        out[#out + 1] = { event[2], event[3] }
      end
      return out
    end

    it("are paid once per period on duty, from the payroll into the salary account", function()
      playing()
      assert.is_true(rpf.jobs.on_duty(JANE))
      p.advance(PERIOD - 1)
      assert.are.same({}, paid())
      p.advance(1)
      assert.are.same({ { JANE, 250 } }, paid())
      assert.are.equal(350, rpf.accounts.balance(JANE_BANK))
      assert.are.equal(-250, rpf.accounts.balance(TREASURY))
      assert.are.equal(10, rpf.accounts.balance(JANE_WALLET))

      local event = events_of("jobs.paid")[1]
      p.advance(1000)
      local reported
      for _, change in ipairs(last_of(p, "state_changed").changes) do
        for _, tx in ipairs(change.transactions or {}) do
          reported = tx
        end
      end
      assert.are.same({
        client_id = event[4],
        from_account = TREASURY,
        to_account = JANE_BANK,
        amount = 250,
        description = "Salary: lspd/officer",
      }, reported, "a ledger entry, reported with the paying account")

      p.advance(PERIOD - 1000)
      assert.are.equal(2, #paid())
      p.advance(3 * PERIOD)
      assert.are.equal(5, #paid(), "exactly one per period")
    end)

    it("are measured from going on duty, and stop when the shift ends", function()
      playing()
      assert.is_true(rpf.jobs.on_duty(JANE))
      p.advance(10 * MINUTE)
      assert.is_true(rpf.jobs.off_duty(JANE))
      assert.is_true(rpf.jobs.on_duty(JANE))
      p.advance(5 * MINUTE)
      assert.are.same({}, paid(), "the first shift's timer is stale")
      p.advance(10 * MINUTE)
      assert.are.same({ { JANE, 250 } }, paid(), "a full period into the second shift")

      assert.is_true(rpf.jobs.off_duty(JANE))
      p.advance(10 * PERIOD)
      assert.are.equal(1, #paid(), "nothing off duty")
    end)

    it("are never paid to a character nobody is playing", function()
      playing()
      assert.is_true(rpf.jobs.on_duty(JANE))
      rpf.players.dropped(7, "quit")
      p.advance(10 * PERIOD)
      assert.are.same({}, paid())
    end)

    it("follow the pay period setting, falling back to 15 minutes", function()
      configure(p, { settings = { ["economy.salary_interval_minutes"] = 5 } })
      playing()
      assert.is_true(rpf.jobs.on_duty(JANE))
      p.advance(5 * MINUTE)
      assert.are.equal(1, #paid())
      assert.is_true(rpf.jobs.off_duty(JANE))

      for _, minutes in ipairs({ 0, 1441, 2.5, "5" }) do
        configure(p, { settings = { ["economy.salary_interval_minutes"] = minutes } })
        assert.are.equal(PERIOD, rpf.jobs.pay_period_ms(), tostring(minutes))
      end
    end)

    it("are paid into the account the setting names", function()
      configure(p, { settings = { ["economy.salary_account"] = "wallet" } })
      playing()
      assert.is_true(rpf.jobs.on_duty(JANE))
      p.advance(PERIOD)
      assert.are.equal(260, rpf.accounts.balance(JANE_WALLET))
      assert.are.equal(100, rpf.accounts.balance(JANE_BANK))

      configure(p, { settings = { ["economy.salary_account"] = "Not An Identifier" } })
      assert.are.equal("bank", rpf.jobs.salary_account())
    end)

    it("read the config at each payment, and pay what it says then", function()
      playing()
      assert.is_true(rpf.jobs.on_duty(JANE))
      local jobs = default_jobs()
      jobs[1].salary = 300
      configure(p, { jobs = jobs })
      p.advance(PERIOD)
      assert.are.same({ { JANE, 300 } }, paid())
    end)

    it("are skipped, logged, while the employer has no payroll, and paid once it has", function()
      configure(p, { payroll = false })
      playing()
      assert.is_true(rpf.jobs.on_duty(JANE))
      p.advance(PERIOD)
      assert.are.same({}, paid())
      assert.are.equal(1, #p.logged("warn", "not paying the job lspd/officer: its employer has no payroll account"))
      assert.is_true(rpf.jobs.is_on_duty(JANE), "the shift goes on")

      configure(p, { payroll = "pension" })
      p.advance(PERIOD)
      assert.are.same({}, paid())
      assert.are.equal(1, #p.logged("warn", "its payroll account pension is not one of this server's paying accounts"))

      configure(p)
      p.advance(PERIOD)
      assert.are.same({ { JANE, 250 } }, paid())
    end)

    it("are skipped, logged, without the salary account", function()
      configure(p, { settings = { ["economy.salary_account"] = "savings" } })
      playing()
      assert.is_true(rpf.jobs.on_duty(JANE))
      p.advance(PERIOD)
      assert.are.same({}, paid())
      assert.are.equal(1, #p.logged("warn", "the character has no account named savings held here"))
    end)

    it("are skipped, logged, when the payroll account is not held", function()
      playing()
      assert.is_true(rpf.jobs.on_duty(JANE))
      rpf.records.forget({ { kind = "account", id = TREASURY } })
      p.advance(PERIOD)
      assert.are.same({}, paid())
      assert.are.equal(1, #p.logged("warn", "not paying the job lspd/officer (not_held)"))
    end)

    it("are nothing for an unpaid job", function()
      playing()
      assert.is_true(rpf.jobs.set_job(JANE, "lspd", "chief"))
      assert.is_true(rpf.jobs.on_duty(JANE))
      p.advance(2 * PERIOD)
      assert.are.same({}, paid())
      assert.are.same({}, p.logged("warn", "not paying"))
      assert.is_true(rpf.jobs.is_on_duty(JANE))
    end)

    it("stop with the shift when the config drops the job, without failing", function()
      playing()
      assert.is_true(rpf.jobs.on_duty(JANE))
      local jobs = default_jobs()
      table.remove(jobs, 1)
      configure(p, { jobs = jobs })
      p.advance(2 * PERIOD)
      assert.are.same({}, paid())
      assert.are.same({}, p.logged("error", "jobs"))
    end)
  end)
end)
