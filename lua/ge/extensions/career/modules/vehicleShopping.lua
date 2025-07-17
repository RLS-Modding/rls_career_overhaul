-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {'career_career', 'career_modules_inspectVehicle', 'util_configListGenerator'}

local moduleVersion = 42

local jbeamIO = require('jbeam/io')
local imgui = ui_imgui

local vehicleShopDirtyDate

local vehicleDeliveryDelay = 60
local vehicleOfferTimeToLive = 15 * 60
local dealershipTimeBetweenOffers = 1 * 60
local vehiclesPerDealership = vehicleOfferTimeToLive / dealershipTimeBetweenOffers
local salesTax = 0.07
local customLicensePlatePrice = 300

local starterVehicleMileages = {bx = 165746239, etki = 285817342, covet = 80174611}
local starterVehicleYears = {bx = 1990, etki = 1989, covet = 1989}

local vehiclesInShop = {}
local sellersInfos = {}
local currentSeller

local purchaseData

local tether
local tetherRange = 4 --meter

-- Vehicle cache system for performance optimization
local vehicleCache = {
  starterVehicles = {},
  regularVehicles = {},
  dealershipCache = {},
  lastCacheTime = 0,
  cacheValid = false
}

local function convertKeysToStrings(t)
  local newTable = {}
  for k,v in pairs(t) do
    newTable[tostring(k)] = v
  end
  return newTable
end

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

  return data
end

local function getRandomizedPrice(price, range)
  -- L is the lowest price (These are extreme cases)
  -- NL is the Normal lowest price
  -- NH is the Normal highest price
  -- H is the highest price (These are extreme cases)
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
  if rand <= 0.01 then
    local slope = (NL - L) / 0.01
    return (L + slope * rand) * price
  elseif rand <= 0.99 then
    local slope = (NH - NL) / 0.98
    return (NL + slope * (rand - 0.01)) * price
  else
    local slope = (H - NH) / 0.01
    return (NH + slope * (rand - 0.99)) * price
  end
end

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
  -- Create an IO context for the vehicle directory
  local ioCtx = {
      preloadedDirs = {"/vehicles/" .. modelName .. "/"}
  }
  
  -- Get the PC file content first
  local pcPath = "vehicles/" .. modelName .. "/" .. configKey .. ".pc"
  local pcData = jsonReadFile(pcPath)
  
  if not pcData or not pcData.parts then
      log('E', 'vehicles', 'Unable to read PC file or no parts data: ' .. pcPath)
      return 0
  end
  
  local totalValue = 0
  
  -- Get all available parts using jbeamIO
  local parts = jbeamIO.getAvailableParts(ioCtx)
  
  -- Iterate through each part in the PC file

  for slotName, partName in pairs(pcData.parts) do
      if partName and partName ~= "" then
          -- Get the part data using jbeamIO
          local partData = jbeamIO.getPart(ioCtx, partName)
          if partData and partData.information and partData.information.value then
              totalValue = totalValue + partData.information.value
          else
            log('I', 'vehicles', 'Unable to read part data or no value data: ' .. partName)
          end
      end
  end
  
  return totalValue
end

local function doesVehiclePassFiltersList(vehicleInfo, filters)
  for filterName, parameters in pairs(filters) do
    if filterName == "Years" then
      -- years, which have a min and max
      local vehicleYears = vehicleInfo.Years or vehicleInfo.aggregates.Years
      if not vehicleYears then return false end
      if parameters.min and (vehicleYears.min < parameters.min) or parameters.max and (vehicleYears.min > parameters.max) then
        return false
      end
    elseif filterName ~= "Mileage" then
      if parameters.min or parameters.max then
        -- generic number attribute
        local value = vehicleInfo[filterName] or (vehicleInfo.aggregates[filterName] and vehicleInfo.aggregates[filterName].min)
        if not value or type(value) ~= "number" then return false end
        if parameters.min and (value < parameters.min) or parameters.max and (value > parameters.max) then
          return false
        end
      else
        -- any other attribute that has a single value
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

