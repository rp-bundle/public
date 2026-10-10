---Authority per domain (K1): which of this server's gameplay domains RPF
---owns, and which the server's own RP framework owns instead.
---
---A domain is one of `NAMES`: characters, money, inventory and jobs. Each is
---`rpf` or `external` on a server, and the four together are its profile:
---native (all `rpf`) or companion (all `external`). `external` means RPF's
---own module for that domain is off on this server, never that it mirrors the
---framework (`docs/architecture/framework-integration.md`).
---
---**The profile is the portal's, and fixed for the life of the process.**
---Staff save it in the portal, and it reaches this core twice: in the config
---snapshot's `settings.domains`, which is what staff saved and changes
---whenever they do, and in `Welcome`, which is what the portal enforces on
---this connection. This module takes it from the first `Welcome` and keeps
---it until the process ends, and every later `Hello` reports it, so a
---change staff save while the server runs applies at its next start, and
---the portal follows the profile the server is really running. Nothing
---needs it before then: no player gets past `registered` without the portal.
---A later `Welcome` naming another profile is a portal this process cannot
---follow, and the connection stops (`rpf.client`).
---
---Before the first `Welcome` no profile is fixed: `current` is nil and no
---domain is external.
---
---**A companion server fails closed without its bridge.** RPF's own modules
---refuse an external domain (`domain_external`), so on a companion server
---the domains are the framework's, reached through a bridge (K2). Until a
---bridge is accepted, one whose `provides` is exactly the set of external
---domains, no player gets past `registered` (`may_play`, which
---`rpf.players.advance` asks), and one log line says why: a server with
---RPF's domains off and nothing in their place would let players into a
---world nobody keeps. K2 registers the bridge, checks its contract, and
---offers it here (`accept_bridge`).
---@class rpf.domains
---@field NAMES string[] The four domains, in the portal's order.
---@field NATIVE rpf.Domains The native profile, which a `Welcome` leaves out rather than names. Not to be changed: `fix` copies it.
local domains = {}

local rpf = rpf

domains.NAMES = { "characters", "money", "inventory", "jobs" }

---The native profile, which a `Welcome` leaves out rather than names.
---@type rpf.Domains
domains.NATIVE = { characters = "rpf", money = "rpf", inventory = "rpf", jobs = "rpf" }

---A profile: who owns each domain on this server.
---@class rpf.Domains
---@field characters "rpf"|"external" Who owns characters.
---@field money "rpf"|"external" Who owns accounts and their ledger.
---@field inventory "rpf"|"external" Who owns containers.
---@field jobs "rpf"|"external" Who owns employment: employers, jobs and duty.

---The profile this process fixed, once it has.
---@type rpf.Domains?
local fixed = nil

---The bridge offered for the external domains, once one is (K2).
---@type { name: string, provides: table<string, true> }?
local offered = nil

---The platform log lines go through, once `domains.start` has run.
---@type rpf.ServerPlatform?
local platform = nil

---Whether the line saying why players are held at `registered` has been
---logged, so it is logged once rather than per player.
local gate_logged = false

---A copy of a profile, holding only the four domains.
---@param profile rpf.Domains The profile.
---@return rpf.Domains copy The copy.
local function copy(profile)
  local out = {}
  for _, name in ipairs(domains.NAMES) do
    out[name] = profile[name]
  end
  return out
end

---Whether two profiles give every domain the same authority.
---@param a rpf.Domains A profile.
---@param b rpf.Domains Another.
---@return boolean same True if they agree on all four.
function domains.same(a, b)
  for _, name in ipairs(domains.NAMES) do
    if a[name] ~= b[name] then
      return false
    end
  end
  return true
end

---What kind of profile one is: `native`, `companion`, or `mixed`, which the
---portal does not let staff save yet (K5).
---@param profile rpf.Domains The profile.
---@return "native"|"companion"|"mixed" kind Its kind.
function domains.kind(profile)
  local rpf_count, external_count = 0, 0
  for _, name in ipairs(domains.NAMES) do
    if profile[name] == "rpf" then
      rpf_count = rpf_count + 1
    elseif profile[name] == "external" then
      external_count = external_count + 1
    end
  end
  if rpf_count == #domains.NAMES then
    return "native"
  elseif external_count == #domains.NAMES then
    return "companion"
  end
  return "mixed"
end

---Fixes this process's profile from a `Welcome`, the first time, and checks
---every later one against it. Announces `domains.fixed` with a copy when it
---first fixes one.
---@param profile rpf.Domains The profile the portal adopted, as decoded.
---@return boolean ok False if a profile is fixed already and this one differs.
---@return string? reason Why not, naming both, for the connection's log.
function domains.fix(profile)
  if fixed then
    if domains.same(fixed, profile) then
      return true
    end
    return false,
      "this server runs the "
        .. domains.kind(fixed)
        .. " profile until it restarts, and the portal now enforces the "
        .. domains.kind(profile)
        .. " one"
  end
  fixed = copy(profile)
  rpf.events.emit("domains.fixed", copy(fixed))
  return true
