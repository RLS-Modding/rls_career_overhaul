-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.dependencies =
  {'career_career', 'career_modules_inspectVehicle', 'util_configListGenerator', 'freeroam_organizations'}

local moduleVersion = 42
local jbeamIO = require('jbeam/io')

-- Configuration constants
local vehicleDeliveryDelay = 60
local vehicleOfferTimeToLive = 15 * 60
local dealershipTimeBetweenOffers = 1 * 60
local vehiclesPerDealership = vehicleOfferTimeToLive / dealershipTimeBetweenOffers
local salesTax = 0.07
local customLicensePlatePrice = 300
local refreshInterval = 5
local tetherRange = 4

-- Module state
local vehicleShopDirtyDate
local vehiclesInShop = {}
local sellersInfos = {}
local currentSeller
local purchaseData
local tether

-- Delta tracking system
local lastSnapshotByUid = {}
local lastDelta = {
  seq = 0,
  added = {},
  removed = {},
  sold = {},
  updated = {}
}
local deltaSeq = 0
local pendingSoldUids = {}
local soldVehicles = {} -- vehicles sold but still visible for 2 minutes
local uiOpen = false
local refreshAccumulator = 0

-- Vehicle cache system
local vehicleCache = {
  regularVehicles = {},
  dealershipCache = {},
  lastCacheTime = 0,
  cacheValid = false
}

local partsValueCache = {}

-- State tracking for hold logic
local purchaseMenuOpen = false
local inspectingVehicleUid = nil

-- Utility functions
local function makeUid(v)
  local sid = v.sellerId or ""
  local key = v.key or ""
  local gen = v.generationTime or 0
  return tostring(sid) .. "|" .. tostring(key) .. "|" .. tostring(gen)
end

local function findVehicleById(vehicleId)
  -- Support both UID and legacy shopId for backwards compatibility
  if type(vehicleId) == "number" then
    -- Legacy shopId lookup
    return vehiclesInShop[vehicleId]
  elseif type(vehicleId) == "string" then
    -- UID lookup
    for _, vehicle in ipairs(vehiclesInShop) do
      if vehicle.uid == vehicleId then
        return vehicle
      end
    end
  end
  return nil
end

local function sanitizeVehicleForUi(v)
  local t = {}
  -- Ensure uid and shopId are preserved
  t.uid = v.uid or makeUid(v)
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
  local newTable = {}
  for k, v in pairs(t) do
    newTable[tostring(k)] = v
  end
  return newTable
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

local function getOrgLevelData(org, offset)
  if not org then
    return nil
  end
  local repLevel = (org.reputation and org.reputation.level) or 0
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

-- Delta tracking functions
local function buildSnapshot()
  local snap = {}
  for _, veh in ipairs(vehiclesInShop) do
    veh.uid = veh.uid or makeUid(veh)
    snap[veh.uid] = veh
  end
  return snap
end

local function commitDelta(newSnap, justExpiredUids)
  justExpiredUids = justExpiredUids or {}
  local added, removed, sold, updated = {}, {}, {}, {}
  for uid, veh in pairs(newSnap) do
    if not lastSnapshotByUid[uid] then
      table.insert(added, sanitizeVehicleForUi(veh))
    end
  end
  for uid, veh in pairs(newSnap) do
    local prev = lastSnapshotByUid[uid]
    if prev and veh then
      -- Check if vehicle was just marked as sold (either by expiration or purchase)
      local wasMarkedSold = prev.markedSold == true
      local isMarkedSold = veh.markedSold == true
      local prevSold = (prev.soldViewCounter or 0)
      local currSold = (veh.soldViewCounter or 0)

      -- Always send update for vehicles that just expired
      if justExpiredUids[uid] or (isMarkedSold and not wasMarkedSold) or (currSold > prevSold) then
        local soldVeh = sanitizeVehicleForUi(veh)
        soldVeh.__sold = true
        table.insert(updated, soldVeh)
        if justExpiredUids[uid] then
        end
      end
    end
  end
  for uid, _ in pairs(lastSnapshotByUid) do
    if not newSnap[uid] then
      if pendingSoldUids[uid] then
        local prevVeh = lastSnapshotByUid[uid]
        if prevVeh then
          local soldVeh = sanitizeVehicleForUi(prevVeh)
          soldVeh.uid = uid
          soldVeh.__sold = true
          table.insert(sold, soldVeh)
        else
          table.insert(sold, uid)
        end
        pendingSoldUids[uid] = nil
      else
        table.insert(removed, uid)
      end
    end
  end
  lastSnapshotByUid = newSnap
  deltaSeq = deltaSeq + 1
  lastDelta = {
    seq = deltaSeq,
    added = added,
    removed = removed,
    sold = sold,
    updated = updated
  }
end

-- UI state management
local function setShoppingUiOpen(isOpen)
  uiOpen = not not isOpen
  refreshAccumulator = 0
  -- When UI opens, immediately refresh to ensure stock levels
  if uiOpen then
    M.updateVehicleList(false)
  end
end

local function onUpdate(dt)
  if not uiOpen then
    return
  end
  refreshAccumulator = refreshAccumulator + (dt or 0)
  -- Use faster refresh interval when UI is open to maintain stock levels
  local currentRefreshInterval = uiOpen and (refreshInterval * 0.5) or refreshInterval
  if refreshAccumulator >= currentRefreshInterval then
    refreshAccumulator = 0
    M.updateVehicleList(false)
  end

  -- Check and update spawned vehicle status
  M.checkSpawnedVehicleStatus()
end

