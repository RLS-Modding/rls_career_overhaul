-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Vehicle catalog validation and quarantine for one shopping instance.
-- Read blacklist rules, validation counters and shapes, catalog copying, then saved-listing repair.
local M = {}

function M.new(inputs)
  local service = {}
  local dependencies = {}
  local state = inputs.state
  local shoppingConfig = inputs.config

  local usedVehicleCondition = inputs.usedVehicleCondition

  service.addModelBlacklistToLookup = function(lookup, filter)
    local modelKeys = type(filter) == "table" and type(filter.blackList) == "table" and
      filter.blackList.model_key or nil
    if type(modelKeys) ~= "table" then return end

    for _, modelKey in ipairs(modelKeys) do
      local normalized = string.lower(tostring(modelKey or ""))
      if normalized ~= "" then
        lookup[normalized] = true
      end
    end
  end

  -- Saved offers outlive facility and organization edits, so drop listings the blacklist now forbids.
  service.pruneBlacklistedSellerStock = function(sellers)
    local blacklistedBySeller = {}
    for _, seller in ipairs(sellers or {}) do
      local lookup = {}
      service.addModelBlacklistToLookup(lookup, seller.filter)

      if seller.associatedOrganization then
        local org = overhaul_world_organizations.getOrganization(seller.associatedOrganization)
        local level = dependencies.getOrgLevelData(org)
        if level then
          service.addModelBlacklistToLookup(lookup, level.filter)
        end
      end

      if next(lookup) ~= nil then
        blacklistedBySeller[seller.id] = lookup
      end
    end

    local removed = 0
    for i = #state.vehiclesInShop, 1, -1 do
      local vehicleInfo = state.vehiclesInShop[i]
      local lookup = blacklistedBySeller[vehicleInfo.sellerId]
      local modelKey = string.lower(tostring(vehicleInfo.model_key or vehicleInfo.model or ""))
      if lookup and lookup[modelKey] then
        if vehicleInfo.shopId ~= nil then
          state.vehicleWatchlist[vehicleInfo.shopId] = nil
        end
        table.remove(state.vehiclesInShop, i)
        removed = removed + 1
      end
    end

    if removed > 0 then
      log("I", "Career", string.format("Removed %d dealer listings blocked by current model blacklists", removed))
    end
    return removed
  end

  service.resetVehicleValidationState = function()
    state.badConfigQuarantine = {}
    state.badConfigLogOnce = {}
    state.validationStats = {
      quarantined = 0,
      loadDropped = 0,
      cacheDropped = 0,
      generationDropped = 0
    }
  end

  service.incrementValidationStat = function(statKey, amount)
    if statKey and state.validationStats[statKey] ~= nil then
      state.validationStats[statKey] = state.validationStats[statKey] + (amount or 1)
    end
  end

  service.getVehicleConfigId = function(vehicleInfo)
    if type(vehicleInfo) ~= "table" then
      return nil
    end
    if type(vehicleInfo.model_key) ~= "string" or vehicleInfo.model_key == "" then
      return nil
    end
    if type(vehicleInfo.key) ~= "string" or vehicleInfo.key == "" then
      return nil
    end
    return vehicleInfo.model_key .. "|" .. vehicleInfo.key
  end

  service.getVehicleConfigTrackingKey = function(vehicleInfo)
    local configId = service.getVehicleConfigId(vehicleInfo)
    if configId then
      return configId
    end

    if type(vehicleInfo) ~= "table" then
      return "invalid:" .. tostring(vehicleInfo)
    end

    return string.format("invalid:%s|%s", tostring(vehicleInfo.model_key), tostring(vehicleInfo.key))
  end

  service.quarantineVehicleConfig = function(vehicleInfo, reason, context)
    local configId = service.getVehicleConfigId(vehicleInfo) or service.getVehicleConfigTrackingKey(vehicleInfo)
    if not state.badConfigQuarantine[configId] then
      state.badConfigQuarantine[configId] = true
      state.validationStats.quarantined = state.validationStats.quarantined + 1
    end

    if not state.badConfigLogOnce[configId] then
      state.badConfigLogOnce[configId] = true
      log("W", "Career", string.format("Quarantined vehicle config %s during %s: %s",
        tostring(configId), tostring(context), tostring(reason)))
    end

    return configId
  end

  service.isQuarantined = function(vehicleInfo)
    local trackingKey = service.getVehicleConfigTrackingKey(vehicleInfo)
    return state.badConfigQuarantine[trackingKey] == true
  end

  service.isValidVehicleInfoShape = function(vehicleInfo)
    if type(vehicleInfo) ~= "table" then
      return false, "vehicleInfo is not a table"
    end
    if type(vehicleInfo.model_key) ~= "string" or vehicleInfo.model_key == "" then
      return false, "missing model_key"
    end
    if type(vehicleInfo.key) ~= "string" or vehicleInfo.key == "" then
      return false, "missing key"
    end
    if type(vehicleInfo.Value) ~= "number" then
      local profile = overhaul_career_market_valueCalculator.getVehicleCatalogProfile and
        overhaul_career_market_valueCalculator.getVehicleCatalogProfile(
          vehicleInfo.model_key, vehicleInfo.key, vehicleInfo) or nil
      if profile and tonumber(profile.catalogValue) and profile.catalogValue > 0 then
        vehicleInfo.Value = profile.catalogValue
      else
        return false, "missing numeric Value and no parts-derived catalog"
      end
    end

    if vehicleInfo.aggregates == nil then
      vehicleInfo.aggregates = {}
    elseif type(vehicleInfo.aggregates) ~= "table" then
      return false, "malformed aggregates"
    end

    if type(vehicleInfo.Brand) ~= "string" then
      vehicleInfo.Brand = ""
    end
    if type(vehicleInfo.Name) ~= "string" then
      vehicleInfo.Name = ""
    end

    return true
  end

  service.safeYearsRange = usedVehicleCondition.safeYearsRange

  service.safeNumericAttribute = function(vehicleInfo, attrName)
    if type(vehicleInfo) ~= "table" then
      return nil
    end

    local directValue = tonumber(vehicleInfo[attrName])
    if directValue then
      return directValue
    end

    local aggregateValue = type(vehicleInfo.aggregates) == "table" and vehicleInfo.aggregates[attrName] or nil
    if type(aggregateValue) == "table" then
      return tonumber(aggregateValue.min)
    end

    return nil
  end

  service.normalizeVehicleCatalogValue = function(vehicleInfo, logContext)
    if type(vehicleInfo) ~= "table" then
      return false
    end

    local rawCatalogValue = tonumber(vehicleInfo.rawCatalogValue)
    if rawCatalogValue == nil then
      rawCatalogValue = tonumber(vehicleInfo.Value)
    end

    local profile = overhaul_career_market_valueCalculator.getVehicleCatalogProfile and
      overhaul_career_market_valueCalculator.getVehicleCatalogProfile(
        vehicleInfo.model_key, vehicleInfo.key, vehicleInfo) or nil
    local cachedPartsValue = profile and profile.partsRetailValue
      or overhaul_career_market_valueCalculator.getVehiclePcPartsCatalogSum(
        vehicleInfo.model_key, vehicleInfo.key, logContext)
      or 0
    local partsCatalogValue = profile and profile.catalogValue
      or (overhaul_career_market_valueCalculator.getVehiclePartsCatalogValue and
        overhaul_career_market_valueCalculator.getVehiclePartsCatalogValue(cachedPartsValue))
      or 0
    if rawCatalogValue == nil and partsCatalogValue <= 0 then
      return false
    end
    rawCatalogValue = rawCatalogValue or 0
    local effectiveCatalogValue = partsCatalogValue > 0 and partsCatalogValue or rawCatalogValue

    vehicleInfo.rawCatalogValue = rawCatalogValue
    vehicleInfo.cachedPartsValue = cachedPartsValue
    vehicleInfo.partsCatalogValue = partsCatalogValue
    vehicleInfo.catalogValueSource = profile and profile.catalogSource or
      (partsCatalogValue > 0 and "parts" or "configFallback")
    vehicleInfo.haloScore = profile and profile.haloScore or 0
    vehicleInfo.haloSignals = profile and profile.haloSignals or nil
    vehicleInfo.haloCohortSize = profile and profile.cohortSize or 0
    vehicleInfo.effectiveCatalogValue = effectiveCatalogValue
    vehicleInfo.Value = vehicleInfo.effectiveCatalogValue
    return true
  end

  service.isPrestigeStreetVehicle = function(vehicleInfo)
    if type(vehicleInfo) ~= "table" then
      return false
    end

    -- Some factory configs are competition cars by name; keep Prestige stock focused on valuable street cars.
    local identity = string.lower(table.concat({
      tostring(vehicleInfo["Config Type"] or ""),
      tostring(vehicleInfo.Configuration or ""),
      tostring(vehicleInfo.Name or ""),
      tostring(vehicleInfo.key or "")
    }, " "))
    local excludedWords = {
      "race", "rally", "drag", "drift", "police", "service",
      "commercial", "semi", "trailer", "frame", "taxi",
      "nascar", "track car", "cup car"
    }
    for _, word in ipairs(excludedWords) do
      if string.find(identity, "%f[%a]" .. word) then
        return false
      end
    end

    local aggregates = type(vehicleInfo.aggregates) == "table" and vehicleInfo.aggregates or {}
    local configTypes = type(aggregates["Config Type"]) == "table" and aggregates["Config Type"] or {}
    local vehicleTypes = type(aggregates.Type) == "table" and aggregates.Type or {}
    local isFactory = vehicleInfo["Config Type"] == "Factory" or configTypes.Factory == true
    local isCar = vehicleInfo.Type == "Car" or vehicleTypes.Car == true
    return isFactory and isCar
  end

  service.buildPrestigeTopTrimLookup = function(vehicleInfos, options)
    options = options or {}
    local modelGroups = {}
    for _, vehicleInfo in ipairs(vehicleInfos or {}) do
      local years = service.safeYearsRange(vehicleInfo)
      if service.isPrestigeStreetVehicle(vehicleInfo) and years and years.max >= (options.modernMinYear or 2000) then
        local effectiveValue = tonumber(vehicleInfo.effectiveCatalogValue) or 0
        local originalValue = tonumber(vehicleInfo.rawCatalogValue) or tonumber(vehicleInfo.Value) or 0
        local bestCatalogValue = math.max(effectiveValue, originalValue)
        local haloScore = tonumber(vehicleInfo.haloScore) or 0
        local insuranceClasses = type(vehicleInfo.aggregates) == "table"
          and vehicleInfo.aggregates.InsuranceClass or nil
        local prestigeClass = type(insuranceClasses) == "table" and insuranceClasses.prestige == true

        -- Prestige stock keeps a price floor: the best trim of an economy car is not special enough alone.
        if bestCatalogValue >= (options.valueFloor or 45000)
            or (bestCatalogValue >= (options.haloValueFloor or 35000) and (haloScore >= (options.haloFloor or 0.75) or prestigeClass)) then
          local modelKey = vehicleInfo.model_key
          modelGroups[modelKey] = modelGroups[modelKey] or {}
          table.insert(modelGroups[modelKey], {
            key = service.getVehicleConfigTrackingKey(vehicleInfo),
            value = bestCatalogValue,
            score = bestCatalogValue * (1 + 0.35 * haloScore) + (prestigeClass and 7500 or 0)
          })
        end
      end
    end

    local lookup = {}
    for _, configs in pairs(modelGroups) do
      table.sort(configs, function(a, b)
        if a.score == b.score then
          return tostring(a.key) < tostring(b.key)
        end
        return a.score > b.score
      end)

      local selectedCount = math.max(1, math.min(options.maxTopTrims or 5, math.ceil(#configs * (options.topTrimFraction or 0.20))))
      for rank = 1, selectedCount do
        local config = configs[rank]
        lookup[config.key] = {
          rank = rank,
          cohortSize = #configs,
          score = config.score,
          value = config.value
        }
      end
    end
    return lookup
  end

  service.isPrestigeVehicle = function(vehicleInfo, topTrimLookup, options)
    options = options or {}
    if not service.isPrestigeStreetVehicle(vehicleInfo) then
      return false
    end

    local effectiveValue = tonumber(vehicleInfo.effectiveCatalogValue) or 0
    local originalValue = tonumber(vehicleInfo.rawCatalogValue) or tonumber(vehicleInfo.Value) or 0
    local haloScore = tonumber(vehicleInfo.haloScore) or 0
    local insuranceClasses = type(vehicleInfo.aggregates) == "table"
      and vehicleInfo.aggregates.InsuranceClass or nil
    local prestigeClass = type(insuranceClasses) == "table" and insuranceClasses.prestige == true

    local bestCatalogValue = math.max(effectiveValue, originalValue)
    local topTrimData = type(topTrimLookup) == "table"
      and topTrimLookup[service.getVehicleConfigTrackingKey(vehicleInfo)] or nil
    if topTrimData then
      return true, "modernTopTrim", topTrimData
    end
    if bestCatalogValue >= (options.premiumValueFloor or 100000) then
      return true, "sixFigureCatalog"
    end

    local years = service.safeYearsRange(vehicleInfo)
    if years and years.max < (options.modernMinYear or 2000) and bestCatalogValue >= (options.collectorValueFloor or 50000)
        and (haloScore >= (options.haloFloor or 0.75) or prestigeClass) then
      return true, "collectorHalo"
    end
    return false
  end

  service.safeBoundingBoxDimensions = function(vehicleInfo)
    if type(vehicleInfo) ~= "table" then
      return nil
    end

    local boundingBox = vehicleInfo.BoundingBox
    local dimensions = type(boundingBox) == "table" and boundingBox[2] or nil
    if type(dimensions) ~= "table" then
      return nil
    end

    local x = tonumber(dimensions[1])
    local y = tonumber(dimensions[2])
    local z = tonumber(dimensions[3])
    if not x or not y or not z then
      return nil
    end

    return x, y, z
  end

  -- Nested config data is shared read-only with the eligible list; draws get deep copies.
  service.copyCatalogEntry = function(vehicleInfo)
    local entry = {}
    for key, value in pairs(vehicleInfo) do entry[key] = value end
    return entry
  end

  service.safeVehicleOp = function(context, vehicleInfo, fn)
    local ok, result = pcall(fn)
    if not ok then
      service.quarantineVehicleConfig(vehicleInfo, result, context)
      return nil, result
    end
    return result, nil
  end

  service.sanitizeVehicleInfoList = function(rawVehicles, context, dropStatKey)
    local sanitizedVehicles = {}
    local summary = {
      raw = 0,
      kept = 0,
      malformed = 0,
      quarantined = 0
    }

    if type(rawVehicles) ~= "table" then
      return sanitizedVehicles, summary
    end

    for _, vehicleInfo in ipairs(rawVehicles) do
      summary.raw = summary.raw + 1
      if service.isQuarantined(vehicleInfo) then
        summary.quarantined = summary.quarantined + 1
        service.incrementValidationStat(dropStatKey)
      else
        local ok, reason = service.isValidVehicleInfoShape(vehicleInfo)
        if not ok then
          summary.malformed = summary.malformed + 1
          service.incrementValidationStat(dropStatKey)
          service.quarantineVehicleConfig(vehicleInfo, reason, context)
        else
          service.normalizeVehicleCatalogValue(vehicleInfo, context)
          table.insert(sanitizedVehicles, vehicleInfo)
          summary.kept = summary.kept + 1
        end
      end
    end

    return sanitizedVehicles, summary
  end

  service.logVehicleSanitizationSummary = function(context, summary)
    local logLevel = (summary.kept > 0 or summary.raw == 0) and "I" or "W"
    log(logLevel, "Career", string.format("%s summary: raw=%d kept=%d malformed=%d quarantined=%d",
      tostring(context), summary.raw, summary.kept, summary.malformed, summary.quarantined))
  end

  service.validateSavedVehicleRuntimeFields = function(vehicleInfo)
    local sellerIdType = type(vehicleInfo.sellerId)
    if (sellerIdType ~= "string" and sellerIdType ~= "number") or tostring(vehicleInfo.sellerId) == "" then
      return false, "missing saved sellerId"
    end

    local generationTime = tonumber(vehicleInfo.generationTime)
    if not generationTime then
      return false, "missing saved generationTime"
    end

    local offerTTL = tonumber(vehicleInfo.offerTTL)
    if not offerTTL then
      return false, "missing saved offerTTL"
    end

    local shopId = tonumber(vehicleInfo.shopId)
    if not shopId then
      return false, "missing saved shopId"
    end

    local fees = vehicleInfo.fees
    if fees == nil then
      fees = 0
    else
      fees = tonumber(fees)
      if not fees or fees < 0 then
        return false, "invalid saved fees"
      end
    end

    local tax = vehicleInfo.tax
    if tax == nil then
      tax = shoppingConfig.salesTax
    else
      tax = tonumber(tax)
      if not tax or tax < 0 then
        return false, "invalid saved tax"
      end
    end

    vehicleInfo.generationTime = generationTime
    vehicleInfo.offerTTL = offerTTL
    vehicleInfo.shopId = shopId
    vehicleInfo.fees = fees
    vehicleInfo.tax = tax

    return true
  end

  service.coerceVehiclePricingFields = function(vehicleInfo)
    if type(vehicleInfo) ~= "table" then
      return 0, shoppingConfig.salesTax
    end

    local fees = tonumber(vehicleInfo.fees)
    if not fees or fees < 0 then
      fees = 0
    end

    local tax = tonumber(vehicleInfo.tax)
    if not tax or tax < 0 then
      tax = shoppingConfig.salesTax
    end

    vehicleInfo.fees = fees
    vehicleInfo.tax = tax
    return fees, tax
  end

  service.sanitizeSavedVehicleEntries = function(savedVehicles, context)
    local sanitizedVehicles = {}
    local summary = {
      raw = 0,
      kept = 0,
      malformed = 0,
      quarantined = 0
    }

    if type(savedVehicles) ~= "table" then
      return sanitizedVehicles, summary
    end

    for _, vehicleInfo in ipairs(savedVehicles) do
      summary.raw = summary.raw + 1
      if service.isQuarantined(vehicleInfo) then
        summary.quarantined = summary.quarantined + 1
        service.incrementValidationStat("loadDropped")
      else
        local ok, reason = service.isValidVehicleInfoShape(vehicleInfo)
        if ok then
          ok, reason = service.validateSavedVehicleRuntimeFields(vehicleInfo)
        end
        if not ok then
          local logKey = "loaddrop:" .. service.getVehicleConfigTrackingKey(vehicleInfo)
          summary.malformed = summary.malformed + 1
          service.incrementValidationStat("loadDropped")
          if not state.badConfigLogOnce[logKey] then
            state.badConfigLogOnce[logKey] = true
            log("W", "Career", string.format("Dropped malformed saved vehicle entry %s during %s: %s",
              tostring(service.getVehicleConfigTrackingKey(vehicleInfo)), tostring(context), tostring(reason)))
          end
        else
          table.insert(sanitizedVehicles, vehicleInfo)
          summary.kept = summary.kept + 1
        end
      end
    end

    for _, vehicleInfo in ipairs(sanitizedVehicles) do
      if vehicleInfo.pos ~= nil then
        local posOk, posOrErr = pcall(function()
          return vec3(vehicleInfo.pos)
        end)
        if posOk then
          vehicleInfo.pos = posOrErr
        else
          local posLogKey = service.getVehicleConfigTrackingKey(vehicleInfo) .. "|savedPos"
          if not state.badConfigLogOnce[posLogKey] then
            state.badConfigLogOnce[posLogKey] = true
            log("W", "Career", string.format("Clearing malformed saved vehicle position for %s during %s: %s",
              tostring(service.getVehicleConfigId(vehicleInfo) or service.getVehicleConfigTrackingKey(vehicleInfo)),
              tostring(context), tostring(posOrErr)))
          end
          vehicleInfo.pos = nil
        end
      end
    end

    return sanitizedVehicles, summary
  end

  function service.bindServices(bindings)
    assert(type(bindings.getOrgLevelData) == "function", "validation requires getOrgLevelData")
    dependencies = bindings
  end
  return service
end

return M
