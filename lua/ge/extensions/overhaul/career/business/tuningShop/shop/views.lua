-- Tuning shop: job, vehicle and garage rows, finances, tabs and the computer UI projection.
-- Read row helpers, owner state, jobs and vehicles, garage rows, finances, tabs, UI projections and requests.

local BUSINESS_TYPE = "tuningShop"
local DEFAULT_BUSINESS_NAME = "Tuning Shop"
local PAYMENT_INTERVAL_SECONDS = 1800
local DAMAGE_LOCKED_TAB_IDS = {home = true, jobs = true, techs = true}

-- Number formatting -------------------------------------------------------------------------------

local function roundToPlaces(value, decimalPlaces)
  local multiplier = 10 ^ decimalPlaces
  return math.floor(value * multiplier + 0.5) / multiplier
end

-- Job row helpers ---------------------------------------------------------------------------------

local function formatGoalTime(seconds, decimalPlaces)
  if seconds >= 60 then
    local minutes = math.floor(seconds / 60)
    local remainderSeconds = math.floor(seconds % 60 + 0.5)
    if remainderSeconds >= 1 then
      return string.format("%d min %d s", minutes, remainderSeconds)
    end
    return string.format("%d min", minutes)
  end
  if decimalPlaces > 0 then
    return string.format("%." .. decimalPlaces .. "f s", seconds)
  end
  return string.format("%d s", math.floor(seconds + 0.5))
end

-- The time column uses the same authored leaderboard labels as completion proof.
local function currentJobTime(job, businessId, completion)
  local bestTime = businessId and job.raceLabel and completion.getLeaderboardBestTime(businessId, job)
  return bestTime or job.currentTime or job.baseTime or 0
end

-- Garage row helpers ------------------------------------------------------------------------------

local function getBusinessVehicleObject(businessId, vehicleId)
  if not businessId or not vehicleId then
    return nil
  end

  local vehId = overhaul_career_business_fleet.getSpawnedVehicleId(businessId, vehicleId)
  if vehId then
    return getObjectByID(vehId)
  end

  return nil
end

local function getVehicleDamageByVehId(vehId)
  if not vehId or not map.objects then
    return 0
  end

  local objectData = map.objects[vehId]
  if not objectData then
    return 0
  end

  return objectData.damage or 0
end

-- Finance helpers ---------------------------------------------------------------------------------

local function accountLoans(accountId)
  local businessLoans = {}
  if not accountId then
    return businessLoans
  end
  for _, loan in ipairs(overhaul_career_economy_loans.getActiveLoans() or {}) do
    if loan.businessAccountId == accountId then
      table.insert(businessLoans, loan)
    end
  end
  return businessLoans
end

local function requestSimulationTime()
  guihooks.trigger('businessComputer:onSimulationTime', {success = true, simulationTime = os.time()})
end

-- Tab helpers -------------------------------------------------------------------------------------

-- Tabs in the order the business computer lists them.
local function shopTabDefinitions()
  return {
    {id = "home", label = "Home", section = "BASIC", order = 1, component = "BusinessHomeView",
      icon = '<path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><polyline points="9 22 9 12 15 12 15 22"/>'},
    {id = "jobs", label = "Jobs", section = "BASIC", order = 2, component = "BusinessJobsTab",
      icon = '<path d="M9 11l3 3L22 4M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11"/>'},
    {id = "kits", label = "Kits", section = "BASIC", order = 2.5, component = "BusinessKitsTab",
      icon = '<rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>'},
    {id = "inventory", label = "Inventory", section = "BASIC", order = 3, component = "BusinessInventoryTab",
      icon = '<path d="M16.5 9.4l-9-5.19M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/><polyline points="3.27 6.96 12 12.01 20.73 6.96"/><line x1="12" y1="22.08" x2="12" y2="12"/>'},
    {id = "techs", label = "Techs", section = "BASIC", order = 4, component = "BusinessTechsTab",
      icon = '<circle cx="12" cy="7" r="4"/><path d="M6 21v-2a4 4 0 0 1 4-4h4a4 4 0 0 1 4 4v2"/><circle cx="19" cy="7" r="3"/><path d="M22 21v-2a3 3 0 0 0-3-3h-2"/>'},
    {id = "finances", label = "Finances", section = "BASIC", order = 5, component = "BusinessFinancesTab",
      icon = '<path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6"/>'},
  }
end

