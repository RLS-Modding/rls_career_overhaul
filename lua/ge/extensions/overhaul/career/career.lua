-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/career.lua (BeamNG 0.40).
-- Owns career session state, input restrictions, loading finalization and public entry points.
-- Read configuration, state, helpers, start parts, lifecycle, public API and game hooks in that order.

local M = {}
local modIdentity = require("overhaul/lib/platform/modIdentity")

-- Requires ---------------------------------------------------------------------------------------

local capabilities = require("overhaul/lib/platform/capabilities")
local optional = require("overhaul/lib/platform/optional")
local uiOwners = require("overhaul/lib/ui/ownerCatalog")

local imgui = ui_imgui
local startingModes = require('overhaul/career/start/startingModes')
local transitions = require('overhaul/career/start/transitions')
local routerTransitions = require("ge/extensions/ui/router/managers/transitionManager")
local lifecycle = require('overhaul/lib/lifecycle/host')
local saveSlots = require('overhaul/career/start/saveSlots')
local profileCards = require('overhaul/career/start/profileCards')
local profileReadModels = require('overhaul/lib/career/profileReadModels')

M.dependencies = {'overhaul_career_saveSystem', 'core_camera', 'core_vehicles', 'core_recoveryPrompt', 'gameplay_traffic'}
-- Key metadata follows the unchanged general.json writer.
require("overhaul/lib/save/store").registerKeys({
  {key = "career.general", owner = "overhaul_career_career", files = {"career/general.json"}, phase = "profile", required = true},
})

-- Config -----------------------------------------------------------------------------------------

local saveFile = "general.json"
local DEBUG_SETTINGS_FILE = "settings/RLS/careerDebugSettings.json"
local migrationLoadingScreenTag = "careerMigration"
-- Covers the stock 8 s post-start cap, slow first mount and startup slack.
local PLAY_HANDOFF_RECOVERY_WINDOW_S = 15
local nodegrabberActions = {"nodegrabberGrab", "nodegrabberRender", "nodegrabberStrength", "nodegrabberAction"}

local actionWhitelist = deepcopy(nodegrabberActions)
local blockedActions = core_input_actionFilter.createActionTemplate({"vehicleTeleporting", "vehicleMenues", "physicsControls", "aiControls", "vehicleSwitching", "funStuff", "dropPlayerAtCameraNoReset"}, actionWhitelist)

local cheatblockedActions = core_input_actionFilter.createActionTemplate({"aiControls", "funStuff"})
-- Persisted debug keys remain compatible with older namespace names.
local debugSaveKeys = jsonReadFile("/gameplay/overhaul/career/debugSaveKeys.json") or {}

-- State ------------------------------------------------------------------------------------------

-- Legacy tutorial start choices are ignored.
M.tutorialEnabled = false
M.startingOptions = {}

local debugMenuEnabled = not shipping_build
local autosaveEnabled = true
-- The career session: activation, travel and start-flow state shared with career/start/transitions.lua.
local session = {
  active = false,
  modules = {},
  debugModules = {},
  boughtStarterVehicle = nil,
  organizationInteraction = {},
  switchLevel = nil,
  levelSwitch = nil,
  levelSwitchSequence = 0,
  lastLevelSwitchResult = {phase = "idle"},
  actionsBlocked = false,
  activationRetryCount = 0,
  activationRetrySequence = 0,
  activationRetryPending = false,
  lastActivationError = nil,
  -- Enter freeroam before activation so onClientEndMission cannot race the new career.
  pendingProfileLoad = nil,
  isNewSave = false,
  -- Loading finalization cannot depend on a vehicle-group callback for the player spawn.
  loadingIntroStarted = false,
  -- Router identity binds recovery to this start; splash identity owns its delayed job.
  loadingIntroToken = nil,
  loadingSplashToken = nil,
  startInProgress = false,
}
-- Pending choices belong to this instance while career/start/startingModes.lua prepares its save.
local start = {
  pendingStartingOptions = nil,
  pendingDifficultyMode = nil,
  pendingDifficultyOverrides = nil,
  pendingExperimentalMaintenanceEnabled = nil,
  pendingPoliceEnabled = nil,
  pendingEmploymentApprenticeship = nil,
  pendingStartingGaragePreference = nil,
  pendingCareerStartMode = nil,
  pendingCheatsMode = nil,
  pendingSandboxEconomyProfile = nil,
  pendingSandboxXpProfile = nil,
  startingGaragePreference = nil,
}
local parts = {}
local activationHealthPollTimer = 0
local debugSettingsCache
local migrationLoadingScreenActive = false

