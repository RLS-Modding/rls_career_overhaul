-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Vehicle eligibility, dealer catalog caches and weighted selection for one shopping instance.
-- Read filters and cache-entry merging, cache construction, weighted draws, then cache invalidation.
local M = {}
local populationSelector = require("overhaul/career/market/vehicleShopping/populationSelector")
local usedVehicleCondition = require("overhaul/lib/market/usedVehicleCondition")
local jsonCatalog = require("overhaul/lib/platform/jsonCatalog")

function M.new(inputs)
  local service = {}
  local dependencies = {}
  local state = inputs.state


  -- Pricing ---------------------------------------------------------------------------------------
  service.getRandomizedPrice = function(price, range)
    local boundedRange = overhaul_career_market_valueCalculator.getVehicleListingPriceRange and
      overhaul_career_market_valueCalculator.getVehicleListingPriceRange(range) or
      {tailLow = 0.70, normalLow = 0.88, normalHigh = 1.12, tailHigh = 1.30}
    local normalLow = boundedRange.normalLow
    local normalHigh = boundedRange.normalHigh

    if isReallyRandom then
      math.randomseed(os.time() + os.clock() * 10000)
      for _ = 1, 3 do
        math.random()
      end
    end

    local rand = math.random(0, 1000) / 1000
    if rand < 0 then
      rand = 0
    end
    if rand > 1 then
      rand = 1
    end

    local multiplier
    local priceBand
    if rand <= 0.01 then
      multiplier = boundedRange.tailLow + (normalLow - boundedRange.tailLow) * (rand / 0.01)
      priceBand = "lowTail"
    elseif rand <= 0.99 then
      multiplier = normalLow + (normalHigh - normalLow) * ((rand - 0.01) / 0.98)
      priceBand = "normal"
    else
      multiplier = normalHigh + (boundedRange.tailHigh - normalHigh) * ((rand - 0.99) / 0.01)
      priceBand = "highTail"
    end

    local finalPriceInt = math.floor(multiplier * price + 0.5)
    return math.max(finalPriceInt, 500), priceBand, multiplier
  end

  -- Filtering -------------------------------------------------------------------------------------
  service.doesVehiclePassFiltersList = function(vehicleInfo, filters)
    if type(vehicleInfo) ~= "table" or type(filters) ~= "table" then
      return false
    end

    for filterName, parameters in pairs(filters) do
      if filterName == "Years" then
        local vehicleYears = dependencies.validation.safeYearsRange(vehicleInfo)
        if not vehicleYears then
          return false
        end
        local minYear = parameters.min ~= nil and tonumber(parameters.min) or nil
        local maxYear = parameters.max ~= nil and tonumber(parameters.max) or nil
        if (parameters.min ~= nil and not minYear) or (parameters.max ~= nil and not maxYear) then
          return false
        end
        if (minYear and vehicleYears.max < minYear) or (maxYear and vehicleYears.min > maxYear) then
          return false
        end
      elseif filterName ~= "Mileage" then
        if type(parameters) == "table" and (parameters.min ~= nil or parameters.max ~= nil) then
          local value = dependencies.validation.safeNumericAttribute(vehicleInfo, filterName)
          if not value or type(value) ~= "number" then
            return false
          end
          local minValue = parameters.min ~= nil and tonumber(parameters.min) or nil
          local maxValue = parameters.max ~= nil and tonumber(parameters.max) or nil
          if (parameters.min ~= nil and not minValue) or (parameters.max ~= nil and not maxValue) then
            return false
          end
          if (minValue and value < minValue) or (maxValue and value > maxValue) then
            return false
          end
        else
          if type(parameters) ~= "table" then
            return false
          end

          -- Facility-editor empty filters mean no constraint.
          if next(parameters) ~= nil then
            local passed = false
            local aggregateValue = type(vehicleInfo.aggregates) == "table" and vehicleInfo.aggregates[filterName] or nil
            for _, value in ipairs(parameters) do
              if vehicleInfo[filterName] == value or (type(aggregateValue) == "table" and aggregateValue[value]) then
                passed = true
                break
              end
            end
            if not passed then
              return false
            end
          end
        end
      end
    end
    return true
  end

  service.doesVehiclePassFilter = function(vehicleInfo, filter)
    if type(filter) ~= "table" then
      return false
    end
    if filter.whiteList and not service.doesVehiclePassFiltersList(vehicleInfo, filter.whiteList) then
      return false
    end
    local blacklist = filter.blackList
    if type(blacklist) == "table" and type(blacklist.model_key) == "table" then
      local modelKey = string.lower(tostring(vehicleInfo.model_key or vehicleInfo.model or ""))
      for _, excluded in ipairs(blacklist.model_key) do
        if modelKey == string.lower(tostring(excluded)) then return false end
      end
      blacklist = {}
      for key, value in pairs(filter.blackList) do
        if key ~= "model_key" then blacklist[key] = value end
      end
      if not next(blacklist) then blacklist = nil end
    end
    if blacklist and service.doesVehiclePassFiltersList(vehicleInfo, blacklist) then
      return false
    end
    return true
  end

  -- Merge overlapping filters into one config while retaining combined odds and attribute filters.
  function service.addVehicleToDealerCache(cache, cacheIndexByConfig, vehicleInfo)
    local configKey = dependencies.validation.getVehicleConfigTrackingKey(vehicleInfo)
    local probability = math.max(0, tonumber(vehicleInfo.subFilterProbability) or 1)
    local matchingFilter = {
      filter = vehicleInfo.precomputedFilter,
      probability = probability,
      selectionIndex = vehicleInfo.precomputedFilter and vehicleInfo.precomputedFilter._selectionIndex or 1
    }
    local existingIndex = cacheIndexByConfig[configKey]

    if existingIndex then
      local existing = cache[existingIndex]
      existing.subFilterProbability = (tonumber(existing.subFilterProbability) or 0) + probability
      existing.precomputedFilters = existing.precomputedFilters or {}
      table.insert(existing.precomputedFilters, matchingFilter)
      return false
    end

    vehicleInfo.subFilterProbability = probability
    vehicleInfo.precomputedFilters = {matchingFilter}
    table.insert(cache, vehicleInfo)
    cacheIndexByConfig[configKey] = #cache
    return true
  end

  function service.choosePrecomputedFilter(vehicleInfo)
    local filters = vehicleInfo and vehicleInfo.precomputedFilters
    if type(filters) ~= "table" or tableIsEmpty(filters) then
      return vehicleInfo and vehicleInfo.precomputedFilter or nil
    end

    -- Retain attributes from the sub-filter already selected by the stock lottery.
    if vehicleInfo.selectedSubFilterIndex then
      for _, entry in ipairs(filters) do
        local selectionIndex = entry.selectionIndex or (entry.filter and entry.filter._selectionIndex) or 1
        if selectionIndex == vehicleInfo.selectedSubFilterIndex then
          return entry.filter
        end
      end
    end

    local totalWeight = 0
    for _, entry in ipairs(filters) do
      totalWeight = totalWeight + math.max(0, tonumber(entry.probability) or 1)
    end
    if totalWeight <= 0 then
      return filters[math.random(#filters)].filter
    end

    local cursor = math.random() * totalWeight
    local accumulated = 0
    for _, entry in ipairs(filters) do
      accumulated = accumulated + math.max(0, tonumber(entry.probability) or 1)
      if accumulated >= cursor then
        return entry.filter
      end
    end
    return filters[#filters].filter
  end

  function service.dealerPolicyValid(dealer)
    if dealer.selectionPolicy == nil then return true end
    if dealer.selectionPolicy ~= 'prestige' then
      log('W', 'vehicleShopping', 'Unknown selection policy for ' .. tostring(dealer.id))
      return false
    end
    local options = dealer.selectionPolicyOptions or {}
    if type(options) ~= 'table' then return false end
    for key, value in pairs(options) do
      if not jsonCatalog.finite(value) or value < 0 then
        log('W', 'vehicleShopping', 'Invalid selection option ' .. tostring(key) .. ' for ' .. tostring(dealer.id))
        return false
      end
    end
    if options.maxTopTrims and (options.maxTopTrims < 1 or options.maxTopTrims % 1 ~= 0) then return false end
    if options.topTrimFraction and (options.topTrimFraction <= 0 or options.topTrimFraction > 1) then return false end
    return true
  end

  -- Dealer catalogs --------------------------------------------------------------------------------
  -- Repeat the organization lookup to preserve the observable call order.
  -- An explicit false keeps authored stock rules; organization pricing/access still apply.
  -- Absent preserves the source organization stock behavior for existing dealerships.
  local function resolveDealershipFilters(dealership)
    local filter = dealership.filter or {}
    if dealership.associatedOrganization and dealership.useOrganizationStockFilters ~= false then
      local org = overhaul_world_organizations.getOrganization(dealership.associatedOrganization)
      local level = dependencies.getOrgLevelData(org)
      if level and level.filter then
        filter = deepcopy(filter)
        tableMergeRecursive(filter, level.filter)
      end
    end

    local subFilters = dealership.subFilters or {}
    if dealership.associatedOrganization and dealership.useOrganizationStockFilters ~= false then
      local org = overhaul_world_organizations.getOrganization(dealership.associatedOrganization)
      local level = dependencies.getOrgLevelData(org)
      if level and level.subFilters then
        subFilters = level.subFilters
      end
    end
    if dealership.selectionPolicy == "prestige" then
      -- Prestige eligibility follows value and halo across model years; reputation affects stock and terms.
      subFilters = {}
    end
    return filter, subFilters
  end

  -- The selection index lets a stock draw keep the sub-filter it already picked (see choosePrecomputedFilter).
  local function buildDealershipAggregateFilters(baseFilter, subFilters)
    local filters = {}
    if subFilters and not tableIsEmpty(subFilters) then
      for selectionIndex, subFilter in ipairs(subFilters) do
        local aggregateFilter = deepcopy(baseFilter or {})
        tableMergeRecursive(aggregateFilter, subFilter)
        aggregateFilter._probability = (type(subFilter.probability) == "number" and subFilter.probability) or 1
        aggregateFilter._selectionIndex = selectionIndex
        table.insert(filters, aggregateFilter)
      end
    else
      local aggregateFilter = deepcopy(baseFilter or {})
      aggregateFilter._probability = 1
      aggregateFilter._selectionIndex = 1
      table.insert(filters, aggregateFilter)
    end
    return filters
  end

  -- Quarantine a bad config so filtering or normalization cannot abort the whole dealership build.
  local function buildDealershipCacheCandidate(dealership, filter, subProbability, vehicleInfo, prestigeTopTrimLookup, context)
    return dependencies.validation.safeVehicleOp(context, vehicleInfo, function()
      if not service.doesVehiclePassFilter(vehicleInfo, filter) then
        return false
      end

      local cacheEntry = dependencies.validation.copyCatalogEntry(vehicleInfo)
      cacheEntry.precomputedFilter = filter
      cacheEntry.subFilterProbability = subProbability
      dependencies.validation.normalizeVehicleCatalogValue(cacheEntry, context)
      if dealership.selectionPolicy == "prestige" then
        local qualifies, reason, topTrimData =
          dependencies.validation.isPrestigeVehicle(cacheEntry, prestigeTopTrimLookup, dealership.selectionPolicyOptions)
        if not qualifies then return false end
        cacheEntry.prestigeSelectionReason = reason
        cacheEntry.prestigeTopTrimData = topTrimData
      end
      return cacheEntry
    end)
  end

  local function sellerConditionPolicyValid(seller)
    local valid, reason = usedVehicleCondition.validateSellerPolicy(seller)
    if not valid then
      log('W', 'vehicleShopping', 'Skipping seller ' .. tostring(seller.id) .. ': ' .. reason)
    end
    return valid
  end

  -- The full build and the single-dealership rebuild share this so their filter, quarantine and drop rules cannot drift apart.
  local function collectDealershipCacheVehicles(dealership, filters, regularEligibleVehicles, prestigeTopTrimLookup, context)
    local filteredRegular = {}
    if not sellerConditionPolicyValid(dealership) then return filteredRegular, 0, 0, true end
    if not service.dealerPolicyValid(dealership) then return filteredRegular, 0, 0 end
    local filteredRegularByConfig = {}
    local droppedForDealership = 0
    local addedCount = 0
    for _, filter in ipairs(filters) do
      local subProbability = filter._probability or filter.probability or 1
      for _, vehicleInfo in ipairs(regularEligibleVehicles) do
        if not dependencies.validation.isQuarantined(vehicleInfo) then
          local cachedVehicle, err = buildDealershipCacheCandidate(dealership, filter, subProbability, vehicleInfo,
            prestigeTopTrimLookup, context)
          if err then
            droppedForDealership = droppedForDealership + 1
            dependencies.validation.incrementValidationStat("cacheDropped")
          elseif cachedVehicle and service.addVehicleToDealerCache(filteredRegular, filteredRegularByConfig, cachedVehicle) then
            addedCount = addedCount + 1
          end
        end
      end
    end
    return filteredRegular, droppedForDealership, addedCount
  end

  local function prepareDealershipCache()
    state.vehicleCache.cacheValid = false
    state.vehicleCache.dealershipCache = {}
    local totalPartsCalculated = 0

    local rawEligibleVehicles = util_configListGenerator.getEligibleVehicles() or {}
    local regularEligibleVehicles, eligibleSummary = dependencies.validation.sanitizeVehicleInfoList(rawEligibleVehicles, "cacheDealers",
      "cacheDropped")
    dependencies.validation.logVehicleSanitizationSummary("cacheDealers eligible vehicles", eligibleSummary)
    state.vehicleCache.regularVehicles = regularEligibleVehicles
    local facilities = overhaul_world_facilities.getFacilities(getCurrentLevelIdentifier())

    if facilities and facilities.dealerships then
      for _, dealership in ipairs(facilities.dealerships) do
        local dealershipId = dealership.id
        local prestigeTopTrimLookup = dealership.selectionPolicy == 'prestige' and service.dealerPolicyValid(dealership)
          and dependencies.validation.buildPrestigeTopTrimLookup(regularEligibleVehicles, dealership.selectionPolicyOptions) or {}
        local filter, subFilters = resolveDealershipFilters(dealership)
        local filters = buildDealershipAggregateFilters(filter, subFilters)
        local filteredRegular, droppedForDealership, addedCount, conditionPolicyUnavailable =
          collectDealershipCacheVehicles(dealership, filters, regularEligibleVehicles, prestigeTopTrimLookup, "cacheDealers")
        totalPartsCalculated = totalPartsCalculated + addedCount

        state.vehicleCache.dealershipCache[dealershipId] = state.vehicleCache.dealershipCache[dealershipId] or {}
        if tableIsEmpty(filteredRegular) then
          log("W", "Career", string.format("Dealership not configured: %s (kept=0 dropped=%d)", dealershipId,
            droppedForDealership))
          state.vehicleCache.dealershipCache[dealershipId].notConfigured = true
        end
        state.vehicleCache.dealershipCache[dealershipId].conditionPolicyUnavailable = conditionPolicyUnavailable
        state.vehicleCache.dealershipCache[dealershipId].regularVehicles = filteredRegular
        state.vehicleCache.dealershipCache[dealershipId].selectionPolicy = dealership.selectionPolicy
        state.vehicleCache.dealershipCache[dealershipId].filters = filters
        service.buildPopulationSelector(state.vehicleCache.dealershipCache[dealershipId])

        log("I", "Career", string.format("cacheDealers dealership %s: kept=%d dropped=%d",
          tostring(dealershipId), #filteredRegular, droppedForDealership))
      end
    end
    return totalPartsCalculated, regularEligibleVehicles, eligibleSummary, facilities
  end

  service.cacheDealers = function()
    local startTime = os.clock()
    local totalPartsCalculated, regularEligibleVehicles, eligibleSummary, facilities = prepareDealershipCache()

    local privateVehicles = {}
    local privateVehiclesByConfig = {}
    local privateDropped = 0
    local privateSeller = facilities and facilities.privateSellers and facilities.privateSellers[1] or nil
    local privateBaseFilter = privateSeller and privateSeller.filter or {}
    local privateSubFilters = privateSeller and privateSeller.subFilters or {}
    local privateFilters = {}
    if privateSubFilters and not tableIsEmpty(privateSubFilters) then
      for selectionIndex, subFilter in ipairs(privateSubFilters) do
        local aggregateFilter = deepcopy(privateBaseFilter)
        tableMergeRecursive(aggregateFilter, subFilter)
        aggregateFilter._probability = tonumber(subFilter.probability) or 1
        aggregateFilter._selectionIndex = selectionIndex
        table.insert(privateFilters, aggregateFilter)
      end
    else
      local aggregateFilter = deepcopy(privateBaseFilter)
      aggregateFilter._probability = 1
      aggregateFilter._selectionIndex = 1
      table.insert(privateFilters, aggregateFilter)
    end

    local conditionPolicyUnavailable = privateSeller and not sellerConditionPolicyValid(privateSeller) or false
    for _, privateFilter in ipairs(conditionPolicyUnavailable and {} or privateFilters) do
      for _, sourceVehicle in ipairs(regularEligibleVehicles) do
        local cachedVehicle, err = dependencies.validation.safeVehicleOp("cacheDealers:private", sourceVehicle, function()
          if not service.doesVehiclePassFilter(sourceVehicle, privateFilter) then return false end
          local vehicleInfo = dependencies.validation.copyCatalogEntry(sourceVehicle)
          dependencies.validation.normalizeVehicleCatalogValue(vehicleInfo, "cacheDealers:private")
          vehicleInfo.precomputedFilter = privateFilter
          vehicleInfo.subFilterProbability = privateFilter._probability or 1
          return vehicleInfo
        end)
        if err then
          privateDropped = privateDropped + 1
          dependencies.validation.incrementValidationStat("cacheDropped")
        elseif cachedVehicle then
          service.addVehicleToDealerCache(privateVehicles, privateVehiclesByConfig, cachedVehicle)
        end
      end
    end
    totalPartsCalculated = totalPartsCalculated + #privateVehicles

    state.vehicleCache.dealershipCache["private"] = {
      regularVehicles = privateVehicles,
      conditionPolicyUnavailable = conditionPolicyUnavailable,
      filters = privateFilters
    }
    service.buildPopulationSelector(state.vehicleCache.dealershipCache["private"])
    if tableIsEmpty(privateVehicles) then
      state.vehicleCache.dealershipCache["private"].notConfigured = true
    end

    if overhaul_career_market_valueCalculator.saveCatalogCache then
      overhaul_career_market_valueCalculator.saveCatalogCache()
    end
    state.vehicleCache.lastCacheTime = os.time()
    state.vehicleCache.map = getCurrentLevelIdentifier()
    state.vehicleCache.cacheValid = true
    log("I", "Career", string.format(
      "cacheDealers complete: raw=%d kept=%d malformed=%d quarantined=%d privateKept=%d privateDropped=%d partsCalculated=%d time=%.3fs",
      eligibleSummary.raw, eligibleSummary.kept, eligibleSummary.malformed, eligibleSummary.quarantined,
      #privateVehicles, privateDropped, totalPartsCalculated, os.clock() - startTime))
  end

  service.careerStockPopulationWeight = function(value)
    -- Zero traffic population still gets a career stock chance without changing seller odds.
    if tonumber(value) == 0 then return 50 end
    return populationSelector.populationWeight(value)
  end

  service.buildPopulationSelector = function(dealershipData)
    dealershipData.populationSelector = populationSelector.build(dealershipData.regularVehicles or {},
      dependencies.validation.getVehicleConfigTrackingKey, service.careerStockPopulationWeight)
  end

  service.prepareVehicleCache = function()
    local currentMap = getCurrentLevelIdentifier()
    if currentMap and (not state.vehicleCache.cacheValid or state.vehicleCache.map ~= currentMap) then
      service.cacheDealers()
    end
  end

  service.getRandomVehicleFromCache = function(sellerId, count, excludedConfigKeys, modelLimit, stockedModels)
    if (tonumber(count) or 0) <= 0 then return {} end
    if not state.vehicleCache.cacheValid then
      log("W", "Career", "Vehicle cache invalid, rebuilding...")
      service.cacheDealers()
    end
    local dealershipData = state.vehicleCache.dealershipCache[sellerId]
    if not dealershipData then
      log("W", "Career", "No cached data for seller: " .. tostring(sellerId))
      return {}
    end
    if not dealershipData.populationSelector then service.buildPopulationSelector(dealershipData) end

    -- Validate selected entries only because catalog construction already checked the full pool.
    local selected = populationSelector.draw(dealershipData.populationSelector, count, excludedConfigKeys,
      function(vehicle)
        if dependencies.validation.isQuarantined(vehicle) then return false end
        local ok, reason = dependencies.validation.isValidVehicleInfoShape(vehicle)
        if not ok then
          dependencies.validation.quarantineVehicleConfig(vehicle, reason, "getRandomVehicleFromCache")
          dependencies.validation.incrementValidationStat("cacheDropped")
        end
        return ok
      end, dealershipData.selectionPolicy == "prestige", nil, modelLimit, stockedModels)
    local vehicles = {}
    for _, entry in ipairs(selected) do
      local vehicle = deepcopy(entry.vehicle)
      vehicle.selectedSubFilterIndex = entry.selectionIndex
      table.insert(vehicles, vehicle)
    end
    return vehicles
  end

  service.invalidateVehicleCache = function()
    state.vehicleCache.cacheValid = false
    state.vehicleCache.regularVehicles = {}
    state.vehicleCache.dealershipCache = {}
    state.vehicleCache.map = nil
    -- Also runs while the overhaul is being disabled, after career modules are unloaded.
    if overhaul_career_market_valueCalculator then overhaul_career_market_valueCalculator.clearVehiclePcPartsCatalogSumCache() end
    dependencies.validation.resetVehicleValidationState()
  end

  service.rebuildDealershipCache = function(dealershipId)
    if not state.vehicleCache.cacheValid then
      service.cacheDealers()
      return
    end

    local facilities = overhaul_world_facilities.getFacilities(getCurrentLevelIdentifier())
    if not facilities or not facilities.dealerships then
      return
    end

    local dealership = nil
    for _, d in ipairs(facilities.dealerships) do
      if d.id == dealershipId then
        dealership = d
        break
      end
    end

    if not dealership then
      return
    end

    local regularEligibleVehicles, eligibleSummary = dependencies.validation.sanitizeVehicleInfoList(state.vehicleCache.regularVehicles or {},
      "rebuildDealershipCache:cachedEligible", "cacheDropped")
    if eligibleSummary.raw > 0 then
      state.vehicleCache.regularVehicles = regularEligibleVehicles
    end
    if not regularEligibleVehicles or tableIsEmpty(regularEligibleVehicles) then
      local rawEligibleVehicles = util_configListGenerator.getEligibleVehicles() or {}
      regularEligibleVehicles, eligibleSummary = dependencies.validation.sanitizeVehicleInfoList(rawEligibleVehicles, "rebuildDealershipCache",
        "cacheDropped")
      dependencies.validation.logVehicleSanitizationSummary("rebuildDealershipCache eligible vehicles", eligibleSummary)
      state.vehicleCache.regularVehicles = regularEligibleVehicles
    end
    local prestigeTopTrimLookup = dealership.selectionPolicy == 'prestige' and service.dealerPolicyValid(dealership)
      and dependencies.validation.buildPrestigeTopTrimLookup(regularEligibleVehicles, dealership.selectionPolicyOptions) or {}

    local filter, subFilters = resolveDealershipFilters(dealership)
    local filters = buildDealershipAggregateFilters(filter, subFilters)
    local filteredRegular, droppedForDealership, _, conditionPolicyUnavailable = collectDealershipCacheVehicles(dealership, filters,
      regularEligibleVehicles, prestigeTopTrimLookup, "rebuildDealershipCache")

    local notConfigured = tableIsEmpty(filteredRegular)
    if notConfigured then
      log("W", "Career", string.format("Dealership not configured: %s (kept=0 dropped=%d)", dealershipId,
        droppedForDealership))
    end

    state.vehicleCache.dealershipCache[dealershipId] = {
      regularVehicles = filteredRegular,
      conditionPolicyUnavailable = conditionPolicyUnavailable,
      selectionPolicy = dealership.selectionPolicy,
      filters = filters,
      notConfigured = notConfigured
    }
    service.buildPopulationSelector(state.vehicleCache.dealershipCache[dealershipId])

    log("I", "Career", string.format(
      "Rebuilt cache for dealership %s: kept=%d dropped=%d rawEligible=%d validEligible=%d malformed=%d quarantined=%d",
      dealershipId, #filteredRegular, droppedForDealership, eligibleSummary.raw, eligibleSummary.kept,
      eligibleSummary.malformed, eligibleSummary.quarantined))
  end

  function service.bindServices(bindings)
    assert(type(bindings.getOrgLevelData) == "function", "catalog requires getOrgLevelData")
    assert(type(bindings.validation.buildPrestigeTopTrimLookup) == "function", "catalog requires validation.buildPrestigeTopTrimLookup")
    assert(type(bindings.validation.copyCatalogEntry) == "function", "catalog requires validation.copyCatalogEntry")
    assert(type(bindings.validation.getVehicleConfigTrackingKey) == "function", "catalog requires validation.getVehicleConfigTrackingKey")
    assert(type(bindings.validation.incrementValidationStat) == "function", "catalog requires validation.incrementValidationStat")
    assert(type(bindings.validation.isQuarantined) == "function", "catalog requires validation.isQuarantined")
    assert(type(bindings.validation.isPrestigeVehicle) == "function", "catalog requires validation.isPrestigeVehicle")
    assert(type(bindings.validation.isValidVehicleInfoShape) == "function", "catalog requires validation.isValidVehicleInfoShape")
    assert(type(bindings.validation.logVehicleSanitizationSummary) == "function", "catalog requires validation.logVehicleSanitizationSummary")
    assert(type(bindings.validation.normalizeVehicleCatalogValue) == "function", "catalog requires validation.normalizeVehicleCatalogValue")
    assert(type(bindings.validation.quarantineVehicleConfig) == "function", "catalog requires validation.quarantineVehicleConfig")
    assert(type(bindings.validation.resetVehicleValidationState) == "function", "catalog requires validation.resetVehicleValidationState")
    assert(type(bindings.validation.safeNumericAttribute) == "function", "catalog requires validation.safeNumericAttribute")
    assert(type(bindings.validation.safeVehicleOp) == "function", "catalog requires validation.safeVehicleOp")
    assert(type(bindings.validation.safeYearsRange) == "function", "catalog requires validation.safeYearsRange")
    assert(type(bindings.validation.sanitizeVehicleInfoList) == "function", "catalog requires validation.sanitizeVehicleInfoList")
    dependencies = bindings
  end
  return service
end

return M
