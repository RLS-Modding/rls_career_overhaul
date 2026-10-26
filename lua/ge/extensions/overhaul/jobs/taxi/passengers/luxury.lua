-- Taxi passengers luxury behavior for its job owner.
-- Registration creates fresh preference data and callbacks for each taxi load.
local M = {}
local passengerRewards = require("overhaul/jobs/taxi/passengerRewards")

local luxuryPassenger = {
  name = "Luxury",
  description = "High-paying passengers who value comfort over speed",
  baseMultiplier = 0.7,
  speedWeight = 0.2,
  distanceWeight = 1.2,
  selectionWeight = 2,
  unlockFlag = "taxiPassengerLuxury",
  seatRange = {nil, 5},
  valueRange = {1.2, nil},
  fareWeights = {
    {min = 0.5, max = 0.8, weight = 2},
    {min = 0.8, max = 1.2, weight = 6},
    {min = 1.6, max = 2.2, weight = 2}
  },
  speedTolerance = 0.9,
  calculateTipBreakdown = function(fare, elapsedTime, speedFactor, passengerType)
    local tipBreakdown = {}
    local baseFare = tonumber(fare.baseFare) or 0

    local actualSpeed = (tonumber(fare.paidDistance or fare.totalDistance) or 0) / math.max(1, elapsedTime)
    local suggestedSpeed = 18
    local minSpeed = 2

    if actualSpeed >= minSpeed then
      if actualSpeed <= suggestedSpeed * 0.6 then
        tipBreakdown["Comfort Bonus"] = (suggestedSpeed * 0.6 - actualSpeed) / (suggestedSpeed * 0.6) * 0.25 * baseFare
      elseif actualSpeed <= suggestedSpeed * 0.9 then
        tipBreakdown["Premium Service"] = (suggestedSpeed * 0.9 - actualSpeed) / (suggestedSpeed * 0.9) * 0.15 * baseFare
      end
    end

    if fare.rideQuality then
      local smoothness = fare.rideQuality.smoothness or 0
      local lux = fare.rideQuality.luxury or 0
      if smoothness > 0.92 and lux > 0.95 then
        tipBreakdown["Immaculate Ride"] = 0.6 * baseFare
      elseif smoothness > 0.85 and lux > 0.9 then
        tipBreakdown["Premium Comfort"] = 0.35 * baseFare
      elseif smoothness > 0.75 then
        tipBreakdown["Smooth Ride"] = 0.15 * baseFare
      end
    end

    return tipBreakdown
  end,
  calculateDriverRating = function(fare, rideData, elapsedTime, speedFactor, passengerType)
    local rideQuality = fare.rideQuality or {}
    local smooth = rideQuality.smoothness or 1.0
    local lux = rideQuality.luxury or 1.0
    local speedPreference = tonumber(speedFactor) or 0
    local rating = 5.0
    rating = rating - (1 - smooth) * 2.5
    rating = rating - (1 - lux) * 1.5
    if speedPreference > 0.2 then rating = rating - math.min(1.0, speedPreference) * 1.0 end
    if smooth > 0.95 and lux > 0.95 and speedPreference <= 0.1 then rating = rating + 0.4 end

      return passengerRewards.clampRating(rating)
  end,
  onUpdate = function(fare, rideData, passengerType)
    if not rideData.smoothnessScore then
      rideData.smoothnessScore = 100
      rideData.aggressiveEvents = 0
      rideData.luxuryComfort = 100
    end

    if rideData.currentSensorData then
      local gx, gy, gz = rideData.currentSensorData.gx, rideData.currentSensorData.gy, rideData.currentSensorData.gz
      -- The vertical sensor reads 1 g at rest; only the felt excess counts.
      local dz = math.abs(gz) - 1
      local totalGForce = math.sqrt(gx*gx + gy*gy + dz*dz)

      if gy > 0.5 then
        rideData.aggressiveEvents = rideData.aggressiveEvents + 1
        rideData.smoothnessScore = math.max(0, rideData.smoothnessScore - 10)
        rideData.luxuryComfort = math.max(0, rideData.luxuryComfort - 15)
      elseif gy < -0.45 then
        rideData.aggressiveEvents = rideData.aggressiveEvents + 1
        rideData.smoothnessScore = math.max(0, rideData.smoothnessScore - 8)
        rideData.luxuryComfort = math.max(0, rideData.luxuryComfort - 12)
      elseif math.abs(gx) > 0.65 then
        rideData.aggressiveEvents = rideData.aggressiveEvents + 1
        rideData.smoothnessScore = math.max(0, rideData.smoothnessScore - 8)
        rideData.luxuryComfort = math.max(0, rideData.luxuryComfort - 10)
      end

      if totalGForce < 0.3 then
        rideData.luxuryComfort = math.min(100, rideData.luxuryComfort + 1)
      end

      fare.rideQuality = {
        smoothness = rideData.smoothnessScore / 100,
        aggressiveEvents = rideData.aggressiveEvents,
        luxury = rideData.luxuryComfort / 100
      }
    end
  end,
  getDescription = function(fare, passengerType)
    return string.format("%s (%d passengers) - Premium fare", passengerType.name, fare.passengers)
  end,
  getPaymentLabel = function(fare, speedFactor, passengerType)
    local actualSpeed = (tonumber(fare.paidDistance or fare.totalDistance) or 0) / math.max(1, fare.rideElapsed or 0)
    local suggestedSpeed = 18

    local label
    if actualSpeed < 2 then
      label = "No Pace Bonus"
    elseif actualSpeed <= suggestedSpeed * 0.6 then
      label = "Comfort Bonus"
    elseif actualSpeed <= suggestedSpeed * 0.9 then
      label = "Premium Service"
    else
      label = "Speed Penalty"
    end

    if fare.rideQuality then
      local rideQuality = fare.rideQuality
      if rideQuality.luxury and rideQuality.luxury > 0.95 and rideQuality.smoothness and rideQuality.smoothness > 0.92 then
        label = label .. " | Immaculate Ride"
      elseif rideQuality.luxury and rideQuality.luxury > 0.9 then
        label = label .. " | Premium Comfort"
      elseif rideQuality.smoothness and rideQuality.smoothness < 0.6 then
        label = label .. " | Unacceptable Service"
      elseif rideQuality.aggressiveEvents and rideQuality.aggressiveEvents > 2 then
        label = label .. " | Too Rough"
      end
    end
    return label
  end
}

local function register(taxi)
  taxi.registerPassengerType("LUXURY", luxuryPassenger)
end

M.register = register

return M
