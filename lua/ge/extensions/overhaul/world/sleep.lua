-- Owns the sleep-menu flow and delegates clock control to dynamic weather when available.
-- Requires and save keys, config, state, time-of-day and save helpers, menus, hooks, then the public API.
local M = {}

-- SaveStore keys over the files this module writes today (metadata only).
require("overhaul/lib/save/store").registerKeys({
  {key = "world.time", owner = "overhaul_world_sleep", files = {"career/rls_career/time.json"}, phase = "profile", required = true},
})

local LOG_TAG = "overhaul_world_sleep"
local SAVE_FILE = "time.json"
-- Rolling time of day is the overhaul default; players can disable it from the sleep menu.
local DEFAULT_PLAY = true

local originComputerId
local isSleeping = false
local sleepTime = 0
local careerActive = false
local playBeforeSleep
local usedDynamicSleep = false
local sessionTimeOfDay
-- Menu and unload hooks can run without a level, so the environment preset remains optional here.

local function dynamicWeatherControlsClock()
  if not overhaul_world_weather or not overhaul_world_weather.sleepTo then return false end
  if overhaul_world_weather.isExternalOverrideActive and overhaul_world_weather.isExternalOverrideActive() then return false end
  return true
end

local function isPlayEnabled()
  if core_environment and core_environment.getTimeOfDay then
    local tod = core_environment.getTimeOfDay()
    if tod and tod.play ~= nil then
      return tod.play and true or false
    end
  end
  if scenetree.tod then
    -- BeamNG may expose the cycle as play and/or animate.
    if scenetree.tod.play ~= nil then
      return scenetree.tod.play and true or false
    end
    if scenetree.tod.animate ~= nil then
      return scenetree.tod.animate and true or false
    end
  end
  return DEFAULT_PLAY
end

local function getTodTime()
  if core_environment and core_environment.getTimeOfDay then
    local tod = core_environment.getTimeOfDay()
    if tod and tod.time ~= nil then
      return tod.time
    end
  end
  if scenetree.tod and scenetree.tod.time ~= nil then
    return scenetree.tod.time
  end
  return 0
end

-- Writes the SimObject directly: core_environment.setTimeOfDay no-ops while cargo locks the big map.
local function applyTod(time, playValue)
  local playEnabled = nil
  if playValue ~= nil then
    playEnabled = playValue and true or false
  end

  if scenetree.tod then
    if time ~= nil then scenetree.tod.time = time end
    if playEnabled ~= nil then
      scenetree.tod.play = playEnabled
      if scenetree.tod.animate ~= nil then
        scenetree.tod.animate = playEnabled
      end
    end
  end

  if core_environment and core_environment.setTimeOfDay then
    local tod = core_environment.getTimeOfDay() or {}
    if time ~= nil then tod.time = time end
    if playEnabled ~= nil then tod.play = playEnabled end
    core_environment.setTimeOfDay(tod)
  end
end

local function saveTimeData(currentSavePath, writer)
  if not currentSavePath then return end
  if overhaul_world_weather and overhaul_world_weather.getClockState then
    return
  end
  if not scenetree.tod and not (core_environment and core_environment.getTimeOfDay) then
    return
  end

  local dirPath = currentSavePath .. "/career/rls_career"
  if not writer.exists(dirPath) then
    writer.mkdir(dirPath)
  end

  local data = {
    time = getTodTime(),
    play = isPlayEnabled()
  }
  overhaul_career_saveSystem.jsonWriteFileSafe(dirPath .. "/" .. SAVE_FILE, data, true)
end

local function rememberTod()
  if overhaul_world_weather and overhaul_world_weather.getClockState then return end
  sessionTimeOfDay = {time = getTodTime(), play = isPlayEnabled()}
end

local function loadTimeData()
  if overhaul_world_weather and overhaul_world_weather.getClockState then
    return
  end
  if not overhaul_career_career.isActive() then return end
  local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
  if not currentSavePath then return end

  local filePath = currentSavePath .. "/career/rls_career/" .. SAVE_FILE
  local data = sessionTimeOfDay or jsonReadFile(filePath)

  if data and data.time ~= nil then
    local playValue = DEFAULT_PLAY
    if data.play ~= nil then
      playValue = data.play and true or false
    end
    applyTod(data.time, playValue)
  else
    -- No save yet: enable rolling time of day by default.
    applyTod(nil, DEFAULT_PLAY)
  end
