local M = {}

local function onExtensionLoaded()
    gameplay_taxi.registerPassengerType("STUDENT", {
        name = "Student",
        description = "Budget riders; flexible but reward efficiency",
        baseMultiplier = 0.5,
        speedWeight = 0.8,
        distanceWeight = 1.0,
        selectionWeight = 4,
        seatRange = {1, 5},
        valueRange = {0.0, 1.2},
        fareWeights = {
            {min = 0.7, max = 1.0, weight = 6},
            {min = 1.0, max = 1.3, weight = 3},
            {min = 1.3, max = 1.6, weight = 1}
        },
        speedTolerance = 0.5,
        calculateTipBreakdown = function(fare, elapsedTime, speedFactor, passengerType)
            local tipBreakdown = {}
            local baseFare = tonumber(fare.baseFare) or 0
            if speedFactor > 0.05 then
                tipBreakdown["Efficient Trip"] = math.min(speedFactor * baseFare * 0.25, 0.25 * baseFare)
            end
            return tipBreakdown
        end,
        onUpdate = function(fare, rideData, passengerType)
            -- minimal tracking
        end,
        calculateDriverRating = function(fare, rideData, elapsedTime, speedFactor, passengerType)
            local spd = tonumber(speedFactor) or 0
            local rating = 5.0
            if spd < 0 then rating = rating - math.min(1.0, -spd) * 1.2 end
            if spd > 0 then rating = rating + math.min(0.6, spd) * 0.8 end
            if elapsedTime and elapsedTime > 0 and spd >= 0 then rating = rating + 0.1 end
            if rating > 5 then rating = 5 end
            if rating < 1 then rating = 1 end
            return rating
        end,
        getDescription = function(fare, passengerType)
            return string.format("%s (%d passengers) - Budget trip", passengerType.name, fare.passengers)
        end,
        getPaymentLabel = function(fare, speedFactor, passengerType)
            return speedFactor > 0 and "Efficient Trip" or "Standard"
        end
    })
end

M.onExtensionLoaded = onExtensionLoaded

return M 


