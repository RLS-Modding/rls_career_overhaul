local M = {}

local function onExtensionLoaded()
    print("Loading Tourist Passenger Type...")
    
    -- Register the tourist passenger type with the taxi system
    gameplay_taxi.registerPassengerType("TOURIST", {
        name = "Tourist",
        description = "Tourists who enjoy the journey and scenery",
        baseMultiplier = 0.9,
        speedWeight = -0.2, -- Actually prefer slower rides
        distanceWeight = 0.8,
        selectionWeight = 2,
        fareWeights = {
            {min = 0.4, max = 0.7, weight = 4}, -- 40% chance - budget traveler
            {min = 0.7, max = 1.0, weight = 5}, -- 50% chance - average tourist
            {min = 1.0, max = 1.4, weight = 1}  -- 10% chance - affluent tourist
        },
        speedTolerance = 1.5, -- Very forgiving about time
        calculateReward = function(fare, elapsedTime, speedFactor, passengerType)
            local basePayment = fare.baseFare * (fare.totalDistance / 1000)
            
            -- Tourists enjoy scenic, leisurely rides - custom speed calculation
            local actualSpeed = (fare.totalDistance / 1000) / elapsedTime
            local suggestedSpeed = 18 -- m/s suggested speed
            local minSpeed = 1.5 -- Minimum speed to qualify for bonuses (tourists more tolerant)
            
            local speedModifier = 0
            if actualSpeed >= minSpeed then
                -- Reward leisurely speeds, small penalty for rushing
                if actualSpeed <= suggestedSpeed * 0.8 then
                    -- Big bonus for leisurely scenic driving
                    speedModifier = (suggestedSpeed * 0.8 - actualSpeed) / (suggestedSpeed * 0.8) * 0.6
                elseif actualSpeed <= suggestedSpeed then
                    -- Small bonus for normal speeds
                    speedModifier = (suggestedSpeed - actualSpeed) / suggestedSpeed * 0.2
                else
                    -- Small penalty for rushing (tourists don't mind efficiency as much as luxury)
                    speedModifier = -(actualSpeed - suggestedSpeed) / suggestedSpeed * 0.3
                end
            end
            
            -- Tourists want to enjoy the experience
            local experienceBonus = 0
            if fare.rideQuality then
                experienceBonus = fare.rideQuality.smoothness * 0.6 -- Good smoothness bonus
                if fare.rideQuality.aggressiveEvents > 3 then
                    experienceBonus = experienceBonus - (fare.rideQuality.aggressiveEvents * 0.2) -- Ruins experience
                end
                if fare.rideQuality.scenic then
                    experienceBonus = experienceBonus + 0.3 -- Scenic ride bonus
                end
            end
            
            -- Ensure final multiplier is never below 0.2 (minimum 20% payment)
            local finalMultiplier = math.max(0.2, 1 + speedModifier + experienceBonus)
            return basePayment * finalMultiplier
        end,
        onUpdate = function(fare, rideData, passengerType)
            -- Tourists want to enjoy the scenery and experience
            if not rideData.smoothnessScore then
                rideData.smoothnessScore = 100
                rideData.aggressiveEvents = 0
                rideData.scenicExperience = 100
                rideData.gentleRideTime = 0
            end
            
            if rideData.currentSensorData then
                local gx, gy, gz = rideData.currentSensorData.gx, rideData.currentSensorData.gy, rideData.currentSensorData.gz
                local totalGForce = math.sqrt(gx*gx + gy*gy + gz*gz)
                
                -- Strict thresholds for comfort and experience
                if gy > 0.65 then -- Hard braking
                    ui_message("Tourist Passenger: Hard braking Detected", 2, "info", "info")
                    rideData.aggressiveEvents = rideData.aggressiveEvents + 1
                    rideData.smoothnessScore = math.max(0, rideData.smoothnessScore - 8)
                    rideData.scenicExperience = math.max(0, rideData.scenicExperience - 12)
                elseif gy < -0.55 then -- Hard acceleration
                    ui_message("Tourist Passenger: Hard acceleration Detected", 2, "info", "info")
                    rideData.aggressiveEvents = rideData.aggressiveEvents + 1
                    rideData.smoothnessScore = math.max(0, rideData.smoothnessScore - 6)
                    rideData.scenicExperience = math.max(0, rideData.scenicExperience - 10)
                elseif math.abs(gx) > 0.8 then -- Sharp turns
                    ui_message("Tourist Passenger: Sharp turn Detected", 2, "info", "info")
                    rideData.aggressiveEvents = rideData.aggressiveEvents + 1
                    rideData.smoothnessScore = math.max(0, rideData.smoothnessScore - 6)
                    rideData.scenicExperience = math.max(0, rideData.scenicExperience - 8)
                end
                
                -- Bonus for gentle, scenic driving
                if totalGForce < 0.4 then
                    rideData.gentleRideTime = rideData.gentleRideTime + 1
                    rideData.scenicExperience = math.min(100, rideData.scenicExperience + 1)
                end
                
                local isScenic = rideData.gentleRideTime > 20 and rideData.smoothnessScore > 80
                
                fare.rideQuality = {
                    smoothness = rideData.smoothnessScore / 100,
                    aggressiveEvents = rideData.aggressiveEvents,
                    scenic = isScenic,
                    experience = rideData.scenicExperience / 100
                }
            end
        end,
        getDescription = function(fare, passengerType)
            return string.format("%s (%d passengers) - Scenic route", passengerType.name, fare.passengers)
        end,
        getPaymentLabel = function(fare, speedFactor, passengerType)
            local actualSpeed = (fare.totalDistance / 1000) / (os.difftime(os.time(), fare.startTime))
            local suggestedSpeed = 18
            
            local label
            if actualSpeed <= suggestedSpeed * 0.6 then
                label = "Scenic Bonus"
            elseif actualSpeed <= suggestedSpeed then
                label = "Perfect Pace"
            else
                label = "Too Fast"
            end
            
            if fare.rideQuality then
                local rq = fare.rideQuality
                if rq.scenic then
                    label = label .. " | Wonderful Tour"
                elseif rq.aggressiveEvents and rq.aggressiveEvents > 3 then
                    label = label .. " | Ruined Experience"
                elseif rq.smoothness and rq.smoothness < 0.6 then
                    label = label .. " | Uncomfortable Ride"
                end
            end
            return label
        end
    })
    
    print("Tourist passenger type registered successfully")
end

M.onExtensionLoaded = onExtensionLoaded

return M 