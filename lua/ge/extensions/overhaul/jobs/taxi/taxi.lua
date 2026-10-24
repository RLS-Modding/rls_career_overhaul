-- Taxi fare offers, passenger preferences, ride ratings and completion rewards.
-- Read state and reward rules, passenger registration, locations, fares, ride phases, update and hooks.
local recordRide = require("overhaul/lib/progression/logbookFeed").register("overhaul.taxiRideCompleted", {
  title = "Taxi ride completed", label = "Taxi", icon = "carCoins"
}, "jobs/taxi/taxi.lua")

local M = {}
local shared = {}
M.dependencies = {'gameplay_parking', 'overhaul_vehicles_passengerOccupants'}
local sitesManager = require('overhaul/lib/world/sitesManager').sitesManager

-- Requires ----------------------------------------------------------------------
local core_groundMarkers = require('core/groundMarkers')
local parkingReservation = require('overhaul/lib/parking/reservation').service
local capabilities = require('overhaul/lib/platform/capabilities')
local rewardConfigRules = {}
local defaults = {
  globalRewardMultiplier = 1.0,
  fare = {
    pickupFee = 125, paidKmRate = 110, approachKmRate = 50,
    randomVariation = 0.10, streakBonusPerFare = 0.05, maxStreakBonus = 0.25, maxTipPercent = 0.30,
  },
  xpReward = {base = 150, perPaidKm = 25, maximum = 250},
}

local function defaultFare(fare)
  if type(fare) == "string" then fare = {} end
  for name, value in pairs(defaults.fare) do fare[name] = fare[name] or value end
  return fare
end

local function defaultXp(xpReward)
  if type(xpReward) == "string" then xpReward = {} end
  xpReward.base = tonumber(xpReward.base) or defaults.xpReward.base
  xpReward.perPaidKm = tonumber(xpReward.perPaidKm) or defaults.xpReward.perPaidKm
  xpReward.maximum = tonumber(xpReward.maximum) or defaults.xpReward.maximum
  return xpReward
end

function rewardConfigRules.globalMultiplier(config)
  return math.max(0, tonumber(config.globalRewardMultiplier) or defaults.globalRewardMultiplier)
end

function rewardConfigRules.fare(config)
  local fare = config.fare
  if not fare or type(fare) == 'string' then return defaultFare({}) end
  return fare
end

function rewardConfigRules.xpReward(skillConfig)
  local xpReward = skillConfig.xpReward
  if not xpReward or type(xpReward) == 'string' then return defaultXp({}) end
  return xpReward
end

function rewardConfigRules.normalize(config)
  if type(config) ~= 'table' then return config end
  config.globalRewardMultiplier = rewardConfigRules.globalMultiplier(config)
  config.fare = config.fare or {}
  if type(config.fare) == 'table' then defaultFare(config.fare) end
  config.skill = config.skill or {}
  if type(config.skill) == 'table' then
    config.skill.xpReward = config.skill.xpReward or {}
    if type(config.skill.xpReward) == 'table' then defaultXp(config.skill.xpReward) end
  end
  return config
end
local jobSkillRewards = require('overhaul/lib/jobs/skillRewards')

-- State ----------------------------------------------------------------------
local dataToSend = {}
local cumulativeReward = 0
local fareStreak = 0
local currentFare = nil
local availableSeats = nil
local state = "start"
local timer = 0
local updateTimer = 1
local jobOfferTimer = 0
local jobOfferInterval = math.random(5, 45)

local currentVehiclePartsTree = nil
local vehicleMultiplier = 0.1

local ratingSaveFile = "career/rls_career/taxiRating.json"
local function registerRatingMetadata()
  require('overhaul/lib/save/store').registerKeys({
    {key = "jobs.taxiRating", owner = "overhaul_jobs_taxi_taxi", files = {"career/rls_career/taxiRating.json"}, phase = "profile", required = true},
  })
end

local function createRatingFeature()
  registerRatingMetadata()
  local adapter
  local function bind()
    if adapter then return adapter end
    adapter = assert(require('overhaul/lib/save/store').feature('jobs.taxiRating', {
      owner = 'overhaul_jobs_taxi_taxi',
      files = {ratingSaveFile},
      root = 'slot',
      phase = 'profile',
      required = true,
      writer = {pretty = true},
      capture = function(context, data, writer)
        writer = writer or context.writer
        local directory = context.path():match('^(.*)/[^/]+$')
        if not writer.exists(directory) then writer.mkdir(directory) end
        context.write(data)
      end,
    }))
    local dispose = adapter.dispose
    function adapter.dispose()
      local removed = dispose()
      if removed then registerRatingMetadata() end
      return removed
    end
    return adapter
  end

  -- Extension reload order is not fixed, so the save system may not exist yet when this owner loads. Bind now when it does (a replacement load takes over the key); otherwise at the first save.
  if type(overhaul_career_saveSystem) == 'table' then bind() end
  return {
    isCurrent = function() return adapter ~= nil and adapter.isCurrent() end,
    capture = function(...) return bind().capture(...) end,
    dispose = function()
      if not adapter then return false end
      return adapter.dispose()
    end,
  }
end


local ratingFeature = createRatingFeature()
local playerRating = 2.5
local ratingSum = 0
local ratingCount = 0
local lastPassengerRating = nil
local ratingLoaded = false
local loadedRatingProfile = nil

local parkingSpots = nil
local validPickupSpots = nil
local parkingSpotsLevelKey = nil
local currentReservationToken = nil
local reservedPickupSpot = nil
local reservedDropoffSpot = nil

local suggestedSpeed = 18
local TAXI_REWARD_CONFIG_PATH = "gameplay/overhaul/taxi/rewardConfig.json"
local DEFAULT_TAXI_SKILL_ATTRIBUTE_KEY = "careerSkills-passenger"
local TAXI_SKILL_PATH_IDS = {"careerSkills-passenger", "passenger"}
local taxiRewardConfig = nil

M.rideData = {}

-- Passenger Type System ----------------------------------------------------------------------
local passengerTypes = {
  STANDARD = {
    name = "Standard",
    description = "Regular passengers who value speed and efficiency",
    baseMultiplier = 1.0,
    speedWeight = 1.0,
    distanceWeight = 1.0,
    selectionWeight = 5,
    seatRange = {nil, 10},
    valueRange = {nil, nil},
    fareWeights = {
      {min = 0.5, max = 0.8, weight = 3},
      {min = 0.8, max = 1.2, weight = 5},
      {min = 1.2, max = 1.5, weight = 2}
    },
    speedTolerance = 0.5,
    calculateTipBreakdown = function(fare, elapsedTime, speedFactor, passengerType)
      local tipBreakdown = {}
      local baseFare = tonumber(fare.baseFare) or 0

      if speedFactor > 0 then
        tipBreakdown["Speed Bonus"] = speedFactor * baseFare * passengerType.speedWeight * 0.5
      end

      return tipBreakdown
    end,
    onUpdate = function() end,
    getDescription = function(fare, passengerType)
      return string.format("%s (%d passengers)", passengerType.name, fare.passengers)
    end,
    getPaymentLabel = function(fare, speedFactor, passengerType)
      return speedFactor > 0 and "Speed Bonus" or "Time Penalty"
    end
  }
}