end

---The domains a profile leaves to the framework, as a set.
---@param profile rpf.Domains The profile.
---@return table<string, true> external The external domains.
local function external_set(profile)
  local out = {}
  for _, name in ipairs(domains.NAMES) do
    if profile[name] == "external" then
      out[name] = true
    end
  end
  return out
end

---A set of domain names, in `NAMES` order, for a log line.
---@param set table<string, true> The set.
---@return string names Comma-separated, or "none".
local function names_of(set)
  local out = {}
  for _, name in ipairs(domains.NAMES) do
    if set[name] then
      out[#out + 1] = name
    end
  end
  return #out > 0 and table.concat(out, ", ") or "none"
end

---Why the offered bridge does not fit the fixed profile, or nil if it does
---or there is nothing to fit yet.
---@return string? mismatch The reason, naming both sides.
local function mismatch()
  if not fixed then
    return nil
  end
  local wanted = external_set(fixed)
  if not offered then
    if next(wanted) == nil then
      return nil
    end
    return "this server runs the "
      .. domains.kind(fixed)
      .. " profile, whose "
      .. names_of(wanted)
      .. " are its framework's, and no bridge to that framework is registered"
  end
  for _, name in ipairs(domains.NAMES) do
    if (wanted[name] == true) ~= (offered.provides[name] == true) then
      return "the "
        .. offered.name
        .. " bridge provides "
        .. names_of(offered.provides)
        .. ", and this server's profile leaves "
        .. names_of(wanted)
        .. " to its framework"
    end
  end
  return nil
end

---Offers the bridge for the server's external domains (K2 calls this once
---it has checked the bridge's contract). It is accepted only if `provides`
---is exactly the set of domains the profile marks external; checked again
---when a profile is fixed, since a bridge registers when its resource
---starts, before the portal is reached. At most one is offered.
---@param name string The bridge's name, for the log.
---@param provides string[] The domains its framework owns.
---@return boolean ok False if one was offered already.
---@return string? err Why not.
function domains.accept_bridge(name, provides)
  if offered then
    return false, "a bridge is registered already: " .. offered.name
  end
  local set = {}
  for _, domain in ipairs(provides) do
    set[domain] = true
  end
  offered = { name = name, provides = set }
  gate_logged = false
  return true
end

---The accepted bridge's name: one is offered and fits the fixed profile.
---@return string? name The bridge, or nil.
function domains.bridge()
  if offered and fixed and mismatch() == nil then
    return offered.name
  end
  return nil
end

---Whether players may get past `registered`: always on a native server,
---and on one whose framework owns any domain only once a bridge that fits
---is accepted. Logs the reason once when they may not. Before a profile is
---fixed nobody can be registered, so this answers yes.
---
---A native server needs no bridge, so one offered there never holds a
---player back: it stays inactive (`bridge` is nil), and the log says so
---once, because a framework still running beside a native RPF is a second
---economy its owner should hear about.
---@return boolean ok True if a player may move on.
---@return string? err `"no_bridge"` if not.
function domains.may_play()
  local why = mismatch()
  if not why then
    return true
  end
  if next(external_set(fixed --[[@as rpf.Domains]])) == nil then
    if not gate_logged and platform then
      gate_logged = true
      platform.log("warn", "rpf.domains: " .. why .. "; the bridge stays inactive, and RPF owns every domain here")
    end
    return true
  end
  if not gate_logged then
    gate_logged = true
    if platform then
      platform.log("error", "rpf.domains: " .. why .. ", so players stay at registered until a bridge that provides exactly those is")
    end
  end
  return false, "no_bridge"
end

---The profile this process runs: a copy, or nil before the first `Welcome`.
---@return rpf.Domains? profile The profile.
function domains.current()
  return fixed and copy(fixed)
end

---Who owns a domain on this server: `rpf` or `external`, or nil before a
---profile is fixed or for a name that is not a domain.
---@param name string One of `NAMES`.
---@return ("rpf"|"external")? authority Its authority.
function domains.authority(name)
  return fixed and fixed[name]
end

---Whether the server's framework owns a domain, so RPF's own module for it
---must refuse. False before a profile is fixed.
---@param name string One of `NAMES`.
---@return boolean external True if the domain is external.
function domains.is_external(name)
  return domains.authority(name) == "external"
end

---Binds the platform this module logs through, and checks the gate as each
---player registers, so the reason they go no further is logged when it
---first matters, whatever does or does not try to move them on. Called by
---`rpf.start_server`.
---@param p rpf.ServerPlatform The platform.
function domains.start(p)
  platform = p
  rpf.events.on("players.registered", function()
    domains.may_play()
  end)
end

rpf.domains = domains
return domains
