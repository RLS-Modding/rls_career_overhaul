-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/career/modules/delivery/precisionParking.lua (BeamNG 0.40).

local M = {}
M.dependencies = {"util_stepHandler"}
local xpConfig = require('overhaul/lib/logistics/xpConfig')

local function getPrecisionConfig()
  return xpConfig.getPrecisionParkingRules()
end


-- Calculate precision parking score for a vehicle (based on parkingPointsNode.lua)
local function calculateVehiclePrecisionScore(vehId, targetParkingSpot)
  local precisionConfig = getPrecisionConfig()
  local scoreConfig = precisionConfig.score

  local vehicle = scenetree.findObjectById(vehId)
  if not vehicle then return nil end

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
  local maxSideTolerance = math.max(scoreConfig.sideToleranceMin, (parkingSpotWidth - vehicleWidth) * scoreConfig.toleranceSpaceFactor)
  local maxForwardTolerance = math.max(scoreConfig.forwardToleranceMin, (parkingSpotLength - vehicleLength) * scoreConfig.toleranceSpaceFactor)
  local minSideTolerance = math.max(scoreConfig.sideToleranceFloorMin, maxSideTolerance * scoreConfig.toleranceFloorFactor)
  local minForwardTolerance = math.max(scoreConfig.forwardToleranceFloorMin, maxForwardTolerance * scoreConfig.toleranceFloorFactor)

  -- Calculate scores using adaptive thresholds
  local angleScore = clamp(inverseLerp(scoreConfig.angleWorst, scoreConfig.angleBest, adjustedAngle), 0, 1)
  local sideScore = clamp(inverseLerp(maxSideTolerance, minSideTolerance, sideDist), 0, 1)
  local forwardScore = clamp(inverseLerp(maxForwardTolerance, minForwardTolerance, forwardDist), 0, 1)

  local totalScore = xpConfig.applyRounding(
    math.min(scoreConfig.scoreCap, (angleScore + sideScore + forwardScore) * scoreConfig.scoreScale + scoreConfig.scoreOffset),
    scoreConfig.scoreRounding
  )

  -- Determine precision level based on score (3 good, 2 bad ratings)
  local thresholds = precisionConfig.thresholds
  local precisionLevel = "horrible"
  if totalScore >= thresholds.perfect then
    precisionLevel = "perfect"
  elseif totalScore >= thresholds.great then
    precisionLevel = "great"
  elseif totalScore >= thresholds.good then
    precisionLevel = "good"
  elseif totalScore >= thresholds.bad then
    precisionLevel = "bad"
  end

  return {
    precisionLevel = precisionLevel,
    totalScore = totalScore,
    angle = angle,
    adjustedAngle = adjustedAngle,
    sideDist = sideDist,
    forwardDist = forwardDist,
    angleScore = angleScore * scoreConfig.scoreScale,
    sideScore = sideScore * scoreConfig.scoreScale,
    forwardScore = forwardScore * scoreConfig.scoreScale,
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
  local levelRewards = getPrecisionConfig().rewards[level] or {}

  return {
    precisionLevel = level,
    totalScore = precisionData.totalScore,
    angle = precisionData.angle,
    adjustedAngle = precisionData.adjustedAngle,
    sideDist = precisionData.sideDist,
    forwardDist = precisionData.forwardDist,
    -- Reward components
    moneyFlat = levelRewards.moneyFlat or 0,
    moneyPercent = levelRewards.moneyPercent or 0,
    logisticsFlat = levelRewards.logisticsFlat or 0,
    logisticsPercent = levelRewards.logisticsPercent or 0,
    skillFlat = levelRewards.skillFlat or 0,
    skillPercent = levelRewards.skillPercent or 0,
    reputationFlat = levelRewards.reputationFlat or 0,
    reputationPercent = levelRewards.reputationPercent or 0
  }
end

-- Get precision parking configuration (for UI/debugging)
M.getPrecisionParkingConfig = function()
  return getPrecisionConfig()
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