-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {"util_stepHandler"}

local dParcelManager, dGeneral, dGenerator, dVehicleTasks
M.onCareerActivated = function()
  dParcelManager = career_modules_delivery_parcelManager
  dGeneral = career_modules_delivery_general
  dGenerator = career_modules_delivery_generator
  dVehicleTasks = career_modules_delivery_vehicleTasks
end

-- Precision parking scoring configuration (based on parkingPointsNode.lua)
local PRECISION_PARKING_CONFIG = {
  -- Scoring thresholds (3 good ratings, 2 bad ratings)
  PERFECT_SCORE = 20,           -- Perfect parking score
  GREAT_SCORE = 15,             -- Great parking score
  GOOD_SCORE = 10,             -- Good parking score
  BAD_SCORE = 5,                -- Bad parking score
  -- Below 5 = Horrible

  -- Money rewards (always applied, positive or negative)
  PERFECT_MONEY_FLAT = 30,      -- Flat money bonus for perfect parking
  PERFECT_MONEY_PERCENT = 0.25, -- 15% money bonus for perfect parking
  GREAT_MONEY_FLAT = 20,        -- Flat money bonus for great parking
  GREAT_MONEY_PERCENT = 0.15,   -- 10% money bonus for great parking
  GOOD_MONEY_FLAT = 10,         -- Flat money bonus for good parking
  GOOD_MONEY_PERCENT = 0.10,    -- 5% money bonus for good parking
  BAD_MONEY_FLAT = 0,         -- Flat money penalty for bad parking
  BAD_MONEY_PERCENT = -0.05,    -- 5% money penalty for bad parking
  HORRIBLE_MONEY_FLAT = 0,    -- Flat money penalty for horrible parking
  HORRIBLE_MONEY_PERCENT = -0.10, -- 10% money penalty for horrible parking

  -- Logistics XP rewards (good, great, perfect only)
  PERFECT_LOGISTICS_FLAT = 10,  -- Flat logistics XP bonus for perfect parking
  PERFECT_LOGISTICS_PERCENT = 0.20, -- 20% logistics XP bonus for perfect parking
  GREAT_LOGISTICS_FLAT = 5,    -- Flat logistics XP bonus for great parking
  GREAT_LOGISTICS_PERCENT = 0.15, -- 15% logistics XP bonus for great parking
  GOOD_LOGISTICS_FLAT = 5,      -- Flat logistics XP bonus for good parking
  GOOD_LOGISTICS_PERCENT = 0.10, -- 10% logistics XP bonus for good parking

  -- Skill XP rewards (good, great, perfect only) (applies to delivery, vehicleDelivery or materialsDelivery, depending on the task)
  PERFECT_SKILL_FLAT = 5,      -- Flat skill XP bonus for perfect parking
  PERFECT_SKILL_PERCENT = 0.15, -- 15% skill XP bonus for perfect parking
  GREAT_SKILL_FLAT = 5,         -- Flat skill XP bonus for great parking
  GREAT_SKILL_PERCENT = 0.10,  -- 10% skill XP bonus for great parking
  GOOD_SKILL_FLAT = 3,         -- Flat skill XP bonus for good parking
  GOOD_SKILL_PERCENT = 0.05,   -- 5% skill XP bonus for good parking

  -- Reputation rewards (great, perfect only) and penalties (horrible only)
  PERFECT_REPUTATION_FLAT = 5,  -- Flat reputation bonus for perfect parking
  PERFECT_REPUTATION_PERCENT = 0.20, -- 20% reputation bonus for perfect parking
  GREAT_REPUTATION_FLAT = 2,    -- Flat reputation bonus for great parking
  GREAT_REPUTATION_PERCENT = 0.15, -- 15% reputation bonus for great parking
  HORRIBLE_REPUTATION_FLAT = -5, -- Flat reputation penalty for horrible parking
  HORRIBLE_REPUTATION_PERCENT = -0.10, -- 10% reputation penalty for horrible parking
}