local function getPassengerType(typeKey)
  return passengerTypes[typeKey]
end

local function getTaxiRewardConfig()
  if taxiRewardConfig ~= nil then
    return taxiRewardConfig
  end

  taxiRewardConfig = rewardConfigRules.normalize(jobSkillRewards.loadRewardConfig(TAXI_REWARD_CONFIG_PATH))
  return taxiRewardConfig
end

local function getGlobalTaxiRewardMultiplier()
  return rewardConfigRules.globalMultiplier(getTaxiRewardConfig())
end

local function getTaxiSkillConfig()
  return jobSkillRewards.getSkillConfig(getTaxiRewardConfig())
end

local taxiSkillCache = nil
local taxiSkillCacheFrame = nil
local taxiSkillCacheTick = 0

local function getTaxiSkillContext()
  if taxiSkillCache and taxiSkillCacheFrame == taxiSkillCacheTick then
    return taxiSkillCache.skillConfig, taxiSkillCache.attributeKey, taxiSkillCache.skillLevel
  end
  local skillConfig = getTaxiSkillConfig()
  local attributeKey = jobSkillRewards.getAttributeKey(skillConfig, DEFAULT_TAXI_SKILL_ATTRIBUTE_KEY)
  local skillLevel = jobSkillRewards.getSkillLevel(attributeKey, TAXI_SKILL_PATH_IDS)
  taxiSkillCache = {
    skillConfig = skillConfig,
    attributeKey = attributeKey,
    skillLevel = skillLevel,
  }
  taxiSkillCacheFrame = taxiSkillCacheTick
  return skillConfig, attributeKey, skillLevel
end

local function getTaxiSkillAttributeKey()
  local _, attributeKey = getTaxiSkillContext()
  return attributeKey
end

local function getTaxiSkillLevel()
  local _, _, skillLevel = getTaxiSkillContext()
  return skillLevel
end

local function getTaxiFareBonusMultiplier()
  local skillConfig, _, skillLevel = getTaxiSkillContext()
  return jobSkillRewards.getMoneyBonusMultiplier(skillConfig, skillLevel)
end

local function getTaxiFareBonusPercent()
  local skillConfig, _, skillLevel = getTaxiSkillContext()
  return jobSkillRewards.getMoneyBonusPercent(skillConfig, skillLevel)
end

local function getTaxiSkillRewardAmount(paidDistance)
  local xpReward = rewardConfigRules.xpReward(getTaxiSkillConfig())
  local amount = xpReward.base + math.max(0, tonumber(paidDistance) or 0) / 1000 * xpReward.perPaidKm
  return math.floor(math.max(0, math.min(xpReward.maximum, amount)))
end

local function getTaxiFareConfig()
  return rewardConfigRules.fare(getTaxiRewardConfig())
end

local function getStreakMultiplier()
  local config = getTaxiFareConfig()
  return 1 + math.min(math.max(0, fareStreak) * config.streakBonusPerFare, config.maxStreakBonus)
end

local function capTips(tipBreakdown, baseFare)
  local total = 0
  for key, amount in pairs(tipBreakdown) do
    amount = math.max(0, tonumber(amount) or 0)
    tipBreakdown[key] = amount
    total = total + amount
  end
  local tipCapMoney = math.max(0, baseFare * (getTaxiFareConfig().maxTipPercent))
  if total > tipCapMoney then
    for key, amount in pairs(tipBreakdown) do tipBreakdown[key] = amount * tipCapMoney / total end
    total = tipCapMoney
  end
  return total
end

local function isPassengerTypeUnlocked(passengerType)
  if type(passengerType) ~= "table" then
    return false
  end

  if not passengerType.unlockFlag or passengerType.unlockFlag == "" then
    return true
  end

  if not (overhaul_career_career and overhaul_career_career.isActive()) then
    return true
  end

  return overhaul_career_progression_unlockFlags.getFlag(passengerType.unlockFlag) == true
end

local function buildTaxiStateData(effectiveState)
  local taxiDisabled, disabledReason = shared.isTaxiDisabled()
  local resolvedState = effectiveState or (taxiDisabled and "disabled" or state)

  return {
    state = resolvedState,
    currentFare = currentFare,
    availableSeats = availableSeats,
    vehicleMultiplier = vehicleMultiplier,
    cumulativeReward = cumulativeReward,
    fareStreak = fareStreak,
    currentPassengerType = currentFare and currentFare.passengerTypeName or nil,
    playerRating = playerRating,
    lastPassengerRating = lastPassengerRating,
    taxiDisabled = taxiDisabled,
    disabledReason = disabledReason,
    taxiSkillLevel = getTaxiSkillLevel(),
    taxiFareBonusPercent = getTaxiFareBonusPercent()
  }
end

local function publishTaxiState(newFare)
  local taxiDisabled = shared.isTaxiDisabled()
  local effectiveState = taxiDisabled and "disabled" or state
  -- The builder re-reads availability for the payload, independently of the state selected above.
  dataToSend = buildTaxiStateData(effectiveState)
  if newFare then
    dataToSend.currentFare = newFare
    dataToSend.currentPassengerType = newFare and newFare.passengerTypeName or nil
  end
  guihooks.trigger('updateTaxiState', dataToSend)
end

-- Driver Rating Save/Load ----------------------------------------------------------------------
local function savePlayerRating(currentSavePath, writer)
  if not currentSavePath then return end
  if not (overhaul_career_career and overhaul_career_career.isActive()) then return end
  ratingFeature.capture(currentSavePath, {
    sum = ratingSum,
    count = ratingCount,
    average = playerRating
  }, writer)
end

local function loadPlayerRating(force)
  if not (overhaul_career_career and overhaul_career_career.isActive()) then return end
  local profile, path = overhaul_career_saveSystem.getCurrentProfile()
  if not path then return end
  if not force and ratingLoaded and loadedRatingProfile == profile then return end
  local filePath = path .. "/" .. ratingSaveFile
  local data = jsonReadFile(filePath) or {}
  ratingSum = tonumber(data.sum or 0) or 0
  ratingCount = tonumber(data.count or 0) or 0
  if ratingCount > 0 then
    playerRating = math.max(1.0, math.min(5.0, (ratingSum / ratingCount)))
  else
    playerRating = 2.5
  end
  ratingLoaded = true
  loadedRatingProfile = profile
end

