-- Dyno vehicle controls: context, HUD, inspections, steering, cameras and vehicle restoration.
-- Read the named sections below in order; the final API binds the owner's game hooks.

local lib = {}
local vehicleCommands = require("overhaul/lib/vehicles/vehicleCommands")
local hudSnapshot = require("overhaul/lib/ui/hudSnapshot")

-- Retain the engine serializer's payload bytes while validating the owned VE callee.
local function serializedVehicleCall(functionName, ...)
  local call = vehicleCommands.call("overhaulDynoControls", functionName)
  local arguments = {}
  for index = 1, select('#', ...) do
    local value = select(index, ...)
    arguments[index] = serialize(value)
  end
  return call:sub(1, -2) .. table.concat(arguments, ', ') .. ')'
end

function lib.create(inputs)
  local parts = inputs.parts
  local dynoState = inputs.dynoState
  local dynoSession = inputs.dynoSession

  -- Vehicle context and HUD --------------------------------------------------------------------------

  local function buildVehicleName(vehicleData, inventoryId)
    if not vehicleData then
      return "Current Vehicle"
    end

    -- Prefer the inventory's display name (same as the rest of the career UI) over the raw config id.
    if inventoryId then
      local ok, niceName = pcall(overhaul_career_garage_inventory.getVehicleNiceNameTranslated, inventoryId)
      if ok and type(niceName) == "string" and niceName ~= "" then
        return niceName
      end
    end
    local niceName = vehicleData.niceName
    if type(niceName) == "string" then
      niceName = core_locales.translateWithOrWithoutContext(niceName)
    end
    if type(niceName) == "string" and niceName ~= "" then
      return niceName
    end

    local nameParts = {}
    if vehicleData.year then
      table.insert(nameParts, tostring(vehicleData.year))
    end
    if vehicleData.brand then
      table.insert(nameParts, tostring(vehicleData.brand))
    end
    if vehicleData.name then
      table.insert(nameParts, tostring(vehicleData.name))
    elseif vehicleData.model then
      table.insert(nameParts, tostring(vehicleData.model))
    end

    if #nameParts == 0 then
      return "Current Vehicle"
    end

    return table.concat(nameParts, " ")
  end

  local function getCurrentVehicleContext()
    if not overhaul_career_career.isActive() then
      return nil, "Career mode must be active."
    end

    if gameplay_walk.isWalking() then
      return nil, "Enter one of your vehicles to use the dyno."
    end

    local veh = be:getPlayerVehicle(0)
    if not veh then
      return nil, "Drive a vehicle into the dyno trigger."
    end

    -- The inventory cache can lag behind direct switches between already-spawned owned vehicles. The live object mapping is authoritative for a trigger the player is physically driving into; only fall back to the cache if needed.
    local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(veh:getID())
    if not inventoryId then
      inventoryId = overhaul_career_garage_inventory.getCurrentVehicle()
    end

    if not inventoryId then
      return nil, "Only owned inventory vehicles can use the dyno."
    end

    local vehicleData = overhaul_career_garage_inventory.getVehicles()[inventoryId]
    if not vehicleData then
      return nil, "Vehicle data could not be found."
    end

    return {
      inventoryId = inventoryId,
      veh = veh,
      vehicleId = veh:getID(),
      vehicleData = vehicleData,
      vehicleName = buildVehicleName(vehicleData, inventoryId)
    }
  end

  local function showDynoHud()
    local snapshot = hudSnapshot.build(dynoState.requestSessionData(), "dynoSessionHudLayout")
    if snapshot then guihooks.trigger("DynoSessionHudShow", snapshot) end
  end

  local function hideDynoHud()
    guihooks.trigger("DynoSessionHudHide")
  end

  local function openDynoUi()
    if not dynoSession.active and dynoSession.phase == "offer" then
      dynoSession.error, dynoSession.statusText = nil, nil
    end
    showDynoHud()
  end

  local function closeDynoUi()
    hideDynoHud()
  end

  -- Session reset and live conditions --------------------------------------------------------------

  local function clearPendingSnapshots()
    for _, pending in pairs(inputs.pendingConfigSnapshots) do
      if pending and pending.extraData and pending.extraData.prepaidFee then
        parts.history.refundAmount(pending.extraData.prepaidFeePaid, "Cancelled dyno setup refund", pending.extraData)
        pending.extraData.prepaidFeePaid = 0
        pending.extraData.prepaidFee = false
      end
    end
    table.clear(inputs.pendingConfigSnapshots)
  end

  local function resetDynoSessionState()
    dynoState.restoreRequest = nil
    dynoState.restoreFailed = nil
    dynoState.restoreTransform = nil
    dynoState.displacedAge = nil
    dynoState.serviceRouteSeen = nil
    dynoState.serviceIdleAge = nil
    dynoState.serviceGameplayRoute = nil
    dynoState.serviceDisplacedTransform = nil
    dynoState.serviceRouteInitialized = nil
    if dynoSession.inventoryId then
      local inventory = overhaul_career_garage_inventory
      local record = inventory.getVehicles()[dynoSession.inventoryId]
      if record and dynoSession.originalConfig then record.config = dynoSession.originalConfig end
      inventory.setTransientBuild(dynoSession.inventoryId, false)
    end
    dynoState.conditionRefreshToken = dynoState.conditionRefreshToken + 1
    dynoState.conditionRefreshPending = false
    dynoState.conditionRefreshCallbacks = {}
    dynoState.ownershipWaitCallbacks = {}
    hideDynoHud()
    clearPendingSnapshots()
    dynoSession.active = false
    dynoSession.inventoryId = nil
    dynoSession.sourceVehicleId = nil
    dynoSession.originalTransform = nil
    dynoSession.originalConfig = nil
    dynoSession.originalPartConditions = nil
    dynoSession.originalLiveConfig = nil
    dynoSession.sessionVehicleId = nil
    dynoSession.selectedHubId = DEFAULT_DYNO_HUB_ID
    dynoSession.hubConfigApplied = false
    dynoSession.pullState = nil
    dynoSession.result = nil
    dynoSession.pullsUsed = 0
    dynoSession.setupFeeRefundable = false
    dynoSession.feePaid = 0
    dynoSession.policy = nil
    dynoSession.serviceOpen = nil
    dynoSession.resumePhase = nil
    dynoSession.retryArmDelay = nil
    dynoSession.lastHudPushTime = nil
    dynoSession.phase = "offer"
    dynoSession.error = nil
    dynoSession.statusText = nil
  end

  local function flushConditionRefreshCallbacks()
    local callbacks = dynoState.conditionRefreshCallbacks
    dynoState.conditionRefreshCallbacks = {}
    for _, callback in ipairs(callbacks) do
      if callback then callback() end
    end
  end

  local function refreshLiveVehicleConditions(context, callback)
    if callback then
      dynoState.conditionRefreshCallbacks[#dynoState.conditionRefreshCallbacks + 1] = callback
    end
    if dynoState.conditionRefreshPending then
      return true
    end
    if not context or not context.inventoryId then
      flushConditionRefreshCallbacks()
      return false
    end

    dynoState.conditionRefreshPending = true
    dynoState.conditionRefreshToken = dynoState.conditionRefreshToken + 1
    local token = dynoState.conditionRefreshToken
    local function finished()
      if token ~= dynoState.conditionRefreshToken then return end
      dynoState.conditionRefreshPending = false
      flushConditionRefreshCallbacks()
    end

    overhaul_career_garage_inventory.updatePartConditions(context.vehicleId, context.inventoryId, finished)
    return true
  end

  dynoState.normalizeQualityFlags = function(flags)
    local normalized = {}
    if type(flags) == "table" then
      for key, value in pairs(flags) do
        if type(key) == "number" then
          normalized[tostring(value)] = true
        elseif value then
          normalized[tostring(key)] = true
        end
      end
    end
    return normalized
  end

  local function getQualityFromFlags(flags, valid)
    return valid and (not flags or next(flags) == nil) and "clean" or "warning"
  end

  local function setDynoError(message, phase)
    dynoSession.error = message
    dynoSession.phase = phase or dynoSession.phase
    dynoSession.statusText = dynoSession.phase ~= "offer" and message or nil
    showDynoHud()
  end

  -- Transforms, freeze and ignition ----------------------------------------------------------------

  local function captureVehicleTransform(veh)
    if not veh then
      return nil
    end

    return {
      pos = vec3(veh:getPosition()),
      rot = quat(0, 0, 1, 0) * quat(veh:getRefNodeRotation())
    }
  end

  local function restoreVehicleTransform(veh, transform, reset)
    if not veh or not transform or not transform.pos or not transform.rot then
      return false
    end

    if spawn and spawn.safeTeleport then
      spawn.safeTeleport(veh, transform.pos, transform.rot, nil, nil, nil, nil, reset == true)
      return true
    end

    veh:setPosRot(
      transform.pos.x,
      transform.pos.y,
      transform.pos.z,
      transform.rot.x,
      transform.rot.y,
      transform.rot.z,
      transform.rot.w
    )
    return true
  end

  -- core_vehicleBridge is a level preset; the respawn callback of finishSessionRestore can run after it unloaded, so freeze and ignition keep the direct vehicle command as the fallback.
  local function setVehicleFreeze(veh, shouldFreeze)
    if not veh then
      return
    end

    if core_vehicleBridge and core_vehicleBridge.executeAction then
      pcall(function()
        core_vehicleBridge.executeAction(veh, "setFreeze", shouldFreeze and true or false)
      end)
    else
      veh:queueLuaCommand(string.format("controller.setFreeze(%d)", shouldFreeze and 1 or 0))
    end
  end

  local function setVehicleIgnition(veh, level)
    if not veh then
      return
    end

    if core_vehicleBridge and core_vehicleBridge.executeAction then
      pcall(function()
        core_vehicleBridge.executeAction(veh, "setIgnitionLevel", level)
      end)
    else
      veh:queueLuaCommand(string.format("if electrics and electrics.setIgnitionLevel then electrics.setIgnitionLevel(%d) end", level))
    end
  end

  -- Steering protection ----------------------------------------------------------------------------

  local function getRuntimeFFBConfig(veh)
    local result = {}
    for _, action in ipairs({"steering", "accelerate", "brake"}) do
      local config, id = core_input_bindings.getFFBConfigForAction(veh, action)
      if config then config.FFBID = id; result[action] = config end
    end
    return result
  end

  local function protectDynoSteering(veh, acknowledge)
    if not veh then return end
    local id = veh:getID()
    inputs.protectedSteeringVehicles[id] = true
    local config = getRuntimeFFBConfig(veh)
    veh:queueLuaCommand(string.format([[
      extensions.load("overhaulDynoControls")
      %s
      %s
    ]], serializedVehicleCall("protect", config), acknowledge and string.format(
      "obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(%d, 'dynoSteeringReady', '%d, %d'))", require('overhaul/lib/vehicles/callbacks').open('dynoSteeringReady', {owner = 'dynoSession', vehId = id}), id, dynoState.steeringSetupToken) or ""))
  end

  local function releaseDynoSteering(veh)
    if not veh then return end
    inputs.protectedSteeringVehicles[veh:getID()] = nil
    local config = getRuntimeFFBConfig(veh)
    veh:queueLuaCommand(string.format([[
      if overhaulDynoControls then %s end
    ]], serializedVehicleCall("release", config)))
  end

  local function releaseAllDynoSteering()
    for id in pairs(inputs.protectedSteeringVehicles) do
      local veh = getObjectByID(id)
      if veh then releaseDynoSteering(veh) end
      inputs.protectedSteeringVehicles[id] = nil
    end
  end

  local function onSteeringProtectionReady(id, token)
    if token ~= dynoState.steeringSetupToken or not dynoState.pendingSteeringSetup or id ~= dynoSession.sourceVehicleId or dynoSession.phase ~= "starting" then return end
    local start = dynoState.pendingSteeringSetup
    dynoState.pendingSteeringSetup = nil
    start()
  end

  -- Spawn callbacks run before the new vehicle starts simulation. Queue the guard on the new VM as well as muting the old VM before asking inventory to rebuild.
  local function onVehicleSpawned(id)
    if not dynoSession.active then return end
    local mapped = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(dynoSession.inventoryId)
    if id == dynoSession.sourceVehicleId or id == dynoSession.sessionVehicleId or id == mapped then
      protectDynoSteering(getObjectByID(id))
    end
  end

  local function onFFBConfigChanged()
    for id in pairs(inputs.protectedSteeringVehicles) do
      protectDynoSteering(getObjectByID(id))
    end
  end

  local function stopVehiclePullExtension(veh)
    if not veh then
      return
    end

    veh:queueLuaCommand(string.format([[
      if extensions.isExtensionLoaded("overhaulDynoSession") then
        if overhaulDynoSession and overhaulDynoSession.abortPull then
          %s
        end
      end
    ]], vehicleCommands.call("overhaulDynoSession", "abortPull")))
  end

  -- Parking spot and cameras -----------------------------------------------------------------------

  local function getDynoParkingSpot()
    local station = dynoState.station
    local sitePath = station and station.mapId == getCurrentLevelIdentifier()
      and inputs.levelData.assetPath(station.mapId, station.sitesFile)

    if not sitePath then
      return nil, "Dyno sites file could not be found."
    end

    local sites = gameplay_sites_sitesManager.loadSites(sitePath)
    if not sites or not sites.parkingSpots or not sites.parkingSpots.byName then
      return nil, "Dyno parking spot data is missing."
    end

    local parkingSpot = sites.parkingSpots.byName[station.parkingSpotName]
    if not parkingSpot or parkingSpot.missing then
      return nil, "Dyno parking spot '" .. station.parkingSpotName .. "' was not found."
    end

    return parkingSpot
  end

  local function isDisplacedFromDyno(veh)
    local spot = getDynoParkingSpot()
    if not veh or not spot or not spot.pos then return false end
    -- This runs every frame, including while a service is open. Read scalars
    -- rather than allocating a position vector for each displacement check.
    local x, y, z = veh:getPositionXYZ()
    local dx, dy, dz = x - spot.pos.x, y - spot.pos.y, z - spot.pos.z
    local distance = inputs.getRecoveryConfig().displacedDistanceMetres
    return dx * dx + dy * dy + dz * dz > distance * distance
  end

  -- Inventory respawns can keep the scene object ID while renumbering its nodes. Refresh after the spawn callbacks publish the new vdata, including on exit when the session itself is already inactive. A pose reset alone keeps stale IDs.
  local pendingCameraRefresh = {}
  local function refreshDynoCamera(veh)
    pendingCameraRefresh[veh:getID()] = 2
  end

  local function updateDynoCameras()
    for id, frames in pairs(pendingCameraRefresh) do
      if frames > 0 then
        pendingCameraRefresh[id] = frames - 1
      else
        pendingCameraRefresh[id] = nil
        local veh = getObjectByID(id)
        if veh then
          -- Rebuild all camera modes from the vehicle's current camera definitions, including model-specific reference nodes, offsets and default distance.
          core_camera.onVehicleSpawned(id)
          if be:getPlayerVehicleID(0) == id then core_camera.resetCamera(0) end
        end
      end
    end
  end

  local function alignVehicleToDynoSpot(veh, parkingSpot)
    if not veh or not parkingSpot or not parkingSpot.rot then return end
    local pos = veh:getPosition()
    local rot = quat(0, 0, 1, 0) * quat(parkingSpot.rot)
    veh:setPosRot(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
    if veh.setOriginalTransform then
      veh:setOriginalTransform(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
    end
  end

  local function moveVehicleToDyno(veh)
    local parkingSpot, parkingError = getDynoParkingSpot()
    if not parkingSpot then
      return false, parkingError
    end

    if parkingSpot.moveResetVehicleTo then
      local ok, err = pcall(function()
        parkingSpot:moveResetVehicleTo(veh:getID(), nil, nil, nil, nil, true)
      end)
      if ok then
        alignVehicleToDynoSpot(veh, parkingSpot)
        refreshDynoCamera(veh)
        return true
      end
      return false, tostring(err)
    end

    return false, "Dyno parking spot could not move the vehicle."
  end

  return {
    buildVehicleName = buildVehicleName,
    getCurrentVehicleContext = getCurrentVehicleContext,
    showDynoHud = showDynoHud,
    hideDynoHud = hideDynoHud,
    startReadinessMessage = function(context)
      local inventory = overhaul_career_garage_inventory
      if not context or not context.veh or not context.inventoryId then
        return "Your vehicle is unavailable. Drive into the dyno bay again."
      end
      if inventory.isDamageRestorePending and inventory.isDamageRestorePending(context.inventoryId) then
        return "Your vehicle is still being restored. Please wait."
      end
    end,
    openDynoUi = openDynoUi,
    closeDynoUi = closeDynoUi,
    resetDynoSessionState = resetDynoSessionState,
    refreshLiveVehicleConditions = refreshLiveVehicleConditions,
    getQualityFromFlags = getQualityFromFlags,
    setDynoError = setDynoError,
    captureVehicleTransform = captureVehicleTransform,
    restoreVehicleTransform = restoreVehicleTransform,
    setVehicleFreeze = setVehicleFreeze,
    setVehicleIgnition = setVehicleIgnition,
    protectDynoSteering = protectDynoSteering,
    releaseDynoSteering = releaseDynoSteering,
    releaseAllDynoSteering = releaseAllDynoSteering,
    onSteeringProtectionReady = onSteeringProtectionReady,
    onVehicleSpawned = onVehicleSpawned,
    onFFBConfigChanged = onFFBConfigChanged,
    stopVehiclePullExtension = stopVehiclePullExtension,
    refreshDynoCamera = refreshDynoCamera,
    updateDynoCameras = updateDynoCameras,
    moveVehicleToDyno = moveVehicleToDyno,
    getDynoParkingSpot = getDynoParkingSpot,
    isDisplacedFromDyno = isDisplacedFromDyno,
  }
end

return lib
