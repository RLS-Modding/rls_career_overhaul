local M = {}

-- ================================
-- PARTY PASSENGER TYPE
-- ================================

local function onExtensionLoaded()
    gameplay_taxi.registerPassengerType("PARTY", {
        name = "Party Group",
        description = "Large groups heading to parties who value safety and comfort over speed",
        baseMultiplier = 0.5,
        speedWeight = -0.5, -- Negative weight means they prefer slower, safer driving
        distanceWeight = 1.2,
        selectionWeight = 3,
        seatRange = {15, nil}, -- Minimum 15 seats, no maximum limit
        valueRange = {1.5, nil}, -- Any vehicle value is acceptable
        speedTolerance = 0.3, -- More sensitive to speed variations
        
        -- Party groups prefer lower fares but tip well for safe driving
        fareWeights = {
            {min = 0.4, max = 0.6, weight = 4},
            {min = 0.6, max = 0.9, weight = 3},
            {min = 0.9, max = 1.2, weight = 2}
        },
        
        -- Custom tip breakdown that penalizes high speeds and rewards smooth driving
        calculateTipBreakdown = function(fare, elapsedTime, speedFactor, passengerType)
            local tipBreakdown = {}
            local baseFare = tonumber(fare.baseFare) or 0
            
            -- Party passengers prefer safe, slow driving
            if speedFactor < -0.1 then
                tipBreakdown["Safety Bonus"] = 0.3 * baseFare
            end
            
            -- Additional tip for very smooth ride (if sensor data available)
            if gameplay_taxi.rideData and gameplay_taxi.rideData.currentSensorData then
                local sensorData = gameplay_taxi.rideData.currentSensorData
                local totalG = math.abs(sensorData.gx or 0) + math.abs(sensorData.gy or 0)
                
                if totalG < 0.3 then
                    tipBreakdown["Smooth Ride"] = 0.2 * baseFare
                end
            end
            
            -- Check party data for additional bonuses
            if fare.rideQuality and fare.rideQuality.partyData then
                local partyData = fare.rideQuality.partyData
                if partyData.avgGForce and partyData.avgGForce < 0.25 then
                    tipBreakdown["Gentle Driving"] = 0.15 * baseFare
                end
                if partyData.maxGForce and partyData.maxGForce < 0.5 then
                    tipBreakdown["No Sudden Movements"] = 0.1 * baseFare
                end
            end
            
            return tipBreakdown
        end,
        
        -- Custom description for party groups
        getDescription = function(fare, passengerType)
            return string.format("Party Group (%d people) - Drive safely!", fare.passengers)
        end,
        
        -- Custom payment label
        getPaymentLabel = function(fare, speedFactor, passengerType)
            if speedFactor > 0.2 then
                return "Speed Penalty"
            elseif speedFactor < -0.1 then
                return "Safety Bonus"
            else
                return "Standard Rate"
            end
        end,
        
        -- Track party-specific ride data
        onUpdate = function(fare, rideData, passengerType)
            if not rideData.partyData then
                rideData.partyData = {
                    maxGForce = 0,
                    avgGForce = 0,
                    gForceReadings = {},
                    startTime = os.time()
                }
            end
            
            -- Track G-force data for smooth ride assessment
            if rideData.currentSensorData then
                local totalG = math.abs(rideData.currentSensorData.gx or 0) + 
                              math.abs(rideData.currentSensorData.gy or 0)
                
                rideData.partyData.maxGForce = math.max(rideData.partyData.maxGForce, totalG)
                table.insert(rideData.partyData.gForceReadings, totalG)
                
                -- Calculate running average
                local sum = 0
                for _, reading in ipairs(rideData.partyData.gForceReadings) do
                    sum = sum + reading
                end
                rideData.partyData.avgGForce = sum / #rideData.partyData.gForceReadings
                
                -- Store in fare for tip calculation
                fare.rideQuality = fare.rideQuality or {}
                fare.rideQuality.partyData = rideData.partyData
            end
        end
    })
    
    print("Party passenger type registered successfully!")
end

-- ================================
-- MODULE EXPORTS
-- ================================
M.onExtensionLoaded = onExtensionLoaded

return M 