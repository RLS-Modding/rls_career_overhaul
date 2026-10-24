-- Taxi passengers party behavior for its job owner.
-- Registration creates fresh preference data and callbacks for each taxi load.
local M = {}
local passengerRewards = require("overhaul/jobs/taxi/passengerRewards")

local function register(taxi)
  taxi.registerPassengerType("PARTY", {
    name = "Party Group",
    description = "Large groups heading to parties who value safety and comfort over speed",
    baseMultiplier = 0.55,
    speedWeight = -0.4,
    distanceWeight = 1.15,
    selectionWeight = 3,
    unlockFlag = "taxiPassengerParty",
    seatRange = {12, nil},
    valueRange = {1.2, nil},
    speedTolerance = 0.35,

    fareWeights = {
      {min = 0.45, max = 0.65, weight = 4},
      {min = 0.65, max = 0.95, weight = 3},
      {min = 0.95, max = 1.25, weight = 2}
    },

    calculateTipBreakdown = function(fare, elapsedTime, speedFactor, passengerType)
      local tipBreakdown = {}
      local baseFare = tonumber(fare.baseFare) or 0

      if speedFactor < -0.08 then
        tipBreakdown["Safety Bonus"] = 0.25 * baseFare
      end

      if overhaul_jobs_taxi_taxi.rideData and overhaul_jobs_taxi_taxi.rideData.currentSensorData then
        local sensorData = overhaul_jobs_taxi_taxi.rideData.currentSensorData
        local totalG = math.abs(sensorData.gx or 0) + math.abs(sensorData.gy or 0)

        if totalG < 0.28 then
          tipBreakdown["Smooth Ride"] = 0.18 * baseFare
        end
      end

      if fare.rideQuality and fare.rideQuality.partyData then
        local partyData = fare.rideQuality.partyData
        if partyData.avgGForce and partyData.avgGForce < 0.24 then
          tipBreakdown["Gentle Driving"] = 0.12 * baseFare
        end
        if partyData.maxGForce and partyData.maxGForce < 0.5 then
          tipBreakdown["No Sudden Movements"] = 0.08 * baseFare
        end
      end

      return tipBreakdown
    end,
    calculateDriverRating = function(fare, rideData, elapsedTime, speedFactor, passengerType)
      local partyData = fare.rideQuality and fare.rideQuality.partyData or {}
      local avgG = partyData.avgGForce or 0
      local maxG = partyData.maxGForce or 0
      local speedPreference = tonumber(speedFactor) or 0
      local rating = 5.0
      if avgG > 0.35 then rating = rating - (avgG - 0.35) * 4.0 end
      if maxG > 0.7 then rating = rating - (maxG - 0.7) * 2.0 end
      if speedPreference > 0.15 then rating = rating - math.min(1.0, speedPreference) * 0.8 end
      if avgG < 0.25 and speedPreference <= 0 then rating = rating + 0.3 end

      return passengerRewards.clampRating(rating)
    end,

    getDescription = function(fare, passengerType)
      return string.format("Party Group (%d people) - Drive safely!", fare.passengers)
    end,

    getPaymentLabel = function(fare, speedFactor, passengerType)
      if speedFactor > 0.2 then
        return "Speed Penalty"
      elseif speedFactor < -0.1 then
        return "Safety Bonus"
      else
        return "Standard Rate"
      end
    end,

    onUpdate = function(fare, rideData, passengerType)
      if not rideData.partyData then
        rideData.partyData = {
          maxGForce = 0,
          avgGForce = 0,
          gForceReadings = {},
          startTime = os.time()
        }
      end

      if rideData.currentSensorData then
        local totalG = math.abs(rideData.currentSensorData.gx or 0) +
               math.abs(rideData.currentSensorData.gy or 0)

        rideData.partyData.maxGForce = math.max(rideData.partyData.maxGForce, totalG)
        table.insert(rideData.partyData.gForceReadings, totalG)

        local sum = 0
        for _, reading in ipairs(rideData.partyData.gForceReadings) do
          sum = sum + reading
        end
        rideData.partyData.avgGForce = sum / #rideData.partyData.gForceReadings

        fare.rideQuality = fare.rideQuality or {}
        fare.rideQuality.partyData = rideData.partyData
      end
    end
  })
end

M.register = register

return M
