-- Business computer vehicle records, caches, damage locks and UI payloads.
-- Read personal vehicles, caches, lookups, damage locks, vehicle info and formatting, then UI data.
local installer = {}

-- Each construction shares state and sibling tables with that owner load.
function installer.new(inputs)
  local api = {}
  local cache = inputs.cache

  -- Personal vehicles --------------------------------------------------------------------------------

  function api.isPersonalVehicleId(vehicleId)
    if not vehicleId then
      return false
    end
    local idText = tostring(vehicleId)
    return idText:sub(1, 9) == "personal_"
  end

  local function getActivePersonalVehicleRecord(vehicleId, businessId)
    if not api.isPersonalVehicleId(vehicleId) or not businessId then
      return nil
    end
    local _, businessType = inputs.resolveBusinessModule(businessId)
    if not businessType then
      return nil
    end
    local businessObj = overhaul_career_business_manager.getBusinessObject(businessType)
    if not businessObj or not businessObj.getActivePersonalVehicle then
      return nil
    end
    local activePersonal = businessObj.getActivePersonalVehicle(businessId)
    if activePersonal and tostring(activePersonal.vehicleId) == tostring(vehicleId) then
      return activePersonal
    end
    return nil
  end

  function api.getPersonalVehicleData(vehicleId, businessId)
    return getActivePersonalVehicleRecord(vehicleId, businessId)
  end

  function api.getInventoryIdFromPersonalVehicleId(vehicleId, businessId)
    local record = getActivePersonalVehicleRecord(vehicleId, businessId)
    return record and record.inventoryId or nil
  end

  function api.getSpawnedIdFromPersonalVehicleId(vehicleId)
    if not vehicleId then
      return nil
    end
    local idText = tostring(vehicleId)
    if idText:sub(1, 9) ~= "personal_" then
      return nil
    end
    return tonumber(idText:sub(10))
  end

  -- Vehicle caches ----------------------------------------------------------------------------------

  function api.clearVehicleDataCaches()
    cache.partsTreeCache = {}
    overhaul_career_business_vehicleTuning.clearTuningDataCache()
  end

  function api.partsTreeCacheKeyForBusinessVehicle(businessId, vehicleIdStr, initialVehicle, isPersonal)
    if isPersonal then
      local invId = api.getInventoryIdFromPersonalVehicleId(vehicleIdStr, businessId)
      if invId then
        return "personal_" .. tostring(invId)
      end
      local idText = tostring(vehicleIdStr)
      if idText:sub(1, 9) == "personal_" then
        return idText
      end
      return "personal_unknown"
    end
    if initialVehicle and initialVehicle.vehicleId ~= nil then
      return tostring(tonumber(initialVehicle.vehicleId) or initialVehicle.vehicleId)
    end
    return tostring(tonumber(vehicleIdStr) or vehicleIdStr)
  end

  function api.clearCachesForVehicle(businessId, vehicleId)
    if not businessId or vehicleId == nil then
      return
    end
    local key
    if api.isPersonalVehicleId(vehicleId) then
      local invId = api.getInventoryIdFromPersonalVehicleId(vehicleId, businessId)
      key = invId and ("personal_" .. tostring(invId)) or tostring(vehicleId)
    else
      key = tostring(tonumber(vehicleId) or vehicleId)
    end
    inputs.clearPartsTreeCacheForKey(businessId, key)
    overhaul_career_business_vehicleTuning.clearTuningDataCacheForVehicle(businessId, key)
  end

  -- Vehicle objects and business lookups -----------------------------------------------------------

  function api.getDamageThreshold(businessId)
    local _, businessType = inputs.resolveBusinessModule(businessId)
    if businessType then
      local businessObj = overhaul_career_business_manager.getBusinessObject(businessType)
      if businessObj and businessObj.getDamageThreshold then
        return businessObj.getDamageThreshold(businessId)
      end
    end
    return 1500
  end

  function api.isRacingTeamBusinessId(businessId)
    return inputs.resolveBusinessTypeOnly(businessId) == "racingTeam"
  end

  function api.getBusinessVehicleObject(businessId, vehicleId)
    if not businessId or not vehicleId then
      return nil
    end

    if api.isPersonalVehicleId(vehicleId) then
      local spawnedId = api.getSpawnedIdFromPersonalVehicleId(vehicleId)
      if spawnedId then
        return getObjectByID(spawnedId)
      end
      return nil
    end

    local vehId = overhaul_career_business_fleet.getSpawnedVehicleId(businessId, vehicleId)
    if vehId then
      return getObjectByID(vehId)
    end

    return nil
  end

  function api.getVehicleDamageByVehId(vehId)
    if not vehId then
      return 0
    end

    local objectData = map.objects[vehId]
    if not objectData then
      return 0
    end

    return objectData.damage or 0
  end

  function api.normalizeVehicleIdValue(vehicleId)
    if vehicleId == nil then
      return nil
    end
    local num = tonumber(vehicleId)
    if num then
      return num
    end
    return vehicleId
  end

  function api.getPulledOutVehiclesList(businessId)
    return overhaul_career_business_fleet.getPulledOutVehicles(businessId) or {}
  end

  function api.getActiveBusinessVehicle(businessId)
    if not businessId then
      return nil
    end

    local active = overhaul_career_business_fleet.getActiveVehicle(businessId)
    if active then
      log("D", "businessComputer.getActiveBusinessVehicle", "Using active business vehicle for businessId=" .. tostring(businessId))
      return active
    end
    local pulled = overhaul_career_business_fleet.getPulledOutVehicle(businessId)
    if pulled then
      log("D", "businessComputer.getActiveBusinessVehicle", "Using pulled-out business vehicle for businessId=" .. tostring(businessId))
      return pulled
    end

    local _, businessType = inputs.resolveBusinessModule(businessId)
    if businessType then
      local businessObj = overhaul_career_business_manager.getBusinessObject(businessType)
      if businessObj and businessObj.getActivePersonalVehicle then
        local personalVehicle = businessObj.getActivePersonalVehicle(businessId)
        if personalVehicle then
          log("D", "businessComputer.getActiveBusinessVehicle", "Using personal vehicle for businessId=" .. tostring(businessId))
          return personalVehicle
        end
      end
    end

    log("D", "businessComputer.getActiveBusinessVehicle", "No active vehicle found for businessId=" .. tostring(businessId))
    return nil
  end

  -- Damage locks ------------------------------------------------------------------------------------

  function api.isDamageLocked(businessId, vehicleId)
    local threshold = api.getDamageThreshold(businessId)
    local lockInfo = {
      locked = false,
      damage = 0,
      threshold = threshold
    }

    if not businessId or not vehicleId then
      return lockInfo
    end

    local vehicleObject = api.getBusinessVehicleObject(businessId, vehicleId)
    if not vehicleObject then
      return lockInfo
    end

    local vehId = vehicleObject:getID()
    if not vehId then
      return lockInfo
    end

    local damage = api.getVehicleDamageByVehId(vehId)
    local fleet = overhaul_career_business_fleet
    if api.isRacingTeamBusinessId(businessId) and fleet then
      damage = fleet.getFleetRepairDamage(businessId, vehicleId, damage)
    end
    lockInfo.damage = damage
    lockInfo.locked = damage >= threshold

    return lockInfo
  end

  function api.getDamageLockedVehicleInfo(businessId, vehicleId)
    if not businessId then
      return nil
    end

    if vehicleId then
      local lockInfo = api.isDamageLocked(businessId, vehicleId)
      if lockInfo.locked then
        lockInfo.vehicleId = vehicleId
        return lockInfo
      end
      return nil
    end

    for _, vehicle in ipairs(api.getPulledOutVehiclesList(businessId)) do
      local pulledVehicleId = api.normalizeVehicleIdValue(vehicle.vehicleId)
      local lockInfo = api.isDamageLocked(businessId, pulledVehicleId)
      if lockInfo.locked then
        lockInfo.vehicleId = pulledVehicleId
        return lockInfo
      end
    end

    return nil
  end

  function api.notifyDamageLocked(lockInfo)
    if not lockInfo or not lockInfo.locked then
      return
    end

    local message = string.format("Vehicle damage (%.0f) exceeds the %d limit. Abandon the job to continue.",
      lockInfo.damage or 0, lockInfo.threshold or 1500)
    ui_message(message, 5, "Business Computer", "error")
  end

  function api.shouldPreventVehicleOperation(businessId, vehicleId)
    if not businessId or not vehicleId then
      return false
    end
    if api.isRacingTeamBusinessId(businessId) then
      return false
    end

    local lockInfo = api.isDamageLocked(businessId, vehicleId)
    if lockInfo.locked then
      api.notifyDamageLocked(lockInfo)
      return true
    end

    return false
  end

  -- Vehicle info ------------------------------------------------------------------------------------

  -- Drops the directory and the extension: "vehicles/car.dd" becomes "car".
  local function normalizeConfigKey(configKey)
    if not configKey then
      return nil
    end
    if configKey:find("/") then
      local pathParts = {}
      for part in configKey:gmatch("[^/]+") do
        table.insert(pathParts, part)
      end
      if #pathParts > 0 then
        local filename = pathParts[#pathParts]
        local name = filename:match("^(.+)%.(.+)$")
        return name or filename
      end
    else
      local name = configKey:match("^(.+)%.(.+)$")
      return name or configKey
    end
    return configKey
  end

  local function getVehicleInfo(modelKey, configKey)
    if not modelKey or not configKey then
      return nil
    end

    local normalizedConfigKey = normalizeConfigKey(configKey)

    if util_configListGenerator and util_configListGenerator.getEligibleVehicles then
      if not cache.vehicleInfoCache then
        cache.vehicleInfoCache = util_configListGenerator.getEligibleVehicles(false, false) or {}
      end

      for _, vehicleInfo in ipairs(cache.vehicleInfoCache) do
        if vehicleInfo.model_key == modelKey then
          local vehicleKey = normalizeConfigKey(vehicleInfo.key)
          if vehicleInfo.key == configKey or vehicleKey == normalizedConfigKey or vehicleInfo.key == normalizedConfigKey then
            return vehicleInfo
          end
        end
      end
    end

    local model = core_vehicles.getModel(modelKey)
    if model and not tableIsEmpty(model) then
      local configInfo = core_vehicles.getConfig(modelKey, normalizedConfigKey)
      if configInfo then
        return {
          model_key = modelKey,
          key = configKey,
          Name = configInfo.Name or modelKey,
          Brand = configInfo.Brand or "",
          Years = configInfo.Years or {
            min = 1990,
            max = 2025
          },
          preview = configInfo.preview
        }
      end
    end

    return nil
  end

  -- Vehicle formatting ------------------------------------------------------------------------------

  -- Kit install lock state of a vehicle at a business: locked flag, time left and the kit's name.
  local function kitInstallStatus(businessId, vehicle)
    local kitInstallLocked = false
    local kitInstallTimeRemaining = 0
    local kitInstallKitName = nil
    local _, businessType = inputs.resolveBusinessModule(businessId)
    local businessObj = businessType and overhaul_career_business_manager.getBusinessObject(businessType)
    if businessObj then
      if businessObj.isVehicleKitLocked then
        kitInstallLocked = businessObj.isVehicleKitLocked(businessId, vehicle.vehicleId) or false
      end
      if businessObj.getKitInstallTimeRemaining then
        kitInstallTimeRemaining = businessObj.getKitInstallTimeRemaining(businessId, vehicle.vehicleId) or 0
      end
      if businessObj.getKitInstallLock then
        local lockInfo = businessObj.getKitInstallLock(businessId, vehicle.vehicleId)
        if lockInfo then
          kitInstallKitName = lockInfo.kitName
        end
      end
    end
    return kitInstallLocked, kitInstallTimeRemaining, kitInstallKitName
  end

  -- Racing team vehicles show the insurance repair quote: whether it needs repair and the deductible.
  local function fleetRepairStatus(businessId, vehicle)
    local fleetRepairNeeded = false
    local fleetRepairDeductible = 750
    if businessId and api.isRacingTeamBusinessId(businessId) then
      local quote = overhaul_career_business_fleet.getFleetInsuranceRepairQuote(businessId, vehicle.vehicleId)
      if quote then
        fleetRepairNeeded = quote.needsRepair == true
        fleetRepairDeductible = math.max(0, math.floor(tonumber(quote.deductible) or 750))
      end
    end
    return fleetRepairNeeded, fleetRepairDeductible
  end

  function api.formatVehicleForUI(vehicle, businessId)
    if not vehicle then
      return nil
    end

    local vehicleConfig = vehicle.vehicleConfig or {}
    local modelKey = vehicleConfig.model_key or vehicle.model_key or "unknown"
    local configKey = vehicleConfig.key or vehicle.config_key or "unknown"

    local name, vehicleYear, vehicleType, vehicleImage =
      require('overhaul/lib/business/helpers').extractDisplayInfo(getVehicleInfo(modelKey, configKey))
    local vehicleName = name or modelKey

    local kitInstallLocked, kitInstallTimeRemaining, kitInstallKitName = false, 0, nil
    if businessId then
      kitInstallLocked, kitInstallTimeRemaining, kitInstallKitName = kitInstallStatus(businessId, vehicle)
    end

    local fleetRepairNeeded, fleetRepairDeductible = fleetRepairStatus(businessId, vehicle)

    return {
      id = tostring(vehicle.vehicleId),
      vehicleId = vehicle.vehicleId,
      jobId = vehicle.jobId,
      storedVehicleId = vehicle.storedVehicleId,
      vehicleName = vehicleName,
      vehicleYear = vehicleYear,
      vehicleType = vehicleType,
      vehicleImage = vehicleImage,
      storedTime = vehicle.storedTime,
      kitInstallLocked = kitInstallLocked,
      kitInstallTimeRemaining = kitInstallTimeRemaining,
      kitInstallKitName = kitInstallKitName,
      fleetRepairNeeded = fleetRepairNeeded,
      fleetRepairDeductible = fleetRepairDeductible
    }
  end

  -- Computer UI data --------------------------------------------------------------------------------

  local function primeRacingFleetSnapshots(businessType, businessId)
    if businessType == "racingTeam" then
      pcall(overhaul_career_business_fleet.primeFleetRepairSnapshots, businessId)
    end
  end

  -- Copies the business type's descriptor fields onto the UI data.
  local function applyBusinessTypeDescriptor(result, businessType)
    local descriptor = inputs.getBusinessTypeData(businessType)
    if type(descriptor) == "table" then
      result.module = descriptor.module
      result.sections = descriptor.sections
      result.capabilities = descriptor.capabilities
      result.features = descriptor.features
      result.skillNodes = descriptor.skillNodes
    end
  end

  local function maintenanceEnabledForUI()
    if overhaul_career_career.experimentalMaintenanceEnabled ~= nil then
      return overhaul_career_career.experimentalMaintenanceEnabled == true
    end
    if overhaul_career_maintenance_maintenanceMode.isEnabled then
      return overhaul_career_maintenance_maintenanceMode.isEnabled() == true
    end
    return false
  end

  function api.getBusinessComputerUIData(businessType, businessId)
    if not businessType or not businessId then
      return nil
    end

    inputs.setBusinessContext(businessType, businessId)
    primeRacingFleetSnapshots(businessType, businessId)

    local module = inputs.getBusinessModule(businessType)
    if not module or not module.getUIData then
      log('E', 'businessComputer', 'Business module missing getUIData for type ' .. tostring(businessType))
      return nil
    end

    local ok, result = pcall(module.getUIData, businessId)
    if not ok then
      log('E', 'businessComputer', 'Error getting UI data for type ' .. tostring(businessType) .. ': ' .. tostring(result))
      return nil
    end

    if type(result) == "table" then
      applyBusinessTypeDescriptor(result, businessType)
      result.experimentalMaintenanceEnabled = maintenanceEnabledForUI()
    end

    return result
  end

  return api
end

return installer
