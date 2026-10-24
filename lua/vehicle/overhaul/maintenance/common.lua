-- Pure maintenance curves, interval/capacity calibration and symptom sampling shared by category physics.
-- Read tuning, scalar/copy helpers, mileage/wear, power/load factors, then RNG helpers.
local M = {}

local max = math.max
local min = math.min
local random = math.random
local abs = math.abs

local units = require('common/overhaul/units')
M.milesToMeters = units.METERS_PER_MILE
M.metersToMiles = 1 / M.milesToMeters

-- Config ------------------------------------------------------------------------------------------

local defaultServiceTargetValue = 0.25
local psToWatt = 735.499

local mileageAgeIndexPoints = {
  {0, 1.0},
  {50000, 1.5},
  {100000, 2.0},
  {150000, 3.0},
  {200000, 5.0},
  {250000, 6.5},
  {300000, 8.0}
}

local levelMileageCaps = {
  oilLevel = 12,
  coolantLevel = 260 / 30,
  fluidLevel = 220 / 35
}

local referenceCapacities = {
  oil = 4,
  coolant = 5,
  transmission = 6
}

local classConditionIntervalMultipliers = {
  passenger = 1,
  lightTruck = 1.15,
  mediumTruck = 1.4,
  heavyTruck = 1.75
}

local classDefaultCapacities = {
  passenger = {oil = 4, coolant = 5, transmission = 6},
  lightTruck = {oil = 6, coolant = 8, transmission = 9},
  mediumTruck = {oil = 10, coolant = 15, transmission = 14},
  heavyTruck = {oil = 18, coolant = 25, transmission = 20}
}

-- State -------------------------------------------------------------------------------------------

local intervalCalibrationCache = {}

-- Helpers -----------------------------------------------------------------------------------------

local function clamp(value, minValue, maxValue)
  if value < minValue then
    return minValue
  end
  if value > maxValue then
    return maxValue
  end
  return value
end

local function lerp(a, b, t)
  return a + (b - a) * clamp(t, 0, 1)
end

local function linearScale(value, valueA, valueB, scaleA, scaleB)
  if valueA == valueB then
    return scaleB
  end
  return lerp(scaleA, scaleB, (value - valueA) / (valueB - valueA))
end

local function shallowCopy(source)
  local result = {}
  if type(source) ~= "table" then
    return result
  end
  for key, value in pairs(source) do
    result[key] = value
  end
  return result
end

local function getAverageMaintenance(maintenance)
  if type(maintenance) ~= "table" then
    return 1
  end
  local total = 0
  local count = 0
  for _, value in pairs(maintenance) do
    total = total + clamp(tonumber(value) or 0, 0, 1)
    count = count + 1
  end
  if count == 0 then
    return 1
  end
  return total / count
end

local function getWearProfile(avgMiles)
  avgMiles = max(tonumber(avgMiles) or 0, 0)
  local bandIndex = 1
  local bandName = "fresh"
  local decline = 0
  if avgMiles <= 100000 then
    decline = linearScale(avgMiles, 0, 100000, 0, 0.01)
  elseif avgMiles <= 200000 then
    bandIndex = 2
    bandName = "aged"
    decline = linearScale(avgMiles, 100000, 200000, 0.01, 0.085)
  else
    bandIndex = 3
    bandName = "worn"
    decline = linearScale(avgMiles, 200000, 320000, 0.085, 0.24)
  end
  local normalizedWear = 0
  if avgMiles <= 100000 then
    normalizedWear = linearScale(avgMiles, 0, 100000, 0, 0.15)
  elseif avgMiles <= 200000 then
    normalizedWear = linearScale(avgMiles, 100000, 200000, 0.15, 0.45)
  else
    normalizedWear = linearScale(avgMiles, 200000, 320000, 0.45, 0.82)
  end
  return {
    avgMiles = avgMiles,
    bandIndex = bandIndex,
    bandName = bandName,
    decline = clamp(decline, 0, 0.24),
    normalizedWear = clamp(normalizedWear, 0, 1)
  }
end