-- Shared helpers -----------------------------------------------------------------------------------

local function publish(key, value)
  M[key] = value
  local live = rawget(_G, "overhaul_career_career")
  if live ~= nil and live ~= M then live[key] = value end
end

local function getStartingGaragePreference()
  return deepcopy(start.startingGaragePreference or startingModes.normalizeStartingGaragePreference())
end

local function setStartingGaragePreference(mode, garageId)
  start.startingGaragePreference = startingModes.normalizeStartingGaragePreference(mode, garageId)
  start.pendingStartingGaragePreference = deepcopy(start.startingGaragePreference)
  publish("startingGaragePreference", deepcopy(start.startingGaragePreference))
  return deepcopy(start.startingGaragePreference)
end

local function updateNodegrabberBlocking()
  if session.active and overhaul_career_economy_cheats.isCheatsMode() then
    core_input_actionFilter.setGroup('careerNodeGrabberActions', nodegrabberActions)
    core_input_actionFilter.addAction(0, 'careerNodeGrabberActions', false)
    return
  end
  -- enable node grabber only in walking mode (unless cheats are enabled)
  if session.active and (core_camera.getActiveGlobalCameraName() or not gameplay_walk.isWalking()) then
    core_input_actionFilter.setGroup('careerNodeGrabberActions', nodegrabberActions)
    core_input_actionFilter.addAction(0, 'careerNodeGrabberActions', true)
    be.nodeGrabber:onMouseButton(false)
    return
  end
  core_input_actionFilter.setGroup('careerNodeGrabberActions', nodegrabberActions)
  core_input_actionFilter.addAction(0, 'careerNodeGrabberActions', false)
end

local function blockInputActions(block)
  local actionsToBlock = blockedActions
  if session.active and overhaul_career_economy_cheats.isCheatsMode() then
    actionsToBlock = cheatblockedActions
  end

  core_input_actionFilter.setGroup('careerBlockedActions', actionsToBlock)
  core_input_actionFilter.addAction(0, 'careerBlockedActions', block)
  session.actionsBlocked = block == true

  updateNodegrabberBlocking()
end

local function setupCareerActionsAndUnpause()
  blockInputActions(true)
  simTimeAuthority.pause(false)
  simTimeAuthority.set(1)
end

local function removeNonTrafficVehicles()
  local safeIds = gameplay_traffic.getTrafficList(true)
  safeIds = arrayConcat(safeIds, overhaul_integration_services_parking.getParkedCarsList(true))
  for i = be:getObjectCount()-1, 0, -1 do
    local objId = be:getObject(i):getID()
    if not tableContains(safeIds, objId) then
      be:getObject(i):delete()
    end
  end
end

local function initAfterLevelLoad(newSave)
  extensions.hook("onOverhaulActive", true, newSave)
end

local function closeAllMenus()
  -- Admission is asynchronous: the committed route stays unchanged until Vue
  -- acknowledges this request. A stale profile route is not a failed request.
  local navOk, navResult = pcall(function()
    return extensions.ui_router.navigate("play")
  end)
  if not navOk or (type(navResult) == "table" and navResult.result == false) then
    log("W", "career", "navigate(play) failed: " .. dumps(navResult))
    guihooks.trigger("ChangeState", {state = "play", params = {}})
  end
end

local function retireLoadingIntroRecovery(reason)
  if not session.loadingIntroToken then return end
  session.loadingIntroToken = nil
  log("I", "career", "play handoff recovery retired: " .. reason)
end

-- A newer transition owns the screen and retires this start's recovery.
local function beforeRouteChange()
  local token = session.loadingIntroToken
  if token and token.transitionId ~= routerTransitions.getTransitionId() then
    retireLoadingIntroRecovery("replacement transition")
  end
end

-- Stock commits before mount readiness; recover by cancelled identity, not route state.
local function routeChangeCancelled(payload)
  local token = session.loadingIntroToken
  if not session.active or not token or type(payload) ~= "table" then return end
  if payload.transitionId ~= token.transitionId then return end
  retireLoadingIntroRecovery("matching cancellation")
  if payload.toRoute and payload.toRoute.name == "play" and not routerTransitions.isTransitioning() then
    log("I", "career", "play handoff cancelled (" .. tostring(payload.reason) .. "); retrying once")
    closeAllMenus()
  end
