-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/gameplay/garageMode.lua (BeamNG 0.40).

-- Controls garage cameras, input locks, lighting and delayed vehicle freezing.
local M = {}
local jsonCatalog = require("overhaul/lib/platform/jsonCatalog")
local optional = require("overhaul/lib/platform/optional")
local levelName
local garageLevelPath
local testLevelPath
local locationConfig
local ceilingHeightMeters
local eastPillarBoundaryXMeters
local westPillarBoundaryXMeters
local ceilingObjectGroup
local westObjectGroup
local eastObjectGroup
local lightObjectGroups = {}
local lightObjectState = {}
local blockedInputActions = core_input_actionFilter.createActionTemplate({"funStuff", "bigMap", "vehicleMenues", "vehicleTeleporting", "physicsControls", "aiControls", "walkingMode", "resetPhysics"})

local zoomSpeed = 0.5
local defaultFovDegrees = 48

local vehicleToLoad
local framesUntilFreeze

local previousFovDegrees
local previousDefaultRotation

local startTestCoroutine
local garageMenuState

local lastOwnedVehicleId

local cameraPresets = {
  default = vec3(145, -5, 0),
  front = vec3(180, 0, 0),
  back = vec3(0, 0, 0),
  side = vec3(90, 0, 0),
  left = vec3(-90, 0, 0),
  right = vec3(90, 0, 0),
  top = vec3(90, -90, 0), -- may produce an unwanted rotation for a few degrees depending on a starting vector
}

local active = false
local hiddenGroups = {}
local objectsAutohide = true
local useCurrentLocation
local navigateToPlayOnFadeout = false

-- Per-level config is the only source of showroom geometry and test destinations.
local function unavailable(reason)
  log("W", "garageMode", "Garage location unavailable: " .. reason)
end

local function namedValue(value)
  return type(value) == "string" and value ~= ""
end

local function loadLocation(levelId, quietMissing)
  local level = levelId and core_levels.getLevelByName(levelId)
  if not level then
    if not quietMissing then unavailable("level metadata missing for " .. tostring(levelId)) end
    return
  end
  local file = "/levels/" .. level.levelName .. "/overhaul/garageMode.json"
  if not FS:fileExists(file) then
    if not quietMissing then unavailable("no config at " .. file) end
    return
  end
  -- Stock jsonReadFile returns nil for a missing file and traps decode errors; the pcall covers only its native read, which cannot be proven non-throwing.
  local ok, config = pcall(jsonReadFile, file)
  if not ok or type(config) ~= "table" or config.version ~= 1 then
    unavailable(file .. " requires a version 1 config")
    return
  end
  if not namedValue(config.spawnPoint) or type(config.lightGroups) ~= "table"
    or (config.defaultShowroom ~= nil and type(config.defaultShowroom) ~= "boolean") then
    unavailable(file .. " requires a named spawnPoint, lightGroups array and boolean defaultShowroom")
    return
  end
  local spawnDeclared = false
  for _, point in ipairs(level.spawnPoints or {}) do
    if point.objectname == config.spawnPoint then spawnDeclared = true end
  end
  if not spawnDeclared then
    unavailable(file .. " spawnPoint is absent from core_levels metadata: " .. config.spawnPoint)
    return
  end
  for key, group in pairs(config.lightGroups) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #config.lightGroups or not namedValue(group) then
      unavailable(file .. " lightGroups must contain scene group names")
      return
    end
  end
  local occlusion = config.cameraOcclusion
  if occlusion ~= nil then
    if type(occlusion) ~= "table" or not jsonCatalog.finite(occlusion.ceilingZ)
      or not jsonCatalog.finite(occlusion.eastBoundaryX) or not jsonCatalog.finite(occlusion.westBoundaryX)
      or occlusion.eastBoundaryX > occlusion.westBoundaryX
      or not namedValue(occlusion.ceilingGroup) or not namedValue(occlusion.eastGroup) or not namedValue(occlusion.westGroup) then
      unavailable(file .. " cameraOcclusion requires finite ordered bounds and named groups")
      return
    end
  end
  if (config.testLevel ~= nil and not jsonCatalog.validId(config.testLevel))
    or (config.exitWaypoint ~= nil and not namedValue(config.exitWaypoint)) then
    unavailable(file .. " has an invalid testLevel or exitWaypoint")
    return
  end
  return config, level
