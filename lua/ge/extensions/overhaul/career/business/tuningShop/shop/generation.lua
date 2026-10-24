-- Customer-job selection, quotation and refresh for one tuning shop.
-- Read vehicle/race selection, quote terms, notifications and refresh operations.
local installer = {}
local phoneLayout = require("overhaul/lib/phone/layoutOwner")

function installer.new(inputs)
  -- State and callbacks -------------------------------------------------------------------------
  local parts = inputs.parts
  local operations = {}
  local shop = inputs.shop

  -- Vehicle catalog -------------------------------------------------------------------------------

  local function buildBrandConfigsCache()
    local configs = parts.selections.getFactoryConfigs()
    shop.brandConfigsCache = {}
    for _, config in ipairs(configs) do
      local brand = config.Brand
      if not brand and config.aggregates and config.aggregates.Brand then
        brand = next(config.aggregates.Brand)
      end
      if brand and brand ~= "" then
        shop.brandConfigsCache[brand] = shop.brandConfigsCache[brand] or {}
        table.insert(shop.brandConfigsCache[brand], config)
      end
    end
  end

  local function calculateJobGenerationMultiplier(businessId)
    local availableVehicles = parts.selections.getAvailableVehiclesForBlacklist(businessId)
    local totalAvailable = #availableVehicles

    if totalAvailable == 0 then return 1.0 end

    local blacklist = parts.selections.getBlacklist(businessId)
    local availableSet = {}
    for _, availableKey in ipairs(availableVehicles) do
      availableSet[availableKey] = true
    end

    local blacklistedCount = 0
    for modelKey, _ in pairs(blacklist) do
      if availableSet[modelKey] then
        blacklistedCount = blacklistedCount + 1
      end
    end

    local multiplier = (totalAvailable - blacklistedCount) / totalAvailable
    return math.max(0.0, math.min(1.0, multiplier))
  end

  local function getAvailableBrands()
    local configs = parts.selections.getFactoryConfigs()
    local brands = {}
    local brandSet = {}

    if not configs or #configs == 0 then return brands end

    for _, config in ipairs(configs) do
      if not config or not config.model_key or not config.key then
        goto continue
      end

      local brand = nil
      local vehicleInfo = parts.persist.getVehicleInfo(config.model_key, config.key)

      if vehicleInfo then
        if vehicleInfo.Brand and vehicleInfo.Brand ~= "" then
          brand = vehicleInfo.Brand
        elseif vehicleInfo.aggregates and vehicleInfo.aggregates.Brand then
          local brandAgg = vehicleInfo.aggregates.Brand
          if type(brandAgg) == "table" then
            brand = next(brandAgg)
          elseif type(brandAgg) == "string" then
            brand = brandAgg
          end
        end
      end

      if not brand or brand == "" then
        if config.Brand and config.Brand ~= "" then
          brand = config.Brand
        elseif config.aggregates and config.aggregates.Brand then
          local brandAgg = config.aggregates.Brand
          if type(brandAgg) == "table" then
            brand = next(brandAgg)
          elseif type(brandAgg) == "string" then
            brand = brandAgg
          end
        end
      end

      if brand and brand ~= "" and not brandSet[brand] then
        brandSet[brand] = true
        table.insert(brands, brand)
      end

      ::continue::
    end

    table.sort(brands)
    return brands
  end

  local function getAvailableRaceTypes(businessId)
    businessId = businessId or nil
    local info = nil
    if businessId then
      parts.persist.initializeBusinessData(businessId)
      info = parts.persist.loadBusinessInfo(businessId)
    end

    local races = parts.persist.loadRaceData(businessId)
    if not races or not races.races then return {} end

    local raceTypes = {}
    local racesToCheck = {}

    if info and info.races and #info.races > 0 then
      racesToCheck = info.races
    else
      for raceIdentifier, _ in pairs(races.races) do
        table.insert(racesToCheck, raceIdentifier)
      end
    end

    for _, raceIdentifier in ipairs(racesToCheck) do
      local race = races.races[raceIdentifier]
      if race and parts.persist.getBusinessProof(businessId, raceIdentifier) then
        table.insert(raceTypes, {
          id = parts.persist.convertRaceIdentifierToType(raceIdentifier),
          label = race.label or raceIdentifier
        })
      end
    end

    return raceTypes
  end

  -- Lift capacity ---------------------------------------------------------------------------------

  local function getMaxPulledOutVehicles(businessId)
    local limit = 1
    if not businessId then return limit end

    local treeId = "shop-upgrades"
    local upgrades = {"lift-2", "lift-3", "lift-4"}

    for _, nodeId in ipairs(upgrades) do
      local level = overhaul_career_business_skillTree.getNodeProgress(businessId, treeId, nodeId) or 0
      if level > 0 then
        limit = limit + 1
      end
    end

    return limit
  end

  -- Customer selection ----------------------------------------------------------------------------

  local function selectJobLevel(upgradeCount, maxLevels)
    if upgradeCount == 0 then
      return 1
    elseif upgradeCount == 1 then
      if math.random() < 0.5 then
        return 1
      else
        return math.min(2, maxLevels)
      end
    else
      local rand = math.random()
      if rand < 0.3333 then
        return 1
      elseif rand < 0.6666 then
        return math.min(2, maxLevels)
      else
        return math.min(3, maxLevels)
      end
    end
  end

  local function selectCustomerVehicle(businessId)
    local configs = parts.selections.getFactoryConfigs()
    if not configs or #configs == 0 then return nil end

    local blacklist = parts.selections.getBlacklist(businessId)
    local availableConfigs = {}

    for _, config in ipairs(configs) do
      if config and config.model_key and not blacklist[config.model_key] then
        table.insert(availableConfigs, config)
      end
    end

    if #availableConfigs == 0 then return nil end

    local selectedConfig = nil
    local brandSelection = parts.persist.getBrandSelection(businessId)
    local brandRecognitionUnlocked = parts.garage.getSkillTreeLevel(businessId, "quality-of-life", "brand-recognition") > 0

    if brandRecognitionUnlocked and brandSelection and brandSelection ~= "" then
      if math.random() < 0.75 then
        local brandConfigs = {}
        for _, config in ipairs(availableConfigs) do
          local brand = config.Brand
          if not brand and config.aggregates and config.aggregates.Brand then
            brand = next(config.aggregates.Brand)
          end
          if brand == brandSelection then
            table.insert(brandConfigs, config)
          end
        end
        if #brandConfigs > 0 then
          selectedConfig = brandConfigs[math.random(#brandConfigs)]
        end
      end
    end

    if not selectedConfig then
      selectedConfig = availableConfigs[math.random(#availableConfigs)]
    end

    return selectedConfig
  end

  -- Performance and race selection ----------------------------------------------------------------

  local function readCustomerVehiclePerformance(selectedConfig)
    local power = selectedConfig.Power
    if not power and selectedConfig.aggregates and selectedConfig.aggregates.Power then
      power = selectedConfig.aggregates.Power.min or selectedConfig.aggregates.Power.max
    end
    power = power or 0

    local weight = selectedConfig.Weight
    if not weight and selectedConfig.aggregates and selectedConfig.aggregates.Weight then
      weight = selectedConfig.aggregates.Weight.min or selectedConfig.aggregates.Weight.max
    end
    weight = weight or 0

    if power == 0 or weight == 0 then return nil end

    local year = 2000
    if overhaul_dev_raceDataCollection and overhaul_dev_raceDataCollection.getYearFromModel then
      year = overhaul_dev_raceDataCollection.getYearFromModel(selectedConfig.model_key)
    end
    local powerToWeight = power / weight

    return power, weight, year, powerToWeight
  end

  local function selectCustomerRace(businessId, races)
    -- a new shop's races are only in the in-memory cache until the next save
    local info = shop.cachedBusinessMapInfo[parts.garage.normalizeBusinessId(businessId)]
    if not info or not info.races or #info.races == 0 then
      info = parts.persist.loadBusinessInfo(businessId)
    end
    if not info or not info.races or #info.races == 0 then return nil end

    local raceType = nil
    local raceSelection = parts.selections.getRaceSelection(businessId)
    local raceRecognitionUnlocked = parts.garage.getSkillTreeLevel(businessId, "quality-of-life", "race-recognition") > 0

    local availableRaceTypes = {}
    for _, raceIdentifier in ipairs(info.races) do
      if races.races[raceIdentifier] and parts.persist.getBusinessProof(businessId, raceIdentifier) then
        table.insert(availableRaceTypes, raceIdentifier)
      end
    end

    if #availableRaceTypes == 0 then return nil end

    if raceRecognitionUnlocked and raceSelection and raceSelection ~= "" then
      if math.random() < 0.75 then
        for _, candidate in ipairs(availableRaceTypes) do
          if candidate == raceSelection then
            raceType = raceSelection
            break
          end
        end
      end
    end

    if not raceType then
      raceType = availableRaceTypes[math.random(#availableRaceTypes)]
    end

    local raceIdentifier = parts.persist.convertRaceTypeToIdentifier(raceType)
    local race = races.races[raceIdentifier]
    local raceLabel = race and race.label or ""

    return raceType, raceIdentifier, race, raceLabel
  end

  -- Job pricing -----------------------------------------------------------------------------------

  local function predictCustomerRaceTime(businessId, power, weight, year, powerToWeight, raceType, race)
    local baseTime = nil
    if race and overhaul_dev_raceDataCollection and overhaul_dev_raceDataCollection.predictRaceTime then
      baseTime = math.abs(overhaul_dev_raceDataCollection.predictRaceTime(power, weight, year, race) + 0.5)
    end
    if not baseTime then
      local powerToWeight = power / weight
      baseTime = parts.persist.powerToWeightToTime(powerToWeight, raceType, businessId)
    end
    if not baseTime then return nil end

    return baseTime
  end

  local function quoteCustomerJob(businessId, selectedConfig, power, weight, year, powerToWeight, raceType, raceLabel, race, baseTime)
    local tuningShopConfig = race and race.tuningShop or {}
    local levels = tuningShopConfig.levels or {}
    local decimalPlaces = tuningShopConfig.decimalPlaces or 0
    local commuteSeconds = tuningShopConfig.commute or tuningShopConfig.communte or 120
    if not levels or #levels == 0 then return nil end
    local upgradeCount = parts.persist.getSkillTreeUpgradeCount(businessId)
    local maxAvailableLevel = math.min(#levels, upgradeCount + 1)
    local selectedLevelIndex = selectJobLevel(upgradeCount, maxAvailableLevel)
    selectedLevelIndex = math.min(selectedLevelIndex, #levels)
    selectedLevelIndex = math.max(1, selectedLevelIndex)
    local levelData = levels[selectedLevelIndex]
    if not levelData then return nil end
    local minImprovement = levelData.minImprovement or 1.1
    local maxImprovement = levelData.maxImprovement or 1.2
    local minPayout = levelData.minPayout or 20000
    local maxPayout = levelData.maxPayout or 30000
    local divisor = minImprovement + math.random() * (maxImprovement - minImprovement)
    local targetTime = baseTime / divisor
    local multiplier = 10 ^ decimalPlaces
    baseTime = math.floor(baseTime * multiplier + 0.5) / multiplier
    targetTime = math.floor(targetTime * multiplier + 0.5) / multiplier
    local mileageMinMiles = 20000
    local mileageMaxMiles = 120000
    local mileageMiles = math.random(mileageMinMiles, mileageMaxMiles)
    local mileageMeters = mileageMiles * 1609.34
    local rewardRaw = minPayout + math.random() * (maxPayout - minPayout)
    local reward = math.floor(rewardRaw / 1000) * 1000
    shop.jobIdCounter = shop.jobIdCounter + 1
    local job = {
      jobId = shop.jobIdCounter,
      vehicleConfig = {
        model_key = selectedConfig.model_key,
        key = selectedConfig.key
      },
      mileage = mileageMeters,
      raceType = raceType,
      raceId = raceType,
      proofVersion = 1,
      targetTimeUnit = "s",
      timeUnit = race.businessProof.timeUnit,
      raceLabel = raceLabel,
      baseTime = baseTime,
      targetTime = targetTime,
      powerToWeight = powerToWeight,
      power = power,
      weight = weight,
      year = year,
      reward = reward,
      decimalPlaces = decimalPlaces,
      commuteSeconds = commuteSeconds,
      eventReward = race and race.reward or 0,
      tier = selectedLevelIndex
    }
    return job
  end


  -- Job generation --------------------------------------------------------------------------------

  local function generateJob(businessId)
    parts.persist.syncJobIdCounter()
    local selectedConfig = selectCustomerVehicle(businessId)
    if not selectedConfig then return nil end
    local power, weight, year, powerToWeight = readCustomerVehiclePerformance(selectedConfig)
    if not power then return nil end
    local races = parts.persist.loadRaceData(businessId)
    if not races or not races.races then return nil end
    local raceType, _, race, raceLabel = selectCustomerRace(businessId, races)
    if not raceType then return nil end
    local baseTime = predictCustomerRaceTime(businessId, power, weight, year, powerToWeight, raceType, race)
    if not baseTime then return nil end
    return quoteCustomerJob(businessId, selectedConfig, power, weight, year, powerToWeight, raceType, raceLabel, race, baseTime)
  end

  local function generateNewJobs(businessId, count)
    count = count or 5
    local newJobs = {}

    for _ = 1, count do
      local job = generateJob(businessId)
      if job then
        job.businessId = businessId
        job.businessType = "tuningShop"
        job.status = "new"
        job.remainingLifetime = parts.garage.getJobExpirySeconds(businessId)
        table.insert(newJobs, job)
      end
    end

    return newJobs
  end

  operations.checkAndNotifyJob = function(businessId, job)
    if not businessId or not job or not job.vehicleConfig or not job.vehicleConfig.model_key then return end

    local notificationList = parts.selections.getNotificationList(businessId)
    if not notificationList or #notificationList == 0 then return end

    local jobModelKey = job.vehicleConfig.model_key
    local matchedEntry = nil

    for _, entry in ipairs(notificationList) do
      if entry.model_key == jobModelKey then
        matchedEntry = entry
        break
      end
    end

    if not matchedEntry then return end

    local modelInfo = parts.persist.getModelInfo(jobModelKey)
    local modelName = modelInfo and modelInfo.name or jobModelKey

    local function fireJobAvailableNotification(title, message, kind)
      local layout = phoneLayout.get()
      if layout and layout.fireNotification then
        layout.fireNotification("tuningShop.jobAvailable", {
          title = title,
          message = message,
          kind = kind or "invite",
          ttl = 8,
          source = "Tuning Shop",
          sound = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" },
        })
      end
    end

    if matchedEntry.autoAccept then
      local jobId = tonumber(job.jobId) or job.jobId
      if jobId then
        local acceptSuccess = parts.settlement.acceptJob(businessId, jobId)
        if acceptSuccess then
          job.autoAccepted = true
          fireJobAvailableNotification("Job Auto-Accepted", modelName, "success")
        else
          fireJobAvailableNotification("Job Available", modelName .. " (auto-accept failed)", "invite")
        end
      end
    else
      fireJobAvailableNotification("Job Available", modelName, "invite")
    end
  end

  -- Refresh timers --------------------------------------------------------------------------------

  local function processJobGeneration(businessId, jobs, accumulatedTime)
    if not jobs.new then
      jobs.new = {}
    end

    local interval = parts.garage.getGenerationIntervalSeconds(businessId)
    if interval <= 0 then return false, accumulatedTime end

    local multiplier = calculateJobGenerationMultiplier(businessId)
    if multiplier <= 0 then return false, accumulatedTime end

    local effectiveInterval = interval / math.max(multiplier, 1e-6)
    local jobsToGenerate = math.floor(accumulatedTime / effectiveInterval)
    if jobsToGenerate <= 0 then return false, 0 end
    local consumedTime = jobsToGenerate * effectiveInterval

    local changed = false
    for _ = 1, jobsToGenerate do
      local job = generateJob(businessId)
      if not job then
        break
      end
      job.businessId = businessId
      job.businessType = "tuningShop"
      job.status = "new"
      job.remainingLifetime = parts.garage.getJobExpirySeconds(businessId)
      table.insert(jobs.new, job)
      changed = true

      operations.checkAndNotifyJob(businessId, job)
    end

    return changed, consumedTime
  end

  local function updateNewJobExpirations(businessId, jobs, dtSim)
    if not jobs.new or dtSim <= 0 then return false end

    local defaultLifetime = parts.garage.getJobExpirySeconds(businessId)
    local changed = false
    for i = #jobs.new, 1, -1 do
      local job = jobs.new[i]
      job.remainingLifetime = (tonumber(job.remainingLifetime) or defaultLifetime) - dtSim
      if job.remainingLifetime <= 0 then
        table.remove(jobs.new, i)
        changed = true
      end
    end

    return changed
  end

  local function refreshJobs(businessId, forced)
    local id = parts.garage.normalizeBusinessId(businessId)
    if not id then return false end

    local jobs = parts.persist.loadBusinessJobs(id)
    local now = shop.totalSimTime
    local lastRefresh = shop.lastJobRefreshTimes[id] or now
    local dt = now - lastRefresh

    local changed = false
    if dt > 0 then
      if updateNewJobExpirations(id, jobs, dt) then
        changed = true
      end
    end

    shop.generationTimers[id] = (shop.generationTimers[id] or 0) + dt
    local genInterval = parts.garage.getGenerationIntervalSeconds(id)

    if shop.generationTimers[id] >= genInterval then
      local generated, consumedTime = processJobGeneration(id, jobs, shop.generationTimers[id])
      if generated then
        changed = true
      end
      shop.generationTimers[id] = math.max(0, shop.generationTimers[id] - (consumedTime or 0))
    end

    shop.lastJobRefreshTimes[id] = now
    if changed then
      parts.views.notifyJobsUpdated(id)
    end
    return changed
  end

  local function getJobsForBusiness(businessId)
    refreshJobs(businessId, true)
    local jobs = parts.persist.loadBusinessJobs(businessId)
    if not jobs.new then
      jobs.new = {}
    end

    parts.proof.ensureActiveJobVehicles(businessId, jobs)

    return {
      active = jobs.active or {},
      new = jobs.new or {}
    }
  end

  -- Public services -----------------------------------------------------------------------------
  return {
    buildBrandConfigsCache = buildBrandConfigsCache,
    calculateJobGenerationMultiplier = calculateJobGenerationMultiplier,
    checkAndNotifyJob = operations.checkAndNotifyJob,
    generateJob = generateJob,
    generateNewJobs = generateNewJobs,
    getAvailableBrands = getAvailableBrands,
    getAvailableRaceTypes = getAvailableRaceTypes,
    getJobsForBusiness = getJobsForBusiness,
    getMaxPulledOutVehicles = getMaxPulledOutVehicles,
    refreshJobs = refreshJobs,
  }
end

return installer
