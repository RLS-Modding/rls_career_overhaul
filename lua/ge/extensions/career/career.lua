-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local imgui = ui_imgui

M.dependencies = {'career_saveSystem', 'core_recoveryPrompt', 'gameplay_traffic'}

M.tutorialEnabled = false

local careerModuleDirectory = '/lua/ge/extensions/career/modules/'
local saveFile = "general.json"
local levelName = "west_coast_usa"
local defaultLevel = path.getPathLevelMain(levelName)
local autosaveEnabled = true

local careerActive = false
local careerModules = {}
local debugActive = true
local boughtStarterVehicle
local organizationInteraction = {}
local switchLevel = nil

local devActions = {"dropPlayerAtCameraNoReset"}
local nodegrabberActions = {"nodegrabberGrab", "nodegrabberRender", "nodegrabberStrength", "nodegrabberAction"}


local actionWhitelist = deepcopy(devActions)
arrayConcat(actionWhitelist, nodegrabberActions)
local blockedActions = core_input_actionFilter.createActionTemplate({"vehicleTeleporting", "vehicleMenues", "physicsControls", "aiControls", "vehicleSwitching", "funStuff"}, actionWhitelist)

-- TODO maybe save whenever we go into the esc menu

local function updateNodegrabberBlocking()
  -- enable node grabber only in walking mode
  if careerActive and (core_camera.getActiveGlobalCameraName() or not gameplay_walk.isWalking()) then
    core_input_actionFilter.setGroup('careerNodeGrabberActions', nodegrabberActions)
    core_input_actionFilter.addAction(0, 'careerNodeGrabberActions', true)
    be.nodeGrabber:onMouseButton(false)
    return
  end
  core_input_actionFilter.setGroup('careerNodeGrabberActions', nodegrabberActions)
  core_input_actionFilter.addAction(0, 'careerNodeGrabberActions', false)
end

local function blockInputActions(block)
  if shipping_build then
    core_input_actionFilter.setGroup('careerBlockedDevActions', devActions)
    core_input_actionFilter.addAction(0, 'careerBlockedDevActions', block)
  end

  core_input_actionFilter.setGroup('careerBlockedActions', blockedActions)
  core_input_actionFilter.addAction(0, 'careerBlockedActions', block)

  updateNodegrabberBlocking()
end

local function onCameraModeChanged(modeName)
  if not careerActive then return end
  updateNodegrabberBlocking()
end

local function onGlobalCameraSet(modeName)
  if not careerActive then return end
  updateNodegrabberBlocking()
end

local debugModules = {}
local debugModuleOpenStates = {}
local function debugMenu()
  if not careerActive then return end
  local endCareerMode = false

  local debugSettings = settings.getValue('careerDebugSettings')
  imgui.SetNextWindowSize(imgui.ImVec2(300, 300), imgui.Cond_FirstUseEver)
  imgui.Begin("Career Debug (Save File: " .. career_saveSystem.getCurrentSaveSlot() .. ")###Career Debug", nil, imgui.WindowFlags_MenuBar)
  imgui.BeginMenuBar()
  if imgui.BeginMenu("File") then
    local currentSaveSlot, currentSavePath = career_saveSystem.getCurrentSaveSlot()
    imgui.Text((string.sub(currentSavePath, string.len(career_saveSystem.getSaveRootDirectory())+2, -1)))
    imgui.Separator()
    if imgui.Selectable1("Save Career") then
      career_saveSystem.saveCurrent()
    end
    if imgui.Selectable1("Exit Career Mode") then
      endCareerMode = true
    end
    if imgui.Selectable1("Open Save Folder") then
      Engine.Platform.exploreFolder(currentSavePath)
    end
    imgui.EndMenu()
  end
  if imgui.BeginMenu("Modules") then
    for _, mod in ipairs(debugModules) do
      local active = debugSettings[mod.debugName] or false
      if mod.drawDebugMenu then
        if imgui.Checkbox(mod.debugName, imgui.BoolPtr(active)) then
          debugSettings[mod.debugName] = not active
          settings.setValue('careerDebugSettings', debugSettings)
        end
      end
    end
    imgui.EndMenu()
  end

  if imgui.BeginMenu("Functions") then
    for _, mod in ipairs(careerModules) do
      if extensions[mod].drawDebugFunctions then
        imgui.Text(extensions[mod].debugName or extensions[mod].__extensionName__)
        extensions[mod].drawDebugFunctions()
        imgui.Separator()
      end
    end
    imgui.EndMenu()
  end

  imgui.EndMenuBar()
  for _, mod in ipairs(debugModules) do
    local active = debugSettings[mod.debugName] or false
    if mod.drawDebugMenu and active then
      mod.drawDebugMenu(dt)
      imgui.Separator()
    end
  end
  imgui.End()

  if endCareerMode then
    M.deactivateCareer()
    return true
  end