end

local function selectShowroom()
  local config, level = loadLocation(getCurrentLevelIdentifier(), true)
  if config then return config, level end
  local files = FS:findFiles("/levels/", "garageMode.json", -1, false, false) or {}
  table.sort(files)
  local firstConfig, firstLevel
  for _, file in ipairs(files) do
    local levelId = file:match("/?levels/([^/]+)/overhaul/garageMode%.json$")
    if levelId then
      config, level = loadLocation(levelId)
      if config then
        if config.defaultShowroom then return config, level end
        if not firstConfig then firstConfig, firstLevel = config, level end
      end
    end
  end
  if not firstConfig then unavailable("no configured showroom levels found") end
  return firstConfig, firstLevel
end

local function setLocation(config, level)
  if levelName ~= (level and level.levelName) then hiddenGroups = {} end
  locationConfig = config
  levelName = level and level.levelName
  garageLevelPath = levelName and path.getPathLevelMain(levelName)
  testLevelPath = nil
  local occlusion = config and config.cameraOcclusion or {}
  ceilingHeightMeters = occlusion.ceilingZ
  eastPillarBoundaryXMeters = occlusion.eastBoundaryX
  westPillarBoundaryXMeters = occlusion.westBoundaryX
  ceilingObjectGroup = occlusion.ceilingGroup
  eastObjectGroup = occlusion.eastGroup
  westObjectGroup = occlusion.westGroup
  local groups = config and config.lightGroups or {}
  local lightingChanged = #groups ~= #lightObjectGroups
  for i, group in ipairs(groups) do
    if group ~= lightObjectGroups[i] then lightingChanged = true end
  end
  lightObjectGroups = groups
  if lightingChanged then
    lightObjectState = {}
    for i in ipairs(lightObjectGroups) do lightObjectState[i] = true end
  end
end

local function setVehicleDirty(vehicleDirty, switchedToNewVehicle)
  if not overhaul_career_career.isActive() then return end
  -- Garage has no save button, so dirty-vehicle notifications remain disabled.
end

local function setGarageMenuState(state)
  garageMenuState = state

  -- set dirty in the "paint" menu because we cant tell if something actually changed
  if state == "paint" then
    setVehicleDirty(true)
  end
end

local function getGarageMenuState()
  return garageMenuState
end

local function onOverhaulEnterVehicleFinished(vehicleId)
  if vehicleId then
    lastOwnedVehicleId = vehicleId
  end
end

local function setCameraInJob(job)
  -- This changes the default rotation. Changing it back is probably not worth it because it requires waiting for several frames until the reset is done
  commands.setGameCamera()
  core_camera.setByName(0, "orbit", false)
  job.sleep(0.00001) -- sleep for one frame so the orbit cam can update correctly
  core_camera.setDefaultRotation(be:getPlayerVehicleID(0), cameraPresets[job.args[1] or "default"])
  core_camera.resetCamera(0)
end

local function setCamera(preset)
  core_jobsystem.create(setCameraInJob, nil, preset)
end

local hasPendingCameraReset = false
local function vehicleSpawnedOrGarageModeStarted(vehicleId)
  if not active then return end
  if getCurrentLevelIdentifier() == levelName then
    -- The authored name was checked against core_levels metadata when loading config.
    local spawnPoint = scenetree.findObject(locationConfig.spawnPoint)
    if spawnPoint then
      local vehicle = scenetree.findObjectById(vehicleId)
      spawn.safeTeleport(vehicle, spawnPoint:getPosition(), quat(0,0,1,0) * spawnPoint:getRotation(), nil, nil, nil, true)
    else
      unavailable("spawn object missing: " .. locationConfig.spawnPoint)
    end
  end
  -- We have to call the vlua functions a few frames later, because otherwise they can get reset by another init call in vlua
  framesUntilFreeze = 5
  hasPendingCameraReset = true
end

local function onVehicleSpawned(vehicleId)
  if not active then return end

  -- this calls safeTeleport BEFORE setSafePosition is called in spawn.lua, but it works out because setSafePosition resets it on the same vehicle position
  vehicleSpawnedOrGarageModeStarted(vehicleId)
