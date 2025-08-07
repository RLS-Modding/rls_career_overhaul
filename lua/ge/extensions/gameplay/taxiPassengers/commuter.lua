local M = {}

local function onExtensionLoaded()
    gameplay_taxi.registerPassengerType("COMMUTER", {
        name = "Commuter",
        description = "Daily riders who value punctual, steady driving",
        baseMultiplier = 0.65,
        speedWeight = 0.9,
        distanceWeight = 1.0,
        selectionWeight = 5,
        seatRange = {1, 5},
        valueRange = {0.4, 1.8},
        fareWeights = {
            {min = 0.8, max = 1.1, weight = 5},
            {min = 1.1, max = 1.4, weight = 3},
            {min = 1.4, max = 1.7, weight = 1}
        },
        speedTolerance = 0.4,
        calculateTipBreakdown = function(fare, elapsedTime, speedFactor, passengerType)
            local tipBreakdown = {}
            local baseFare = tonumber(fare.baseFare) or 0
            if speedFactor > 0.05 then
                tipBreakdown["On-Time Bonus"] = math.min(speedFactor * baseFare * 0.35, 0.35 * baseFare)
            end
            if fare.rideQuality and fare.rideQuality.comfort and fare.rideQuality.comfort > 0.8 then
                tipBreakdown["Comfort"] = 0.1 * baseFare
            end
            return tipBreakdown
        end,
        onUpdate = function(fare, rideData, passengerType)
            if not rideData.comfortScore then rideData.comfortScore = 100 end
            if rideData.currentSensorData then
                local gx, gy = rideData.currentSensorData.gx, rideData.currentSensorData.gy
                if math.abs(gx) > 0.8 or math.abs(gy) > 0.8 then
                    rideData.comfortScore = math.max(0, rideData.comfortScore - 2)
                else
                    rideData.comfortScore = math.min(100, rideData.comfortScore + 0.5)
                end
                fare.rideQuality = fare.rideQuality or {}
                fare.rideQuality.comfort = rideData.comfortScore / 100
            end
        end,
        getDescription = function(fare, passengerType)
            return string.format("%s (%d passengers) - Routine trip", passengerType.name, fare.passengers)
        end,
        getPaymentLabel = function(fare, speedFactor, passengerType)
            local label = speedFactor > 0 and "On-Time Bonus" or "Standard"
            if fare.rideQuality and fare.rideQuality.comfort and fare.rideQuality.comfort > 0.85 then
                label = label .. " | Comfort"
            end
            return label
        end
    })
end

M.onExtensionLoaded = onExtensionLoaded

return M 


