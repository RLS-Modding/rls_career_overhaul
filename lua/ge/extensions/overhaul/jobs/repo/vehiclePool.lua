-- Filters repo vehicles by dealership and skill unlocks, then selects weighted candidates.
-- Filter caches belong to this factory instance so extension reloads get fresh state.
return function(REPO_FILTERS_FILE, REPO_SKILL_ATTRIBUTE_KEY, REPO_SKILL_MAX_LEVEL, REPO_SKILL_PATH_IDS)
  local skillLookup = require("overhaul/lib/progression/skillLookup")
  local repoVehicleFiltersCache = nil
  local repoVehicleFiltersByTag = nil

  local function loadRepoVehicleFilters()
    if repoVehicleFiltersCache and repoVehicleFiltersByTag then
      return repoVehicleFiltersCache, repoVehicleFiltersByTag
    end
    repoVehicleFiltersCache = {}
    repoVehicleFiltersByTag = {}
    local rawConfig = jsonReadFile(REPO_FILTERS_FILE) or {}
    for id, filterConfig in pairs(rawConfig) do
      if type(filterConfig) == "table" and filterConfig.type == "vehicle" then
        local normalizedConfig = deepcopy(filterConfig)
        normalizedConfig.id = id
        normalizedConfig.unlockTag = normalizedConfig.unlockTag or id
        normalizedConfig.priority = tonumber(normalizedConfig.priority) or 0
        normalizedConfig.skillUnlockLevel = tonumber(normalizedConfig.skillUnlockLevel) or REPO_SKILL_MAX_LEVEL
        normalizedConfig.payMultiplier = tonumber(normalizedConfig.payMultiplier) or 1
        normalizedConfig.baseXp = tonumber(normalizedConfig.baseXp) or 0
        normalizedConfig.tierLabel = normalizedConfig.tierLabel
          or normalizedConfig.filterName
          or normalizedConfig.unlockTag
        repoVehicleFiltersCache[#repoVehicleFiltersCache + 1] = normalizedConfig
        repoVehicleFiltersByTag[normalizedConfig.unlockTag] = normalizedConfig
      end
    end
    table.sort(repoVehicleFiltersCache, function(a, b)
      if a.priority ~= b.priority then return a.priority > b.priority end
      return tostring(a.id) < tostring(b.id)
    end)
    return repoVehicleFiltersCache, repoVehicleFiltersByTag
  end
  local function safeYearsRange(vehicleInfo)
    if type(vehicleInfo) ~= "table" then return nil end
    local function normalizeYears(years)
      if type(years) ~= "table" then return nil end
      local minYear = tonumber(years.min)
      local maxYear = tonumber(years.max)
      if not minYear or not maxYear or minYear > maxYear then return nil end
      return { min = minYear, max = maxYear }
    end
    return normalizeYears(vehicleInfo.Years)
      or normalizeYears(type(vehicleInfo.aggregates) == "table" and vehicleInfo.aggregates.Years or nil)
  end
  local function safeNumericAttribute(vehicleInfo, attributeName)
    if type(vehicleInfo) ~= "table" then return nil end
    local directValue = tonumber(vehicleInfo[attributeName])
    if directValue then return directValue end
    local aggregateValue = type(vehicleInfo.aggregates) == "table" and vehicleInfo.aggregates[attributeName] or nil
    if type(aggregateValue) == "table" then return tonumber(aggregateValue.min) end
    return nil
  end
  local function doesVehiclePassFiltersList(vehicleInfo, filters)
    if type(vehicleInfo) ~= "table" or type(filters) ~= "table" then return false end
    for filterName, parameters in pairs(filters) do
      if filterName == "Years" then
        local vehicleYears = safeYearsRange(vehicleInfo)
        if not vehicleYears then return false end
        local minYear = parameters.min ~= nil and tonumber(parameters.min) or nil
        local maxYear = parameters.max ~= nil and tonumber(parameters.max) or nil
        if (parameters.min ~= nil and not minYear) or (parameters.max ~= nil and not maxYear) then return false end
        if (minYear and vehicleYears.max < minYear) or (maxYear and vehicleYears.min > maxYear) then return false end
      elseif filterName ~= "Mileage" then
        if type(parameters) == "table" and (parameters.min ~= nil or parameters.max ~= nil) then
          local value = safeNumericAttribute(vehicleInfo, filterName)
          if not value or type(value) ~= "number" then return false end
          local minValue = parameters.min ~= nil and tonumber(parameters.min) or nil
          local maxValue = parameters.max ~= nil and tonumber(parameters.max) or nil
          if (parameters.min ~= nil and not minValue) or (parameters.max ~= nil and not maxValue) then return false end
          if (minValue and value < minValue) or (maxValue and value > maxValue) then return false end
        else
          if type(parameters) ~= "table" then return false end
          local passed = false
          local aggregateValue = type(vehicleInfo.aggregates) == "table" and vehicleInfo.aggregates[filterName] or nil
          for _, value in ipairs(parameters) do
            if vehicleInfo[filterName] == value or (type(aggregateValue) == "table" and aggregateValue[value]) then
              passed = true
              break
            end
          end
          if not passed then return false end
        end
      end
    end
    return true
  end
  local function doesVehiclePassFilter(vehicleInfo, filter)
    if type(filter) ~= "table" then return false end
    if filter.whiteList and not doesVehiclePassFiltersList(vehicleInfo, filter.whiteList) then return false end
    if filter.blackList and doesVehiclePassFiltersList(vehicleInfo, filter.blackList) then return false end
    return true
  end
  local function getOrgLevelData(organization, offset)
    if not organization then return nil end
    local repLevel = (organization.reputation and organization.reputation.level) or 0
    if type(repLevel) ~= "number" then repLevel = 0 end
    local levels = organization.reputationLevels
    if not levels then return nil end
    local arrayIndex = repLevel + 2 + (offset or 0)
    if arrayIndex < 1 or arrayIndex > #levels then return nil end
    return levels[arrayIndex]
  end

  local function getRepoTagData(tag)
    local _, filtersByTag = loadRepoVehicleFilters()
    return filtersByTag[tag]
  end
  local function getRepoSkillLevel()
    return math.min(
      skillLookup.levelFirstPathOrValueUncheckedCalc(REPO_SKILL_ATTRIBUTE_KEY, REPO_SKILL_PATH_IDS),
      REPO_SKILL_MAX_LEVEL
    )
  end
  local function getRepoPayoutBonusPercent(level)
    local clampedLevel = math.min(math.max(tonumber(level) or 0, 0), REPO_SKILL_MAX_LEVEL)
    local rewardCount = math.max(0, math.min(24, math.floor(clampedLevel / 2)))
    return 4 * (rewardCount / 24)
  end
  local function isRepoTagUnlocked(tag)
    local tagData = getRepoTagData(tag)
    if not tagData then return false end
    local unlocked = false
    local unlockFlag = tagData.skillUnlockFlag or tagData.unlockFlag
    if overhaul_career_career.isActive() and unlockFlag then
      unlocked = overhaul_career_progression_unlockFlags.getFlag(unlockFlag) == true
    end
    if unlocked then return true end
    return getRepoSkillLevel() >= (tagData.skillUnlockLevel or REPO_SKILL_MAX_LEVEL)
  end
  local function doesVehiclePassRepoFilterConfig(vehicleInfo, filterConfig)
    if type(filterConfig) ~= "table" then return false end
    local baseFilter = filterConfig.filter or {}
    if not doesVehiclePassFilter(vehicleInfo, baseFilter) then return false end
    local subFilters = filterConfig.subFilters
    if type(subFilters) ~= "table" or tableIsEmpty(subFilters) then return true end
    for _, subFilter in ipairs(subFilters) do
      local aggregateFilter = deepcopy(baseFilter)
      if type(subFilter) == "table" then
        tableMergeRecursive(aggregateFilter, subFilter)
        if doesVehiclePassFilter(vehicleInfo, aggregateFilter) then return true end
      end
    end
    return false
  end
  local function getRepoVehicleTag(vehicleInfo)
    local orderedFilters = loadRepoVehicleFilters()
    for _, filterConfig in ipairs(orderedFilters) do
      if doesVehiclePassRepoFilterConfig(vehicleInfo, filterConfig) and isRepoTagUnlocked(filterConfig.unlockTag) then
        return filterConfig.unlockTag
      end
    end
    return nil
  end

  local function buildDealershipFilters(dealership)
    local filter = dealership and dealership.filter or {}
    local subFilters = dealership and dealership.subFilters or {}
    if dealership and dealership.associatedOrganization then
      local organization = overhaul_world_organizations.getOrganization(dealership.associatedOrganization)
      local level = getOrgLevelData(organization)
      if level and level.filter then filter = level.filter end
      if level and level.subFilters then subFilters = level.subFilters end
    end
    local filters = {}
    if subFilters and not tableIsEmpty(subFilters) then
      for _, subFilter in ipairs(subFilters) do
        local aggregateFilter = deepcopy(filter or {})
        tableMergeRecursive(aggregateFilter, subFilter)
        aggregateFilter._probability = (type(subFilter.probability) == "number" and subFilter.probability) or 1
        table.insert(filters, aggregateFilter)
      end
    else
      local aggregateFilter = deepcopy(filter or {})
      aggregateFilter._probability = 1
      table.insert(filters, aggregateFilter)
    end
    return filters
  end
  local function getEligibleRepoVehiclesForDealership(dealership, eligibleVehicles)
    local candidates = {}
    local dealershipFilters = buildDealershipFilters(dealership)
    for _, filterVariant in ipairs(dealershipFilters) do
      local variantProbability = tonumber(filterVariant._probability) or 1
      for _, vehicleInfo in ipairs(eligibleVehicles or {}) do
        if doesVehiclePassFilter(vehicleInfo, filterVariant) then
          local repoTag = getRepoVehicleTag(vehicleInfo)
          local repoTagData = getRepoTagData(repoTag)
          if repoTag and repoTagData and isRepoTagUnlocked(repoTag) then
            local candidate = deepcopy(vehicleInfo)
            candidate.repoTag = repoTag
            candidate.repoTierLabel = repoTagData.tierLabel
            candidate.repoSubFilterProbability = variantProbability
            table.insert(candidates, candidate)
          end
        end
      end
    end
    return candidates
  end

  local function pickWeightedRepoVehicleInfo(candidates)
    if not candidates or #candidates == 0 then return nil end
    local totalWeight = 0
    local weightedCandidates = {}
    for _, vehicleInfo in ipairs(candidates) do
      local weight = tonumber(vehicleInfo.adjustedPopulation) or tonumber(vehicleInfo.Population) or 1
      weight = weight * math.max(tonumber(vehicleInfo.repoSubFilterProbability) or 1, 0)
      if weight > 0 then
        totalWeight = totalWeight + weight
        weightedCandidates[#weightedCandidates + 1] = { vehicleInfo = vehicleInfo, weight = weight }
      end
    end
    if totalWeight <= 0 then return deepcopy(candidates[math.random(#candidates)]) end
    local roll = math.random() * totalWeight
    local runningWeight = 0
    for _, entry in ipairs(weightedCandidates) do
      runningWeight = runningWeight + entry.weight
      if runningWeight >= roll then return deepcopy(entry.vehicleInfo) end
    end
    return deepcopy(weightedCandidates[#weightedCandidates].vehicleInfo)
  end
  local function getRepoStateFields(instance)
    local repoSkillLevel = getRepoSkillLevel()
    return {
      repoTag = instance and instance.repoTag or "",
      repoTierLabel = instance and instance.repoTierLabel or "",
      repoSkillLevel = repoSkillLevel,
      repoPayoutBonusPercent = getRepoPayoutBonusPercent(repoSkillLevel),
    }
  end
  return {
    getEligibleRepoVehiclesForDealership = getEligibleRepoVehiclesForDealership,
    getRepoPayoutBonusPercent = getRepoPayoutBonusPercent,
    getRepoSkillLevel = getRepoSkillLevel,
    getRepoStateFields = getRepoStateFields,
    getRepoTagData = getRepoTagData,
    pickWeightedRepoVehicleInfo = pickWeightedRepoVehicleInfo,
  }
end