-- Data access functions
local function getShoppingData()
  local data = {}

  -- Ensure all vehicles have UIDs before sending to UI
  for i, vehicle in ipairs(vehiclesInShop) do
    if not vehicle.uid then
      vehicle.uid = makeUid(vehicle)
    end
    -- Also ensure shopId is set for backwards compatibility
    vehicle.shopId = i
  end

  data.vehiclesInShop = convertKeysToStrings(vehiclesInShop)
  data.currentSeller = currentSeller
  if currentSeller then
    local dealership = freeroam_facilities.getDealership(currentSeller)
    data.currentSellerNiceName = dealership.name
  end
  data.playerAttributes = career_modules_playerAttributes.getAllAttributes()
  data.inventoryHasFreeSlot = career_modules_inventory.hasFreeSlot()
  data.numberOfFreeSlots = career_modules_inventory.getNumberOfFreeSlots()

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
  data.organizations = {}
  if facilities and facilities.dealerships then
    for _, d in ipairs(facilities.dealerships) do
      local orgId = d.associatedOrganization or d.associatedOrganization
      table.insert(data.dealerships, {
        id = d.id,
        name = d.name,
        description = d.description,
        preview = d.preview,
        hiddenFromDealerList = d.hiddenFromDealerList,
        associatedOrganization = d.associatedOrganization
      })

      if orgId and not data.organizations[orgId] then
        local org = freeroam_organizations.getOrganization(orgId)
        if org then
          local sanitizedOrg = {
            reputationLevels = {},
            reputation = {}
          }
          if org.reputation then
            sanitizedOrg.reputation.level = org.reputation.level or 0
            sanitizedOrg.reputation.levelIndex = (org.reputation.level or 0) + 2
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
          data.organizations[orgId] = sanitizedOrg
        end
      end
    end
  end

  -- Also expose private sellers metadata so UI can show preview images and text
  if facilities and facilities.privateSellers then
    for _, d in ipairs(facilities.privateSellers) do
      table.insert(data.dealerships, {
        id = d.id,
        name = d.name,
        description = d.description,
        preview = d.preview,
        hiddenFromDealerList = d.hiddenFromDealerList,
        associatedOrganization = d.associatedOrganization
      })
      -- private sellers usually have no associated organization; keep organizations map unchanged
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

  -- Ensure the final price is always an integer and at least 500
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
    configInfo.adjustedPopulation = configInfo.Population or 1
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

local function getVehiclePartsValue(modelName, configKey)
  if not modelName or not configKey then
    return 0
  end
  local cacheKey = tostring(modelName) .. "|" .. tostring(configKey)
  if partsValueCache[cacheKey] ~= nil then
    return partsValueCache[cacheKey]
  end
  local ioCtx = {
    preloadedDirs = {"/vehicles/" .. modelName .. "/"}
  }

  local pcPath = "vehicles/" .. modelName .. "/" .. configKey .. ".pc"
  local pcData = jsonReadFile(pcPath)

  if not pcData or not pcData.parts then
    log('E', 'vehicles', 'Unable to read PC file or no parts data: ' .. pcPath)
    return 0
  end

  local totalValue = 0
  local parts = jbeamIO.getAvailableParts(ioCtx)

  for slotName, partName in pairs(pcData.parts) do
    if partName and partName ~= "" then
      local partData = jbeamIO.getPart(ioCtx, partName)
      if partData and partData.information and partData.information.value then
        totalValue = totalValue + partData.information.value
      end
    end
  end

  partsValueCache[cacheKey] = totalValue
  return totalValue
end

