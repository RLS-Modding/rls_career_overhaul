-- Food delivery offers, driving quality, ratings and completion rewards.
-- Read config and state, location and fare helpers, completion, update, lifecycle and public hooks.
local M = {}
local shared = {}
local parts = {}
M.dependencies = {
  'overhaul_world_facilities'
}

local core_groundMarkers = require('core/groundMarkers')
local phoneLayout = require('overhaul/lib/phone/layoutOwner')
local configRules = require('overhaul/jobs/beamEats/config')
local logisticsXPConfig = require('overhaul/lib/logistics/xpConfig')
local statePush = require('overhaul/lib/ui/statePush')
local saveStore = require('overhaul/lib/save/store')
local sitesManager = require('overhaul/lib/world/sitesManager').sitesManager
local levelData = require('overhaul/lib/world/levelData')

-- Config ------------------------------------------------------------------------------------------

M.config = {
  roughEventThreshold = 1.2,
  tipTiers = {
    { maxEvents = 0, percent = 0.55 },
    { maxEvents = 5, percent = 0.40 },
    { maxEvents = 10, percent = 0.22 },
    { maxEvents = 20, percent = 0.08 }
  },

  averageSpeedMPS = 16,

  bonusPerSecondEarly = 100,
  penaltyPerSecondLate = 0,
  onTimeBonusPercent = 0.13,

  baseFarePerKm = 105,
  zeroTipChance = 0.03,
  hugeTipChance = 0.08,
  stopVelocityThreshold = 0.5,
  pickupDropoffDuration = 3.0,
  pickupDropoffTimeBuffer = 6, -- Seconds added to expected time for pickup/dropoff actions

  streakMultiplierPerLevel = 0.03,
  streakMultiplierMax = 1.0,

  maxRatingBonus = 0.9,
  logisticsMultCap = 0.75,

  intervalMinRating = {min = 40, max = 60},
  intervalMaxRating = {min = 1, max = 3},

  ratingDampeningCount = 4,

  roughEventRatingPenalty = 0.25,
  lateDeliveryRatingPenalty = 0.45,
  onTimeRatingBonus = 0.35,
  ratingPullTowardFive = 0.18,

  baseDeliveryRadius = 1000, -- meters at 0 stars
  radiusStep = 100, -- meters increase per ratingStep
  radiusStepRatingInterval = 0.3, -- rating interval for radius increase

  minDeliveryAirDistance = 600,
  localRestaurantPoolSize = 3,
  recentRestaurantCooldown = 2,
  longHaulChanceMin = 0.18,
  longHaulChancePerRating = 0.03, -- +3% per star, ~0.33 at 5*
  dropoffExpandStep = 500,
  localDropoffMaxCap = 3500,
  longHaulDropoffStartMin = 2000,
  longHaulDropoffMaxCap = 8000,
  dropoffRoadCheckAttempts = 15,
  dropoffRoadDistanceFactor = 2.0,
  restaurantPickAttempts = 6,
}

local config = M.config

-- State -------------------------------------------------------------------------------------------

local dataToSend = {}
local cumulativeReward = 0
local orderStreak = 0
local currentOrder = nil
local state = "start"
local timer = 0
local dwellTimer = 0
local dwellDuration = config.pickupDropoffDuration

local updateTimer = 1
local uiUpdateTimer = 0
local jobOfferTimer = 0

local jobOfferInterval = 60

local vehicleMultiplier = 0.1

local restaurants = {}
local allDeliverySpots = nil
local lastRatingDelta = nil
local recentRestaurantIds = {}

local ratingSaveFile = "beamEatsRating.json"
local ratingSave
local playerRating = 0.0
local ratingCount = 0
local ratingSum = 0
local ratingLoaded = false
local loadedRatingProfile = nil
local locationsLevelKey = nil

M.deliveryData = {}

-- Parts -------------------------------------------------------------------------------------------

parts.pay = require('overhaul/jobs/beamEats/pay')(config, logisticsXPConfig)

-- Rating and offer timing -------------------------------------------------------------------------

-- Bind only at the existing profile read/write boundary, so loading the job never restores a save.
local function ratingFeature()
  if not ratingSave or not ratingSave.isCurrent() then
    ratingSave = assert(saveStore.feature("jobs.beamEatsRating", {
      owner = "overhaul_jobs_beamEats",
      files = {"career/rls_career/" .. ratingSaveFile},
      root = "slot",
      phase = "profile",
      required = true,
      writer = {pretty = true}
    }))
  end
  return ratingSave
end

local function releaseRatingFeature()
  if ratingSave then ratingSave.dispose(); ratingSave = nil end
end

local function formatPlayerRatingDisplay(forCompletion)
  if forCompletion and lastRatingDelta then
    if math.abs(lastRatingDelta) < 0.005 then
      return string.format("%.2f / 5.0 (0.00)", playerRating)
    end
    return string.format("%.2f / 5.0 (%+.2f)", playerRating, lastRatingDelta)
  end
  return string.format("%.2f / 5.0", playerRating)
end

local function calculateJobOfferInterval()
  local t = math.min(1.0, math.max(0.0, playerRating / 5.0))
  local minInterval = config.intervalMinRating.min + (config.intervalMaxRating.min - config.intervalMinRating.min) * t
  local maxInterval = config.intervalMinRating.max + (config.intervalMaxRating.max - config.intervalMinRating.max) * t

  local floorMin = math.floor(minInterval)
  local floorMax = math.floor(maxInterval)

  -- Ensure floorMax >= floorMin to avoid math.random error
  if floorMax < floorMin then floorMax = floorMin end

  return math.random(floorMin, floorMax)
end

local function savePlayerRating(currentSavePath, writer)
  if not currentSavePath then return end
  if not overhaul_career_career.isActive() then return end

  local feature = ratingFeature()
  local dirPath = feature.path(currentSavePath):match("^(.*)/[^/]+$")
  if not writer.exists(dirPath) then
    writer.mkdir(dirPath)
  end

  local data = {
    sum = ratingSum,
    count = ratingCount,
    average = playerRating
  }
  feature.write(currentSavePath, data)
end