end

local function onRouteTiming(routeName)
  if routeName == "play" and not routerTransitions.isTransitioning() then
    retireLoadingIntroRecovery("play completed")
  end
end

local function finishCareerLoadingIntro(opts)
  opts = opts or {}
  local firstIntro = not session.loadingIntroStarted
  if firstIntro and session.active then
    extensions.hook("onOverhaulCareerSplashRequested", false)
  end
  if server and server.fadeoutLoadingScreen then
    pcall(server.fadeoutLoadingScreen)
  end
  if core_gamestate.getLoadingStatus("careerLoading") then
    core_gamestate.requestExitLoadingScreen("careerLoading")
  end
  if opts.setCamera then
    commands.setGameCamera(true)
  end
  if not firstIntro or not session.active then return end
  session.loadingIntroStarted = true
  session.startInProgress = false
  -- Activation already exits loading synchronously. Every start hands off now;
  -- fadeout is cosmetic and cannot own or repeat navigation.
  local liveRoute = routerTransitions.isTransitioning() and routerTransitions.getToRoute()
  if not (liveRoute and liveRoute.name == "play") then closeAllMenus() end
  local transitionId = routerTransitions.getTransitionId()
  if transitionId then
    session.loadingIntroToken = {transitionId = transitionId, remainingSeconds = PLAY_HANDOFF_RECOVERY_WINDOW_S}
  end
  local splashToken = {}
  session.loadingSplashToken = splashToken
  core_jobsystem.create(function(job)
    job.sleep(0.15)
    if not session.active or session.loadingSplashToken ~= splashToken then return end
    session.loadingSplashToken = nil
    extensions.hook("onOverhaulCareerSplashRequested", true)
  end)
end

local function beginLegacySaveMigrationLoading()
  if migrationLoadingScreenActive then return true end
  migrationLoadingScreenActive = true
  core_gamestate.requestEnterLoadingScreen(migrationLoadingScreenTag)
  return true
end

local function endLegacySaveMigrationLoading()
  if not migrationLoadingScreenActive then return false end
  migrationLoadingScreenActive = false
  core_gamestate.requestExitLoadingScreen(migrationLoadingScreenTag)
  return true
end

-- Debug menu ---------------------------------------------------------------------------------------

local function getDebugSettings()
  if not debugSettingsCache then
    debugSettingsCache = jsonReadFile(DEBUG_SETTINGS_FILE) or deepcopy(settings.getValue('careerDebugSettings') or {})
  end
  return debugSettingsCache
end

local function drawDebugFileMenu()
  local endCareerMode = false
  if imgui.BeginMenu("File") then
    local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
    imgui.Text((string.sub(currentSavePath, string.len(overhaul_career_saveSystem.getSaveRootDirectory())+2, -1)))
    imgui.Separator()
    if imgui.Selectable1("Save Career") then
      require("overhaul/lib/save/store").request("career:debugMenuSave", nil, {manual = true})
    end
    if imgui.Selectable1("Exit Career Mode") then
      endCareerMode = true
    end
    if imgui.Selectable1("Open Save Folder") then
      Engine.Platform.exploreFolder(currentSavePath:lower())
    end
    imgui.EndMenu()
  end
  return endCareerMode
end

local function drawDebugModuleMenu(debugSettings)
  if imgui.BeginMenu("Modules") then
    for _, mod in ipairs(session.debugModules) do
      local active = debugSettings[mod.debugName] or false
      if mod.drawDebugMenu then
        if imgui.Checkbox(mod.debugName, imgui.BoolPtr(active)) then
          debugSettings[mod.debugName] = not active
          jsonWriteFile(DEBUG_SETTINGS_FILE, debugSettings, true)
        end
      end
    end
    imgui.EndMenu()
  end
end

local function drawDebugFunctionMenu()
  if imgui.BeginMenu("Functions") then
    for _, moduleName in ipairs(session.modules) do
      local owner = optional(moduleName)
      if owner and owner.drawDebugFunctions then
        imgui.Text(owner.debugName or owner.__extensionName__)
        owner.drawDebugFunctions()
        imgui.Separator()
      end
    end
    imgui.EndMenu()
  end
