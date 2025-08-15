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
        calculateDriverRating = function(fare, rideData, elapsedTime, speedFactor, passengerType)
            local smooth = (fare.rideQuality and fare.rideQuality.smoothness) or 1.0
            local spd = tonumber(speedFactor) or 0
            local rating = 5.0
            rating = rating - (1 - smooth) * 3.0
            if spd > 0.2 then rating = rating - math.min(1.0, spd) * 1.0 end
            if smooth > 0.95 and spd <= 0.1 then rating = rating + 0.3 end
            if rating > 5 then rating = 5 end
            if rating < 1 then rating = 1 end
            return rating
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


