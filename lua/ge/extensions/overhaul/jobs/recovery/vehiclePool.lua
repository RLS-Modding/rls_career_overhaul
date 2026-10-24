-- Recovery vehicle eligibility, weighted selection and condition rolls.
-- Caches belong to one extension load; remembered spawn failures prevent repeated broken offers.
return function(LOG_TAG, constants)
  local skillLookup = require("overhaul/lib/progression/skillLookup")
  local filterCache
  local filterByTag

  local unspawnableConfigs = {}

  local function getSkillLevel()
    local level = skillLookup.levelMaxPathOrValue(constants.SKILL_ATTRIBUTE, constants.SKILL_PATHS)
    return math.min(50, math.max(1, math.floor(level)))
  end

  local function getPayoutBonus(level)
    local clampedLevel = math.max(1, math.min(50, math.floor(tonumber(level) or 1)))
    -- Level 5 unlocks the activity without also granting its first payout step. The 22 odd-level rewards from 7 through 49 still reach the +200% cap.
    local rewardCount = math.max(0, math.min(22, math.floor((clampedLevel - 5) / 2)))
    local progress = rewardCount / 22
    return 2 * progress * progress
  end

  local function loadFilters()
    if filterCache then return filterCache, filterByTag end
    filterCache, filterByTag = {}, {}
    for id, raw in pairs(jsonReadFile(constants.FILTERS_FILE) or {}) do
      if type(raw) == "table" and raw.type == "vehicle" then
        local item = deepcopy(raw)
        item.id = id
        item.unlockTag = item.unlockTag or id
        item.skillUnlockLevel = tonumber(item.skillUnlockLevel) or 50
        item.payMultiplier = tonumber(item.payMultiplier) or 1
        item.baseXp = tonumber(item.baseXp) or 0
        item.priority = tonumber(item.priority) or 0
        item.tierLabel = item.tierLabel or item.filterName or item.unlockTag
        filterCache[#filterCache + 1] = item
        filterByTag[item.unlockTag] = item
      end
    end
    table.sort(filterCache, function(a, b)
      if a.priority ~= b.priority then return a.priority > b.priority end
      return tostring(a.id) < tostring(b.id)
    end)
    return filterCache, filterByTag
  end

  local function rangeValue(vehicleInfo, key)
    local direct = tonumber(vehicleInfo and vehicleInfo[key])
    if direct then return direct end
    local aggregate = vehicleInfo and type(vehicleInfo.aggregates) == "table" and vehicleInfo.aggregates[key]
    if type(aggregate) == "table" then return tonumber(aggregate.min) end
  end

  local function matchesFiltersList(vehicleInfo, filters)
    if type(vehicleInfo) ~= "table" or type(filters) ~= "table" then return false end
    for key, expected in pairs(filters) do
      if type(expected) == "table" and (expected.min ~= nil or expected.max ~= nil) then
        local value = rangeValue(vehicleInfo, key)
        if not value then return false end
        if expected.min ~= nil and value < (tonumber(expected.min) or math.huge) then return false end
        if expected.max ~= nil and value > (tonumber(expected.max) or -math.huge) then return false end
      else
        if type(expected) ~= "table" then return false end
        local aggregate = type(vehicleInfo.aggregates) == "table" and vehicleInfo.aggregates[key]
        local matched = false
        for _, option in ipairs(expected) do
          if vehicleInfo[key] == option or (type(aggregate) == "table" and aggregate[option]) then
            matched = true
            break
          end
        end
        if not matched then return false end
      end
    end
    return true
  end

  local function matchesFilter(vehicleInfo, filter)
    if type(filter) ~= "table" then return false end
    if filter.whiteList and not matchesFiltersList(vehicleInfo, filter.whiteList) then return false end
    if filter.blackList and matchesFiltersList(vehicleInfo, filter.blackList) then return false end
    return true
  end

  local function matchesFilterConfig(vehicleInfo, config)
    local base = config.filter or {}
    if not matchesFilter(vehicleInfo, base) then return false end
    if type(config.subFilters) ~= "table" or tableIsEmpty(config.subFilters) then return true end
    for _, subFilter in ipairs(config.subFilters) do
      local merged = deepcopy(base)
      tableMergeRecursive(merged, subFilter)
      if matchesFilter(vehicleInfo, merged) then return true end
    end
    return false
  end

  local function appendMetadataStrings(value, output, depth)
    if depth > 3 then return end
    if type(value) == "string" then
      output[#output + 1] = value:lower()
    elseif type(value) == "table" then
      for key, child in pairs(value) do
        if type(key) == "string" then output[#output + 1] = key:lower() end
        appendMetadataStrings(child, output, depth + 1)
      end
    end
  end

  local function isElectricOrHybrid(vehicleInfo)
    local values = {}
    for _, key in ipairs({"Fuel Type", "FuelType", "fuelType", "Powertrain", "Propulsion"}) do
      appendMetadataStrings(vehicleInfo and vehicleInfo[key], values, 0)
      appendMetadataStrings(vehicleInfo and vehicleInfo.aggregates and vehicleInfo.aggregates[key], values, 0)
    end
    local text = table.concat(values, " ")
    return text:find("electric", 1, true) ~= nil or text:find("hybrid", 1, true) ~= nil
  end

  local MISSION_STARTING_CONFIG_TYPES = {
    roleplay = true,
    police = true
  }

  local function configTypeStartsMissions(vehicleInfo)
    if type(vehicleInfo) ~= "table" then return false end
    local values = {}
    appendMetadataStrings(vehicleInfo["Config Type"], values, 0)
    appendMetadataStrings(vehicleInfo.configType, values, 0)
    appendMetadataStrings(vehicleInfo.aggregates and vehicleInfo.aggregates["Config Type"], values, 0)
    for _, text in ipairs(values) do
      if MISSION_STARTING_CONFIG_TYPES[text] then return true end
    end
    return false
  end

  local function filterUnlocked(filter, level)
    if level >= (filter.skillUnlockLevel or 50) then return true end
    local flag = filter.skillUnlockFlag
    return flag and overhaul_career_career.isActive() and overhaul_career_progression_unlockFlags.getFlag(flag) == true
  end

  local function safeBoundingBoxDimensions(vehicleInfo)
    local box = type(vehicleInfo) == "table" and vehicleInfo.BoundingBox
    local dimensions = type(box) == "table" and box[2]
    if type(dimensions) ~= "table" then return nil end
    local x, y, z = tonumber(dimensions[1]), tonumber(dimensions[2]), tonumber(dimensions[3])
    if not x or not y or not z then return nil end
    return x, y, z
  end

  local function vehicleFitsSpot(vehicleInfo, spot)
    local x, y, z = safeBoundingBoxDimensions(vehicleInfo)
    if not x then return true end
    if spot and spot.boxFits then
      local ok, fits = pcall(function() return spot:boxFits(x, y, z) end)
      if ok then return fits == true end
    end
    local scale = spot and spot.scl
    if not scale then return true end
    return x <= (tonumber(scale.x) or tonumber(scale[1]) or x) * 0.9
      and y <= (tonumber(scale.y) or tonumber(scale[2]) or y) * 0.9
      and z <= (tonumber(scale.z) or tonumber(scale[3]) or z) * 0.9
  end

  local function configPopulation(vehicleInfo)
    return math.max(tonumber(vehicleInfo and vehicleInfo.adjustedPopulation) or tonumber(vehicleInfo and vehicleInfo.Population) or 1, 0)
  end

  local function chooseWeighted(candidates)
    if #candidates == 0 then return nil end

    local byModel = {}
    local modelKeys = {}
    for _, candidate in ipairs(candidates) do
      local modelKey = candidate.model_key or candidate.model or candidate.key or "_"
      local bucket = byModel[modelKey]
      if not bucket then
        bucket = {}
        byModel[modelKey] = bucket
        modelKeys[#modelKeys + 1] = modelKey
      end
      bucket[#bucket + 1] = candidate
    end

    local configs = byModel[modelKeys[math.random(#modelKeys)]]
    if #configs == 1 then return configs[1] end

    local total = 0
    for _, candidate in ipairs(configs) do
      candidate._recoveryWeight = configPopulation(candidate)
      total = total + candidate._recoveryWeight
    end
    if total <= 0 then return configs[math.random(#configs)] end
    local roll, running = math.random() * total, 0
    for _, candidate in ipairs(configs) do
      running = running + candidate._recoveryWeight
      if running >= roll then return candidate end
    end
    return configs[#configs]
  end

  local function isTrailerInfo(vehicleInfo)
    local vehicleType = tostring(vehicleInfo and vehicleInfo.Type or ""):lower()
    return vehicleType == "trailer" or tostring(vehicleInfo and vehicleInfo.recoveryTag or "") == "recoveryTrailer"
  end

  local function rollCondition(vehicleInfo)
    if isTrailerInfo(vehicleInfo) then
      return "complete", 0
    end
    if math.random(100) <= 70 then return "complete", 0 end
    return "brokenEngine", 0
  end

  local function randomMileageMeters(year)
    local currentYear = tonumber(os.date("%Y")) or 2026
    local age = math.max(0, currentYear - (tonumber(year) or currentYear))
    local ageFactor = math.min(1, age / 30)
    local centerMiles = constants.MIN_TARGET_MILEAGE_MI + (constants.MAX_TARGET_MILEAGE_MI - constants.MIN_TARGET_MILEAGE_MI) * ageFactor
    local spreadMiles = 25000
    local minMiles = math.max(constants.MIN_TARGET_MILEAGE_MI, math.floor(centerMiles - spreadMiles))
    local maxMiles = math.min(constants.MAX_TARGET_MILEAGE_MI, math.ceil(centerMiles + spreadMiles))
    local miles = math.random(minMiles, math.max(minMiles, maxMiles))
    return math.floor(miles * constants.METERS_PER_MILE + 0.5)
  end

  local function offerVehicleValue(vehicleInfo)
    local year = tonumber(vehicleInfo.year) or 2023
    local mileage = tonumber(vehicleInfo.Mileage) or 0
    local baseValue = tonumber(vehicleInfo.Value) or 1000
    if overhaul_career_career.isActive() then
      return overhaul_career_market_valueCalculator.getVehicleCatalogIntrinsicBookValue({
        catalogBaseValue = baseValue,
        mileageMeters = mileage,
        age = math.max(0, (tonumber(os.date("%Y")) or 2026) - year),
        modelName = vehicleInfo.model_key,
        configKey = vehicleInfo.key,
        logContext = LOG_TAG,
        applyVehicleBuyMarket = false
      }) or baseValue
    end
    return baseValue
  end

  local function spawnConfigKey(model, config)
    local configId = config
    if type(config) == "table" then
      configId = config.partConfigFilename or config.key
    end
    return tostring(model or "") .. "|" .. tostring(configId or "")
  end

  local function isRememberedUnspawnable(model, config)
    return unspawnableConfigs[spawnConfigKey(model, config)] == true
  end

  local function rememberUnspawnable(model, config)
    if type(model) ~= "string" or model == "" then return end
    unspawnableConfigs[spawnConfigKey(model, config)] = true
  end

  local function resolveConfigPath(model, config)
    if type(config) ~= "string" or config == "" then return nil end
    local vehicleDir = "/vehicles/" .. tostring(model) .. "/"
    local configPath = config
    if not configPath:find("/", 1, true) and not configPath:find("\\", 1, true) then
      configPath = vehicleDir .. configPath
    elseif configPath:sub(1, 1) ~= "/" then
      configPath = "/" .. configPath:gsub("\\", "/")
    end
    if configPath:sub(-3):lower() ~= ".pc" then configPath = configPath .. ".pc" end
    return configPath
  end

  local function targetContentAvailable(model, config)
    if type(model) ~= "string" or model == "" then return false end

    -- Avoid core_vehicles.getModel() here. Its first call builds the complete enabled vehicle cache, while restoring a contract only needs to establish that this particular vehicle is still mounted.
    local vehicleDir = "/vehicles/" .. model .. "/"
    if not FS:directoryExists(vehicleDir) then return false end
    if not FS:fileExists(vehicleDir .. "info.json") then return false end
    -- Add-on part packs can leave a model directory mounted after the base mod is disabled. Only root JBeam files define the actual spawnable model.
    local jbeamFiles = FS:findFiles(vehicleDir, "*.jbeam", 0, false, false)
    if type(jbeamFiles) ~= "table" or #jbeamFiles == 0 then return false end

    -- A saved vehicle snapshot contains the parts needed to rebuild the target; its original .pc may legitimately no longer exist. New jobs still use a catalog config key, so validate that file before asking the engine to spawn.
    if type(config) == "table" then
      if type(config.partsTree) == "table" and next(config.partsTree) ~= nil then return true end
      if type(config.parts) == "table" and next(config.parts) ~= nil then return true end
      config = config.partConfigFilename
    end
    if type(config) ~= "string" or config == "" then return false end

    local configPath = resolveConfigPath(model, config)
    return FS:fileExists(configPath)
  end

  local function candidateCanSpawn(vehicleInfo)
    local model = vehicleInfo and vehicleInfo.model_key
    local config = vehicleInfo and vehicleInfo.key
    if isRememberedUnspawnable(model, config) then return false end
    return targetContentAvailable(model, config)
  end

  local function removeVehicleCandidate(list, vehicleInfo)
    local remaining = {}
    for _, candidate in ipairs(list or {}) do
      if not (candidate.model_key == vehicleInfo.model_key and candidate.key == vehicleInfo.key) then
        remaining[#remaining + 1] = candidate
      end
    end
    return remaining
  end

  return {candidateCanSpawn = candidateCanSpawn, chooseWeighted = chooseWeighted,
      configTypeStartsMissions = configTypeStartsMissions, filterUnlocked = filterUnlocked,
      getPayoutBonus = getPayoutBonus, getSkillLevel = getSkillLevel,
      isElectricOrHybrid = isElectricOrHybrid, isRememberedUnspawnable = isRememberedUnspawnable,
      loadFilters = loadFilters, matchesFilterConfig = matchesFilterConfig,
      offerVehicleValue = offerVehicleValue, randomMileageMeters = randomMileageMeters,
      rememberUnspawnable = rememberUnspawnable, removeVehicleCandidate = removeVehicleCandidate,
      resolveConfigPath = resolveConfigPath, rollCondition = rollCondition,
      targetContentAvailable = targetContentAvailable, vehicleFitsSpot = vehicleFitsSpot}
end