local function selectRandomPassengerType(valueMultiplier, availableSeats)
  local eligibleTypes = {}
  local totalWeight = 0

  for typeKey, passengerType in pairs(passengerTypes) do
    local seatsValid = (not availableSeats) or
             (availableSeats >= (passengerType.seatRange[1] or 1) and
             availableSeats <= (passengerType.seatRange[2] or 999))

    local valueValid = (not valueMultiplier) or
             (valueMultiplier >= (passengerType.valueRange[1] or 0.0) and
             valueMultiplier <= (passengerType.valueRange[2] or 999.0))

    local ratingValid = true
    if passengerType.driverRatingRange then
      local minDriverRating = passengerType.driverRatingRange[1]
      local maxDriverRating = passengerType.driverRatingRange[2]
      ratingValid = (not minDriverRating or playerRating >= minDriverRating) and (not maxDriverRating or playerRating <= maxDriverRating)
    end

    local unlocked = isPassengerTypeUnlocked(passengerType)

    if seatsValid and valueValid and ratingValid and unlocked then
      eligibleTypes[typeKey] = passengerType
      totalWeight = totalWeight + passengerType.selectionWeight
    end
  end

  if totalWeight == 0 then
    return "STANDARD"
  end

  local weightRoll = math.random() * totalWeight
  local cumulativeWeight = 0

  for typeKey, passengerType in pairs(eligibleTypes) do
    cumulativeWeight = cumulativeWeight + passengerType.selectionWeight
    if weightRoll <= cumulativeWeight then
      return typeKey
    end
  end

  return "STANDARD"
end

local function setPassengerCallbacks(passengerTypeData)
  if not passengerTypeData.calculateTipBreakdown then
    passengerTypeData.calculateTipBreakdown = function(fare, elapsedTime, speedFactor, passengerType)
      local tipBreakdown = {}
      local baseFare = tonumber(fare.baseFare) or 0

      if speedFactor > 0 then
        tipBreakdown["Speed Bonus"] = speedFactor * baseFare * passengerType.speedWeight * 0.5
      end

      return tipBreakdown
    end
  end

  if not passengerTypeData.getDescription then
    passengerTypeData.getDescription = function(fare, passengerType)
      return string.format("%s (%d passengers)", passengerType.name, fare.passengers)
    end
  end

  if not passengerTypeData.getPaymentLabel then
    passengerTypeData.getPaymentLabel = function(fare, speedFactor, passengerType)
      return speedFactor > 0 and "Speed Bonus" or "Time Penalty"
    end
  end

  if not passengerTypeData.onUpdate then
    passengerTypeData.onUpdate = function(fare, rideData, passengerType)
      rideData.roughEvents = rideData.roughEvents or 0
      local sensorData = rideData.currentSensorData
      if sensorData then
        local peak = math.max(math.abs(sensorData.gx2 or 0), math.abs(sensorData.gy2 or 0), math.abs(sensorData.gz2 or 0))
        if peak > 0.6 then
          rideData.roughEvents = rideData.roughEvents + 1
        end
      end
    end
  end

  passengerTypeData.driverRatingRange = passengerTypeData.driverRatingRange or {nil, nil}
  if not passengerTypeData.calculateDriverRating then
    passengerTypeData.calculateDriverRating = function(fare, rideData, elapsedTime, speedFactor, passengerType)
      local roughEventCount = (rideData and rideData.roughEvents) or 0
      local baseRating = 5.0 - (roughEventCount * 0.3)
      local speedRatingAdjustment = math.max(-1.0, math.min(1.0, speedFactor or 0)) * 0.5
      local rating = baseRating + speedRatingAdjustment
      if fare and fare.passengers and fare.passengers > 3 then
        rating = rating + 0.2
      end
      return math.max(1.0, math.min(5.0, rating))
    end
  end

end

local function registerPassengerType(key, passengerTypeData)
  passengerTypeData.baseMultiplier = passengerTypeData.baseMultiplier or 1.0
  passengerTypeData.speedWeight = passengerTypeData.speedWeight or 1.0
  passengerTypeData.distanceWeight = passengerTypeData.distanceWeight or 1.0
  passengerTypeData.selectionWeight = passengerTypeData.selectionWeight or 1
  passengerTypeData.speedTolerance = passengerTypeData.speedTolerance or 0.5
  passengerTypeData.unlockFlag = passengerTypeData.unlockFlag or nil

  passengerTypeData.seatRange = passengerTypeData.seatRange or {nil, nil}
  passengerTypeData.valueRange = passengerTypeData.valueRange or {nil, nil}

  if not passengerTypeData.fareWeights and not passengerTypeData.fareRange then
    passengerTypeData.fareWeights = {
      {min = 0.5, max = 0.8, weight = 3},
      {min = 0.8, max = 1.2, weight = 5},
      {min = 1.2, max = 1.5, weight = 2}
    }
  end

  setPassengerCallbacks(passengerTypeData)
  passengerTypes[key] = passengerTypeData
end

local function getPassengerTypes()
  local types = {}
  for typeKey, passengerType in pairs(passengerTypes) do
    table.insert(types, {
      key = typeKey,
      name = passengerType.name,
      description = passengerType.description,
      baseMultiplier = passengerType.baseMultiplier,
      speedWeight = passengerType.speedWeight,
      selectionWeight = passengerType.selectionWeight,
      seatRange = passengerType.seatRange,
      valueRange = passengerType.valueRange,
      unlockFlag = passengerType.unlockFlag,
      fareWeights = passengerType.fareWeights,
      fareRange = passengerType.fareRange,
      driverRatingRange = passengerType.driverRatingRange
    })
  end
  return types
end

local function getCurrentPassengerType()
  if currentFare and currentFare.passengerType then
    return getPassengerType(currentFare.passengerType)
  end
  return nil
end

-- Sensor Data Handling ----------------------------------------------------------------------
local function updateSensorData()
  if not currentFare or state ~= "dropoff" then
    return
  end

  local vehicle = be:getPlayerVehicle(0)
  if not vehicle then return end

  vehicle:queueLuaCommand([[
        local sensors = require('sensors')
        if sensors then
            local gx, gy, gz = sensors.gx or 0, sensors.gy or 0, sensors.gz or 0
            local gx2, gy2, gz2 = sensors.gx2 or 0, sensors.gy2 or 0, sensors.gz2 or 0
            obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(]] .. require('overhaul/lib/vehicles/callbacks').open('taxiSensorData', {owner = 'taxi', vehId = vehicle:getID()}) .. [[, 'taxiSensorData', gx..','..gy..','..gz..','..gx2..','..gy2..','..gz2))
        end
    ]])
end