end

local function setupCareerActionsAndUnpause()
  blockInputActions(true)
  simTimeAuthority.pause(false)
  simTimeAuthority.set(1)
end

local function onCareerModulesActivated(alreadyInLevel)
  setupCareerActionsAndUnpause()
end

local function toggleCareerModules(active, alreadyInLevel)
  if active then
    table.clear(careerModules)
    local extensionFiles = {}
    local files = FS:findFiles(careerModuleDirectory, '*.lua', -1, true, false)
    for i = 1, tableSize(files) do
      extensions.luaPathToExtName(modulePath)
      local extensionFile = string.gsub(files[i], "/lua/ge/extensions/", "")
      extensionFile = string.gsub(extensionFile, ".lua", "")
      --if not string.find(extensionFile, "delivery") then
        table.insert(extensionFiles, extensionFile)
        table.insert(careerModules, extensions.luaPathToExtName(extensionFile))
      --else
        --log("I","","Skipping "..extensionFile .. " for now while it is WIP (temporary)")
      --end
    end
    extensions.load(careerModules)
    extensions.disableSerialization(careerModules)

    -- prevent these extensions from being unloaded when switching level
    for _, extension in ipairs(extensionFiles) do
      setExtensionUnloadMode(extensions.luaPathToExtName(extension), "manual")
    end

    for _, moduleName in ipairs(careerModules) do
      if extensions[moduleName].onCareerActivated then
        extensions[moduleName].onCareerActivated()
      end
    end

    onCareerModulesActivated(alreadyInLevel)
    extensions.hook("onCareerModulesActivated", alreadyInLevel)
    debugModules = {}
    for _, moduleName in ipairs(careerModules) do
      if extensions[moduleName].debugName then
        table.insert(debugModules,extensions[moduleName])
      end
    end
    table.sort(debugModules, function(a,b) return a.debugOrder < b.debugOrder end)
  else
    for _, name in ipairs(careerModules) do
      extensions.unload(name)
    end
    table.clear(careerModules)
  end
end


local function onUpdate(dtReal, dtSim, dtRaw)
  if not careerActive then return end
  if not shipping_build then
    if debugMenu() then
      return
    end
  end
end

local function removeNonTrafficVehicles()
  local safeIds = gameplay_traffic.getTrafficList(true)
  safeIds = arrayConcat(safeIds, gameplay_parking.getParkedCarsList(true))
  for i = be:getObjectCount()-1, 0, -1 do
    local objId = be:getObject(i):getID()
    if not tableContains(safeIds, objId) then
      be:getObject(i):delete()
    end
  end
end