end

local function openMenuFromComputer(computerId)
  originComputerId = computerId
  log('D', LOG_TAG, "Open sleep menu from computer: " .. computerId)
  extensions.ui_router.navigate("sleep-menu")
end

local function closeMenu()
  if originComputerId then
    local computer = overhaul_world_facilities.getFacility("computer", originComputerId)
    overhaul_career_garage_computer.openMenu(computer)
  else
    overhaul_career_career.closeAllMenus()
  end
end

local function closeAllMenus()
  overhaul_career_career.closeAllMenus()
end

local function getDayNightCycle()
  if overhaul_world_weather and overhaul_world_weather.getDayNightCycle then
    return overhaul_world_weather.getDayNightCycle()
  end
  return {play = isPlayEnabled(), time = getTodTime()}
end

local function toggleDayNightCycle(toggle)
  if overhaul_world_weather and overhaul_world_weather.toggleDayNightCycle then
    overhaul_world_weather.toggleDayNightCycle(toggle)
    return
  end
  applyTod(nil, toggle and true or false)
  rememberTod()
end

local function sleep(time)
  isSleeping = true
  sleepTime = time
  ui_fadeScreen.start(0.5)
end

local function showClosestGarage()
  local closestGarage = overhaul_career_garage_inventory.getClosestGarage()
  if not closestGarage then return end
  local garagePosition = overhaul_world_facilities.getGaragePosRot(closestGarage)
  if garagePosition then
    overhaul_career_police_playerDriving.showPosition(garagePosition)
  end
end

-- Dynamic weather moves the clock itself when it can; otherwise the sleep writes the time of day.
local function startSleepFade()
  usedDynamicSleep = dynamicWeatherControlsClock()
  if usedDynamicSleep then
    usedDynamicSleep = overhaul_world_weather.sleepTo(sleepTime) == true
  end
  if not usedDynamicSleep then
    playBeforeSleep = isPlayEnabled()
    applyTod(sleepTime, true)
  end
  ui_fadeScreen.stop(0.5)
  showClosestGarage()
end

local function endSleepFade()
  if not usedDynamicSleep then
    -- Restore the player's cycle preference (default rolling if unknown).
    applyTod(nil, playBeforeSleep == nil and DEFAULT_PLAY or playBeforeSleep)
  end
  usedDynamicSleep = false
  isSleeping = false
  rememberTod()
end

M.openMenuFromComputer = openMenuFromComputer
M.sleep = sleep
M.getDayNightCycle = getDayNightCycle
M.toggleDayNightCycle = toggleDayNightCycle
M.closeMenu = closeMenu
M.closeAllMenus = closeAllMenus

local function onOverhaulActive(active)
  careerActive = active
  sessionTimeOfDay = nil
end

local function onWorldReadyState(state)
  if state == 2 and careerActive then
    loadTimeData()
  end
end

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  saveTimeData(currentSavePath, writer)
end

local function onOverhaulComputerAddFunctions(menuData, computerFunctions)
  if not menuData.computerFacility.functions["sleep"] then
    return
  end

  local computerFunctionData = {
    id = "sleep",
    label = "Sleep",
    callback = function()
      openMenuFromComputer(menuData.computerFacility.id)
    end,
    order = 20
  }

  computerFunctions.general[computerFunctionData.id] = computerFunctionData
end

local function onScreenFadeState(state)
  if state == 1 and isSleeping then
    startSleepFade()
  elseif state == 3 and isSleeping then
    endSleepFade()
  end
end

M.onOverhaulComputerAddFunctions = onOverhaulComputerAddFunctions
M.onScreenFadeState = onScreenFadeState
M.onOverhaulActive = onOverhaulActive
M.onWorldReadyState = onWorldReadyState
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile

return M
