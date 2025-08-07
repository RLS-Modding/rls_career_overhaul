local M = {}

local function onExtensionLoaded()
    gameplay_taxi.registerPassengerType("EXECUTIVE", {
        name = "Executive",
        description = "High-status clients expecting impeccable, quiet service",
        baseMultiplier = 0.9,
        speedWeight = 0.5,
        distanceWeight = 1.1,
        selectionWeight = 1,
        seatRange = {1, 4},
        valueRange = {1.5, nil},
        fareWeights = {
            {min = 1.0, max = 1.3, weight = 3},
            {min = 1.3, max = 1.7, weight = 5},
            {min = 1.7, max = 2.3, weight = 2}
        },
        speedTolerance = 0.3,
        calculateTipBreakdown = function(fare, elapsedTime, speedFactor, passengerType)
            local tipBreakdown = {}
            local baseFare = tonumber(fare.baseFare) or 0

            if fare.rideQuality then
                local sm = fare.rideQuality.smoothness or 0
                if sm > 0.92 then
                    tipBreakdown["White-Glove Service"] = 0.5 * baseFare
                elseif sm > 0.85 then
                    tipBreakdown["Discreet Comfort"] = 0.3 * baseFare
                end
            end
            return tipBreakdown
        end,
        onUpdate = function(fare, rideData, passengerType)
            if not rideData.smoothnessScore then rideData.smoothnessScore = 100 end
            if rideData.currentSensorData then
                local gx, gy = rideData.currentSensorData.gx, rideData.currentSensorData.gy
                if math.abs(gx) > 0.6 or math.abs(gy) > 0.55 then
                    rideData.smoothnessScore = math.max(0, rideData.smoothnessScore - 3)
                else
                    rideData.smoothnessScore = math.min(100, rideData.smoothnessScore + 0.6)
                end
                fare.rideQuality = fare.rideQuality or {}
                fare.rideQuality.smoothness = rideData.smoothnessScore / 100
            end
        end,
        getDescription = function(fare, passengerType)
            return string.format("%s (%d passengers) - Premium client", passengerType.name, fare.passengers)
        end,
        getPaymentLabel = function(fare, speedFactor, passengerType)
            local label = "Standard"
            if fare.rideQuality and fare.rideQuality.smoothness and fare.rideQuality.smoothness > 0.92 then
                label = "White-Glove Service"
            end
            return label
        end
    })
end

M.onExtensionLoaded = onExtensionLoaded

return M 