local function activateCareer(removeVehicles)
  if careerActive then return end
  -- load career
  local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()
  if not saveSlot then return end
  extensions.hook("onBeforeCareerActivate")
  if removeVehicles == nil then
    removeVehicles = true
  end
  if core_groundMarkers then core_groundMarkers.setPath(nil) end

  careerActive = true
  log("I", "Loading career from " .. savePath .. "/career/" .. saveFile)
  local careerData = (savePath and jsonReadFile(savePath .. "/career/" .. saveFile)) or {}
  local levelToLoad = careerData.level or levelName
  boughtStarterVehicle = true
  debugModuleOpenStates = careerData.debugModuleOpenStates or {}
  organizationInteraction = careerData.organizationInteraction or {}

  -- Disable the tutorial
  M.tutorialEnabled = false
  log("I", "", "Tutorial for career disabled.")

  if not getCurrentLevelIdentifier() or (getCurrentLevelIdentifier() ~= levelToLoad) then
    spawn.preventPlayerSpawning = true
    freeroam_freeroam.startFreeroam(path.getPathLevelMain(levelToLoad))
    toggleCareerModules(true)
  else
    if removeVehicles then
      core_vehicles.removeAll()
    else
      removeNonTrafficVehicles()
    end
    toggleCareerModules(true, true)
    M.closeAllMenus()
    M.onUpdate = onUpdate
  end

  gameplay_rawPois.clear()
  core_recoveryPrompt.setDefaultsForCareer()
  extensions.hook("onCareerActive", true)
  guihooks.trigger('ClearTasklist')
  core_gamestate.setGameState("career","career", nil)

  career_modules_playerDriving.ensureTraffic = true

  if career_modules_linearTutorial.isLinearTutorialActive() then
    M.setAutosaveEnabled(false)
    print("Disabling autosave because we are in tutorial!")
  end
end

local function deactivateCareer(saveCareer)
  if not careerActive then return end
  M.onUpdate = nil
  careerActive = false
  toggleCareerModules(false)
  blockInputActions(false)
  gameplay_rawPois.clear()
  core_recoveryPrompt.setDefaultsForFreeroam()
  extensions.hook("onCareerActive", false)
  guihooks.trigger("HideCareerTasklist")
end

local function deactivateCareerAndReloadLevel(saveCareer)
  if not careerActive then return end
  deactivateCareer(saveCareer)
  freeroam_freeroam.startFreeroam(path.getPathLevelMain(getCurrentLevelIdentifier()))
end

local function isActive()
  return careerActive
end

local function enableTutorial(enabled)
  if enabled then
    log("I","","Tutorial for career enabled.")
  end
  M.tutorialEnabled = enabled or false
end

local function enableHardcoreMode(enabled)
  if enabled then
    log("I","","Hardcore mode enabled.")
  end
  M.hardcoreMode = enabled
end

local function createOrLoadCareerAndStart(name, specificAutosave)
  --M.tutorialEnabled = string.find(string.lower(name), "tutorial") and true or false
  --M.vehSelectEnabled = string.find(string.lower(name), "vehselect") and true or false
  log("I","",string.format("Create or Load Career: %s - %s", name, specificAutosave))
  if career_saveSystem.setSaveSlot(name, specificAutosave) then
    activateCareer()
    return true
  end
  return false
end

local function onSaveCurrentSaveSlot(currentSavePath)
  if not careerActive then return end

  local filePath = currentSavePath .. "/career/" .. saveFile
  -- read the info file
  local data = {}

  data.level = getCurrentLevelIdentifier()
  if switchLevel then
    data.level = switchLevel
    data.justSwitched = true
  end
  data.boughtStarterVehicle = boughtStarterVehicle
  data.debugModuleOpenStates = {}
  data.organizationInteraction = organizationInteraction or {}
  for _, module in ipairs(debugModules) do
    if module.getDebugMenuActive then
      data.debugModuleOpenStates[module.___extensionName___] = module.getDebugMenuActive()
    end
  end

  career_saveSystem.jsonWriteFileSafe(filePath, data, true)
end

local function onBeforeSetSaveSlot(currentSavePath, currentSaveSlot)
  if isActive() then
    deactivateCareer()
  end
end

local function onClientStartMission(levelPath)
  if careerActive then
    M.onUpdate = onUpdate
    gameplay_rawPois.clear()
    setupCareerActionsAndUnpause()
    core_gamestate.setGameState("career","career", nil)
  end
end