end

local function drawActiveDebugModules(debugSettings)
  for _, mod in ipairs(session.debugModules) do
    local active = debugSettings[mod.debugName] or false
    if mod.drawDebugMenu and active then
      mod.drawDebugMenu(dt)
      imgui.Separator()
    end
  end
end

local function debugMenu()
  if not session.active then return end
  local debugSettings = getDebugSettings()
  imgui.SetNextWindowSize(imgui.ImVec2(300, 300), imgui.Cond_FirstUseEver)
  imgui.Begin("Career Debug (Save File: " .. overhaul_career_saveSystem.getCurrentProfile() .. ")###Career Debug", nil, imgui.WindowFlags_MenuBar)
  imgui.BeginMenuBar()
  local endCareerMode = drawDebugFileMenu()
  drawDebugModuleMenu(debugSettings)
  drawDebugFunctionMenu()
  imgui.EndMenuBar()
  drawActiveDebugModules(debugSettings)
  imgui.End()

  if endCareerMode then
    M.deactivateCareer()
    return true
  end
end

-- Parts ------------------------------------------------------------------------------------------

parts.transitions = transitions.newCareer({
  session = session,
  start = start,
  module = M,
  publish = publish,
  getPublic = function(key) return M[key] end,
  blockInputActions = function(...) return blockInputActions(...) end,
  setupActions = function() return setupCareerActionsAndUnpause() end,
  closeAllMenus = function() return closeAllMenus() end,
  finishLoadingIntro = function(...) return finishCareerLoadingIntro(...) end,
  initAfterLevelLoad = function(...) return initAfterLevelLoad(...) end,
  removeNonTrafficVehicles = function() return removeNonTrafficVehicles() end,
})

parts.start = startingModes.new({
  start = start,
  publish = publish,
  getPublic = function(key) return M[key] end,
  isActive = function() return session.active end,
  isStartInProgress = function() return session.startInProgress end,
  setStartInProgress = function(value) session.startInProgress = value end,
  resetLoadingIntro = function()
    session.loadingIntroStarted = false
    retireLoadingIntroRecovery("start reset")
    session.loadingSplashToken = nil
  end,
  activateCareer = function(...) return parts.transitions.activateCareer(...) end,
  deactivateCareer = function(...)
    local transition = lifecycle.begin("profile", {via = "careerStart"})
    local result = parts.transitions.deactivateCareer(...)
    lifecycle.finish(transition, "done")
    return result
  end,
  endLegacySaveMigrationLoading = function() return endLegacySaveMigrationLoading() end,
  restart = function(...) return M.createOrLoadCareerAndStart(...) end,
})
parts.slots = saveSlots.new({isActive = function() return session.active end})
parts.cards = profileCards.new({isActive = function() return session.active end, getPublic = function(key) return M[key] end})

-- Per-frame update ---------------------------------------------------------------------------------

local function onUpdate(dtReal, dtSim, dtRaw)
  if not session.active then return end
  local token = session.loadingIntroToken
  if token then
    token.remainingSeconds = token.remainingSeconds - (dtReal or 0)
    if token.remainingSeconds <= 0 then retireLoadingIntroRecovery("window expired") end
  end
  activationHealthPollTimer = activationHealthPollTimer - (dtReal or 0)
  if session.levelSwitch and session.levelSwitch.phase == "activating"
    and activationHealthPollTimer <= 0 then
    activationHealthPollTimer = 0.25
    local health = parts.transitions.getActivationHealth()
    if health.ok
      and health.currentLevel == session.levelSwitch.destination
      and health.savedLevel == session.levelSwitch.destination then
      log("I", "career", "Finalizing healthy destination transaction from career update")
      parts.transitions.finalizeSuccessfulCareerActivation()
    end
  end
  if debugMenuEnabled then
    if debugMenu() then
      return
    end
  end
  extensions.hook("onOverhaulCareerSimStep", dtSim)
end

-- Lifecycle ----------------------------------------------------------------------------------------

local function deactivateCareerAndReloadLevel(saveCareer)
  if not session.active then return end
  overhaul_career_saveSystem.flushSaveForExit(function()
    parts.transitions.deactivateCareer(saveCareer)
    freeroam_freeroam.startFreeroam(path.getPathLevelMain(getCurrentLevelIdentifier()))
  end)