local function ensureTabsRegistered()

  local existingTabs = overhaul_career_business_tabRegistry.getTabs(BUSINESS_TYPE) or {}
  if #existingTabs > 0 then
    return true
  end

  for _, tab in ipairs(shopTabDefinitions()) do
    overhaul_career_business_tabRegistry.registerTab(BUSINESS_TYPE, tab)
  end
  return true
end

local function keepTabs(tabs, shouldKeep)
  local kept = {}
  for _, tab in ipairs(tabs) do
    if shouldKeep(tab) then
      table.insert(kept, tab)
    end
  end
  return kept
end

-- Business and fleet read helpers -----------------------------------------------------------------

local function businessNameFor(business, businessId)
  if business then
    return business.name or DEFAULT_BUSINESS_NAME
  end
  local savedInfo = overhaul_career_business_manager.getBusinessInfo(BUSINESS_TYPE, businessId)
  if savedInfo and savedInfo.name then
    return savedInfo.name
  end
  return DEFAULT_BUSINESS_NAME
end

local function readFleetVehicles(businessId, isOnBusinessMap)
  if isOnBusinessMap then
    return overhaul_career_business_fleet.getBusinessVehicles(businessId) or {}
  end
  return {}
end

-- Off the map the fleet reads empty, so say why the jobs show no cars.
local function logOffMapFleetHidden(businessId, jobs, vehicles, isOnBusinessMap)
  local activeCount = #(jobs.active or {})
  local newCount = #(jobs.new or {})
  if not isOnBusinessMap and (activeCount + newCount) > 0 and #vehicles == 0 then
    log('D', 'tuningShop.getUIData', string.format(
      'off-map fleet hidden: businessId=%s activeJobs=%d newJobs=%d (vehicles[] empty until on business map)',
      tostring(businessId), activeCount, newCount))
  end
end

local function readPulledOutVehicles(businessId, isOnBusinessMap)
  if not isOnBusinessMap then
    return {}
  end
  return overhaul_career_business_fleet.getPulledOutVehicles(businessId) or {}
end

-- Menu opening ------------------------------------------------------------------------------------

local function openMenu(businessId)
  ensureTabsRegistered()
  extensions.ui_router.navigate('business-computer', {
    businessType = BUSINESS_TYPE,
    businessId = tostring(businessId),
  })
end

local installer = {}