local function processSensorData(gx, gy, gz, gx2, gy2, gz2)
  local gravityMPS2 = 9.81 -- Preserve the historical sensor conversion.
  M.rideData.currentSensorData = {
    gx = gx / gravityMPS2, gy = gy / gravityMPS2, gz = gz / gravityMPS2,
    gx2 = gx2 / gravityMPS2, gy2 = gy2 / gravityMPS2, gz2 = gz2 / gravityMPS2,
    timestamp = os.time()
  }

  if currentFare and currentFare.passengerType then
    local passengerType = getPassengerType(currentFare.passengerType)
    if passengerType and passengerType.onUpdate then
      passengerType.onUpdate(currentFare, M.rideData, passengerType)
    end
  end
end

-- Location And Site Management ----------------------------------------------------------------------
local function getParkingSpotsLevelKey()
  local level = getCurrentLevelIdentifier()
  if level and level ~= "" then return level end
  return getMissionFilename() or ""
end

local function findParkingSpots(force)
  local levelKey = getParkingSpotsLevelKey()
  if not force and parkingSpots and parkingSpotsLevelKey == levelKey then
    return parkingSpots
  end
  local sitePath = sitesManager().getCurrentLevelSitesFileByName('city')
  if sitePath then
    local siteData = sitesManager().loadSites(sitePath, true, true)
    local loadedParkingSpots = siteData and siteData.parkingSpots
    if loadedParkingSpots and loadedParkingSpots.objects then
      parkingSpots = loadedParkingSpots
      parkingSpotsLevelKey = levelKey
    else
      parkingSpots = nil
      parkingSpotsLevelKey = nil
    end
  else
    parkingSpots = nil
    parkingSpotsLevelKey = nil
  end
  return parkingSpots
end

local function findValidPickupSpots()
  local validPickupSpots = {}
  if not be:getPlayerVehicle(0) then return end
  local playerPos = be:getPlayerVehicle(0):getPosition()

  if not parkingSpots then
    findParkingSpots()
  end
  if not parkingSpots or not parkingSpots.objects then
    return validPickupSpots
  end
  for _, spot in pairs(parkingSpots.objects) do
    if spot.pos and (spot.pos - playerPos):length() < 500 then
      table.insert(validPickupSpots, spot)
    end
  end
  return validPickupSpots
end

local function safeSpotPath(spot)
  if spot and spot.getPath then
    local ok, path = pcall(function() return spot:getPath() end)
    if ok then
      return path
    end
  end
end

local function releasePickupReservation()
  if reservedPickupSpot and currentReservationToken then
    parkingReservation.releaseSpot(reservedPickupSpot, currentReservationToken)
  end
  reservedPickupSpot = nil
end

local function releaseDropoffReservation()
  if reservedDropoffSpot and currentReservationToken then
    parkingReservation.releaseSpot(reservedDropoffSpot, currentReservationToken)
  end
  reservedDropoffSpot = nil
end

local function releaseReservations()
  releasePickupReservation()
  releaseDropoffReservation()
  currentReservationToken = nil
end

local function reserveTaxiSpots(pickupCandidates, dropoffCandidates)
  releaseReservations()

  currentReservationToken = parkingReservation.makeReservationToken("taxi")
  local livePickup = parkingReservation.findReservableSpot(parkingReservation.shuffleSpots(pickupCandidates), currentReservationToken)
  if not livePickup then
    releaseReservations()
    return nil, nil
  end

  local filteredDropoffs = {}
  local pickupPath = safeSpotPath(livePickup)
  if not pickupPath then
    parkingReservation.releaseSpot(livePickup, currentReservationToken)
    releaseReservations()
    return nil, nil
  end

  for _, spot in ipairs(parkingReservation.shuffleSpots(dropoffCandidates)) do
    local liveSpot = parkingReservation.resolveLiveSpot(spot)
    local dropoffPath = liveSpot and safeSpotPath(liveSpot)
    if liveSpot and dropoffPath and dropoffPath ~= pickupPath then
      table.insert(filteredDropoffs, liveSpot)
    end
  end

  local liveDropoff = parkingReservation.findReservableSpot(filteredDropoffs, currentReservationToken)
  if not liveDropoff then
    parkingReservation.releaseSpot(livePickup, currentReservationToken)
    releaseReservations()
    return nil, nil
  end

  reservedPickupSpot = livePickup
  reservedDropoffSpot = liveDropoff
  return livePickup, liveDropoff
end

-- Vehicle Capacity Calculations ----------------------------------------------------------------------
local function retrievePartsTree()
  currentVehiclePartsTree = nil
  local vehicle = be:getPlayerVehicle(0)
  if vehicle then
    vehicle:queueLuaCommand(
      [[
                local partsTree = v.config.partsTree
                obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(]] .. require('overhaul/lib/vehicles/callbacks').open('taxiPartsTree', {owner = 'taxi', vehId = vehicle:getID()}) .. [[, 'taxiPartsTree', serialize(partsTree)))
            ]]
    )
  end
end

local function specificCapcityCases(partName)
  if partName:find("capsule") and partName:find("seats") then
   if partName:find("sd12m") then return 25
   elseif partName:find("sd18m") then return 41
   elseif partName:find("sd105") then return 21
   elseif partName:find("sd_seats") then return 33
   elseif partName:find("dd105") then return 29
   elseif partName:find("sd195") then return 43
   elseif partName:find("lhd_artic_seats_upper") then return 77
   elseif partName:find("lhd_artic_seats") then return 30
   elseif partName:find("lh_seats_upper") then return 53
   elseif partName:find("lh_seats") then return 17
   elseif partName:find("lhd_seats_upper") then return 53
   elseif partName:find("lhd_seats") then return 17
   elseif partName:find("rhd_artic_seats_upper") then return 77
   elseif partName:find("rhd_artic_seats") then return 30 end
  end
  if partName:find("schoolbus_seats_r_c")  then
   return 10
  end
  if partName:find("schoolbus_seats_l_c")  then
   return 10
  end
  if partName:find("limo_seat") then return 8 end
  return nil
end

local function countOccupantSlots(parts)
  local count, hasSlots = 0, false
  for _, part in pairs(parts or {}) do
   if (part.id or ""):match("^seat_occupant") then
    hasSlots = true
    if part.chosenPartName and part.chosenPartName ~= "" then count = count + 1 end
   else
    local childCount, childSlots = countOccupantSlots(part.children)
    count, hasSlots = count + childCount, hasSlots or childSlots
   end
  end
  return count, hasSlots
end