end

local function onSpawnCCallback(vehicleId)
  if not active then return end

  -- turn off the engine on spawn
  local additionalVehicleData = {spawnWithEngineRunning = false}
  core_vehicle_manager.queueAdditionalVehicleData(additionalVehicleData, vehicleId)
end

local function getCurrentVehicle()
  local result = nil
  if gameplay_walk and gameplay_walk.isWalking() then
    return result
  end

  -- get the current vehicle to load it in the garage
  local vehicle = getPlayerVehicle(0)
  local playerVehicleData = core_vehicle_manager.getPlayerVehicleData()
  if vehicle and playerVehicleData then
    local config = serialize(playerVehicleData.config) -- when using "vehicle.partConfig" here, the color of the vehicle will be wrong if you use a custom default config
    local model = vehicle.JBeam
    result = { model, {config=config} }
  end
  return result
end

local function onGarageEnter(context, toRoute, fromRoute, data)
  local routeName = toRoute and toRoute.name or "garage"
  data.layoutMenu = {
    topbar = {
      show = true,
      tabs = {
        { routeName = "garage", label = "Garage", visible = true, enabled = true },
        { routeName = "garage.vehicle.tuning", label = "Tuning", visible = true, enabled = true },
      },
      selectedTab = routeName == "garage.vehicle.tuning" and 1 or 0,
      hints = {
        tabLeft = "Previous Tab",
        tabRight = "Next Tab",
      },
      rightWidget = "garageInfo",
    },
    header = {
      heading = routeName == "garage.vehicle.tuning" and "Garage Tuning" or "Garage",
      breadcrumbs = routeName == "garage.vehicle.tuning" and {
        { label = "Garage", routeName = "garage" },
        { label = "Tuning", routeName = "garage.vehicle.tuning" },
      } or {},
    },
    rails = {
      left = {},
      right = {},
      bottom = {},
    },
    content = {
      main = {},
      side = {},
      panels = {},
      rawRouteData = {},
    },
    nav = {
      scopeId = "garage-root",
      autoFocus = true,
    },
  }
  data.garage = {
    routeName = routeName,
    context = context or {},
  }
end

local function vehicleByIdOrActive(vehicleId)
  local modelKey = vehicleId
  if not modelKey then
    local vehicle = getPlayerVehicle(0)
    if not vehicle then
      return nil
    end
    modelKey = vehicle:getJBeamFilename()
  end

  local info = core_vehicles.getModel(modelKey)
  if info and info.model then
    local brand = info.model.Brand
    local name = info.model.Name
    return string.format("%s %s", brand, name)
  end
end

local zoomDirectionLastFrame = 0
local zoomTimerSeconds = 0
local function zoom(value)
  if not active then return end
  if value ~= 0 then
    local zoomRate = -zoomSpeed * value
    if zoomDirectionLastFrame ~= (value > 0) then
      zoomTimerSeconds = 0
    end
    zoomTimerSeconds = zoomTimerSeconds + 0.05
    core_camera.cameraZoom(zoomRate * zoomTimerSeconds)
    zoomDirectionLastFrame = value > 0
  end
end

local function setHiddenRec(object, hidden)
  object.hidden = hidden
  if object:isSubClassOf("SimSet") then
    for i=0, object:size() - 1 do
      setHiddenRec(object:at(i), hidden)
    end
  end
end

local function hideGroup(groupName, hidden)
  if not groupName then return end
  local group = scenetree.findObject(groupName)
  if group then
    setHiddenRec(group, hidden)
  elseif hiddenGroups[groupName] == nil then
    unavailable("scene group missing: " .. groupName)
  end
  hiddenGroups[groupName] = hidden
end

local function objectsShouldBeHidden()
  return objectsAutohide and not editor.isEditorActive()
end

local function setObjectGroupVisibility(west)
  local groupName = west and westObjectGroup or eastObjectGroup
  if not groupName then return end
  local pillarsShouldBeHidden
  if west then
    pillarsShouldBeHidden = function(x) return objectsShouldBeHidden() and x > westPillarBoundaryXMeters end
  else
    pillarsShouldBeHidden = function(x) return objectsShouldBeHidden() and x < eastPillarBoundaryXMeters end
  end

  if not hiddenGroups[groupName] and pillarsShouldBeHidden(core_camera.getPosition().x) then
    hideGroup(groupName, true)
  end

  if hiddenGroups[groupName] and not pillarsShouldBeHidden(core_camera.getPosition().x) then
    hideGroup(groupName, false)
  end