local function sampleCurve(value, points)
  if type(points) ~= "table" or not points[1] then
    return 0
  end

  value = tonumber(value) or 0
  local firstX = tonumber(points[1][1]) or 0
  local lastX = tonumber(points[#points][1]) or firstX
  local ascending = firstX <= lastX

  if ascending then
    if value <= firstX then
      return points[1][2]
    end

    for index = 1, #points - 1 do
      local currentPoint = points[index]
      local nextPoint = points[index + 1]
      if value <= nextPoint[1] then
        return linearScale(value, currentPoint[1], nextPoint[1], currentPoint[2], nextPoint[2])
      end
    end
  else
    if value >= firstX then
      return points[1][2]
    end

    for index = 1, #points - 1 do
      local currentPoint = points[index]
      local nextPoint = points[index + 1]
      if value >= nextPoint[1] then
        return linearScale(value, currentPoint[1], nextPoint[1], currentPoint[2], nextPoint[2])
      end
    end
  end

  return points[#points][2]
end

local function getMileageAgeIndex(avgMiles)
  avgMiles = max(tonumber(avgMiles) or 0, 0)
  local result = mileageAgeIndexPoints[1][2]
  for _, point in ipairs(mileageAgeIndexPoints) do
    if avgMiles < point[1] then
      break
    end
    result = point[2]
  end
  return result
end

local function getLevelMileageMultiplier(itemName, avgMiles)
  local cap = tonumber(levelMileageCaps[itemName]) or 1
  local ageIndex = getMileageAgeIndex(avgMiles)
  return 1 + (ageIndex - 1) * ((cap - 1) / 7)
end

local function getLowFluidConditionMultiplier(level)
  return sampleCurve(clamp(tonumber(level) or 0, 0, 1), {
    {1.0, 1.0},
    {0.70, 1.0},
    {0.50, 1.25},
    {0.30, 2.0},
    {0.15, 4.0},
    {0.0, 8.0}
  })
end

local function getCapacityFactor(kind, profile)
  local reference = tonumber(referenceCapacities[kind]) or 1
  local capacities = type(profile) == "table" and profile.capacities or nil
  local actual = capacities and tonumber(capacities[kind]) or reference
  if not actual or actual <= 0 then
    actual = reference
  end
  return clamp(math.sqrt(reference / actual), 0.55, 1.5)
end

local function getClassConditionIntervalMultiplier(profile)
  local className = type(profile) == "table" and profile.class or profile
  className = classConditionIntervalMultipliers[className] and className or "passenger"
  return classConditionIntervalMultipliers[className] or 1
end

local function getClassDefaultCapacities(className)
  className = classDefaultCapacities[className] and className or 'passenger'
  return deepcopy(classDefaultCapacities[className])
end

local function getOilTemperatureMultiplier(oilTemp)
  return sampleCurve(max(tonumber(oilTemp) or 0, 0), {
    {0, 1},
    {110, 1},
    {135, 2},
    {150, 4},
    {170, 8}
  })
end

local function getTorqueCapacityStress(combustionTorque, maxTorqueRating)
  combustionTorque = max(tonumber(combustionTorque) or 0, 0)
  maxTorqueRating = tonumber(maxTorqueRating) or -1
  if maxTorqueRating <= 0 then
    return 0, nil
  end
  local ratio = combustionTorque / maxTorqueRating
  return sampleCurve(ratio, {
    {0, 0},
    {0.90, 0},
    {0.95, 0.35},
    {1.0, 0.75},
    {1.10, 1.0}
  }), ratio
end

local function getIntervalMiles(intervalsByBand, avgMiles)
  if type(intervalsByBand) ~= "table" then
    return 0
  end

  local wear = getWearProfile(avgMiles)
  return tonumber(intervalsByBand[wear.bandName]) or tonumber(intervalsByBand.fresh) or 0
end

local function getConditionWearFactor(currentValue)
  currentValue = clamp(tonumber(currentValue) or 0, 0, 1)
  return 0.55 + ((1 - currentValue) ^ 1.35) * 2.45
end

local function getIntervalCalibration(targetValue)
  targetValue = clamp(tonumber(targetValue) or defaultServiceTargetValue, 0, 1)
  local cacheKey = string.format("%.4f", targetValue)
  if intervalCalibrationCache[cacheKey] ~= nil then
    return intervalCalibrationCache[cacheKey]
  end

  local steps = 1024
  local integral = 0
  local previousValue = 1
  for index = 1, steps do
    local nextValue = 1 - (1 - targetValue) * (index / steps)
    local midpoint = (previousValue + nextValue) * 0.5
    local factor = max(getConditionWearFactor(midpoint), 0.000001)
    integral = integral + abs(previousValue - nextValue) / factor
    previousValue = nextValue
  end

  intervalCalibrationCache[cacheKey] = integral
  return integral
end

local function getBaseWearPerMile(intervalMiles, targetValue)
  intervalMiles = max(tonumber(intervalMiles) or 0, 0)
  if intervalMiles <= 0 then
    return 0
  end
  return getIntervalCalibration(targetValue) / intervalMiles
end

local function normalizeDriveMultiplier(rawMultiplier, referenceMultiplier)
  rawMultiplier = max(tonumber(rawMultiplier) or 0, 0)
  referenceMultiplier = max(tonumber(referenceMultiplier) or 0, 0)
  if referenceMultiplier <= 0 then
    return rawMultiplier
  end
  return rawMultiplier / referenceMultiplier
end

local function applyIntervalWear(currentValue, intervalMiles, deltaMiles, driveMultiplier, targetValue)
  currentValue = clamp(tonumber(currentValue) or 0, 0, 1)
  deltaMiles = max(tonumber(deltaMiles) or 0, 0)
  if deltaMiles <= 0 or currentValue <= 0 then
    return currentValue
  end

  local baseWearPerMile = getBaseWearPerMile(intervalMiles, targetValue)
  local wearFactor = getConditionWearFactor(currentValue)
  local normalizedDriveMultiplier = max(tonumber(driveMultiplier) or 0, 0)
  local wearAmount = deltaMiles * baseWearPerMile * wearFactor * normalizedDriveMultiplier
  return clamp(currentValue - wearAmount, 0, 1)
end

local function estimateMilesToTarget(currentValue, intervalMiles, driveMultiplier, targetValue)
  currentValue = clamp(tonumber(currentValue) or 0, 0, 1)
  targetValue = clamp(tonumber(targetValue) or defaultServiceTargetValue, 0, 1)
  local normalizedDriveMultiplier = max(tonumber(driveMultiplier) or 0, 0)
  if normalizedDriveMultiplier <= 0 then
    return math.huge
  end
  if currentValue <= targetValue then
    return 0
  end

  local baseWearPerMile = getBaseWearPerMile(intervalMiles, targetValue)
  if baseWearPerMile <= 0 then
    return math.huge
  end

  local steps = 192
  local integral = 0
  local previousValue = currentValue
  for index = 1, steps do
    local nextValue = currentValue - (currentValue - targetValue) * (index / steps)
    local midpoint = (previousValue + nextValue) * 0.5
    local factor = max(getConditionWearFactor(midpoint), 0.000001)
    integral = integral + abs(previousValue - nextValue) / factor
    previousValue = nextValue
  end

  return integral / (baseWearPerMile * normalizedDriveMultiplier)
end

local function getPowerFactor(powerHp)
  powerHp = max(tonumber(powerHp) or 0, 0)
  return sampleCurve(powerHp, {
    {0, 0},
    {300, 0},
    {700, 0.35},
    {1200, 0.8},
    {2500, 1.8},
    {5000, 4.5}
  })
end

local function getBeamPowerWatts(rawPower)
  rawPower = max(tonumber(rawPower) or 0, 0)
  if rawPower <= 0 then
    return 0
  end
  -- Beam powertrain maxPower is usually PS-scale. Very large values are already SI watts.
  if rawPower > 10000 then
    return rawPower
  end
  return rawPower * psToWatt
end

local function getTorqueFactor(torqueNm)
  torqueNm = max(tonumber(torqueNm) or 0, 0)
  return sampleCurve(torqueNm, {
    {0, 0},
    {300, 0},
    {700, 0.35},
    {1200, 0.9},
    {2000, 1.8},
    {4000, 4.5},
    {7000, 6.5}
  })
end

-- Compare output with each engine's torque rating so heavy stock engines do not look overstressed.
local function getRatedOutputFactor(torqueNm, maxTorqueRating)
  torqueNm = tonumber(torqueNm) or 0
  maxTorqueRating = tonumber(maxTorqueRating) or 0
  if torqueNm <= 0 or maxTorqueRating <= 0 then return nil end
  local ratio = torqueNm / maxTorqueRating
  return sampleCurve(ratio, {
    {0, 0},
    {0.75, 0},
    {0.9, 0.35},
    {1.0, 0.8},
    {1.25, 1.4},
    {1.6, 2.0},
    {2.5, 3.0},
    {4.0, 4.5},
    {6.0, 5.5}
  }), ratio
end

-- Unrated engines retain absolute power and torque stress curves.
local function getOutputStress(powerHp, torqueNm, maxTorqueRating)
  local rated, ratio = getRatedOutputFactor(torqueNm, maxTorqueRating)
  if rated then
    return {engine = rated, drivetrain = rated, ratedRatio = ratio}
  end
  local powerFactor, torqueFactor = getPowerFactor(powerHp), getTorqueFactor(torqueNm)
  return {
    engine = max(powerFactor, torqueFactor) + min(powerFactor, torqueFactor) * 0.35,
    drivetrain = max(powerFactor, torqueFactor),
  }
end

-- Unrated engines retain the earlier absolute-output overload rules.
local function getRatedOverloadGate(torqueNm, maxTorqueRating)
  local _, ratio = getRatedOutputFactor(torqueNm, maxTorqueRating)
  if not ratio then return 1 end
  return sampleCurve(ratio, {
    {0, 0},
    {1.0, 0},
    {1.25, 1}
  })
end

-- Project service dates from averaged driving rates instead of every throttle and idle fluctuation.
local function getPlanningMultiplier(env, itemName, effectiveMultiplier, normalizedDriveMultiplier)
  local planned = type(env) == "table" and type(env.plannedDriveMultipliers) == "table" and
                    tonumber(env.plannedDriveMultipliers[itemName]) or nil
  if planned and planned > 0 then return planned end
  return (tonumber(effectiveMultiplier) or 1) / max(tonumber(normalizedDriveMultiplier) or 1, 0.05)
end

-- Output only stresses parts while the engine is actually working hard.
local function getOutputLoadGate(loadFactor)
  return sampleCurve(clamp(tonumber(loadFactor) or 0, 0, 1), {
    {0, 0},
    {0.35, 0},
    {0.65, 0.25},
    {0.85, 0.7},
    {1, 1}
  })
end

local function getMaintenanceSeverity(maintenanceAvg)
  maintenanceAvg = clamp(tonumber(maintenanceAvg) or 1, 0, 1)
  local caution = clamp(linearScale(maintenanceAvg, 0.5, 0.25, 0, 1), 0, 1)
  local crisis = clamp(linearScale(maintenanceAvg, 0.25, 0, 0, 1), 0, 1)
  return caution + crisis * 1.75
end

local function rollChance(chancePerSecond, dt)
  local chance = clamp((tonumber(chancePerSecond) or 0) * max(tonumber(dt) or 0, 0), 0, 0.95)
  if chance <= 0 then
    return false
  end
  return random() < chance
end

local function chooseWeighted(options)
  if type(options) ~= "table" then
    return nil
  end
  local totalWeight = 0
  for _, option in ipairs(options) do
    totalWeight = totalWeight + max(tonumber(option.weight) or 0, 0)
  end
  if totalWeight <= 0 then
    return options[1] and options[1].value or nil
  end
  local cursor = random() * totalWeight
  local running = 0
  for _, option in ipairs(options) do
    running = running + max(tonumber(option.weight) or 0, 0)
    if cursor <= running then
      return option.value
    end
  end
  return options[#options] and options[#options].value or nil
end

local function pickDuration(minSeconds, maxSeconds)
  if not minSeconds or not maxSeconds then
    return tonumber(minSeconds) or tonumber(maxSeconds) or 0
  end
  return lerp(minSeconds, maxSeconds, random())
end

-- Public API --------------------------------------------------------------------------------------

M.clamp = clamp
M.lerp = lerp
M.linearScale = linearScale
M.shallowCopy = shallowCopy
M.deepCopy = deepcopy
M.getAverageMaintenance = getAverageMaintenance
M.getWearProfile = getWearProfile
M.sampleCurve = sampleCurve
M.getMileageAgeIndex = getMileageAgeIndex
M.getLevelMileageMultiplier = getLevelMileageMultiplier
M.getLowFluidConditionMultiplier = getLowFluidConditionMultiplier
M.getCapacityFactor = getCapacityFactor
M.getClassConditionIntervalMultiplier = getClassConditionIntervalMultiplier
M.getClassDefaultCapacities = getClassDefaultCapacities
M.getOilTemperatureMultiplier = getOilTemperatureMultiplier
M.getTorqueCapacityStress = getTorqueCapacityStress
M.getIntervalMiles = getIntervalMiles
M.getConditionWearFactor = getConditionWearFactor
M.getBaseWearPerMile = getBaseWearPerMile
M.normalizeDriveMultiplier = normalizeDriveMultiplier
M.applyIntervalWear = applyIntervalWear
M.estimateMilesToTarget = estimateMilesToTarget
M.getPowerFactor = getPowerFactor
M.getBeamPowerWatts = getBeamPowerWatts
M.getTorqueFactor = getTorqueFactor
M.getRatedOutputFactor = getRatedOutputFactor
M.getOutputStress = getOutputStress
M.getOutputLoadGate = getOutputLoadGate
M.getRatedOverloadGate = getRatedOverloadGate
M.getPlanningMultiplier = getPlanningMultiplier
M.getMaintenanceSeverity = getMaintenanceSeverity
M.rollChance = rollChance
M.chooseWeighted = chooseWeighted
M.pickDuration = pickDuration

return M