-- Calculate precision parking score for a vehicle (based on parkingPointsNode.lua)
local function calculateVehiclePrecisionScore(vehId, targetParkingSpot)
  local vehicle = scenetree.findObjectById(vehId)
  if not vehicle then return nil end

  local vehiclePos = vehicle:getPosition()
  local vehicleRot = vehicle:getRotation()
  local vehicleDir = vehicle:getDirectionVector()

  local targetPos = targetParkingSpot.pos
  local targetRot = targetParkingSpot.rot
  local targetDir = targetRot * vec3(0, 1, 0) -- Forward direction of target

  -- Calculate alignment (dot product between vehicle and target direction)
  local dotAngle = vehicleDir:dot(targetDir)
  local angle = math.acos(math.max(-1, math.min(1, dotAngle))) / math.pi * 180
  if angle ~= angle then angle = 0 end -- Handle NaN

  -- Handle both forward and backward parking (0° and 180° are both valid)
  -- Penalize orthogonal parking (90° is worst)
  local adjustedAngle = angle
  if angle > 90 then
    adjustedAngle = 180 - angle -- Convert 180° to 0°, 150° to 30°, etc.
  end

  -- Calculate distances (similar to rectMarker.lua)
  local vehicleBB = vehicle:getSpawnWorldOOBB()
  local bbCenter = vehicleBB:getCenter()
  local alignedOffset = (bbCenter - targetPos):projectToOriginPlane(vec3(0, 0, 1))

  local xVec = targetRot * vec3(1, 0, 0) -- Right direction
  local yVec = targetRot * vec3(0, 1, 0) -- Forward direction

  local sideDist = math.abs(alignedOffset:dot(xVec))
  local forwardDist = math.abs(alignedOffset:dot(yVec))

  -- Get vehicle and parking spot dimensions for adaptive scoring
  local vehicleHalfExtents = vehicleBB:getHalfExtents()
  local vehicleWidth = vehicleHalfExtents.x * 2
  local vehicleLength = vehicleHalfExtents.y * 2

  -- Get parking spot dimensions (assume standard size if not specified)
  local parkingSpotWidth = targetParkingSpot.width or 2.5  -- Default 2.5m width
  local parkingSpotLength = targetParkingSpot.length or 5.0  -- Default 5.0m length

  -- Calculate adaptive thresholds based on vehicle and parking spot sizes
  local maxSideTolerance = math.max(0.3, (parkingSpotWidth - vehicleWidth) * 0.3)  -- 30% of available space
  local maxForwardTolerance = math.max(0.4, (parkingSpotLength - vehicleLength) * 0.3)  -- 30% of available space
  local minSideTolerance = math.max(0.1, maxSideTolerance * 0.3)  -- 30% of max tolerance
  local minForwardTolerance = math.max(0.15, maxForwardTolerance * 0.3)  -- 30% of max tolerance

  -- Calculate scores using adaptive thresholds
  local angleScore = clamp(inverseLerp(7.5, 1.6, adjustedAngle), 0, 1)
  local sideScore = clamp(inverseLerp(maxSideTolerance, minSideTolerance, sideDist), 0, 1)
  local forwardScore = clamp(inverseLerp(maxForwardTolerance, minForwardTolerance, forwardDist), 0, 1)

  local totalScore = round(math.min(20, (angleScore + sideScore + forwardScore) * 6 + 2))

  -- Determine precision level based on score (3 good, 2 bad ratings)
  local precisionLevel = "horrible"
  if totalScore >= PRECISION_PARKING_CONFIG.PERFECT_SCORE then
    precisionLevel = "perfect"
  elseif totalScore >= PRECISION_PARKING_CONFIG.GREAT_SCORE then
    precisionLevel = "great"
  elseif totalScore >= PRECISION_PARKING_CONFIG.GOOD_SCORE then
    precisionLevel = "good"
  elseif totalScore >= PRECISION_PARKING_CONFIG.BAD_SCORE then
    precisionLevel = "bad"
  end

  return {
    precisionLevel = precisionLevel,
    totalScore = totalScore,
    angle = angle,
    adjustedAngle = adjustedAngle,
    sideDist = sideDist,
    forwardDist = forwardDist,
    angleScore = angleScore * 6,
    sideScore = sideScore * 6,
    forwardScore = forwardScore * 6,
    -- Adaptive tolerance data for debugging
    vehicleWidth = vehicleWidth,
    vehicleLength = vehicleLength,
    parkingSpotWidth = parkingSpotWidth,
    parkingSpotLength = parkingSpotLength,
    maxSideTolerance = maxSideTolerance,
    maxForwardTolerance = maxForwardTolerance,
    minSideTolerance = minSideTolerance,
    minForwardTolerance = minForwardTolerance
  }