end

local function ceilingGroupShouldBeHidden(z)
  return objectsShouldBeHidden() and z > ceilingHeightMeters
end

local function setCeilingGroupVisibility()
  if not ceilingObjectGroup then return end
  if not hiddenGroups[ceilingObjectGroup] and ceilingGroupShouldBeHidden(core_camera.getPosition().z) then
    hideGroup(ceilingObjectGroup, true)
  end

  if hiddenGroups[ceilingObjectGroup] and not ceilingGroupShouldBeHidden(core_camera.getPosition().z) then
    hideGroup(ceilingObjectGroup, false)
  end
end

local function onUpdate(dtReal)
  if not active then return end
  if core_gamestate.state.state ~= "overhaul" then
    -- Set the gamestate here because it can get overwritten from other places when going from missions into garage mode
    core_gamestate.setGameState('overhaul', 'garage', 'garage', {isFreeroam = useCurrentLocation})
  end
  if framesUntilFreeze then
    framesUntilFreeze = framesUntilFreeze - 1
    if framesUntilFreeze <= 0 then
      core_vehicleBridge.executeAction(getPlayerVehicle(0),'setFreeze', true)
      framesUntilFreeze = false
    end
  end
  setObjectGroupVisibility(true)
  setObjectGroupVisibility(false)
  setCeilingGroupVisibility()

  if zoomTimerSeconds > 0 then
    zoomTimerSeconds = zoomTimerSeconds - dtReal
    if zoomTimerSeconds <= 0 then
      core_camera.cameraZoom(0)
      zoomTimerSeconds = 0
    end
  end

  -- when spawning a new vehicle, set the cameras max distance and default rotation
  if hasPendingCameraReset and core_camera.getActiveCamName(0) == "orbit" then
    local orbitCameraData = core_camera.getCameraDataById(be:getPlayerVehicleID(0)).orbit
    if orbitCameraData then
      previousFovDegrees = orbitCameraData.fov
      previousDefaultRotation = orbitCameraData.defaultRotation

      core_camera.setMaxDistance(be:getPlayerVehicleID(0), orbitCameraData.defaultDistance)
      core_camera.setDefaultRotation(be:getPlayerVehicleID(0), cameraPresets.default)
      core_camera.setFOV(be:getPlayerVehicleID(0), defaultFovDegrees)
      core_camera.setSkipFovModifier(be:getPlayerVehicleID(0), true)
      core_camera.resetCamera(0)
    end
    hasPendingCameraReset = false
  end
end

local function setLighting(state)
  if state then
    lightObjectState = state
  else
    lightObjectState = {}
    for i in ipairs(lightObjectGroups) do lightObjectState[i] = true end
  end
  for i in ipairs(lightObjectGroups) do
    hideGroup(lightObjectGroups[i], not lightObjectState[i])
  end
end

local function setActive(isActive)
  active = isActive
  if active then
    M.onUpdate = onUpdate
  else
    M.onUpdate = nil
  end
  extensions.hookUpdate("onUpdate")
end

local function activateGarageMode()
  core_gamestate.setGameState('overhaul', 'garage', 'garage', {isFreeroam = useCurrentLocation})
  setActive(true)
  objectsAutohide = true

  -- block some input actions
  core_input_actionFilter.setGroup('garageModeBlockedActions', blockedInputActions)
  core_input_actionFilter.addAction(0, 'garageModeBlockedActions', true)

  pushActionMap("GarageMode")

  if overhaul_career_career.isActive() then
    lastOwnedVehicleId = overhaul_career_garage_inventory.getCurrentVehicle()
  end
  vehicleSpawnedOrGarageModeStarted(be:getPlayerVehicleID(0))
end

local garageInitModules = {"overhaul_integration_services_garageMode", "overhaul_career_garage_inventory"}
local garageInitCurrentStep = 1
local function callNextInitStep()
  local module = optional(garageInitModules[garageInitCurrentStep])
  if module and module.garageModeStartStep then module.garageModeStartStep() else garageInitCurrentStep = 1 end