function installer.new(inputs)
  local parts = inputs.parts
  -- Owner state --------------------------------------------------------------------------------------
  local operations = {}

  -- Shared helpers ------------------------------------------------------------------------------

  -- Required lazily: the helpers pull in the capability registry, which must load in the same order as before.
  local function vehicleDisplayInfo(modelKey, configKey)
    local name, vehicleYear, vehicleType, vehicleImage =
      require('overhaul/lib/business/helpers').extractDisplayInfo(parts.persist.getVehicleInfo(modelKey, configKey))
    return name or modelKey, vehicleYear, vehicleType, vehicleImage
  end

  -- Job rows ------------------------------------------------------------------------------------
  local function jobCompletionStatus(job, businessId)
    if job.status == "active" and businessId and job.jobId then
      return parts.proof.jobCompletion.getStatus(businessId, job.jobId) or {}
    end
    return {}
  end

  local function jobExpiresInSeconds(job, businessId)
    if job.status ~= "new" then
      return nil
    end
    local lifetime = tonumber(job.remainingLifetime)
    if not lifetime or lifetime < 0 then
      lifetime = parts.garage.getJobExpirySeconds(businessId)
    end
    return math.max(0, math.floor(lifetime))
  end

  local function formatJobForUI(job, businessId)
    if not job then
      return nil
    end

    local vehicleConfig = job.vehicleConfig or {}
    local vehicleName, vehicleYear, vehicleType, vehicleImage =
      vehicleDisplayInfo(vehicleConfig.model_key or "unknown", vehicleConfig.key or "unknown")
    local unit = job.timeUnit or "s"
    local scale = ({s = 1, min = 60, ms = 0.001})[unit] or 1
    local decimalPlaces = job.decimalPlaces or 0
    local goal = formatGoalTime(job.targetTime or 0, decimalPlaces) .. " " .. (job.raceLabel or "")

    local baselineTime = roundToPlaces((job.baseTime or 0) / scale, decimalPlaces)
    local currentTime = roundToPlaces(currentJobTime(job, businessId, parts.proof.jobCompletion) / scale, decimalPlaces)
    local goalTime = roundToPlaces((job.targetTime or 0) / scale, decimalPlaces)

    local penalty = parts.settlement.getAbandonPenalty(businessId, job.jobId)
    local completionStatus = jobCompletionStatus(job, businessId)
    local expiresInSeconds = jobExpiresInSeconds(job, businessId)

    return {
      id = tostring(job.jobId),
      jobId = job.jobId,
      storedVehicleId = job.storedVehicleId,
      vehicleName = vehicleName,
      vehicleYear = vehicleYear or "Unknown",
      vehicleType = vehicleType,
      vehicleImage = vehicleImage,
      goal = goal,
      reward = job.reward or 20000,
      status = job.status or "new",
      baselineTime = baselineTime,
      currentTime = currentTime,
      goalTime = goalTime,
      timeUnit = unit,
      raceType = job.raceType,
      raceLabel = job.raceLabel,
      decimalPlaces = decimalPlaces,
      expiresInSeconds = expiresInSeconds,
      penalty = penalty,
      techAssigned = job.techAssigned,
      isLocked = job.locked or false,
      tier = tonumber(job.tier) or 1,
      canComplete = completionStatus.canComplete or false,
      goalTimeMet = completionStatus.goalTimeMet or false,
      buildChanged = completionStatus.buildChanged or false,
      completionBlockedMessage = completionStatus.blockedMessage,
    }
  end

  local function formatJobRows(jobRows, businessId)
    local rows = {}
    for _, job in ipairs(jobRows or {}) do
      table.insert(rows, formatJobForUI(job, businessId))
    end
    return rows
  end

  -- Vehicle rows --------------------------------------------------------------------------------

  -- Kit locks tell the UI a car is being fitted and how long is left.
  local function applyKitInstallLock(result, businessId, vehicleId)
    local kitsModule = inputs.getTuningShopKits()
    result.kitInstallLocked = kitsModule.isVehicleKitLocked(businessId, vehicleId)
    if not result.kitInstallLocked then
      return
    end
    result.kitInstallTimeRemaining = kitsModule.getKitInstallTimeRemaining(businessId, vehicleId)
    local lock = kitsModule.getKitInstallLock(businessId, vehicleId)
    if lock then
      result.kitInstallKitName = lock.kitName
    end
  end

  local function formatVehicleForUI(vehicle, businessId)
    if not vehicle then
      return nil
    end

    local vehicleConfig = vehicle.vehicleConfig or {}
    local modelKey = vehicleConfig.model_key or vehicle.model_key or "unknown"
    local configKey = vehicleConfig.key or vehicle.config_key or "unknown"
    local vehicleName, vehicleYear, vehicleType, vehicleImage = vehicleDisplayInfo(modelKey, configKey)

    local spawnedVehicleId = vehicle.spawnedVehicleId
    if not spawnedVehicleId then
      spawnedVehicleId = overhaul_career_business_fleet.getSpawnedVehicleId(businessId, vehicle.vehicleId)
    end

    local result = {
      id = tostring(vehicle.vehicleId),
      vehicleId = vehicle.vehicleId,
      vehicleName = vehicleName,
      vehicleYear = vehicleYear,
      vehicleType = vehicleType,
      vehicleImage = vehicleImage,
      jobId = vehicle.jobId,
      storedTime = vehicle.storedTime,
      spawnedVehicleId = spawnedVehicleId,
      model_key = modelKey,
      config_key = configKey,
    }

    if vehicle.isPersonal then
      result.isPersonal = true
      result.inventoryId = vehicle.inventoryId
      result.spawnedVehicleId = vehicle.spawnedVehicleId
      result.inGarageZone = true
    end

    applyKitInstallLock(result, businessId, vehicle.vehicleId)
    return result
  end

  local function isDamageLocked(businessId, vehicleId)
    local threshold = inputs.getDamageThreshold(businessId)
    local lockInfo = {locked = false, damage = 0, threshold = threshold}
    if not businessId or not vehicleId then
      return lockInfo
    end

    local vehObj = getBusinessVehicleObject(businessId, vehicleId)
    local vehId = vehObj and vehObj:getID()
    if not vehId then
      return lockInfo
    end

    local damage = getVehicleDamageByVehId(vehId)
    lockInfo.damage = damage
    lockInfo.locked = damage >= threshold
    return lockInfo
  end

  -- Garage rows ---------------------------------------------------------------------------------

  -- A pulled-out car is active when it matches the active id, after numeric coercion.
  local function formatPulledOutGarageRow(businessId, vehicle, activeVehicleId)
    local formatted = formatVehicleForUI(vehicle, businessId)
    if not formatted then
      return nil
    end
    local damageInfo = isDamageLocked(businessId, vehicle.vehicleId)
    formatted.damage = damageInfo.damage
    formatted.damageLocked = damageInfo.locked
    formatted.damageThreshold = damageInfo.threshold
    formatted.inGarageZone = true
    formatted.isActive = (activeVehicleId and (tonumber(formatted.vehicleId) or formatted.vehicleId) == activeVehicleId) or false
    return formatted, damageInfo
  end

  -- Personal cars take no damage, and their active check compares the raw id.
  local function formatPersonalGarageRow(businessId, personalVehicle, activeVehicleId)
    local formatted = formatVehicleForUI(personalVehicle, businessId)
    if not formatted then
      return nil
    end
    formatted.damage = 0
    formatted.damageLocked = false
    formatted.damageThreshold = inputs.getDamageThreshold(businessId)
    formatted.inGarageZone = true
    formatted.isPersonal = true
    formatted.inventoryId = personalVehicle.inventoryId
    formatted.spawnedVehicleId = personalVehicle.spawnedVehicleId
    formatted.isActive = (activeVehicleId and formatted.vehicleId == activeVehicleId) or false
    return formatted
  end

  local function formatTuningShopGarageVehicles(businessId, activeVehicle, pulledOutVehiclesInZone, personalVehiclesInZone)
    local activeVehicleId = activeVehicle and (tonumber(activeVehicle.vehicleId) or activeVehicle.vehicleId)
    local pulledOutDamageInfo = {locked = false, damage = 0, threshold = inputs.getDamageThreshold(businessId)}
    local formattedPulledOutVehicles = {}
    local hasDamageLockedVehicle = false

    for _, vehicle in ipairs(pulledOutVehiclesInZone) do
      local formatted, damageInfo = formatPulledOutGarageRow(businessId, vehicle, activeVehicleId)
      if formatted then
        if damageInfo.locked then
          hasDamageLockedVehicle = true
        end
        if formatted.isActive then
          pulledOutDamageInfo = damageInfo
        end
        table.insert(formattedPulledOutVehicles, formatted)
      end
    end

    for _, personalVehicle in ipairs(personalVehiclesInZone) do
      local formatted = formatPersonalGarageRow(businessId, personalVehicle, activeVehicleId)
      if formatted then
        table.insert(formattedPulledOutVehicles, formatted)
      end
    end

    return {
      activeVehicleId = activeVehicleId,
      pulledOutDamageInfo = pulledOutDamageInfo,
      formattedPulledOutVehicles = formattedPulledOutVehicles,
      hasDamageLockedVehicle = hasDamageLockedVehicle,
    }
  end

  -- Finances ------------------------------------------------------------------------------------
  local function operatingCostTimerData(businessId, operatingCosts)
    if operatingCosts.solarPowerActive or not (operatingCosts.total > 0) then
      return nil
    end
    local timerState = parts.manager.loadOperatingCostTimer(businessId)
    return {
      elapsed = timerState.elapsed,
      lastChargeTime = timerState.lastChargeTime,
      paymentInterval = PAYMENT_INTERVAL_SECONDS,
      remainingTime = PAYMENT_INTERVAL_SECONDS - (timerState.elapsed % PAYMENT_INTERVAL_SECONDS),
    }
  end

  local function getFinancesData(businessId)
    if not businessId then
      return nil
    end

    local operatingCosts = parts.manager.getOperatingCosts(businessId)
    local account = overhaul_career_economy_bank.getBusinessAccount(BUSINESS_TYPE, businessId)
    local accountId, accountBalance, transactions = nil, 0, {}
    if account then
      accountId = account.id
      accountBalance = overhaul_career_economy_bank.getAccountBalance(accountId) or 0
      transactions = overhaul_career_economy_bank.getAccountTransactions(accountId, 100) or {}
    end

    return {
      operatingCosts = operatingCosts,
      account = {id = accountId, balance = accountBalance, name = account and account.name or nil},
      transactions = transactions,
      loans = accountLoans(accountId),
      operatingCostTimer = operatingCostTimerData(businessId, operatingCosts),
    }
  end

  local function requestFinancesData(businessId)
    if not businessId then
      guihooks.trigger('businessComputer:onFinancesData', {success = false, error = "Missing businessId"})
      return
    end

    local financesData = getFinancesData(businessId)
    if not financesData then
      guihooks.trigger('businessComputer:onFinancesData', {
        success = false,
        error = "Failed to get finances data",
        businessId = businessId,
      })
      return
    end

    guihooks.trigger('businessComputer:onFinancesData', {
      success = true,
      businessId = businessId,
      finances = financesData,
      simulationTime = os.time(),
    })
  end

  -- Tabs ----------------------------------------------------------------------------------------

  local function getTuningShopVisibleTabs(businessType, businessId, hasDamageLockedVehicle)

    ensureTabsRegistered()
    local skillTree = overhaul_career_business_skillTree
    pcall(function()
      skillTree.ensureTabsRegistered(businessType)
    end)

    local tabs = overhaul_career_business_tabRegistry.getTabs(businessType) or {}
    if hasDamageLockedVehicle then
      tabs = keepTabs(tabs, function(tab) return tab.id and DAMAGE_LOCKED_TAB_IDS[tab.id] end)
    end

    local tuningShopKits = inputs.getTuningShopKits()
    if not tuningShopKits.hasKitStorageUnlocked(businessId) then
      tabs = keepTabs(tabs, function(tab) return tab.id ~= "kits" end)
    end
    return tabs
  end

  -- Manager -------------------------------------------------------------------------------------
  local function isTuningShopManagerReadyToAssign(businessId)
    if not parts.manager.hasManager(businessId) then return false end
    if parts.manager.hasGeneralManager(businessId) then return true end
    local timerState = parts.manager.getManagerTimerState(businessId)
    return timerState.flagActive == true
  end

  local function isTuningShopManagerPaused(businessId)
    if not parts.manager.hasManager(businessId) then return false end
    local timerState = parts.manager.getManagerTimerState(businessId)
    return timerState.paused == true
  end

  -- Time until the next manager assignment; nil when no manager counts down.
  local function managerTimeRemaining(businessId)
    if not parts.manager.hasManager(businessId) or parts.manager.hasGeneralManager(businessId) then
      return nil
    end
    local timerState = parts.manager.getManagerTimerState(businessId)
    local interval = parts.manager.getManagerAssignmentInterval(businessId)
    return math.max(0, interval - timerState.elapsed)
  end

  local function applyManagerFields(record, businessId)
    record.hasManager = parts.manager.hasManager(businessId)
    record.hasGeneralManager = parts.manager.hasGeneralManager(businessId)
    record.managerAssignmentInterval = parts.manager.hasManager(businessId) and parts.manager.getManagerAssignmentInterval(businessId) or nil
    record.managerReadyToAssign = isTuningShopManagerReadyToAssign(businessId)
    record.managerTimeRemaining = managerTimeRemaining(businessId)
    record.managerPaused = isTuningShopManagerPaused(businessId)
  end

  -- UI projection: business and fleet reads -----------------------------------------------------
  local function pulledOutVehiclesInGarage(businessId, pulledOutVehiclesRaw)
    local inZone = {}
    for _, vehicle in ipairs(pulledOutVehiclesRaw) do
      if parts.garage.isSpawnedVehicleInGarageZone(businessId, vehicle.vehicleId) then
        table.insert(inZone, vehicle)
      end
    end
    return inZone
  end

  -- Personal cars show only with the unlock, the player in the shop zone and the business on the map.
  local function readPersonalVehiclesInZone(businessId, isOnBusinessMap, playerInZone, personalUseUnlocked)
    local personalVehiclesInZone = {}
    if personalUseUnlocked and playerInZone and isOnBusinessMap then
      for _, invVeh in ipairs(parts.garage.getInventoryVehiclesInGarageZone(businessId)) do
        local personalEntry = parts.garage.createPersonalVehicleEntry(businessId, invVeh.inventoryId, invVeh.inventoryVehicleData, invVeh.spawnedId)
        if personalEntry then
          table.insert(personalVehiclesInZone, personalEntry)
        end
      end
    end
    return personalVehiclesInZone
  end

  -- The fleet's active car wins when it is in the zone; otherwise the first in-zone car is active.
  local function pickActiveVehicle(businessId, isOnBusinessMap, pulledOutVehiclesInZone, personalVehiclesInZone)
    if not isOnBusinessMap then
      return nil, false
    end
    local fleet = overhaul_career_business_fleet
    local rawActive = fleet.getActiveVehicle(businessId)
    if rawActive and parts.garage.isSpawnedVehicleInGarageZone(businessId, rawActive.vehicleId) then
      return rawActive, false
    end
    if #pulledOutVehiclesInZone > 0 then
      return pulledOutVehiclesInZone[1], false
    end
    if #personalVehiclesInZone > 0 then
      return personalVehiclesInZone[1], true
    end
    return nil, false
  end

  local function rememberPersonalSelection(businessId, activeVehicle, selectedPersonalVehicle)
    if selectedPersonalVehicle and activeVehicle and activeVehicle.isPersonal then
      inputs.activePersonalVehicle[parts.garage.normalizeBusinessId(businessId)] = activeVehicle
    end
  end

  -- UI projection: rows and stats ---------------------------------------------------------------
  local function formatFleetRows(vehicles, businessId, isOnBusinessMap)
    local rows = {}
    -- Fleet rows feed Jobs Pull Out even if the player briefly leaves the garage trigger.
    if isOnBusinessMap then
      for _, vehicle in ipairs(vehicles) do
        table.insert(rows, formatVehicleForUI(vehicle, businessId))
      end
    end
    return rows
  end

  local function summarizePulledOutVehicle(activeVehicle, pulledOutDamageInfo, businessId)
    if not activeVehicle then
      return nil
    end
    local summary = formatVehicleForUI(activeVehicle, businessId)
    if not summary then
      return nil
    end
    summary.inGarageZone = true
    summary.damage = pulledOutDamageInfo.damage
    summary.damageLocked = pulledOutDamageInfo.locked
    summary.damageThreshold = pulledOutDamageInfo.threshold
    if activeVehicle.isPersonal then
      summary.isPersonal = true
      summary.inventoryId = activeVehicle.inventoryId
      summary.spawnedVehicleId = activeVehicle.spawnedVehicleId
    end
    return summary
  end

  local function techEntriesFor(businessId)
    local entries = {}
    for _, tech in ipairs(inputs.tuningShopTechs.loadBusinessTechs(businessId)) do
      local formattedTech = inputs.tuningShopTechs.formatTechForUIEntry(businessId, tech)
      if formattedTech then
        table.insert(entries, formattedTech)
      end
    end
    return entries
  end

  local function statsFor(businessId, vehicleList, storedParts, activeJobs, newJobs)
    local totalPartsValue = 0
    for _, part in ipairs(storedParts) do
      totalPartsValue = totalPartsValue + (part.price or part.value or 0)
    end
    return {
      totalVehicles = #vehicleList,
      totalParts = #storedParts,
      totalPartsValue = totalPartsValue,
      activeJobsCount = #activeJobs,
      newJobsCount = #newJobs,
      kits = inputs.getTuningShopKits().loadBusinessKits(businessId),
      maxKitStorage = inputs.getTuningShopKits().getMaxKitStorage(businessId),
      currentKitCount = #(inputs.getTuningShopKits().loadBusinessKits(businessId)),
    }
  end

  -- UI projection -------------------------------------------------------------------------------
  local function getUIData(businessId)
    if not businessId then
      return nil
    end

    local business = overhaul_world_facilities.getFacility(BUSINESS_TYPE, businessId)
    local isOnBusinessMap = business ~= nil
    local businessName = businessNameFor(business, businessId)
    local playerInZone = isOnBusinessMap and parts.garage.isPlayerInTuningShopZone(businessId) or false

    local jobs = parts.generation.getJobsForBusiness(businessId)
    local vehicles = readFleetVehicles(businessId, isOnBusinessMap)
    logOffMapFleetHidden(businessId, jobs, vehicles, isOnBusinessMap)
    local pulledOutVehiclesInZone = pulledOutVehiclesInGarage(businessId, readPulledOutVehicles(businessId, isOnBusinessMap))
    local personalUseUnlocked = parts.garage.isPersonalUseUnlocked(businessId)
    local personalVehiclesInZone = readPersonalVehiclesInZone(businessId, isOnBusinessMap, playerInZone, personalUseUnlocked)

    local activeVehicle, selectedPersonalVehicle =
      pickActiveVehicle(businessId, isOnBusinessMap, pulledOutVehiclesInZone, personalVehiclesInZone)
    rememberPersonalSelection(businessId, activeVehicle, selectedPersonalVehicle)
    local garage = formatTuningShopGarageVehicles(businessId, activeVehicle, pulledOutVehiclesInZone, personalVehiclesInZone)

    local activeJobs = formatJobRows(jobs.active, businessId)
    local newJobs = formatJobRows(jobs.new, businessId)
    local vehicleList = formatFleetRows(vehicles, businessId, isOnBusinessMap)
    local pulledOutVehicleData = summarizePulledOutVehicle(activeVehicle, garage.pulledOutDamageInfo, businessId)
    local storedParts = {}
    local tabs = getTuningShopVisibleTabs(BUSINESS_TYPE, businessId, garage.hasDamageLockedVehicle)
    local techEntries = techEntriesFor(businessId)

    local record = {
      businessId = businessId,
      businessType = BUSINESS_TYPE,
      businessName = businessName,
      activeJobs = activeJobs,
      newJobs = newJobs,
      vehicles = vehicleList,
      parts = storedParts,
      pulledOutVehicle = pulledOutVehicleData,
      pulledOutVehicles = garage.formattedPulledOutVehicles,
      activeVehicleId = garage.activeVehicleId,
      maxPulledOutVehicles = parts.generation.getMaxPulledOutVehicles(businessId),
      tabs = tabs,
      techs = techEntries,
      vehicleDamage = garage.pulledOutDamageInfo.damage,
      vehicleDamageLocked = garage.pulledOutDamageInfo.locked,
      vehicleDamageThreshold = garage.pulledOutDamageInfo.threshold,
      maxActiveJobs = parts.settlement.getMaxActiveJobs(businessId),
      playerInZone = playerInZone,
      stats = statsFor(businessId, vehicleList, storedParts, activeJobs, newJobs),
      personalUseUnlocked = personalUseUnlocked,
    }
    applyManagerFields(record, businessId)
    return record
  end

  -- Operations ----------------------------------------------------------------------------------

  -- Kept as a table so the job lists can call each other through it.
  local function getActiveJobs(businessId, skipRefresh)
    local normalizedId = parts.garage.normalizeBusinessId(businessId)
    local jobs = skipRefresh and parts.persist.loadBusinessJobs(normalizedId) or parts.generation.getJobsForBusiness(normalizedId)
    return formatJobRows(jobs.active, normalizedId)
  end

  local function getNewJobs(businessId, skipRefresh)
    local normalizedId = parts.garage.normalizeBusinessId(businessId)
    local jobs = skipRefresh and parts.persist.loadBusinessJobs(normalizedId) or parts.generation.getJobsForBusiness(normalizedId)
    return formatJobRows(jobs.new, normalizedId)
  end

  operations.getJobsOnly = function(businessId, skipRefresh)
    local normalizedId = parts.garage.normalizeBusinessId(businessId)
    return {
      businessId = tostring(normalizedId),
      businessType = BUSINESS_TYPE,
      activeJobs = getActiveJobs(normalizedId, skipRefresh),
      newJobs = getNewJobs(normalizedId, skipRefresh),
      maxActiveJobs = parts.settlement.getMaxActiveJobs(normalizedId),
    }
  end

  operations.notifyJobsUpdated = function(businessId)
    if not businessId then
      return
    end
    guihooks.trigger('businessComputer:onJobsUpdated', operations.getJobsOnly(businessId, true))
  end

  -- Requests ------------------------------------------------------------------------------------
  local function requestAvailableBrands()
    guihooks.trigger('businessComputer:onAvailableBrandsReceived', {brands = parts.generation.getAvailableBrands()})
  end

  local function requestAvailableRaceTypes(businessId)
    guihooks.trigger('businessComputer:onAvailableRaceTypesReceived', {raceTypes = parts.generation.getAvailableRaceTypes(businessId)})
  end

  -- Public API ----------------------------------------------------------------------------------
  return {
    ensureTabsRegistered = ensureTabsRegistered,
    formatVehicleForUI = formatVehicleForUI,
    getActiveJobs = getActiveJobs,
    getFinancesData = getFinancesData,
    getJobsOnly = operations.getJobsOnly,
    getNewJobs = getNewJobs,
    getUIData = getUIData,
    notifyJobsUpdated = operations.notifyJobsUpdated,
    openMenu = openMenu,
    requestAvailableBrands = requestAvailableBrands,
    requestAvailableRaceTypes = requestAvailableRaceTypes,
    requestFinancesData = requestFinancesData,
    requestSimulationTime = requestSimulationTime,
  }
end

return installer