end

-- Calculate precision parking score for cargo dropoff
local function calculateCargoPrecisionScore(cargo, targetLocation)
  local playerVehId = be:getPlayerVehicleID(0)
  if not playerVehId then return nil end

  local vehicle = scenetree.findObjectById(playerVehId)
  if not vehicle then return nil end

  -- Get target parking spot
  local targetParkingSpot = dGenerator.getParkingSpotByPath(targetLocation.psPath)
  if not targetParkingSpot then return nil end

  return calculateVehiclePrecisionScore(playerVehId, targetParkingSpot)
end

-- Get precision parking bonus for rewards
local function getPrecisionParkingBonus(precisionData)
  if not precisionData then
    return {
      precisionLevel = "none",
      moneyFlat = 0,
      moneyPercent = 0,
      logisticsFlat = 0,
      logisticsPercent = 0,
      skillFlat = 0,
      skillPercent = 0,
      reputationFlat = 0,
      reputationPercent = 0
    }
  end

  local level = precisionData.precisionLevel
  local config = PRECISION_PARKING_CONFIG

  -- Initialize all rewards to 0
  local moneyFlat = 0
  local moneyPercent = 0
  local logisticsFlat = 0
  local logisticsPercent = 0
  local skillFlat = 0
  local skillPercent = 0
  local reputationFlat = 0
  local reputationPercent = 0

  -- Money rewards (always applied)
  if level == "perfect" then
    moneyFlat = config.PERFECT_MONEY_FLAT
    moneyPercent = config.PERFECT_MONEY_PERCENT
  elseif level == "great" then
    moneyFlat = config.GREAT_MONEY_FLAT
    moneyPercent = config.GREAT_MONEY_PERCENT
  elseif level == "good" then
    moneyFlat = config.GOOD_MONEY_FLAT
    moneyPercent = config.GOOD_MONEY_PERCENT
  elseif level == "bad" then
    moneyFlat = config.BAD_MONEY_FLAT
    moneyPercent = config.BAD_MONEY_PERCENT
  elseif level == "horrible" then
    moneyFlat = config.HORRIBLE_MONEY_FLAT
    moneyPercent = config.HORRIBLE_MONEY_PERCENT
  end

  -- Logistics XP rewards (good, great, perfect only)
  if level == "perfect" then
    logisticsFlat = config.PERFECT_LOGISTICS_FLAT
    logisticsPercent = config.PERFECT_LOGISTICS_PERCENT
  elseif level == "great" then
    logisticsFlat = config.GREAT_LOGISTICS_FLAT
    logisticsPercent = config.GREAT_LOGISTICS_PERCENT
  elseif level == "good" then
    logisticsFlat = config.GOOD_LOGISTICS_FLAT
    logisticsPercent = config.GOOD_LOGISTICS_PERCENT
  end

  -- Skill XP rewards (good, great, perfect only)
  if level == "perfect" then
    skillFlat = config.PERFECT_SKILL_FLAT
    skillPercent = config.PERFECT_SKILL_PERCENT
  elseif level == "great" then
    skillFlat = config.GREAT_SKILL_FLAT
    skillPercent = config.GREAT_SKILL_PERCENT
  elseif level == "good" then
    skillFlat = config.GOOD_SKILL_FLAT
    skillPercent = config.GOOD_SKILL_PERCENT
  end

  -- Reputation rewards (great, perfect only) and penalties (horrible only)
  if level == "perfect" then
    reputationFlat = config.PERFECT_REPUTATION_FLAT
    reputationPercent = config.PERFECT_REPUTATION_PERCENT
  elseif level == "great" then
    reputationFlat = config.GREAT_REPUTATION_FLAT
    reputationPercent = config.GREAT_REPUTATION_PERCENT
  elseif level == "horrible" then
    reputationFlat = config.HORRIBLE_REPUTATION_FLAT
    reputationPercent = config.HORRIBLE_REPUTATION_PERCENT
  end

  return {
    precisionLevel = level,
    totalScore = precisionData.totalScore,
    angle = precisionData.angle,
    adjustedAngle = precisionData.adjustedAngle,
    sideDist = precisionData.sideDist,
    forwardDist = precisionData.forwardDist,
    -- Reward components
    moneyFlat = moneyFlat,
    moneyPercent = moneyPercent,
    logisticsFlat = logisticsFlat,
    logisticsPercent = logisticsPercent,
    skillFlat = skillFlat,
    skillPercent = skillPercent,
    reputationFlat = reputationFlat,
    reputationPercent = reputationPercent
  }
