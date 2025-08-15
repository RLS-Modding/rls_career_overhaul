local M = {}

local function onExtensionLoaded()
    gameplay_taxi.registerPassengerType("FAMILY", {
        name = "Family",
        description = "Families prioritizing safe, smooth rides with more seats",
        baseMultiplier = 0.6,
        speedWeight = -0.2,
        distanceWeight = 1.1,
        selectionWeight = 3,
        seatRange = {4, 8},
        valueRange = {0.6, nil},
        fareWeights = {
            {min = 0.7, max = 1.0, weight = 5},
            {min = 1.0, max = 1.3, weight = 3},
            {min = 1.3, max = 1.6, weight = 1}
        },
        speedTolerance = 0.4,
        calculateTipBreakdown = function(fare, elapsedTime, speedFactor, passengerType)
            local tipBreakdown = {}
            local baseFare = tonumber(fare.baseFare) or 0
            if speedFactor < -0.05 then
                tipBreakdown["Safe Driving"] = 0.2 * baseFare
            end
            if fare.rideQuality and fare.rideQuality.smoothness and fare.rideQuality.smoothness > 0.75 then
                tipBreakdown["Smooth Ride"] = 0.15 * baseFare
            end
            return tipBreakdown
        end,
		onUpdate = function(fare, rideData, passengerType)
			if not rideData.smoothnessScore then
				rideData.smoothnessScore = 100
				rideData.peakG = 0
			end
			if rideData.currentSensorData then
				local gx = rideData.currentSensorData.gx
				local gy = rideData.currentSensorData.gy
				local gz = rideData.currentSensorData.gz or 0
				local totalGForce = math.sqrt(gx*gx + gy*gy + gz*gz)
				if totalGForce > (rideData.peakG or 0) then
					rideData.peakG = totalGForce
				end
				if totalGForce > 2.0 then
					rideData.smoothnessScore = math.max(0, rideData.smoothnessScore - 20)
				elseif math.abs(gx) > 0.7 or math.abs(gy) > 0.6 then
					rideData.smoothnessScore = math.max(0, rideData.smoothnessScore - 2)
				else
					rideData.smoothnessScore = math.min(100, rideData.smoothnessScore + 0.5)
				end
				fare.rideQuality = fare.rideQuality or {}
				fare.rideQuality.smoothness = rideData.smoothnessScore / 100
				fare.rideQuality.peakG = rideData.peakG
			end
		end,
        calculateDriverRating = function(fare, rideData, elapsedTime, speedFactor, passengerType)
            local smooth = (fare.rideQuality and fare.rideQuality.smoothness) or 1.0
            local spd = tonumber(speedFactor) or 0
            local rating = 5.0
            rating = rating - (1 - smooth) * 2.0
            if spd > 0 then rating = rating - math.min(1.0, spd) * 0.8 end
            if spd < -0.1 and smooth > 0.85 then rating = rating + 0.2 end
            if rating > 5 then rating = 5 end
            if rating < 1 then rating = 1 end
            return rating
        end,
        getDescription = function(fare, passengerType)
            return string.format("%s (%d passengers) - Keep it safe", passengerType.name, fare.passengers)
        end,
        getPaymentLabel = function(fare, speedFactor, passengerType)
            local label = speedFactor < 0 and "Safe Driving" or "Standard"
            if fare.rideQuality and fare.rideQuality.smoothness and fare.rideQuality.smoothness > 0.8 then
                label = label .. " | Smooth Ride"
            end
            return label
        end
    })
end

M.onExtensionLoaded = onExtensionLoaded

return M 


