-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Owns module activation, retries and map travel for one career session.
-- Read config, health and starting choices, then module lifecycle, travel, activation and the per-career API.
local recordArrival = require("overhaul/lib/progression/logbookFeed").register("overhaul.mapArrived", {
  title = "Arrived on a new map", label = "Travel", icon = "mapPoint"
}, "career/start/transitions.lua")

local M = {}

-- Requires ----------------------------------------------------------------------------------------

local lifecycle = require('overhaul/lib/lifecycle/host')
local devScope = require('overhaul/lib/lifecycle/scopes/dev')
local optional = require('overhaul/lib/platform/optional')
local capabilities = require('overhaul/lib/platform/capabilities')
local difficultyModePersist = require('overhaul/lib/career/difficultyPersist')
local startingModes = require('overhaul/career/start/startingModes')
local careerManifest = require('overhaul/lib/career/manifest')
local levelData = require('overhaul/lib/world/levelData')

-- Config ------------------------------------------------------------------------------------------

local careerModuleDirectory = '/lua/ge/extensions/'
local saveFile = "general.json"
local LEVEL_SWITCH_SAVE_TIMEOUT = 30
local MAX_ACTIVATION_RETRIES = 1
local LEVEL_START_LOADING_TAG = "overhaulCareerLevelStart"
local CHEATS_STARTING_CAPITAL = 1e12
local requiredCareerModules = {
  "overhaul_career_garage_inventory",
  "overhaul_career_economy_payment",
  "overhaul_career_permissions",
  "overhaul_career_economy_playerAttributes",
  "overhaul_career_garage_switchMap",
}

-- Career state belongs to the instance factories below; these module-level helpers retain no session.
-- Activation health -------------------------------------------------------------------------------

local function getCareerPlayerIdentity()
  local playerVehicleId = be:getPlayerVehicleID(0)
  local walking = gameplay_walk.isWalking() or false
  if walking and playerVehicleId and playerVehicleId >= 0 then
    return true, "walking", playerVehicleId
  end
  if playerVehicleId and playerVehicleId >= 0 and overhaul_career_garage_inventory then
    local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(playerVehicleId)
    if inventoryId ~= nil then
      return true, "inventory", playerVehicleId, inventoryId
    end
  end
  return false, nil, playerVehicleId
end

local function ensureCareerPlayerIdentity()
  local valid = getCareerPlayerIdentity()
  if valid then return true end

  -- Inventory can finish an empty spawn list before walking exists after a map handoff.
  spawn.preventPlayerSpawning = nil
  local recovery = levelData.recoverySpawn()
  if not recovery then
    log('W', 'career', 'No recoverySpawn for this level; using the engine/level default spawn')
  end
  gameplay_walk.setWalkingMode(true, recovery and recovery.pos, recovery and recovery.rot, true)
  return getCareerPlayerIdentity()
end

-- An explicit destination wins over the save, then the installed map catalog supplies the default.
local function resolveCareerLevel(selected, saved, session, transition)
  local level = selected or saved or levelData.defaultMap()
  if not level then
    session.lastActivationError = 'No default career map configured'
    log('E', 'career', session.lastActivationError)
    lifecycle.finish(transition, 'failed')
  end
  return level
end

local function missingRequiredModules()
  local missingModules = {}
  for _, moduleName in ipairs(requiredCareerModules) do
    local loaded = extensions.isExtensionLoaded(moduleName)
    if not loaded or optional(moduleName) == nil then
      table.insert(missingModules, moduleName)
    end
  end
  return missingModules
end

local function getCareerActivationHealth(session)
  local missingModules = missingRequiredModules()
  local gameState = core_gamestate.state and core_gamestate.state.state or nil
  local playerIdentityValid, playerIdentity, playerVehicleId, inventoryId = getCareerPlayerIdentity()
  local profile, savePath = overhaul_career_saveSystem.getCurrentProfile()
  local savedCareer = savePath and jsonReadFile(savePath .. "/career/" .. saveFile) or nil
  local health = {
    ok = session.active and gameState == "overhaul" and session.actionsBlocked and #missingModules == 0 and playerIdentityValid,
    careerActive = session.active,
    currentLevel = getCurrentLevelIdentifier(),
    gameState = gameState,
    inputRestrictionsActive = session.actionsBlocked,
    playerIdentityValid = playerIdentityValid,
    playerIdentity = playerIdentity,
    playerVehicleId = playerVehicleId,
    playerInventoryId = inventoryId,
    missingModules = missingModules,
    profile = profile,
    savedLevel = savedCareer and savedCareer.level or nil,
    lastActivationError = session.lastActivationError,
  }
  return health