local function cyclePartsTree(partData, seatingCapacity)
  for first, part in pairs(partData) do
   local partName = (part.chosenPartName or ""):lower()
   local slotName = (part.id or ""):lower()
   local countedOccupants = false
   if partName:find("seat") and not partName:find("cargo") and not partName:find("captains")
    and not partName:match("^seat_race_") and not slotName:match("^race_seat_")
    and not partName:find("occupant") and not partName:match("_space$")
    and not slotName:find("occupant") and not slotName:match("_space$") then
    local seatSize = nil
    if partName:find("seats") then
     seatSize = 3
    elseif partName:find("ext") then
     seatSize = 2
    else
     if partName:match("(%d+)r") then
      seatSize = 2
     else
      seatSize = 1
     end
    end
    if partName:find("citybus_seats") then seatSize = 44
    elseif partName:find("skin") then seatSize = 0 end
    local occupantCount, hasOccupants = countOccupantSlots(part.children)
    if hasOccupants then seatSize, countedOccupants = occupantCount, true end
    seatSize = specificCapcityCases(partName) or seatSize
    seatingCapacity = seatingCapacity + seatSize
   end
   if part.children and not countedOccupants then
    seatingCapacity = cyclePartsTree(part.children, seatingCapacity)
   end
   if partName == "pickup" then
    seatingCapacity = math.max(seatingCapacity, 7)
   end
  end
  return seatingCapacity
end

local function calculateSeatingCapacity()
  if not currentVehiclePartsTree then
    retrievePartsTree()
  end
  return cyclePartsTree({currentVehiclePartsTree}, 0)
end
shared.isTaxiDisabled = function()
  local disabled = false
  local reason = ""

  if gameplay_walk and gameplay_walk.isWalking() then
    disabled = true
    reason = "Taxi service is not available while walking"
    return disabled, reason
  end

  local vehicle = be:getPlayerVehicle(0)
  if vehicle then
    local vehId = vehicle:getID()
    if overhaul_career_career and overhaul_career_career.isActive() then
      local vehicleLoans = capabilities.get("vehicleLoans")
      local loaningOrgs = vehicleLoans and vehicleLoans.getLoaningOrgsOfVehicle
        and vehicleLoans.getLoaningOrgsOfVehicle(vehId)
      if loaningOrgs and next(loaningOrgs) then
        disabled = true
        reason = "Taxi service is not available in loaned vehicles"
        return disabled, reason
      end
    end
  end

  local taxiMultiplier = overhaul_career_economyAdjuster.getSectionMultiplier("taxi") or 1.0
  if taxiMultiplier == 0 then
    disabled = true
    reason = "Taxi multiplier is set to 0"
  end

  if overhaul_career_challengeModes.isChallengeActive() then
    local activeChallenge = overhaul_career_challengeModes.getActiveChallenge()
    if activeChallenge then
      if activeChallenge.economyAdjuster and activeChallenge.economyAdjuster.taxi == 0 then
        disabled = true
        reason = string.format("Taxi is disabled due to '%s' Challenge", activeChallenge.name or "Unknown Challenge")
      end
    end
  end

  return disabled, reason
end

local function calculateCapacity(vehicleId)
  if not vehicleId then
    vehicleId = be:getPlayerVehicle(0):getID()
  end
  if overhaul_career_career and overhaul_career_career.isActive() then
    local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehicleId)
    if not inventoryId then
      return 0
    end
  end
  local seatingCapacity = calculateSeatingCapacity()
  availableSeats = math.max(0, seatingCapacity - 1)
  publishTaxiState()
  return availableSeats
end

-- Fare Generation And Calculation ----------------------------------------------------------------------
local function calculatePassengerCount()
  if availableSeats <= 0 then
    return 0
  end
  local weights = {}
  local total = 0

  for i = 1, availableSeats do
    weights[i] = (availableSeats - i + 1)
    total = total + weights[i]
  end

  local weightRoll = math.random(total)
  local cumulative = 0

  for i = 1, availableSeats do
    cumulative = cumulative + weights[i]
    if weightRoll <= cumulative then
      return i
    end
  end
  return 1
end

local function calculatePassengerCountForType(passengerType)
  if not passengerType then
    return calculatePassengerCount()
  end
  if not availableSeats or availableSeats <= 0 then
    return 0
  end
  local minSeats = passengerType.seatRange and passengerType.seatRange[1] or 1
  local maxSeats = passengerType.seatRange and passengerType.seatRange[2] or availableSeats
  minSeats = math.max(1, minSeats or 1)
  maxSeats = math.min(availableSeats, maxSeats or availableSeats)
  if minSeats > maxSeats then
    minSeats = maxSeats
  end
  local weights = {}
  local total = 0
  for i = minSeats, maxSeats do
    local w = (i - minSeats + 1)
    weights[i] = w
    total = total + w
  end
  local weightRoll = math.random(total)
  local cumulative = 0
  for i = minSeats, maxSeats do
    cumulative = cumulative + weights[i]
    if weightRoll <= cumulative then
      return i
    end
  end
  return minSeats
end

local function generateFareMultiplier(passengerTypeKey)
  local variation = math.max(0, math.min(1, getTaxiFareConfig().randomVariation))
  return 1 + (math.random() * 2 - 1) * variation
end

local function calculateDrivingDistance(startPos, endPos)
  local path = map.getPointToPointPath(startPos, endPos, 0, 1000, 200, 10000, 1)

  if not path or #path == 0 then
    -- Fallback to straight-line distance if no path found
    return startPos:distance(endPos)
  end

  local totalDistance = 0
  local prevNodePos = startPos

  for i = 1, #path do
    local nodePos = map.getMap().nodes[path[i]].pos
    if nodePos then
      totalDistance = totalDistance + prevNodePos:distance(nodePos)
      prevNodePos = nodePos
    end
  end

  totalDistance = totalDistance + prevNodePos:distance(endPos)

  return totalDistance
end

local function calculateBaseFare(passengerCount, totalDistance, valueMultiplier, selectedPassengerType, approachDistance)
  local config = getTaxiFareConfig()
  local services = config.serviceMultipliers or {}
  local service = services[string.upper(selectedPassengerType.name)] or 1
  local baseFare = config.pickupFee
    + math.max(0, totalDistance or 0) / 1000 * config.paidKmRate * service
    + math.max(0, approachDistance or 0) / 1000 * config.approachKmRate
  baseFare = baseFare * getGlobalTaxiRewardMultiplier()
  local economyMultiplier = 1.0

  if overhaul_career_economyAdjuster then
    local passengerTypeKey = string.format("taxi_%s", selectedPassengerType.name:lower())
    local taxiMultiplier = overhaul_career_economyAdjuster.getSectionMultiplier("taxi") or 1.0
    economyMultiplier = taxiMultiplier
    for _, typeName in ipairs(overhaul_career_economyAdjuster.getAvailableTypes()) do
      if typeName == passengerTypeKey then
        economyMultiplier = overhaul_career_economyAdjuster.getSectionMultiplier(passengerTypeKey) or 1.0
        break
      end
    end
    baseFare = baseFare * economyMultiplier
    if economyMultiplier ~= 1.0 then
    end
  end

  baseFare = baseFare * getTaxiFareBonusMultiplier()

  baseFare = math.floor(baseFare + 0.5)

  return baseFare, economyMultiplier