local function loadPlayerRating(force)
  if not overhaul_career_career or not overhaul_career_career.isActive() then return end
  local profile, path = overhaul_career_saveSystem.getCurrentProfile()
  if not path then return end
  if not force and ratingLoaded and loadedRatingProfile == profile then return end
  local filePath = ratingFeature().path(path)
  local data = jsonReadFile(filePath) or {}
  ratingSum = tonumber(data.sum or 0) or 0
  ratingCount = tonumber(data.count or 0) or 0

  local virtualStartCount = configRules.value(config, "ratingDampeningCount")
  local virtualStartRating = 0.0

  local effectiveSum = ratingSum + (virtualStartCount * virtualStartRating)
  local effectiveCount = ratingCount + virtualStartCount

  playerRating = math.max(0.0, math.min(5.0, effectiveSum / effectiveCount))
  ratingLoaded = true
  loadedRatingProfile = profile
end

local function isBeamEatsDisabled()
  local disabled = false
  local reason = ""

  if gameplay_walk and gameplay_walk.isWalking() then
    disabled = true
    reason = "BeamEats is not available while walking"
    return disabled, reason
  end

  local beamEatsMultiplier = (overhaul_career_economyAdjuster and overhaul_career_economyAdjuster.getSectionMultiplier("beamEats")) or 1.0
  if beamEatsMultiplier == 0 then
    disabled = true
    reason = "BeamEats multiplier is set to 0"
    return disabled, reason
  end

  if not restaurants or #restaurants == 0 then
    disabled = true
    reason = "No food pickup locations on this map"
    return disabled, reason
  end

  if not allDeliverySpots or not allDeliverySpots.objects or #allDeliverySpots.objects == 0 then
    disabled = true
    reason = "No food delivery destinations on this map"
    return disabled, reason
  end

  return disabled, reason
end

-- Phone app state ---------------------------------------------------------------------------------
local function buildBeamEatsStateData()
  local beamEatsDisabled, disabledReason = isBeamEatsDisabled()
  local effectiveState = beamEatsDisabled and "disabled" or state

  local ratingStr = formatPlayerRatingDisplay(state == "completed")

  local previewStreak = orderStreak + 1
  local previewDistance = currentOrder and currentOrder.totalDistance or 0
  local streakXP = currentOrder and currentOrder.streakXP
  if streakXP == nil then
    streakXP = parts.pay.calculateLogisticsXp(previewDistance, previewStreak)
  end

  local promotionLabel, promotionPayBonus, promotionXpMultiplier = parts.pay.getPromotionState()
  local logisticsLevel = parts.pay.getLogisticsLevel()
  local _, logisticsPayBonus = parts.pay.getLogisticsMoneyBonusMultiplier()
  local promotionPayPercent = math.floor((promotionPayBonus or 0) * 100 + 0.5)
  local promotionXpPercent = math.floor(((promotionXpMultiplier or 1) - 1) * 100 + 0.5)
  local logisticsPayPercent = math.floor((logisticsPayBonus or 0) * 100 + 0.5)

  return {
    state = effectiveState,
    currentOrder = currentOrder,
    vehicleMultiplier = string.format("%.1f", vehicleMultiplier),
    cumulativeReward = cumulativeReward,
    orderStreak = orderStreak,
    streakXP = streakXP,
    beamEatsDisabled = beamEatsDisabled,
    disabledReason = disabledReason,
    playerRating = ratingStr,
    promotionLabel = promotionLabel,
    promotionPayPercent = promotionPayPercent,
    promotionXpPercent = promotionXpPercent,
    logisticsLevel = logisticsLevel,
    logisticsPayPercent = logisticsPayPercent
  }
end

-- Sensor data -------------------------------------------------------------------------------------
local function updateSensorData()
  if not currentOrder or state ~= "dropoff" then
    return
  end

  local vehicle = be:getPlayerVehicle(0)
  if not vehicle then
    return
  end

  vehicle:queueLuaCommand([[
        local sensors = require('sensors')
        if sensors then
            local gx, gy, gz = sensors.gx or 0, sensors.gy or 0, sensors.gz or 0
            local gx2, gy2, gz2 = sensors.gx2 or 0, sensors.gy2 or 0, sensors.gz2 or 0
            obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(]] .. require('overhaul/lib/vehicles/callbacks').open('beamEatsSensorData', {owner = 'beamEats', vehId = vehicle:getID()}) .. [[, 'beamEatsSensorData', gx..','..gy..','..gz..','..gx2..','..gy2..','..gz2))
        end
    ]])
end

local function processSensorData(gx, gy, gz, gx2, gy2, gz2)
  local gravityMPS2 = 9.81 -- Preserve the historical sensor conversion.
  M.deliveryData.currentSensorData = {
    gx = gx / gravityMPS2,
    gy = gy / gravityMPS2,
    gz = gz / gravityMPS2,
    gx2 = gx2 / gravityMPS2,
    gy2 = gy2 / gravityMPS2,
    gz2 = gz2 / gravityMPS2,
    timestamp = os.time()
  }

  if not M.deliveryData.roughEvents then
    M.deliveryData.roughEvents = 0
  end
  if not M.deliveryData.isRoughEventActive then
    M.deliveryData.isRoughEventActive = false
  end

  local peak = math.max(math.abs(gx2 / gravityMPS2), math.abs(gy2 / gravityMPS2), math.abs(gz2 / gravityMPS2))

  if M.deliveryData.isRoughEventActive then
    if peak < (config.roughEventThreshold * 0.8) then
      M.deliveryData.isRoughEventActive = false
    end
  else
    if peak > config.roughEventThreshold then
      M.deliveryData.roughEvents = M.deliveryData.roughEvents + 1
      M.deliveryData.isRoughEventActive = true
    end
  end
end

-- Restaurants and locations -----------------------------------------------------------------------
local function providesFood(accessPoint)
  if not accessPoint.logisticTypesProvided then return false end
  for _, logisticType in ipairs(accessPoint.logisticTypesProvided) do
    if logisticType == "food" or logisticType == "takeout" then return true end
  end
  return false
end

-- A facility is a restaurant when any access point provides food delivery, regardless of its ID.
local function isRestaurantFacility(fac)
  for _, accessPoint in ipairs(fac.manualAccessPoints or {}) do
    if providesFood(accessPoint) then return true end
  end
  return false