end

-- Starting settings -------------------------------------------------------------------------------

local function newActivationSettings(context)
  -- State -----------------------------------------------------------------------------------------

  local session, start = context.session, context.start

  -- Helpers ---------------------------------------------------------------------------------------

  local function applyPendingDifficulty()
    if start.pendingDifficultyMode then
      overhaul_career_economy_difficultyMode.setMode(start.pendingDifficultyMode, false, start.pendingDifficultyOverrides)
      start.pendingDifficultyMode = nil
      start.pendingDifficultyOverrides = nil
    end
    context.publish("hardcoreMode", overhaul_career_economy_difficultyMode.isHardcoreMode() == true)
  end

  local function applyPendingCheats()
    -- Cheats must be visible before capital and onOverhaulActive seed their state.
    if start.pendingCheatsMode then overhaul_career_economy_cheats.enableCheatsMode(true) end
    start.pendingCheatsMode = nil
  end

  local function startPendingChallenge()
    local challengeStarted = false
    if context.getPublic("pendingChallengeId") then
      challengeStarted = overhaul_career_challengeModes.startChallenge(context.getPublic("pendingChallengeId")) and true or false
      if not challengeStarted then
        log("W", "career", "Challenge " .. tostring(context.getPublic("pendingChallengeId")) .. " failed to start; using normal starting capital")
      end
      context.publish("pendingChallengeId", nil)
    end
    return challengeStarted
  end

  local function applyStartingCapital()
    overhaul_career_economy_economyAdjusterPolicy.rebuild()
    if not session.isNewSave then return end
    local startingCapital = overhaul_career_economy_difficultyMode.getStartingCapital()
    if overhaul_career_economy_cheats.isCheatsMode() then startingCapital = CHEATS_STARTING_CAPITAL end
    overhaul_career_economy_playerAttributes.setAttributes({money = startingCapital}, {label = "Starting Capital", tags = {"startingFunds"}, finance = {category = "starting_funds", vehicleRelated = false}})
  end

  local function onOverhaulModulesActivated(alreadyInLevel)
    context.setupActions()
    applyPendingDifficulty()
    applyPendingCheats()
    if not startPendingChallenge() then applyStartingCapital() end
    session.isNewSave = false
  end

  local function restoreStartingOptions(careerData, newSave)
    local savedStartingOptions = (type(careerData.startingOptions) == "table") and careerData.startingOptions or {}
    if newSave and type(start.pendingStartingOptions) == "table" then
      context.publish("startingOptions", deepcopy(start.pendingStartingOptions))
    else
      context.publish("startingOptions", deepcopy(savedStartingOptions))
    end
    start.pendingStartingOptions = nil
  end

  local function restoreGaragePreference(careerData, newSave)
    start.startingGaragePreference = newSave and start.pendingStartingGaragePreference or
      startingModes.normalizeStartingGaragePreference(careerData.startingGarageMode, careerData.startingGarageId)
    context.publish("startingGaragePreference", deepcopy(start.startingGaragePreference))
  end

  local function restoreHardcoreMode(savePath)
    -- Module activation must see a consistent difficulty flag on its first tick.
    if start.pendingDifficultyMode then
      context.publish("hardcoreMode", start.pendingDifficultyMode == "hardcore")
    else
      local savedDifficulty = difficultyModePersist.readModeFromSave(savePath)
      context.publish("hardcoreMode", savedDifficulty == "hardcore")
    end
  end

  local function restoreStartingState(careerData, savePath, newSave)
    restoreStartingOptions(careerData, newSave)
    restoreGaragePreference(careerData, newSave)
    session.boughtStarterVehicle = true
    session.organizationInteraction = careerData.organizationInteraction or {}
    restoreHardcoreMode(savePath)
    context.publish("tutorialEnabled", false)
    -- A test drive may have disabled autosave before the previous career ended.
    context.module.setAutosaveEnabled(true)
    log("I", "", "Tutorial for career disabled.")
  end

  return {applyLoadedModes = onOverhaulModulesActivated, restoreStartingState = restoreStartingState}
end