end

-- Apply precision parking bonus to vehicle delivery rewards
local function applyVehiclePrecisionBonus(taskData, precisionBonus)
  if not precisionBonus then
    return taskData
  end

  -- Calculate precision parking rewards
  local moneyReward = precisionBonus.moneyFlat + (taskData.originalRewards.money * precisionBonus.moneyPercent)
  local logisticsReward = precisionBonus.logisticsFlat + (taskData.originalRewards["logistics-vehicleDelivery"] or 0) * precisionBonus.logisticsPercent
  local skillReward = precisionBonus.skillFlat + (taskData.originalRewards["logistics-vehicleDelivery"] or 0) * precisionBonus.skillPercent
  local reputationReward = precisionBonus.reputationFlat + (taskData.originalRewards[taskData.offer.organization.."Reputation"] or 0) * precisionBonus.reputationPercent

  -- Apply money reward
  taskData.adjustedRewards.money = taskData.adjustedRewards.money + math.floor(moneyReward)

  -- Apply logistics XP reward
  if logisticsReward ~= 0 then
    taskData.adjustedRewards["logistics-vehicleDelivery"] = (taskData.adjustedRewards["logistics-vehicleDelivery"] or 0) + math.floor(logisticsReward)
  end

  -- Apply skill XP reward (same as logistics for vehicle delivery)
  if skillReward ~= 0 then
    taskData.adjustedRewards["logistics-vehicleDelivery"] = (taskData.adjustedRewards["logistics-vehicleDelivery"] or 0) + math.floor(skillReward)
  end

  -- Apply reputation reward
  if reputationReward ~= 0 and taskData.offer.organization then
    taskData.adjustedRewards[taskData.offer.organization.."Reputation"] = (taskData.adjustedRewards[taskData.offer.organization.."Reputation"] or 0) + math.floor(reputationReward)
  end

  -- Add precision bonus breakdown
  taskData.breakdown.precisionParking = {
    type = "precisionParking",
    level = precisionBonus.precisionLevel,
    totalScore = precisionBonus.totalScore,
    angle = precisionBonus.angle,
    adjustedAngle = precisionBonus.adjustedAngle,
    sideDist = precisionBonus.sideDist,
    forwardDist = precisionBonus.forwardDist,
    -- Reward breakdown
    moneyFlat = precisionBonus.moneyFlat,
    moneyPercent = precisionBonus.moneyPercent,
    logisticsFlat = precisionBonus.logisticsFlat,
    logisticsPercent = precisionBonus.logisticsPercent,
    skillFlat = precisionBonus.skillFlat,
    skillPercent = precisionBonus.skillPercent,
    reputationFlat = precisionBonus.reputationFlat,
    reputationPercent = precisionBonus.reputationPercent
  }

  return taskData
end