local function doesVehiclePassFiltersList(vehicleInfo, filters)
  for filterName, parameters in pairs(filters) do
    if filterName == "Years" then
      local vehicleYears = vehicleInfo.Years or vehicleInfo.aggregates.Years
      if not vehicleYears then
        return false
      end
      if parameters.min and (vehicleYears.min < parameters.min) or parameters.max and
        (vehicleYears.min > parameters.max) then
        return false
      end
    elseif filterName ~= "Mileage" then
      if parameters.min or parameters.max then
        local value = vehicleInfo[filterName] or
                        (vehicleInfo.aggregates[filterName] and vehicleInfo.aggregates[filterName].min)
        if not value or type(value) ~= "number" then
          return false
        end
        if parameters.min and (value < parameters.min) or parameters.max and (value > parameters.max) then
          return false
        end
      else
        local passed = false
        for _, value in ipairs(parameters) do
          if vehicleInfo[filterName] == value or
            (vehicleInfo.aggregates[filterName] and vehicleInfo.aggregates[filterName][value]) then
            passed = true
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
  partsValueCache = {}
  local totalPartsCalculated = 0

  local regularEligibleVehicles = util_configListGenerator.getEligibleVehicles() or {}
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
            if doesVehiclePassFilter(vehicleInfo, filter) then
              local cachedVehicle = deepcopy(vehicleInfo)
              cachedVehicle.precomputedFilter = filter
              cachedVehicle.subFilterProbability = subProb
              cachedVehicle.cachedPartsValue = getVehiclePartsValue(vehicleInfo.model_key, vehicleInfo.key)
              totalPartsCalculated = totalPartsCalculated + 1
              table.insert(filteredRegular, cachedVehicle)
            end
          end
        end

        vehicleCache.dealershipCache[dealershipId] = vehicleCache.dealershipCache[dealershipId] or {}
        if tableIsEmpty(filteredRegular) then
          log("W", "Career", string.format("No vehicles matched filters for dealership %s; using fallback stock", dealershipId))
          filteredRegular = {}
          for _, vehicleInfo in ipairs(regularEligibleVehicles) do
            local fallbackVehicle = deepcopy(vehicleInfo)
            fallbackVehicle.precomputedFilter = nil
            fallbackVehicle.subFilterProbability = 1
            fallbackVehicle.cachedPartsValue = getVehiclePartsValue(fallbackVehicle.model_key, fallbackVehicle.key)
            totalPartsCalculated = totalPartsCalculated + 1
            table.insert(filteredRegular, fallbackVehicle)
          end
          filters = {}
        end
        vehicleCache.dealershipCache[dealershipId].regularVehicles = filteredRegular
        vehicleCache.dealershipCache[dealershipId].filters = filters

        log("D", "Career", string.format("Cached %d regular vehicles for dealership %s", #filteredRegular, dealershipId))
      end
    end
  end

  local privateVehicles = deepcopy(regularEligibleVehicles)
  for _, vehicleInfo in ipairs(privateVehicles) do
    vehicleInfo.cachedPartsValue = getVehiclePartsValue(vehicleInfo.model_key, vehicleInfo.key)
    totalPartsCalculated = totalPartsCalculated + 1
  end

  vehicleCache.dealershipCache["private"] = {
    regularVehicles = privateVehicles,
    filters = {{}}
  }

  vehicleCache.lastCacheTime = os.time()
  vehicleCache.cacheValid = true
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

  if tableIsEmpty(sourceVehicles) then
    log("W", "Career", "No cached vehicles available for seller: " .. tostring(sellerId))
    return {}
  end

  local selectedVehicles = {}
  local availableVehicles = deepcopy(sourceVehicles)

  for i = 1, math.min(count, #availableVehicles) do
    local totalWeight = 0
    for _, vehicle in ipairs(availableVehicles) do
      local pop = vehicle.adjustedPopulation or 1
      local prob = vehicle.subFilterProbability or 1
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
        local pop = vehicle.adjustedPopulation or 1
        local prob = vehicle.subFilterProbability or 1
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
end

-- Vehicle list management functions
local function updateVehicleList(fromScratch)
  vehicleShopDirtyDate = os.date("!%Y-%m-%dT%XZ")
  local sellers = {}
  local currentMap = getCurrentLevelIdentifier()

  if fromScratch then
    vehiclesInShop = {}
    sellersInfos = {}
  end

  local filteredVehiclesInShop = {}
  for i, vehicleInfo in ipairs(vehiclesInShop) do
    if vehicleInfo.mapId == currentMap then
      vehicleInfo.shopId = #filteredVehiclesInShop + 1
      table.insert(filteredVehiclesInShop, vehicleInfo)
    end
  end
  vehiclesInShop = filteredVehiclesInShop

  local filteredSellersInfos = {}
  for sellerId, sellerInfo in pairs(sellersInfos) do
    if sellerInfo.mapId == currentMap then
      filteredSellersInfos[sellerId] = sellerInfo
    end
  end
  sellersInfos = filteredSellersInfos

  if not vehicleCache.cacheValid then
    cacheDealers()
  end

  local facilitiesData = freeroam_facilities.getFacilities(getCurrentLevelIdentifier())
  if not facilitiesData then
    log("W", "Career", "No facilities data available for current map; skipping vehicle list update")
    return
  end
  local facilities = deepcopy(facilitiesData)

  if facilities.dealerships then
    for _, dealership in ipairs(facilities.dealerships) do
      table.insert(sellers, dealership)
    end
  end

  if facilities.privateSellers then
    for _, dealership in ipairs(facilities.privateSellers) do
      table.insert(sellers, dealership)
    end
  end
  table.sort(sellers, function(a, b)
    return a.id < b.id
  end)

  local currentTime = os.time()

  -- Track which vehicles are being marked as sold this update
  local justExpiredUids = {}

  for i = #vehiclesInShop, 1, -1 do
    local vehicleInfo = vehiclesInShop[i]
    local offerTime = currentTime - vehicleInfo.generationTime
    if offerTime > vehicleInfo.offerTTL then
      -- Check if vehicle should be held from being sold
      local spawnedVehicleInfo = career_modules_inspectVehicle.getSpawnedVehicleInfo()
      local isVehicleSpawned = spawnedVehicleInfo and
                                 (spawnedVehicleInfo.shopId == vehicleInfo.shopId or spawnedVehicleInfo.uid ==
                                   vehicleInfo.uid or (inspectingVehicleUid and inspectingVehicleUid == vehicleInfo.uid))
      local isVehicleInPurchase = purchaseData and purchaseData.vehicleInfo and
                                    (purchaseData.vehicleInfo.uid == vehicleInfo.uid or
                                      (purchaseData.uid and purchaseData.uid == vehicleInfo.uid))
      local isVehicleBeingInspected = inspectingVehicleUid == vehicleInfo.uid
      local isPurchaseMenuOpen = purchaseMenuOpen

      if not vehicleInfo.markedSold and
        (isVehicleSpawned or isVehicleInPurchase or isVehicleBeingInspected or isPurchaseMenuOpen) then
        -- Vehicle is actively being used - don't mark as sold, extend its life
        vehicleInfo.uid = vehicleInfo.uid or makeUid(vehicleInfo)
        vehicleInfo.offerTTL = vehicleOfferTimeToLive -- Reset the timer
        log("D", "Career",
          "Vehicle hold logic extended life of " .. tostring(vehicleInfo.uid) .. " (actively being used)")
      elseif not vehicleInfo.markedSold then
        -- Vehicle is not being used and not already marked as sold - mark it as sold
        vehicleInfo.uid = vehicleInfo.uid or makeUid(vehicleInfo)
        vehicleInfo.markedSold = true
        vehicleInfo.soldViewCounter = 1
        vehicleInfo.soldGraceUntil = currentTime + 120
        justExpiredUids[vehicleInfo.uid] = true
        log("D", "Career", "Vehicle marked as sold (hold logic check passed): " .. tostring(vehicleInfo.uid))
      else
        -- Log why vehicle was not marked as sold (already marked)
        log("D", "Career", "Vehicle already marked as sold: " .. tostring(vehicleInfo.uid))
      end
    elseif vehicleInfo.soldGraceUntil and currentTime >= vehicleInfo.soldGraceUntil then
      -- Grace period expired - now remove it
      table.remove(vehiclesInShop, i)
    end
  end

  for id, vehInfo in ipairs(vehiclesInShop) do
    vehInfo.shopId = id
  end

  for _, seller in ipairs(sellers) do
    if not sellersInfos[seller.id] then
      sellersInfos[seller.id] = {
        lastGenerationTime = 0,
        mapId = currentMap
      }
    end
    if fromScratch then
      sellersInfos[seller.id].lastGenerationTime = 0
    end

    local randomVehicleInfos = {}
    local currentVehicleCount = 0
    for _, vehicleInfo in ipairs(vehiclesInShop) do
      if vehicleInfo.sellerId == seller.id and not vehicleInfo.soldViewCounter then
        currentVehicleCount = currentVehicleCount + 1
      end
    end

    local maxStock = seller.stock or 10
    if seller.associatedOrganization then
      local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
      local level = getOrgLevelData(org)
      if level and level.stock then
        maxStock = level.stock
      end
    end
    local availableSlots = math.max(0, maxStock - currentVehicleCount)

    local numberOfVehiclesToGenerate = 0

    if fromScratch or sellersInfos[seller.id].lastGenerationTime == 0 then
      numberOfVehiclesToGenerate = availableSlots
      log("D", "Career",
        string.format("Initial stock fill for %s: generating %d vehicles", seller.id, numberOfVehiclesToGenerate))
    else
      local stockScalingFactor = math.max(1, maxStock / 10)
      local scaledTimeBetweenOffers = dealershipTimeBetweenOffers / stockScalingFactor

      -- If UI is open, be more aggressive with stock replenishment
      if uiOpen then
        scaledTimeBetweenOffers = scaledTimeBetweenOffers * 0.5 -- Generate twice as fast when UI is open
      end

      local timeBasedGeneration = math.floor((currentTime - sellersInfos[seller.id].lastGenerationTime) /
                                               scaledTimeBetweenOffers)

      local stockPercentage = currentVehicleCount / maxStock
      local minGenerationRate
      if stockPercentage < 0.5 then
        minGenerationRate = availableSlots
      elseif uiOpen and stockPercentage < 0.8 then
        -- When UI is open, ensure we maintain higher stock levels
        minGenerationRate = math.max(1, math.ceil(maxStock * 0.05))
      else
        minGenerationRate = 1
      end

      numberOfVehiclesToGenerate = math.min(math.max(timeBasedGeneration, minGenerationRate), availableSlots)

      -- Additional check: if we have no vehicles in stock, generate at least some vehicles
      if numberOfVehiclesToGenerate == 0 and currentVehicleCount == 0 and availableSlots > 0 then
        numberOfVehiclesToGenerate = math.min(math.ceil(maxStock * 0.3), availableSlots)
        log("D", "Career",
          string.format("No vehicles in stock for %s: generating %d vehicles", seller.id, numberOfVehiclesToGenerate))
      end

      -- Additional check: if UI is open and we have very low stock, generate at least 1 vehicle
      if uiOpen and numberOfVehiclesToGenerate == 0 and currentVehicleCount < maxStock * 0.3 and availableSlots > 0 then
        numberOfVehiclesToGenerate = 1
        log("D", "Career",
          string.format("UI open - emergency stock replenishment for %s: generating 1 vehicle", seller.id))
      end
    end

    randomVehicleInfos = getRandomVehicleFromCache(seller.id, numberOfVehiclesToGenerate)

    for i, randomVehicleInfo in ipairs(randomVehicleInfos) do
      randomVehicleInfo.generationTime = currentTime - ((i - 1) * dealershipTimeBetweenOffers)
      randomVehicleInfo.offerTTL = vehicleOfferTimeToLive

      randomVehicleInfo.sellerId = seller.id
      randomVehicleInfo.sellerName = seller.name

      local filter = randomVehicleInfo.precomputedFilter or seller.filter or {}
      if seller.associatedOrganization then
        local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
        local level = getOrgLevelData(org)
        if level and level.filter then
          filter = level.filter
        end
      end
      randomVehicleInfo.filter = filter

      local years = randomVehicleInfo.Years or randomVehicleInfo.aggregates.Years

      randomVehicleInfo.year = years and math.random(years.min, years.max) or 2023
      if filter.whiteList and filter.whiteList.Mileage then
        randomVehicleInfo.Mileage = randomGauss3() / 3 * (filter.whiteList.Mileage.max - filter.whiteList.Mileage.min) +
                                      filter.whiteList.Mileage.min
      else
        randomVehicleInfo.Mileage = 0
      end

      local totalPartsValue = randomVehicleInfo.cachedPartsValue or
                                (getVehiclePartsValue(randomVehicleInfo.model_key, randomVehicleInfo.key) or 0)
      totalPartsValue = math.floor(career_modules_valueCalculator.getDepreciatedPartValue(totalPartsValue,
        randomVehicleInfo.Mileage) * 1.081)
      local adjustedBaseValue = career_modules_valueCalculator.getAdjustedVehicleBaseValue(randomVehicleInfo.Value, {
        mileage = randomVehicleInfo.Mileage,
        age = 2025 - randomVehicleInfo.year
      })
      local baseValue = math.floor(math.max(adjustedBaseValue, totalPartsValue) / 1000) * 1000 -- Round to nearest thousand

      local range = seller.range
      if seller.associatedOrganization then
        local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
        local level = getOrgLevelData(org)
        if level and level.range then
          range = level.range
        end
      end
      randomVehicleInfo.Value = getRandomizedPrice(baseValue, range)
      randomVehicleInfo.shopId = tableSize(vehiclesInShop) + 1
      randomVehicleInfo.uid = makeUid(randomVehicleInfo) -- Set UID immediately when vehicle is created

      local fees = seller.fees or 0
      if seller.associatedOrganization then
        local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
        local level = getOrgLevelData(org)
        if level and level.fees then
          fees = level.fees
        end
      end
      randomVehicleInfo.fees = fees

      local tax = seller.salesTax or salesTax
      if seller.associatedOrganization then
        local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
        local level = getOrgLevelData(org)
        if level and level.tax then
          tax = level.tax
        end
      end
      randomVehicleInfo.tax = tax
      if seller.id == "private" then
        local parkingData = gameplay_parking.getParkingSpots()
        local parkingSpots = parkingData and parkingData.byName or {}
        local sizeMatches, allowedSpots = {}, {}
        for name, spot in pairs(parkingSpots) do
          local tags = (spot.customFields and spot.customFields.tags) or {}
          if not tags.notprivatesale then
            table.insert(allowedSpots, {
              name = name,
              spot = spot
            })
            if randomVehicleInfo.BoundingBox and randomVehicleInfo.BoundingBox[2] and spot.boxFits and
              spot:boxFits(randomVehicleInfo.BoundingBox[2][1], randomVehicleInfo.BoundingBox[2][2],
                randomVehicleInfo.BoundingBox[2][3]) then
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
            string.format("No parking spot available for private sale vehicle %s", tostring(randomVehicleInfo.uid)))
        end
      else
        local dealership = freeroam_facilities.getDealership(seller.id)
        randomVehicleInfo.pos = freeroam_facilities.getAverageDoorPositionForFacility(dealership)
      end

      local requiredInsurance =
        career_modules_insurance.getMinApplicablePolicyFromVehicleShoppingData(randomVehicleInfo)
      if requiredInsurance then
        randomVehicleInfo.requiredInsurance = requiredInsurance
      end

      randomVehicleInfo.mapId = currentMap

      vehiclesInShop[randomVehicleInfo.shopId] = randomVehicleInfo
    end
    if not tableIsEmpty(randomVehicleInfos) then
      sellersInfos[seller.id].lastGenerationTime = currentTime
    end
  end

  local newSnap = buildSnapshot()
  commitDelta(newSnap, justExpiredUids)
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
    career_modules_inventory.storeVehicle(inventoryId)
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
end

local deleteAddedVehicle
local function buyVehicleAndSendToGarage(options)
  if career_modules_playerAttributes.getAttributeValue("money") < purchaseData.prices.finalPrice or
    not career_modules_inventory.hasFreeSlot() then
    return
  end
  payForVehicle()

  local closestGarage = career_modules_inventory.getClosestGarage()
  local garagePos, _ = freeroam_facilities.getGaragePosRot(closestGarage)
  local delay = getDeliveryDelay(purchaseData.vehicleInfo.pos:distance(garagePos))
  spawnFollowUpActions = {
    delayAccess = delay,
    licensePlateText = options.licensePlateText,
    dealershipId = options.dealershipId,
    policyId = options.policyId
  }
  spawnVehicle(purchaseData.vehicleInfo)
  deleteAddedVehicle = true
end

local function buyVehicleAndSpawnInParkingSpot(options)
  if career_modules_playerAttributes.getAttributeValue("money") < purchaseData.prices.finalPrice or
    not career_modules_inventory.hasFreeSlot() then
    return
  end
  payForVehicle()
  spawnFollowUpActions = {
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
      -- For private dealerships that aren't facilities, use position of first vehicle
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
      buyingAvailable = not computer or not not computer.functions.vehicleShop,
      marketplaceAvailable = not currentSeller
    }
  })
  extensions.hook("onVehicleShoppingMenuOpened", {
    seller = currentSeller
  })