local beamXPLevels ={
    {requiredValue = 0}, -- to reach lvl 1
    {requiredValue = 100},-- to reach lvl 2
    {requiredValue = 300},-- to reach lvl 3
    {requiredValue = 600},-- to reach lvl 4
    {requiredValue = 1000},-- to reach lvl 5
}
local function getBeamXPLevel(xp)
  local level = -1
  local neededForNext = -1
  local curLvlProgress = -1
  for i, lvl in ipairs(beamXPLevels) do
    if xp >= lvl.requiredValue then
      level = i
    end
  end
  if beamXPLevels[level+1] then
    neededForNext = beamXPLevels[level+1].requiredValue
    curLvlProgress = xp - beamXPLevels[level].requiredValue
  end
  return level, curLvlProgress, neededForNext
end

local function formatSaveSlotForUi(saveSlot)
  local data = {}
  data.id = saveSlot

  -- Add preview image based on level
  local levelPreviewMap = {
    west_coast_usa = "/ui/modules/career/profilePreview_WCUSA.jpg"
  }

  -- Get level from save data
  local autosavePath = career_saveSystem.getAutosave(career_saveSystem.getSaveRootDirectory() .. saveSlot)
  local infoData = jsonReadFile(autosavePath .. "/info.json")
  local careerData = jsonReadFile(autosavePath .. "/career/" .. saveFile)
  local hardcoreData = jsonReadFile(autosavePath .. "/career/rls_career/hardcore.json")

  if hardcoreData then
    data.hardcoreMode = hardcoreData.hardcoreMode
  end
  
  if careerData and careerData.level then
    if levelPreviewMap[careerData.level] then
      data.preview = levelPreviewMap[careerData.level]
    else
      local preview = "/ui/modules/career/profilePreview_" .. careerData.level .. ".jpg"
      if FS:fileExists(preview) then
        data.preview = preview
      else
        data.preview = levelPreviewMap.west_coast_usa
      end
    end
  end

  local currentSaveSlot, _ = career_saveSystem.getCurrentSaveSlot()
  if career_career.isActive() and currentSaveSlot == saveSlot then

    -- current save slot
    data.tutorialActive = career_modules_linearTutorial.isLinearTutorialActive()
    data.money = career_modules_playerAttributes.getAttribute("money")
    data.beamXP = career_modules_playerAttributes.getAttribute("beamXP")
    data.vouchers = career_modules_playerAttributes.getAttribute("vouchers")
    data.beamXP.level, data.beamXP.curLvlProgress, data.beamXP.neededForNext = getBeamXPLevel(data.beamXP.value)
    data.branches = {}

    for _, br in ipairs(career_branches.getSortedBranches()) do
      if br.isBranch and br.parentDomain == "apm" then
        local attKey = br.attributeKey
        local brData = deepcopy(career_modules_playerAttributes.getAttribute(attKey) or {value=br.defaultValue or 0})
        brData.level, brData.curLvlProgress, brData.neededForNext = career_branches.calcBranchLevelFromValue(brData.value, br.id)
        brData.id = attKey
        brData.icon = br.icon
        brData.color = br.color
        brData.label = br.name
        brData.levelLabel = {txt='ui.career.lvlLabel', context={lvl=brData.level}}
        table.insert(data.branches, brData)
        -- remove this assigment once UI side works with the new branch list
        data[attKey] = brData
      end
    end
    data.currentVehicle = career_modules_inventory.getCurrentVehicle() and career_modules_inventory.getVehicles()[career_modules_inventory.getCurrentVehicle()]
  else
    -- save slot from file
    local attData = jsonReadFile(autosavePath .. "/career/playerAttributes.json")
    local inventoryData = jsonReadFile(autosavePath .. "/career/inventory.json")

    if attData then
      data.money = deepcopy(attData.money) or {value=0}
      data.beamXP = deepcopy(attData.beamXP) or {value=0}
      data.vouchers = deepcopy(attData.vouchers) or {value=0}
      data.beamXP.level, data.beamXP.curLvlProgress, data.beamXP.neededForNext = getBeamXPLevel(data.beamXP.value)
      data.branches = {}
      for _, br in ipairs(career_branches.getSortedBranches()) do
        if br.isBranch and br.parentDomain == "apm" then
          local attKey = br.attributeKey
          local newAttKey = career_branches.newAttributeNamesToOldNames[attKey] or attKey
          local brData = deepcopy(attData[newAttKey] or attData[attKey] or {value=br.defaultValue or 0})
          brData.level, brData.curLvlProgress, brData.neededForNext = career_branches.calcBranchLevelFromValue(brData.value, br.id)
          brData.id = attKey
          brData.icon = br.icon
          brData.color = br.color
          brData.label = br.name
          brData.levelLabel = {txt='ui.career.lvlLabel', context={lvl=brData.level}}

          table.insert(data.branches, brData)
          -- remove this assigment once UI side works with the new branch list
          data[attKey] = brData
        end
      end
    end

    if inventoryData and inventoryData.currentVehicle then
      local vehicleData = jsonReadFile(autosavePath .. "/career/vehicles/" .. inventoryData.currentVehicle .. ".json")
      if vehicleData then
        data.currentVehicle = vehicleData.niceName
      end
    end
  end

  -- add the infoData raw
  if infoData and infoData.version then
    infoData.incompatibleVersion = career_saveSystem.getBackwardsCompVersion() > infoData.version
    infoData.outdatedVersion = career_saveSystem.getSaveSystemVersion() > infoData.version
    tableMerge(data, infoData)
  end

  return data
