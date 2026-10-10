---@meta

-- The part of DarkRP (https://github.com/FPtje/DarkRP) the bridge's entry
-- point calls, for the language server. DarkRP ships no annotations, so
-- these follow its source at 2.7.0. This file is a definition and is never
-- loaded or shipped; DarkRP, the gamemode, defines all of it.

---DarkRP's library table, which DarkRP makes as it loads. The bridge only
---asks whether it exists.
---@type table
DarkRP = {}

---DarkRP's jobs, by team number. The bridge only asks whether it exists.
---@type table
RPExtraTeams = {}

---One of DarkRP's jobs, as `getJobTable` hands it over.
---@class DarkRP.Job
---@field command string What `/job` and the F4 menu call it, unique among jobs.
---@field name string What players see.

---@class Player
---@field DarkRPUnInitialized boolean? Set while DarkRP loads the player's data, and left set when the load failed.
---@field DarkRPDataRetrievalFailed boolean? Set when DarkRP gave up loading the player's data.
local Player = {}

---One of the player's DarkRPVars (`money`, `rpname`, `job`, …).
---@param var string The var.
---@param fallback any? What to answer when it is not set.
---@return any value Its value, or `fallback`.
function Player:getDarkRPVar(var, fallback) end

---Whether the player's wallet holds an amount: false while their data is not loaded.
---@param amount number The amount.
---@return boolean affordable True if it does.
function Player:canAfford(amount) end

---Adds a signed amount to the player's wallet, through `playerWalletChanged`, and saves it.
---@param amount number The amount, floored.
---@return boolean? done False for an amount it cannot read; nothing otherwise.
function Player:addMoney(amount) end

---The job of the player's team.
---@return DarkRP.Job? job The job, or nil for a team that is none.
function Player:getJobTable() end
