-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {'career_career', 'career_modules_inspectVehicle', 'util_configListGenerator', 'freeroam_organizations'}

local moduleVersion = 42
local jbeamIO = require('jbeam/io')
local imgui = ui_imgui

-- Configuration constants
local vehicleDeliveryDelay = 60
local vehicleOfferTimeToLive = 15 * 60
local dealershipTimeBetweenOffers = 1 * 60
local vehiclesPerDealership = vehicleOfferTimeToLive / dealershipTimeBetweenOffers
local salesTax = 0.07
local customLicensePlatePrice = 300
local refreshInterval = 5
local tetherRange = 4

-- Starter vehicle data
local starterVehicleMileages = {bx = 165746239, etki = 285817342, covet = 80174611}
local starterVehicleYears = {bx = 1990, etki = 1989, covet = 1989}

-- Module state
local vehicleShopDirtyDate
local vehiclesInShop = {}
local sellersInfos = {}
local currentSeller
local purchaseData
local tether

-- Delta tracking system
local lastSnapshotByUid = {}
local lastDelta = {seq = 0, added = {}, removed = {}, sold = {}, updated = {}}
local deltaSeq = 0
local pendingSoldUids = {}
local soldVehicles = {} -- vehicles sold but still visible for 2 minutes
local uiOpen = false
local refreshAccumulator = 0

-- Vehicle cache system
local vehicleCache = {
  starterVehicles = {},
  regularVehicles = {},
  dealershipCache = {},
  lastCacheTime = 0,
  cacheValid = false
}

-- Utility functions
local function makeUid(v)
  local sid = v.sellerId or ""
  local key = v.key or ""
  local gen = v.generationTime or 0
  return tostring(sid) .. "|" .. tostring(key) .. "|" .. tostring(gen)
end

local function sanitizeVehicleForUi(v)
  local t = {}
  for k, val in pairs(v) do
    local ty = type(val)
    if k == "pos" then
      if val and val.x then t.pos = {x = val.x, y = val.y, z = val.z} end
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
  for k,v in pairs(t) do
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
  if distance < 500 then return 1 end
  return vehicleDeliveryDelay
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
          log("I", "Career", string.format("Sending updated delta for expired vehicle: uid=%s, __sold=true", uid))
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
  lastDelta = {seq = deltaSeq, added = added, removed = removed, sold = sold, updated = updated}
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
  if not uiOpen then return end
  refreshAccumulator = refreshAccumulator + (dt or 0)
  -- Use faster refresh interval when UI is open to maintain stock levels
  local currentRefreshInterval = uiOpen and (refreshInterval * 0.5) or refreshInterval
  if refreshAccumulator >= currentRefreshInterval then
    refreshAccumulator = 0
    M.updateVehicleList(false)
  end
end

-- Data access functions
local function getShoppingData()
  local data = {}
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
        associatedOrganization = d.associatedOrganization,
      })

      if orgId and not data.organizations[orgId] then
        local org = freeroam_organizations.getOrganization(orgId)
        if org then
          local sanitizedOrg = {reputationLevels = {}, reputation = {level = (org.reputation and org.reputation.level - 1) or 0}}
          if org.reputationLevels then
            for idx, lvl in pairs(org.reputationLevels) do
              sanitizedOrg.reputationLevels[idx] = {hiddenFromDealerList = lvl and lvl.hiddenFromDealerList or nil}
            end
          end
          data.organizations[orgId] = sanitizedOrg
        end
      end
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
  if rand < 0 then rand = 0 end
  if rand > 1 then rand = 1 end

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

  -- Ensure the final price is always an integer (round to nearest thousand)
  return math.floor(finalPrice)
end

-- Vehicle filtering and processing functions
local function normalizePopulations(configs, scalingFactor)
  local sum = 0
  for _, configInfo in ipairs(configs) do
    configInfo.adjustedPopulation = configInfo.Population or 1
    sum = sum + configInfo.adjustedPopulation
  end
  local average = sum / tableSize(configs)
  for _, configInfo in ipairs(configs) do
    local distanceFromAverage = configInfo.adjustedPopulation - average
    configInfo.adjustedPopulation = round(configInfo.adjustedPopulation - scalingFactor * distanceFromAverage)
  end
end

local function getVehiclePartsValue(modelName, configKey)
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

  return totalValue