end

local function sendAllCareerSaveSlotsData()
  local res = {}
  for _, saveSlot in ipairs(career_saveSystem.getAllSaveSlots()) do
    local saveSlotData = formatSaveSlotForUi(saveSlot)
    if saveSlotData then
      table.insert(res, saveSlotData)
    end
  end

  table.sort(res, function(a,b) return (a.creationDate or "Z") < (b.creationDate or "Z") end)
  guihooks.trigger("allCareerSaveSlots", res)
  return res
end

local function sendCurrentSaveSlotData()
  if not careerActive then return end
  local saveSlot = career_saveSystem.getCurrentSaveSlot()
  if saveSlot then
    return formatSaveSlotForUi(saveSlot)
  end
end

local function getAutosavesForSaveSlot(saveSlot)
  local res = {}
  for _, saveData in ipairs(career_saveSystem.getAllAutosaves(saveSlot)) do
    local data = jsonReadFile(career_saveSystem.getSaveRootDirectory() .. saveSlot .. "/" .. saveData.name .. "/career/playerAttributes.json")
    if data then
      data.id = saveSlot
      data.autosaveName = saveData.name
      table.insert(res, data)
    end
  end
  return res
end

local function switchCareerLevel(nextLevel)
  if not nextLevel or nextLevel == getCurrentLevelIdentifier() then return end

  switchLevel = nextLevel
  career_saveSystem.saveCurrent()
end

local function onClientEndMission(levelPath)
  if not careerActive then return end
  local levelNameToLoad = path.levelFromPath(levelPath)
  if levelNameToLoad == levelName then
    deactivateCareer()
  end
end

local function onSerialize()
  local data = {}
  if careerActive then
    data.reactivate = true
    deactivateCareer()
  end
  return data
end

local function onDeserialized(v)
  if v.reactivate then
    activateCareer(false)
  end
end

local function sendCurrentSaveSlotName()
  guihooks.trigger("currentSaveSlotName", {saveSlot = career_saveSystem.getCurrentSaveSlot()})
end

local function onAnyMissionChanged(state, mission)
  if not careerActive then return end
  if mission then
    if state == "stopped" then
      blockInputActions(true)
    elseif state == "started" then
      blockInputActions(false)
    end
  end
end

local physicsPausedFromOutside = false
local function onSimTimePauseCalled(paused)
  physicsPausedFromOutside = paused
end

local function requestPause(pause)
  if careerActive then
    if
      freeroam_bigMapMode.bigMapActive() -- when switching to bigmap, dont mess with the pause state
      or pause == simTimeAuthority.getPause()
      or physicsPausedFromOutside
      then return
    end
    simTimeAuthority.pause(pause)
    physicsPausedFromOutside = false
  end