end

local function navigateToDealership(dealershipId)
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

  -- Fallback: if price is 0 but we have a distance, estimate using same constants as quickTravel
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
  -- Clear inspection state when shopping menu closes
  inspectingVehicleUid = nil
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
  if career_modules_playerAttributes.getAttributeValue("money") >= purchaseData.prices.finalPrice and
    career_modules_inventory.hasFreeSlot() then
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
  -- Use the stored vehicle info instead of looking up by potentially stale shopId
  local vehicleShopInfo = deepcopy(purchaseData.vehicleInfo)
  vehicleShopInfo.niceName = vehicleShopInfo.Brand .. " " .. vehicleShopInfo.Name
  do
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
  end
  -- Update vehicleInfo in purchaseData with the fresh copy
  purchaseData.vehicleInfo = vehicleShopInfo

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
  local spawnedVehicleInfo = career_modules_inspectVehicle.getSpawnedVehicleInfo()
  purchaseData.vehId = spawnedVehicleInfo and spawnedVehicleInfo.vehId

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
    vehId = purchaseData.vehId
  }

  if not data.vehicleInfo.requiredInsurance then
    data.ownsRequiredInsurance = false
  else
    local playerInsuranceData = career_modules_insurance.getPlayerPolicyData()[data.vehicleInfo.requiredInsurance.id]
    if playerInsuranceData then
      data.ownsRequiredInsurance = playerInsuranceData.owned
    else
      data.ownsRequiredInsurance = false
    end
  end

  local atDealership = (purchaseData.purchaseType == "instant" and currentSeller) or
                         (purchaseData.purchaseType == "inspect" and vehicleShopInfo.sellerId ~= "private")

  -- allow trade in only when at a dealership
  if atDealership then
    data.tradeInEnabled = true
  end

  -- allow location selection in all cases except when on the computer
  if (atDealership or vehicleShopInfo.sellerId == "private") then
    data.locationSelectionEnabled = true
  end

  guihooks.trigger("vehiclePurchaseData", data)