end

local function isActive()
  return session.active
end

local function applyChallengeConfig(config)
  if not config then return false end
  if not isActive() then return false end
  -- Challenge capital resets are setup, not spending from the pinned cheat wallet.
  if type(config.money) == 'number' and not (overhaul_career_economy_cheats and overhaul_career_economy_cheats.isCheatsMode()) then
    overhaul_career_economy_playerAttributes.setAttributes({money = config.money}, require("overhaul/lib/finance/metadata").tag({label = "Challenge Start"}, "starting_funds"))
  end
  if type(config.loans) == 'table' then
    for _, loan in ipairs(config.loans) do
      local orgId = loan and loan.orgId
      local amount = loan and loan.amount
      local payments = loan and loan.payments
      local rate = loan and loan.rate
      if orgId and type(amount) == 'number' and amount > 0 and type(payments) == 'number' and payments > 0 then
        capabilities.get("challengeLoans").takeLoan(orgId, amount, payments, rate)
      end
    end
  end
  return true
end

local function launchMostRecentCareer()
  local allProfiles = overhaul_career_saveSystem.getAllProfiles()
  if tableSize(allProfiles) == 0 then
    log("W", "", "No career save slots found")
    return false
  end

  local mostRecentProfile = nil
  local mostRecentDate = "0"

  for _, profileName in ipairs(allProfiles) do
    local _, saveDate = saveSlots.getNewestSaveForProfile(profileName)
    if saveDate and saveDate ~= "0" and saveDate ~= "A" then
      if saveDate > mostRecentDate then
        mostRecentDate = saveDate
        mostRecentProfile = profileName
      end
    end
  end

  if not mostRecentProfile then
    log("W", "", "No valid career saves found")
    return false
  end

  log("I", "", "Launching most recent career: " .. mostRecentProfile)
  return parts.start.createOrLoadCareerAndStart(mostRecentProfile)
end

local function getLegacySavePreflight(profile, specificSaveFolder)
  return overhaul_career_saveMigration.getLegacySavePreflight(profile, specificSaveFolder)
end

local function prepareLegacySaveMigration(profile, specificSaveFolder, options)
  local result = overhaul_career_saveMigration.prepareLegacySaveMigration(profile, specificSaveFolder, options)
  -- A failed copy must dismiss loading even if its original UI is gone.
  if type(result) ~= "table" or not result.ok then
    endLegacySaveMigrationLoading()
  end
  return result
end

-- Public API helpers -------------------------------------------------------------------------------

local function hasBoughtStarterVehicle()
  return session.boughtStarterVehicle
end

local function setBoughtStarterVehicle(value)
  session.boughtStarterVehicle = value == true
end

local function hasInteractedWithOrganization(id)
  return session.organizationInteraction[id]
end

local function interactWithOrganization(id)
  session.organizationInteraction[id] = true
end

local function isAutosaveEnabled()
  return autosaveEnabled and not (overhaul_shell_settings.getSetting("autosaveEnabled") == false)
end

local function setAutosaveEnabled(enabled)
  autosaveEnabled = enabled
end

local function getAdditionalMenuButtons()
  local buttons = {}
  table.insert(buttons, {label = _tr("ui.career.pause.map"), luaFun = "freeroam_bigMapMode.enterBigMap({instant=true, ignoreUiStateChange=false})"})
  for _, button in ipairs(uiOwners.additionalMenuButtons(M)) do table.insert(buttons, button) end
  return buttons
end

local function setDebugMenuEnabled(enabled)
  debugMenuEnabled = enabled
end

-- Public API: activation and travel ---------------------------------------------------------------

M.createOrLoadCareerAndStart = parts.start.createOrLoadCareerAndStart
M.activateCareer = parts.transitions.activateCareer
-- Stop waits for the pending save before advancing the profile lifetime.
M.deactivateCareer = function(saveCareer)
  local transition = session.active and lifecycle.begin("profile", {via = "stop"}) or nil
  return overhaul_career_saveSystem.flushSaveForExit(function()
    parts.transitions.deactivateCareer(saveCareer)
    lifecycle.finish(transition, "done")
  end)