end

local function hasBoughtStarterVehicle()
  return boughtStarterVehicle
end

local function hasInteractedWithOrganization(id)
  return organizationInteraction[id]
end

local function interactWithOrganization(id)
  --print("Interact with: " .. dumps(id))
  organizationInteraction[id] = true
end

local function onVehicleAddedToInventory(data)
  -- if data.vehicleInfo is present, then the vehicle was bought
  if not boughtStarterVehicle and data.vehicleInfo then
    boughtStarterVehicle = true
    career_modules_vehicleShopping.updateVehicleList(true)
  end
end

local function closeAllMenus()
  guihooks.trigger('ChangeState', {state = 'play', params = {}})
end

local function isAutosaveEnabled()
  return autosaveEnabled
end

local function setAutosaveEnabled(enabled)
  autosaveEnabled = enabled
end

local function getAdditionalMenuButtons()
  local ret = {}
  --table.insert(ret, {label = "Test", luaFun = "print('Test!')"})
  if career_modules_delivery_general.isDeliveryModeActive() then
    table.insert(ret, {label = "Map (My Cargo)", luaFun = "career_modules_delivery_cargoScreen.enterMyCargo()"})
  else
    table.insert(ret, {label = "Map", luaFun = "freeroam_bigMapMode.enterBigMap({instant=true})"})
  end
  if not career_modules_linearTutorial.isLinearTutorialActive() and M.hasBoughtStarterVehicle() then
    table.insert(ret, {label = "Progress", luaFun = "guihooks.trigger('ChangeState', {state = 'domainSelection'})", showIndicator = career_modules_milestones_milestones.unclaimedMilestonesCount() > 0})
  end
  if career_modules_vehiclePerformance.isTestInProgress() then
    table.insert(ret, {label = "Cancel Certification", luaFun = "career_modules_vehiclePerformance.cancelTest()", showIndicator = true})
  end
  return ret
end

local function onWorldReadyState(state)
  if state == 2 and switchLevel then
    if not careerActive then
      activateCareer()
    end
    switchLevel = nil
  end
end

local function onSaveFinished()
  if switchLevel then
    deactivateCareer()
    spawn.preventPlayerSpawning = true
    activateCareer()
  end
end

M.onSaveFinished = onSaveFinished
M.switchCareerLevel = switchCareerLevel
M.onWorldReadyState = onWorldReadyState

M.getAdditionalMenuButtons = getAdditionalMenuButtons

M.enableHardcoreMode = enableHardcoreMode
M.enableTutorial = enableTutorial
M.createOrLoadCareerAndStart = createOrLoadCareerAndStart
M.activateCareer = activateCareer
M.deactivateCareer = deactivateCareer
M.deactivateCareerAndReloadLevel = deactivateCareerAndReloadLevel
M.isActive = isActive
M.sendAllCareerSaveSlotsData = sendAllCareerSaveSlotsData
M.sendCurrentSaveSlotData = sendCurrentSaveSlotData
M.getAutosavesForSaveSlot = getAutosavesForSaveSlot
M.requestPause = requestPause
M.hasBoughtStarterVehicle = hasBoughtStarterVehicle
M.hasInteractedWithOrganization = hasInteractedWithOrganization
M.interactWithOrganization = interactWithOrganization
M.closeAllMenus = closeAllMenus
M.isAutosaveEnabled = isAutosaveEnabled
M.setAutosaveEnabled = setAutosaveEnabled
M.getBeamXPLevel = getBeamXPLevel

M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onBeforeSetSaveSlot = onBeforeSetSaveSlot
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onAnyMissionChanged = onAnyMissionChanged
M.onSimTimePauseCalled = onSimTimePauseCalled
M.onVehicleAddedToInventory = onVehicleAddedToInventory
M.onCameraModeChanged = onCameraModeChanged
M.onGlobalCameraSet = onGlobalCameraSet

M.sendCurrentSaveSlotName = sendCurrentSaveSlotName

return M