end

local function onClientStartMission()
  vehiclesInShop = {}
end

local function onAddedVehiclePartsToInventory(inventoryId, newParts)

  -- Update the vehicle parts with the actual parts that are installed (they differ from the pc file)
  local vehicle = career_modules_inventory.getVehicles()[inventoryId]

  -- set the year of the vehicle
  vehicle.year = purchaseData and purchaseData.vehicleInfo.year or 1990

  vehicle.originalParts = {}
  local allSlotsInVehicle = {
    main = true
  }

  for partName, part in pairs(newParts) do
    part.year = vehicle.year
    -- vehicle.config.parts[part.containingSlot] = part.name -- TODO removed with parts refactor. check if needed
    vehicle.originalParts[part.containingSlot] = {
      name = part.name,
      value = part.value
    }

    if part.description.slotInfoUi then
      for slot, _ in pairs(part.description.slotInfoUi) do
        allSlotsInVehicle[slot] = true
      end
    end
    -- Also check if we do the same for part shopping or part inventory or vehicle shopping
  end

  -- TODO removed with parts refactor. check if this is needed. depends on if there are slots in the data missing that contain a default part or if there are slots with some weird name like "none"

  -- remove old leftover slots that dont exist anymore
  --[[ local slotsToRemove = {}
  for slot, partName in pairs(vehicle.config.parts) do
    if not allSlotsInVehicle[slot] then
      slotsToRemove[slot] = true
    end
  end
  for slot, _ in pairs(slotsToRemove) do
    vehicle.config.parts[slot] = nil
  end

  -- every part that is now in "vehicle.config.parts", but not in "vehicle.originalParts" is either a part that no longer exists in the game or it is just some way to denote an empty slot (like "none")
  -- in both cases we change the slot to a unified ""
  for slot, partName in pairs(vehicle.config.parts) do
    if not vehicle.originalParts[slot] then
      vehicle.config.parts[slot] = ""
    end
  end ]]

  vehicle.changedSlots = {}

  if deleteAddedVehicle then
    -- Move vehicle to garage before removing the object
    local vehicleName = vehicle.niceName or vehicle.Name or "Unknown Vehicle"

    local moveSuccess = career_modules_inventory.moveVehicleToGarage(inventoryId)

    if moveSuccess then
      log("I", "Career", string.format("Vehicle '%s' successfully moved to garage", vehicleName))
    else
      log("W", "Career", string.format("Failed to move vehicle '%s' to garage - no available space found", vehicleName))
      -- Still proceed with removing the vehicle object, but notify the player
      ui_message(string.format("Warning: %s could not be moved to a garage. Please check your garage space.",
        vehicleName), 5, "vehicleInventory")
    end

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
    -- removeUnusedPlayerVehicles()
    removeNonUsedPlayerVehicles = nil
  end