end

local function initStepFinished()
  garageInitCurrentStep = garageInitCurrentStep + 1
  if garageInitCurrentStep > tableSize(garageInitModules) then
    garageInitCurrentStep = 1
    return
  end
  callNextInitStep()
end

local garageModeInitActive
local function garageModeStartStep()
  garageModeInitActive = true
  overhaul_career_saveSystem.saveCurrent()
end

local function onOverhaulVehicleSaveFinished()
  if garageModeInitActive then
    initStepFinished()
    garageModeInitActive = nil
  end
end

local activateGarageModeOnLevelLoad
local function start(requestedCurrentLocation, skipInventoryStep)
  useCurrentLocation = requestedCurrentLocation
  if useCurrentLocation then
    setLocation(loadLocation(getCurrentLevelIdentifier(), true))
    if overhaul_career_career.isActive() then
      if tableSize(overhaul_career_garage_inventory.getVehicles()) == 0 then
        ui_message("No vehicles in inventory! Buy a vehicle to enter garage mode.", nil, "garageMode")
        return
      end

      if not skipInventoryStep and overhaul_career_garage_inventory.onBeforeGarage and not overhaul_career_garage_inventory.onBeforeGarage() then
        return
      end

      -- clearing the cache because of some garage specific filters
      core_vehicles.clearCache()
    end
    core_camera.setByName(0, "orbit", false)
    core_vehicleBridge.executeAction(getPlayerVehicle(0),'setIgnitionLevel', 0)
    activateGarageMode()
    if overhaul_career_career.isActive() then
      garageInitCurrentStep = 1
      callNextInitStep()
    end
    if not overhaul_career_career.isActive() then
      extensions.ui_router.navigate("garage")
    end
  else
    local config, level = selectShowroom()
    if not config then return false end
    setLocation(config, level)
    -- load the level
    activateGarageModeOnLevelLoad = true
    core_levels.startLevel(garageLevelPath, true, nil, getCurrentVehicle())
  end
end

local function endGarageMode()
  if not active then return end

  setVehicleDirty(false)
  setActive(false)
  garageMenuState = nil
  useCurrentLocation = nil
  core_input_actionFilter.setGroup('garageModeBlockedActions', blockedInputActions)
  core_input_actionFilter.addAction(0, 'garageModeBlockedActions', false)
  popActionMap("GarageMode")

  local cameraData = core_camera.getCameraDataById(be:getPlayerVehicleID(0))
  if cameraData and cameraData.orbit then
    cameraData.orbit:setMaxDistance(nil)
    cameraData.orbit:setDefaultRotation(previousDefaultRotation)
    cameraData.orbit:setFOV(previousFovDegrees)
    cameraData.orbit:setSkipFovModifier(false)
    cameraData.orbit:init()
  end
  objectsAutohide = false
  core_gamestate.setGameState('overhaul','overhaul',nil)
  core_vehicleBridge.executeAction(getPlayerVehicle(0),'setFreeze', false)

  extensions.hook("onEndGarageMode")
end

local function stop()
  core_vehicleBridge.executeAction(getPlayerVehicle(0),'setIgnitionLevel', 3)
  endGarageMode()
end

local function getLighting()
  return lightObjectState
end

local function onClientStartMission(levelPath)
  if vehicleToLoad then
    core_vehicles.replaceVehicle(unpack(vehicleToLoad))
    vehicleToLoad = nil
  end
end

local function onClientPreStartMission(levelPath)
  if activateGarageModeOnLevelLoad and not active then
    unloadAutoExtensions()
    loadPresetExtensions()
    activateGarageMode()
    activateGarageModeOnLevelLoad = nil
    if not overhaul_career_career.isActive() then
      extensions.ui_router.navigate("garage")
    end
  elseif active then
    endGarageMode()
  end
end

local function onSerialize()
  local data = {}
  data.active = active
  return data
end

local function onDeserialized(v)
  if v.active then setLocation(loadLocation(getCurrentLevelIdentifier(), true)) end
  setActive(v.active)
end

local function isActive()
  return active == true
end

local function setObjectsAutohide(v)
  objectsAutohide = v
end

local function isObjectsAutohide()
  return objectsAutohide