end

local function doesVehiclePassFiltersList(vehicleInfo, filters)
  for filterName, parameters in pairs(filters) do
    if filterName == "Years" then
      local vehicleYears = vehicleInfo.Years or vehicleInfo.aggregates.Years
      if not vehicleYears then return false end
      if parameters.min and (vehicleYears.min < parameters.min) or parameters.max and (vehicleYears.min > parameters.max) then
        return false
      end
    elseif filterName ~= "Mileage" then
      if parameters.min or parameters.max then
        local value = vehicleInfo[filterName] or (vehicleInfo.aggregates[filterName] and vehicleInfo.aggregates[filterName].min)
        if not value or type(value) ~= "number" then return false end
        if parameters.min and (value < parameters.min) or parameters.max and (value > parameters.max) then
          return false
        end
      else
        local passed = false
        for _, value in ipairs(parameters) do
          if vehicleInfo[filterName] == value or (vehicleInfo.aggregates[filterName] and vehicleInfo.aggregates[filterName][value]) then
            passed = true
          end
        end
        if not passed then return false end
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
  log("I", "Career", "Caching vehicle configurations for dealerships...")

  local startTime = os.clock()
  vehicleCache.cacheValid = false
  vehicleCache.dealershipCache = {}
  local totalPartsCalculated = 0

  local starterEligibleVehicles = util_configListGenerator.getEligibleVehicles(true)
  local regularEligibleVehicles = util_configListGenerator.getEligibleVehicles()

  normalizePopulations(starterEligibleVehicles, 0.4)
  normalizePopulations(regularEligibleVehicles, 0.4)

  vehicleCache.starterVehicles = starterEligibleVehicles
  vehicleCache.regularVehicles = regularEligibleVehicles

  local facilities = freeroam_facilities.getFacilities(getCurrentLevelIdentifier())

  if facilities and facilities.dealerships then
    for _, dealership in ipairs(facilities.dealerships) do
      local dealershipId = dealership.id

      if dealership.containsStarterVehicles then
        local starterFilter = {whiteList = {careerStarterVehicle = {true}}}
        local filteredStarters = {}

        for _, vehicleInfo in ipairs(starterEligibleVehicles) do
          if doesVehiclePassFilter(vehicleInfo, starterFilter) then
            local cachedVehicle = deepcopy(vehicleInfo)
            cachedVehicle.cachedPartsValue = getVehiclePartsValue(vehicleInfo.model_key, vehicleInfo.key)
            totalPartsCalculated = totalPartsCalculated + 1
            table.insert(filteredStarters, cachedVehicle)
          end
        end

        vehicleCache.dealershipCache[dealershipId] = vehicleCache.dealershipCache[dealershipId] or {}
        vehicleCache.dealershipCache[dealershipId].starterVehicles = filteredStarters

        log("D", "Career", string.format("Cached %d starter vehicles for dealership %s", #filteredStarters, dealershipId))
      end

      local filter = dealership.filter or {}
      if dealership.associatedOrganization then
        local org = freeroam_organizations.getOrganization(dealership.associatedOrganization)
        if org then
          local level = org.reputationLevels[org.reputation.level + 1]
          filter = level.filter or filter
        end
      end

      local subFilters = dealership.subFilters or {}
      if dealership.associatedOrganization then
        local org = freeroam_organizations.getOrganization(dealership.associatedOrganization)
        if org then
          local level = org.reputationLevels[org.reputation.level + 1]
          subFilters = level.subFilters or subFilters
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

  local endTime = os.clock()
  log("I", "Career", string.format("Vehicle cache completed in %.3f seconds. Cached %d dealership types with %d pre-calculated parts values.",
    endTime - startTime, tableSize(vehicleCache.dealershipCache), totalPartsCalculated))
end

local function getRandomVehicleFromCache(sellerId, count, isStarterVehicle)
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
  if isStarterVehicle and dealershipData.starterVehicles then
    sourceVehicles = dealershipData.starterVehicles
  else
    sourceVehicles = dealershipData.regularVehicles or {}
  end

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
  log("I", "Career", "Invalidating vehicle cache due to reputation level change")
  vehicleCache.cacheValid = false
end

-- Vehicle list management functions
local function updateVehicleList(fromScratch)
  vehicleShopDirtyDate = os.date("!%Y-%m-%dT%XZ")
  local sellers = {}
  local onlyStarterVehicles = not career_career.hasBoughtStarterVehicle()
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

  if onlyStarterVehicles and not tableIsEmpty(vehiclesInShop) then
    return
  end

  if not vehicleCache.cacheValid then
    cacheDealers()
  end

  local facilities = deepcopy(freeroam_facilities.getFacilities(getCurrentLevelIdentifier()))
  for _, dealership in ipairs(facilities.dealerships) do
    if onlyStarterVehicles then
      if dealership.containsStarterVehicles then
        table.insert(sellers, dealership)
      end
    else
      table.insert(sellers, dealership)
    end
  end

  if not onlyStarterVehicles then
    for _, dealership in ipairs(facilities.privateSellers) do
      table.insert(sellers, dealership)
    end
  end
  table.sort(sellers, function(a,b) return a.id < b.id end)

  local currentTime = os.time()

  -- Track which vehicles are being marked as sold this update
  local justExpiredUids = {}
  
  for i = #vehiclesInShop, 1, -1 do
    local vehicleInfo = vehiclesInShop[i]
    local offerTime = currentTime - vehicleInfo.generationTime
    if offerTime > vehicleInfo.offerTTL then
      if not vehicleInfo.markedSold then
        -- First time detecting expiration - mark as sold but keep in list
        vehicleInfo.uid = vehicleInfo.uid or makeUid(vehicleInfo)
        vehicleInfo.markedSold = true
        vehicleInfo.soldViewCounter = 1
        vehicleInfo.soldGraceUntil = currentTime + 120
        justExpiredUids[vehicleInfo.uid] = true
        log("I", "Career", string.format("Vehicle expired and marked as sold: %s (uid: %s)", vehicleInfo.niceName or vehicleInfo.Name or "unknown", vehicleInfo.uid))
      elseif vehicleInfo.soldGraceUntil and currentTime >= vehicleInfo.soldGraceUntil then
        -- Grace period expired - now remove it
        table.remove(vehiclesInShop, i)
      end
    end
  end

  for id, vehInfo in ipairs(vehiclesInShop) do
    vehInfo.shopId = id
  end

  for _, seller in ipairs(sellers) do
    if not sellersInfos[seller.id] then
      sellersInfos[seller.id] = {
        lastGenerationTime = 0,
        mapId = currentMap,
      }
    end
    if fromScratch then
      sellersInfos[seller.id].lastGenerationTime = 0
    end

    local randomVehicleInfos = {}
    if onlyStarterVehicles then
      randomVehicleInfos = getRandomVehicleFromCache(seller.id, 3, true)
    else
      local currentVehicleCount = 0
      for _, vehicleInfo in ipairs(vehiclesInShop) do
        if vehicleInfo.sellerId == seller.id and not vehicleInfo.soldViewCounter then
          currentVehicleCount = currentVehicleCount + 1
        end
      end

      local maxStock = seller.stock or 10
      if seller.associatedOrganization then
        local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
        if org then
          local level = org.reputationLevels[org.reputation.level + 2]
          maxStock = level.stock or maxStock
        end
      end
      local availableSlots = math.max(0, maxStock - currentVehicleCount)

      local numberOfVehiclesToGenerate = 0

      if fromScratch or sellersInfos[seller.id].lastGenerationTime == 0 then
        numberOfVehiclesToGenerate = availableSlots
        log("D", "Career", string.format("Initial stock fill for %s: generating %d vehicles", seller.id, numberOfVehiclesToGenerate))
      else
        local stockScalingFactor = math.max(1, maxStock / 10)
        local scaledTimeBetweenOffers = dealershipTimeBetweenOffers / stockScalingFactor

        -- If UI is open, be more aggressive with stock replenishment
        if uiOpen then
          scaledTimeBetweenOffers = scaledTimeBetweenOffers * 0.5  -- Generate twice as fast when UI is open
        end

        local timeBasedGeneration = math.floor((currentTime - sellersInfos[seller.id].lastGenerationTime) / scaledTimeBetweenOffers)

        local stockPercentage = currentVehicleCount / maxStock
        local minGenerationRate = 1
        if stockPercentage < 0.5 then
          minGenerationRate = math.ceil(maxStock * 0.1)
        elseif uiOpen and stockPercentage < 0.8 then
          -- When UI is open, ensure we maintain higher stock levels
          minGenerationRate = math.ceil(maxStock * 0.05)
        end

        numberOfVehiclesToGenerate = math.min(math.max(timeBasedGeneration, minGenerationRate), availableSlots)

        -- Additional check: if UI is open and we have very low stock, generate at least 1 vehicle
        if uiOpen and numberOfVehiclesToGenerate == 0 and currentVehicleCount < maxStock * 0.3 and availableSlots > 0 then
          numberOfVehiclesToGenerate = 1
          log("D", "Career", string.format("UI open - emergency stock replenishment for %s: generating 1 vehicle", seller.id))
        end
      end

      randomVehicleInfos = getRandomVehicleFromCache(seller.id, numberOfVehiclesToGenerate, false)
    end

    for i, randomVehicleInfo in ipairs(randomVehicleInfos) do
      randomVehicleInfo.generationTime = currentTime - ((i-1) * dealershipTimeBetweenOffers)
      randomVehicleInfo.offerTTL = vehicleOfferTimeToLive

      randomVehicleInfo.sellerId = seller.id
      randomVehicleInfo.sellerName = seller.name

      local filter = randomVehicleInfo.precomputedFilter or seller.filter or {}
      if seller.associatedOrganization then
        local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
        if org then
          local level = org.reputationLevels[org.reputation.level + 2]
          filter = level.filter or filter
        end
      end
      randomVehicleInfo.filter = filter

      local years = randomVehicleInfo.Years or randomVehicleInfo.aggregates.Years

      if not onlyStarterVehicles then
        randomVehicleInfo.year = years and math.random(years.min, years.max) or 2023
        if filter.whiteList and filter.whiteList.Mileage then
          randomVehicleInfo.Mileage = randomGauss3()/3 * (filter.whiteList.Mileage.max - filter.whiteList.Mileage.min) + filter.whiteList.Mileage.min
        else
          randomVehicleInfo.Mileage = 0
        end
      else
        randomVehicleInfo.year = starterVehicleYears[randomVehicleInfo.model_key]
        randomVehicleInfo.Mileage = starterVehicleMileages[randomVehicleInfo.model_key]
      end

      local totalPartsValue = randomVehicleInfo.cachedPartsValue or (getVehiclePartsValue(randomVehicleInfo.model_key, randomVehicleInfo.key) or 0)
      totalPartsValue = math.floor(career_modules_valueCalculator.getDepreciatedPartValue(totalPartsValue, randomVehicleInfo.Mileage) * 1.081)
      local adjustedBaseValue = career_modules_valueCalculator.getAdjustedVehicleBaseValue(randomVehicleInfo.Value, {mileage = randomVehicleInfo.Mileage, age = 2025 - randomVehicleInfo.year})
      local baseValue = math.floor(math.max(adjustedBaseValue, totalPartsValue) / 1000) * 1000  -- Round to nearest thousand

      local range = seller.range
      if seller.associatedOrganization then
        local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
        if org then
          local level = org.reputationLevels[org.reputation.level + 2]
          range = level.range or range
        end
      end
      randomVehicleInfo.Value = getRandomizedPrice(baseValue, range)
      randomVehicleInfo.shopId = tableSize(vehiclesInShop) + 1
      randomVehicleInfo.uid = makeUid(randomVehicleInfo) -- Set UID immediately when vehicle is created

      local fees = seller.fees or 0
      if seller.associatedOrganization then
        local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
        if org then
          local level = org.reputationLevels[org.reputation.level + 2]
          fees = level.fees or fees
        end
      end
      randomVehicleInfo.fees = fees

      local tax = seller.salesTax or salesTax
      if seller.associatedOrganization then
        local org = freeroam_organizations.getOrganization(seller.associatedOrganization)
        if org then
          local level = org.reputationLevels[org.reputation.level + 2]
          tax = level.tax or tax
        end
      end
      randomVehicleInfo.tax = tax
      if seller.id == "private" then
        local parkingSpots = gameplay_parking.getParkingSpots().byName
        local parkingSpotNames = tableKeys(parkingSpots)

        local parkingSpotName, parkingSpot
        if randomVehicleInfo.BoundingBox and randomVehicleInfo.BoundingBox[2] then
          repeat
            parkingSpotName = parkingSpotNames[math.random(tableSize(parkingSpotNames))]
            parkingSpot = parkingSpots[parkingSpotName]
          until not parkingSpot.customFields.tags.notprivatesale and parkingSpot:boxFits(randomVehicleInfo.BoundingBox[2][1], randomVehicleInfo.BoundingBox[2][2], randomVehicleInfo.BoundingBox[2][3])
        end

        if not parkingSpotName then
          repeat
            parkingSpotName = parkingSpotNames[math.random(tableSize(parkingSpotNames))]
            parkingSpot = parkingSpots[parkingSpotName]
          until not parkingSpot.customFields.tags.notprivatesale
        end

        randomVehicleInfo.parkingSpotName = parkingSpotName
        randomVehicleInfo.pos = parkingSpot.pos
      else
        local dealership = freeroam_facilities.getDealership(seller.id)
        randomVehicleInfo.pos = freeroam_facilities.getAverageDoorPositionForFacility(dealership)
      end

      local requiredInsurance = career_modules_insurance.getMinApplicablePolicyFromVehicleShoppingData(randomVehicleInfo)
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

  log("I", "Career", "Vehicles in shop: " .. tableSize(vehiclesInShop))
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
  if dealershipToMoveTo then moveVehicleToDealership(newVeh, dealershipToMoveTo) end
  core_vehicleBridge.executeAction(newVeh,'setIgnitionLevel', 0)

  newVeh:queueLuaCommand(string.format("partCondition.initConditions(nil, %d, nil, %f) obj:queueGameEngineLua('career_modules_vehicleShopping.onVehicleSpawnFinished(%d)')", vehicleInfo.Mileage, getVisualValueFromMileage(vehicleInfo.Mileage), newVeh:getID()))
  return newVeh
end

local function onVehicleSpawnFinished(vehId)
  local veh = getObjectByID(vehId)
  local inventoryId = career_modules_inventory.addVehicle(vehId)

  if spawnFollowUpActions then
    if spawnFollowUpActions.delayAccess then
      career_modules_inventory.delayVehicleAccess(inventoryId, spawnFollowUpActions.delayAccess, "bought")
    end
    if spawnFollowUpActions.licensePlateText then
      career_modules_inventory.setLicensePlateText(inventoryId, spawnFollowUpActions.licensePlateText)
    end
    if spawnFollowUpActions.dealershipId and (spawnFollowUpActions.dealershipId == "policeDealership" or spawnFollowUpActions.dealershipId == "poliziaAuto") then
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
    label = label .. string.format(" and traded in vehicle id %d: %s", purchaseData.tradeInVehicleInfo.id, purchaseData.tradeInVehicleInfo.niceName)
  end
  career_modules_playerAttributes.addAttributes({money=-purchaseData.prices.finalPrice}, {tags={"vehicleBought","buying"},label=label})
  Engine.Audio.playOnce('AudioGui','event:>UI>Career>Buy_01')
end

local deleteAddedVehicle
local function buyVehicleAndSendToGarage(options)
  if career_modules_playerAttributes.getAttributeValue("money") < purchaseData.prices.finalPrice
  or not career_modules_inventory.hasFreeSlot() then
    return
  end
  payForVehicle()

  local closestGarage = career_modules_inventory.getClosestGarage()
  local garagePos, _ = freeroam_facilities.getGaragePosRot(closestGarage)
  local delay = getDeliveryDelay(purchaseData.vehicleInfo.pos:distance(garagePos))
  spawnFollowUpActions = {delayAccess = delay, licensePlateText = options.licensePlateText, dealershipId = options.dealershipId, policyId = options.policyId}
  spawnVehicle(purchaseData.vehicleInfo)
  deleteAddedVehicle = true
end

local function buyVehicleAndSpawnInParkingSpot(options)
  if career_modules_playerAttributes.getAttributeValue("money") < purchaseData.prices.finalPrice
  or not career_modules_inventory.hasFreeSlot() then
    return
  end
  payForVehicle()
  spawnFollowUpActions = {licensePlateText = options.licensePlateText, dealershipId = options.dealershipId, policyId = options.policyId}
  local newVehObj = spawnVehicle(purchaseData.vehicleInfo, purchaseData.vehicleInfo.sellerId)
  if gameplay_walk.isWalking() then
    gameplay_walk.setRot(newVehObj:getPosition() - getPlayerVehicle(0):getPosition())
  end
end

-- Navigation functions
local function navigateToPos(pos)
  core_groundMarkers.setPath(vec3(pos.x, pos.y, pos.z))
  guihooks.trigger('ChangeState', {state = 'play', params = {}})
end

-- TODO At this point, the part conditions of the previous vehicle should have already been saved. for example when entering the garage
local originComputerId
local function openShop(seller, _originComputerId, screenTag)
  currentSeller = seller
  originComputerId = _originComputerId

  local currentTime = os.time()
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
          sellerInfos[vehicleInfo.sellerId] = {distance = distance, quicktravelPrice = quicktravelPrice}
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
    local tetherPos = freeroam_facilities.getAverageDoorPositionForFacility(freeroam_facilities.getFacility("dealership",currentSeller))
    tether = career_modules_tether.startSphereTether(tetherPos, tetherRange, M.endShopping)
  elseif originComputerId then
    computer = freeroam_facilities.getFacility("computer", originComputerId)
    tether = career_modules_tether.startDoorTether(computer.doors[1], nil, M.endShopping)
  end

  guihooks.trigger('ChangeState', {state = 'vehicleShopping', params = {screenTag = screenTag, buyingAvailable = not computer or not not computer.functions.vehicleShop, marketplaceAvailable = not currentSeller}})
  extensions.hook("onVehicleShoppingMenuOpened", {seller = currentSeller})
end

local function navigateToDealership(dealershipId)
  local dealership = freeroam_facilities.getDealership(dealershipId)
  if not dealership then return end
  local pos = freeroam_facilities.getAverageDoorPositionForFacility(dealership)
  if not pos then return end
  navigateToPos(pos)
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
  if tether then tether.remove = true tether = nil end
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
  if career_modules_playerAttributes.getAttributeValue("money") >= purchaseData.prices.finalPrice
  and career_modules_inventory.hasFreeSlot() then
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
  vehicleShopInfo.deliveryDelay = getDeliveryDelay(vehicleShopInfo.distance)
  -- Update vehicleInfo in purchaseData with the fresh copy
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

  local data = {
    vehicleInfo = purchaseData.vehicleInfo,
    playerMoney = career_modules_playerAttributes.getAttributeValue("money"),
    inventoryHasFreeSlot = career_modules_inventory.hasFreeSlot(),
    purchaseType = purchaseData.purchaseType,
    forceTradeIn = not career_modules_linearTutorial.getTutorialFlag("purchasedFirstCar") or nil,
    tradeInVehicleInfo = purchaseData.tradeInVehicleInfo,
    prices = purchaseData.prices,
    dealershipId = vehicleShopInfo.sellerId,
  }

  local playerInsuranceData = career_modules_insurance.getPlayerPolicyData()[data.vehicleInfo.requiredInsurance.id]
  if playerInsuranceData then
    data.ownsRequiredInsurance = playerInsuranceData.owned
  else
    data.ownsRequiredInsurance = false
  end

  local atDealership = (purchaseData.purchaseType == "instant" and currentSeller) or (purchaseData.purchaseType == "inspect" and vehicleShopInfo.sellerId ~= "private")

  -- allow trade in only when at a dealership
  if atDealership then
    data.tradeInEnabled = true
  end

  -- allow location selection in all cases except when on the computer
  if (atDealership or vehicleShopInfo.sellerId == "private") then
    data.locationSelectionEnabled = true
  end

  if not career_career.hasBoughtStarterVehicle() then
    data.forceNoDelivery = true
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
  local allSlotsInVehicle = {main = true}

  for partName, part in pairs(newParts) do
    part.year = vehicle.year
    --vehicle.config.parts[part.containingSlot] = part.name -- TODO removed with parts refactor. check if needed
    vehicle.originalParts[part.containingSlot] = {name = part.name, value = part.value}

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
    log("I", "Career", string.format("Moving purchased vehicle '%s' (ID: %d) to garage", vehicleName, inventoryId))

    local moveSuccess = career_modules_inventory.moveVehicleToGarage(inventoryId)

    if moveSuccess then
      log("I", "Career", string.format("Vehicle '%s' successfully moved to garage", vehicleName))
    else
      log("W", "Career", string.format("Failed to move vehicle '%s' to garage - no available space found", vehicleName))
      -- Still proceed with removing the vehicle object, but notify the player
      ui_message(string.format("Warning: %s could not be moved to a garage. Please check your garage space.", vehicleName), 5, "vehicleInventory")
    end

    career_modules_inventory.removeVehicleObject(inventoryId)
    deleteAddedVehicle = nil
  end

  endShopping()
  career_modules_inspectVehicle.setInspectScreen(false)

  extensions.hook("onVehicleAddedToInventory", {inventoryId = inventoryId, vehicleInfo = purchaseData and purchaseData.vehicleInfo})

  if career_career.isAutosaveEnabled() then
    career_saveSystem.saveCurrent()
  end
end

local function onEnterVehicleFinished()
  if removeNonUsedPlayerVehicles then
   --removeUnusedPlayerVehicles()
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

  --notify other extensions
  extensions.hook("onVehicleShoppingVehicleShown", {vehicleInfo = vehicleInfo})
end

local function showVehicle(shopId)
  local vehicleInfo = getVehiclesInShop()[shopId]
  if not vehicleInfo then
    log("E", "Career", "Failed to find vehicle for inspection with shopId: " .. tostring(shopId))
    return
  end
  core_jobsystem.create(startInspectionWorkitem, nil, vehicleInfo)
end

local function quickTravelToVehicle(shopId)
  local vehicleInfo = getVehiclesInShop()[shopId]
  if not vehicleInfo then
    log("E", "Career", "Failed to find vehicle for quick travel with shopId: " .. tostring(shopId))
    return
  end
  core_jobsystem.create(startInspectionWorkitem, nil, vehicleInfo, true)
end

local function openPurchaseMenu(purchaseType, shopId)
  guihooks.trigger('ChangeState', {state = 'vehiclePurchase', params = {}})

  -- Find the vehicle and store its unique UID instead of mutable shopId
  local vehicle = getVehiclesInShop()[shopId]
  if not vehicle then
    log("E", "Career", "Failed to find vehicle for purchase with shopId: " .. tostring(shopId))
    return
  end

  local uid = vehicle.uid or makeUid(vehicle)
  vehicle.uid = uid -- Ensure UID is set

  purchaseData = {
    shopId = shopId,
    uid = uid,
    purchaseType = purchaseType,
    vehicleInfo = vehicle -- Store the vehicle info directly to avoid lookup issues
  }
  extensions.hook("onVehicleShoppingPurchaseMenuOpened", {purchaseType = purchaseType, shopId = shopId})
end

local function buyFromPurchaseMenu(purchaseType, options)
  if purchaseData.tradeInVehicleInfo then
    career_modules_inventory.removeVehicle(purchaseData.tradeInVehicleInfo.id)
  end

  local dealership = freeroam_facilities.getFacility("dealership", options.dealershipId)
  if dealership and dealership.associatedOrganization then
    local orgId = dealership.associatedOrganization
    local org = freeroam_organizations.getOrganization(orgId)
    if org then
      career_modules_playerAttributes.addAttributes({[orgId .. "Reputation"] = 10}, {tags={"buying"}, label=string.format("Bought vehicle from %s", orgId)})
    end
  end

  local buyVehicleOptions = {licensePlateText = options.licensePlateText, dealershipId = options.dealershipId, policyId = options.policyId}
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
    career_modules_playerAttributes.addAttributes({money=-purchaseData.prices.customLicensePlate}, {tags={"buying"}, label=string.format("Bought custom license plate for new vehicle")})
  end

  -- Mark the vehicle as sold first, then remove it
  -- Find the vehicle by UID to ensure we remove the correct one
  local vehicleToRemove = nil
  local vehicleIndex = nil
  for i, vehicle in ipairs(vehiclesInShop) do
    if vehicle.uid == purchaseData.uid then
      vehicleToRemove = vehicle
      vehicleIndex = i
      break
    end
  end

  if vehicleToRemove then
    vehicleToRemove.markedSold = true
    vehicleToRemove.soldViewCounter = 1
    pendingSoldUids[purchaseData.uid] = true
  else
    log("E", "Career", "Could not find vehicle to remove with UID: " .. tostring(purchaseData.uid))
    return
  end

  -- Remove the vehicle from the shop and update the other vehicles shopIds
  table.remove(vehiclesInShop, vehicleIndex)
  for id, vehInfo in ipairs(vehiclesInShop) do
    vehInfo.shopId = id
  end
end

local function cancelPurchase(purchaseType)
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
  career_modules_inventory.openMenu(
    {{
      callback = function(inventoryId)
        local vehicle = career_modules_inventory.getVehicles()[inventoryId]
        if vehicle then
          purchaseData.tradeInVehicleInfo = {id = inventoryId, niceName = vehicle.niceName, Value = career_modules_valueCalculator.getInventoryVehicleValue(inventoryId) * (career_modules_hardcore.isHardcoreMode() and 0.33 or 0.66)}
          guihooks.trigger('ChangeState', {state = 'vehiclePurchase', params = {}})
        end
      end,
      buttonText = "Trade-In",
      repairRequired = true,
      ownedRequired = true,
    }}, "Trade-In",
    {
      repairEnabled = false,
      sellEnabled = false,
      favoriteEnabled = false,
      storingEnabled = false,
      returnLoanerEnabled = false
    },
    function()
      guihooks.trigger('ChangeState', {state = 'vehiclePurchase', params = {}})
    end
  )
end

local function onExtensionLoaded()
  if not career_career.isActive() then return false end

  -- Initialize vehicle cache
  cacheDealers()

  -- load from saveslot
  local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()
  if not saveSlot or not savePath then return end

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
  if vehicleShopDirtyDate and oldSaveDate >= vehicleShopDirtyDate then return end
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
    callback = function() openShop(nil, menuData.computerFacility.id) end,
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
    
    local filteredVehicleCount = #vehiclesInShop
    local filteredSellerCount = tableSize(sellersInfos)
    
    if initialVehicleCount > filteredVehicleCount or initialSellerCount > filteredSellerCount then
      log("I", "Career", string.format("Map changed to %s: filtered %d vehicles (%d->%d) and %d sellers (%d->%d)", 
        currentMap, 
        initialVehicleCount - filteredVehicleCount, initialVehicleCount, filteredVehicleCount,
        initialSellerCount - filteredSellerCount, initialSellerCount, filteredSellerCount))
    end
    
    cacheDealers()
  end
end

-- Statistics and utility functions
local function getCacheStats()
  if not vehicleCache.cacheValid then
    return {valid = false, message = "Cache not initialized"}
  end

  local stats = {
    valid = true,
    cacheTime = vehicleCache.lastCacheTime,
    dealerships = {},
    totalVehicles = 0
  }

  for dealershipId, data in pairs(vehicleCache.dealershipCache) do
    local dealershipStats = {
      starterVehicles = data.starterVehicles and #data.starterVehicles or 0,
      regularVehicles = data.regularVehicles and #data.regularVehicles or 0
    }
    dealershipStats.total = dealershipStats.starterVehicles + dealershipStats.regularVehicles
    stats.dealerships[dealershipId] = dealershipStats
    stats.totalVehicles = stats.totalVehicles + dealershipStats.total
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

  log("I", "Career", string.format("Cleared %d vehicles and %d sellers from other maps. Current map: %s", removedVehicles, removedSellers, targetMap))

  return {vehiclesRemoved = removedVehicles, sellersRemoved = removedSellers}
end

-- Public API
M.openShop = openShop
M.showVehicle = showVehicle
M.navigateToPos = navigateToPos
M.navigateToDealership = navigateToDealership
M.buySpawnedVehicle = buySpawnedVehicle
M.quickTravelToVehicle = quickTravelToVehicle
M.updateVehicleList = updateVehicleList
M.getShoppingData = getShoppingData
M.sendPurchaseDataToUi = sendPurchaseDataToUi
M.getCurrentSellerId = getCurrentSellerId
M.getVisualValueFromMileage = getVisualValueFromMileage
M.invalidateVehicleCache = invalidateVehicleCache
M.getLastDelta = function() return lastDelta end
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

M.cacheDealers = cacheDealers
M.getRandomVehicleFromCache = getRandomVehicleFromCache
M.getCacheStats = getCacheStats
M.getMapStats = getMapStats
M.clearDataFromOtherMaps = clearDataFromOtherMaps

return M