end

local function startInspectionWorkitem(job, vehicleInfo, teleportToVehicle)
  ui_fadeScreen.start(0.5)
  job.sleep(1.0)
  career_modules_inspectVehicle.startInspection(vehicleInfo, teleportToVehicle)
  job.sleep(0.5)
  ui_fadeScreen.stop(0.5)
  job.sleep(1.0)

  -- Track that this vehicle is being inspected
  inspectingVehicleUid = vehicleInfo.uid

  -- notify other extensions
  extensions.hook("onVehicleShoppingVehicleShown", {
    vehicleInfo = vehicleInfo
  })
end

-- Navigation functions
local function navigateToPos(pos, vehicleId)
  core_groundMarkers.setPath(vec3(pos.x, pos.y, pos.z))
  guihooks.trigger('ChangeState', {
    state = 'play',
    params = {}
  })

  -- If vehicleId is provided, also spawn the vehicle for inspection
  if vehicleId then
    local vehicleInfo = findVehicleById(vehicleId)
    if not vehicleInfo then
      log("E", "Career", "Failed to find vehicle for inspection with vehicleId: " .. tostring(vehicleId))
      return
    end
    core_jobsystem.create(startInspectionWorkitem, nil, vehicleInfo, false)
  end
end

local function showVehicle(vehicleId)
  local vehicleInfo = findVehicleById(vehicleId)
  if not vehicleInfo then
    log("E", "Career", "Failed to find vehicle for inspection with vehicleId: " .. tostring(vehicleId))
    return
  end
  core_jobsystem.create(startInspectionWorkitem, nil, vehicleInfo, true)
end

local function quickTravelToVehicle(vehicleId)
  local vehicleInfo = findVehicleById(vehicleId)
  if not vehicleInfo then
    log("E", "Career", "Failed to find vehicle for quick travel with vehicleId: " .. tostring(vehicleId))
    return
  end
  core_jobsystem.create(startInspectionWorkitem, nil, vehicleInfo, true)
end