-- Apply precision parking bonus to cargo delivery rewards
local function applyCargoPrecisionBonus(cargo, precisionBonus)
  if not precisionBonus then
    return cargo
  end

  -- Calculate precision parking rewards
  local moneyReward = precisionBonus.moneyFlat + (cargo.rewards.money * precisionBonus.moneyPercent)
  local logisticsReward = precisionBonus.logisticsFlat + (cargo.rewards["logistics-delivery"] or 0) * precisionBonus.logisticsPercent
  local skillReward = precisionBonus.skillFlat + (cargo.rewards["logistics-delivery"] or 0) * precisionBonus.skillPercent
  local reputationReward = precisionBonus.reputationFlat + (cargo.rewards[cargo.organization.."Reputation"] or 0) * precisionBonus.reputationPercent

  -- Apply money reward
  cargo.rewards.money = cargo.rewards.money + math.floor(moneyReward)

  -- Apply logistics XP reward
  if logisticsReward ~= 0 then
    cargo.rewards["logistics-delivery"] = (cargo.rewards["logistics-delivery"] or 0) + math.floor(logisticsReward)
  end

  -- Apply skill XP reward (same as logistics for cargo delivery)
  if skillReward ~= 0 then
    cargo.rewards["logistics-delivery"] = (cargo.rewards["logistics-delivery"] or 0) + math.floor(skillReward)
  end

  -- Apply reputation reward
  if reputationReward ~= 0 and cargo.organization then
    cargo.rewards[cargo.organization.."Reputation"] = (cargo.rewards[cargo.organization.."Reputation"] or 0) + math.floor(reputationReward)
  end

  -- Store precision data for breakdown
  cargo.precisionParking = {
    level = precisionBonus.precisionLevel,
    totalScore = precisionBonus.totalScore,
    angle = precisionBonus.angle,
    adjustedAngle = precisionBonus.adjustedAngle,
    sideDist = precisionBonus.sideDist,
    forwardDist = precisionBonus.forwardDist,
    -- Reward breakdown
    moneyFlat = precisionBonus.moneyFlat,
    moneyPercent = precisionBonus.moneyPercent,
    logisticsFlat = precisionBonus.logisticsFlat,
    logisticsPercent = precisionBonus.logisticsPercent,
    skillFlat = precisionBonus.skillFlat,
    skillPercent = precisionBonus.skillPercent,
    reputationFlat = precisionBonus.reputationFlat,
    reputationPercent = precisionBonus.reputationPercent
  }

  return cargo
end

-- Main function to calculate and apply precision parking for vehicle delivery
M.calculateVehiclePrecisionParking = function(taskData)
  if not taskData or not taskData.dropOffPsPath then
    return taskData
  end

  local targetParkingSpot = dGenerator.getParkingSpotByPath(taskData.dropOffPsPath)
  if not targetParkingSpot then
    return taskData
  end

  local precisionData = calculateVehiclePrecisionScore(taskData.vehId, targetParkingSpot)
  if not precisionData then
    return taskData
  end

  local precisionBonus = getPrecisionParkingBonus(precisionData)
  return applyVehiclePrecisionBonus(taskData, precisionBonus)
end

-- Main function to calculate and apply precision parking for cargo delivery
M.calculateCargoPrecisionParking = function(cargo, targetLocation)
  if not cargo or not targetLocation then
    return cargo
  end

  local precisionData = calculateCargoPrecisionScore(cargo, targetLocation)
  if not precisionData then
    return cargo
  end

  local precisionBonus = getPrecisionParkingBonus(precisionData)
  return applyCargoPrecisionBonus(cargo, precisionBonus)
end

-- Get precision parking configuration (for UI/debugging)
M.getPrecisionParkingConfig = function()
  return PRECISION_PARKING_CONFIG
end

-- Expose getPrecisionParkingBonus for debug module
M.getPrecisionParkingBonus = getPrecisionParkingBonus

-- Expose calculateVehiclePrecisionScore for breakdown integration
M.calculateVehiclePrecisionScore = calculateVehiclePrecisionScore

-- Debug function to test precision parking
M.debugPrecisionParking = function(vehId, targetParkingSpot)
  local precisionData = calculateVehiclePrecisionScore(vehId, targetParkingSpot)
  if precisionData then
    --log("I", "", string.format("Precision Parking Debug - Level: %s, Score: %d, Angle: %.1f° (Adj: %.1f°), Side: %.2fm, Forward: %.2fm",
    --  precisionData.precisionLevel, precisionData.totalScore, precisionData.angle, precisionData.adjustedAngle, precisionData.sideDist, precisionData.forwardDist))
  end
  return precisionData
end

return M