end

local function onThumbnailTriggered(active)
  local currentLevel = getCurrentLevelIdentifier()
  if currentLevel ~= levelName then
    local config, level = loadLocation(currentLevel, true)
    if not config then return end
    setLocation(config, level)
  end
  if currentLevel == levelName then
    if active then
      guihooks.trigger("GarageModeBlackscreen", {active = true})
      -- When taking a thumbnail, end the garage mode
      endGarageMode()
      hideGroup(eastObjectGroup, true)
      hideGroup(westObjectGroup, false)
      hideGroup(ceilingObjectGroup, false)
    else
      activateGarageMode()
      guihooks.trigger("GarageModeBlackscreen", {active = false})
    end
  end
end

local function startTestWorkitem(job)
  -- move the camera to the default position
  core_camera.speedFactor = 10000
  setCameraInJob(job)
  job.sleep(0.5)
  core_camera.speedFactor = 1
  commands.setFreeCamera()
  core_camera.setFOV(0, defaultFovDegrees)

  -- let the vehicle drive forward
  local playerVeh = getPlayerVehicle(0)
  core_vehicleBridge.executeAction(playerVeh, 'setFreeze', false)
  if locationConfig.exitWaypoint then
    playerVeh:queueLuaCommand('ai.driveUsingPath({wpTargetList = {' .. string.format("%q", locationConfig.exitWaypoint) .. '}})')
    job.sleep(2)
  end

  -- fade to black
  guihooks.trigger("FadeScreen", {active = true})
  job.sleep(1.5)

  -- load the test level
  navigateToPlayOnFadeout = true
  freeroam_freeroam.startFreeroam(testLevelPath, nil, nil, getCurrentVehicle())
end

local function testVehicle()
  if not locationConfig or not locationConfig.testLevel then
    unavailable("no testLevel configured for the current garage")
    return false
  end
  local level = core_levels.getLevelByName(locationConfig.testLevel)
  if not level then
    unavailable("test level metadata missing for " .. locationConfig.testLevel)
    return false
  end
  testLevelPath = path.getPathLevelMain(level.levelName)
  core_jobsystem.create(startTestWorkitem)
end

local function getLastOwnedVehicleId()
  return lastOwnedVehicleId
end

local function onLoadingScreenFadeout()
  if navigateToPlayOnFadeout then
    navigateToPlayOnFadeout = false
    extensions.ui_router.navigate("play")
  end
end

M.start = start
M.stop = stop
M.isActive = isActive
M.zoom = zoom
M.setCamera = setCamera
M.setObjectsAutohide = setObjectsAutohide
M.isObjectsAutohide = isObjectsAutohide
M.testVehicle = testVehicle
M.setLighting = setLighting
M.getLighting = getLighting
M.setGarageMenuState = setGarageMenuState
M.getGarageMenuState = getGarageMenuState
M.setVehicleDirty = setVehicleDirty
M.getLastOwnedVehicleId = getLastOwnedVehicleId
M.vehicleByIdOrActive = vehicleByIdOrActive
M.onGarageEnter = onGarageEnter
M.initStepFinished = initStepFinished
M.garageModeStartStep = garageModeStartStep

M.onVehicleSpawned = onVehicleSpawned
M.onSpawnCCallback = onSpawnCCallback
M.onClientPreStartMission = onClientPreStartMission
M.onClientStartMission = onClientStartMission
M.onDeserialized = onDeserialized
M.onSerialize = onSerialize
M.onThumbnailTriggered = onThumbnailTriggered
M.onOverhaulEnterVehicleFinished = onOverhaulEnterVehicleFinished
M.onOverhaulVehicleSaveFinished = onOverhaulVehicleSaveFinished
M.onLoadingScreenFadeout = onLoadingScreenFadeout

M.onOverhaulActive = function(value)
  if not value then
    if active then stop() end
    lastOwnedVehicleId = nil
    garageModeInitActive = nil
    garageInitCurrentStep = 1
  end
end
for name, fn in pairs(M) do
  if type(fn) == "function" and name:match("^on") and not name:match("^onOverhaul") then
    M[name] = function(...)
      if overhaul_career_career and overhaul_career_career.isActive() then return fn(...) end
    end
  end
end
return M