end

local function generateValueMultiplier()
  if not (overhaul_career_career and overhaul_career_career.isActive()) then
    return 1
  end
  local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(be:getPlayerVehicle(0):getID())
  if not inventoryId then
    return 0
  end
  local rawMultiplier = (overhaul_career_market_valueCalculator.getInventoryVehicleValue(inventoryId) / 30000) ^ 0.5
  vehicleMultiplier = 1 + ((rawMultiplier - 1) * 0.35)
  vehicleMultiplier = math.max(vehicleMultiplier, 0.1)
  vehicleMultiplier = math.floor((vehicleMultiplier * 10) + 0.5) / 10
  return vehicleMultiplier
end

local function reserveFareLocations()
  local dropoffSpots = {}
  local minDistance = 600
  local pickupSpot, dropoffSpot

  local shuffledPickups = parkingReservation.shuffleSpots(validPickupSpots)
  for _, candidatePickup in ipairs(shuffledPickups) do
    if candidatePickup.pos then
      table.clear(dropoffSpots)
      for _, spot in pairs(parkingSpots.objects or {}) do
        if spot.pos and spot ~= candidatePickup and candidatePickup.pos:distance(spot.pos) >= minDistance then
          table.insert(dropoffSpots, spot)
        end
      end

      pickupSpot, dropoffSpot = reserveTaxiSpots({candidatePickup}, dropoffSpots)
      if pickupSpot and dropoffSpot then
        break
      end
    end
  end

  return pickupSpot, dropoffSpot
end

local function generateJob()
  local taxiDisabled = shared.isTaxiDisabled()
  if taxiDisabled then
    return false
  end
  validPickupSpots = findValidPickupSpots()
  if not validPickupSpots or #validPickupSpots == 0 then
    return false
  end
  local pickupSpot, dropoffSpot = reserveFareLocations()
  if not pickupSpot or not dropoffSpot then
    return false
  end
  if not availableSeats or availableSeats == 0 then
    calculateCapacity(be:getPlayerVehicle(0):getID())
  end
  local valueMultiplier = generateValueMultiplier()
  local selectedPassengerTypeKey = selectRandomPassengerType(valueMultiplier, availableSeats)
  local selectedPassengerType = getPassengerType(selectedPassengerTypeKey)
  local passengerCount = calculatePassengerCountForType(selectedPassengerType)
  local fareMultiplier = generateFareMultiplier(selectedPassengerTypeKey)
  local actualDistance = calculateDrivingDistance(pickupSpot.pos, dropoffSpot.pos)
  local playerVehicle = be:getPlayerVehicle(0)
  local approachDistance = playerVehicle and calculateDrivingDistance(playerVehicle:getPosition(), pickupSpot.pos) or 0
  local baseFareCalc, economyMultiplier = calculateBaseFare(passengerCount, actualDistance, valueMultiplier, selectedPassengerType, approachDistance)
  local baseFare = fareMultiplier * baseFareCalc * getStreakMultiplier()
  local variation = math.max(0, math.min(1, getTaxiFareConfig().randomVariation))
  local passengerRating = variation > 0 and 1 + ((fareMultiplier - (1 - variation)) / (2 * variation)) * 4 or 3
  local fields = dropoffSpot.customFields
  local destinationName = fields and fields:has("name") and fields:get("name")
  if type(destinationName) ~= "string" or destinationName == "" then destinationName = "Taxi destination" end
  local fare = {
    pickup = {
      pos = pickupSpot.pos,
      spotPath = safeSpotPath(pickupSpot)
    },
    destination = {
      pos = dropoffSpot.pos,
      spotPath = safeSpotPath(dropoffSpot),
      name = destinationName
    },
    baseFare = baseFare,
    initialBaseFare = baseFare, -- Freeze pay and both routed legs at offer generation.
    approachDistance = approachDistance,
    paidDistance = actualDistance,
    totalDistance = actualDistance,
    economyMultiplier = economyMultiplier or 1.0, -- Store combined economy multiplier for pay
    demandMultiplier = (overhaul_career_career and overhaul_career_career.isActive() and overhaul_career_economy_activityHeat.getDemandFactor("taxi")) or 1.0,
    valueMultiplier = valueMultiplier,
    passengers = passengerCount,
    passengerRating = string.format("%.1f", passengerRating),
    passengerType = selectedPassengerTypeKey,
    passengerTypeName = selectedPassengerType.name,
    passengerDescription = selectedPassengerType.description
  }
  currentFare = fare
  return fare
end

local function calculateSpeedFactor()
  if not currentFare then
    return 0
  end
  local elapsedTime = os.difftime(os.time(), currentFare.startTime)
  local actualSpeed = (currentFare.paidDistance or currentFare.totalDistance or 0) / math.max(1, elapsedTime)

  return (actualSpeed - suggestedSpeed) / suggestedSpeed
end

-- Job Lifecycle Management ----------------------------------------------------------------------
shared.startRide = function(fare)
  local taxiDisabled = shared.isTaxiDisabled()
  if taxiDisabled then

    return
  end

  if not fare and not currentFare then

    return
  end
  if not currentFare then
    currentFare = fare
  end

  currentFare.startTime = os.time()
  state = "pickup"
  M.rideData = {}
end

local function prepareRideCompletion()
  overhaul_vehicles_passengerOccupants.clear('taxi')

  local elapsedTime = os.difftime(os.time(), currentFare.startTime)
  local speedFactor = calculateSpeedFactor()

  local passengerType = getPassengerType(currentFare.passengerType)
  if not passengerType then
    passengerType = getPassengerType("STANDARD")
  end

  currentFare.completed = true
  fareStreak = fareStreak + 1

  local baseFare = currentFare.initialBaseFare
  if not baseFare then
    local baseFareCalc, ecoMult = calculateBaseFare(currentFare.passengers, currentFare.paidDistance or currentFare.totalDistance, currentFare.valueMultiplier, passengerType, currentFare.approachDistance)
    baseFare = baseFareCalc
    currentFare.economyMultiplier = ecoMult or 1.0
  end

  currentFare.baseFare = string.format("%.2f", baseFare)

  local tipBreakdown = {}
  if passengerType.calculateTipBreakdown then
    tipBreakdown = passengerType.calculateTipBreakdown(currentFare, elapsedTime, speedFactor, passengerType)
  else
    -- Fallback for STANDARD type
    local speedTip = speedFactor > 0 and (speedFactor * baseFare * 0.5) or 0
    tipBreakdown = speedFactor > 0 and {["Speed Bonus"] = speedTip} or {}
  end

  local totalTips = capTips(tipBreakdown, baseFare)

  local finalPayment = baseFare + totalTips

  currentFare.totalTips = string.format("%.2f", totalTips)
  currentFare.tipBreakdown = tipBreakdown
  currentFare.totalFare = string.format("%.2f", finalPayment)

  local keyCount = 0
  for _ in pairs(tipBreakdown) do
    keyCount = keyCount + 1
  end
  currentFare.timeMultiplier = string.format("%.1f", 1 + speedFactor)
  currentFare.totalDistanceKm = (currentFare.paidDistance or currentFare.totalDistance or 0) / 1000

  return elapsedTime, speedFactor, passengerType, finalPayment