local function openPurchaseMenu(purchaseType, vehicleId)
  guihooks.trigger('ChangeState', {
    state = 'vehiclePurchase',
    params = {}
  })

  -- Debug logging to see what's being passed
  log("D", "Career",
    "openPurchaseMenu called with purchaseType: " .. tostring(purchaseType) .. ", vehicleId: " .. tostring(vehicleId))

  -- Validate inputs
  if not purchaseType then
    log("E", "Career", "openPurchaseMenu: purchaseType is nil")
    return
  end

  if not vehicleId or vehicleId == "" then
    log("E", "Career", "openPurchaseMenu: vehicleId is nil or empty")
    return
  end

  -- Find the vehicle using the new lookup function
  local vehicle = findVehicleById(vehicleId)
  if not vehicle then
    log("E", "Career", "Failed to find vehicle for purchase with vehicleId: " .. tostring(vehicleId))
    -- Try to find any vehicle as fallback (for debugging)
    if #vehiclesInShop > 0 then
      log("D", "Career", "Available vehicles in shop:")
      for i, v in ipairs(vehiclesInShop) do
        log("D", "Career", "  Vehicle " .. i .. ": uid=" .. tostring(v.uid) .. ", shopId=" .. tostring(v.shopId) ..
          ", key=" .. tostring(v.key))
      end
    else
      log("E", "Career", "No vehicles available in shop")
    end
    return
  end

  -- Always create/ensure UID exists
  local uid = vehicle.uid
  if not uid or uid == "" then
    uid = makeUid(vehicle)
    log("D", "Career", "Created new UID for vehicle: " .. tostring(uid))
  else
    log("D", "Career", "Using existing UID: " .. tostring(uid))
  end
  vehicle.uid = uid -- Ensure UID is set

  purchaseData = {
    vehicleId = vehicleId, -- Store the vehicleId used for lookup
    uid = uid,
    purchaseType = purchaseType,
    vehicleInfo = vehicle -- Store the vehicle info directly to avoid lookup issues
  }

  purchaseMenuOpen = true
  log("D", "Career", "Successfully opened purchase menu for vehicle: " .. tostring(uid))
  extensions.hook("onVehicleShoppingPurchaseMenuOpened", {
    purchaseType = purchaseType,
    vehicleId = vehicleId
  })
end

local function buyFromPurchaseMenu(purchaseType, options)
  if purchaseData.tradeInVehicleInfo then
    career_modules_inventory.removeVehicle(purchaseData.tradeInVehicleInfo.id)
  end
  if options.dealershipId ~= "private" then
    local dealership = freeroam_facilities.getFacility("dealership", options.dealershipId)
    if dealership and dealership.associatedOrganization then
      local orgId = dealership.associatedOrganization
      local org = freeroam_organizations.getOrganization(orgId)
      if org then
        career_modules_playerAttributes.addAttributes({
          [orgId .. "Reputation"] = 20
        }, {
          tags = {"buying"},
          label = string.format("Bought vehicle from %s", orgId)
        })
      else
      end
    end
  end

  -- Handle insurance purchase if requested
  local selectedPolicyId = options.policyId or 0
  if options.purchaseInsurance and selectedPolicyId > 0 then
    -- Purchase the insurance policy before buying the vehicle
    if career_modules_insurance and career_modules_insurance.purchasePolicy then
      career_modules_insurance.purchasePolicy(selectedPolicyId)
    end
  end

  -- Store the selected policy ID in purchaseData for use when vehicle is added to inventory
  purchaseData.selectedPolicyId = selectedPolicyId
  local buyVehicleOptions = {
    licensePlateText = options.licensePlateText,
    dealershipId = options.dealershipId,
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

  -- Mark the vehicle as sold first, then remove it
  -- Find the vehicle by the stored vehicleId to ensure we remove the correct one
  local vehicleToRemove = nil
  local vehicleIndex = nil

  -- First, try to find the vehicle using the stored vehicle info directly
  if purchaseData.vehicleInfo and purchaseData.vehicleInfo.uid then
    for i, vehicle in ipairs(vehiclesInShop) do
      if vehicle.uid == purchaseData.vehicleInfo.uid then
        vehicleToRemove = vehicle
        vehicleIndex = i
        break
      end
    end
  end

  -- Fallback: search by UID from purchaseData if direct lookup failed
  if not vehicleToRemove then
    for i, vehicle in ipairs(vehiclesInShop) do
      -- Check both UID and the original vehicleId for backwards compatibility
      if vehicle.uid == purchaseData.uid or (purchaseData.vehicleId and vehicle.uid == purchaseData.vehicleId) then
        vehicleToRemove = vehicle
        vehicleIndex = i
        break
      end
    end
  end

  if vehicleToRemove then
    vehicleToRemove.markedSold = true
    vehicleToRemove.soldViewCounter = 1
    -- Mark both UID and vehicleId as sold for backwards compatibility
    pendingSoldUids[purchaseData.uid] = true
    if purchaseData.vehicleId and purchaseData.vehicleId ~= purchaseData.uid then
      pendingSoldUids[purchaseData.vehicleId] = true
    end

    -- Remove the vehicle from the shop and update the other vehicles shopIds
    table.remove(vehiclesInShop, vehicleIndex)
    for id, vehInfo in ipairs(vehiclesInShop) do
      vehInfo.shopId = id
    end
  else
    -- Vehicle not found - this could happen if it was removed by updateVehicleList
    -- Log the issue but don't fail the purchase since the vehicle was already processed
    log("W", "Career", "Vehicle not found in shop during purchase completion (likely removed by update): " ..
      tostring(purchaseData.vehicleId or purchaseData.uid) ..
      ". Purchase will continue but vehicle removal from shop list was skipped.")

    -- Still mark as sold in pendingSoldUids to maintain consistency
    pendingSoldUids[purchaseData.uid] = true
    if purchaseData.vehicleId and purchaseData.vehicleId ~= purchaseData.uid then
      pendingSoldUids[purchaseData.vehicleId] = true
    end
  end
  purchaseMenuOpen = false
  inspectingVehicleUid = nil
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
            (career_modules_hardcore.isHardcoreMode() and 0.33 or 0.66)
        }
        guihooks.trigger('ChangeState', {
          state = 'vehiclePurchase',
          params = {}
        })
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
  }, function()
    guihooks.trigger('ChangeState', {
      state = 'vehiclePurchase',
      params = {}
    })
  end)
