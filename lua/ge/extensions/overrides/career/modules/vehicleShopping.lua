-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.dependencies =
  {'career_career', 'career_modules_inspectVehicle', 'career_modules_valueCalculator', 'util_configListGenerator',
   'freeroam_organizations'}

local moduleVersion = 63

-- Configuration constants
local vehicleDeliveryDelay = 60
local vehicleOfferTimeToLive = 10 * 60
local timeToRemoveSoldVehicle = 5 * 60
local dealershipTimeBetweenOffers = 1 * 60
local vehiclesPerDealership = vehicleOfferTimeToLive / dealershipTimeBetweenOffers
local salesTax = 0.07
local customLicensePlatePrice = 300
local dealershipPurchaseReputationGain = 2000
local missingYearsFallbackModelYear = 2023
local refreshInterval = 5
local tetherRange = 4
local POLICE_DEALERSHIP_UNLOCK_LEVEL = 10
local POLICE_DEALERSHIP_IDS = {
  policeDealership = true,
  poliziaAuto = true
}
local POLICE_SKILL_PATH_IDS = {"careerSkills-police", "police", "freestyle-police"}

-- Module state
local vehicleShopDirtyDate
local vehiclesInShop = {}
local sellersInfos = {}
local otherMapsData = {}
local lastMap
local currentSeller
local purchaseData
local tether
local vehicleWatchlist = {}
local currentUiState

-- Delta tracking system
local lastSnapshotByShopId = {}
local lastDelta = {
  seq = 0,
  added = {},
  removed = {},
  sold = {},
  updated = {}
}
local deltaSeq = 0
local pendingSoldShopIds = {}
local soldVehicles = {}
local uiOpen = false
local refreshAccumulator = 0
local nextShopUpdateTime = 0

-- Vehicle cache system
local vehicleCache = {
  regularVehicles = {},
  dealershipCache = {},
  lastCacheTime = 0,
  cacheValid = false
}

local badConfigQuarantine = {}
local badConfigLogOnce = {}
local validationStats = {
  quarantined = 0,
  loadDropped = 0,
  cacheDropped = 0,
  generationDropped = 0
}

-- State tracking
local purchaseMenuOpen = false
local inspectingVehicleShopId = nil

-- Utility functions
local function generateShopId()
  local shopId = 0
  while true do
    shopId = math.floor(math.random() * 1000000)
    local found = false
    for _, vehInfo in ipairs(vehiclesInShop) do
      if vehInfo.shopId == shopId then
        found = true
        break
      end
    end
    if not found then
      return shopId
    end
  end
end

local function getBranchLevelByPathIds(pathIds)
  if not career_branches or not career_branches.getBranchLevel then
    return 0
  end

  for _, skillPathId in ipairs(pathIds or {}) do
    local branchLevel = career_branches.getBranchLevel(skillPathId)
    local level = tonumber(branchLevel)
    if level then
      return math.max(0, math.floor(level))
    end
  end

  return 0
end

local function getPoliceSkillLevel()
  local level = getBranchLevelByPathIds(POLICE_SKILL_PATH_IDS)
  if level > 0 then
    return level
  end

  if career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue and career_branches and career_branches.calcBranchLevelFromValue then
    local value = tonumber(career_modules_playerAttributes.getAttributeValue("careerSkills-police")) or 0
    for _, skillPathId in ipairs(POLICE_SKILL_PATH_IDS) do
      local branchLevel = career_branches.calcBranchLevelFromValue(value, skillPathId)
      level = math.max(level, tonumber(branchLevel) or 0)
    end
  end

  return math.max(0, math.floor(level))
end

local function isPoliceDealershipLocked(dealershipId)
  return POLICE_DEALERSHIP_IDS[dealershipId] and getPoliceSkillLevel() < POLICE_DEALERSHIP_UNLOCK_LEVEL or false
end

local function getPoliceDealershipLockLabel()
  return string.format("Police Dealership requires Police Skill level %d", POLICE_DEALERSHIP_UNLOCK_LEVEL)
end

local function getVehicleInfoByShopId(shopId)
  if not shopId then
    return nil
  end
  local numShopId = tonumber(shopId)
  if not numShopId then
    log("W", "Career", "getVehicleInfoByShopId: Invalid shopId type: " .. tostring(shopId))
    return nil
  end
  for _, vehInfo in ipairs(vehiclesInShop) do
    if vehInfo.shopId == numShopId then
      return vehInfo
    end
  end
  return nil
end

local function generateSoldVehicleValue(shopId)
  local vehicleInfo = getVehicleInfoByShopId(shopId)
  if not vehicleInfo then return 0 end
  local value = vehicleInfo.Value * (0.9 + math.random() * 0.1)
  return round(value / 10) * 10
end

local function getRoundedPrice(value, priceRoundingType)
  if priceRoundingType == "prestige" then
    local thousands = math.floor(value / 1000)
    local candidate495 = thousands * 1000 + 495
    if value <= candidate495 then return candidate495 end
    local candidate995 = thousands * 1000 + 995
    if value <= candidate995 then return candidate995 end
    return (thousands + 1) * 1000 + 495
  elseif priceRoundingType == "private" then
    return math.ceil(value / 100) * 100
  elseif priceRoundingType == "dealer" then
    return math.ceil(value / 20) * 20
  else
    return math.ceil(value / 10) * 10
  end
end

local function getEligibleVehiclesWithoutDealershipVehicles(eligibleVehicles, seller)
  local eligibleVehiclesWithoutDealershipVehicles = deepcopy(eligibleVehicles)
  local configsInDealership = {}
  for _, vehicleInfo in ipairs(vehiclesInShop) do
    if vehicleInfo.sellerId == seller.id then
      configsInDealership[vehicleInfo.model_key] = configsInDealership[vehicleInfo.model_key] or {}
      configsInDealership[vehicleInfo.model_key][vehicleInfo.key] = true
    end
  end

  for i = #eligibleVehiclesWithoutDealershipVehicles, 1, -1 do
    local vehicleInfo = eligibleVehiclesWithoutDealershipVehicles[i]
    if configsInDealership[vehicleInfo.model_key] and configsInDealership[vehicleInfo.model_key][vehicleInfo.key] then
      table.remove(eligibleVehiclesWithoutDealershipVehicles, i)
    end
  end
  return eligibleVehiclesWithoutDealershipVehicles
end

local privateSellersPreview = "/levels/west_coast_usa/facilities/privateSeller_dealership.jpg"
local function getUiDealershipsData(unsoldVehicles)
  local dealerships = freeroam_facilities.getFacilitiesByType("dealership")
  local vehicleCountPerDealership = {}
  for _, vehicle in ipairs(unsoldVehicles) do
    vehicleCountPerDealership[vehicle.sellerId] = (vehicleCountPerDealership[vehicle.sellerId] or 0) + 1
  end
  local data = {}
  if dealerships then
    for _, dealership in ipairs(dealerships) do
      table.insert(data, {
        id = dealership.id,
        name = dealership.name,
        description = dealership.description,
        vehicleCount = vehicleCountPerDealership[dealership.id] or 0,
        preview = dealership.preview,
        icon = "carDealer"
      })
    end
  end
  table.sort(data, function(a,b) return a.name < b.name end)
  table.insert(data, {
    id = "private",
    name = "Private Sellers",
    vehicleCount = vehicleCountPerDealership["private"] or 0,
    preview = privateSellersPreview,
    icon = "personSolid"
  })
  return data
end

local function sanitizeVehicleForUi(v)
  local t = {}
  t.shopId = v.shopId

  for k, val in pairs(v) do
    local ty = type(val)
    if k == "pos" then
      if val and val.x then
        t.pos = {
          x = val.x,
          y = val.y,
          z = val.z
        }
      end
    elseif k == "precomputedFilter" or k == "filter" or k == "distanceVec" then
    elseif ty == "function" or ty == "userdata" then
    else
      t[k] = val
    end
  end
  return t
end

local function convertKeysToStrings(t)
  local unsoldVehicles = {}
  local soldVehiclesResult = {}
  for k, v in ipairs(t) do
    if v.soldViewCounter and v.soldViewCounter > 0 then
      table.insert(soldVehiclesResult, v)
    else
      table.insert(unsoldVehicles, v)
    end
  end
  return unsoldVehicles, soldVehiclesResult
end

local function sanitizeOrganizationForUi(org)
  if not org then
    return nil
  end

  local sanitizedOrg = {
    reputationLevels = {},
    reputation = {}
  }

  if org.reputation then
    local repLevel = org.reputation.level or 0
    if type(repLevel) ~= "number" then
      repLevel = 0
    end
    repLevel = math.max(0, repLevel)
    sanitizedOrg.reputation.level = repLevel
    sanitizedOrg.reputation.levelIndex = repLevel + 2
    sanitizedOrg.reputation.value = org.reputation.value
    sanitizedOrg.reputation.curLvlProgress = org.reputation.curLvlProgress
    sanitizedOrg.reputation.neededForNext = org.reputation.neededForNext
    sanitizedOrg.reputation.prevThreshold = org.reputation.prevThreshold
    sanitizedOrg.reputation.nextThreshold = org.reputation.nextThreshold
  else
    sanitizedOrg.reputation.level = 0
    sanitizedOrg.reputation.levelIndex = 2
  end

  if org.reputationLevels then
    for idx, lvl in pairs(org.reputationLevels) do
      sanitizedOrg.reputationLevels[idx] = {
        hiddenFromDealerList = lvl and lvl.hiddenFromDealerList or nil
      }
    end
  end

  return sanitizedOrg
end

local function collectOrganizationsForUi(facilities)
  local organizations = {}
  if not facilities or not facilities.dealerships then
    return organizations
  end

  local organizationsById = freeroam_organizations.getOrganizations()
  for _, dealer in ipairs(facilities.dealerships) do
    local orgId = dealer.associatedOrganization
    if orgId and not organizations[orgId] then
      local org = organizationsById and organizationsById[orgId]
      local sanitizedOrg = sanitizeOrganizationForUi(org)
      if sanitizedOrg then
        organizations[orgId] = sanitizedOrg
      end
    end
  end

  return organizations
end

local function getVisualValueFromMileage(mileage)
  mileage = clamp(mileage, 0, 2000000000)
  if mileage <= 10000000 then
    return 1
  elseif mileage <= 50000000 then
    return rescale(mileage, 10000000, 50000000, 1, 0.95)
  elseif mileage <= 100000000 then
    return rescale(mileage, 50000000, 100000000, 0.95, 0.925)
  elseif mileage <= 200000000 then
    return rescale(mileage, 100000000, 200000000, 0.925, 0.88)
  elseif mileage <= 500000000 then
    return rescale(mileage, 200000000, 500000000, 0.88, 0.825)
  elseif mileage <= 1000000000 then
    return rescale(mileage, 500000000, 1000000000, 0.825, 0.8)
  else
    return rescale(mileage, 1000000000, 2000000000, 0.8, 0.75)
  end
end

local function getDeliveryDelay(distance)
  if not distance then return 1 end
  if distance < 500 then return 1 end
  return vehicleDeliveryDelay
end

local function applyPurchaseAdjustedMarketValue(vehicleInfo)
  if not vehicleInfo then return end
  local vehicleBuyMult = career_modules_valueCalculator.getVehicleBuyMarketMultiplier()
  local marketValue = vehicleInfo.marketValueBase or vehicleInfo.marketValue or vehicleInfo.Value
  vehicleInfo.marketValueAdjusted = math.floor((marketValue or 0) * vehicleBuyMult + 0.5)

  local valueBase = vehicleInfo.valueBase
  if not valueBase then
    if vehicleInfo.marketValue and vehicleInfo.negotiationPersonality and vehicleInfo.negotiationPersonality.priceMultiplier then
      valueBase = vehicleInfo.marketValue * vehicleInfo.negotiationPersonality.priceMultiplier
    else
      valueBase = vehicleInfo.Value
    end
  end
  if valueBase then
    vehicleInfo.valueAdjusted = getRoundedPrice(valueBase * vehicleBuyMult, vehicleInfo.priceRoundingType or "default")
  else
    vehicleInfo.valueAdjusted = vehicleInfo.Value
  end
end

local function getOrgLevelData(org, offset)
  if not org then
    return nil
  end
  local repLevel = (org.reputation and org.reputation.level) or 0
  if type(repLevel) ~= "number" then
    repLevel = 0
  end
  repLevel = math.max(0, repLevel)
  local levels = org.reputationLevels
  if not levels then
    return nil
  end
  local arrayIndex = repLevel + 2 + (offset or 0)
  if arrayIndex < 1 or arrayIndex > #levels then
    return nil
  end
  return levels[arrayIndex]
end

local function resetVehicleValidationState()
  badConfigQuarantine = {}
  badConfigLogOnce = {}
  validationStats = {
    quarantined = 0,
    loadDropped = 0,
    cacheDropped = 0,
    generationDropped = 0
  }
end

local function incrementValidationStat(statKey, amount)
  if statKey and validationStats[statKey] ~= nil then
    validationStats[statKey] = validationStats[statKey] + (amount or 1)
  end
end

local function getVehicleConfigId(vehicleInfo)
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

