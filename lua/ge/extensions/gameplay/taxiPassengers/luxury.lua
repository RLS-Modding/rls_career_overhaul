local M = {}

local luxuryPassenger = {
    name = "Luxury",
    description = "High-paying passengers who value comfort over speed",
    baseMultiplier = 0.7,
    speedWeight = 0.3,
    distanceWeight = 1.2,
    selectionWeight = 2,
    seatRange = {nil, 5},
    valueRange = {1, nil},
    fareWeights = {
        {min = 0.5, max = 0.8, weight = 2},
        {min = 0.8, max = 1.2, weight = 5},
        {min = 1.5, max = 2.0, weight = 3}
    },
    speedTolerance = 1.0,
    calculateReward = function(fare, elapsedTime, speedFactor, passengerType)
        local basePayment = fare.baseFare * (fare.totalDistance / 1000)
        
        local actualSpeed = (fare.totalDistance / 1000) / elapsedTime
        local suggestedSpeed = 18
        local minSpeed = 2
        
        local speedModifier = 0
        if actualSpeed >= minSpeed then
            if actualSpeed <= suggestedSpeed then
                speedModifier = (suggestedSpeed - actualSpeed) / suggestedSpeed * 0.4
            else
                speedModifier = -(actualSpeed - suggestedSpeed) / suggestedSpeed * 0.6
            end
        end
        
        local qualityBonus = 0
        if fare.rideQuality then
            qualityBonus = fare.rideQuality.smoothness * 0.8
            if fare.rideQuality.aggressiveEvents > 2 then
                qualityBonus = qualityBonus - (fare.rideQuality.aggressiveEvents * 0.3)
            end
        end
        
        local finalMultiplier = math.max(0.1, 1 + speedModifier + qualityBonus)
        return basePayment * finalMultiplier
    end,
    onUpdate = function(fare, rideData, passengerType)
        if not rideData.smoothnessScore then
            rideData.smoothnessScore = 100
            rideData.aggressiveEvents = 0
            rideData.luxuryComfort = 100
        end
        
        if rideData.currentSensorData then
            local gx, gy, gz = rideData.currentSensorData.gx, rideData.currentSensorData.gy, rideData.currentSensorData.gz
            local totalGForce = math.sqrt(gx*gx + gy*gy + gz*gz)
            
            if gy > 0.55 then
                rideData.aggressiveEvents = rideData.aggressiveEvents + 1
                ui_message("Luxury Passenger: Hard braking Detected", 2, "info", "info")
                rideData.smoothnessScore = math.max(0, rideData.smoothnessScore - 10)
                rideData.luxuryComfort = math.max(0, rideData.luxuryComfort - 15)
            elseif gy < -0.5 then
                rideData.aggressiveEvents = rideData.aggressiveEvents + 1
                ui_message("Luxury Passenger: Hard acceleration Detected", 2, "info", "info")
                rideData.smoothnessScore = math.max(0, rideData.smoothnessScore - 8)
                rideData.luxuryComfort = math.max(0, rideData.luxuryComfort - 12)
            elseif math.abs(gx) > 0.7 then
                rideData.aggressiveEvents = rideData.aggressiveEvents + 1
                ui_message("Luxury Passenger: Sharp turn Detected", 2, "info", "info")
                rideData.smoothnessScore = math.max(0, rideData.smoothnessScore - 8)
                rideData.luxuryComfort = math.max(0, rideData.luxuryComfort - 10)
            end
            
            if totalGForce < 0.3 then
                rideData.luxuryComfort = math.min(100, rideData.luxuryComfort + 1)
            end
            
            fare.rideQuality = {
                smoothness = rideData.smoothnessScore / 100,
                aggressiveEvents = rideData.aggressiveEvents,
                luxury = rideData.luxuryComfort / 100
            }
        end
    end,
    getDescription = function(fare, passengerType)
        return string.format("%s (%d passengers) - Premium fare", passengerType.name, fare.passengers)
    end,
    getPaymentLabel = function(fare, speedFactor, passengerType)
        local actualSpeed = (fare.totalDistance / 1000) / (os.difftime(os.time(), fare.startTime))
        local suggestedSpeed = 18
        
        local label
        if actualSpeed <= suggestedSpeed * 0.7 then
            label = "Comfort Bonus"
        elseif actualSpeed <= suggestedSpeed then
            label = "Premium Service"
        else
            label = "Speed Penalty"
        end
        
        if fare.rideQuality then
            local rq = fare.rideQuality
            if rq.luxury and rq.luxury > 0.9 then
                label = label .. " | Premium Comfort"
            elseif rq.smoothness and rq.smoothness < 0.6 then
                label = label .. " | Unacceptable Service"
            elseif rq.aggressiveEvents and rq.aggressiveEvents > 2 then
                label = label .. " | Too Rough"
            end
        end
        return label
    end
}

local function onExtensionLoaded()
    gameplay_taxi.registerPassengerType("LUXURY", luxuryPassenger)
end

M.onExtensionLoaded = onExtensionLoaded

return M 