end

local function presentRideCompletion(elapsedTime, speedFactor, passengerType)
  local passengerGivenRating
  if passengerType and passengerType.calculateDriverRating then
    passengerGivenRating = tonumber(passengerType.calculateDriverRating(currentFare, M.rideData, elapsedTime, speedFactor, passengerType)) or 5.0
  else
    passengerGivenRating = 5.0
  end
  lastPassengerRating = passengerGivenRating
  ratingSum = ratingSum + passengerGivenRating
  ratingCount = ratingCount + 1
  playerRating = math.max(1.0, math.min(5.0, ratingSum / math.max(1, ratingCount)))

  state = "complete"
  if overhaul_phone_phone and not overhaul_phone_phone.isPhoneOpen() then

    overhaul_phone_phone.togglePhone("You completed a taxi fare! Open the phone to view your earnings.")
  end

  publishTaxiState()

  local fareDescription = passengerType.getDescription(currentFare, passengerType)
  local paymentLabel = passengerType.getPaymentLabel(currentFare, speedFactor, passengerType)

  local label = string.format("Taxi fare: %s: $%s\nDistance: %.2fkm | %s: x %.2f",
    fareDescription, currentFare.totalFare, currentFare.totalDistanceKm, paymentLabel, currentFare.timeMultiplier)

  core_groundMarkers.resetAll()
  releaseReservations()

  return fareDescription, paymentLabel, label
end

local function settleRideCompletion(finalPayment, fareDescription, paymentLabel, label)
  if not (overhaul_career_career and overhaul_career_career.isActive()) then
    return
  end

  local rewardData = {
    money = {
      amount = math.floor(finalPayment)
    },
    [getTaxiSkillAttributeKey()] = {
      amount = getTaxiSkillRewardAmount(currentFare.paidDistance or currentFare.totalDistance)
    }
  }
  overhaul_career_economy_difficultyMode.scalePaymentRewardData(rewardData, {includeMoney = false})
  local awardedMoney = (rewardData.money and rewardData.money.amount) or math.floor(finalPayment)
  local awardedTaxiSkillXp = (rewardData[getTaxiSkillAttributeKey()] and rewardData[getTaxiSkillAttributeKey()].amount) or 0
  cumulativeReward = cumulativeReward + awardedMoney
  currentFare.totalFare = string.format("%.2f", awardedMoney)
  currentFare.taxiSkillXpAwarded = awardedTaxiSkillXp
  local surgeText = overhaul_career_economy_activityHeat.formatSurgeBonusText(currentFare.demandMultiplier or "taxi")
  label = string.format("Taxi fare: %s: $%s%s\nDistance: %.2fkm | %s: x %.2f",
    fareDescription, currentFare.totalFare, surgeText, currentFare.totalDistanceKm, paymentLabel, currentFare.timeMultiplier)
  dataToSend = buildTaxiStateData()
  dataToSend.currentFare = currentFare
  guihooks.trigger('updateTaxiState', dataToSend)

  local skillXpByAttribute = {}
  for key, entry in pairs(rewardData) do
    if key ~= "money" then skillXpByAttribute[key] = entry.amount end
  end
  local paid, problem = overhaul_career_economy_payment.payout({
    amount = rewardData.money and rewardData.money.amount,
    xp = skillXpByAttribute,
    label = label,
    tags = {"transport", "taxi"},
    category = "activity:taxi",
    reason = {finance = {
      source = "taxi", sourceName = "Taxi",
      vehicleId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(be:getPlayerVehicleID(0)),
      locationId = currentFare.destination and currentFare.destination.spotPath,
      locationName = currentFare.destination and currentFare.destination.name or "Taxi destination",
    }},
    fullReward = true
  })
  -- Completion and dropoff historically survive refusal; do not retry an already completed fare.
  if paid ~= true then
    log("W", "taxi", "Fare payout refused: " .. tostring(problem))
  else
    recordRide({detail = currentFare.destination and currentFare.destination.name or "Taxi destination",
      money = rewardData.money and rewardData.money.amount})
  end
  overhaul_career_garage_inventory.addTaxiDropoff(overhaul_career_garage_inventory.getInventoryIdFromVehicleId(be:getPlayerVehicleID(0)), currentFare.passengers)
  core_groundMarkers.resetAll()
end

local function completeRide()
  if not currentFare or currentFare.completed then return end
  local elapsedTime, speedFactor, passengerType, finalPayment = prepareRideCompletion()
  local fareDescription, paymentLabel, label = presentRideCompletion(elapsedTime, speedFactor, passengerType)
  settleRideCompletion(finalPayment, fareDescription, paymentLabel, label)
end

local function rejectJob()
  overhaul_vehicles_passengerOccupants.clear('taxi')
  releaseReservations()
  state = "ready"
  currentFare = nil
  core_groundMarkers.resetAll()
  fareStreak = 0
  jobOfferTimer = 0
  jobOfferInterval = math.random(5, 45)
  dataToSend = {}
end

local function stopTaxiJob()
  if overhaul_vehicles_passengerOccupants then overhaul_vehicles_passengerOccupants.clear('taxi') end
  releaseReservations()
  state = "start"
  currentFare = nil
  core_groundMarkers.resetAll()
  jobOfferTimer = 0
  jobOfferInterval = math.random(5, 45)
  cumulativeReward = 0
  fareStreak = 0
  dataToSend = {}
end

local function setAvailable()
  local taxiDisabled = shared.isTaxiDisabled()
  if taxiDisabled then

    shared.requestTaxiState()
    return
  end

  state = "ready"
  jobOfferTimer = 0
  jobOfferInterval = math.random(5, 45)
  dataToSend = {}
  shared.requestTaxiState()
end

-- Ui And Data Management ----------------------------------------------------------------------
local function prepareTaxiJob()
  calculateCapacity(be:getPlayerVehicle(0):getID())
  local multiplier = generateValueMultiplier()
  return {
    seats = availableSeats,
    multiplier = string.format("%.1f", multiplier)
  }
end

shared.requestTaxiState = function()
  prepareTaxiJob()
  publishTaxiState()
end

local function getTaxiJob()
  prepareTaxiJob()
  if not currentFare then
    shared.startRide(generateJob())
  end
end

