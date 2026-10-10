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
---@class rpf.domains
---@field NAMES string[] The four domains, in the portal's order.
local domains = {}

local rpf = rpf

domains.NAMES = { "characters", "money", "inventory", "jobs" }

---A profile: who owns each domain on this server.
---@class rpf.Domains
---@field characters "rpf"|"external" Who owns characters.
---@field money "rpf"|"external" Who owns accounts and their ledger.
---@field inventory "rpf"|"external" Who owns containers.
---@field jobs "rpf"|"external" Who owns employment: employers, jobs and duty.

---The profile this process fixed, once it has.
---@type rpf.Domains?
local fixed = nil

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

rpf.domains = domains
return domains
