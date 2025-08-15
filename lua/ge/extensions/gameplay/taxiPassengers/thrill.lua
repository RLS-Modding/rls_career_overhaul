local M = {}

local function onExtensionLoaded()
    gameplay_taxi.registerPassengerType("THRILL", {
        name = "Thrill Seeker",
        description = "Adrenaline junkies who love high G-forces and speed",
        baseMultiplier = 0.8,
        speedWeight = 2.0,
        distanceWeight = 1.0,
        selectionWeight = 2,
        seatRange = {nil, 5},
        valueRange = {0.0, 1.6},
        fareWeights = {
            {min = 0.9, max = 1.2, weight = 3},
            {min = 1.2, max = 1.6, weight = 5},
            {min = 1.6, max = 2.2, weight = 2}
        },
        speedTolerance = 0.6,
        calculateTipBreakdown = function(fare, elapsedTime, speedFactor, passengerType)
            local tipBreakdown = {}
            local baseFare = tonumber(fare.baseFare) or 0

            if speedFactor > 0.05 then
                tipBreakdown["Speed Rush"] = math.min(speedFactor * baseFare * 0.5, 0.5 * baseFare)
            end

            if fare.rideQuality and fare.rideQuality.thrillData then
                local td = fare.rideQuality.thrillData
                if td.avgG and td.avgG > 0.7 then
                    tipBreakdown["Adrenaline Bonus"] = math.min((td.avgG - 0.7) * 0.8 * baseFare, 0.5 * baseFare)
                end
                if td.maxG and td.maxG > 1.2 then
                    tipBreakdown["Peak Thrill"] = math.min((td.maxG - 1.2) * 0.4 * baseFare, 0.4 * baseFare)
                end
            end

            return tipBreakdown
        end,
        onUpdate = function(fare, rideData, passengerType)
            if not rideData.thrillData then
                rideData.thrillData = {gReadings = {}, avgG = 0, maxG = 0}
            end
            if rideData.currentSensorData then
                local gx, gy = rideData.currentSensorData.gx, rideData.currentSensorData.gy
                local total = math.sqrt(gx*gx + gy*gy)
                rideData.thrillData.maxG = math.max(rideData.thrillData.maxG, total)
                table.insert(rideData.thrillData.gReadings, total)
                local sum = 0
                for _, v in ipairs(rideData.thrillData.gReadings) do sum = sum + v end
                rideData.thrillData.avgG = sum / #rideData.thrillData.gReadings

                fare.rideQuality = fare.rideQuality or {}
                fare.rideQuality.thrillData = { avgG = rideData.thrillData.avgG, maxG = rideData.thrillData.maxG }
            end
        end,
        calculateDriverRating = function(fare, rideData, elapsedTime, speedFactor, passengerType)
            local td = fare.rideQuality and fare.rideQuality.thrillData or {}
            local avgG = td.avgG or 0
            local maxG = td.maxG or 0
            local spd = tonumber(speedFactor) or 0
            local rating = 5.0
            if avgG < 0.4 then rating = rating - (0.4 - avgG) * 2.0 end
            if maxG < 0.8 then rating = rating - (0.8 - maxG) * 1.5 end
            if spd <= 0 then rating = rating - math.min(1.0, -spd) * 0.6 end
            if spd > 0.15 then rating = rating + math.min(1.0, spd) * 0.6 end
            if avgG > 1.2 then rating = rating - (avgG - 1.2) * 1.0 end
            if rating > 5 then rating = 5 end
            if rating < 1 then rating = 1 end
            return rating
        end,
        getDescription = function(fare, passengerType)
            return string.format("%s (%d passengers) - Fast and wild", passengerType.name, fare.passengers)
        end,
        getPaymentLabel = function(fare, speedFactor, passengerType)
            local label = speedFactor > 0.1 and "Speed Rush" or "Too Slow"
            if fare.rideQuality and fare.rideQuality.thrillData then
                local td = fare.rideQuality.thrillData
                if td.maxG and td.maxG > 1.2 then
                    label = label .. " | Peak Thrill"
                elseif td.avgG and td.avgG > 0.7 then
                    label = label .. " | Adrenaline Bonus"
                end
            end
            return label
        end
    })
end

M.onExtensionLoaded = onExtensionLoaded

return M 