-- Update Loop ----------------------------------------------------------------------
local function updateRidePickup()
    if core_groundMarkers.getPathLength() == 0 then
      core_groundMarkers.setPath(currentFare.pickup.pos, {clearPathOnReachingTarget = true})
    end

    local vehicle = be:getPlayerVehicle(0)
    if not vehicle then return false end
    local distToPickup = (vehicle:getPosition() - currentFare.pickup.pos):length()

    if distToPickup < 5 then
      releasePickupReservation()
      state = "dropoff"
      overhaul_vehicles_passengerOccupants.setPassengers('taxi', vehicle:getID(), currentFare.passengers)
      core_groundMarkers.setPath(currentFare.destination.pos, {clearPathOnReachingTarget = true})
      currentFare.startTime = os.time()
      -- Only the passenger leg is used for speed, tips and skill XP.
      currentFare.paidDistance = currentFare.paidDistance or calculateDrivingDistance(currentFare.pickup.pos, currentFare.destination.pos)
      currentFare.totalDistance = currentFare.paidDistance
      M.rideData = {}
      publishTaxiState()
    end
  return true
end

local function updateRideDropoff()
    if core_groundMarkers.getPathLength() == 0 then
      core_groundMarkers.setPath(currentFare.destination.pos, {clearPathOnReachingTarget = true})
    end

    updateSensorData()

    local vehicle = be:getPlayerVehicle(0)
    if not vehicle then return false end
    local vehiclePos = vehicle:getPosition()
    local destDist = (vehiclePos - currentFare.destination.pos):length()

    if destDist < 5 then
      completeRide()
    end
  return true
end

local function updateFareOffers()
    local taxiDisabled = shared.isTaxiDisabled()
    if taxiDisabled then
      -- If taxi becomes disabled while ready, update UI and stay in start state

      state = "start"
      shared.requestTaxiState()
      return
    end

    jobOfferTimer = jobOfferTimer + 1
    if jobOfferTimer >= jobOfferInterval then
      local newFare = generateJob()
      if newFare then
        state = "accept"
        if overhaul_phone_phone and not overhaul_phone_phone.isPhoneOpen() then

          overhaul_phone_phone.togglePhone("You have a new taxi fare! Open the phone to view the details.")
        end
      else
        jobOfferTimer = 0
        jobOfferInterval = math.random(5, 45)
      end

      if newFare then
        publishTaxiState(newFare)
      end
    end
end

local function update(_, dtSimSeconds)
  taxiSkillCacheTick = taxiSkillCacheTick + 1
  timer = timer + dtSimSeconds
  if timer < updateTimer then
    return
  end
  timer = 0

  if currentFare and state == "pickup" and not updateRidePickup() then return end
  if currentFare and state == "dropoff" and not updateRideDropoff() then return end
  if state == "ready" then updateFareOffers() end
end

-- Event Handlers ----------------------------------------------------------------------
local function onOverhaulEnterVehicleFinished()
  findParkingSpots(false)
  loadPlayerRating()
end

local function onClientStartMission()
  parkingSpots = nil
  validPickupSpots = nil
  parkingSpotsLevelKey = nil
end

local function onVehicleSwitched(oldId, newId, player)
  if player and player ~= 0 then return end
  if oldId and oldId == newId then return end
  overhaul_vehicles_passengerOccupants.clear('taxi')
  currentVehiclePartsTree = nil
  -- Reset taxi job state when switching vehicles
  state = "start"
  if currentFare then
    core_groundMarkers.resetAll()
  end
  releaseReservations()
  currentFare = nil
  jobOfferTimer = 0
  jobOfferInterval = math.random(5, 45)
  cumulativeReward = 0
  fareStreak = 0

  availableSeats = 0
  vehicleMultiplier = 0.1

  if be:getPlayerVehicle(0) and not (gameplay_walk and gameplay_walk.isWalking()) then
    calculateCapacity(be:getPlayerVehicle(0):getID())
    generateValueMultiplier()
  end

  publishTaxiState()
end

local function returnPartsTree(partsTree)
  currentVehiclePartsTree = partsTree
  calculateCapacity()
end

local function receiveSensorData(gx, gy, gz, gx2, gy2, gz2)
  processSensorData(gx, gy, gz, gx2, gy2, gz2)
end

-- Module Loading System ----------------------------------------------------------------------
-- Passenger types are require-only libraries; each registers itself with this module.
local passengerModules = {
  require('overhaul/jobs/taxi/passengers/business'),
  require('overhaul/jobs/taxi/passengers/commuter'),
  require('overhaul/jobs/taxi/passengers/executive'),
  require('overhaul/jobs/taxi/passengers/family'),
  require('overhaul/jobs/taxi/passengers/luxury'),
  require('overhaul/jobs/taxi/passengers/party'),
  require('overhaul/jobs/taxi/passengers/student'),
  require('overhaul/jobs/taxi/passengers/thrill'),
  require('overhaul/jobs/taxi/passengers/tourist'),
}

local function loadPassengerModules()

  for _, passengerModule in ipairs(passengerModules) do
    passengerModule.register(M)
  end
end

local function onExtensionLoaded()

  loadPassengerModules()
  loadPlayerRating(true)
end

local function isTaxiJobActive()
  return state ~= "start"
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

-- Module Exports ----------------------------------------------------------------------
M.onExtensionLoaded = onExtensionLoaded
M.onClientStartMission = onClientStartMission
M.onOverhaulEnterVehicleFinished = onOverhaulEnterVehicleFinished
M.onUpdate = update
M.onVehicleSwitched = onVehicleSwitched
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.onOverhaulBeforeSetProfile = function() ratingLoaded = false; stopTaxiJob() end
M.onClientEndMission = stopTaxiJob
M.onExtensionUnloaded = function()
  stopTaxiJob()
  ratingFeature.dispose()
end
M.onOverhaulActive = function(active) if active == false then stopTaxiJob() end end

M.acceptJob = shared.startRide
M.rejectJob = rejectJob
M.setAvailable = setAvailable
M.stopTaxiJob = stopTaxiJob
M.generateJob = generateJob
M.getTaxiJob = getTaxiJob
M.prepareTaxiJob = prepareTaxiJob
M.requestTaxiState = shared.requestTaxiState
M.isTaxiJobActive = isTaxiJobActive

M.registerPassengerType = registerPassengerType
M.getPassengerTypes = getPassengerTypes
M.getCurrentPassengerType = getCurrentPassengerType
M.selectRandomPassengerType = selectRandomPassengerType
M.getPassengerType = getPassengerType

M.updateSensorData = updateSensorData
M.returnPartsTree = returnPartsTree
M.receiveSensorData = receiveSensorData

-- This load's activity definition, adopted by the activity host; it delegates to the functions above (no projection: the payload builder fills the job's skill cache).
M.activity = require('overhaul/jobs/taxi/activity')(M)

return M