-- Freeroam start ----------------------------------------------------------------------------------

-- Start outside hooks so unloading photomode cannot leave stale callbacks in the current loop.
local function startFreeroamOutsideHookLoop(levelPath, callback)
  local function begin()
    freeroam_freeroam.startFreeroam(levelPath, nil, false, nil, callback)
    if core_gamestate.getLoadingStatus(LEVEL_START_LOADING_TAG) then
      core_gamestate.requestExitLoadingScreen(LEVEL_START_LOADING_TAG)
    end
  end
  local noUi = type(cmdArgs) == "table" and tableFindKey(cmdArgs, "-noui")
  if headless_mode or noUi then return begin() end
  core_gamestate.requestEnterLoadingScreen(LEVEL_START_LOADING_TAG, begin)
end
-- Module lifecycle --------------------------------------------------------------------------------

local function newModuleLifecycle(session, onOverhaulModulesActivated)
  -- State -----------------------------------------------------------------------------------------

  -- Mod changes invalidate the instance's discovery cache before its next activation.
  local discoveredModules = nil
  local demandModules = {}

  -- Helpers ---------------------------------------------------------------------------------------

  local function careerModules()
    if not discoveredModules then
      discoveredModules, demandModules = careerManifest.discoverModules()
      demandModules = demandModules or {}
    end
    return discoveredModules
  end

  -- Existing saved data still restores at activation; unused owners can wait for a capability request.
  local function needsStartup(path)
    local policy = demandModules[path]
    if not policy then return true end
    local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
    for _, file in ipairs(policy.saveFiles) do
      if savePath and FS:fileExists(savePath .. "/" .. file) then return true end
    end
    return false
  end

  -- Dev checkouts report current manifest coverage without changing release discovery or dev gates.
  local function warnUnlistedCareerModules()
    if not devScope.isKeyValid() then return end
    local unlisted, missing, problems = careerManifest.validateCoverage(
      FS:findFiles(careerModuleDirectory, '*.lua', -1, true, false), careerModuleDirectory)
    for _, path in ipairs(unlisted) do log("W", "career", "Career extension needs one manifest in " .. careerManifest.modulesDir .. ": " .. path) end
    for _, path in ipairs(missing) do log("W", "career", "Career manifest has no extension file: " .. path) end
    for _, message in ipairs(problems) do log("W", "career", message) end
  end

  -- Loads and activates the career's modules, or unloads them when the career stops.
  local function toggleCareerModules(active, alreadyInLevel)
    capabilities.reset()
    -- Unload hooks and failed activation must never leave debug panels holding retired owners.
    session.debugModules = {}
    if not active then
      for _, name in ipairs(session.modules) do
        -- Otherwise the next level load would bring them back outside the career.
        setExtensionUnloadMode(name, "auto")
        extensions.unload(name)
      end
      table.clear(session.modules)
      return
    end

    table.clear(session.modules)
    local extensionFiles = {}
    local withDebugPanels = devScope.debugPanelsEnabled()
    for _, path in ipairs(careerModules()) do
      if withDebugPanels or not careerManifest.isDebugModule(path) then
        if needsStartup(path) then table.insert(extensionFiles, path) end
        table.insert(session.modules, extensions.luaPathToExtName(path))
      end
    end
    warnUnlistedCareerModules()
    local startupModules = {}
    for _, path in ipairs(extensionFiles) do startupModules[#startupModules + 1] = extensions.luaPathToExtName(path) end
    extensions.load(startupModules)
    extensions.disableSerialization(session.modules)

    -- prevent these extensions from being unloaded when switching level
    for _, extension in ipairs(extensionFiles) do
      setExtensionUnloadMode(extensions.luaPathToExtName(extension), "manual")
    end
    -- Career statistics must be ready before any module activates.
    if not overhaul_integration_services_statistic then extensions.load("overhaul_integration_services_statistic") end
    overhaul_integration_services_statistic.ensureCareerReady()

    -- Inspect globals: indexing extensions would acquire deferred owners.
    for _, moduleName in ipairs(session.modules) do
      local mod = optional(moduleName)
      if mod and mod.onCareerActivated then
        mod.onCareerActivated()
      end
    end
    onOverhaulModulesActivated(alreadyInLevel)
    extensions.hook("onOverhaulModulesActivated", alreadyInLevel)
    for _, moduleName in ipairs(session.modules) do
      -- (a module that failed to load is absent: skip it rather than stop the activation)
      local mod = optional(moduleName)
      if mod and mod.debugName then
        table.insert(session.debugModules, mod)
      end
    end
    table.sort(session.debugModules, function(a,b) return a.debugOrder < b.debugOrder end)
  end

  local function forgetDiscoveredModules()
    require('overhaul/lib/platform/manifests').invalidate()
    capabilities.reset()
    discoveredModules = nil
  end
  return toggleCareerModules, forgetDiscoveredModules
end

-- Level travel ------------------------------------------------------------------------------------

local function newTravelLifecycle(context, session)
  -- State -----------------------------------------------------------------------------------------

  local travel = nil

  -- Helpers ---------------------------------------------------------------------------------------

  local function getLevelSwitchState()
    if session.levelSwitch then
      return deepcopy(session.levelSwitch)
    end
    return {
      phase = "idle",
      lastResult = deepcopy(session.lastLevelSwitchResult),
    }
  end

  local function closeCareerLoadingScreens()
    for _, loadingName in ipairs({"careerActivate", "careerLoading"}) do
      if core_gamestate.getLoadingStatus(loadingName) then
        core_gamestate.requestExitLoadingScreen(loadingName)
      end
    end
  end

  local function failLevelSwitch(reason)
    reason = tostring(reason or "Unknown map travel failure")
    local failedTransaction = session.levelSwitch and deepcopy(session.levelSwitch) or {}
    failedTransaction.phase = "failed"
    failedTransaction.lastError = reason
    session.lastLevelSwitchResult = failedTransaction
    session.levelSwitch = nil
    session.switchLevel = nil
    lifecycle.finish(travel, "failed", {reason = reason})
    closeCareerLoadingScreens()
    simTimeAuthority.pause(false)

    if session.active then
      context.setupActions()
      context.closeAllMenus()
    else
      -- A failed destination activation must remain gated instead of becoming freeroam.
      spawn.preventPlayerSpawning = true
      context.blockInputActions(true)
      if extensions.ui_router then
        extensions.ui_router.navigate("overhaul.profiles")
      end
    end

    guihooks.trigger("toastrMsg", {
      type = "error",
      title = "Map travel failed",
      msg = reason,
    })
    log("E", "career", "Map travel failed: " .. reason)
  end

  local function completeLevelSwitch()
    if not session.levelSwitch then return end
    local completed = deepcopy(session.levelSwitch)
    completed.phase = "completed"
    completed.completedLevel = getCurrentLevelIdentifier()
    completed.lastError = nil
    session.lastLevelSwitchResult = completed
    session.levelSwitch = nil
    session.switchLevel = nil
    lifecycle.finish(travel, "done")
    return completed
  end

  local function finalizeSuccessfulCareerActivation()
    local completedSwitch = completeLevelSwitch()
    -- Release loading ownership before third-party hooks so a failed hook cannot hide a healthy destination.
    closeCareerLoadingScreens()
    context.finishLoadingIntro({ setCamera = true })
    if completedSwitch then
      local map = require("overhaul/lib/world/levelData").getMap(completedSwitch.completedLevel)
      recordArrival({name = map and map.label or completedSwitch.completedLevel})
      local hookOk, hookError = xpcall(function()
        extensions.hook("onOverhaulMapTravelCompleted", deepcopy(completedSwitch))
      end, debug.traceback)
      if not hookOk then
        log("E", "career", "Map travel completion hook failed:\n" .. tostring(hookError))
      end
    end
    return completedSwitch
  end

  local function startLevelSwitchSaveWatchdog(sequence)
    core_jobsystem.create(function(job)
      job.sleep(LEVEL_SWITCH_SAVE_TIMEOUT)
      if session.levelSwitch and session.levelSwitch.sequence == sequence and session.levelSwitch.phase == "saving" then
        failLevelSwitch("Career save did not finish within " .. tostring(LEVEL_SWITCH_SAVE_TIMEOUT) .. " seconds")
      end
    end)
  end

  local function beginTravel(source, destination)
    travel = lifecycle.begin("travel", {source = source, destination = destination})
  end

  local function phaseTravel(phase)
    lifecycle.phase(travel, phase)
  end

  return {
    getLevelSwitchState = getLevelSwitchState,
    closeCareerLoadingScreens = closeCareerLoadingScreens,
    failLevelSwitch = failLevelSwitch,
    finalizeSuccessfulCareerActivation = finalizeSuccessfulCareerActivation,
    startLevelSwitchSaveWatchdog = startLevelSwitchSaveWatchdog,
    begin = beginTravel,
    phase = phaseTravel,
  }
end

-- Activation --------------------------------------------------------------------------------------

local function beginActivation(session, levelToLoad)
  local transition = lifecycle.begin("activate", {level = levelToLoad, retry = session.activationRetryPending})
  local isActivationRetry = session.activationRetryPending
  session.activationRetryPending = false
  if not isActivationRetry then
    session.activationRetryCount = 0
    session.activationRetrySequence = session.activationRetrySequence + 1
    session.lastActivationError = nil
  end
  return transition
end

local function findActivatableProfile(session, travel, transition)
  local profile, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if not profile then
    session.startInProgress = false
    travel.closeCareerLoadingScreens()
    lifecycle.finish(transition, "refused")
    return nil, nil, "noProfile"
  end
  local report = overhaul_career_saveMigration.getLegacySavePreflight(profile, savePath and savePath:match("([^/\\]+)$"))
  if report.requiresMigration then
    session.startInProgress = false
    travel.closeCareerLoadingScreens()
    overhaul_career_saveMigration.requestLegacySaveMigration(report)
    lifecycle.finish(transition, "refused")
    return nil, nil, "migration"
  end
  return profile, savePath
end

local function newCareerActivation(context, session, settings, toggleCareerModules, travel, getActivationHealth)
  -- Returns the reason the activated career is not usable, or nil. Sets health.ok to false on a mismatch.
  local function checkActivatedHealth(health)
    if session.levelSwitch and getCurrentLevelIdentifier() ~= session.levelSwitch.destination then
      health.ok = false
      return string.format(
        "Destination mismatch after activation (expected %s, got %s)",
        tostring(session.levelSwitch.destination), tostring(getCurrentLevelIdentifier()))
    elseif session.levelSwitch and health.savedLevel ~= session.levelSwitch.destination then
      health.ok = false
      return string.format(
        "Saved career level mismatch after activation (expected %s, got %s)",
        tostring(session.levelSwitch.destination), tostring(health.savedLevel))
    elseif not health.ok then
      return "Career activation health check failed: " .. dumps(health)
    end
    return nil
  end

  -- Puts the modules in the level, then reports whether the activation succeeded.
  local function loadModulesInLevel(attempt, alreadyInLevel)
    session.active = true
    lifecycle.advance("career", "activated")
    return xpcall(function()
      toggleCareerModules(true, alreadyInLevel)
      context.initAfterLevelLoad(attempt.newSave)
    end, debug.traceback)
  end

  -- Unloads the half-activated modules and stops the career's input and publishes.
  local function rollbackActivation()
    context.publish("onUpdate", nil)
    local rollbackOk, rollbackError = xpcall(function()
      toggleCareerModules(false)
    end, debug.traceback)
    if not rollbackOk then
      log("E", "career", "Career activation rollback failed:\n" .. tostring(rollbackError))
    end
    session.active = false
    lifecycle.advance("career", "activationFailed")
    context.blockInputActions(true)
  end

  -- A newer activation invalidates the delayed retry.
  local function scheduleActivationRetry(attempt)
    if session.activationRetryCount >= MAX_ACTIVATION_RETRIES then return false end
    session.activationRetryCount = session.activationRetryCount + 1
    local retrySequence = session.activationRetrySequence
    if session.levelSwitch then
      session.levelSwitch.phase = "activationRetry"
      session.levelSwitch.retryCount = session.activationRetryCount
      session.levelSwitch.lastError = session.lastActivationError
    end
    log("W", "career", string.format("Retrying career activation (%d/%d)", session.activationRetryCount, MAX_ACTIVATION_RETRIES))
    lifecycle.finish(attempt.transition, "failed")
    core_jobsystem.create(function(job)
      job.sleep(0.5)
      if retrySequence ~= session.activationRetrySequence or session.active then return end
      session.activationRetryPending = true
      attempt.activate(false, attempt.levelToLoad)
    end)
    return true
  end

  -- Gives up on this career: the level switch fails, or the player is sent back to the profiles.
  local function abandonActivation(attempt)
    session.startInProgress = false
    if session.levelSwitch then
      travel.failLevelSwitch(session.lastActivationError)
    else
      travel.closeCareerLoadingScreens()
      spawn.preventPlayerSpawning = true
      if extensions.ui_router then
        extensions.ui_router.navigate("overhaul.profiles")
      end
      guihooks.trigger("toastrMsg", {
        type = "error",
        title = "Career failed to load",
        msg = "Career modules could not be activated. See the log for details.",
      })
    end
    lifecycle.finish(attempt.transition, "failed")
    return false
  end

  local function failActivation(attempt, activationError)
    session.lastActivationError = tostring(activationError)
    log('E', 'career', 'Career activation failed:\n' .. session.lastActivationError)
    rollbackActivation()
    if scheduleActivationRetry(attempt) then return false end
    return abandonActivation(attempt)
  end

  local function succeedActivation(attempt)
    session.activationRetryCount = 0
    session.lastActivationError = nil
    travel.finalizeSuccessfulCareerActivation()
    lifecycle.finish(attempt.transition, "done")
    extensions.hook("onOverhaulActivationReady", deepcopy(getActivationHealth()))
    return true
  end

  local function finishActivateInLevel(attempt, alreadyInLevel)
    local activationOk, activationError = loadModulesInLevel(attempt, alreadyInLevel)
    if activationOk then
      ensureCareerPlayerIdentity()
      local health = getActivationHealth()
      activationError = checkActivatedHealth(health)
      activationOk = health.ok
    end
    if activationOk then
      return succeedActivation(attempt)
    end
    return failActivation(attempt, activationError)
  end

  -- Enter freeroam before activation so mission-end teardown cannot erase the pending load.
  local function deferActivationUntilLevelReady(removeVehicles, levelToLoad, currentLevel)
    session.pendingProfileLoad = {
      removeVehicles = removeVehicles,
      levelToLoad = levelToLoad,
    }
    -- Keep the start loading gate until world-ready activation takes over.
    if core_groundMarkers then core_groundMarkers.setPath(nil) end
    spawn.preventPlayerSpawning = true
    freeroam_freeroam.resetSpawningOptions()
    freeroam_freeroam.spawningOptionsHelper.trafficMode = "disabled"
    log("I", "", string.format("Deferring career activate until level ready: %s -> %s", tostring(currentLevel), tostring(levelToLoad)))
    freeroam_freeroam.startFreeroam(path.getPathLevelMain(levelToLoad), nil, false, nil, function()
      server.fadeoutLoadingScreen()
    end)
  end

  -- The careerActivate screen covers the load; the marker route is cleared before the modules load.
  local function enterActivationLoading()
    if not core_gamestate.getLoadingStatus('careerActivate') then
      core_gamestate.requestEnterLoadingScreen('careerActivate')
    end
    extensions.hook("onOverhaulBeforeCareerActivate")
    if core_groundMarkers then core_groundMarkers.setPath(nil) end
  end

  -- Keep career inactive until the main-menu level load has finished.
  local function startFromMainMenu(attempt)
    spawn.preventPlayerSpawning = true
    freeroam_freeroam.resetSpawningOptions()
    freeroam_freeroam.spawningOptionsHelper.trafficMode = "disabled" -- the career's driving module sets traffic up once active
    startFreeroamOutsideHookLoop(path.getPathLevelMain(attempt.levelToLoad), function()
      finishActivateInLevel(attempt, false)
      server.fadeoutLoadingScreen()
    end)
  end

  -- Start of one activation attempt. A retry comes back here with activationRetryPending set.
  local function activateCareer(removeVehicles, levelToLoad)
    if session.active then return end
    local transition = beginActivation(session, levelToLoad)

    local _, savePath, refusal = findActivatableProfile(session, travel, transition)
    if refusal == "noProfile" then return end
    if refusal == "migration" then return false end
    if removeVehicles == nil then
      removeVehicles = true
    end

    local careerData = (savePath and jsonReadFile(savePath .. "/career/" .. saveFile)) or {}
    levelToLoad = resolveCareerLevel(levelToLoad, careerData.level, session, transition)
    if not levelToLoad then return false end

    local currentLevel = getCurrentLevelIdentifier()
    if currentLevel and currentLevel ~= levelToLoad then
      deferActivationUntilLevelReady(removeVehicles, levelToLoad, currentLevel)
      lifecycle.finish(transition, "deferred")
      return
    end

    enterActivationLoading()

    log("I", "Loading career from " .. savePath .. "/career/" .. saveFile)
    local newSave = tableIsEmpty(careerData)
    session.isNewSave = newSave
    settings.restoreStartingState(careerData, savePath, newSave)

    local attempt = {transition = transition, levelToLoad = levelToLoad, newSave = newSave, activate = activateCareer}
    if currentLevel then
      if removeVehicles then
        core_vehicles.removeAll()
      else
        context.removeNonTrafficVehicles()
      end
      return finishActivateInLevel(attempt, true)
    end

    startFromMainMenu(attempt)
  end

  return activateCareer
end

-- Travel hooks ------------------------------------------------------------------------------------

local function newTravelHooks(context, session, start, toggleCareerModules, activateCareer, travel)

  -- Stops the career: its modules unload, its pending choices clear, and the HUD tasklist hides.
  local function deactivateCareer(saveCareer)
    if not session.active then return end
    context.publish("onUpdate", nil)
    -- A stopped career retires its handoff recovery and welcome splash.
    session.loadingSplashToken = nil
    if session.loadingIntroToken then log("I", "career", "play handoff recovery retired: career stopped") end
    session.loadingIntroToken = nil
    session.active = false
    lifecycle.advance("career", "stopped")
    session.loadingIntroStarted = false
    start.pendingStartingOptions = nil
    start.pendingStartingGaragePreference = nil
    start.pendingCareerStartMode = nil
    start.pendingCheatsMode = nil
    start.pendingDifficultyMode = nil
    start.pendingDifficultyOverrides = nil
    start.pendingSandboxEconomyProfile = nil
    start.pendingSandboxXpProfile = nil
    context.publish("pendingChallengeId", nil)
    context.publish("pendingCareerStartMode", nil)
    context.publish("pendingSandboxEconomyProfile", nil)
    context.publish("pendingSandboxXpProfile", nil)
    context.publish("cheatsMode", false)
    context.publish("hardcoreMode", false)
    start.startingGaragePreference = nil
    context.publish("startingGaragePreference", nil)
    toggleCareerModules(false)
    context.blockInputActions(false)
    gameplay_rawPois.clear()
    overhaul_ui_recoveryPrompt.setDefaultsForFreeroam()
    extensions.hook("onOverhaulActive", false)
    guihooks.trigger("HideCareerTasklist")
  end

  -- Checks that a map travel can start now; returns the refusal reason, or nil.
  local function travelRefusal(nextLevel)
    if type(nextLevel) ~= "string" or nextLevel == "" then
      return "A destination level is required"
    end
    if not session.active then
      return "Career is not active"
    end
    local blockMsg = overhaul_career_work_employment.getMapTravelBlockMessage()
    if blockMsg then
      ui_message(blockMsg, 8, "warning")
      return blockMsg
    end
    if session.levelSwitch then
      return "Map travel is already in progress"
    end
    if nextLevel == getCurrentLevelIdentifier() then
      return "Already in the requested destination"
    end
    local compatibleMaps = overhaul_world_maps.getCompatibleMaps() or nil
    if type(compatibleMaps) ~= "table" or compatibleMaps[nextLevel] == nil then
      return "Destination is not registered as a compatible career map: " .. nextLevel
    end
    if not FS:directoryExists("/levels/" .. nextLevel) then
      return "Destination level is unavailable: " .. nextLevel
    end
    return nil
  end

  -- Starts a map travel: the career saves first, and the level changes once the save finishes.
  local function switchCareerLevel(nextLevel)
    local refusal = travelRefusal(nextLevel)
    if refusal then
      return false, refusal
    end

    local currentLevel = getCurrentLevelIdentifier()
    session.levelSwitchSequence = session.levelSwitchSequence + 1
    session.levelSwitch = {
      source = currentLevel,
      destination = nextLevel,
      phase = "saving",
      retryCount = 0,
      sequence = session.levelSwitchSequence,
      startedAt = os.time(),
    }
    session.switchLevel = nextLevel
    session.lastLevelSwitchResult = {phase = "inProgress"}
    travel.begin(currentLevel, nextLevel)

    extensions.hook("onOverhaulBeforeCareerLevelSwitch", currentLevel, nextLevel)
    travel.startLevelSwitchSaveWatchdog(session.levelSwitchSequence)
    -- Leaving the map requires a checkpoint even when periodic autosaves are disabled.
    require("overhaul/lib/save/store").bind(overhaul_career_saveSystem).request("career:levelSwitch", nil, {force = true, manual = true})
    overhaul_career_saveSystem.flushSaveForExit(function() context.module.onOverhaulSaveFinished() end)
    return true
  end

  -- The destination world is ready: reload the modules for the new map.
  local function onWorldReadyState(state)
    if state ~= 2 then return end

    if session.levelSwitch then
      session.levelSwitch.phase = "activating"
      travel.phase("activating")
      if session.active then
        -- Handoffs without onClientEndMission must still retire the source map's modules.
        log("W", "career", "Career remained active through map handoff; reloading destination modules")
        deactivateCareer(false)
        context.blockInputActions(true)
      end
      activateCareer(false, session.levelSwitch.destination)
    end

    -- Mid-session (or deferred) profile load: level is up, now activate on the new save.
    if session.pendingProfileLoad then
      local opts = session.pendingProfileLoad
      session.pendingProfileLoad = nil
      if not session.active then
        activateCareer(opts.removeVehicles, opts.levelToLoad)
      end
    end
  end

  -- The save is written: the level change can now load.
  local function onOverhaulSaveFinished()
    if session.levelSwitch and session.levelSwitch.phase == "saving" then
      if overhaul_career_saveSystem.isSavePending() then return end
      session.levelSwitch.phase = "loadingLevel"
      travel.phase("loadingLevel")
      if not core_gamestate.getLoadingStatus("careerLoading") then core_gamestate.requestEnterLoadingScreen("careerLoading") end
      local sequence = session.levelSwitch.sequence
      core_jobsystem.create(function(job)
        job.sleep(0.01)
        if not session.levelSwitch or session.levelSwitch.sequence ~= sequence then return end
        if session.active then
          deactivateCareer(false)
          -- Keep reset/teleport/free-roam actions gated while the destination loads.
          context.blockInputActions(true)
        end
        spawn.preventPlayerSpawning = true
        freeroam_freeroam.startFreeroam(path.getPathLevelMain(session.levelSwitch.destination), nil, false, nil, function()
          server.fadeoutLoadingScreen()
        end)
      end)
    end
  end

  local function onOverhaulSaveFailed(savePath)
    if session.levelSwitch and session.levelSwitch.phase == "saving" then
      travel.failLevelSwitch("Career save failed before map travel" .. (savePath and (": " .. tostring(savePath)) or ""))
    end
  end

  return {
    deactivateCareer = deactivateCareer,
    switchCareerLevel = switchCareerLevel,
    worldReady = onWorldReadyState,
    saveFinished = onOverhaulSaveFinished,
    saveFailed = onOverhaulSaveFailed,
  }
end

-- Per-career API ----------------------------------------------------------------------------------

M.startFreeroamOutsideHookLoop = startFreeroamOutsideHookLoop

-- Each group retains this career instance's session, so delayed callbacks keep their original owner.
function M.newCareer(ctx)
  -- State -----------------------------------------------------------------------------------------

  local context, session, start = ctx, ctx.session, ctx.start

  -- Helpers ---------------------------------------------------------------------------------------

  local function getActivationHealth() return getCareerActivationHealth(session) end
  local settings = newActivationSettings(ctx)
  local onOverhaulModulesActivated = settings.applyLoadedModes
  local toggleCareerModules, forgetDiscoveredModules = newModuleLifecycle(session, onOverhaulModulesActivated)
  local travel = newTravelLifecycle(context, session)
  local activateCareer = newCareerActivation(context, session, settings, toggleCareerModules, travel, getActivationHealth)
  local hooks = newTravelHooks(context, session, start, toggleCareerModules, activateCareer, travel)
  return {
    toggleCareerModules = toggleCareerModules,
    getActivationHealth = getActivationHealth,
    getLevelSwitchState = travel.getLevelSwitchState,
    finalizeSuccessfulCareerActivation = travel.finalizeSuccessfulCareerActivation,
    activateCareer = activateCareer,
    deactivateCareer = hooks.deactivateCareer,
    switchCareerLevel = hooks.switchCareerLevel,
    worldReady = hooks.worldReady,
    saveFinished = hooks.saveFinished,
    saveFailed = hooks.saveFailed,
    modsChanged = forgetDiscoveredModules,
  }
end

return M
