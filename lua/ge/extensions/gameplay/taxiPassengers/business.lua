local M = {}

local function onExtensionLoaded()
    gameplay_taxi.registerPassengerType("BUSINESS", {
        name = "Business",
        description = "Time-conscious passengers with strict schedules",
        baseMultiplier = 0.7,
        speedWeight = 1.5,
        distanceWeight = 1.0,
        selectionWeight = 3,
        seatRange = {nil, 10},
        valueRange = {0.5, 2},
        fareWeights = {
            {min = 0.8, max = 1.2, weight = 2},
            {min = 1.2, max = 1.6, weight = 6},
            {min = 1.6, max = 2.0, weight = 2}
        },
        speedTolerance = 0.2,
        calculateReward = function(fare, elapsedTime, speedFactor, passengerType)
            local basePayment = fare.baseFare * (fare.totalDistance / 1000)
            local speedBonus = math.max(-0.5, speedFactor * passengerType.speedWeight) -- Cap negative bonus
            local timePenalty = 0
            
            local efficiencyBonus = 0
            if fare.rideQuality then
                if fare.rideQuality.aggressiveEvents > 8 then
                    efficiencyBonus = efficiencyBonus - math.min(0.4, (fare.rideQuality.aggressiveEvents - 8) * 0.05) -- Cap aggressive penalty
                end
                if speedFactor > 0.2 and fare.rideQuality.assertive then
                    efficiencyBonus = efficiencyBonus + 0.15
                end
            end
            
            local finalMultiplier = math.max(0.1, 1 + speedBonus + timePenalty + efficiencyBonus) -- Ensure minimum 10% payout
            return basePayment * finalMultiplier
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
                
                if gy > 0.9 then
                    ui_message("Business Passenger: Very hard braking Detected", 2, "info", "info")
                    rideData.aggressiveEvents = rideData.aggressiveEvents + 1
                    rideData.efficiencyScore = math.max(0, rideData.efficiencyScore - 2)
                elseif gy < -0.8 then
                    ui_message("Business Passenger: Hard acceleration Detected", 2, "info", "info")
                    rideData.aggressiveEvents = rideData.aggressiveEvents + 1
                    rideData.assertiveDriving = true
                elseif math.abs(gx) > 1 then
                    ui_message("Business Passenger: Very sharp turn Detected", 2, "info", "info")
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
            if speedFactor < -0.1 then
                label = "Lateness Penalty"
            elseif speedFactor > 0.1 then
                label = "Efficiency Bonus"
            else
                label = "On Time"
            end
            
            if fare.rideQuality then
                local rq = fare.rideQuality
                if speedFactor > 0.2 and rq.assertive then
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