end
M.deactivateCareerAndReloadLevel = deactivateCareerAndReloadLevel
M.isActive = isActive
M.isStarting = function() return session.startInProgress end
M.applyChallengeConfig = applyChallengeConfig
M.switchCareerLevel = parts.transitions.switchCareerLevel
M.getLevelSwitchState = parts.transitions.getLevelSwitchState
M.getActivationHealth = parts.transitions.getActivationHealth
M.launchMostRecentCareer = launchMostRecentCareer

-- Public API: profiles and starting choices -------------------------------------------------------

M.sendAllCareerProfilesData = parts.cards.sendAllCareerProfilesData
M.sendAllCareerProfilesDataAsync = parts.cards.sendAllCareerProfilesDataAsync
M.sendEntryCardProfilesDataAsync = parts.cards.sendEntryCardProfilesDataAsync
M.sendCurrentProfileData = parts.cards.sendCurrentProfileData
M.formatImportSourceCard = function(profile, sourcePath) return parts.cards.formatProfileForUi(profile, sourcePath) end
M.getImportSourceHighlights = function(profile, sourcePath, limit) return parts.cards.getProfileHighlights(profile, limit, sourcePath) end
M.getAutosavesForProfile = saveSlots.getAutosavesForProfile
M.getSaveFoldersForProfile = saveSlots.getSaveFoldersForProfile
M.getProfileHighlights = parts.cards.getProfileHighlights
M.getStartingModeOptions = startingModes.getStartingModeOptions
M.getCurrentStartingModeData = parts.start.getCurrentStartingModeData

M.setMaintenanceModeForSaveSlot = parts.slots.setMaintenanceModeForSaveSlot
M.setPoliceEnabledForSaveSlot = parts.slots.setPoliceEnabledForSaveSlot
M.setEmploymentApprenticeshipForSaveSlot = saveSlots.setEmploymentApprenticeshipForSaveSlot

-- Public API: session and preferences -------------------------------------------------------------

M.hasBoughtStarterVehicle = hasBoughtStarterVehicle
M.setBoughtStarterVehicle = setBoughtStarterVehicle
M.hasInteractedWithOrganization = hasInteractedWithOrganization
M.interactWithOrganization = interactWithOrganization
M.closeAllMenus = closeAllMenus
M.isAutosaveEnabled = isAutosaveEnabled
M.setAutosaveEnabled = setAutosaveEnabled
M.getBeamXPLevel = profileReadModels.getBeamXPLevel
M.setDebugMenuEnabled = setDebugMenuEnabled
M.getStartingGaragePreference = getStartingGaragePreference
M.setStartingGaragePreference = setStartingGaragePreference
M.getAdditionalMenuButtons = getAdditionalMenuButtons
M.getLegacySavePreflight = getLegacySavePreflight
M.getEmploymentModePreflight = saveSlots.getEmploymentModePreflight
M.prepareLegacySaveMigration = prepareLegacySaveMigration
M.takePendingLegacySaveMigration = function()
  return overhaul_career_saveMigration.takePendingLegacySaveMigration()
end
M.beginLegacySaveMigrationLoading = beginLegacySaveMigrationLoading
M.endLegacySaveMigrationLoading = endLegacySaveMigrationLoading

-- Game hooks ---------------------------------------------------------------------------------------

local function onCameraModeChanged(modeName)
  if not session.active then return end
  updateNodegrabberBlocking()
end

local function onGlobalCameraSet(modeName)
  if not session.active then return end
  updateNodegrabberBlocking()
end

local function onOverhaulCheatsModeChanged(enabled)
  if not session.active then return end
  blockInputActions(true)
end

local function onOverhaulActive(active)
  if not active then return end
  overhaul_ui_recoveryPrompt.setDefaultsForCareer()
  guihooks.trigger('ClearTasklist')
  ui_appContainers.showApp("topLeft", "tasks")
  publish("onUpdate", onUpdate)
  gameplay_rawPois.clear()
  setupCareerActionsAndUnpause()
  core_gamestate.setGameState("overhaul", "overhaul", nil)
end

