-- Business computer views: job completion, the active and pulled-out vehicles, shopping vehicles, and the UI payloads for jobs, techs and stats.
-- Reading order: job completion, active vehicle selection, shopping vehicles, job status, UI payloads.
local installer = {}

-- Each construction shares state and helpers with that owner load.
function installer.new(inputs)
  local api = {}
  local M = inputs.M

  -- Job completion -----------------------------------------------------------------------------------

  function api.completeJob(businessId, jobId)
    local module, businessType = inputs.resolveBusinessModule(businessId)
    if module and module.completeJob then
      local finished = false
      local function onComplete(success)
        if finished then return end
        finished = true
        local jobsData = M.getJobsOnly(businessId)
        if not success then
          jobsData.businessType = businessType
          guihooks.trigger('businessComputer:onJobsUpdated', jobsData)
          return
        end
        local vehiclesData = M.getVehiclesOnly(businessId)
        guihooks.trigger('businessComputer:onJobCompleted', {
          businessType = businessType,
          businessId = businessId,
          jobId = jobId,
          activeJobs = jobsData.activeJobs,
          vehicles = vehiclesData.vehicles,
          pulledOutVehicles = vehiclesData.pulledOutVehicles
        })
      end
      local success = module.completeJob(businessId, jobId, onComplete)
      -- Synchronous business modules can still report their outcome by return value.
      if success ~= nil then onComplete(success) end
      return success
    end
    return false
  end

  -- Active vehicle selection -------------------------------------------------------------------------

  -- Tells the UI which pulled-out personal vehicle is now active.
  local function notifyPersonalVehiclePulledOut(businessId, businessType, normalizedVehicleId)
    local vehiclesData = M.getVehiclesOnly(businessId)
    local matchingVehicleId = nil
    for _, veh in ipairs(vehiclesData.pulledOutVehicles) do
      if veh.isPersonal and inputs.parts.vehicles.normalizeVehicleIdValue(veh.vehicleId) == normalizedVehicleId then
        matchingVehicleId = veh.vehicleId
        break
      end
    end
    if not matchingVehicleId then return end
    guihooks.trigger('businessComputer:onVehiclePulledOut', {
      businessType = businessType,
      businessId = businessId,
      vehicleId = matchingVehicleId,
      vehicles = vehiclesData.vehicles,
      pulledOutVehicles = vehiclesData.pulledOutVehicles,
      maxPulledOutVehicles = vehiclesData.maxPulledOutVehicles,
      isPersonalVehicle = true
    })
  end

  -- Selects the garage-zone inventory row that holds this spawned personal vehicle.
  local function selectPersonalVehicleInZone(businessId, vehicleId, normalizedVehicleId)
    local _, businessType = inputs.resolveBusinessModule(businessId)
    if not businessType then return false end
    local businessObj = overhaul_career_business_manager.getBusinessObject(businessType)
    if not (businessObj and businessObj.selectPersonalVehicle) then return false end
    local spawnedId = inputs.parts.vehicles.getSpawnedIdFromPersonalVehicleId(vehicleId)
    if not (spawnedId and businessObj.getInventoryVehiclesInGarageZone) then return false end
    local inventoryVehiclesInZone = businessObj.getInventoryVehiclesInGarageZone(businessId) or {}
    for _, invVeh in ipairs(inventoryVehiclesInZone) do
      if invVeh.spawnedId == spawnedId then
        local result = businessObj.selectPersonalVehicle(businessId, invVeh.inventoryId)
        if result and result.success then
          notifyPersonalVehiclePulledOut(businessId, businessType, normalizedVehicleId)
        end
        return result and result.success or false
      end
    end
    return false
  end

  function api.setActiveVehicle(businessId, vehicleId)
    if not businessId or not vehicleId then
      return false
    end

    local lockInfo = inputs.parts.vehicles.getDamageLockedVehicleInfo(businessId, vehicleId)
    if lockInfo then
      inputs.parts.vehicles.notifyDamageLocked(lockInfo)
      return {
        success = false,
        errorCode = "damageLocked"
      }
    end

    if inputs.parts.vehicles.isPersonalVehicleId(vehicleId) then
      return selectPersonalVehicleInZone(businessId, vehicleId, inputs.parts.vehicles.normalizeVehicleIdValue(vehicleId))
    end

    local result = overhaul_career_business_fleet.setActiveVehicle(businessId, vehicleId)
    if result then
      local _, resolvedBusinessType = inputs.resolveBusinessModule(businessId)
      local vehiclesData = M.getVehiclesOnly(businessId)
      local normalizedVehicleId = inputs.parts.vehicles.normalizeVehicleIdValue(vehicleId)
      local matchingVehicleId = normalizedVehicleId
      for _, veh in ipairs(vehiclesData.pulledOutVehicles) do
        if inputs.parts.vehicles.normalizeVehicleIdValue(veh.vehicleId) == normalizedVehicleId then
          matchingVehicleId = veh.vehicleId
          break
        end
      end
      guihooks.trigger('businessComputer:onVehiclePulledOut', {
        businessType = resolvedBusinessType,
        businessId = businessId,
        vehicleId = matchingVehicleId,
        vehicles = vehiclesData.vehicles,
        pulledOutVehicles = vehiclesData.pulledOutVehicles,
        maxPulledOutVehicles = vehiclesData.maxPulledOutVehicles
      })
    end
    return result
  end

  function api.getActiveVehicle(businessId)
    return inputs.parts.vehicles.getActiveBusinessVehicle(businessId)
  end

  -- Shopping vehicles --------------------------------------------------------------------------------

  function api.enterShoppingVehicle(businessId, vehicleId)
    if not businessId or not vehicleId then
      log("W", "businessComputer", "enterShoppingVehicle: Missing businessId or vehicleId")
      return false
    end

    local spawnedVehId = nil

    if inputs.parts.vehicles.isPersonalVehicleId(vehicleId) then
      spawnedVehId = inputs.parts.vehicles.getSpawnedIdFromPersonalVehicleId(vehicleId)
    else
      spawnedVehId = overhaul_career_business_fleet.getSpawnedVehicleId(businessId, vehicleId)
    end

    if not spawnedVehId or spawnedVehId == 0 then
      return false
    end

    local vehObj = be:getObjectByID(spawnedVehId)
    if not vehObj then
      return false
    end

    if gameplay_walk.isWalking() then
      gameplay_walk.getInVehicle(vehObj)
    else
      be:enterVehicle(0, vehObj)
    end
    return true
  end

  -- Only the vehicle this business spawned or pulled out counts; anything else keeps the player in place.
  function api.exitShoppingVehicle(businessId)
    local playerVeh = be:getPlayerVehicle(0)
    if not playerVeh then
      return false
    end
    if businessId then
      local playerVehId = playerVeh:getID()
      local isValidVehicle = false

      local _, businessType = inputs.resolveBusinessModule(businessId)
      if businessType then
        local businessObj = overhaul_career_business_manager.getBusinessObject(businessType)
        if businessObj and businessObj.getActivePersonalVehicle then
          local activePersonal = businessObj.getActivePersonalVehicle(businessId)
          if activePersonal and activePersonal.spawnedVehicleId == playerVehId then
            isValidVehicle = true
          end
        end
      end

      if not isValidVehicle then
        local pulledOutList = inputs.parts.vehicles.getPulledOutVehiclesList(businessId)
        for _, vehicle in ipairs(pulledOutList) do
          local spawnedId = overhaul_career_business_fleet.getSpawnedVehicleId(businessId, vehicle.vehicleId)
          if spawnedId and spawnedId == playerVehId then
            isValidVehicle = true
            break
          end
        end
      end

      if not isValidVehicle then
        return false
      end
    end
    gameplay_walk.setWalkingMode(true, nil, nil, true)

    if businessId then
      local _, businessType = inputs.resolveBusinessModule(businessId)
      if businessType then
        local businessObj = overhaul_career_business_manager.getBusinessObject(businessType)
        if businessObj and businessObj.clearActivePersonalVehicle then
          businessObj.clearActivePersonalVehicle(businessId)
          log("D", "businessComputer.exitShoppingVehicle", "Cleared personal selection for businessId=" .. tostring(businessId))
        end
      end
    end
    return true
  end

  -- Job status --------------------------------------------------------------------------------------

  function api.getJobCompletionStatus(businessId, jobId)
    local module = inputs.resolveBusinessModule(businessId)
    if module and module.getJobCompletionStatus then
      return module.getJobCompletionStatus(businessId, jobId)
    end
    return {
      canComplete = false,
      goalTimeMet = false,
      buildChanged = false,
      blockedMessage = nil
    }
  end

  function api.canCompleteJob(businessId, jobId)
    local module = inputs.resolveBusinessModule(businessId)
    if module and module.canCompleteJob then
      return module.canCompleteJob(businessId, jobId)
    end
    return false
  end

  function api.getAbandonPenalty(businessId, jobId)
    local module = inputs.resolveBusinessModule(businessId)
    if module and module.getAbandonPenalty then
      return module.getAbandonPenalty(businessId, jobId)
    end
    return 0
  end

  -- UI payloads --------------------------------------------------------------------------------------

  function api.getJobsOnly(businessId)
    local module = inputs.resolveBusinessModule(businessId)
    if not module then
      return { activeJobs = {}, newJobs = {} }
    end
    local activeJobs = {}
    local newJobs = {}
    if module.getActiveJobs then
      activeJobs = module.getActiveJobs(businessId) or {}
    end
    if module.getNewJobs then
      newJobs = module.getNewJobs(businessId) or {}
    end
    local maxActiveJobs = 2
    if module.getMaxActiveJobs then
      maxActiveJobs = module.getMaxActiveJobs(businessId) or 2
    end
    return {
      businessId = businessId,
      activeJobs = activeJobs,
      newJobs = newJobs,
      maxActiveJobs = maxActiveJobs
    }
  end

  -- Vehicle rows for the garage: fleet rows, pulled-out rows with damage, then the zone's personal vehicles.
  function api.getVehiclesOnly(businessId)
    if not businessId then
      return { vehicles = {}, pulledOutVehicles = {} }
    end
    local vehicles = overhaul_career_business_fleet.getBusinessVehicles(businessId) or {}
    local pulledOutVehiclesRaw = inputs.parts.vehicles.getPulledOutVehiclesList(businessId)
    -- Business types with their own vehicle rows (racing team values) must not be replaced by generic rows.
    local rowModule = inputs.resolveBusinessModule(businessId)
    local format = rowModule and rowModule.formatVehicleForUI or inputs.parts.vehicles.formatVehicleForUI
    local formattedVehicles = {}
    for _, vehicle in ipairs(vehicles) do
      table.insert(formattedVehicles, format(vehicle, businessId))
    end
    local formattedPulledOut = {}
    for _, vehicle in ipairs(pulledOutVehiclesRaw) do
      local formatted = format(vehicle, businessId)
      if formatted then
        local vehicleDamageInfo = inputs.parts.vehicles.isDamageLocked(businessId, vehicle.vehicleId)
        formatted.damage = vehicleDamageInfo.damage
        formatted.damageLocked = vehicleDamageInfo.locked
        if inputs.parts.vehicles.isRacingTeamBusinessId(businessId) then
          formatted.damageLocked = false
        end
        formatted.damageThreshold = vehicleDamageInfo.threshold
        table.insert(formattedPulledOut, formatted)
      end
    end
    local module = inputs.resolveBusinessModule(businessId)
    local maxPulledOut = 1
    if module and module.getMaxPulledOutVehicles then
      maxPulledOut = module.getMaxPulledOutVehicles(businessId) or 1
    end
    if module and module.getFormattedPersonalVehiclesInZone then
      local personalVehicles = module.getFormattedPersonalVehiclesInZone(businessId) or {}
      for _, personalVehicle in ipairs(personalVehicles) do
        table.insert(formattedPulledOut, personalVehicle)
      end
    end
    return {
      businessId = businessId,
      vehicles = formattedVehicles,
      pulledOutVehicles = formattedPulledOut,
      maxPulledOutVehicles = maxPulledOut
    }
  end

  function api.getTechsOnly(businessId)
    local module, businessType = inputs.resolveBusinessModule(businessId)
    if not module then
      return { techs = {} }
    end
    local techs = {}
    local businessObj = businessType and overhaul_career_business_manager.getBusinessObject(businessType)
    if businessObj and businessObj.getTechsForBusiness then
      local rawTechs = businessObj.getTechsForBusiness(businessId) or {}
      if businessObj.formatTechForUIEntry then
        for _, tech in ipairs(rawTechs) do
          local formattedTech = businessObj.formatTechForUIEntry(businessId, tech)
          if formattedTech then
            table.insert(techs, formattedTech)
          end
        end
      else
        techs = rawTechs
      end
    elseif module.getTechsForBusiness then
      techs = module.getTechsForBusiness(businessId) or {}
    end
    return {
      businessId = businessId,
      techs = techs
    }
  end

  function api.getStatsOnly(businessId)
    local module, businessType = inputs.resolveBusinessModule(businessId)
    if not module then
      return { stats = {} }
    end
    local kits = {}
    local businessObj = businessType and overhaul_career_business_manager.getBusinessObject(businessType)
    if businessObj and businessObj.loadBusinessKits then
      kits = businessObj.loadBusinessKits(businessId) or {}
    end
    local vehicles = overhaul_career_business_fleet.getBusinessVehicles(businessId) or {}
    return {
      businessId = businessId,
      stats = {
        totalVehicles = #vehicles,
        kits = kits
      }
    }
  end

  function api.getManagerDataOnly(businessId)
    local module = inputs.resolveBusinessModule(businessId)
    if not module or not module.getManagerData then
      return nil
    end
    return module.getManagerData(businessId)
  end

  return api
end

return installer
