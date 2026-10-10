-- The Qbox bridge's character selection, on the player's client (K3). With
-- `useExternalCharacters = true`, qbx_core shows none of its own, and this
-- stands where its selection stood. The server shows it on RPF's cue
-- (`rpf-qbox:select`), once the player has logged in to RPF, and decides
-- everything: which characters are theirs, and whether one may load. This
-- file only asks and draws, on ox_lib's menus.
--
-- After a load it does what qbx_core's own selection does after one
-- (`client/character.lua` in qbx_core 1.24): spawns the ped, ends the
-- loading screen, and sends `QBCore:Server:OnPlayerLoaded` and
-- `QBCore:Client:OnPlayerLoaded`. Those two are how qbx_core's client and
-- other scripts learn that the player is in, and they come from whichever
-- selection is running. They are the only Qbox events the bridge sends, and
-- its server never trusts the networked one.

---Where a new character spawns: qbx_core's own `defaultSpawn`
---(`config/shared.lua`), which another resource cannot read.
local DEFAULT_SPAWN = vec4(-540.58, -212.02, 37.65, 208.88)

---The most characters' worth of text a field takes, as qbx_core's own
---creation checks.
local MAX_TEXT = 50

---The menu's id with ox_lib.
local MENU = "rpf_qbox_select"

---Whether a request to the server is in flight, so a second click waits.
local busy = false

---The selection, shown again after anything that did not load a character.
local choose

---Puts the ped in the world at a position, then tells qbx_core's client and
---every other script that the player is in, as qbx_core's selection does.
---@param at vector4|vector3|table? Where: the character's last position, or nil for the default spawn.
local function spawn(at)
  local x, y, z, heading = DEFAULT_SPAWN.x, DEFAULT_SPAWN.y, DEFAULT_SPAWN.z, DEFAULT_SPAWN.w
  if type(at) == "table" or type(at) == "vector4" or type(at) == "vector3" then
    x, y, z = at.x or x, at.y or y, at.z or z
    heading = at.w or heading
  end
  DoScreenFadeOut(500)
  while not IsScreenFadedOut() do
    Wait(0)
  end
  pcall(function()
    exports.spawnmanager:spawnPlayer({ x = x, y = y, z = z, heading = heading })
  end)
  ShutdownLoadingScreen()
  ShutdownLoadingScreenNui()
  TriggerServerEvent("QBCore:Server:OnPlayerLoaded")
  TriggerEvent("QBCore:Client:OnPlayerLoaded")
  DoScreenFadeIn(500)
end

---The character qbx_core's client has, once the server's login reached it.
---@return table? data Its `PlayerData`, or nil if none arrived in time.
local function player_data()
  for _ = 1, 50 do
    local ok, data = pcall(function()
      return exports.qbx_core:GetPlayerData()
    end)
    if ok and type(data) == "table" and data.citizenid then
      return data
    end
    Wait(100)
  end
  return nil
end

---Says why the selection did not load a character, and shows it again.
---@param why string? The server's reason.
local function failed(why)
  lib.notify({ type = "error", description = "That character could not be loaded (" .. tostring(why) .. ")." })
  SetTimeout(500, function()
    choose()
  end)
end

---Asks the server to load one of the player's characters.
---@param citizenid string The character.
local function load(citizenid)
  if busy then
    return
  end
  busy = true
  local answer = lib.callback.await("rpf-qbox:load", false, citizenid)
  busy = false
  if type(answer) ~= "table" or not answer.ok then
    failed(type(answer) == "table" and answer.error or "no answer")
    return
  end
  local data = player_data()
  spawn(data and data.position or nil)
end

---Creates a character through qbx_core's own creation, which applies its
---rules (the character cap, its checks, the starter items) and loads it.
---The server accepts that load only while the player is choosing.
local function create()
  local values = lib.inputDialog("New character", {
    { type = "input", label = "First name", required = true, maxLength = MAX_TEXT },
    { type = "input", label = "Last name", required = true, maxLength = MAX_TEXT },
    { type = "input", label = "Nationality", required = true, maxLength = MAX_TEXT },
    { type = "date", label = "Date of birth", required = true, format = "YYYY-MM-DD", returnString = true },
    {
      type = "select",
      label = "Gender",
      required = true,
      options = { { value = "0", label = "Male" }, { value = "1", label = "Female" } },
    },
  })
  if not values then
    choose()
    return
  end
  if busy then
    return
  end
  busy = true
  local created = lib.callback.await("qbx_core:server:createCharacter", false, {
    firstname = values[1],
    lastname = values[2],
    nationality = values[3],
    birthdate = values[4],
    gender = tonumber(values[5]),
  })
  busy = false
  if not created then
    failed("qbx_core refused it")
    return
  end
  spawn(nil)
  -- What qbx_core's own selection does for a new character: the appearance
  -- resource (illenium-appearance, qb-clothing) starts its first-character
  -- setup on this event.
  TriggerEvent("qb-clothes:client:CreateFirstCharacter")
end

choose = function()
  local answer = lib.callback.await("rpf-qbox:characters", false)
  if type(answer) ~= "table" or type(answer.characters) ~= "table" then
    return
  end
  local options = {}
  for _, character in ipairs(answer.characters) do
    local citizenid = character.citizenid
    options[#options + 1] = {
      title = character.name,
      onSelect = function()
        load(citizenid)
      end,
    }
  end
  options[#options + 1] = { title = "New character", icon = "plus", onSelect = create }
  ShutdownLoadingScreen()
  ShutdownLoadingScreenNui()
  lib.registerContext({ id = MENU, title = "Choose a character", canClose = false, options = options })
  lib.showContext(MENU)
end

-- Only the server shows the selection: a script on this client cannot
-- (`GetInvokingResource` is nil only for an event from the server). It
-- does so only while the bridge is active, so this is also where the
-- client takes over spawning, as qbx_core's own selection does: a player
-- spawns only once a character is loaded. Never before, so a server where
-- the bridge stays inactive (a native one) keeps its own spawning.
RegisterNetEvent("rpf-qbox:select", function()
  if GetInvokingResource() then
    return
  end
  pcall(function()
    exports.spawnmanager:setAutoSpawn(false)
  end)
  choose()
end)

-- RPF's login comes before the selection, and has to show over the game:
-- once the session starts the loading screen ends, as qbx_core's own
-- selection ends it. Qbox's recipe leaves it for the selection to end
-- (`loadscreen:externalShutdown`). Only where qbx_core runs, so a server
-- where the bridge stays inactive keeps its loading screen as it was.
CreateThread(function()
  while not NetworkIsSessionStarted() do
    Wait(0)
  end
  if GetResourceState("qbx_core") == "started" then
    ShutdownLoadingScreen()
    ShutdownLoadingScreenNui()
  end
end)