local function onOverhaulSaveCurrentProfile(currentSavePath)
  if not session.active then return end

  local filePath = currentSavePath .. "/career/" .. saveFile
  local data = {}

  data.level = getCurrentLevelIdentifier()
  if session.switchLevel then
    data.level = session.switchLevel
    data.justSwitched = true
  end
  data.startingOptions = deepcopy(M.startingOptions or {})
  data.boughtStarterVehicle = session.boughtStarterVehicle
  data.startingGarageMode = start.startingGaragePreference and start.startingGaragePreference.mode or "default"
  data.startingGarageId = start.startingGaragePreference and start.startingGaragePreference.garageId or nil
  data.debugModuleOpenStates = {}
  data.organizationInteraction = session.organizationInteraction or {}
  for _, module in ipairs(session.debugModules) do
    if module.getDebugMenuActive then
      data.debugModuleOpenStates[debugSaveKeys[module.___extensionName___] or module.___extensionName___] = module.getDebugMenuActive()
    end
  end

  overhaul_career_saveSystem.jsonWriteFileSafe(filePath, data, true)
end

local function onOverhaulBeforeSetProfile(currentSavePath)
  if isActive() then
    local transition = lifecycle.begin("profile", {via = "setProfile"})
    parts.transitions.deactivateCareer()
    lifecycle.finish(transition, "done")
  end
end

local function onClientStartMission(levelPath)
  if session.active then
    publish("onUpdate", onUpdate)
    gameplay_rawPois.clear()
    setupCareerActionsAndUnpause()
    core_gamestate.setGameState("overhaul", "overhaul", nil)
    ui_appContainers.showApp("topLeft", "tasks")
  end
end

local function onClientEndMission(levelPath)
  lifecycle.advance("map", "endMission")
  if not session.active then return end
  local transition = lifecycle.begin("unload", {via = "endMission"})
  parts.transitions.deactivateCareer()
  lifecycle.finish(transition, "done")
end

local function onSerialize()
  local data = {}
  if session.active then
    data.reactivate = true
    parts.transitions.deactivateCareer()
  end
  return data
end

local function onDeserialized(data)
  if data.reactivate then
    parts.transitions.activateCareer(false)
  end
end

local function onAnyMissionChanged(state, mission)
  if not session.active then return end
  if mission then
    if state == "stopped" then
      blockInputActions(true)
    elseif state == "started" then
      blockInputActions(false)
    end
  end
end

local function onOverhaulVehicleAddedToInventory(data)
  if not session.boughtStarterVehicle and data.vehicleInfo then
    session.boughtStarterVehicle = true
    capabilities.get("inventoryProgress").onFirstVehicleAdded()
  end
end

local function onVehicleGroupSpawned()
  if not session.active and not session.startInProgress and not core_gamestate.getLoadingStatus("careerLoading") then
    return
  end
  if session.loadingIntroStarted and not core_gamestate.getLoadingStatus("careerLoading") then
    return
  end
  core_jobsystem.create(function(job)
    job.sleep(0.25)
    finishCareerLoadingIntro({ setCamera = true })
  end)
end

local function onModsChanged()
  parts.transitions.modsChanged()
  M.activity.modsChanged()
end

M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
-- Queued profile-list builds of this instance must not publish after a replacement loads.
M.onExtensionUnloaded = parts.cards.dispose
M.onOverhaulBeforeSetProfile = onOverhaulBeforeSetProfile
M.onOverhaulActive = onOverhaulActive
M.onOverhaulSaveFinished = parts.transitions.saveFinished
M.onOverhaulSaveFailed = parts.transitions.saveFailed
-- A mod enabled or disabled mid-career can add or remove career modules and activity owners.
M.onModActivated = onModsChanged
M.onModDeactivated = function(modData)
  if modIdentity.isOwnMod(modData) then return end
  onModsChanged()
end
M.onWorldReadyState = parts.transitions.worldReady
M.onVehicleGroupSpawned = onVehicleGroupSpawned
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.onClientStartMission = onClientStartMission
M.beforeRouteChange = beforeRouteChange
M.routeChangeCancelled = routeChangeCancelled
M.onRouteTiming = onRouteTiming
M.onClientEndMission = onClientEndMission
M.onAnyMissionChanged = onAnyMissionChanged
M.onOverhaulVehicleAddedToInventory = onOverhaulVehicleAddedToInventory
M.onCameraModeChanged = onCameraModeChanged
M.onGlobalCameraSet = onGlobalCameraSet
M.onOverhaulCheatsModeChanged = onOverhaulCheatsModeChanged

-- The always-loaded owner exposes activity access without registering another extension.
M.activity = require('overhaul/lib/activity/access').get()

return M
