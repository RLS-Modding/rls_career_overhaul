-- Business fleet part conditions, repair baselines and insurance repairs.
-- Read owner inputs, replacement data, baseline capture, then repair operations and the returned API.
local part = {}

-- Each construction shares state and helpers with that owner load.
function part.new(inputs)
  local fleetState = inputs.fleetState

  local function getVisualValueFromMileage(mileage)
    if not mileage then
      return nil
    end
    return overhaul_career_market_vehicleShopping.getVisualValueFromMileage(mileage)
  end

  local function requestFleetRepairBaseline(businessId, vehicle, vehObj)
    fleetState.fleetBaselineCaptures[vehicle] = {businessId = businessId, spawnedId = vehObj:getID(), elapsed = 0, quiet = 0, interval = 0}
  end

  -- Compares integrity and replacement flags of two part-condition snapshots.
  local function sameFleetDamageState(a, b)
    for partId, cond in pairs(a) do
      local other = b[partId]
      if type(cond) == "table" then
        if type(other) ~= "table" then return false end
        local integrity, otherIntegrity = tonumber(cond.integrityValue), tonumber(other.integrityValue)
        if integrity ~= otherIntegrity and (not integrity or not otherIntegrity or math.abs(integrity - otherIntegrity) > 0.001) then return false end
        local visual, otherVisual = cond.visualState, other.visualState
        local replacement = type(visual) == "table" and type(visual.jbeam) == "table" and visual.jbeam.needsReplacement == true
        local otherReplacement = type(otherVisual) == "table" and type(otherVisual.jbeam) == "table" and otherVisual.jbeam.needsReplacement == true
        if replacement ~= otherReplacement then return false end
      end
    end
    for partId in pairs(b) do
      if a[partId] == nil then return false end
    end
    return true
  end

  local function clearAwaitingBaselineSample(vehicle)
    local capture = fleetState.fleetBaselineCaptures[vehicle]
    if capture then capture.awaiting = nil end
  end

  -- The vehicle replies through the callback bridge; the reply is read by fleet.lua's onFleetRepairBaseline.
  local function sampleFleetRepairBaseline(businessId, vehicle, vehObj)
    local args = string.format("%s, %s, %d, ", serialize(businessId), serialize(vehicle.vehicleId), vehObj:getID())
    local requestId = require('overhaul/lib/vehicles/callbacks').open('fleetRepairBaseline', {
      owner = 'businessInventory',
      vehId = vehObj:getID(),
      onFail = function() clearAwaitingBaselineSample(vehicle) end,
    })
    vehObj:queueLuaCommand("obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(" .. requestId .. ", 'fleetRepairBaseline', " .. string.format("%q", args) ..
      " .. serialize(partCondition.getConditions()) .. ', ' .. tostring(obj:getDissipatedEnergy() + beamstate.damageExt)))")
  end

  local function requestAndStorePartConditions(vehicle, vehObj, businessId)
    if not vehObj or not vehicle then
      return
    end
    core_vehicleBridge.requestValue(vehObj, function(res)
      if vehicle.fleetRepairBaselinePending or inputs.getSpawnedVehicleId(businessId, vehicle.vehicleId) ~= vehObj:getID() then return end
      if not res or not res.result then
        return
      end
      vehicle.partConditions = deepcopy(res.result)
    end, 'getPartConditions')
  end

  local function primeFleetRepairSnapshots(businessId)
    businessId = inputs.normalizeBusinessId(businessId)
    if not businessId then
      return 0
    end
    local vehicles = inputs.getBusinessVehicles(businessId) or {}
    local primed = 0
    for _, vehicle in ipairs(vehicles) do
      local vehicleId = tonumber(vehicle and vehicle.vehicleId) or (vehicle and vehicle.vehicleId)
      if vehicleId then
        local sid = inputs.getSpawnedVehicleId(businessId, vehicleId)
        local vehObj = sid and getObjectByID(sid)
        if vehObj then
          requestAndStorePartConditions(vehicle, vehObj, businessId)
          primed = primed + 1
        end
      end
    end
    return primed
  end

  local function getPartConditionApplyOpts(vehicle)
    local partsTree = vehicle and vehicle.config and vehicle.config.partsTree
    if not partsTree or not inputs.businessPartConditions then
      return nil
    end
    return {
      validPartKeys = inputs.businessPartConditions.collectPartConditionKeysFromPartsTree(partsTree),
    }
  end

  local function applyPartConditionsForVehicle(vehicle, vehObj, businessId)
    if not vehObj or not vehicle then
      return
    end

    if vehicle.partConditions then
      inputs.businessPartConditions.applyInitPartConditions(
        vehObj, vehicle.partConditions, 0, 1, 1, getPartConditionApplyOpts(vehicle))
      return
    end

    local mileage = tonumber(vehicle.mileage or 0)
    if mileage > 0 then
      local visualValue = getVisualValueFromMileage(mileage) or 1
      vehObj:queueLuaCommand(string.format("partCondition.initConditions(nil, %d, nil, %f)", mileage, visualValue))
      requestAndStorePartConditions(vehicle, vehObj, businessId)
      return
    end

    requestAndStorePartConditions(vehicle, vehObj, businessId)
  end

  local function buildReplacementData(vehicle, configKey)
    local vehicleData = {
      config = configKey,
      autoEnterVehicle = false,
      keepLoaded = true,
      keepOtherVehRotation = true,
    }
    if vehicle.config and vehicle.config.partsTree then
      vehicleData.config = deepcopy(vehicle.config)
      if vehicle.vars then
        vehicleData.config.vars = deepcopy(vehicle.vars)
      end
    elseif vehicle.vars then
      vehicleData.config = {
        key = configKey,
        vars = deepcopy(vehicle.vars),
      }
    end
    return vehicleData
  end

  local function repairSpawnedBusinessVehicle(businessId, vehicleId)
    businessId = inputs.normalizeBusinessId(businessId)
    vehicleId = tonumber(vehicleId) or vehicleId
    local vehicle = inputs.getVehicleById(businessId, vehicleId)
    if not vehicle or not vehicle.vehicleConfig then
      return false
    end
    local oldSid = inputs.getSpawnedVehicleId(businessId, vehicleId)
    local oldVehObj = oldSid and getObjectByID(oldSid)
    if not oldVehObj then
      return false
    end
    local modelKey = vehicle.vehicleConfig.model_key or vehicle.model_key
    local configKey = vehicle.vehicleConfig.key or vehicle.config_key
    if not modelKey or not configKey then
      return false
    end
    local newVehObj = core_vehicles.replaceVehicle(modelKey, buildReplacementData(vehicle, configKey), oldVehObj)
    if not newVehObj then
      return false
    end
    if not fleetState.spawnedBusinessVehicles[businessId] then
      fleetState.spawnedBusinessVehicles[businessId] = {}
    end
    fleetState.spawnedBusinessVehicles[businessId][vehicleId] = newVehObj:getID()
    newVehObj:queueLuaCommand("extensions.load('overhaulDamageState')")
    core_vehicleBridge.requestValue(newVehObj, function()
      core_vehicleBridge.executeAction(newVehObj, 'initPartConditions', {}, 0, 1, 1)
      if vehicle.fleetRepairBaselinePending then
        requestFleetRepairBaseline(businessId, vehicle, newVehObj)
      else
        requestAndStorePartConditions(vehicle, newVehObj, businessId)
      end
    end, 'ping')
    local playerVid = be:getPlayerVehicleID(0)
    if playerVid == oldSid then
      be:enterVehicle(0, newVehObj)
    end
    return true
  end

  return {
    applyPartConditionsForVehicle = applyPartConditionsForVehicle,
    getPartConditionApplyOpts = getPartConditionApplyOpts,
    primeFleetRepairSnapshots = primeFleetRepairSnapshots,
    repairSpawnedBusinessVehicle = repairSpawnedBusinessVehicle,
    requestFleetRepairBaseline = requestFleetRepairBaseline,
    sameFleetDamageState = sameFleetDamageState,
    sampleFleetRepairBaseline = sampleFleetRepairBaseline,
  }
end

return part