local function getVehicleConfigTrackingKey(vehicleInfo)
  local configId = getVehicleConfigId(vehicleInfo)
  if configId then
    return configId
  end

  if type(vehicleInfo) ~= "table" then
    return "invalid:" .. tostring(vehicleInfo)
  end

  return string.format("invalid:%s|%s", tostring(vehicleInfo.model_key), tostring(vehicleInfo.key))
end

local function quarantineVehicleConfig(vehicleInfo, reason, context)
  local configId = getVehicleConfigId(vehicleInfo) or getVehicleConfigTrackingKey(vehicleInfo)
  if not badConfigQuarantine[configId] then
    badConfigQuarantine[configId] = true
    validationStats.quarantined = validationStats.quarantined + 1
  end

  if not badConfigLogOnce[configId] then
    badConfigLogOnce[configId] = true
    log("W", "Career", string.format("Quarantined vehicle config %s during %s: %s",
      tostring(configId), tostring(context), tostring(reason)))
  end

  return configId
end

local function isQuarantined(vehicleInfo)
  local trackingKey = getVehicleConfigTrackingKey(vehicleInfo)
  return badConfigQuarantine[trackingKey] == true
end

local function isValidVehicleInfoShape(vehicleInfo)
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
    return false, "missing numeric Value"
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

local function safeYearsRange(vehicleInfo)
  if type(vehicleInfo) ~= "table" then
    return nil
  end

  local function normalizeYears(years)
    if type(years) ~= "table" then
      return nil
    end
    local minYear = tonumber(years.min)
    local maxYear = tonumber(years.max)
    if not minYear or not maxYear or minYear > maxYear then
      return nil
    end
    return {min = minYear, max = maxYear}
  end

  return normalizeYears(vehicleInfo.Years) or
    normalizeYears(type(vehicleInfo.aggregates) == "table" and vehicleInfo.aggregates.Years or nil)
end

local function safeNumericAttribute(vehicleInfo, attrName)
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

local function safeBoundingBoxDimensions(vehicleInfo)
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

local function safeVehicleOp(context, vehicleInfo, fn)
  local ok, result = pcall(fn)
  if not ok then
    quarantineVehicleConfig(vehicleInfo, result, context)
    return nil, result
  end
  return result, nil
end

local function sanitizeVehicleInfoList(rawVehicles, context, dropStatKey)
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
    if isQuarantined(vehicleInfo) then
      summary.quarantined = summary.quarantined + 1
      incrementValidationStat(dropStatKey)
    else
      local ok, reason = isValidVehicleInfoShape(vehicleInfo)
      if not ok then
        summary.malformed = summary.malformed + 1
        incrementValidationStat(dropStatKey)
        quarantineVehicleConfig(vehicleInfo, reason, context)
      else
        table.insert(sanitizedVehicles, vehicleInfo)
        summary.kept = summary.kept + 1
      end
    end
  end

  return sanitizedVehicles, summary
end

local function logVehicleSanitizationSummary(context, summary)
  local logLevel = (summary.kept > 0 or summary.raw == 0) and "I" or "W"
  log(logLevel, "Career", string.format("%s summary: raw=%d kept=%d malformed=%d quarantined=%d",
    tostring(context), summary.raw, summary.kept, summary.malformed, summary.quarantined))
end

local function validateSavedVehicleRuntimeFields(vehicleInfo)
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
    tax = salesTax
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

local function coerceVehiclePricingFields(vehicleInfo)
  if type(vehicleInfo) ~= "table" then
    return 0, salesTax
  end

  local fees = tonumber(vehicleInfo.fees)
  if not fees or fees < 0 then
    fees = 0
  end

  local tax = tonumber(vehicleInfo.tax)
  if not tax or tax < 0 then
    tax = salesTax
  end

  vehicleInfo.fees = fees
  vehicleInfo.tax = tax
  return fees, tax
end

local function sanitizeSavedVehicleEntries(savedVehicles, context)
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
    if isQuarantined(vehicleInfo) then
      summary.quarantined = summary.quarantined + 1
      incrementValidationStat("loadDropped")
    else
      local ok, reason = isValidVehicleInfoShape(vehicleInfo)
      if ok then
        ok, reason = validateSavedVehicleRuntimeFields(vehicleInfo)
      end
      if not ok then
        local logKey = "loaddrop:" .. getVehicleConfigTrackingKey(vehicleInfo)
        summary.malformed = summary.malformed + 1
        incrementValidationStat("loadDropped")
        if not badConfigLogOnce[logKey] then
          badConfigLogOnce[logKey] = true
          log("W", "Career", string.format("Dropped malformed saved vehicle entry %s during %s: %s",
            tostring(getVehicleConfigTrackingKey(vehicleInfo)), tostring(context), tostring(reason)))
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
        local posLogKey = getVehicleConfigTrackingKey(vehicleInfo) .. "|savedPos"
        if not badConfigLogOnce[posLogKey] then
          badConfigLogOnce[posLogKey] = true
          log("W", "Career", string.format("Clearing malformed saved vehicle position for %s during %s: %s",
            tostring(getVehicleConfigId(vehicleInfo) or getVehicleConfigTrackingKey(vehicleInfo)),
            tostring(context), tostring(posOrErr)))
        end
        vehicleInfo.pos = nil
      end
    end
  end

  return sanitizedVehicles, summary
end

-- Delta tracking functions
local function buildSnapshot()
  local snap = {}
  for _, veh in ipairs(vehiclesInShop) do
    snap[veh.shopId] = veh
  end
  return snap
end

local function commitDelta(newSnap, justExpiredShopIds)
  justExpiredShopIds = justExpiredShopIds or {}
  local added, removed, sold, updated = {}, {}, {}, {}
  for shopId, veh in pairs(newSnap) do
    if not lastSnapshotByShopId[shopId] then
      table.insert(added, sanitizeVehicleForUi(veh))
    end
  end
  for shopId, veh in pairs(newSnap) do
    local prev = lastSnapshotByShopId[shopId]
    if prev and veh then
      local wasMarkedSold = prev.markedSold == true
      local isMarkedSold = veh.markedSold == true
      local prevSold = (prev.soldViewCounter or 0)
      local currSold = (veh.soldViewCounter or 0)

      if justExpiredShopIds[shopId] or (isMarkedSold and not wasMarkedSold) or (currSold > prevSold) then
        local soldVeh = sanitizeVehicleForUi(veh)
        soldVeh.__sold = true
        table.insert(updated, soldVeh)
      end
    end
  end
  for shopId, _ in pairs(lastSnapshotByShopId) do
    if not newSnap[shopId] then
      if pendingSoldShopIds[shopId] then
        local prevVeh = lastSnapshotByShopId[shopId]
        if prevVeh then
          local soldVeh = sanitizeVehicleForUi(prevVeh)
          soldVeh.shopId = shopId
          soldVeh.__sold = true
          table.insert(sold, soldVeh)
        else
          table.insert(sold, shopId)
        end
        pendingSoldShopIds[shopId] = nil
      else
        table.insert(removed, shopId)
      end
    end
  end
  lastSnapshotByShopId = newSnap
  deltaSeq = deltaSeq + 1
  lastDelta = {
    seq = deltaSeq,
    added = added,
    removed = removed,
    sold = sold,
    updated = updated,
    organizations = collectOrganizationsForUi(freeroam_facilities.getFacilities(getCurrentLevelIdentifier())),
    dealershipPurchaseReputationGain = dealershipPurchaseReputationGain
  }
end

-- UI state management
local function setShoppingUiOpen(isOpen)
  uiOpen = not not isOpen
  refreshAccumulator = 0
  if uiOpen then
    M.updateVehicleList(false)
    nextShopUpdateTime = 0
  end
end

local function onUiChangedState(toState)
  currentUiState = toState
end

local function onUpdate(dt)
  refreshAccumulator = refreshAccumulator + dt
  if refreshAccumulator < 5 then
    return
  end
  refreshAccumulator = 0

  -- Watchlist expiration check
  if not tableIsEmpty(vehicleWatchlist) and (not currentUiState or currentUiState == "play") then
    local currentTime = os.time()
    local inspectedVehicleInfo = career_modules_inspectVehicle.getSpawnedVehicleInfo()
    for shopId, status in pairs(vehicleWatchlist) do
      if status == "unsold" and (not inspectedVehicleInfo or inspectedVehicleInfo.shopId ~= shopId) then
        local vehicleInfo = getVehicleInfoByShopId(shopId)
        if vehicleInfo then
          local offerTime = currentTime - vehicleInfo.generationTime
          if offerTime > vehicleInfo.offerTTL then
            vehicleInfo.soldFor = generateSoldVehicleValue(shopId)
            vehicleWatchlist[shopId] = "sold"
            guihooks.trigger("toastrMsg", {type="info", title="A vehicle you were interested in has been sold.", msg = vehicleInfo.Name .. " for $" .. string.format("%.2f", vehicleInfo.soldFor)})
            break
          end
        end
      end
    end
  end

  -- UI refresh logic
  if not uiOpen then
    return
  end
  local now = os.time()
  if (nextShopUpdateTime == 0) or (now >= nextShopUpdateTime) then
    M.updateVehicleList(false)
  end

  M.checkSpawnedVehicleStatus()
end

-- Data access functions
local function getShoppingData()
  local data = {}

  local unsoldVehicles, soldVehiclesResult = convertKeysToStrings(vehiclesInShop)
  for _, vehicleInfo in ipairs(unsoldVehicles) do
    applyPurchaseAdjustedMarketValue(vehicleInfo)
  end
  for _, vehicleInfo in ipairs(soldVehiclesResult) do
    applyPurchaseAdjustedMarketValue(vehicleInfo)
  end
  data.vehiclesInShop = unsoldVehicles
  data.soldVehicles = soldVehiclesResult
  data.uiDealershipsData = getUiDealershipsData(unsoldVehicles)
  data.currentSeller = currentSeller
  if currentSeller then
    local dealership = freeroam_facilities.getDealership(currentSeller)
    if dealership then
      data.currentSellerNiceName = dealership.name
    end
  end
  data.playerAttributes = career_modules_playerAttributes.getAllAttributes()
  data.inventoryHasFreeSlot = career_modules_inventory.hasFreeSlot()
  data.numberOfFreeSlots = career_modules_inventory.getNumberOfFreeSlots()
  data.cheatsMode = career_modules_cheats and career_modules_cheats.isCheatsMode() or false
  data.dealershipPurchaseReputationGain = dealershipPurchaseReputationGain

  data.tutorialPurchase = (not career_modules_linearTutorial.getTutorialFlag("purchasedFirstCar")) or nil

  data.disableShopping = false
  local reason = career_modules_permissions.getStatusForTag("vehicleShopping")
  if not reason.allow then
    data.disableShopping = true
  end
  if reason.permission ~= "allowed" then
    data.disableShoppingReason = reason.label or "not allowed (TODO)"
  end

  local facilities = freeroam_facilities.getFacilities(getCurrentLevelIdentifier())
  data.dealerships = {}
  data.organizations = collectOrganizationsForUi(facilities)
  if facilities and facilities.dealerships then
    for _, d in ipairs(facilities.dealerships) do
      table.insert(data.dealerships, {
        id = d.id,
        name = d.name,
        description = d.description,
        preview = d.preview,
        hiddenFromDealerList = d.hiddenFromDealerList or isPoliceDealershipLocked(d.id),
        associatedOrganization = d.associatedOrganization
      })
    end
  end

  if facilities and facilities.privateSellers then
    for _, d in ipairs(facilities.privateSellers) do
      table.insert(data.dealerships, {
        id = d.id,
        name = d.name,
        description = d.description,
        preview = d.preview,
        hiddenFromDealerList = d.hiddenFromDealerList or isPoliceDealershipLocked(d.id),
        associatedOrganization = d.associatedOrganization
      })
    end
  end

  return data
end

-- Price calculation functions
local function getRandomizedPrice(price, range)
  range = range or {0.5, 0.90, 1.15, 1.5}
  local L, NL, NH, H = range[1], range[2], range[3], range[4]

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

  local finalPrice
  if rand <= 0.01 then
    local slope = (NL - L) / 0.01
    finalPrice = (L + slope * rand) * price
  elseif rand <= 0.99 then
    local slope = (NH - NL) / 0.98
    finalPrice = (NL + slope * (rand - 0.01)) * price
  else
    local slope = (H - NH) / 0.01
    finalPrice = (NH + slope * (rand - 0.99)) * price
  end

  local finalPriceInt = math.floor(finalPrice + 0.5)
  return math.max(finalPriceInt, 500)
end

-- Vehicle filtering and processing functions
local function normalizePopulations(configs, scalingFactor)
  if not configs or tableIsEmpty(configs) then
    return
  end
  local sum = 0
  for _, configInfo in ipairs(configs) do
    configInfo.adjustedPopulation = tonumber(configInfo.Population) or 1
    sum = sum + configInfo.adjustedPopulation
  end
  local count = tableSize(configs)
  if count == 0 then
    return
  end
  local average = sum / count
  for _, configInfo in ipairs(configs) do
    local distanceFromAverage = configInfo.adjustedPopulation - average
    configInfo.adjustedPopulation = round(configInfo.adjustedPopulation - scalingFactor * distanceFromAverage)
  end
end

