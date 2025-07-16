local M = {}

local function onExtensionLoaded()
    print("Loading Business Passenger Type...")
    
    -- Register the business passenger type with the taxi system
    gameplay_taxi.registerPassengerType("BUSINESS", {
        name = "Business",
        description = "Time-conscious passengers with strict schedules",
        baseMultiplier = 1.4,
        speedWeight = 1.5, -- Very concerned about speed
        distanceWeight = 1.0,
        selectionWeight = 3,
        fareWeights = {
            {min = 1.0, max = 1.3, weight = 2}, -- 20% chance - budget meeting
            {min = 1.3, max = 1.8, weight = 6}, -- 60% chance - normal business
            {min = 1.8, max = 2.3, weight = 2}  -- 20% chance - urgent/executive
        },
        speedTolerance = 0.2, -- Very strict about time
        calculateReward = function(fare, elapsedTime, speedFactor, passengerType)
            local basePayment = fare.baseFare * (fare.totalDistance / 1000)
            local speedBonus = speedFactor * passengerType.speedWeight
            local timePenalty = math.min(0, speedFactor * 1.5) -- Business passengers heavily penalize slowness
            
            -- Business passengers care more about efficiency than comfort
            local efficiencyBonus = 0
            if fare.rideQuality then
                -- Small penalty for excessive aggressive events
                if fare.rideQuality.aggressiveEvents > 8 then
                    efficiencyBonus = efficiencyBonus - (fare.rideQuality.aggressiveEvents * 0.05)
                end
                -- Bonus for assertive driving if it improved speed
                if speedFactor > 0.2 and fare.rideQuality.assertive then
                    efficiencyBonus = efficiencyBonus + 0.15
                end
            end
            
            return basePayment * (1 + speedBonus + timePenalty + efficiencyBonus)
        end,
        onUpdate = function(fare, rideData, passengerType)
            -- Business passengers prioritize time over comfort
            if not rideData.aggressiveEvents then
                rideData.aggressiveEvents = 0
                rideData.assertiveDriving = false
                rideData.efficiencyScore = 100
            end
            
            if rideData.currentSensorData then
                local gx, gy = rideData.currentSensorData.gx, rideData.currentSensorData.gy
                local totalGForce = math.sqrt(gx*gx + gy*gy)
                
                -- More lenient thresholds - they understand urgency
                if gy > 0.9 then -- Very hard braking
                    ui_message("Business Passenger: Very hard braking Detected", 2, "info", "info")
                    rideData.aggressiveEvents = rideData.aggressiveEvents + 1
                    rideData.efficiencyScore = math.max(0, rideData.efficiencyScore - 2)
                elseif gy < -0.8 then -- Hard acceleration (but give them credit for urgency)
                    ui_message("Business Passenger: Hard acceleration Detected", 2, "info", "info")
                    rideData.aggressiveEvents = rideData.aggressiveEvents + 1
                    rideData.assertiveDriving = true
                elseif math.abs(gx) > 1 then -- Very sharp turns
                    ui_message("Business Passenger: Very sharp turn Detected", 2, "info", "info")
                    rideData.aggressiveEvents = rideData.aggressiveEvents + 1
                    rideData.efficiencyScore = math.max(0, rideData.efficiencyScore - 2)
                end
                
                -- Bonus for confident, assertive driving
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
    
    print("Business passenger type registered successfully")
end

M.onExtensionLoaded = onExtensionLoaded

return M 