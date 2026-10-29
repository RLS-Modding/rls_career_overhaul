-- Business computer garage: pull-out and put-away, repairs, painting, refueling, job lists and brand and race selection.
-- Reading order: pull-out refusals, pull-out and put-away, repairs and painting, job lists, brand and race selection.
local installer = {}

-- Each construction shares state and helpers with that owner load.
function installer.new(inputs)
  local api = {}
  local cache = inputs.cache
  local M = inputs.M

  -- Pull-out refusals --------------------------------------------------------------------------------

  -- Lift slots for this business; the business module can change the count, never below one.
  local function maxPulledOutVehiclesFor(module, businessId)
    local maxPulledOut = 1
    if module and module.getMaxPulledOutVehicles then
      maxPulledOut = tonumber(module.getMaxPulledOutVehicles(businessId)) or 1
    end
    if maxPulledOut < 1 then
      maxPulledOut = 1
    end
    return maxPulledOut
  end

  local function pullOutDamageRefusal(businessId)
    if inputs.parts.vehicles.isRacingTeamBusinessId(businessId) then
      return nil
    end
    local lockInfo = inputs.parts.vehicles.getDamageLockedVehicleInfo(businessId)
    if not lockInfo then
      return nil
    end
    log('D', 'businessComputer.pullOut', 'return damageLocked businessId=' .. tostring(businessId))
    inputs.parts.vehicles.notifyDamageLocked(lockInfo)
    return {
      success = false,
      errorCode = "damageLocked"
    }
  end

  local function isVehiclePulledOut(pulledOutVehiclesList, normalizedVehicleId)
    for _, current in ipairs(pulledOutVehiclesList) do
      if inputs.parts.vehicles.normalizeVehicleIdValue(current.vehicleId) == normalizedVehicleId then
        return true
      end
    end
    return false
  end

  -- A stored vehicle whose job the business's tech is still working on cannot come out.
  local function jobLockRefusal(businessId, module, normalizedVehicleId)
    if not (module and module.isJobLockedByTech) then
      return nil
    end
    local vehicles = overhaul_career_business_fleet.getBusinessVehicles(businessId) or {}
    for _, stored in ipairs(vehicles) do
      if inputs.parts.vehicles.normalizeVehicleIdValue(stored.vehicleId) == normalizedVehicleId then
        local jobId = tonumber(stored.jobId) or stored.jobId
        if jobId and module.isJobLockedByTech(businessId, jobId) then
          log('D', 'businessComputer.pullOut',
            string.format('return jobLocked businessId=%s vehicleId=%s jobId=%s', tostring(businessId),
              tostring(normalizedVehicleId), tostring(jobId)))
          return {
            success = false,
            errorCode = "jobLocked"
          }
        end
        break
      end
    end
    return nil
  end

  -- A vehicle whose kit is still being installed cannot come out.
  local function kitLockRefusal(businessId, businessType, normalizedVehicleId)
    local businessObj = businessType and overhaul_career_business_manager.getBusinessObject(businessType)
    if not (businessObj and businessObj.isVehicleKitLocked) then
      return nil
    end
    if not businessObj.isVehicleKitLocked(businessId, normalizedVehicleId) then
      return nil
    end
    local remaining = businessObj.getKitInstallTimeRemaining and businessObj.getKitInstallTimeRemaining(businessId, normalizedVehicleId) or 0
    log('D', 'businessComputer.pullOut',
      string.format('return kitInstallLocked businessId=%s vehicleId=%s remaining=%s', tostring(businessId),
        tostring(normalizedVehicleId), tostring(remaining)))
    return {
      success = false,
      errorCode = "kitInstallLocked",
      timeRemaining = remaining
    }
  end

  local function maxVehiclesRefusal(businessId, pulledOutCount, maxPulledOut)
    if pulledOutCount < maxPulledOut then
      return nil
    end
    local message = string.format("All %d lift slots are in use. Put away a vehicle first.", maxPulledOut)
    log('D', 'businessComputer.pullOut',
      string.format('return maxVehicles businessId=%s pulledOut=%d max=%d', tostring(businessId),
        pulledOutCount, maxPulledOut))
    return {
      success = false,
      errorCode = "maxVehicles",
      message = message
    }
  end

  -- Pull-out and put-away ----------------------------------------------------------------------------

  -- Sends the garage snapshot for one vehicle event. A put-away with no vehicle leaves the id out.
  local function triggerVehicleGarageEvent(eventName, businessId, businessType, vehicleId)
    local vehiclesData = M.getVehiclesOnly(businessId)
    guihooks.trigger(eventName, {
      businessType = businessType,
      businessId = businessId,
      vehicleId = vehicleId,
      vehicles = vehiclesData.vehicles,
      pulledOutVehicles = vehiclesData.pulledOutVehicles,
      maxPulledOutVehicles = vehiclesData.maxPulledOutVehicles
    })
  end

  function api.pullOutVehicle(businessId, vehicleId)
    if not businessId or not vehicleId then
      log('D', 'businessComputer.pullOut', 'abort: missing businessId or vehicleId')
      return false
    end

    local businessType = cache.businessContexts[businessId]
    if not businessType then
      log('E', 'businessComputer',
        'Cannot pull out vehicle, unknown business type for businessId=' .. tostring(businessId))
      return {
        success = false,
        errorCode = "unknownBusiness"
      }
    end

    log('D', 'businessComputer.pullOut',
      string.format('start businessId=%s vehicleId=%s businessType=%s', tostring(businessId), tostring(vehicleId),
        tostring(businessType)))

    local module = inputs.getBusinessModule(businessType)
    local maxPulledOut = maxPulledOutVehiclesFor(module, businessId)
    local refusal = pullOutDamageRefusal(businessId)
    if refusal then
      return refusal
    end

    local normalizedVehicleId = inputs.parts.vehicles.normalizeVehicleIdValue(vehicleId)
    local pulledOutVehiclesList = inputs.parts.vehicles.getPulledOutVehiclesList(businessId)
    if isVehiclePulledOut(pulledOutVehiclesList, normalizedVehicleId) then
      -- The fleet verifies the world object and repairs a stale lift reservation.
      local result = overhaul_career_business_fleet.pullOutVehicle(businessType, businessId, vehicleId)
      if result then
        overhaul_career_business_fleet.setActiveVehicle(businessId, normalizedVehicleId)
        triggerVehicleGarageEvent('businessComputer:onVehiclePulledOut', businessId, businessType, normalizedVehicleId)
      end
      return result
    end

    refusal = jobLockRefusal(businessId, module, normalizedVehicleId)
      or kitLockRefusal(businessId, businessType, normalizedVehicleId)
      or maxVehiclesRefusal(businessId, #pulledOutVehiclesList, maxPulledOut)
    if refusal then
      return refusal
    end

    local result = overhaul_career_business_fleet.pullOutVehicle(businessType, businessId, vehicleId)
    log('D', 'businessComputer.pullOut',
      string.format('inventory.pullOutVehicle result=%s businessId=%s vehicleId=%s', tostring(result),
        tostring(businessId), tostring(vehicleId)))
    if result then
      overhaul_career_business_fleet.setActiveVehicle(businessId, normalizedVehicleId)
    end
    if result then
      triggerVehicleGarageEvent('businessComputer:onVehiclePulledOut', businessId, businessType, normalizedVehicleId)
    end
    return result
  end

  function api.putAwayVehicle(businessId, vehicleId)
    if not businessId then
      return false
    end

    local businessType = cache.businessContexts[businessId]
    local targetVehicleId = vehicleId
    if not targetVehicleId then
      local activeVehicle = inputs.parts.vehicles.getActiveBusinessVehicle(businessId)
      targetVehicleId = activeVehicle and activeVehicle.vehicleId
    end

    local normalizedVehicleId = nil
    if targetVehicleId then
      normalizedVehicleId = inputs.parts.vehicles.normalizeVehicleIdValue(targetVehicleId)
    end
    if not inputs.parts.vehicles.isRacingTeamBusinessId(businessId) then
      local lockInfo = inputs.parts.vehicles.getDamageLockedVehicleInfo(businessId, normalizedVehicleId)
      if lockInfo then
        inputs.parts.vehicles.notifyDamageLocked(lockInfo)
        return {
          success = false,
          errorCode = "damageLocked"
        }
      end
    end

    return overhaul_career_business_fleet.putAwayVehicle(businessId, normalizedVehicleId, function(ok)
      if ok ~= false then
        triggerVehicleGarageEvent('businessComputer:onVehiclePutAway', businessId, businessType, normalizedVehicleId)
      end
    end)
  end

  -- Repairs and painting -----------------------------------------------------------------------------

  function api.computeBusinessVehicleRepairCost(businessId, vehicleId)
    local threshold = inputs.parts.vehicles.getDamageThreshold(businessId)
    local vehObj = inputs.parts.vehicles.getBusinessVehicleObject(businessId, vehicleId)
    if not vehObj then
      return nil
    end
    local vehicleObjectId = vehObj:getID()
    local damage = inputs.parts.vehicles.getVehicleDamageByVehId(vehicleObjectId)
    local fleet = overhaul_career_business_fleet
    if inputs.parts.vehicles.isRacingTeamBusinessId(businessId) and fleet then
      damage = fleet.getFleetRepairDamage(businessId, vehicleId, damage)
    end
    if damage < 1 then
      return 0, damage, threshold
    end
    local ratio = math.min(1, damage / math.max(1, threshold))
    return math.floor(150 + ratio * 5500), damage, threshold
  end

  function api.repairBusinessVehicleDamage(businessId, vehicleId)
    if not businessId or not vehicleId then
      return { success = false, errorCode = "badArgs" }
    end
    local businessType = inputs.resolveBusinessTypeOnly(businessId)
    if not businessType then
      return { success = false, errorCode = "unknownBusiness" }
    end
    local fleet = overhaul_career_business_fleet
    if not fleet then
      return { success = false, errorCode = "noInventory" }
    end
    if inputs.parts.vehicles.isRacingTeamBusinessId(businessId) then
      return fleet.repairFleetVehicleInsuranceStyle(businessId, vehicleId, businessType)
    end
    local spawnedId = fleet.getSpawnedVehicleId(businessId, vehicleId)
    if not spawnedId then
      return { success = false, errorCode = "notPulledOut" }
    end
    local cost, damage, threshold = api.computeBusinessVehicleRepairCost(businessId, vehicleId)
    if cost == nil then
      return { success = false, errorCode = "noVehicle" }
    end
    if cost <= 0 then
      return { success = true, cost = 0, damage = damage or 0, threshold = threshold }
    end
    local account = overhaul_career_economy_bank.getBusinessAccount(businessType, businessId)
    if not account then
      return { success = false, errorCode = "noAccount" }
    end
    local paid = overhaul_career_economy_bank.payFromAccount({
      money = { amount = cost, canBeNegative = false },
    }, account.id, "Vehicle Repair", "Garage vehicle repair", {category = "repair"})
    if not paid then
      return { success = false, errorCode = "noFunds", cost = cost }
    end
    local ok = fleet.repairSpawnedBusinessVehicle(businessId, vehicleId)
    if not ok then
      overhaul_career_economy_bank.rewardToAccount({ money = { amount = cost } }, account.id, "Refund", "Repair failed", {category = "refund"})
      return { success = false, errorCode = "repairFailed", cost = cost }
    end
    ui_message(string.format("Vehicle repaired for $%d.", cost), 5, "Business Computer", "info")
    overhaul_career_saveSystem.saveCurrent()
    return { success = true, cost = cost, damage = damage, threshold = threshold }
  end

  function api.startVehiclePainting(businessId, vehicleId)
    if not businessId or not vehicleId then
      return { success = false, errorCode = "badArgs" }
    end
    local businessType = inputs.resolveBusinessTypeOnly(businessId)
    if not businessType then
      return { success = false, errorCode = "unknownBusiness" }
    end
    if not inputs.parts.vehicles.isRacingTeamBusinessId(businessId) then
      return { success = false, errorCode = "unsupportedBusiness" }
    end
    local fleet = overhaul_career_business_fleet
    if not fleet or not fleet.getSpawnedVehicleId then
      return { success = false, errorCode = "noInventory" }
    end
    local spawnedId = fleet.getSpawnedVehicleId(businessId, vehicleId)
    if not spawnedId or not getObjectByID(spawnedId) then
      return { success = false, errorCode = "notPulledOut" }
    end
    local ok, reason = overhaul_career_parts_painting.startForBusinessVehicle(businessId, vehicleId, nil)
    if not ok then
      return { success = false, errorCode = reason or "paintingFailed" }
    end
    return { success = true }
  end

  function api.startVehicleRefueling(businessId, vehicleId)
    if not businessId or not vehicleId then
      return { success = false, errorCode = "badArgs" }
    end
    local businessType = inputs.resolveBusinessTypeOnly(businessId)
    if not businessType then
      return { success = false, errorCode = "unknownBusiness" }
    end
    if not inputs.parts.vehicles.isRacingTeamBusinessId(businessId) then
      return { success = false, errorCode = "unsupportedBusiness" }
    end

    local skillTree = overhaul_career_business_skillTree
    if skillTree and skillTree.getNodeProgress then
      local ok, level = pcall(skillTree.getNodeProgress, businessId, "team-operations", "pit-fuel")
      if not ok or (tonumber(level) or 0) < 1 then
        return { success = false, errorCode = "pitFuelLocked" }
      end
    end

    local fleet = overhaul_career_business_fleet
    if not fleet or not fleet.getSpawnedVehicleId then
      return { success = false, errorCode = "noInventory" }
    end
    local spawnedId = fleet.getSpawnedVehicleId(businessId, vehicleId)
    if not spawnedId or not getObjectByID(spawnedId) then
      return { success = false, errorCode = "notPulledOut" }
    end
    local ok, reason = overhaul_career_maintenance_fuel.startForBusinessVehicle(businessId, vehicleId)
    if not ok then
      return { success = false, errorCode = reason or "fuelingFailed" }
    end
    return { success = true }
  end

  -- Job lists ----------------------------------------------------------------------------------------

  function api.getActiveJobs(businessId)
    local module = inputs.resolveBusinessModule(businessId)
    if module and module.getActiveJobs then
      return module.getActiveJobs(businessId)
    end
    return {}
  end

  function api.getNewJobs(businessId)
    local module = inputs.resolveBusinessModule(businessId)
    if module and module.getNewJobs then
      return module.getNewJobs(businessId)
    end
    return {}
  end

  -- Brand and race selection -------------------------------------------------------------------------

  function api.getBrandSelection(businessId)
    local module = inputs.resolveBusinessModule(businessId)
    if module and module.getBrandSelection then
      return module.getBrandSelection(businessId)
    end
    return nil
  end

  function api.setBrandSelection(businessId, brand)
    local module = inputs.resolveBusinessModule(businessId)
    if module and module.setBrandSelection then
      return module.setBrandSelection(businessId, brand)
    end
    return false
  end

  function api.getRaceSelection(businessId)
    local module = inputs.resolveBusinessModule(businessId)
    if module and module.getRaceSelection then
      return module.getRaceSelection(businessId)
    end
    return nil
  end

  function api.setRaceSelection(businessId, raceType)
    local module = inputs.resolveBusinessModule(businessId)
    if module and module.setRaceSelection then
      return module.setRaceSelection(businessId, raceType)
    end
    return false
  end

  function api.getAvailableBrands()
    local tuningShop = overhaul_career_business_tuningShop_tuningShop
    if tuningShop and tuningShop.getAvailableBrands then
      return tuningShop.getAvailableBrands()
    end
    return {}
  end

  function api.getAvailableRaceTypes()
    local tuningShop = overhaul_career_business_tuningShop_tuningShop
    if tuningShop and tuningShop.getAvailableRaceTypes then
      return tuningShop.getAvailableRaceTypes()
    end
    return {}
  end

  function api.requestAvailableBrands()
    local tuningShop = overhaul_career_business_tuningShop_tuningShop
    if tuningShop and tuningShop.requestAvailableBrands then
      tuningShop.requestAvailableBrands()
    end
  end

  function api.requestAvailableRaceTypes(businessId)
    if not businessId then
      return
    end
    local tuningShop = overhaul_career_business_tuningShop_tuningShop
    if tuningShop and tuningShop.requestAvailableRaceTypes then
      tuningShop.requestAvailableRaceTypes(businessId)
    end
  end

  return api
end

return installer