end

-- The pickup spot for a food access point, or nil when the facility's sites file does not place it.
local function findPickupSpot(fac, accessPoint)
  if not fac.sitesFile then return nil end
  local siteData = sitesManager().loadSites(fac.sitesFile)
  local byName = siteData and siteData.parkingSpots and siteData.parkingSpots.byName
  local ps = byName and byName[accessPoint.psName]
  if not (ps and ps.pos) then return nil end
  return {
    pos = ps.pos,
    name = accessPoint.psName,
    restaurantId = fac.id,
    restaurantName = fac.name
  }
end

local function collectPickupSpots(fac, parkingSpotNames)
  local pickupSpots = {}
  for _, accessPoint in ipairs(fac.manualAccessPoints) do
    if providesFood(accessPoint) then
      table.insert(parkingSpotNames, accessPoint.psName)
      local pickupSpot = findPickupSpot(fac, accessPoint)
      if pickupSpot then
        table.insert(pickupSpots, pickupSpot)
      end
    end
  end
  return pickupSpots
end

local function findRestaurants()
  restaurants = {}
  local facilities = overhaul_world_facilities.getFacilitiesByType("deliveryProvider")

  if not facilities then
    return
  end

  local restaurantParkingSpotNames = {}
  local restaurantParkingSpotPaths = {}

  for _, fac in ipairs(facilities) do
    if isRestaurantFacility(fac) then
      local pickupSpots = collectPickupSpots(fac, restaurantParkingSpotNames)
      local path = levelData.assetPath(getCurrentLevelIdentifier(), fac.sitesFile)
      for _, pickupSpot in ipairs(pickupSpots) do
        if path then restaurantParkingSpotPaths[path .. "|" .. pickupSpot.name] = true end
      end
      if #pickupSpots > 0 then
        table.insert(restaurants, {
          id = fac.id,
          name = fac.name,
          pickupSpots = pickupSpots
        })
      end
    end
  end

  M.restaurantParkingSpotNames = restaurantParkingSpotNames
  M.restaurantParkingSpotPaths = restaurantParkingSpotPaths
end

