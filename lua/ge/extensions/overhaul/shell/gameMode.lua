-- Overhaul game mode: starts, stops and saves the career mode, and keeps the game state in step with it.
-- Owns mode state; career and UI services keep their own lifetimes.
local M = {}

M.dependencies = {
  "overhaul_integration_ownedServices", "overhaul_integration_vanillaServices", "overhaul_vehicles_vehicleServices",
}

local active = false
local starting = false
local stopping = false
local previousState
local profileName
local afterStop
-- Read by per-frame wraps instead of calling isActive(); always equal to it.
local status = { active = false }
M.status = status

local function setActive(value)
  active = value
  status.active = value
end

local function call(module, name, ...)
  if type(module) ~= "table" or type(module[name]) ~= "function" then return false, "unavailable" end
  return module[name](...)
end

local function rememberGameState()
  previousState = core_gamestate.getGameState()
end

local function setModeState()
  core_gamestate.setGameState("overhaul", "overhaul", nil)
end

-- Turns on the mode's UI parts; a part that refuses to enable fails the whole start.
local function refresh()
  if not active or stopping then return end
  setModeState()
  for _, item in ipairs({
    { overhaul_shell_patches, "enableAll" },
    { overhaul_ui_routes, "enable" },
    { overhaul_ui_radial, "enable" },
    { overhaul_ui_pause, "enable" },
  }) do
    if type(item[1]) == "table" and type(item[1][item[2]]) == "function" and call(item[1], item[2]) == false then
      error("shell_activation_failed: " .. item[2])
    end
  end
end

local function restoreState()
  local state = previousState or {}
  core_gamestate.setGameState(state.state or "freeroam", state.appLayout or "freeroam", state.menuItems, state.options)
  previousState = nil
end

-- Turns off every UI part, collects the failures, and then restores the game state either way.
local function cleanup()
  local errors = {}
  for _, item in ipairs({
    { overhaul_ui_pause, "disable" },
    { overhaul_ui_radial, "disable" },
    { overhaul_ui_routes, "disable" },
    { overhaul_shell_patches, "disableAll" },
  }) do
    if type(item[1]) == "table" and type(item[1][item[2]]) == "function" then
      local ok, result = pcall(call, item[1], item[2])
      if not ok then
        errors[#errors + 1] = tostring(result)
      elseif result == false then
        errors[#errors + 1] = "shell_cleanup_failed: " .. item[2]
      end
    end
  end
  restoreState()
  if #errors > 0 then return false, table.concat(errors, "; ") end
  return true
end

local function navigate(route, params)
  return call(ui_router, "navigate", route, params)
end

local function careerStillActive()
  return overhaul_career_career and overhaul_career_career.isActive()
end

local function loadCareerModules()
  if not overhaul_career_saveSystem then extensions.load("overhaul_career_saveSystem") end
  if not overhaul_career_career then extensions.load("overhaul_career_career") end
end

-- Refreshes the UI around the career start, so the mode is visible while the save loads.
local function startCareer(career, saveName, specificAutosave, startingOptions)
  refresh()
  local loaded = career.createOrLoadCareerAndStart(saveName, specificAutosave, startingOptions)
  if loaded == false then error("career_start_failed") end
  refresh()
end

function M.start(saveName, specificAutosave, startingOptions)
  if active or starting or stopping then return false, "already_active" end
  if type(saveName) ~= "string" or saveName == "" then return false, "missing_save_name" end
  loadCareerModules()
  local career = overhaul_career_career
  if type(career) ~= "table" or type(career.createOrLoadCareerAndStart) ~= "function" then
    return false, "career_unavailable"
  end
  if type(career.isActive) == "function" and career.isActive() then return false, "career_already_active" end
  rememberGameState()
  setActive(true)
  starting = true
  profileName = saveName
  local ok, result = pcall(startCareer, career, saveName, specificAutosave, startingOptions)
  starting = false
  if not ok then
    M.stop()
    return false, tostring(result)
  end
  extensions.hook("onOverhaulModeStarted", saveName)
  return true
end

local function finishStop()
  setActive(false)
  local cleaned, cleanupErr = cleanup()
  stopping = false
  profileName = nil
  extensions.hook("onOverhaulModeStopped")
  local callback = afterStop
  afterStop = nil
  if cleaned and callback then callback() end
  return cleaned, cleanupErr
end

-- Returns "save_pending" when the career cannot stop yet because its save is still being written.
function M.stop()
  if stopping then return false, "save_pending" end
  if not active then return true end
  stopping = true
  local ok, result = pcall(call, overhaul_career_career, "deactivateCareer", false)
  if not stopping then return true end
  if ok and result == false and careerStillActive() then
    return false, "save_pending"
  end
  local cleaned, cleanupErr = finishStop()
  if not ok then return false, tostring(result) end
  return cleaned, cleanupErr
end

-- The profile screens start the career directly; adopt it as the active mode.
local function adopt()
  if active or starting or stopping then return end
  rememberGameState()
  setActive(true)
  profileName = overhaul_career_saveSystem and type(overhaul_career_saveSystem.getCurrentSaveSlot) == "function"
    and overhaul_career_saveSystem.getCurrentSaveSlot() or nil
  extensions.hook("onOverhaulModeStarted", profileName)
end

function M.isActive()
  return active
end

function M.save()
  if not active then return false end
  return call(overhaul_career_saveSystem, "saveCurrent", false, { force = true, playSuccessSound = true })
end

function M.load()
  if not active then return false end
  local ok, err = M.stop()
  if not ok then
    if err == "save_pending" then afterStop = function() navigate("overhaul.profiles") end end
    return false, err
  end
  return navigate("overhaul.profiles")
end

function M.openPhone()
  if not active then return false end
  return navigate("overhaul.phone")
end

function M.openComputer()
  if not active then return false end
  return navigate("overhaul.computer")
end

function M.mainMenu()
  local ok, err = M.stop()
  if not ok then
    if err == "save_pending" then afterStop = function() M.mainMenu() end end
    return false, err
  end
  if type(returnToMainMenu) == "function" then returnToMainMenu() else navigate("menu") end
  return ok, err
end

function M.onOverhaulActive(value)
  if value then
    adopt()
    refresh()
  elseif stopping then
    finishStop()
  elseif active and not starting then
    M.stop()
  end
end

function M.onOverhaulBeforeCareerActivate()
  adopt()
  refresh()
end

M.onWorldReadyState = function(worldReadyState)
  if worldReadyState == 2 then refresh() end
end

-- Vanilla drift missions restore career/career when career is active and freeroam/freeroam otherwise.
local driftLayout = false
M.onGameStateUpdate = function(gameState)
  if not active or stopping or type(gameState) ~= "table" then
    driftLayout = false
    return
  end
  if gameState.appLayout == "driftMission" then
    driftLayout = true
    return
  end
  local afterDrift = driftLayout and gameState.state == "freeroam" and gameState.appLayout == "freeroam"
  driftLayout = false
  if afterDrift or gameState.state == "career" or (gameState.state == "overhaul" and gameState.appLayout == "career") then
    setModeState()
  end
end

M.onSerialize = function() return { active = active, profileName = profileName, previousState = previousState } end

M.onDeserialized = function(data)
  if data and data.active then
    setActive(true)
    profileName = data.profileName
    previousState = data.previousState
    refresh()
  end
end

M.onExtensionUnloaded = M.stop

return M