local function doesVehiclePassFiltersList(vehicleInfo, filters)
  if type(vehicleInfo) ~= "table" or type(filters) ~= "table" then
    return false
  end

  for filterName, parameters in pairs(filters) do
    if filterName == "Years" then
      local vehicleYears = safeYearsRange(vehicleInfo)
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
        local value = safeNumericAttribute(vehicleInfo, filterName)
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
  return true
end

local function doesVehiclePassFilter(vehicleInfo, filter)
  if type(filter) ~= "table" then
    return false
  end
  if filter.whiteList and not doesVehiclePassFiltersList(vehicleInfo, filter.whiteList) then
    return false
  end
  if filter.blackList and doesVehiclePassFiltersList(vehicleInfo, filter.blackList) then
    return false
  end
  return true
end

-- Cache management functions
local function cacheDealers()
  local startTime = os.clock()
  vehicleCache.cacheValid = false
  vehicleCache.dealershipCache = {}
  local totalPartsCalculated = 0

  local rawEligibleVehicles = util_configListGenerator.getEligibleVehicles() or {}
  local regularEligibleVehicles, eligibleSummary = sanitizeVehicleInfoList(rawEligibleVehicles, "cacheDealers",
    "cacheDropped")
  logVehicleSanitizationSummary("cacheDealers eligible vehicles", eligibleSummary)
  normalizePopulations(regularEligibleVehicles, 0.4)
  vehicleCache.regularVehicles = regularEligibleVehicles

  local facilities = freeroam_facilities.getFacilities(getCurrentLevelIdentifier())

  if facilities and facilities.dealerships then
    for _, dealership in ipairs(facilities.dealerships) do
      local dealershipId = dealership.id

      local filter = dealership.filter or {}
      if dealership.associatedOrganization then
        local org = freeroam_organizations.getOrganization(dealership.associatedOrganization)
        local level = getOrgLevelData(org)
        if level and level.filter then
          filter = level.filter
        end
      end

      local subFilters = dealership.subFilters or {}
      if dealership.associatedOrganization then
        local org = freeroam_organizations.getOrganization(dealership.associatedOrganization)
        local level = getOrgLevelData(org)
        if level and level.subFilters then
          subFilters = level.subFilters
        end
      end

      if filter or subFilters then
        local filteredRegular = {}
        local filters = {}
        local droppedForDealership = 0

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

        for _, filter in ipairs(filters) do
          local subProb = filter._probability or filter.probability or 1
          for _, vehicleInfo in ipairs(regularEligibleVehicles) do
            if not isQuarantined(vehicleInfo) then
              local cachedVehicle, err = safeVehicleOp("cacheDealers", vehicleInfo, function()
                if not doesVehiclePassFilter(vehicleInfo, filter) then
                  return false
                end

                local cacheEntry = deepcopy(vehicleInfo)
                cacheEntry.precomputedFilter = filter
                cacheEntry.subFilterProbability = subProb
                cacheEntry.cachedPartsValue = career_modules_valueCalculator.getVehiclePcPartsCatalogSum(
                  vehicleInfo.model_key, vehicleInfo.key, "cacheDealers")
                return cacheEntry
              end)

              if err then
                droppedForDealership = droppedForDealership + 1
                incrementValidationStat("cacheDropped")
              elseif cachedVehicle then
                totalPartsCalculated = totalPartsCalculated + 1
                table.insert(filteredRegular, cachedVehicle)
              end
            end
          end
        end

        vehicleCache.dealershipCache[dealershipId] = vehicleCache.dealershipCache[dealershipId] or {}
        if tableIsEmpty(filteredRegular) then
          log("W", "Career", string.format("Dealership not configured: %s (kept=0 dropped=%d)", dealershipId,
            droppedForDealership))
          vehicleCache.dealershipCache[dealershipId].notConfigured = true
        end
        vehicleCache.dealershipCache[dealershipId].regularVehicles = filteredRegular
        vehicleCache.dealershipCache[dealershipId].filters = filters

        log("I", "Career", string.format("cacheDealers dealership %s: kept=%d dropped=%d",
          tostring(dealershipId), #filteredRegular, droppedForDealership))
      end
    end
  end

  local privateVehicles = deepcopy(regularEligibleVehicles)
  local privateDropped = 0
  for i = #privateVehicles, 1, -1 do
    local vehicleInfo = privateVehicles[i]
    local cachedVehicle, err = safeVehicleOp("cacheDealers:private", vehicleInfo, function()
      vehicleInfo.cachedPartsValue = career_modules_valueCalculator.getVehiclePcPartsCatalogSum(
        vehicleInfo.model_key, vehicleInfo.key, "cacheDealers:private")
      return vehicleInfo
    end)

    if err or not cachedVehicle then
      table.remove(privateVehicles, i)
      privateDropped = privateDropped + 1
      if err then
        incrementValidationStat("cacheDropped")
      end
    else
      totalPartsCalculated = totalPartsCalculated + 1
    end
  end

  vehicleCache.dealershipCache["private"] = {
    regularVehicles = privateVehicles,
    filters = {{}}
  }
  if tableIsEmpty(privateVehicles) then
    vehicleCache.dealershipCache["private"].notConfigured = true
  end

  vehicleCache.lastCacheTime = os.time()
  vehicleCache.cacheValid = true
  log("I", "Career", string.format(
    "cacheDealers complete: raw=%d kept=%d malformed=%d quarantined=%d privateKept=%d privateDropped=%d partsCalculated=%d time=%.3fs",
    eligibleSummary.raw, eligibleSummary.kept, eligibleSummary.malformed, eligibleSummary.quarantined,
    #privateVehicles, privateDropped, totalPartsCalculated, os.clock() - startTime))
end

local function getRandomVehicleFromCache(sellerId, count)
  if not vehicleCache.cacheValid then
    log("W", "Career", "Vehicle cache invalid, rebuilding...")
    cacheDealers()
  end

  local dealershipData = vehicleCache.dealershipCache[sellerId]
  if not dealershipData then
    log("W", "Career", "No cached data for seller: " .. tostring(sellerId))
    return {}
  end

  local sourceVehicles
  sourceVehicles = dealershipData.regularVehicles or {}

  local sanitizedSourceVehicles, sourceSummary = sanitizeVehicleInfoList(sourceVehicles, "getRandomVehicleFromCache",
    "cacheDropped")
  if sourceSummary.malformed > 0 or sourceSummary.quarantined > 0 then
    logVehicleSanitizationSummary("getRandomVehicleFromCache " .. tostring(sellerId), sourceSummary)
  end

  if tableIsEmpty(sanitizedSourceVehicles) then
    log("W", "Career", "No cached vehicles available for seller: " .. tostring(sellerId))
    return {}
  end

  local selectedVehicles = {}
  local availableVehicles = deepcopy(sanitizedSourceVehicles)

  for _ = 1, math.min(count, #availableVehicles) do
    for j = #availableVehicles, 1, -1 do
      local vehicle = availableVehicles[j]
      if isQuarantined(vehicle) then
        table.remove(availableVehicles, j)
        incrementValidationStat("cacheDropped")
      else
        local ok, reason = isValidVehicleInfoShape(vehicle)
        if not ok then
          quarantineVehicleConfig(vehicle, reason, "getRandomVehicleFromCache")
          table.remove(availableVehicles, j)
          incrementValidationStat("cacheDropped")
        end
      end
    end

    if tableIsEmpty(availableVehicles) then
      break
    end

    local totalWeight = 0
    for _, vehicle in ipairs(availableVehicles) do
      local pop = tonumber(vehicle.adjustedPopulation) or 1
      local prob = tonumber(vehicle.subFilterProbability) or 1
      totalWeight = totalWeight + (pop * prob)
    end

    if totalWeight <= 0 then
      local randomIndex = math.random(#availableVehicles)
      table.insert(selectedVehicles, availableVehicles[randomIndex])
      table.remove(availableVehicles, randomIndex)
    else
      local randomWeight = math.random() * totalWeight
      local currentWeight = 0

      for j, vehicle in ipairs(availableVehicles) do
        local pop = tonumber(vehicle.adjustedPopulation) or 1
        local prob = tonumber(vehicle.subFilterProbability) or 1
        currentWeight = currentWeight + (pop * prob)
        if currentWeight >= randomWeight then
          table.insert(selectedVehicles, vehicle)
          table.remove(availableVehicles, j)
          break
        end
      end
    end
  end

  return selectedVehicles
end

local function invalidateVehicleCache()
  vehicleCache.cacheValid = false
  vehicleCache.regularVehicles = {}
  vehicleCache.dealershipCache = {}
  career_modules_valueCalculator.clearVehiclePcPartsCatalogSumCache()
  resetVehicleValidationState()
end

local function rebuildDealershipCache(dealershipId)
  if not vehicleCache.cacheValid then
    cacheDealers()
    return
  end

  local facilities = freeroam_facilities.getFacilities(getCurrentLevelIdentifier())
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

  local regularEligibleVehicles, eligibleSummary = sanitizeVehicleInfoList(vehicleCache.regularVehicles or {},
    "rebuildDealershipCache:cachedEligible", "cacheDropped")
  if eligibleSummary.raw > 0 then
    vehicleCache.regularVehicles = regularEligibleVehicles
  end
  if not regularEligibleVehicles or tableIsEmpty(regularEligibleVehicles) then
    local rawEligibleVehicles = util_configListGenerator.getEligibleVehicles() or {}
    regularEligibleVehicles, eligibleSummary = sanitizeVehicleInfoList(rawEligibleVehicles, "rebuildDealershipCache",
      "cacheDropped")
    logVehicleSanitizationSummary("rebuildDealershipCache eligible vehicles", eligibleSummary)
    normalizePopulations(regularEligibleVehicles, 0.4)
    vehicleCache.regularVehicles = regularEligibleVehicles
  end

  local filter = dealership.filter or {}
  if dealership.associatedOrganization then
    local org = freeroam_organizations.getOrganization(dealership.associatedOrganization)
    local level = getOrgLevelData(org)
    if level and level.filter then
      filter = level.filter
    end
  end

  local subFilters = dealership.subFilters or {}
  if dealership.associatedOrganization then
    local org = freeroam_organizations.getOrganization(dealership.associatedOrganization)
    local level = getOrgLevelData(org)
    if level and level.subFilters then
      subFilters = level.subFilters
    end
  end

  local filteredRegular = {}
  local filters = {}
  local droppedForDealership = 0

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

  for _, f in ipairs(filters) do
    local subProb = f._probability or f.probability or 1
    for _, vehicleInfo in ipairs(regularEligibleVehicles) do
      if not isQuarantined(vehicleInfo) then
        local cachedVehicle, err = safeVehicleOp("rebuildDealershipCache", vehicleInfo, function()
          if not doesVehiclePassFilter(vehicleInfo, f) then
            return false
          end

          local cacheEntry = deepcopy(vehicleInfo)
          cacheEntry.precomputedFilter = f
          cacheEntry.subFilterProbability = subProb
          cacheEntry.cachedPartsValue = career_modules_valueCalculator.getVehiclePcPartsCatalogSum(
            vehicleInfo.model_key, vehicleInfo.key, "rebuildDealershipCache")
          return cacheEntry
        end)

        if err then
          droppedForDealership = droppedForDealership + 1
          incrementValidationStat("cacheDropped")
        elseif cachedVehicle then
          table.insert(filteredRegular, cachedVehicle)
        end
      end
    end
  end

  local notConfigured = tableIsEmpty(filteredRegular)
  if notConfigured then
    log("W", "Career", string.format("Dealership not configured: %s (kept=0 dropped=%d)", dealershipId,
      droppedForDealership))
  end

  vehicleCache.dealershipCache[dealershipId] = {
    regularVehicles = filteredRegular,
    filters = filters,
    notConfigured = notConfigured
  }

  log("I", "Career", string.format(
    "Rebuilt cache for dealership %s: kept=%d dropped=%d rawEligible=%d validEligible=%d malformed=%d quarantined=%d",
    dealershipId, #filteredRegular, droppedForDealership, eligibleSummary.raw, eligibleSummary.kept,
    eligibleSummary.malformed, eligibleSummary.quarantined))
end

-- Vehicle list management functions
local function updateVehicleList(fromScratch)
  fromScratch = not not fromScratch
  local sellers = {}
  local currentMap = getCurrentLevelIdentifier()
  local onlyStarterVehicles = not career_career.hasBoughtStarterVehicle()
  local changed = false
  local updateSummary = {
    attempted = 0,
    inserted = 0,
    dropped = 0
  }

  if fromScratch then
    invalidateVehicleCache()
    vehiclesInShop = {}
    sellersInfos = {}
    vehicleWatchlist = {}
    changed = true
  end

  -- If there are already vehicles in the shop, don't generate starter vehicles
  if onlyStarterVehicles and not tableIsEmpty(vehiclesInShop) then
    nextShopUpdateTime = os.time() + 3600
    return
  end

  local filteredVehiclesInShop = {}
  for i, vehicleInfo in ipairs(vehiclesInShop) do
    if vehicleInfo.mapId == currentMap then
      table.insert(filteredVehiclesInShop, vehicleInfo)
    else
      changed = true
    end
  end
  vehiclesInShop = filteredVehiclesInShop

  local filteredSellersInfos = {}
  for sellerId, sellerInfo in pairs(sellersInfos) do
    if sellerInfo.mapId == currentMap then
      filteredSellersInfos[sellerId] = sellerInfo
    else
      changed = true
    end
  end
  sellersInfos = filteredSellersInfos

  if not vehicleCache.cacheValid then
    cacheDealers()
    changed = true
  end

  local facilitiesData = freeroam_facilities.getFacilities(getCurrentLevelIdentifier())
  if not facilitiesData then
    log("W", "Career", "No facilities data available for current map; skipping vehicle list update")
    nextShopUpdateTime = os.time() + 60
    return
  end
  local facilities = facilitiesData

  if facilities.dealerships then
    for _, dealership in ipairs(facilities.dealerships) do
      if onlyStarterVehicles then
        if dealership.containsStarterVehicles then
          table.insert(sellers, {
            id = dealership.id,
            name = dealership.name,
            description = dealership.description,
            preview = dealership.preview,
            hiddenFromDealerList = dealership.hiddenFromDealerList or isPoliceDealershipLocked(dealership.id),
            associatedOrganization = dealership.associatedOrganization,
            vehicleGenerationMultiplier = dealership.vehicleGenerationMultiplier,
            stock = dealership.stock,
            range = dealership.range,
            fees = dealership.fees,
            salesTax = dealership.salesTax,
            priceRoundingType = dealership.priceRoundingType,
            filter = {whiteList = {careerStarterVehicle = {true}}},
            subFilters = nil
          })
        end
      else
        table.insert(sellers, {
          id = dealership.id,
          name = dealership.name,
          description = dealership.description,
          preview = dealership.preview,
          hiddenFromDealerList = dealership.hiddenFromDealerList or isPoliceDealershipLocked(dealership.id),
          associatedOrganization = dealership.associatedOrganization,
          vehicleGenerationMultiplier = dealership.vehicleGenerationMultiplier,
          stock = dealership.stock,
          range = dealership.range,
          fees = dealership.fees,
          salesTax = dealership.salesTax,
          priceRoundingType = dealership.priceRoundingType,
          filter = dealership.filter or {},
          subFilters = dealership.subFilters
        })
      end
    end
  end

  if not onlyStarterVehicles and facilities.privateSellers then
    for _, dealership in ipairs(facilities.privateSellers) do
      table.insert(sellers, {
        id = dealership.id,
        name = dealership.name,
        description = dealership.description,
        preview = dealership.preview,
        hiddenFromDealerList = dealership.hiddenFromDealerList,
        associatedOrganization = dealership.associatedOrganization,
        vehicleGenerationMultiplier = dealership.vehicleGenerationMultiplier,
        stock = dealership.stock,
        range = dealership.range,
        fees = dealership.fees,
        salesTax = dealership.salesTax,
        priceRoundingType = dealership.priceRoundingType,
        filter = dealership.filter or {},
        subFilters = dealership.subFilters
      })
    end
  end
  table.sort(sellers, function(a, b)
    return a.id < b.id
  end)

  local currentTime = os.time()

  -- Track which vehicles are being marked as sold this update
  local justExpiredShopIds = {}

  -- Remove vehicles that have expired using v38 watchlist logic
  for i = #vehiclesInShop, 1, -1 do
    local vehicleInfo = vehiclesInShop[i]
    local offerTime = currentTime - vehicleInfo.generationTime
    if offerTime > vehicleInfo.offerTTL then
      if vehicleWatchlist[vehicleInfo.shopId] then
        if type(vehicleWatchlist[vehicleInfo.shopId]) ~= "number" then
          vehicleWatchlist[vehicleInfo.shopId] = currentTime + timeToRemoveSoldVehicle
          if not vehicleInfo.soldFor then
            vehicleInfo.soldFor = generateSoldVehicleValue(vehicleInfo.shopId)
          end
        end
        vehicleInfo.soldViewCounter = vehicleInfo.soldViewCounter or 0
        vehicleInfo.soldViewCounter = vehicleInfo.soldViewCounter + 1
        vehicleInfo.markedSold = true
        justExpiredShopIds[vehicleInfo.shopId] = true
        changed = true
        if currentTime > vehicleWatchlist[vehicleInfo.shopId] then
          vehicleWatchlist[vehicleInfo.shopId] = nil
          table.remove(vehiclesInShop, i)
          changed = true
        end
      else
        table.remove(vehiclesInShop, i)
        changed = true
      end
    end
  end

  local unsoldCountBySellerId = {}
  for _, vehicleInfo in ipairs(vehiclesInShop) do
    if vehicleInfo.sellerId and not vehicleInfo.soldViewCounter then
      unsoldCountBySellerId[vehicleInfo.sellerId] = (unsoldCountBySellerId[vehicleInfo.sellerId] or 0) + 1
    end
  end

  local sellerMeta = {}

  for _, seller in ipairs(sellers) do
    local sellerAttemptedStart = updateSummary.attempted
    local sellerInsertedStart = updateSummary.inserted
    local sellerDroppedStart = updateSummary.dropped
    local dealershipData = vehicleCache.dealershipCache[seller.id]
    if dealershipData and dealershipData.notConfigured then
      goto continue
    end

    if not sellersInfos[seller.id] then
      sellersInfos[seller.id] = {
        lastGenerationTime = 0,
        mapId = currentMap,
        lastOrgLevel = nil
      }
      changed = true
    end
    if fromScratch then
      sellersInfos[seller.id].lastGenerationTime = 0
    end

    local randomVehicleInfos = {}
    local currentVehicleCount = unsoldCountBySellerId[seller.id] or 0

    local currentOrgLevel = nil
    if seller.associatedOrganization then
      local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
      if org and org.reputation then
        local repLevel = org.reputation.level or 0
        if type(repLevel) ~= "number" then
          repLevel = 0
        end
        currentOrgLevel = math.max(0, repLevel)
      end
    end

    local storedLevel = sellersInfos[seller.id].lastOrgLevel
    local levelChanged = (currentOrgLevel ~= nil) and (storedLevel ~= nil) and (storedLevel ~= currentOrgLevel)

    local maxStock = tonumber(seller.stock) or 10
    if seller.associatedOrganization then
      local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
      local level = getOrgLevelData(org)
      local levelStock = level and tonumber(level.stock) or nil
      if levelStock then
        maxStock = levelStock
      end
    end
    maxStock = math.max(math.floor(maxStock), 1)
    local availableSlots = math.max(0, maxStock - currentVehicleCount)

    local numberOfVehiclesToGenerate = 0
    local adjustedTimeBetweenOffers = vehicleOfferTimeToLive / maxStock
    local generationMultiplier = tonumber(seller.vehicleGenerationMultiplier)
    if generationMultiplier and generationMultiplier > 0 then
      adjustedTimeBetweenOffers = adjustedTimeBetweenOffers / generationMultiplier
    end

    if onlyStarterVehicles then
      -- Generate the starter vehicles
      local eligibleVehiclesStarterRaw = util_configListGenerator.getEligibleVehicles(onlyStarterVehicles) or {}
      local eligibleVehiclesStarter, starterSummary = sanitizeVehicleInfoList(eligibleVehiclesStarterRaw,
        "updateVehicleList:starterEligible", "generationDropped")
      if starterSummary.malformed > 0 or starterSummary.quarantined > 0 then
        logVehicleSanitizationSummary("updateVehicleList starter eligible vehicles", starterSummary)
      end
      randomVehicleInfos = util_configListGenerator.getRandomVehicleInfos(seller, 3, eligibleVehiclesStarter,
        "adjustedPopulation") or {}
    else
      -- vehicleGenerationMultiplier lowers the time between offers
      local maxVehicles = math.floor(vehicleOfferTimeToLive / adjustedTimeBetweenOffers)
      numberOfVehiclesToGenerate = math.min(math.floor((currentTime - sellersInfos[seller.id].lastGenerationTime) / adjustedTimeBetweenOffers), maxVehicles)

      if levelChanged then
        rebuildDealershipCache(seller.id)
        numberOfVehiclesToGenerate = availableSlots
        sellersInfos[seller.id].lastGenerationTime = 0
        log("I", "Career", string.format("Level changed for %s (from %d to %d), restocking to %d vehicles", 
          seller.id, storedLevel, currentOrgLevel, availableSlots))
      elseif fromScratch or sellersInfos[seller.id].lastGenerationTime == 0 then
        numberOfVehiclesToGenerate = availableSlots
        log("D", "Career",
          string.format("Initial stock fill for %s: generating %d vehicles", seller.id, numberOfVehiclesToGenerate))
      elseif availableSlots > 0 and numberOfVehiclesToGenerate < availableSlots then
        numberOfVehiclesToGenerate = availableSlots
        log("D", "Career",
          string.format("Stock below target for %s: generating %d vehicles to reach %d", seller.id, availableSlots, maxStock))
      end

      -- Generate the vehicles without duplicating vehicles that are already in the dealership
      local newRandomVehicleInfos = getRandomVehicleFromCache(seller.id, numberOfVehiclesToGenerate)
      arrayConcat(randomVehicleInfos, newRandomVehicleInfos)

      -- Generate the remaining vehicles without a duplicate check
      local numberOfMissingVehicles = numberOfVehiclesToGenerate - tableSize(newRandomVehicleInfos)
      if numberOfMissingVehicles > 0 then
        log("I", "Career", "Generating " .. numberOfMissingVehicles .. " more vehicles without duplicate check for " .. seller.id)
        local newVehicleInfos = getRandomVehicleFromCache(seller.id, numberOfMissingVehicles)
        arrayConcat(randomVehicleInfos, newVehicleInfos)
      end
    end

    local starterVehicleMileages = {bx = 165746239, etki = 285817342, covet = 80174611}
    local starterVehicleYears = {bx = 1990, etki = 1989, covet = 1989}
    local targetVehicleCount = onlyStarterVehicles and tableSize(randomVehicleInfos) or numberOfVehiclesToGenerate
    local successfulGenerationsForSeller = 0
    local replacementCycles = 0
    local maxReplacementCycles = onlyStarterVehicles and 0 or 2
    local nextBatchStartIndex = 1
    local attemptedGenerationForSeller = false

    if onlyStarterVehicles then
      attemptedGenerationForSeller = not tableIsEmpty(randomVehicleInfos)
    elseif numberOfVehiclesToGenerate > 0 then
      attemptedGenerationForSeller = true
    end

    while nextBatchStartIndex <= #randomVehicleInfos and successfulGenerationsForSeller < targetVehicleCount do
      local batchEndIndex = #randomVehicleInfos
      for i = nextBatchStartIndex, batchEndIndex do
        if successfulGenerationsForSeller >= targetVehicleCount then
          break
        end

        local randomVehicleInfo = randomVehicleInfos[i]
        updateSummary.attempted = updateSummary.attempted + 1
        if isQuarantined(randomVehicleInfo) then
          updateSummary.dropped = updateSummary.dropped + 1
          incrementValidationStat("generationDropped")
        else
          local shapeOk, shapeReason = isValidVehicleInfoShape(randomVehicleInfo)
          if not shapeOk then
            quarantineVehicleConfig(randomVehicleInfo, shapeReason, "updateVehicleList")
            updateSummary.dropped = updateSummary.dropped + 1
            incrementValidationStat("generationDropped")
          else
            local generatedVehicle, err = safeVehicleOp("updateVehicleList", randomVehicleInfo, function()
              randomVehicleInfo.generationTime = currentTime - (successfulGenerationsForSeller * adjustedTimeBetweenOffers)
              randomVehicleInfo.offerTTL = onlyStarterVehicles and math.huge or vehicleOfferTimeToLive

              randomVehicleInfo.sellerId = seller.id
              randomVehicleInfo.sellerName = seller.name

              local filter = type(randomVehicleInfo.precomputedFilter) == "table" and randomVehicleInfo.precomputedFilter or nil
              if not filter and seller.associatedOrganization then
                local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
                local level = getOrgLevelData(org)
                if level and level.filter then
                  filter = level.filter
                end
              end
              filter = filter or (seller.filter or {})
              randomVehicleInfo.filter = filter

              local years = safeYearsRange(randomVehicleInfo)

              if not onlyStarterVehicles then
                if years then
                  local minYear = years.min
                  local filterMinYear = filter.whiteList and filter.whiteList.Years and tonumber(filter.whiteList.Years.min)
                  if filterMinYear then
                    minYear = math.max(minYear, filterMinYear)
                  end
                  local maxYear = years.max
                  local filterMaxYear = filter.whiteList and filter.whiteList.Years and tonumber(filter.whiteList.Years.max)
                  if filterMaxYear then
                    maxYear = math.min(maxYear, filterMaxYear)
                  end
                  if minYear > maxYear then
                    error("invalid year bounds after filtering")
                  end
                  randomVehicleInfo.year = math.random(minYear, maxYear)
                else
                  randomVehicleInfo.year = tonumber(randomVehicleInfo.year) or missingYearsFallbackModelYear
                end

                local mileageMin = filter.whiteList and filter.whiteList.Mileage and tonumber(filter.whiteList.Mileage.min)
                local mileageMax = filter.whiteList and filter.whiteList.Mileage and tonumber(filter.whiteList.Mileage.max)
                if mileageMin and mileageMax then
                  if mileageMin > mileageMax then
                    error("invalid mileage bounds after filtering")
                  end
                  randomVehicleInfo.Mileage = randomGauss3() / 3 *
                                                (mileageMax - mileageMin) +
                                                mileageMin
                elseif mileageMin then
                  local mileageSpread = math.max(mileageMin * 0.5, 5000000)
                  randomVehicleInfo.Mileage = mileageMin +
                                                math.abs(randomGauss3() / 3) * mileageSpread
                elseif mileageMax then
                  local mileageSpread = math.max(mileageMax * 0.5, 5000000)
                  randomVehicleInfo.Mileage = mileageMax -
                                                math.abs(randomGauss3() / 3) * mileageSpread
                  randomVehicleInfo.Mileage = math.max(randomVehicleInfo.Mileage, 0)
                else
                  randomVehicleInfo.Mileage = 0
                end
                if randomVehicleInfo.Mileage < 0 then
                  randomVehicleInfo.Mileage = math.max(randomVehicleInfo.Mileage, 0)
                end
              else
                randomVehicleInfo.year = starterVehicleYears[randomVehicleInfo.model_key]
                if not randomVehicleInfo.year then
                  if years then
                    randomVehicleInfo.year = math.random(years.min, years.max)
                  else
                    randomVehicleInfo.year = tonumber(randomVehicleInfo.year) or missingYearsFallbackModelYear
                  end
                end
                randomVehicleInfo.Mileage = starterVehicleMileages[randomVehicleInfo.model_key] or 100000000
              end

              local valuationYear = tonumber(os.date("%Y")) or 2026
              local vehicleAge = math.max(0, valuationYear - (tonumber(randomVehicleInfo.year) or valuationYear))
              local baseValue = career_modules_valueCalculator.getVehicleCatalogIntrinsicBookValue({
                catalogBaseValue = randomVehicleInfo.Value,
                mileageMeters = randomVehicleInfo.Mileage,
                age = vehicleAge,
                modelName = randomVehicleInfo.model_key,
                configKey = randomVehicleInfo.key,
                partsCatalogSum = randomVehicleInfo.cachedPartsValue,
                logContext = "updateVehicleList",
                applyVehicleBuyMarket = false
              }) or math.max(1500,
                math.floor(career_modules_valueCalculator.getAdjustedVehicleBaseValue(randomVehicleInfo.Value, {
                  mileage = randomVehicleInfo.Mileage,
                  age = vehicleAge
                }) / 1000) * 1000)

              local range = seller.range
              if seller.associatedOrganization then
                local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
                local level = getOrgLevelData(org)
                if level and level.range then
                  range = level.range
                end
              end

              if seller.id == "private" then
                if career_modules_marketplace and career_modules_marketplace.generatePersonality then
                  randomVehicleInfo.negotiationPersonality = career_modules_marketplace.generatePersonality(false)
                  randomVehicleInfo.sellerName = randomVehicleInfo.negotiationPersonality.name
                end
              else
                if career_modules_marketplace and career_modules_marketplace.generatePersonality then
                  local personalityKey = seller.id
                  randomVehicleInfo.negotiationPersonality = career_modules_marketplace.generatePersonality(false,
                    {personalityKey})
                end
              end

              randomVehicleInfo.marketValue = getRandomizedPrice(baseValue, range)
              randomVehicleInfo.marketValueBase = randomVehicleInfo.marketValue
              randomVehicleInfo.priceRoundingType = seller.priceRoundingType

              local priceMultiplier = (randomVehicleInfo.negotiationPersonality and
                                        randomVehicleInfo.negotiationPersonality.priceMultiplier) or 1
              randomVehicleInfo.valueBase = randomVehicleInfo.marketValue * priceMultiplier
              randomVehicleInfo.priceMultiplier = priceMultiplier

              local vehicleBuyMult = career_modules_valueCalculator.getVehicleBuyMarketMultiplier()
              randomVehicleInfo.Value = getRoundedPrice(randomVehicleInfo.valueBase * vehicleBuyMult,
                seller.priceRoundingType)

              randomVehicleInfo.negotiationPossible = not onlyStarterVehicles
              randomVehicleInfo.shopId = generateShopId()
              randomVehicleInfo.associatedOrganization = seller.associatedOrganization

              local fees = seller.fees or 0
              if seller.associatedOrganization then
                local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
                local level = getOrgLevelData(org)
                if level and level.fees ~= nil then
                  fees = level.fees
                end
              end
              fees = tonumber(fees)
              randomVehicleInfo.fees = fees or 0

              local tax = seller.salesTax or salesTax
              if seller.associatedOrganization then
                local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
                local level = getOrgLevelData(org)
                if level and level.tax ~= nil then
                  tax = level.tax
                end
              end
              tax = tonumber(tax)
              randomVehicleInfo.tax = tax or salesTax

              if seller.id == "private" then
                local parkingData = gameplay_parking.getParkingSpots()
                local parkingSpots = parkingData and parkingData.byName or {}
                local sizeMatches, allowedSpots = {}, {}
                local boxX, boxY, boxZ = safeBoundingBoxDimensions(randomVehicleInfo)
                for name, spot in pairs(parkingSpots) do
                  local tags = (spot.customFields and spot.customFields.tags) or {}
                  if not tags.notprivatesale then
                    table.insert(allowedSpots, {
                      name = name,
                      spot = spot
                    })
                    if boxX and spot.boxFits and spot:boxFits(boxX, boxY, boxZ) then
                      table.insert(sizeMatches, {
                        name = name,
                        spot = spot
                      })
                    end
                  end
                end

                local pool = (#sizeMatches > 0) and sizeMatches or allowedSpots
                local chosen = nil
                if #pool > 0 then
                  chosen = pool[math.random(#pool)]
                end
                if chosen then
                  randomVehicleInfo.parkingSpotName = chosen.name
                  randomVehicleInfo.pos = chosen.spot.pos
                else
                  log("W", "Career",
                    string.format("No parking spot available for private sale vehicle %s",
                      tostring(randomVehicleInfo.shopId)))
                end
              else
                local dealership = freeroam_facilities.getDealership(seller.id)
                randomVehicleInfo.pos = freeroam_facilities.getAverageDoorPositionForFacility(dealership)
              end

              if career_modules_insurance_insurance and
                career_modules_insurance_insurance.getInsuranceClassFromVehicleShoppingData then
                local vehicleInsuranceClass =
                  career_modules_insurance_insurance.getInsuranceClassFromVehicleShoppingData(randomVehicleInfo)
                if vehicleInsuranceClass then
                  randomVehicleInfo.insuranceClass = vehicleInsuranceClass
                end
              end

              if career_modules_insurance and career_modules_insurance.getMinApplicablePolicyFromVehicleShoppingData then
                local requiredInsurance =
                  career_modules_insurance.getMinApplicablePolicyFromVehicleShoppingData(randomVehicleInfo)
                if requiredInsurance then
                  randomVehicleInfo.requiredInsurance = requiredInsurance
                end
              end

              randomVehicleInfo.mapId = currentMap
              return randomVehicleInfo
            end)

            if err or not generatedVehicle then
              updateSummary.dropped = updateSummary.dropped + 1
              incrementValidationStat("generationDropped")
            else
              table.insert(vehiclesInShop, generatedVehicle)
              if generatedVehicle.sellerId and not generatedVehicle.soldViewCounter then
                unsoldCountBySellerId[generatedVehicle.sellerId] = (unsoldCountBySellerId[generatedVehicle.sellerId] or 0) + 1
              end
              changed = true
              updateSummary.inserted = updateSummary.inserted + 1
              successfulGenerationsForSeller = successfulGenerationsForSeller + 1
            end
          end
        end
      end

      nextBatchStartIndex = batchEndIndex + 1
      if successfulGenerationsForSeller >= targetVehicleCount or replacementCycles >= maxReplacementCycles then
        break
      end

      local replacementCount = targetVehicleCount - successfulGenerationsForSeller
      if replacementCount <= 0 then
        break
      end

      replacementCycles = replacementCycles + 1
      local replacementVehicles = getRandomVehicleFromCache(seller.id, replacementCount)
      if tableIsEmpty(replacementVehicles) then
        break
      end

      attemptedGenerationForSeller = true
      arrayConcat(randomVehicleInfos, replacementVehicles)
    end
    if successfulGenerationsForSeller >= targetVehicleCount then
      sellersInfos[seller.id].lastGenerationTime = currentTime
      changed = true
    elseif attemptedGenerationForSeller and targetVehicleCount == 0 then
      sellersInfos[seller.id].lastGenerationTime = currentTime
      changed = true
    end
    if updateSummary.attempted > sellerAttemptedStart then
      log("I", "Career", string.format("updateVehicleList seller %s: attempted=%d inserted=%d dropped=%d",
        tostring(seller.id),
        updateSummary.attempted - sellerAttemptedStart,
        updateSummary.inserted - sellerInsertedStart,
        updateSummary.dropped - sellerDroppedStart))
    end

    if currentOrgLevel ~= nil then
      sellersInfos[seller.id].lastOrgLevel = currentOrgLevel
    end

    sellerMeta[seller.id] = {
      maxStock = maxStock,
      adjustedTimeBetweenOffers = adjustedTimeBetweenOffers
    }

    ::continue::
  end

  local minNext = math.huge
  for _, veh in ipairs(vehiclesInShop) do
    if veh.generationTime and veh.offerTTL then
      local expiryTime = veh.generationTime + veh.offerTTL
      if expiryTime > currentTime and expiryTime < minNext then
        minNext = expiryTime
      end
    end
  end
  for _, seller in ipairs(sellers) do
    local meta = sellerMeta[seller.id]
    local fallbackMaxStock = math.max(math.floor(tonumber(seller.stock) or 10), 1)
    local maxStock = meta and meta.maxStock or fallbackMaxStock
    local currentCount = unsoldCountBySellerId[seller.id] or 0
    local availableSlotsAfter = math.max(0, maxStock - currentCount)
    if availableSlotsAfter > 0 then
      local lastGen = (sellersInfos[seller.id] and sellersInfos[seller.id].lastGenerationTime) or 0
      local interval = meta and meta.adjustedTimeBetweenOffers or (vehicleOfferTimeToLive / maxStock)
      local nextGen = (lastGen > 0 and (lastGen + interval)) or currentTime
      if nextGen < minNext then
        minNext = nextGen
      end
    end
  end
  if minNext == math.huge then
    minNext = currentTime + 60
  end
  nextShopUpdateTime = minNext

  if not changed then
    return
  end

  vehicleShopDirtyDate = os.date("!%Y-%m-%dT%H:%M:%SZ")
  log("I", "Career", "Vehicles in shop: " .. tableSize(vehiclesInShop))
  log("I", "Career", string.format("updateVehicleList summary: attempted=%d inserted=%d dropped=%d",
    updateSummary.attempted, updateSummary.inserted, updateSummary.dropped))

  local newSnap = buildSnapshot()
  commitDelta(newSnap, justExpiredShopIds)
  guihooks.trigger("vehicleShopDelta", lastDelta)
end

-- Vehicle spawning and delivery functions
local spawnFollowUpActions

local function moveVehicleToDealership(vehObj, dealershipId)
  local dealership = freeroam_facilities.getDealership(dealershipId)
  local parkingSpots = freeroam_facilities.getParkingSpotsForFacility(dealership)
  local parkingSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(vehObj:getID(), parkingSpots)
  parkingSpot:moveResetVehicleTo(vehObj:getID(), nil, nil, nil, nil, true)
end

local function spawnVehicle(vehicleInfo, dealershipToMoveTo)
  local spawnOptions = {}
  spawnOptions.config = vehicleInfo.key
  spawnOptions.autoEnterVehicle = false
  local newVeh = core_vehicles.spawnNewVehicle(vehicleInfo.model_key, spawnOptions)
  if dealershipToMoveTo then
    moveVehicleToDealership(newVeh, dealershipToMoveTo)
  end
  core_vehicleBridge.executeAction(newVeh, 'setIgnitionLevel', 0)

  newVeh:queueLuaCommand(string.format(
    "partCondition.initConditions(nil, %d, nil, %f) obj:queueGameEngineLua('career_modules_vehicleShopping.onVehicleSpawnFinished(%d)')",
    vehicleInfo.Mileage, getVisualValueFromMileage(vehicleInfo.Mileage), newVeh:getID()))
  return newVeh
end

local function onVehicleSpawnFinished(vehId)
  local inventoryId = career_modules_inventory.addVehicle(vehId)

  if spawnFollowUpActions then
    if spawnFollowUpActions.delayAccess then
      career_modules_inventory.delayVehicleAccess(inventoryId, spawnFollowUpActions.delayAccess, "bought")
    end
    if spawnFollowUpActions.licensePlateText then
      career_modules_inventory.setLicensePlateText(inventoryId, spawnFollowUpActions.licensePlateText)
    end
    if spawnFollowUpActions.dealershipId and
      (spawnFollowUpActions.dealershipId == "policeDealership" or spawnFollowUpActions.dealershipId == "poliziaAuto") then
      career_modules_inventory.setVehicleRole(inventoryId, "police")
    end
    if spawnFollowUpActions.policyId ~= nil then
      local policyId = tonumber(spawnFollowUpActions.policyId) or 0
      if career_modules_insurance and career_modules_insurance.changeVehPolicy then
        career_modules_insurance.changeVehPolicy(inventoryId, policyId)
      end
    end
    career_modules_inventory.moveVehicleToGarage(inventoryId, spawnFollowUpActions.targetGarageId)
    spawnFollowUpActions = nil
  end
end

-- Purchase and payment functions
local function payForVehicle()
  local label = string.format("Bought a vehicle: %s", purchaseData.vehicleInfo.niceName)
  if purchaseData.tradeInVehicleInfo then
    label = label .. string.format(" and traded in vehicle id %d: %s", purchaseData.tradeInVehicleInfo.id,
      purchaseData.tradeInVehicleInfo.niceName)
  end
  career_modules_playerAttributes.addAttributes({
    money = -purchaseData.prices.finalPrice
  }, {
    tags = {"vehicleBought", "buying"},
    label = label
  })
  Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
  vehicleWatchlist[purchaseData.shopId] = nil
end

local deleteAddedVehicle
local function buyVehicleAndSendToGarage(options)
  local canAfford = career_modules_cheats and career_modules_cheats.isCheatsMode() or career_modules_playerAttributes.getAttributeValue("money") >= purchaseData.prices.finalPrice
  if not canAfford or not career_modules_inventory.hasFreeSlot() then
    return
  end
  payForVehicle()

  -- Use the robust garage detection in inventory.lua which handles computer links and proximity
  local targetGarage = career_modules_inventory.getClosestOwnedGarageWithSpace() or career_modules_inventory.getClosestGarage()
  if not targetGarage then
    return
  end

  local garagePos, _ = freeroam_facilities.getGaragePosRot(targetGarage)
  local delay = 1
  if purchaseData.vehicleInfo.pos then
    delay = getDeliveryDelay(purchaseData.vehicleInfo.pos:distance(garagePos))
  end
  spawnFollowUpActions = {
    delayAccess = delay,
    targetGarageId = targetGarage.id,
    licensePlateText = options.licensePlateText,
    dealershipId = options.dealershipId,
    policyId = options.policyId
  }
  spawnVehicle(purchaseData.vehicleInfo)
  deleteAddedVehicle = true
end

local function buyVehicleAndSpawnInParkingSpot(options)
  local canAfford = career_modules_cheats and career_modules_cheats.isCheatsMode() or career_modules_playerAttributes.getAttributeValue("money") >= purchaseData.prices.finalPrice
  if not canAfford or not career_modules_inventory.hasFreeSlot() then
    return
  end
  payForVehicle()

  local targetGarage = career_modules_inventory.getClosestOwnedGarageWithSpace() or career_modules_inventory.getClosestGarage()

  spawnFollowUpActions = {
    targetGarageId = targetGarage and targetGarage.id or nil,
    licensePlateText = options.licensePlateText,
    dealershipId = options.dealershipId,
    policyId = options.policyId
  }
  local newVehObj = spawnVehicle(purchaseData.vehicleInfo, purchaseData.vehicleInfo.sellerId)
  if gameplay_walk.isWalking() then
    gameplay_walk.setRot(newVehObj:getPosition() - getPlayerVehicle(0):getPosition())
  end
end

-- TODO At this point, the part conditions of the previous vehicle should have already been saved. for example when entering the garage
local originComputerId
local function openShop(seller, _originComputerId, screenTag)
  if seller and isPoliceDealershipLocked(seller) then
    ui_message(getPoliceDealershipLockLabel(), 8, "Police", "info")
    return
  end

  currentSeller = seller
  originComputerId = _originComputerId

  if not career_modules_inspectVehicle.getSpawnedVehicleInfo() then
    updateVehicleList()
  end

  local sellerInfos = {}
  for id, vehicleInfo in ipairs(vehiclesInShop) do
    if vehicleInfo.pos then
      if vehicleInfo.sellerId ~= "private" then
        local sellerInfo = sellerInfos[vehicleInfo.sellerId]
        if sellerInfo then
          vehicleInfo.distance = sellerInfo.distance
          vehicleInfo.quickTravelPrice = sellerInfo.quicktravelPrice
        else
          local quicktravelPrice, distance = career_modules_quickTravel.getPriceForQuickTravel(vehicleInfo.pos)
          sellerInfos[vehicleInfo.sellerId] = {
            distance = distance,
            quicktravelPrice = quicktravelPrice
          }
          vehicleInfo.distance = distance
          vehicleInfo.quickTravelPrice = quicktravelPrice
        end
      else
        local quicktravelPrice, distance = career_modules_quickTravel.getPriceForQuickTravel(vehicleInfo.pos)
        vehicleInfo.distance = distance
        vehicleInfo.quickTravelPrice = quicktravelPrice
      end
    else
      vehicleInfo.distance = 0
    end
  end

  local computer
  if currentSeller then
    local dealership = freeroam_facilities.getFacility("dealership", currentSeller)
    local tetherPos
    if dealership then
      tetherPos = freeroam_facilities.getAverageDoorPositionForFacility(dealership)
    else
      for _, vehicleInfo in ipairs(vehiclesInShop) do
        if vehicleInfo.sellerId == currentSeller and vehicleInfo.pos then
          tetherPos = vehicleInfo.pos
          break
        end
      end
    end
    if tetherPos then
      tether = career_modules_tether.startSphereTether(tetherPos, tetherRange, M.endShopping)
    end
  elseif originComputerId then
    computer = freeroam_facilities.getFacility("computer", originComputerId)
    tether = career_modules_tether.startDoorTether(computer.doors[1], nil, M.endShopping)
  end

  guihooks.trigger('ChangeState', {
    state = 'vehicleShopping',
    params = {
      screenTag = screenTag,
      buyingAvailable = (not computer or computer.functions.vehicleShop) and "true" or "false",
      marketplaceAvailable = (career_career.hasBoughtStarterVehicle() and not currentSeller) and "true" or "false"
    }
  })
  extensions.hook("onVehicleShoppingMenuOpened", {
    seller = currentSeller
  })
end

local function navigateToDealership(dealershipId)
  if isPoliceDealershipLocked(dealershipId) then
    ui_message(getPoliceDealershipLockLabel(), 8, "Police", "info")
    return
  end

  local dealership = freeroam_facilities.getDealership(dealershipId)
  if not dealership then
    return
  end
  local pos = freeroam_facilities.getAverageDoorPositionForFacility(dealership)
  if not pos then
    return
  end
  navigateToPos(pos)
end

local function taxiToDealership(dealershipId)
  if isPoliceDealershipLocked(dealershipId) then
    ui_message(getPoliceDealershipLockLabel(), 8, "Police", "info")
    return
  end

  local dealership = freeroam_facilities.getDealership(dealershipId)
  if not dealership then
    return
  end
  local pos = freeroam_facilities.getAverageDoorPositionForFacility(dealership)
  if not pos then
    return
  end
  career_modules_quickTravel.quickTravelToPos(pos, true,
    string.format("Took a taxi to %s", dealership.name or "dealership"))
end

local function getTaxiPriceToDealership(dealershipId)
  if isPoliceDealershipLocked(dealershipId) then
    return 0
  end

  local dealership = freeroam_facilities.getDealership(dealershipId)
  if not dealership then
    log("W", "Career", "getTaxiPriceToDealership: Dealership not found: " .. tostring(dealershipId))
    return 0
  end
  local pos = freeroam_facilities.getAverageDoorPositionForFacility(dealership)
  if not pos then
    log("W", "Career", "getTaxiPriceToDealership: No position found for dealership: " .. tostring(dealershipId))
    return 0
  end

  local playerPos = getPlayerVehicle(0):getPosition()
  local distance = (pos - playerPos):length()

  local price, calcDistance = career_modules_quickTravel.getPriceForQuickTravel(pos)

  if (not price or price <= 0) and (calcDistance and calcDistance > 0) then
    local basePrice = 5
    local pricePerM = 0.08
    local est = basePrice + round(calcDistance * pricePerM * 100) / 100
    log("W", "Career",
      string.format("getTaxiPriceToDealership: fallback price used=%.2f (distance=%.2f)", est, calcDistance))
    price = est
  end

  return price * 5 or 0
end

local function endShopping()
  career_career.closeAllMenus()
  extensions.hook("onVehicleShoppingMenuClosed", {})
end

local function cancelShopping()
  if originComputerId then
    local computer = freeroam_facilities.getFacility("computer", originComputerId)
    career_modules_computer.openMenu(computer)
  else
    career_career.closeAllMenus()
  end
end

local function onShoppingMenuClosed()
  if tether then
    tether.remove = true
    tether = nil
  end
  inspectingVehicleShopId = nil
  purchaseMenuOpen = false
end

local function getVehiclesInShop()
  return vehiclesInShop
end

local removeNonUsedPlayerVehicles
local function removeUnusedPlayerVehicles()
  for inventoryId, vehId in pairs(career_modules_inventory.getMapInventoryIdToVehId()) do
    if inventoryId ~= career_modules_inventory.getCurrentVehicle() then
      career_modules_inventory.removeVehicleObject(inventoryId)
    end
  end
end

local function buySpawnedVehicle(buyVehicleOptions)
  local canAfford = career_modules_cheats and career_modules_cheats.isCheatsMode() or career_modules_playerAttributes.getAttributeValue("money") >= purchaseData.prices.finalPrice
  if canAfford and career_modules_inventory.hasFreeSlot() then
    local vehObj = getObjectByID(purchaseData.vehId)
    payForVehicle()
    local newInventoryId = career_modules_inventory.addVehicle(vehObj:getID())
    if buyVehicleOptions.licensePlateText then
      career_modules_inventory.setLicensePlateText(newInventoryId, buyVehicleOptions.licensePlateText)
    end
    if buyVehicleOptions.dealershipId == "policeDealership" then
      career_modules_inventory.setVehicleRole(newInventoryId, "police")
    end
    career_modules_inventory.storeVehicle(newInventoryId)
    removeNonUsedPlayerVehicles = true
    if be:getPlayerVehicleID(0) == vehObj:getID() then
      career_modules_inventory.enterVehicle(newInventoryId)
    end
  end
end

local function sendPurchaseDataToUi()
  local vehicleShopInfo = deepcopy(getVehicleInfoByShopId(purchaseData.shopId))
  if not vehicleShopInfo then
    log("E", "Career", "sendPurchaseDataToUi: Vehicle not found for shopId: " .. tostring(purchaseData.shopId))
    return
  end
  vehicleShopInfo.shopId = purchaseData.shopId
  vehicleShopInfo.niceName = vehicleShopInfo.Brand .. " " .. vehicleShopInfo.Name
  vehicleShopInfo.deliveryDelay = getDeliveryDelay(vehicleShopInfo.distance)
  applyPurchaseAdjustedMarketValue(vehicleShopInfo)
  vehicleShopInfo.Value = vehicleShopInfo.valueAdjusted or vehicleShopInfo.Value
  coerceVehiclePricingFields(vehicleShopInfo)
  purchaseData.vehicleInfo = vehicleShopInfo

  local tradeInValue = purchaseData.tradeInVehicleInfo and purchaseData.tradeInVehicleInfo.Value or 0
  local taxes = math.max((vehicleShopInfo.Value + vehicleShopInfo.fees - tradeInValue) * (vehicleShopInfo.tax or salesTax), 0)
  if vehicleShopInfo.sellerId == "discountedDealership" or vehicleShopInfo.sellerId == "joesJunkDealership" then
    taxes = 0
  end
  local finalPrice = vehicleShopInfo.Value + vehicleShopInfo.fees + taxes - tradeInValue
  purchaseData.prices = {fees = vehicleShopInfo.fees, taxes = taxes, finalPrice = finalPrice, customLicensePlate = customLicensePlatePrice}
  local spawnedVehicleInfo = career_modules_inspectVehicle.getSpawnedVehicleInfo()
  purchaseData.vehId = spawnedVehicleInfo and spawnedVehicleInfo.vehId

  -- Insurance options from v38
  if not purchaseData.insuranceId then
    if vehicleShopInfo.insuranceClass and vehicleShopInfo.insuranceClass.id then
      if career_modules_insurance_insurance and career_modules_insurance_insurance.getDefaultInsuranceForClassId then
        local defaultInsurance = career_modules_insurance_insurance.getDefaultInsuranceForClassId(vehicleShopInfo.insuranceClass.id)
        if defaultInsurance then
          purchaseData.insuranceId = defaultInsurance.id
        end
      end
    end
  end

  purchaseData.insuranceOptions = {
    insuranceId = purchaseData.insuranceId,
    shopId = purchaseData.shopId,
  }

  if purchaseData.insuranceId and purchaseData.insuranceId >= 0 then
    if career_modules_insurance_insurance and career_modules_insurance_insurance.getInsuranceDataById then
      local insuranceInfo = career_modules_insurance_insurance.getInsuranceDataById(purchaseData.insuranceId)
      if insuranceInfo then
        purchaseData.insuranceOptions.spendingReason = string.format("Insurance Policy: \"%s\"", insuranceInfo.name)
        if career_modules_insurance_insurance.calculateAddVehiclePrice then
          purchaseData.insuranceOptions.priceMoney = career_modules_insurance_insurance.calculateAddVehiclePrice(purchaseData.insuranceId, purchaseData.vehicleInfo.Value)
        end
      end
    end
  end

  local data = {
    vehicleInfo = purchaseData.vehicleInfo,
    playerMoney = career_modules_playerAttributes.getAttributeValue("money"),
    inventoryHasFreeSlot = career_modules_inventory.hasFreeSlot(),
    purchaseType = purchaseData.purchaseType,
    forceTradeIn = not career_modules_linearTutorial.getTutorialFlag("purchasedFirstCar") or nil,
    tradeInVehicleInfo = purchaseData.tradeInVehicleInfo,
    prices = purchaseData.prices,
    dealershipId = vehicleShopInfo.sellerId,
    alreadyDidTestDrive = career_modules_inspectVehicle.getDidTestDrive() or false,
    vehId = purchaseData.vehId,
    cheatsMode = career_modules_cheats and career_modules_cheats.isCheatsMode() or false,
    insuranceOptions = purchaseData.insuranceOptions
  }

  if not data.vehicleInfo.requiredInsurance then
    data.ownsRequiredInsurance = false
  else
    if career_modules_insurance and career_modules_insurance.getPlayerPolicyData then
      local playerInsuranceData = career_modules_insurance.getPlayerPolicyData()[data.vehicleInfo.requiredInsurance.id]
      if playerInsuranceData then
        data.ownsRequiredInsurance = playerInsuranceData.owned
      else
        data.ownsRequiredInsurance = false
      end
    else
      data.ownsRequiredInsurance = false
    end
  end

  local atDealership = (purchaseData.purchaseType == "instant" and currentSeller) or
                         (purchaseData.purchaseType == "inspect" and vehicleShopInfo.sellerId ~= "private")

  if atDealership then
    data.tradeInEnabled = true
  end

  if (atDealership or vehicleShopInfo.sellerId == "private") then
    data.locationSelectionEnabled = true
  end

  if not career_career.hasBoughtStarterVehicle() then
    data.forceNoDelivery = true
  end

  guihooks.trigger("vehiclePurchaseData", data)
end

local function updateInsuranceSelection(insuranceId)
  if purchaseData then
    purchaseData.insuranceId = insuranceId
    sendPurchaseDataToUi()
  end
end

local function onClientStartMission()
  vehiclesInShop = {}
end

local function onAddedVehiclePartsToInventory(inventoryId, newParts)
  local vehicle = career_modules_inventory.getVehicles()[inventoryId]

  vehicle.year = purchaseData and purchaseData.vehicleInfo.year or 1990

  vehicle.originalParts = {}
  local allSlotsInVehicle = {
    main = true
  }

  for partName, part in pairs(newParts) do
    part.year = vehicle.year
    vehicle.originalParts[part.containingSlot] = {
      name = part.name,
      value = part.value
    }

    if part.description.slotInfoUi then
      for slot, _ in pairs(part.description.slotInfoUi) do
        allSlotsInVehicle[slot] = true
      end
    end
  end

  vehicle.changedSlots = {}

  if deleteAddedVehicle then
    career_modules_inventory.removeVehicleObject(inventoryId)
    deleteAddedVehicle = nil
  end

  endShopping()

  extensions.hook("onVehicleAddedToInventory", {
    inventoryId = inventoryId,
    vehicleInfo = purchaseData and purchaseData.vehicleInfo,
    selectedPolicyId = purchaseData and purchaseData.selectedPolicyId,
    purchaseData = purchaseData
  })

  if career_career.isAutosaveEnabled() then
    career_saveSystem.saveCurrent()
  end
end

local function onEnterVehicleFinished()
  if removeNonUsedPlayerVehicles then
    removeNonUsedPlayerVehicles = nil
  end
end

local function startInspectionWorkitem(job, vehicleInfo, teleportToVehicle)
  ui_fadeScreen.start(0.5)
  job.sleep(1.0)
  guihooks.trigger("ChangeState","play")
  career_modules_inspectVehicle.startInspection(vehicleInfo, teleportToVehicle)
  job.sleep(0.5)
  ui_fadeScreen.stop(0.5)
  job.sleep(1.0)

  inspectingVehicleShopId = vehicleInfo.shopId

  extensions.hook("onVehicleShoppingVehicleShown", {
    vehicleInfo = vehicleInfo
  })
end

-- Navigation functions
local function navigateToPos(pos, shopId)
  core_groundMarkers.setPath(vec3(pos.x, pos.y, pos.z))
  guihooks.trigger('ChangeState', {
    state = 'play',
    params = {}
  })

  if shopId then
    local vehicleInfo = getVehicleInfoByShopId(shopId)
    if not vehicleInfo then
      log("E", "Career", "Failed to find vehicle for inspection with shopId: " .. tostring(shopId))
      return
    end
    core_jobsystem.create(startInspectionWorkitem, nil, vehicleInfo, false)
  end
end

local function showVehicle(shopId)
  local vehicleInfo = getVehicleInfoByShopId(shopId)
  if not vehicleInfo then
    log("E", "Career", "Failed to find vehicle for inspection with shopId: " .. tostring(shopId))
    return
  end
  core_jobsystem.create(startInspectionWorkitem, nil, vehicleInfo, true)
end

local function quickTravelToVehicle(shopId)
  if not shopId then
    log("E", "Career", "quickTravelToVehicle: shopId is nil")
    return
  end
  log("D", "Career", "quickTravelToVehicle called with shopId: " .. tostring(shopId) .. " (type: " .. type(shopId) .. ")")
  local vehicleInfo = getVehicleInfoByShopId(shopId)
  if not vehicleInfo then
    log("E", "Career", "Failed to find vehicle for quick travel with shopId: " .. tostring(shopId))
    log("D", "Career", "Vehicles in shop: " .. tableSize(vehiclesInShop))
    if tableSize(vehiclesInShop) > 0 then
      log("D", "Career", "Sample shopIds in vehiclesInShop:")
      for i = 1, math.min(5, #vehiclesInShop) do
        log("D", "Career", "  Vehicle " .. i .. ": shopId=" .. tostring(vehiclesInShop[i].shopId) .. " (type: " .. type(vehiclesInShop[i].shopId) .. ")")
      end
    end
    return
  end
  core_jobsystem.create(startInspectionWorkitem, nil, vehicleInfo, true)
end

local function openPurchaseMenu(purchaseType, shopId, insuranceId)
  vehicleWatchlist[shopId] = "unsold"
  guihooks.trigger('ChangeState', {
    state = 'vehiclePurchase',
    params = {}
  })

  log("D", "Career",
    "openPurchaseMenu called with purchaseType: " .. tostring(purchaseType) .. ", shopId: " .. tostring(shopId))

  if not purchaseType then
    log("E", "Career", "openPurchaseMenu: purchaseType is nil")
    return
  end

  if not shopId then
    log("E", "Career", "openPurchaseMenu: shopId is nil")
    return
  end

  local vehicle = getVehicleInfoByShopId(shopId)
  if not vehicle then
    log("E", "Career", "Failed to find vehicle for purchase with shopId: " .. tostring(shopId))
    if #vehiclesInShop > 0 then
      log("D", "Career", "Available vehicles in shop:")
      for i, v in ipairs(vehiclesInShop) do
        log("D", "Career", "  Vehicle " .. i .. ": shopId=" .. tostring(v.shopId) .. ", key=" .. tostring(v.key))
      end
    else
      log("E", "Career", "No vehicles available in shop")
    end
    return
  end

  local vehicleShopInfo = deepcopy(vehicle)
  vehicleShopInfo.niceName = vehicleShopInfo.Brand .. " " .. vehicleShopInfo.Name
  coerceVehiclePricingFields(vehicleShopInfo)

  local distance = vehicleShopInfo.distance
  if not distance or type(distance) ~= "number" then
    if vehicleShopInfo.pos then
      local qtPrice, dist = career_modules_quickTravel.getPriceForQuickTravel(vehicleShopInfo.pos)
      vehicleShopInfo.quickTravelPrice = vehicleShopInfo.quickTravelPrice or qtPrice
      distance = dist
    else
      distance = 0
    end
    vehicleShopInfo.distance = distance
  end
  vehicleShopInfo.deliveryDelay = getDeliveryDelay(distance)

  local tradeInValue = 0
  local taxes = math.max((vehicleShopInfo.Value + vehicleShopInfo.fees - tradeInValue) *
                           (vehicleShopInfo.tax or salesTax), 0)
  if vehicleShopInfo.sellerId == "discountedDealership" or vehicleShopInfo.sellerId == "joesJunkDealership" then
    taxes = 0
  end
  local finalPrice = vehicleShopInfo.Value + vehicleShopInfo.fees + taxes - tradeInValue

  purchaseData = {
    shopId = shopId,
    purchaseType = purchaseType,
    vehicleInfo = vehicleShopInfo,
    insuranceId = insuranceId,
    prices = {
      fees = vehicleShopInfo.fees,
      taxes = taxes,
      finalPrice = finalPrice,
      customLicensePlate = customLicensePlatePrice
    }
  }

  purchaseMenuOpen = true
  log("D", "Career", "Successfully opened purchase menu for vehicle: " .. tostring(shopId))
  extensions.hook("onVehicleShoppingPurchaseMenuOpened", {
    purchaseType = purchaseType,
    shopId = shopId
  })
end

local function buyFromPurchaseMenu(purchaseType, options)
  options = options or {}

  if not purchaseData then
    log("E", "Career", "buyFromPurchaseMenu: purchaseData is nil")
    return
  end
  if not purchaseData.vehicleInfo then
    log("E", "Career", "buyFromPurchaseMenu: purchaseData.vehicleInfo is nil")
    return
  end
  if not purchaseData.prices then
    log("W", "Career", "buyFromPurchaseMenu: purchaseData.prices is nil, calculating prices as fallback")
    local vehicleShopInfo = purchaseData.vehicleInfo
    coerceVehiclePricingFields(vehicleShopInfo)
    local tradeInValue = purchaseData.tradeInVehicleInfo and purchaseData.tradeInVehicleInfo.Value or 0
    local taxes = math.max((vehicleShopInfo.Value + vehicleShopInfo.fees - tradeInValue) *
                             (vehicleShopInfo.tax or salesTax), 0)
    if vehicleShopInfo.sellerId == "discountedDealership" or vehicleShopInfo.sellerId == "joesJunkDealership" then
      taxes = 0
    end
    local finalPrice = vehicleShopInfo.Value + vehicleShopInfo.fees + taxes - tradeInValue
    purchaseData.prices = {
      fees = vehicleShopInfo.fees,
      taxes = taxes,
      finalPrice = finalPrice,
      customLicensePlate = customLicensePlatePrice
    }
  end

  if purchaseData.tradeInVehicleInfo then
    career_modules_inventory.removeVehicle(purchaseData.tradeInVehicleInfo.id)
  end

  local orgId = purchaseData.vehicleInfo and purchaseData.vehicleInfo.associatedOrganization
  if not orgId then
    local dealershipId = options.dealershipId or (purchaseData.vehicleInfo and purchaseData.vehicleInfo.sellerId)
    if dealershipId and dealershipId ~= "private" then
      local dealership = freeroam_facilities.getDealership(dealershipId)
      if dealership and dealership.associatedOrganization then
        orgId = dealership.associatedOrganization
      end
    end
  end

  if orgId then
    local org = freeroam_organizations.getOrganization(orgId)
    if org then
      career_modules_playerAttributes.addAttributes({
        [orgId .. "Reputation"] = dealershipPurchaseReputationGain
      }, {
        tags = {"buying"},
        label = string.format("Bought vehicle from %s", orgId)
      })
    end
  end

  local selectedPolicyId = options.policyId or 0
  if options.purchaseInsurance and selectedPolicyId > 0 then
    if career_modules_insurance and career_modules_insurance.purchasePolicy then
      career_modules_insurance.purchasePolicy(selectedPolicyId)
    end
  end

  purchaseData.selectedPolicyId = selectedPolicyId
  local buyVehicleOptions = {
    licensePlateText = options.licensePlateText,
    dealershipId = options.dealershipId or (purchaseData.vehicleInfo and purchaseData.vehicleInfo.sellerId),
    policyId = selectedPolicyId
  }
  if purchaseType == "inspect" then
    if options.makeDelivery then
      deleteAddedVehicle = true
    end
    career_modules_inspectVehicle.buySpawnedVehicle(buyVehicleOptions)
  elseif purchaseType == "instant" then
    career_modules_inspectVehicle.showVehicle(nil)
    if options.makeDelivery then
      buyVehicleAndSendToGarage(buyVehicleOptions)
    else
      buyVehicleAndSpawnInParkingSpot(buyVehicleOptions)
    end
  end

  if options.licensePlateText then
    career_modules_playerAttributes.addAttributes({
      money = -purchaseData.prices.customLicensePlate
    }, {
      tags = {"buying"},
      label = string.format("Bought custom license plate for new vehicle")
    })
  end

  -- Remove the vehicle from the shop
  local targetShopId = tonumber(purchaseData.shopId) or purchaseData.shopId
  for i, vehInfo in ipairs(vehiclesInShop) do
    local vehShopId = tonumber(vehInfo.shopId) or vehInfo.shopId
    if vehShopId == targetShopId then
      vehInfo.markedSold = true
      vehInfo.soldViewCounter = 1
      pendingSoldShopIds[purchaseData.shopId] = true
      table.remove(vehiclesInShop, i)
      break
    end
  end

  purchaseMenuOpen = false
  inspectingVehicleShopId = nil

  if uiOpen then
    commitDelta(buildSnapshot())
    guihooks.trigger("vehicleShopDelta", lastDelta)
  end
end

local function cancelPurchase(purchaseType)
  purchaseMenuOpen = false
  if purchaseType == "inspect" then
    career_career.closeAllMenus()
  elseif purchaseType == "instant" then
    openShop(currentSeller, originComputerId)
  end
end

local function removeTradeInVehicle()
  purchaseData.tradeInVehicleInfo = nil
  sendPurchaseDataToUi()
end

local function openInventoryMenuForTradeIn()
  career_modules_inventory.openMenu({{
    callback = function(inventoryId)
      local vehicle = career_modules_inventory.getVehicles()[inventoryId]
      if vehicle then
        purchaseData.tradeInVehicleInfo = {
          id = inventoryId,
          niceName = vehicle.niceName,
          Value = career_modules_valueCalculator.getInventoryVehicleValue(inventoryId) *
            (career_modules_difficultyMode and career_modules_difficultyMode.isHardcoreMode and career_modules_difficultyMode.isHardcoreMode() and 0.33 or 0.66)
        }
        guihooks.trigger('UINavigation', 'back', 1)
      end
    end,
    buttonText = "Trade-In",
    repairRequired = true,
    ownedRequired = true
  }}, "Trade-In", {
    repairEnabled = false,
    sellEnabled = false,
    favoriteEnabled = false,
    storingEnabled = false,
    returnLoanerEnabled = false
  })
end

local function onExtensionLoaded()
  if not career_career.isActive() then
    return false
  end

  resetVehicleValidationState()
  cacheDealers()

  purchaseMenuOpen = false
  inspectingVehicleShopId = nil

  local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()
  if not saveSlot or not savePath then
    return
  end

  local saveInfo = savePath and jsonReadFile(savePath .. "/info.json")
  local outdated = not saveInfo or saveInfo.version < moduleVersion

  local data = not outdated and jsonReadFile(savePath .. "/career/vehicleShop.json")
  if data then
    local currentMap = getCurrentLevelIdentifier()
    vehicleWatchlist = data.vehicleWatchlist or {}

    -- New format with 'maps' key
    if data.maps then
      otherMapsData = data.maps
      for mapId, mapData in pairs(otherMapsData) do
        if mapData.vehiclesInShop then
          local sanitizedVehicles, loadSummary = sanitizeSavedVehicleEntries(mapData.vehiclesInShop,
            "load:" .. tostring(mapId))
          mapData.vehiclesInShop = sanitizedVehicles
          if loadSummary.raw > 0 then
            logVehicleSanitizationSummary("saved vehicle load " .. tostring(mapId), loadSummary)
          end
        end
      end
    else
      -- Migration from old flat format
      local oldVehicles = data.vehiclesInShop or {}
      local oldSellers = data.sellersInfos or {}
      local oldDirtyDate = data.dirtyDate

      for _, vehicleInfo in ipairs(oldVehicles) do
        local sanitizedVehicles, _ = sanitizeSavedVehicleEntries({vehicleInfo}, "load:migration")
        local sanitizedVehicle = sanitizedVehicles[1]
        if sanitizedVehicle then
          local mId = sanitizedVehicle.mapId or currentMap
          if not otherMapsData[mId] then otherMapsData[mId] = {vehiclesInShop = {}, sellersInfos = {}} end
          table.insert(otherMapsData[mId].vehiclesInShop, sanitizedVehicle)
        end
      end

      for sellerId, sellerInfo in pairs(oldSellers) do
        local mId = sellerInfo.mapId or currentMap
        if not otherMapsData[mId] then otherMapsData[mId] = {vehiclesInShop = {}, sellersInfos = {}} end
        otherMapsData[mId].sellersInfos[sellerId] = sellerInfo
      end
      
      -- Assign dirty date to the current map if it was migration
      if otherMapsData[currentMap] then
        otherMapsData[currentMap].dirtyDate = oldDirtyDate
      end
    end

    -- Set current map data
    local currentData = otherMapsData[currentMap] or {}
    local sanitizedVehicles, loadSummary = sanitizeSavedVehicleEntries(currentData.vehiclesInShop or {},
      "load:current:" .. tostring(currentMap))
    if loadSummary.raw > 0 then
      logVehicleSanitizationSummary("saved vehicle load current " .. tostring(currentMap), loadSummary)
    end
    currentData.vehiclesInShop = sanitizedVehicles
    vehiclesInShop = sanitizedVehicles
    sellersInfos = currentData.sellersInfos or {}
    vehicleShopDirtyDate = currentData.dirtyDate
    lastMap = currentMap
  end
end

local function onSaveCurrentSaveSlot(currentSavePath, oldSaveDate)
  local currentMap = getCurrentLevelIdentifier()
  
  -- Update the stash for the current map
  otherMapsData[currentMap] = {
    vehiclesInShop = vehiclesInShop,
    sellersInfos = sellersInfos,
    dirtyDate = vehicleShopDirtyDate
  }

  local data = {}
  data.maps = otherMapsData
  data.vehicleWatchlist = vehicleWatchlist
  data.version = moduleVersion
  
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/vehicleShop.json", data, true)
end

local function getCurrentSellerId()
  return currentSeller
end

local function onComputerAddFunctions(menuData, computerFunctions)
  local computerFunctionData = {
    id = "vehicleShop",
    label = "Vehicle Marketplace",
    callback = function()
      openShop(nil, menuData.computerFacility.id)
    end,
    order = 10
  }
  if menuData.tutorialPartShoppingActive or menuData.tutorialTuningActive then
    computerFunctionData.disabled = true
    computerFunctionData.reason = career_modules_computer.reasons.tutorialActive
  end
  local reason = career_modules_permissions.getStatusForTag("vehicleShopping")
  if not reason.allow then
    computerFunctionData.disabled = true
  end
  if reason.permission ~= "allowed" then
    computerFunctionData.reason = reason
  end

  computerFunctions.general[computerFunctionData.id] = computerFunctionData
end

local function onModActivated()
  resetVehicleValidationState()
  cacheDealers()
end

local function onWorldReadyState(state)
  if state == 2 then
    local currentMap = getCurrentLevelIdentifier()

    -- Stash previous map data if it exists
    if lastMap and lastMap ~= currentMap then
      otherMapsData[lastMap] = {
        vehiclesInShop = vehiclesInShop,
        sellersInfos = sellersInfos,
        dirtyDate = vehicleShopDirtyDate
      }
    end

    -- Load new map data
    if otherMapsData[currentMap] then
      local currentData = otherMapsData[currentMap]
      local sanitizedVehicles, loadSummary = sanitizeSavedVehicleEntries(currentData.vehiclesInShop or {},
        "onWorldReadyState:" .. tostring(currentMap))
      if loadSummary.raw > 0 then
        logVehicleSanitizationSummary("world load " .. tostring(currentMap), loadSummary)
      end
      currentData.vehiclesInShop = sanitizedVehicles
      vehiclesInShop = sanitizedVehicles
      sellersInfos = currentData.sellersInfos or {}
      vehicleShopDirtyDate = currentData.dirtyDate
    else
      -- If no data for this map, start fresh but keep watchlist
      vehiclesInShop = {}
      sellersInfos = {}
      vehicleShopDirtyDate = nil
    end

    lastMap = currentMap
    cacheDealers()
  end
end

-- Statistics and utility functions
local function getCacheStats()
  if not vehicleCache.cacheValid then
    return {
      valid = false,
      message = "Cache not initialized"
    }
  end

  local stats = {
    valid = true,
    cacheTime = vehicleCache.lastCacheTime,
    dealerships = {},
    totalVehicles = 0
  }

  for dealershipId, data in pairs(vehicleCache.dealershipCache) do
    local regularCount = data.regularVehicles and #data.regularVehicles or 0
    stats.dealerships[dealershipId] = {
      regularVehicles = regularCount,
      total = regularCount
    }
    stats.totalVehicles = stats.totalVehicles + regularCount
  end

  return stats
end

local function getMapStats()
  local stats = {
    currentMap = getCurrentLevelIdentifier(),
    vehiclesByMap = {},
    sellersByMap = {},
    totalVehicles = #vehiclesInShop,
    totalSellers = tableSize(sellersInfos)
  }

  for _, vehicleInfo in ipairs(vehiclesInShop) do
    local mapId = vehicleInfo.mapId or "unknown"
    stats.vehiclesByMap[mapId] = (stats.vehiclesByMap[mapId] or 0) + 1
  end

  for sellerId, sellerInfo in pairs(sellersInfos) do
    local mapId = sellerInfo.mapId or "unknown"
    stats.sellersByMap[mapId] = (stats.sellersByMap[mapId] or 0) + 1
  end

  return stats
end

local function clearDataFromOtherMaps(targetMap)
  targetMap = targetMap or getCurrentLevelIdentifier()

  local filteredVehicles = {}
  for _, vehicleInfo in ipairs(vehiclesInShop) do
    if vehicleInfo.mapId == targetMap then
      table.insert(filteredVehicles, vehicleInfo)
    end
  end
  local removedVehicles = #vehiclesInShop - #filteredVehicles
  vehiclesInShop = filteredVehicles

  local filteredSellers = {}
  local removedSellers = 0
  for sellerId, sellerInfo in pairs(sellersInfos) do
    if sellerInfo.mapId == targetMap then
      filteredSellers[sellerId] = sellerInfo
    else
      removedSellers = removedSellers + 1
    end
  end
  sellersInfos = filteredSellers

  return {
    vehiclesRemoved = removedVehicles,
    sellersRemoved = removedSellers
  }
end

-- Public API
M.openShop = openShop
M.showVehicle = showVehicle
M.navigateToPos = navigateToPos
M.navigateToDealership = navigateToDealership
M.taxiToDealership = taxiToDealership
M.getTaxiPriceToDealership = getTaxiPriceToDealership
M.buySpawnedVehicle = buySpawnedVehicle
M.quickTravelToVehicle = quickTravelToVehicle
M.updateVehicleList = updateVehicleList
M.getShoppingData = getShoppingData
M.sendPurchaseDataToUi = sendPurchaseDataToUi
M.getCurrentSellerId = getCurrentSellerId
M.getVisualValueFromMileage = getVisualValueFromMileage
M.invalidateVehicleCache = invalidateVehicleCache
M.getLastDelta = function()
  return lastDelta
end
M.setShoppingUiOpen = setShoppingUiOpen
M.getVehicleInfoByShopId = getVehicleInfoByShopId

M.openPurchaseMenu = openPurchaseMenu
M.updateInsuranceSelection = updateInsuranceSelection
M.buyFromPurchaseMenu = buyFromPurchaseMenu
M.openInventoryMenuForTradeIn = openInventoryMenuForTradeIn
M.removeTradeInVehicle = removeTradeInVehicle

M.endShopping = endShopping
M.cancelShopping = cancelShopping
M.cancelPurchase = cancelPurchase

M.getVehiclesInShop = getVehiclesInShop

M.onWorldReadyState = onWorldReadyState
M.onModActivated = onModActivated
M.onClientStartMission = onClientStartMission
M.onVehicleSpawnFinished = onVehicleSpawnFinished
M.onAddedVehiclePartsToInventory = onAddedVehiclePartsToInventory
M.onEnterVehicleFinished = onEnterVehicleFinished
M.onExtensionLoaded = onExtensionLoaded
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onShoppingMenuClosed = onShoppingMenuClosed
M.onComputerAddFunctions = onComputerAddFunctions
M.onUpdate = onUpdate
M.onUiChangedState = onUiChangedState

M.onVehicleInspectionFinished = function(shopId)
  if inspectingVehicleShopId == shopId then
    inspectingVehicleShopId = nil
    log("D", "Career", "Inspection finished for vehicle: " .. tostring(shopId))
  end
end

M.checkSpawnedVehicleStatus = function()
  local spawnedVehicleInfo = career_modules_inspectVehicle.getSpawnedVehicleInfo()
  if spawnedVehicleInfo and inspectingVehicleShopId and spawnedVehicleInfo.shopId == inspectingVehicleShopId then
    return true
  elseif inspectingVehicleShopId then
    log("D", "Career", "Clearing inspection state for vehicle: " .. tostring(inspectingVehicleShopId))
    inspectingVehicleShopId = nil
    return false
  end
  return false
end

M.cacheDealers = cacheDealers
M.rebuildDealershipCache = rebuildDealershipCache
M.getRandomVehicleFromCache = getRandomVehicleFromCache
M.getCacheStats = getCacheStats
M.getMapStats = getMapStats
M.clearDataFromOtherMaps = clearDataFromOtherMaps
M.getEligibleVehiclesWithoutDealershipVehicles = getEligibleVehiclesWithoutDealershipVehicles

return M