local function collectDeliverySpots(collection, restaurantSpotsLookup, allParkingSpots, seen)
  local sitePath = levelData.assetPath(getCurrentLevelIdentifier(), collection.sitesFile)
  local siteData = sitePath and sitesManager().loadSites(sitePath, true, true)
  local objects = siteData and siteData.parkingSpots and siteData.parkingSpots.objects
  if not objects then
    log("W", "beamEats", "Food destinations unavailable: " .. tostring(sitePath))
    return
  end
  for _, spot in pairs(objects) do
    local tags = spot.customFields and spot.customFields.tags or {}
    local eligible = collection.allParkingSpots == true or tags.foodDeliveryDestination
    local key = sitePath .. "|" .. tostring(spot.name)
    if eligible and spot.name and spot.pos and not restaurantSpotsLookup[key] and not seen[key] then
      local destination = {}
      for key, value in pairs(spot) do destination[key] = value end
      destination.zoneName = spot.zoneName or (spot.customFields and spot.customFields.values and spot.customFields.values.zoneName) or collection.zoneName
      allParkingSpots[#allParkingSpots + 1] = destination
      seen[key] = true
    end
  end
end

local function findAllDeliveryParkingSpots()
  allDeliverySpots = {objects = {}}
  local level = getCurrentLevelIdentifier()
  if not level then return end
  local data = jsonReadFile(levelData.assetPath(level, "overhaul/beamEats.json"))
  local collections = data and data.deliverySites
  if type(collections) ~= "table" then
    log("W", "beamEats", "Food delivery disabled: missing deliverySites in overhaul/beamEats.json")
    return
  end
  local restaurantSpotsLookup, seen = M.restaurantParkingSpotPaths or {}, {}
  for _, collection in ipairs(collections) do
    if type(collection) == "table" and type(collection.sitesFile) == "string" then
      collectDeliverySpots(collection, restaurantSpotsLookup, allDeliverySpots.objects, seen)
    else
      log("W", "beamEats", "Ignoring food collection without sitesFile")
    end
  end
  if #allDeliverySpots.objects == 0 then log("W", "beamEats", "Food delivery disabled: no configured customer destinations") end
end

local function getLocationsLevelKey()
  local level = getCurrentLevelIdentifier()
  if level and level ~= "" then return level end
  return getMissionFilename() or ""
end

local function refreshLocations(force)
  local levelKey = getLocationsLevelKey()
  if not force and locationsLevelKey == levelKey and allDeliverySpots then
    return false
  end
  findRestaurants()
  findAllDeliveryParkingSpots()
  locationsLevelKey = levelKey
  return true
end

-- Road distance and restaurant picking ------------------------------------------------------------

-- Road data can be absent while loading; fallback distances keep offers usable.
local function calculateDrivingDistance(startPos, endPos)
  local startRoad, _, startDist = map.findClosestRoad(startPos)
  local endRoad, _, endDist = map.findClosestRoad(endPos)

  if not startRoad or not endRoad then
    return startPos:distance(endPos) * 2.0
  end

  local path = map.getPath(startRoad, endRoad)
  if not path or #path == 0 then
    return startPos:distance(endPos) * 2.0
  end

  local totalDistance = 0
  local prevNodePos = startPos
  local mapData = map.getMap()

  if not mapData or not mapData.nodes then
    return startPos:distance(endPos) * 2.0
  end

  local lastRoadNode = nil
  for i = 1, #path do
    local node = mapData.nodes[path[i]]
    if node then
      local nodePos = node.pos
      if prevNodePos then
        totalDistance = totalDistance + prevNodePos:distance(nodePos)
      end
      prevNodePos = nodePos
      lastRoadNode = nodePos
    end
  end

  if lastRoadNode then
    totalDistance = totalDistance + lastRoadNode:distance(endPos)
  else
    totalDistance = totalDistance + prevNodePos:distance(endPos)
  end

  return totalDistance
end

local function getDeliveryLocationName(spot)
  if not spot then return "Customer" end

  if spot.zones then
    for _, zone in pairs(spot.zones) do
      if zone.name then
        return zone.name
      end
    end
  end

  -- 2. Zone Name (Fallback: manually attached in findAllDeliveryParkingSpots if native lookup fails)
  if spot.zoneName then
    return spot.zoneName
  end

  return "Customer"
end

local function getRestaurantAnchorPos(restaurant)
  if not restaurant or not restaurant.pickupSpots then
    return nil
  end
  for _, spot in ipairs(restaurant.pickupSpots) do
    if spot and spot.pos then
      return spot.pos
    end
  end
  return nil
end

local function weightedPickRestaurant(pool)
  if not pool or #pool == 0 then
    return nil
  end
  local totalWeight = 0
  for _, entry in ipairs(pool) do
    totalWeight = totalWeight + (entry.weight or 1)
  end
  if totalWeight <= 0 then
    return pool[math.random(#pool)].restaurant
  end
  local roll = math.random() * totalWeight
  local cumulative = 0
  for _, entry in ipairs(pool) do
    cumulative = cumulative + (entry.weight or 1)
    if roll <= cumulative then
      return entry.restaurant
    end
  end
  return pool[#pool].restaurant
end

-- Orders and fares --------------------------------------------------------------------------------
local function generateValueMultiplier()
  if not overhaul_career_career or not overhaul_career_career.isActive() then
    return 1
  end
  local playerVehicle = be:getPlayerVehicle(0)
  if not playerVehicle then
    return 0.1
  end
  local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(playerVehicle:getID())
  if not inventoryId then
    return 0
  end
  vehicleMultiplier = (overhaul_career_market_valueCalculator.getInventoryVehicleValue(inventoryId) / 30000) ^ 0.5
  vehicleMultiplier = math.max(vehicleMultiplier, 0.1)
  return vehicleMultiplier
end

local function computeOrderBaseFare(totalDistance)
  local distancePay, economyMultiplier = parts.pay.computeDistancePay(totalDistance)
  local logisticsMult = select(1, parts.pay.getLogisticsMoneyBonusMultiplier())
  local coreBase = distancePay * logisticsMult
  local ratingMult = parts.pay.calculateRatingPayMultiplier(playerRating)
  local _, promotionPayBonus = parts.pay.getPromotionState()
  local baseFare = coreBase * ratingMult * (1 + promotionPayBonus)
  return math.floor(baseFare + 0.5), economyMultiplier
end

local function applyOrderFareFields(order, totalDistance)
  local baseFare, economyMultiplier = computeOrderBaseFare(totalDistance)
  local _, logisticsPayBonus = parts.pay.getLogisticsMoneyBonusMultiplier()

  order.baseFare = baseFare
  order.totalDistance = totalDistance
  order.economyMultiplier = economyMultiplier or 1.0
  order.demandMultiplier = (overhaul_career_economy_activityHeat and overhaul_career_economy_activityHeat.getDemandFactor("beamEats")) or 1.0
  order.baseFareDisplay = string.format("%.2f (%s)", baseFare, formatPlayerRatingDisplay(false))
  order.totalPaymentDisplay = string.format("%.2f", baseFare)
  order.totalDistanceDisplay = string.format("%.2f", totalDistance / 1000)
  order.logisticsPayPercent = math.floor((logisticsPayBonus or 0) * 100 + 0.5)

  return order
end

local function rememberRecentRestaurant(restaurantId)
  if not restaurantId then
    return
  end
  for i = #recentRestaurantIds, 1, -1 do
    if recentRestaurantIds[i] == restaurantId then
      table.remove(recentRestaurantIds, i)
    end
  end
  table.insert(recentRestaurantIds, 1, restaurantId)
  local keep = configRules.number(config, "recentRestaurantCooldown")
  while #recentRestaurantIds > keep do
    table.remove(recentRestaurantIds)
  end
end

local function isRecentRestaurant(restaurantId)
  for _, id in ipairs(recentRestaurantIds) do
    if id == restaurantId then
      return true
    end
  end
  return false
end

local function restaurantHasAirDropoff(restaurant, minDistance, maxDistance)
  if not restaurant or not restaurant.pickupSpots or not allDeliverySpots or not allDeliverySpots.objects then
    return false
  end
  for _, pickup in ipairs(restaurant.pickupSpots) do
    if pickup and pickup.pos then
      for _, spot in pairs(allDeliverySpots.objects) do
        if spot and spot.pos then
          local dist = pickup.pos:distance(spot.pos)
          if dist >= minDistance and dist <= maxDistance then
            return true
          end
        end
      end
    end
  end
  return false
end

local function getBaseDropoffMaxDistance()
  return config.baseDeliveryRadius
    + (math.floor(playerRating / config.radiusStepRatingInterval) * config.radiusStep)
end

local function findValidDropoff(pickupPos, minDistance, startMaxDistance, absoluteMaxDistance)
  if not pickupPos or not allDeliverySpots or not allDeliverySpots.objects then
    return nil, nil
  end

  local expandStep = configRules.number(config, "dropoffExpandStep")
  local maxAttempts = configRules.number(config, "dropoffRoadCheckAttempts")
  local roadDistanceFactor = configRules.number(config, "dropoffRoadDistanceFactor")
  local maxDistance = math.max(minDistance, startMaxDistance or minDistance)
  local absoluteMax = math.max(maxDistance, absoluteMaxDistance or maxDistance)

  while maxDistance <= absoluteMax + 0.01 do
    local potentialSpots = {}
    for _, spot in pairs(allDeliverySpots.objects) do
      if spot and spot.pos then
        local airDist = pickupPos:distance(spot.pos)
        if airDist >= minDistance and airDist <= maxDistance then
          table.insert(potentialSpots, spot)
        end
      end
    end

    local roadAllowance = maxDistance * roadDistanceFactor
    local attempts = 0
    while #potentialSpots > 0 and attempts < maxAttempts do
      attempts = attempts + 1
      local index = math.random(#potentialSpots)
      local spot = potentialSpots[index]
      local roadDist = calculateDrivingDistance(pickupPos, spot.pos)
      if roadDist <= roadAllowance then
        return spot, roadDist
      end
      table.remove(potentialSpots, index)
    end

    if maxDistance >= absoluteMax then
      break
    end
    maxDistance = math.min(absoluteMax, maxDistance + expandStep)
  end

  return nil, nil
end

local function buildRestaurantPools(vehiclePos, minDistance, viabilityMaxDistance)
  local viable = {}
  for _, restaurant in ipairs(restaurants) do
    local anchor = getRestaurantAnchorPos(restaurant)
    if anchor and restaurantHasAirDropoff(restaurant, minDistance, viabilityMaxDistance) then
      local dist = vehiclePos:distance(anchor)
      table.insert(viable, {
        restaurant = restaurant,
        dist = dist,
        weight = 1 / (dist + 50),
      })
    end
  end

  table.sort(viable, function(a, b)
    return a.dist < b.dist
  end)

  local localPoolPreferred = {}
  local localPoolFallback = {}
  local poolSize = configRules.number(config, "localRestaurantPoolSize")
  for i = 1, math.min(poolSize, #viable) do
    local entry = viable[i]
    if isRecentRestaurant(entry.restaurant.id) then
      table.insert(localPoolFallback, entry)
    else
      table.insert(localPoolPreferred, entry)
    end
  end

  local localPool = (#localPoolPreferred > 0) and localPoolPreferred or localPoolFallback

  return localPool, viable
end

local function chooseDeliveryStops(vehiclePos)
  local minDistance = configRules.number(config, "minDeliveryAirDistance")
  local baseMaxDistance = getBaseDropoffMaxDistance()
  local localCap = math.max(baseMaxDistance, configRules.number(config, "localDropoffMaxCap"))
  local longHaulCap = math.max(localCap, configRules.number(config, "longHaulDropoffMaxCap"))
  local longHaulStartMin = configRules.number(config, "longHaulDropoffStartMin")
  local longHaulChance = (configRules.number(config, "longHaulChanceMin"))
    + ((configRules.number(config, "longHaulChancePerRating")) * (tonumber(playerRating) or 0))
  longHaulChance = math.min(0.45, math.max(0, longHaulChance))

  local localPool, allViable = buildRestaurantPools(vehiclePos, minDistance, longHaulCap)
  if #allViable == 0 then
    return nil
  end

  local restaurant = nil
  local pickupSpot = nil
  local deliverySpot = nil
  local validDistDelivery = nil
  local pickAttempts = configRules.number(config, "restaurantPickAttempts")

  for _ = 1, pickAttempts do
    local wantLongHaul = math.random() < longHaulChance
    local pool = wantLongHaul and allViable or ((#localPool > 0) and localPool or allViable)
    local candidate = weightedPickRestaurant(pool)
    if candidate and candidate.pickupSpots and #candidate.pickupSpots > 0 then
      local pickup = candidate.pickupSpots[math.random(#candidate.pickupSpots)]
      if pickup and pickup.pos then
        local startMax = baseMaxDistance
        local absMax = localCap
        if wantLongHaul then
          startMax = math.max(baseMaxDistance, longHaulStartMin)
          absMax = longHaulCap
        end

        local spot, roadDist = findValidDropoff(pickup.pos, minDistance, startMax, absMax)
        if spot then
          restaurant = candidate
          pickupSpot = pickup
          deliverySpot = spot
          validDistDelivery = roadDist
          break
        end
      end
    end
  end

  if not restaurant or not pickupSpot or not deliverySpot then
    return nil
  end

  return restaurant, pickupSpot, deliverySpot, validDistDelivery
end

local function generateOrder()
  local beamEatsDisabled = isBeamEatsDisabled()
  if beamEatsDisabled then
    return nil
  end

  if #restaurants == 0 then
    return nil
  end

  if not allDeliverySpots or not allDeliverySpots.objects or #allDeliverySpots.objects == 0 then
    return nil
  end

  local vehicle = be:getPlayerVehicle(0)
  if not vehicle then
    return nil
  end

  local vehiclePos = vehicle:getPosition()
  local restaurant, pickupSpot, deliverySpot, validDistDelivery = chooseDeliveryStops(vehiclePos)
  if not restaurant then return nil end
  rememberRecentRestaurant(restaurant.id)
  generateValueMultiplier()

  local distToPickup = calculateDrivingDistance(vehiclePos, pickupSpot.pos)
  local distDelivery = validDistDelivery or calculateDrivingDistance(pickupSpot.pos, deliverySpot.pos)
  local totalDistance = distToPickup + distDelivery -- Total trip distance

  local expectedTime = (totalDistance / config.averageSpeedMPS) + config.pickupDropoffTimeBuffer
  expectedTime = math.max(expectedTime, 60) -- Minimum 60 seconds for the whole trip

  local order = {
    restaurant = restaurant.name,
    restaurantId = restaurant.id,
    pickup = {
      pos = pickupSpot.pos,
      name = pickupSpot.name
    },
    destination = {
      pos = deliverySpot.pos,
      name = getDeliveryLocationName(deliverySpot)
    },
    expectedTime = expectedTime,
    startTime = nil
  }

  applyOrderFareFields(order, totalDistance)
  order.expectedTimeDisplay = string.format("%d min %d sec", math.floor(expectedTime / 60), math.floor(expectedTime % 60))

  return order
end

-- Delivery completion -----------------------------------------------------------------------------

-- Defer phone navigation until the reward UI has finished pushing its screen.
local function openBeamEatsApp()
  local function navigate()
    if overhaul_phone_phone and overhaul_phone_phone.openRoute then
      overhaul_phone_phone.openRoute("phone-beam-eats")
    elseif extensions.ui_router then
      extensions.ui_router.navigate("phone-beam-eats")
    end
  end

  core_jobsystem.create(function(job)
    job.sleep(0.2)
    navigate()
  end)
end

local function saveCompletedDelivery()
  if overhaul_career_career.isAutosaveEnabled() then
    overhaul_career_saveSystem.saveCurrent()
  end
end

local function calculateDeliveryTips()
  local elapsedTime = timer - currentOrder.startTime
  local expectedTime = currentOrder.expectedTime
  local timeDiff = expectedTime - elapsedTime

  local nextStreak = orderStreak + 1
  local logisticsXp = parts.pay.calculateLogisticsXp(currentOrder.totalDistance, nextStreak)

  local roughEvents = M.deliveryData.roughEvents or 0
  local baseFare = currentOrder.baseFare
  local smoothDrivingTip = parts.pay.calculateSmoothDrivingTip(baseFare, roughEvents)

  local timeBonus = 0
  if timeDiff >= 0 then
    timeBonus = baseFare * config.onTimeBonusPercent
  else
    local penaltyPerSecond = 0.05
    local secondsLate = math.abs(timeDiff)
    local totalPenaltyPercent = 0

    for _ = 1, math.ceil(secondsLate) do
      totalPenaltyPercent = totalPenaltyPercent + (math.random() * penaltyPerSecond)
    end

    totalPenaltyPercent = math.min(1.0, totalPenaltyPercent)

    smoothDrivingTip = smoothDrivingTip * (1.0 - totalPenaltyPercent)
  end

  return logisticsXp, roughEvents, baseFare, timeDiff, smoothDrivingTip, timeBonus
end

local function recordDeliveryPayment(baseFare, roughEvents, smoothDrivingTip, timeBonus)
  local streakMultiplier = math.min(orderStreak * config.streakMultiplierPerLevel, config.streakMultiplierMax)
  local streakBonus = baseFare * streakMultiplier

  local totalTips = smoothDrivingTip + timeBonus

  local finalPayment = baseFare + streakBonus + totalTips
  cumulativeReward = cumulativeReward + finalPayment
  orderStreak = orderStreak + 1

  currentOrder.totalPayment = finalPayment
  currentOrder.smoothDrivingTip = smoothDrivingTip
  currentOrder.timeBonus = timeBonus
  currentOrder.roughEvents = roughEvents
  currentOrder.totalTips = totalTips
  currentOrder.streakBonus = streakBonus

  return finalPayment, totalTips
end

local function recordDeliveryRating(roughEvents, timeDiff)
  local rating = 5.0
  rating = rating - (roughEvents * (configRules.value(config, "roughEventRatingPenalty")))
  if timeDiff < 0 then -- Late
    rating = rating - (configRules.value(config, "lateDeliveryRatingPenalty"))
  else
    rating = rating + (configRules.value(config, "onTimeRatingBonus")) -- bonus for on-time delivery
  end
  rating = math.max(1.0, math.min(5.0, rating)) -- Clamp between 1 and 5
  -- Pull rating toward 5 so star average climbs faster with good deliveries
  local pull = configRules.value(config, "ratingPullTowardFive")
  if pull > 0 then
    rating = rating + (5.0 - rating) * pull
    rating = math.max(1.0, math.min(5.0, rating))
  end

  local oldRating = playerRating

  ratingSum = ratingSum + rating
  ratingCount = ratingCount + 1

  local virtualStartCount = configRules.value(config, "ratingDampeningCount")
  local virtualStartRating = 0.0

  local effectiveSum = ratingSum + (virtualStartCount * virtualStartRating)
  local effectiveCount = ratingCount + virtualStartCount

  playerRating = math.max(0.0, math.min(5.0, effectiveSum / effectiveCount))

  lastRatingDelta = playerRating - oldRating
end

local function presentCompletedDelivery(finalPayment, totalTips, logisticsXp)
  currentOrder.totalPaymentDisplay = string.format("%.2f", finalPayment)
  currentOrder.totalTipsDisplay = string.format("%.2f", totalTips)
  currentOrder.totalDistanceDisplay = string.format("%.2f", currentOrder.totalDistance / 1000)

  state = "completed"

  guihooks.trigger('ClearTasklist')
  guihooks.trigger('SetTasklistHeader', {label = "BeamEats Delivery Complete"})

  local xpMsg = ""
  if logisticsXp > 0 then
    currentOrder.streakXP = logisticsXp
    xpMsg = string.format(" | Logistics XP: +%d", logisticsXp)
  end

  guihooks.trigger('SetTasklistTask', {
    id = "beamEats_complete_msg",
    label = string.format("Earned: $%s%s", currentOrder.totalPaymentDisplay, xpMsg),
    done = true,
    active = true,
    type = "message",
    clear = false
  })

  -- Schedule clearing of the tasklist after 8 seconds We can't use simple 'sleep' here as we are in main thread update flow potentially We will set a timer variable that the update loop checks to clear it
  M.deliveryData.clearTasklistTimer = 8.0

  dataToSend = buildBeamEatsStateData()
  statePush.send('updateBeamEatsState', dataToSend)

  openBeamEatsApp()
end

local function settleCompletedDelivery(finalPayment, logisticsXp)
  local label = string.format("BeamEats delivery: $%s\nDistance: %skm | Tips: $%s", currentOrder.totalPaymentDisplay,
    currentOrder.totalDistanceDisplay, currentOrder.totalTipsDisplay)
  if not overhaul_career_career or not overhaul_career_career.isActive() then
    return
  end
  local xpLabel = ""
  if logisticsXp > 0 then
    xpLabel = string.format("\nLogistics XP (streak %d): +%d", orderStreak, logisticsXp)
  end
  local rewardData = {
    money = {
      amount = math.floor(finalPayment)
    }
  }
  if logisticsXp > 0 then
    rewardData["logistics-delivery"] = {
      amount = logisticsXp
    }
  end
  overhaul_career_economy_difficultyMode.scalePaymentRewardData(rewardData, {includeMoney = false})
  local awardedMoney = (rewardData.money and rewardData.money.amount) or math.floor(finalPayment)
  logisticsXp = (rewardData["logistics-delivery"] and rewardData["logistics-delivery"].amount) or logisticsXp
  currentOrder.totalPaymentDisplay = string.format("%.2f", awardedMoney)
  if logisticsXp > 0 then
    xpLabel = string.format("\nLogistics XP (streak %d): +%d", orderStreak, logisticsXp)
    currentOrder.streakXP = logisticsXp
  else
    xpLabel = ""
    currentOrder.streakXP = nil
  end
  local surgeText = overhaul_career_economy_activityHeat.formatSurgeBonusText(currentOrder.demandMultiplier or "beamEats")
  label = string.format("BeamEats delivery: $%s%s\nDistance: %skm | Tips: $%s",
    currentOrder.totalPaymentDisplay, surgeText, currentOrder.totalDistanceDisplay, currentOrder.totalTipsDisplay) .. xpLabel
  guihooks.trigger('SetTasklistTask', {
    id = "beamEats_complete_msg",
    label = string.format("Earned: $%s%s%s", currentOrder.totalPaymentDisplay, surgeText, xpLabel),
    done = true,
    active = true,
    type = "message",
    clear = false
  })
  shared.requestBeamEatsState()
  local paid = overhaul_career_economy_payment.payout{
    amount = awardedMoney,
    xp = rewardData["logistics-delivery"] and { ["logistics-delivery"] = logisticsXp } or nil,
    label = label,
    tags = {"transport", "beamEats"},
    fullReward = true
  }
  if paid ~= true then
    -- Completion already precedes settlement; a refusal keeps the legacy save without retrying.
    return saveCompletedDelivery()
  end
  saveCompletedDelivery()
end

local function completeDelivery()
  if not currentOrder then return end
  local logisticsXp, roughEvents, baseFare, timeDiff, smoothDrivingTip, timeBonus = calculateDeliveryTips()
  local finalPayment, totalTips = recordDeliveryPayment(baseFare, roughEvents, smoothDrivingTip, timeBonus)
  recordDeliveryRating(roughEvents, timeDiff)
  presentCompletedDelivery(finalPayment, totalTips, logisticsXp)
  settleCompletedDelivery(finalPayment, logisticsXp)
end

local function dismissSummary()
  state = "ready"
  currentOrder = nil
  jobOfferTimer = 0
  jobOfferInterval = calculateJobOfferInterval()
  core_groundMarkers.resetAll()
  M.deliveryData = {}
  shared.requestBeamEatsState()
end

-- Job control -------------------------------------------------------------------------------------
local function rejectOrder()
  state = "ready"
  currentOrder = nil
  jobOfferTimer = 0
  jobOfferInterval = calculateJobOfferInterval()
  shared.requestBeamEatsState()
end

local function stopBeamEatsJob()
  state = "start"
  if currentOrder then
    core_groundMarkers.resetAll()
  end
  currentOrder = nil
  jobOfferTimer = 0
  jobOfferInterval = calculateJobOfferInterval()
  cumulativeReward = 0
  orderStreak = 0
  M.deliveryData = {}
  guihooks.trigger('ClearTasklist')
end

local function setAvailable()
  if #restaurants == 0 then
    pcall(findRestaurants)
  end
  if not allDeliverySpots or not allDeliverySpots.objects or #allDeliverySpots.objects == 0 then
    pcall(findAllDeliveryParkingSpots)
  end

  state = "ready"
  shared.requestBeamEatsState()
end

local function prepareBeamEatsJob(dt)
  if not currentOrder then
    return
  end

  local vehicle = be:getPlayerVehicle(0)
  if not vehicle then
    return
  end

  local vehiclePos = vehicle:getPosition()
  local pickupDist = (vehiclePos - currentOrder.pickup.pos):length()

  if pickupDist < 5 then
  if vehicle:getVelocity():length() < config.stopVelocityThreshold then
    dwellTimer = dwellTimer + dt
    if dwellTimer < dwellDuration then
      ui_message(string.format("Picking up order... %0.1fs", dwellDuration - dwellTimer), 0.1, 'beamEats_dwell', 'timer')
      return
    end
  else
    dwellTimer = 0
    ui_message("Stop to pick up order", 1, 'beamEats_dwell', 'info')
    return
  end

    dwellTimer = 0
    state = "dropoff"

    M.deliveryData = {
      roughEvents = 0
    }
    core_groundMarkers.setPath(currentOrder.destination.pos, { clearPathOnReachingTarget = true })

    ui_message("Order picked up! Don't spill it!", 6, 'beamEats_main', 'check')

    dataToSend = buildBeamEatsStateData()
    statePush.send('updateBeamEatsState', dataToSend)
  end
end

-- State requests and delivery start ---------------------------------------------------------------

function shared.requestBeamEatsState()
  dataToSend = buildBeamEatsStateData()
  statePush.send('updateBeamEatsState', dataToSend)
end

function shared.startDelivery(order)
  if not order then
    order = currentOrder
  end

  if not order then
    return
  end

  -- Recalculate route and time based on current position to prevent "travel before accept" exploit
  local vehicle = be:getPlayerVehicle(0)
  if vehicle then
    local vehiclePos = vehicle:getPosition()
    local distToPickup = calculateDrivingDistance(vehiclePos, order.pickup.pos)
    local distDelivery = calculateDrivingDistance(order.pickup.pos, order.destination.pos)

    local totalDistance = distToPickup + distDelivery
    local expectedTime = (totalDistance / config.averageSpeedMPS) + config.pickupDropoffTimeBuffer
    expectedTime = math.max(expectedTime, 60)

    order.expectedTime = expectedTime
    order.expectedTimeDisplay = string.format("%d min %d sec", math.floor(expectedTime / 60), math.floor(expectedTime % 60))
    applyOrderFareFields(order, totalDistance)
  end

  state = "pickup"
  currentOrder = order
  currentOrder.startTime = timer
  core_groundMarkers.setPath(order.pickup.pos, { clearPathOnReachingTarget = true })

  dataToSend = buildBeamEatsStateData()
  statePush.send('updateBeamEatsState', dataToSend)
end

-- Per-frame update --------------------------------------------------------------------------------
local updateInterval = 1.0
local function updateDeliveryDropoff(dt)
      updateSensorData()
      local vehicle = be:getPlayerVehicle(0)
      if vehicle then
        local vehiclePos = vehicle:getPosition()
        local destDist = (vehiclePos - currentOrder.destination.pos):length()

        if destDist < 5 then
          if vehicle:getVelocity():length() < config.stopVelocityThreshold then
            dwellTimer = dwellTimer + dt
            if dwellTimer < dwellDuration then
              ui_message(string.format("Dropping off order... %0.1fs", dwellDuration - dwellTimer), 0.1, 'beamEats_dwell', 'timer')
            else
              dwellTimer = 0
              completeDelivery()
            end
          else
            dwellTimer = 0
            ui_message("Stop to drop off order", 0.1, 'beamEats_dwell', 'info')
          end
        else
          dwellTimer = 0
        end
      end
end

local function refreshDeliveryTasklist()
      uiUpdateTimer = 0
      local elapsedTime = timer - currentOrder.startTime
      local timeLeft = math.max(0, currentOrder.expectedTime - elapsedTime)
      local timeDiff = currentOrder.expectedTime - elapsedTime
      local totalTime = currentOrder.expectedTime

      local phaseLabel = (state == "pickup") and "Pickup at: " .. currentOrder.restaurant or "Deliver to: " .. (currentOrder.destination.name or "Customer")

      local progressPercent = (timeLeft / totalTime) * 100
      if timeDiff < 0 then progressPercent = 0 end

      local timerText = string.format("%0.0fs", timeLeft)
      if timeDiff < 0 then
        timerText = string.format("LATE: %0.0fs", math.abs(timeDiff))
      end

      guihooks.trigger('SetTasklistHeader', {label = "BeamEats Delivery"})

      guihooks.trigger('SetTasklistTask', {
        id = "beamEats_phase",
        label = phaseLabel,
        done = false,
        active = true,
        type = "message",
        clear = false
      })
      guihooks.trigger('SetTasklistTask', {
        id = "beamEats_timer",
        label = "Time Limit",
        subtext = timerText,
        percent = progressPercent,
        done = false,
        active = true,
        type = "goal",
        clear = false
      })
end

local function updateOrderOffers(dt)
    local beamEatsDisabled = isBeamEatsDisabled()
    if beamEatsDisabled then
      state = "start"
      shared.requestBeamEatsState()
      return
    end

    jobOfferTimer = jobOfferTimer + dt
    if jobOfferTimer >= jobOfferInterval then

      jobOfferInterval = calculateJobOfferInterval()

      local newOrder = generateOrder()
      if newOrder then
        currentOrder = newOrder
        state = "incoming"
        shared.requestBeamEatsState()

        local layout = phoneLayout.get()
        if layout and layout.fireNotification then
          layout.fireNotification("beamEats.newOrder", {
            title = "New Order",
            message = newOrder.restaurant,
            meta = string.format("$%0.2f · %0.1f km", newOrder.baseFare, newOrder.totalDistance / 1000),
            kind = "invite",
            ttl = 8,
            source = "BeamEats",
            sound = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" },
          })
        end
      else
        jobOfferTimer = 0
        jobOfferInterval = math.random(10, 20)
      end
    end
end

local function update(_, dt)
  timer = timer + dt
  updateTimer = updateTimer + dt
  uiUpdateTimer = uiUpdateTimer + dt

  if updateTimer >= updateInterval then
    updateTimer = 0
    dataToSend = buildBeamEatsStateData()
    statePush.refresh('updateBeamEatsState', dataToSend)
  end

  if M.deliveryData.clearTasklistTimer then
    M.deliveryData.clearTasklistTimer = M.deliveryData.clearTasklistTimer - dt
    if M.deliveryData.clearTasklistTimer <= 0 then
      guihooks.trigger('ClearTasklist')
      M.deliveryData.clearTasklistTimer = nil
    end
  end

  if currentOrder and (state == "pickup" or state == "dropoff") then
    if state == "pickup" then prepareBeamEatsJob(dt) else updateDeliveryDropoff(dt) end
    if uiUpdateTimer >= 0.5 then refreshDeliveryTasklist() end
  end
  if state == "ready" then updateOrderOffers(dt) end
end

-- Lifecycle ---------------------------------------------------------------------------------------

local function onOverhaulEnterVehicleFinished()
  refreshLocations(false)
  loadPlayerRating()
end

local function onClientStartMission()
  releaseRatingFeature()
  restaurants = {}
  allDeliverySpots = nil
  locationsLevelKey = nil
  local ok, err = pcall(function()
    refreshLocations(true)
  end)
  if not ok then
    log('E', 'beamEats', "Error refreshing BeamEats locations on mission start: " .. tostring(err))
  end
end

local function onVehicleSwitched()

  state = "start"
  if currentOrder then
    core_groundMarkers.resetAll()
  end
  currentOrder = nil
  jobOfferTimer = 0
  jobOfferInterval = calculateJobOfferInterval()
  cumulativeReward = 0
  orderStreak = 0

  vehicleMultiplier = 0.1

  if be:getPlayerVehicle(0) and (not gameplay_walk or not gameplay_walk.isWalking()) then
    generateValueMultiplier()
  end
  dataToSend = buildBeamEatsStateData()
  statePush.send('updateBeamEatsState', dataToSend)
end

local function receiveSensorData(gx, gy, gz, gx2, gy2, gz2)
  processSensorData(gx, gy, gz, gx2, gy2, gz2)
end

local function onExtensionLoaded()

  if be:getPlayerVehicle(0) then
    local status, err = pcall(function()
      refreshLocations(true)
      loadPlayerRating(true)
      jobOfferInterval = calculateJobOfferInterval()
    end)
    if not status then
      log('E', 'beamEats', "Error initializing BeamEats: " .. tostring(err))
    end
  end
end

local function isBeamEatsJobActive()
  return state ~= "start" and state ~= "disabled"
end

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  if not ratingLoaded then
    loadPlayerRating()
    if not ratingLoaded then
      ratingLoaded = true
      loadedRatingProfile = overhaul_career_saveSystem.getCurrentProfile()
    end
  end
  savePlayerRating(currentSavePath, writer)
end

-- Public API --------------------------------------------------------------------------------------

M.acceptOrder = shared.startDelivery
M.rejectOrder = rejectOrder
M.setAvailable = setAvailable
M.stopBeamEatsJob = stopBeamEatsJob
M.generateOrder = generateOrder
M.requestBeamEatsState = shared.requestBeamEatsState
M.isBeamEatsJobActive = isBeamEatsJobActive

M.dismissSummary = dismissSummary
M.receiveSensorData = receiveSensorData

M.activity = require('overhaul/jobs/beamEats/activity')(M)

-- Game hooks --------------------------------------------------------------------------------------

M.onExtensionLoaded = onExtensionLoaded
M.onClientStartMission = onClientStartMission
M.onOverhaulEnterVehicleFinished = onOverhaulEnterVehicleFinished
M.onUpdate = update
M.onVehicleSwitched = onVehicleSwitched
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.onOverhaulBeforeSetProfile = function() releaseRatingFeature(); ratingLoaded = false end

return M
