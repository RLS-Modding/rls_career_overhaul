local M = {}

local function onExtensionLoaded()
    gameplay_taxi.registerPassengerType("FAMILY", {
        name = "Family",
        description = "Families prioritizing safe, smooth rides with more seats",
        baseMultiplier = 0.6,
        speedWeight = -0.2,
        distanceWeight = 1.1,
        selectionWeight = 3,
        seatRange = {4, 8},
        valueRange = {0.6, nil},
        fareWeights = {
            {min = 0.7, max = 1.0, weight = 5},
            {min = 1.0, max = 1.3, weight = 3},
            {min = 1.3, max = 1.6, weight = 1}
        },
        speedTolerance = 0.4,
        calculateTipBreakdown = function(fare, elapsedTime, speedFactor, passengerType)
            local tipBreakdown = {}
            local baseFare = tonumber(fare.baseFare) or 0
            if speedFactor < -0.05 then
                tipBreakdown["Safe Driving"] = 0.2 * baseFare
            end
            if fare.rideQuality and fare.rideQuality.smoothness and fare.rideQuality.smoothness > 0.75 then
                tipBreakdown["Smooth Ride"] = 0.15 * baseFare
            end
            return tipBreakdown
        end,
        onUpdate = function(fare, rideData, passengerType)
            if not rideData.smoothnessScore then rideData.smoothnessScore = 100 end
            if rideData.currentSensorData then
                local gx, gy = rideData.currentSensorData.gx, rideData.currentSensorData.gy
                if math.abs(gx) > 0.7 or math.abs(gy) > 0.6 then
                    rideData.smoothnessScore = math.max(0, rideData.smoothnessScore - 2)
                else
                    rideData.smoothnessScore = math.min(100, rideData.smoothnessScore + 0.5)
                end
                fare.rideQuality = fare.rideQuality or {}
                fare.rideQuality.smoothness = rideData.smoothnessScore / 100
            end
        end,
        getDescription = function(fare, passengerType)
            return string.format("%s (%d passengers) - Keep it safe", passengerType.name, fare.passengers)
        end,
        getPaymentLabel = function(fare, speedFactor, passengerType)
            local label = speedFactor < 0 and "Safe Driving" or "Standard"
            if fare.rideQuality and fare.rideQuality.smoothness and fare.rideQuality.smoothness > 0.8 then
                label = label .. " | Smooth Ride"
            end
            return label
        end
    })
end

M.onExtensionLoaded = onExtensionLoaded

return M 