end

local function onExtensionLoaded()
  if not career_career.isActive() then
    return false
  end

  -- Initialize vehicle cache
  cacheDealers()

  -- Initialize state tracking
  purchaseMenuOpen = false
  inspectingVehicleUid = nil

  -- load from saveslot
  local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()
  if not saveSlot or not savePath then
    return
  end

  local saveInfo = savePath and jsonReadFile(savePath .. "/info.json")
  local outdated = not saveInfo or saveInfo.version < moduleVersion

  local data = not outdated and jsonReadFile(savePath .. "/career/vehicleShop.json")
  if data then
    local currentMap = getCurrentLevelIdentifier()
    vehiclesInShop = data.vehiclesInShop or {}
    sellersInfos = data.sellersInfos or {}
    vehicleShopDirtyDate = data.dirtyDate

    -- Filter vehicles to only current map and fix missing mapId
    local filteredVehicles = {}
    for _, vehicleInfo in ipairs(vehiclesInShop) do
      vehicleInfo.pos = vec3(vehicleInfo.pos)
      -- If mapId is missing (old save), assume it belongs to current map
      if not vehicleInfo.mapId then
        vehicleInfo.mapId = currentMap
      end
      -- Only keep vehicles from current map
      if vehicleInfo.mapId == currentMap then
        vehicleInfo.shopId = #filteredVehicles + 1
        -- Ensure UID is set for loaded vehicles
        vehicleInfo.uid = vehicleInfo.uid or makeUid(vehicleInfo)
        table.insert(filteredVehicles, vehicleInfo)
      end
    end
    vehiclesInShop = filteredVehicles

    -- Filter sellers to only current map and fix missing mapId  
    local filteredSellers = {}
    for sellerId, sellerInfo in pairs(sellersInfos) do
      -- If mapId is missing (old save), assume it belongs to current map
      if not sellerInfo.mapId then
        sellerInfo.mapId = currentMap
      end
      -- Only keep sellers from current map
      if sellerInfo.mapId == currentMap then
        filteredSellers[sellerId] = sellerInfo
      end
    end
    sellersInfos = filteredSellers
  end
end

local function onSaveCurrentSaveSlot(currentSavePath, oldSaveDate)
  if vehicleShopDirtyDate and oldSaveDate >= vehicleShopDirtyDate then
    return
  end
  local data = {}
  data.vehiclesInShop = vehiclesInShop
  data.sellersInfos = sellersInfos
  data.dirtyDate = vehicleShopDirtyDate
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
  -- tutorial active
  if menuData.tutorialPartShoppingActive or menuData.tutorialTuningActive then
    computerFunctionData.disabled = true
    computerFunctionData.reason = career_modules_computer.reasons.tutorialActive
  end
  -- generic gameplay reason
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
  cacheDealers()
end

local function onWorldReadyState(state)
  if state == 2 then
    local currentMap = getCurrentLevelIdentifier()
    local initialVehicleCount = #vehiclesInShop
    local initialSellerCount = tableSize(sellersInfos)

    -- Filter out vehicles and sellers from other maps when changing maps
    local filteredVehicles = {}
    for _, vehicleInfo in ipairs(vehiclesInShop) do
      if vehicleInfo.mapId == currentMap then
        vehicleInfo.shopId = #filteredVehicles + 1
        -- Ensure UID is set when filtering by map
        vehicleInfo.uid = vehicleInfo.uid or makeUid(vehicleInfo)
        table.insert(filteredVehicles, vehicleInfo)
      end
    end
    vehiclesInShop = filteredVehicles

    local filteredSellers = {}
    for sellerId, sellerInfo in pairs(sellersInfos) do
      if sellerInfo.mapId == currentMap then
        filteredSellers[sellerId] = sellerInfo
      end
    end
    sellersInfos = filteredSellers

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
      vehicleInfo.shopId = #filteredVehicles + 1
      -- Ensure UID is set when clearing data from other maps
      vehicleInfo.uid = vehicleInfo.uid or makeUid(vehicleInfo)
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

M.openPurchaseMenu = openPurchaseMenu
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

-- Add callback for when inspection ends
M.onVehicleInspectionFinished = function(vehicleUid)
  if inspectingVehicleUid == vehicleUid then
    inspectingVehicleUid = nil
    log("D", "Career", "Inspection finished for vehicle: " .. tostring(vehicleUid))
  end
end

-- Function to check if spawned vehicle still exists
M.checkSpawnedVehicleStatus = function()
  local spawnedVehicleInfo = career_modules_inspectVehicle.getSpawnedVehicleInfo()
  if spawnedVehicleInfo and inspectingVehicleUid and spawnedVehicleInfo.uid == inspectingVehicleUid then
    -- Vehicle is still spawned, keep tracking
    return true
  elseif inspectingVehicleUid then
    -- Vehicle is no longer spawned or inspection ended
    log("D", "Career", "Clearing inspection state for vehicle: " .. tostring(inspectingVehicleUid))
    inspectingVehicleUid = nil
    return false
  end
  return false
end

M.cacheDealers = cacheDealers
M.getRandomVehicleFromCache = getRandomVehicleFromCache
M.getCacheStats = getCacheStats
M.getMapStats = getMapStats
M.clearDataFromOtherMaps = clearDataFromOtherMaps

return M
