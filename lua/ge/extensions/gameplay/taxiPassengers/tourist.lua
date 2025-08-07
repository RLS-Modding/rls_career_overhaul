local M = {}

local function onExtensionLoaded()
    gameplay_taxi.registerPassengerType("TOURIST", {
        name = "Tourist",
        description = "Tourists who enjoy the journey and scenery",
        baseMultiplier = 0.85,
        speedWeight = -0.25,
        distanceWeight = 0.9,
        selectionWeight = 3,
        seatRange = {4, nil},
        valueRange = {0.6, nil},
        fareWeights = {
            {min = 0.5, max = 0.75, weight = 4},
            {min = 0.75, max = 1.05, weight = 5},
            {min = 1.05, max = 1.4, weight = 2}
        },
        speedTolerance = 1.2,
        calculateTipBreakdown = function(fare, elapsedTime, speedFactor, passengerType)
            local tipBreakdown = {}
            local baseFare = tonumber(fare.baseFare) or 0
            
            local actualSpeed = (tonumber(fare.totalDistance) or 0) / math.max(1, elapsedTime) * 1000
            local suggestedSpeed = 18
            local minSpeed = 1.5
            
            -- Speed preference (tourists enjoy slower, scenic drives)
            if actualSpeed >= minSpeed then
                if actualSpeed <= suggestedSpeed * 0.6 then
                    tipBreakdown["Scenic Bonus"] = (suggestedSpeed * 0.6 - actualSpeed) / (suggestedSpeed * 0.6) * 0.5 * baseFare
                elseif actualSpeed <= suggestedSpeed * 0.8 then
                    tipBreakdown["Perfect Pace"] = (suggestedSpeed * 0.8 - actualSpeed) / (suggestedSpeed * 0.8) * 0.35 * baseFare
                elseif actualSpeed <= suggestedSpeed then
                    tipBreakdown["Good Pace"] = (suggestedSpeed - actualSpeed) / suggestedSpeed * 0.15 * baseFare
                end
            end
            
            -- Experience bonuses only
            if fare.rideQuality then
                if fare.rideQuality.smoothness and fare.rideQuality.smoothness > 0.8 then
                    tipBreakdown["Comfortable Tour"] = fare.rideQuality.smoothness * 0.5 * baseFare
                elseif fare.rideQuality.smoothness and fare.rideQuality.smoothness > 0.6 then
                    tipBreakdown["Smooth Experience"] = fare.rideQuality.smoothness * 0.25 * baseFare
                end
                
                if fare.rideQuality.scenic then
                    tipBreakdown["Wonderful Tour"] = 0.25 * baseFare
                end
            end
            
            return tipBreakdown
        end,
        onUpdate = function(fare, rideData, passengerType)
            if not rideData.smoothnessScore then
                rideData.smoothnessScore = 100
                rideData.aggressiveEvents = 0
                rideData.scenicExperience = 100
                rideData.gentleRideTime = 0
            end
            
            if rideData.currentSensorData then
                local gx, gy, gz = rideData.currentSensorData.gx, rideData.currentSensorData.gy, rideData.currentSensorData.gz
                local totalGForce = math.sqrt(gx*gx + gy*gy + gz*gz)
                
                if gy > 0.65 then
                    rideData.aggressiveEvents = rideData.aggressiveEvents + 1
                    rideData.smoothnessScore = math.max(0, rideData.smoothnessScore - 8)
                    rideData.scenicExperience = math.max(0, rideData.scenicExperience - 12)
                elseif gy < -0.55 then
                    rideData.aggressiveEvents = rideData.aggressiveEvents + 1
                    rideData.smoothnessScore = math.max(0, rideData.smoothnessScore - 6)
                    rideData.scenicExperience = math.max(0, rideData.scenicExperience - 10)
                elseif math.abs(gx) > 0.8 then
                    rideData.aggressiveEvents = rideData.aggressiveEvents + 1
                    rideData.smoothnessScore = math.max(0, rideData.smoothnessScore - 6)
                    rideData.scenicExperience = math.max(0, rideData.scenicExperience - 8)
                end
                
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
            local actualSpeed = (fare.totalDistance / 1000) / math.max(1, (os.difftime(os.time(), fare.startTime)))
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
end

M.onExtensionLoaded = onExtensionLoaded

return M 