local function cacheDealers()
  log("I", "Career", "Caching vehicle configurations for dealerships...")
  
  local startTime = os.clock()
  vehicleCache.cacheValid = false
  vehicleCache.dealershipCache = {}
  local totalPartsCalculated = 0
  
  -- Get base eligible vehicles (starter and regular)
  local starterEligibleVehicles = util_configListGenerator.getEligibleVehicles(true) -- allowAuxiliaryVehicles = true for starters
  local regularEligibleVehicles = util_configListGenerator.getEligibleVehicles()
  
  -- Normalize populations for both sets
  normalizePopulations(starterEligibleVehicles, 0.4)
  normalizePopulations(regularEligibleVehicles, 0.4)
  
  -- Cache the base vehicle sets
  vehicleCache.starterVehicles = starterEligibleVehicles
  vehicleCache.regularVehicles = regularEligibleVehicles
  
  -- Get all facilities and pre-cache filtered vehicles for each dealership type
  local facilities = freeroam_facilities.getFacilities(getCurrentLevelIdentifier())
  
  if facilities and facilities.dealerships then
    for _, dealership in ipairs(facilities.dealerships) do
      local dealershipId = dealership.id
      
      -- Cache starter vehicles for this dealership if it supports them
      if dealership.containsStarterVehicles then
        local starterFilter = {whiteList = {careerStarterVehicle = {true}}}
        local filteredStarters = {}
        
        for _, vehicleInfo in ipairs(starterEligibleVehicles) do
          if doesVehiclePassFilter(vehicleInfo, starterFilter) then
            -- Pre-calculate parts value during caching
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
      
      -- Cache regular vehicles for this dealership
      if dealership.filter or dealership.subFilters then
        local filteredRegular = {}
        local filters = {}
        
        -- Create aggregated filters like the original system
        if dealership.subFilters and not tableIsEmpty(dealership.subFilters) then
          for _, subFilter in ipairs(dealership.subFilters) do
            local aggregateFilter = deepcopy(dealership.filter or {})
            tableMergeRecursive(aggregateFilter, subFilter)
            table.insert(filters, aggregateFilter)
          end
        else
          table.insert(filters, dealership.filter or {})
        end
        
        -- Pre-filter vehicles for each filter combination
        for _, filter in ipairs(filters) do
          for _, vehicleInfo in ipairs(regularEligibleVehicles) do
            if doesVehiclePassFilter(vehicleInfo, filter) then
              -- Add the filter info to the vehicle for later use and pre-calculate parts value
              local cachedVehicle = deepcopy(vehicleInfo)
              cachedVehicle.precomputedFilter = filter
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
  
  -- Cache private seller vehicles (no specific filters, just use all regular vehicles)
  local privateVehicles = deepcopy(regularEligibleVehicles)
  for _, vehicleInfo in ipairs(privateVehicles) do
    vehicleInfo.cachedPartsValue = getVehiclePartsValue(vehicleInfo.model_key, vehicleInfo.key)
    totalPartsCalculated = totalPartsCalculated + 1
  end
  
  vehicleCache.dealershipCache["private"] = {
    regularVehicles = privateVehicles,
    filters = {{}} -- empty filter
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
    -- Use weighted selection based on adjustedPopulation
    local totalWeight = 0
    for _, vehicle in ipairs(availableVehicles) do
      totalWeight = totalWeight + (vehicle.adjustedPopulation or 1)
    end
    
    if totalWeight <= 0 then
      -- Fallback to random selection
      local randomIndex = math.random(#availableVehicles)
      table.insert(selectedVehicles, availableVehicles[randomIndex])
      table.remove(availableVehicles, randomIndex)
    else
      -- Weighted random selection
      local randomWeight = math.random() * totalWeight
      local currentWeight = 0
      
      for j, vehicle in ipairs(availableVehicles) do
        currentWeight = currentWeight + (vehicle.adjustedPopulation or 1)
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

local function updateVehicleList(fromScratch)
  vehicleShopDirtyDate = os.date("!%Y-%m-%dT%XZ")
  local sellers = {}
  local onlyStarterVehicles = not career_career.hasBoughtStarterVehicle()

  if fromScratch then
    vehiclesInShop = {}
  end

  -- if there are already vehicles in the shop, don't generate starter vehicles
  if onlyStarterVehicles and not tableIsEmpty(vehiclesInShop) then
    return
  end
  
  -- Ensure cache is valid
  if not vehicleCache.cacheValid then
    cacheDealers()
  end

  -- get the dealerships from the level
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

  -- remove vehicles that have expired
  for i = #vehiclesInShop, 1, -1 do
    local vehicleInfo = vehiclesInShop[i]
    local offerTime = currentTime - vehicleInfo.generationTime
    if offerTime > vehicleInfo.offerTTL then
      vehicleInfo.soldViewCounter = vehicleInfo.soldViewCounter or 0
      vehicleInfo.soldViewCounter = vehicleInfo.soldViewCounter + 1
      if vehicleInfo.soldViewCounter > 1 then
        table.remove(vehiclesInShop, i)
      end
    end
  end

  -- update the shopId for each vehicle that hasnt been removed
  for id, vehInfo in ipairs(vehiclesInShop) do
    vehInfo.shopId = id
  end

  for _, seller in ipairs(sellers) do
    if not sellersInfos[seller.id] then
      sellersInfos[seller.id] = {
        lastGenerationTime = 0,
      }
    end
    if fromScratch then
      sellersInfos[seller.id].lastGenerationTime = 0
    end

    local randomVehicleInfos = {}
    if onlyStarterVehicles then
      -- Use cached starter vehicles
      randomVehicleInfos = getRandomVehicleFromCache(seller.id, 3, true)
    else
      -- Count how many vehicles this seller already has in the shop (excluding sold ones)
      local currentVehicleCount = 0
      for _, vehicleInfo in ipairs(vehiclesInShop) do
        if vehicleInfo.sellerId == seller.id and not vehicleInfo.soldViewCounter then
          currentVehicleCount = currentVehicleCount + 1
        end
      end
      
      -- Calculate how many vehicles can be generated based on stock limit and time
      local maxStock = seller.stock or 10 -- fallback to 10 if no stock limit defined
      local availableSlots = math.max(0, maxStock - currentVehicleCount)
      
      local numberOfVehiclesToGenerate = 0
      
      if fromScratch or sellersInfos[seller.id].lastGenerationTime == 0 then
        -- Fill stock completely on first generation or from scratch
        numberOfVehiclesToGenerate = availableSlots
        log("D", "Career", string.format("Initial stock fill for %s: generating %d vehicles", seller.id, numberOfVehiclesToGenerate))
      else
        -- Scale restock speed based on dealership size (larger dealerships restock faster)
        local stockScalingFactor = math.max(1, maxStock / 10) -- Larger dealerships get faster restock
        local scaledTimeBetweenOffers = dealershipTimeBetweenOffers / stockScalingFactor
        
        local timeBasedGeneration = math.floor((currentTime - sellersInfos[seller.id].lastGenerationTime) / scaledTimeBetweenOffers)
        
        -- Ensure dealerships maintain at least 50% stock, generate more aggressively when stock is low
        local stockPercentage = currentVehicleCount / maxStock
        local minGenerationRate = 1
        if stockPercentage < 0.5 then
          minGenerationRate = math.ceil(maxStock * 0.1) -- Generate at least 10% of max stock when low
        end
        
        numberOfVehiclesToGenerate = math.min(math.max(timeBasedGeneration, minGenerationRate), availableSlots)
      end
  
      -- Use cached regular vehicles
      randomVehicleInfos = getRandomVehicleFromCache(seller.id, numberOfVehiclesToGenerate, false)
    end

    for i, randomVehicleInfo in ipairs(randomVehicleInfos) do
      -- Distribute generation times evenly between lastGenerationTime and currentTime
      randomVehicleInfo.generationTime = currentTime - ((i-1) * dealershipTimeBetweenOffers)
      randomVehicleInfo.offerTTL = vehicleOfferTimeToLive

      randomVehicleInfo.sellerId = seller.id
      randomVehicleInfo.sellerName = seller.name
      
      -- Use precomputed filter if available, otherwise use seller filter
      local filter = randomVehicleInfo.precomputedFilter or seller.filter or {}
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
        -- values for the starter vehicles
        randomVehicleInfo.year = starterVehicleYears[randomVehicleInfo.model_key]
        randomVehicleInfo.Mileage = starterVehicleMileages[randomVehicleInfo.model_key]
      end

      -- Use pre-calculated parts value from cache instead of recalculating
      local totalPartsValue = randomVehicleInfo.cachedPartsValue or (getVehiclePartsValue(randomVehicleInfo.model_key, randomVehicleInfo.key) or 0)
      totalPartsValue = career_modules_valueCalculator.getDepreciatedPartValue(totalPartsValue, randomVehicleInfo.Mileage) * 1.081
      local baseValue = math.max(career_modules_valueCalculator.getAdjustedVehicleBaseValue(randomVehicleInfo.Value, {mileage = randomVehicleInfo.Mileage, age = 2025 - randomVehicleInfo.year}), totalPartsValue)

      randomVehicleInfo.Value = getRandomizedPrice(baseValue, seller.range)
      randomVehicleInfo.shopId = tableSize(vehiclesInShop) + 1

      -- compute taxes and fees
      randomVehicleInfo.fees = seller.fees or 0
      randomVehicleInfo.tax = seller.salesTax or salesTax
      
      if seller.id == "private" then
        local parkingSpots = gameplay_parking.getParkingSpots().byName
        local parkingSpotNames = tableKeys(parkingSpots)

        -- get a random parking spot on the map
        -- TODO needs some error handling when there are no parking spots
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
      vehiclesInShop[randomVehicleInfo.shopId] = randomVehicleInfo
    end
    if not tableIsEmpty(randomVehicleInfos) then
      sellersInfos[seller.id].lastGenerationTime = currentTime
    end
  end

  log("I", "Career", "Vehicles in shop: " .. tableSize(vehiclesInShop))
end

local function moveVehicleToDealership(vehObj, dealershipId)
  local dealership = freeroam_facilities.getDealership(dealershipId)
  local parkingSpots = freeroam_facilities.getParkingSpotsForFacility(dealership)
  local parkingSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(vehObj:getID(), parkingSpots)
  parkingSpot:moveResetVehicleTo(vehObj:getID(), nil, nil, nil, nil, true)
end

local function getDeliveryDelay(distance)
  if distance < 500 then return 1 end
  return vehicleDeliveryDelay
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

local spawnFollowUpActions

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
    career_modules_inventory.storeVehicle(inventoryId)
    spawnFollowUpActions = nil
  end
end

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
  spawnFollowUpActions = {delayAccess = delay, licensePlateText = options.licensePlateText, dealershipId = options.dealershipId}
  spawnVehicle(purchaseData.vehicleInfo)
  deleteAddedVehicle = true
end

local function buyVehicleAndSpawnInParkingSpot(options)
  if career_modules_playerAttributes.getAttributeValue("money") < purchaseData.prices.finalPrice
  or not career_modules_inventory.hasFreeSlot() then
    return
  end
  payForVehicle()
  spawnFollowUpActions = {licensePlateText = options.licensePlateText, dealershipId = options.dealershipId}
  local newVehObj = spawnVehicle(purchaseData.vehicleInfo, purchaseData.vehicleInfo.sellerId)
  if gameplay_walk.isWalking() then
    gameplay_walk.setRot(newVehObj:getPosition() - getPlayerVehicle(0):getPosition())
  end
end

local function navigateToPos(pos)
  -- TODO this should better take vec3s directly
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
  local vehicleShopInfo = deepcopy(getVehiclesInShop()[purchaseData.shopId])
  vehicleShopInfo.shopId = purchaseData.shopId
  vehicleShopInfo.niceName = vehicleShopInfo.Brand .. " " .. vehicleShopInfo.Name
  vehicleShopInfo.deliveryDelay = getDeliveryDelay(vehicleShopInfo.distance)
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
  core_jobsystem.create(startInspectionWorkitem, nil, vehicleInfo)
end

local function quickTravelToVehicle(shopId)
  local vehicleInfo = vehiclesInShop[shopId]
  core_jobsystem.create(startInspectionWorkitem, nil, vehicleInfo, true)
end

local function openPurchaseMenu(purchaseType, shopId)
  guihooks.trigger('ChangeState', {state = 'vehiclePurchase', params = {}})
  purchaseData = {shopId = shopId, purchaseType = purchaseType}
  extensions.hook("onVehicleShoppingPurchaseMenuOpened", {purchaseType = purchaseType, shopId = shopId})
end

local function buyFromPurchaseMenu(purchaseType, options)
  if purchaseData.tradeInVehicleInfo then
    career_modules_inventory.removeVehicle(purchaseData.tradeInVehicleInfo.id)
  end

  local buyVehicleOptions = {licensePlateText = options.licensePlateText, dealershipId = options.dealershipId}
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

  -- remove the vehicle from the shop and update the other vehicles shopIds
  table.remove(vehiclesInShop, purchaseData.vehicleInfo.shopId)
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
    vehiclesInShop = data.vehiclesInShop or {}
    sellersInfos = data.sellersInfos or {}
    vehicleShopDirtyDate = data.dirtyDate

    for _, vehicleInfo in ipairs(vehiclesInShop) do
      vehicleInfo.pos = vec3(vehicleInfo.pos)
    end
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
    cacheDealers()
  end
end

M.openShop = openShop
M.showVehicle = showVehicle
M.navigateToPos = navigateToPos
M.buySpawnedVehicle = buySpawnedVehicle
M.quickTravelToVehicle = quickTravelToVehicle
M.updateVehicleList = updateVehicleList
M.getShoppingData = getShoppingData
M.sendPurchaseDataToUi = sendPurchaseDataToUi
M.getCurrentSellerId = getCurrentSellerId
M.getVisualValueFromMileage = getVisualValueFromMileage

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

M.cacheDealers = cacheDealers
M.getRandomVehicleFromCache = getRandomVehicleFromCache
M.getCacheStats = getCacheStats

return M