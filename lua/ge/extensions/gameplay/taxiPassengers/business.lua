local M = {}

local function onExtensionLoaded()
    gameplay_taxi.registerPassengerType("BUSINESS", {
        name = "Business",
        description = "Time-conscious passengers with strict schedules",
        baseMultiplier = 0.75,
        speedWeight = 1.3,
        distanceWeight = 1.0,
        selectionWeight = 3,
        seatRange = {nil, 10},
        valueRange = {0.5, 2.2},
        fareWeights = {
            {min = 0.9, max = 1.2, weight = 3},
            {min = 1.2, max = 1.6, weight = 6},
            {min = 1.6, max = 2.1, weight = 3}
        },
        speedTolerance = 0.25,
        calculateTipBreakdown = function(fare, elapsedTime, speedFactor, passengerType)
            local tipBreakdown = {}
            local baseFare = tonumber(fare.baseFare) or 0
            
            if speedFactor > 0.05 then
                tipBreakdown["Efficiency Bonus"] = math.min(speedFactor * baseFare * passengerType.speedWeight * 0.45, baseFare * 0.45)
            end
            
            if fare.rideQuality then
                if speedFactor > 0.15 and fare.rideQuality.assertive then
                    tipBreakdown["Assertive Driving"] = 0.12 * baseFare
                end
            end
            
            return tipBreakdown
        end,
        calculateDriverRating = function(fare, rideData, elapsedTime, speedFactor, passengerType)
            local rq = fare.rideQuality or {}
            local spd = tonumber(speedFactor) or 0
            local rating = 5.0
            if spd < -0.05 then rating = rating - math.min(1.0, -spd) * 1.5 end
            if spd > 0.05 then rating = rating + math.min(1.0, spd) * 0.8 end
            if rq.assertive and spd > 0.15 then rating = rating + 0.3 end
            if rq.aggressiveEvents and rq.aggressiveEvents > 8 then rating = rating - 1.0 end
            if rating > 5 then rating = 5 end
            if rating < 1 then rating = 1 end
            return rating
        end,
        onUpdate = function(fare, rideData, passengerType)
            if not rideData.aggressiveEvents then
                rideData.aggressiveEvents = 0
                rideData.assertiveDriving = false
                rideData.efficiencyScore = 100
            end
            
            if rideData.currentSensorData then
                local gx, gy = rideData.currentSensorData.gx, rideData.currentSensorData.gy
                local totalGForce = math.sqrt(gx*gx + gy*gy)
                
                if gy > 0.85 then
                    rideData.aggressiveEvents = rideData.aggressiveEvents + 1
                    rideData.efficiencyScore = math.max(0, rideData.efficiencyScore - 2)
                elseif gy < -0.75 then
                    rideData.aggressiveEvents = rideData.aggressiveEvents + 1
                    rideData.assertiveDriving = true
                elseif math.abs(gx) > 0.95 then
                    rideData.aggressiveEvents = rideData.aggressiveEvents + 1
                    rideData.efficiencyScore = math.max(0, rideData.efficiencyScore - 2)
                end
                
                if totalGForce > 0.6 and totalGForce < 1.2 then
                    rideData.assertiveDriving = true
                end
                
                fare.rideQuality = {
                    aggressiveEvents = rideData.aggressiveEvents,
                    assertive = rideData.assertiveDriving,
                    efficiency = rideData.efficiencyScore / 100
                }
            end
        end,
        getDescription = function(fare, passengerType)
            return string.format("%s (%d passengers) - Time critical", passengerType.name, fare.passengers)
        end,
        getPaymentLabel = function(fare, speedFactor, passengerType)
            local label
            if speedFactor < -0.08 then
                label = "Lateness Penalty"
            elseif speedFactor > 0.08 then
                label = "Efficiency Bonus"
            else
                label = "On Time"
            end
            
            if fare.rideQuality then
                local rq = fare.rideQuality
                if speedFactor > 0.15 and rq.assertive then
                    label = label .. " | Assertive Driving"
                elseif speedFactor < -0.2 then
                    label = label .. " | Unacceptable Delays"
                elseif rq.aggressiveEvents and rq.aggressiveEvents > 10 then
                    label = label .. " | Reckless Driving"
                end
            end
            return label
        end
    })
end

M.onExtensionLoaded = onExtensionLoaded

return M 