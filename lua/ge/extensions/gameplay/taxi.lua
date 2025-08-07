local M = {}
M.dependencies = {'gameplay_sites_sitesManager', 'freeroam_facilities'}

-- ================================
-- MODULE DEPENDENCIES
-- ================================
local core_groundMarkers = require('core/groundMarkers')

-- ================================
-- STATE VARIABLES
-- ================================
local dataToSend = {}
local cumulativeReward = 0
local fareStreak = 0
local currentFare = nil
local availableSeats = nil
local state = "start"
local timer = 0
local updateTimer = 1
local jobOfferTimer = 0
local jobOfferInterval = math.random(5, 45)

local currentVehiclePartsTree = nil
local vehicleMultiplier = 0.1

local parkingSpots = nil
local validPickupSpots = nil

local distanceMultiplier = 4.5
local suggestedSpeed = 18

M.rideData = {}

-- ================================
-- FORWARD DECLARATIONS
-- ================================
local requestTaxiState
local startRide

-- ================================
-- PASSENGER TYPE SYSTEM
-- ================================
local passengerTypes = {
    STANDARD = {
        name = "Standard",
        description = "Regular passengers who value speed and efficiency",
        baseMultiplier = 1.0,
        speedWeight = 1.0,
        distanceWeight = 1.0,
        selectionWeight = 5,
        seatRange = {nil, 10},
        valueRange = {nil, nil},
        fareWeights = {
            {min = 0.5, max = 0.8, weight = 3},
            {min = 0.8, max = 1.2, weight = 5},
            {min = 1.2, max = 1.5, weight = 2}
        },
        speedTolerance = 0.5,
        calculateTipBreakdown = function(fare, elapsedTime, speedFactor, passengerType)
            local tipBreakdown = {}
            local baseFare = tonumber(fare.baseFare) or 0
            
            if speedFactor > 0 then
                tipBreakdown["Speed Bonus"] = speedFactor * baseFare * passengerType.speedWeight * 0.5
            end
            
            return tipBreakdown
        end,
        onUpdate = function() end,
        getDescription = function(fare, passengerType)
            return string.format("%s (%d passengers)", passengerType.name, fare.passengers)
        end,
        getPaymentLabel = function(fare, speedFactor, passengerType)
            return speedFactor > 0 and "Speed Bonus" or "Time Penalty"
        end
    }
}

local function getPassengerType(typeKey)
    return passengerTypes[typeKey]
end

local function selectRandomPassengerType(valueMultiplier, availableSeats)
    -- Filter passenger types based on seat and value multiplier requirements
    local eligibleTypes = {}
    local totalWeight = 0
    
    for typeKey, passengerType in pairs(passengerTypes) do
        local seatsValid = (not availableSeats) or 
                          (availableSeats >= (passengerType.seatRange[1] or 1) and 
                           availableSeats <= (passengerType.seatRange[2] or 999))
        
        local valueValid = (not valueMultiplier) or 
                          (valueMultiplier >= (passengerType.valueRange[1] or 0.0) and 
                           valueMultiplier <= (passengerType.valueRange[2] or 999.0))
        
        if seatsValid and valueValid then
            eligibleTypes[typeKey] = passengerType
            totalWeight = totalWeight + passengerType.selectionWeight
        end
    end
    
    -- If no types are eligible, fall back to STANDARD
    if totalWeight == 0 then
        return "STANDARD"
    end
    
    local random = math.random() * totalWeight
    local currentWeight = 0
    
    for typeKey, passengerType in pairs(eligibleTypes) do
        currentWeight = currentWeight + passengerType.selectionWeight
        if random <= currentWeight then
            return typeKey
        end
    end
    
    return "STANDARD"
end

local function registerPassengerType(key, passengerTypeData)
    -- Set default values if not provided
    passengerTypeData.baseMultiplier = passengerTypeData.baseMultiplier or 1.0
    passengerTypeData.speedWeight = passengerTypeData.speedWeight or 1.0
    passengerTypeData.distanceWeight = passengerTypeData.distanceWeight or 1.0
    passengerTypeData.selectionWeight = passengerTypeData.selectionWeight or 1
    passengerTypeData.speedTolerance = passengerTypeData.speedTolerance or 0.5
    
    -- Set default seat and value multiplier ranges as arrays
    passengerTypeData.seatRange = passengerTypeData.seatRange or {nil, nil}
    passengerTypeData.valueRange = passengerTypeData.valueRange or {nil, nil}
    
    -- Set default fare system
    if not passengerTypeData.fareWeights and not passengerTypeData.fareRange then
        passengerTypeData.fareWeights = {
            {min = 0.5, max = 0.8, weight = 3},
            {min = 0.8, max = 1.2, weight = 5},
            {min = 1.2, max = 1.5, weight = 2}
        }
    end
    
    -- Set default functions if not provided
    if not passengerTypeData.calculateTipBreakdown then
        passengerTypeData.calculateTipBreakdown = function(fare, elapsedTime, speedFactor, passengerType)
            local tipBreakdown = {}
            local baseFare = tonumber(fare.baseFare) or 0
            
            if speedFactor > 0 then
                tipBreakdown["Speed Bonus"] = speedFactor * baseFare * passengerType.speedWeight * 0.5
            end
            
            return tipBreakdown
        end
    end
    
    if not passengerTypeData.getDescription then
        passengerTypeData.getDescription = function(fare, passengerType)
            return string.format("%s (%d passengers)", passengerType.name, fare.passengers)
        end
    end
    
    if not passengerTypeData.getPaymentLabel then
        passengerTypeData.getPaymentLabel = function(fare, speedFactor, passengerType)
            return speedFactor > 0 and "Speed Bonus" or "Time Penalty"
        end
    end
    
    if not passengerTypeData.onUpdate then
        passengerTypeData.onUpdate = function(fare, rideData, passengerType)
            -- Default: no special ride tracking
        end
    end

    print("Adding passenger type: " .. passengerTypeData.name)
    
    passengerTypes[key] = passengerTypeData
    print("Registered new passenger type: " .. passengerTypeData.name)
end

local function getPassengerTypes()
    local types = {}
    for typeKey, passengerType in pairs(passengerTypes) do
        table.insert(types, {
            key = typeKey,
            name = passengerType.name,
            description = passengerType.description,
            baseMultiplier = passengerType.baseMultiplier,
            speedWeight = passengerType.speedWeight,
            selectionWeight = passengerType.selectionWeight,
            seatRange = passengerType.seatRange,
            valueRange = passengerType.valueRange,
            fareWeights = passengerType.fareWeights,
            fareRange = passengerType.fareRange
        })
    end
    return types
end

local function getCurrentPassengerType()
    if currentFare and currentFare.passengerType then
        return getPassengerType(currentFare.passengerType)
    end
    return nil
end

-- ================================
-- SENSOR DATA HANDLING
-- ================================
local function updateSensorData()
    if not currentFare or state ~= "dropoff" then
        return
    end
    
    local vehicle = be:getPlayerVehicle(0)
    if not vehicle then return end
    
    vehicle:queueLuaCommand([[
        local sensors = require('sensors')
        if sensors then
            local gx, gy, gz = sensors.gx or 0, sensors.gy or 0, sensors.gz or 0
            local gx2, gy2, gz2 = sensors.gx2 or 0, sensors.gy2 or 0, sensors.gz2 or 0
            obj:queueGameEngineLua('gameplay_taxi.receiveSensorData('..gx..','..gy..','..gz..','..gx2..','..gy2..','..gz2..')')
        end
    ]])
end

local function processSensorData(gx, gy, gz, gx2, gy2, gz2)
    local grav = 9.81 -- Convert to G-force
    M.rideData.currentSensorData = {
        gx = gx / grav, gy = gy / grav, gz = gz / grav,
        gx2 = gx2 / grav, gy2 = gy2 / grav, gz2 = gz2 / grav,
        timestamp = os.time()
    }

    dump(M.rideData.currentSensorData)
    
    if currentFare and currentFare.passengerType then
        local passengerType = getPassengerType(currentFare.passengerType)
        if passengerType and passengerType.onUpdate then
            passengerType.onUpdate(currentFare, M.rideData, passengerType)
        end
    end
end

-- ================================
-- LOCATION AND SITE MANAGEMENT
-- ================================
local function findParkingSpots()
    local sitePath = gameplay_sites_sitesManager.getCurrentLevelSitesFileByName('city')
    if sitePath then
        local siteData = gameplay_sites_sitesManager.loadSites(sitePath, true, true)
        parkingSpots = siteData and siteData.parkingSpots
    end
end

local function findValidPickupSpots()
    local validPickupSpots = {}
    if not be:getPlayerVehicle(0) then return end
    local playerPos = be:getPlayerVehicle(0):getPosition()

    if not parkingSpots then
        findParkingSpots()
    end
    for _, spot in pairs(parkingSpots.objects) do
        if spot.pos and (spot.pos - playerPos):length() < 500 then
            table.insert(validPickupSpots, spot)
        end
    end
    return validPickupSpots
end

-- ================================
-- VEHICLE CAPACITY CALCULATIONS
-- ================================
local function retrievePartsTree()
    currentVehiclePartsTree = nil
    local vehicle = be:getPlayerVehicle(0)
    if vehicle then
        vehicle:queueLuaCommand(
            [[
                local partsTree = v.config.partsTree
                obj:queueGameEngineLua('gameplay_taxi.returnPartsTree(' .. serialize(partsTree) .. ')')
            ]]
        )
    end
end

local function specificCapcityCases(partName)
    if partName:find("capsule") and partName:find("seats") then
      if partName:find("sd12m") then return 25
      elseif partName:find("sd18m") then return 41
      elseif partName:find("sd105") then return 21
      elseif partName:find("sd_seats") then return 33
      elseif partName:find("dd105") then return 29
      elseif partName:find("sd195") then return 43
      elseif partName:find("lh_seats_upper") then return 53        
      elseif partName:find("lh_seats") then return 17
      elseif partName:find("lhd_seats_upper") then return 53        
      elseif partName:find("lhd_seats") then return 17
      elseif partName:find("capsule_rhd_artic_seats_upper") then return 77
      elseif partName:find("capsule_rhd_artic_seats") then return 30 end
    end
    if partName:find("schoolbus_seats_R_c")  then
      return 10
    end
    if partName:find("schoolbus_seats_L_c")  then
      return 10
    end
    return nil
end
  
local function cyclePartsTree(partData, seatingCapacity)
    for first, part in pairs(partData) do
      local partName = part.chosenPartName
      if partName:find("seat") and not partName:find("cargo") and not partName:find("captains") then
        local seatSize = nil
        if partName:find("seats") then
          seatSize = 3
        elseif partName:find("ext") then
          seatSize = 2
        else
          if partName:match("(%d+)R") then
            seatSize = 2
          else
            seatSize = 1
          end
        end
        if partName:find("citybus_seats") then seatSize = 44
        elseif partName:find("skin") then seatSize = 0 end
        if specificCapcityCases(partName) then seatSize = specificCapcityCases(partName) end
        seatingCapacity = seatingCapacity + seatSize
      end
      if part.children then
        seatingCapacity = cyclePartsTree(part.children, seatingCapacity)
      end
      if partName == "pickup" then
        seatingCapacity = math.max(seatingCapacity, 7)
      end
    end
    return seatingCapacity
end
  
local function calculateSeatingCapacity()
    if not currentVehiclePartsTree then
        retrievePartsTree()
    end
    return cyclePartsTree({currentVehiclePartsTree}, 0)
end

local function calculateCapacity(vehicleId)
    if not vehicleId then
        vehicleId = be:getPlayerVehicle(0):getID()
    end
    if career_career.isActive() then
        local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehicleId)
        if not inventoryId then
            return 0
        end
    end
    local seatingCapacity = calculateSeatingCapacity()
    availableSeats = seatingCapacity - 1
    dataToSend = {
        state = state,
        currentFare = currentFare,
        availableSeats = availableSeats,
        vehicleMultiplier = vehicleMultiplier,
        cumulativeReward = cumulativeReward,
        fareStreak = fareStreak,
        currentPassengerType = currentFare and currentFare.passengerTypeName or nil
    }
    guihooks.trigger('updateTaxiState', dataToSend)
    return availableSeats
end

-- ================================
-- FARE GENERATION AND CALCULATION
-- ================================
local function calculatePassengerCount()
    if availableSeats <= 0 then
        return 0
    end
    local weights = {}
    local total = 0

    for i = 1, availableSeats do
        weights[i] = (availableSeats - i + 1)
        total = total + weights[i]
    end

    local random = math.random(total)
    local cumulative = 0

    for i = 1, availableSeats do
        cumulative = cumulative + weights[i]
        if random <= cumulative then
            return i
        end
    end
    return 1
end

local function calculatePassengerCountForType(passengerType)
    if not passengerType then
        return calculatePassengerCount()
    end
    if not availableSeats or availableSeats <= 0 then
        return 0
    end
    local minSeats = passengerType.seatRange and passengerType.seatRange[1] or 1
    local maxSeats = passengerType.seatRange and passengerType.seatRange[2] or availableSeats
    minSeats = math.max(1, minSeats or 1)
    maxSeats = math.min(availableSeats, maxSeats or availableSeats)
    if minSeats > maxSeats then
        minSeats = maxSeats
    end
    local weights = {}
    local total = 0
    for i = minSeats, maxSeats do
        local w = (i - minSeats + 1)
        weights[i] = w
        total = total + w
    end
    local r = math.random(total)
    local cumulative = 0
    for i = minSeats, maxSeats do
        cumulative = cumulative + weights[i]
        if r <= cumulative then
            return i
        end
    end
    return minSeats
end

local function generateFareMultiplier(passengerTypeKey)
    local passengerType = getPassengerType(passengerTypeKey)
    if not passengerType then
        passengerType = getPassengerType("STANDARD")
    end
    
    if passengerType.fareWeights then
        local fareWeights = passengerType.fareWeights
        
        local totalWeight = 0
        for _, tier in ipairs(fareWeights) do
            totalWeight = totalWeight + tier.weight
        end
        
        local random = math.random(totalWeight)
        local currentWeight = 0
        local selectedTier
        
        for _, tier in ipairs(fareWeights) do
            currentWeight = currentWeight + tier.weight
            if random <= currentWeight then
                selectedTier = tier
                break
            end
        end
        
        return math.random(selectedTier.min * 100, selectedTier.max * 100) / 100
    else
        local fareRange = passengerType.fareRange or {0.8, 1.2}
        local min = fareRange[1]
        local max = fareRange[2]
        return math.random(min * 100, max * 100) / 100
    end
end

local function calculateDrivingDistance(startPos, endPos)
    if not map or not map.getPointToPointPath then
        -- Fallback to straight-line distance if pathfinding is not available
        return startPos:distance(endPos)
    end
    
    -- Use the same method as the cab system to calculate actual driving distance
    local path = map.getPointToPointPath(startPos, endPos, 0, 1000, 200, 10000, 1)
    
    if not path or #path == 0 then
        -- Fallback to straight-line distance if no path found
        return startPos:distance(endPos)
    end
    
    -- Calculate total driving distance from path
    local totalDistance = 0
    local prevNodePos = startPos
    
    for i = 1, #path do
        local nodePos = map.getMap().nodes[path[i]].pos
        if nodePos then
            totalDistance = totalDistance + prevNodePos:distance(nodePos)
            prevNodePos = nodePos
        end
    end
    
    -- Add distance from last path node to destination
    totalDistance = totalDistance + prevNodePos:distance(endPos)
    
    return totalDistance
end

local function calculateBaseFare(passengerCount, totalDistance, valueMultiplier, selectedPassengerType)
    local baseFare = 100 * (passengerCount ^ 0.5) * valueMultiplier * distanceMultiplier * selectedPassengerType.baseMultiplier
    baseFare = baseFare * (totalDistance / 1000)
    
    if career_career and career_career.isActive() and career_modules_hardcore.isHardcoreMode() then
        baseFare = baseFare * 0.66
    end
    
    return baseFare
end

local function generateValueMultiplier()
    if not career_career or not career_career.isActive() then
        return 1
    end
    local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(be:getPlayerVehicle(0):getID())
    if not inventoryId then
        return 0
    end
    vehicleMultiplier = (career_modules_valueCalculator.getInventoryVehicleValue(inventoryId) / 30000) ^ 0.5
    vehicleMultiplier = string.format("%.1f", vehicleMultiplier)
    return math.max(vehicleMultiplier, 0.1)
end

local function generateJob()
    validPickupSpots = findValidPickupSpots()
    if not validPickupSpots or #validPickupSpots == 0 then
        print("No nearby pickup locations found!")
        return false
    end

    local pickupSpot = validPickupSpots[math.random(#validPickupSpots)]

    local dropoffSpots = {}
    local minDistance = 600
    for _, spot in pairs(parkingSpots.objects) do
        if spot ~= pickupSpot and pickupSpot.pos:distance(spot.pos) >= minDistance then
            table.insert(dropoffSpots, spot)
        end
    end

    if #dropoffSpots == 0 then
        local randomDir = vec3(math.random() - 0.5, math.random() - 0.5, 0):normalized()
        local destPos = pickupSpot.pos + randomDir * math.random(600, 2000)
        dropoffSpots = {{
            pos = destPos,
            name = "Random Location"
        }}
    end

    local dropoffSpot = dropoffSpots[math.random(#dropoffSpots)]

    if not availableSeats or availableSeats == 0 then
        calculateCapacity(be:getPlayerVehicle(0):getID())
    end

    local valueMultiplier = generateValueMultiplier()
    local selectedPassengerTypeKey = selectRandomPassengerType(valueMultiplier, availableSeats)
    local selectedPassengerType = getPassengerType(selectedPassengerTypeKey)
    local passengerCount = calculatePassengerCountForType(selectedPassengerType)
    local fareMultiplier = generateFareMultiplier(selectedPassengerTypeKey)

    -- Calculate actual driving distance between pickup and dropoff for accurate initial fare
    local actualDistance = calculateDrivingDistance(pickupSpot.pos, dropoffSpot.pos)
    local baseFare = fareMultiplier * calculateBaseFare(passengerCount, actualDistance, valueMultiplier, selectedPassengerType) * ((fareStreak + 1) ^ 0.5)

    if selectedPassengerType.fareWeights then
        local minFare = selectedPassengerType.fareWeights[1].min
        local maxFare = selectedPassengerType.fareWeights[1].max
        
        for _, tier in ipairs(selectedPassengerType.fareWeights) do
            minFare = math.min(minFare, tier.min)
            maxFare = math.max(maxFare, tier.max)
        end
        
        local normalized = (fareMultiplier - minFare) / (maxFare - minFare)
        passengerRating = 1 + (normalized * 4)
    end

    local fare = {
        pickup = {
            pos = pickupSpot.pos
        },
        destination = {
            pos = dropoffSpot.pos
        },
        baseFare = baseFare,
        initialBaseFare = baseFare, -- Save the initial base fare for final payment
        passengers = passengerCount,
        passengerRating = string.format("%.1f", passengerRating),
        passengerType = selectedPassengerTypeKey,
        passengerTypeName = selectedPassengerType.name,
        passengerDescription = selectedPassengerType.description
    }
    currentFare = fare
    return fare
end

local function calculateSpeedFactor()
    if not currentFare then
        return 0
    end
    local elapsedTime = os.difftime(os.time(), currentFare.startTime)
    local actualSpeed = (currentFare.totalDistance or 0) / elapsedTime

    return (actualSpeed - suggestedSpeed) / suggestedSpeed
end

-- ================================
-- JOB LIFECYCLE MANAGEMENT
-- ================================
startRide = function(fare)
    if not fare and not currentFare then
        print("No fare provided and no current fare")
        return
    end
    if not currentFare then
        currentFare = fare
    end

    currentFare.startTime = os.time()
    state = "pickup"
    M.rideData = {}
end

local function completeRide()
    if not currentFare then
        return
    end

    local elapsedTime = os.difftime(os.time(), currentFare.startTime)
    local speedFactor = calculateSpeedFactor()
    
    local passengerType = getPassengerType(currentFare.passengerType)
    if not passengerType then
        passengerType = getPassengerType("STANDARD")
    end

    fareStreak = fareStreak + 1

    -- Use the initial base fare that was calculated at job generation
    local baseFare = currentFare.initialBaseFare or calculateBaseFare(currentFare.passengers, currentFare.totalDistance, valueMultiplier, passengerType)
    
    -- Store base fare in currentFare for tip calculations
    currentFare.baseFare = string.format("%.2f", baseFare)
    
    -- Get tip breakdown from passenger type
    local tipBreakdown = {}
    if passengerType.calculateTipBreakdown then
        tipBreakdown = passengerType.calculateTipBreakdown(currentFare, elapsedTime, speedFactor, passengerType)
    else
        -- Fallback for STANDARD type
        local speedTip = speedFactor > 0 and (speedFactor * baseFare * 0.5) or 0
        tipBreakdown = speedFactor > 0 and {["Speed Bonus"] = speedTip} or {}
    end
    
    -- Calculate total tips
    local totalTips = 0
    for _, tipAmount in pairs(tipBreakdown) do
        totalTips = totalTips + tipAmount
    end
    
    local finalPayment = baseFare + totalTips

    cumulativeReward = cumulativeReward + finalPayment

    currentFare.totalTips = string.format("%.2f", totalTips)
    currentFare.tipBreakdown = tipBreakdown
    currentFare.totalFare = string.format("%.2f", finalPayment)
    
    -- Debug: Print tip breakdown for debugging
    print("Tip breakdown:", tipBreakdown)
    print("Total tips:", totalTips)
    local keyCount = 0
    for key, value in pairs(tipBreakdown) do
        keyCount = keyCount + 1
        print("  ", key, "=", value)
    end
    print("Tip breakdown keys count:", keyCount)
    currentFare.timeMultiplier = string.format("%.1f", 1 + speedFactor)
    currentFare.totalDistance = string.format("%.2f", currentFare.totalDistance / 1000)

    state = "complete"
    if not gameplay_phone.isPhoneOpen() then
        print("Phone is not open, opening phone")
        gameplay_phone.togglePhone("You completed a taxi fare! Open the phone to view your earnings.")
    end

    dataToSend = {
        state = state,
        currentFare = currentFare,
        availableSeats = availableSeats,
        vehicleMultiplier = vehicleMultiplier,
        cumulativeReward = cumulativeReward,
        fareStreak = fareStreak,
        currentPassengerType = currentFare and currentFare.passengerTypeName or nil
    }
    guihooks.trigger('updateTaxiState', dataToSend)

    local fareDescription = passengerType.getDescription(currentFare, passengerType)
    local paymentLabel = passengerType.getPaymentLabel(currentFare, speedFactor, passengerType)
    
    local label = string.format("Taxi fare: %s: $%s\nDistance: %.2fkm | %s: x %.2f", 
        fareDescription, currentFare.totalFare, currentFare.totalDistance, paymentLabel, currentFare.timeMultiplier)
    
    if not career_career or not career_career.isActive() then
        return
    end

    if career_modules_hardcore.isHardcoreMode() then
        label = label .. "\nHardcore mode is enabled, all rewards lowered."
    end

    career_modules_payment.reward({
        money = {
            amount = math.floor(finalPayment)
        },
        beamXP = {
            amount = math.floor(finalPayment / 10)
        }
    }, {
        label = label,
        tags = {"transport", "taxi"}
    }, true)
    core_groundMarkers.resetAll()
    career_modules_inventory.addTaxiDropoff(career_modules_inventory.getInventoryIdFromVehicleId(be:getPlayerVehicleID(0)), currentFare.passengers)
    core_groundMarkers.resetAll()
end

local function rejectJob()
    state = "ready"
    currentFare = nil
    core_groundMarkers.resetAll()
    fareStreak = 0
    jobOfferTimer = 0
    jobOfferInterval = math.random(5, 45)
    dataToSend = {}
end

local function stopTaxiJob()
    state = "start"
    currentFare = nil
    core_groundMarkers.resetAll()
    jobOfferTimer = 0
    jobOfferInterval = math.random(5, 45)
    cumulativeReward = 0
    fareStreak = 0
    dataToSend = {}
end

local function setAvailable()
    state = "ready"
    jobOfferTimer = 0
    jobOfferInterval = math.random(5, 45)
    dataToSend = {}
    requestTaxiState()
end

-- ================================
-- UI AND DATA MANAGEMENT
-- ================================
local function prepareTaxiJob()
    calculateCapacity(be:getPlayerVehicle(0):getID())
    local multiplier = generateValueMultiplier()
    return {
        seats = availableSeats,
        multiplier = string.format("%.1f", multiplier)
    }
end

requestTaxiState = function()
    prepareTaxiJob()
    dataToSend = {
        state = state,
        currentFare = currentFare,
        availableSeats = availableSeats,
        vehicleMultiplier = vehicleMultiplier,
        cumulativeReward = cumulativeReward,
        fareStreak = fareStreak,
        currentPassengerType = currentFare and currentFare.passengerTypeName or nil
    }
    guihooks.trigger('updateTaxiState', dataToSend)
end

local function getTaxiJob()
    prepareTaxiJob()
    if not currentFare then
        startRide(generateJob())
    end
end

-- ================================
-- UPDATE LOOP
-- ================================
local function update(_, dt)
    timer = timer + dt
    if timer < updateTimer then
        return
    end
    timer = 0

    if currentFare and state == "pickup" then
        if core_groundMarkers.getPathLength() == 0 then
            core_groundMarkers.setPath(currentFare.pickup.pos)
            local pickupDistance = core_groundMarkers.getPathLength()
            currentFare.totalDistance = pickupDistance or 0
        end

        local vehicle = be:getPlayerVehicle(0)
        local distToPickup = (vehicle:getPosition() - currentFare.pickup.pos):length()

        if distToPickup < 5 then
            state = "dropoff"
            core_groundMarkers.setPath(currentFare.destination.pos)
            local dropoffDistance = core_groundMarkers.getPathLength()
            currentFare.startTime = os.time()
            currentFare.totalDistance = currentFare.totalDistance + dropoffDistance
            M.rideData = {}
            dataToSend = {
                state = state,
                currentFare = currentFare,
                availableSeats = availableSeats,
                vehicleMultiplier = vehicleMultiplier,
                cumulativeReward = cumulativeReward,
                fareStreak = fareStreak,
                currentPassengerType = currentFare and currentFare.passengerTypeName or nil
            }
            guihooks.trigger('updateTaxiState', dataToSend)
        end
    end

    if currentFare and state == "dropoff" then
        updateSensorData()
        
        local vehicle = be:getPlayerVehicle(0)
        local vehiclePos = vehicle:getPosition()
        local destDist = (vehiclePos - currentFare.destination.pos):length()

        if destDist < 5 then
            completeRide()
        end
    end

    if state == "ready" then
        jobOfferTimer = jobOfferTimer + 1
        if jobOfferTimer >= jobOfferInterval then
            state = "accept"
            local newFare = generateJob()
            if not gameplay_phone.isPhoneOpen() then
                print("Phone is not open, opening phone")
                gameplay_phone.togglePhone("You have a new taxi fare! Open the phone to view the details.")
            end
            dataToSend = {
                state = state,
                currentFare = newFare,
                availableSeats = availableSeats,
                vehicleMultiplier = vehicleMultiplier,
                cumulativeReward = cumulativeReward,
                fareStreak = fareStreak,
                currentPassengerType = newFare and newFare.passengerTypeName or nil
            }
            guihooks.trigger('updateTaxiState', dataToSend)

            jobOfferTimer = 0
            jobOfferInterval = math.random(5, 45)
        end
    end
end

-- ================================
-- EVENT HANDLERS
-- ================================
local function onEnterVehicleFinished()
    validPickupSpots = findParkingSpots()
end

local function onVehicleSwitched()
    currentVehiclePartsTree = nil
    -- Reset taxi job state when switching vehicles
    state = "start"
    currentFare = nil
    core_groundMarkers.resetAll()
    jobOfferTimer = 0
    jobOfferInterval = math.random(5, 45)
    cumulativeReward = 0
    fareStreak = 0
    
    -- Reset vehicle-specific values
    availableSeats = 0
    vehicleMultiplier = 0.1
    
    -- If there's a player vehicle, recalculate capacity and multiplier
    if be:getPlayerVehicle(0) and not gameplay_walk.isWalking() then
        calculateCapacity(be:getPlayerVehicle(0):getID())
        generateValueMultiplier()
    end
    
    dataToSend = {
        state = state,
        currentFare = currentFare,
        availableSeats = availableSeats,
        vehicleMultiplier = vehicleMultiplier,
        cumulativeReward = cumulativeReward,
        fareStreak = fareStreak
    }
    guihooks.trigger('updateTaxiState', dataToSend)
end

local function returnPartsTree(partsTree)
    currentVehiclePartsTree = partsTree
    calculateCapacity()
end

local function receiveSensorData(gx, gy, gz, gx2, gy2, gz2)
    processSensorData(gx, gy, gz, gx2, gy2, gz2)
end

-- ================================
-- MODULE LOADING SYSTEM
-- ================================
local function loadPassengerModules()
    print("Initializing Taxi Passenger Modules")
    
    local passengersPath = "/lua/ge/extensions/gameplay/taxiPassengers/"
    local files = FS:findFiles(passengersPath, "*.lua", -1, true, false)
    
    if files then
        for _, filePath in ipairs(files) do
            local filename = string.match(filePath, "([^/]+)%.lua$")
            
            if filename then
                local extensionName = "gameplay_taxiPassengers_" .. filename
                extensions.unload(extensionName)
                setExtensionUnloadMode(extensionName, "manual")
                print("Loaded taxi passenger module: " .. extensionName)
            end
        end
    end
    loadManualUnloadExtensions()
end

local function onExtensionLoaded()
    print("Taxi module loaded, initializing passenger types...")
    loadPassengerModules()
end

local function isTaxiJobActive()
    return state ~= "start"
end

-- ================================
-- MODULE EXPORTS
-- ================================
M.onExtensionLoaded = onExtensionLoaded
M.onEnterVehicleFinished = onEnterVehicleFinished
M.onUpdate = update
M.onVehicleSwitched = onVehicleSwitched

M.acceptJob = startRide
M.rejectJob = rejectJob
M.setAvailable = setAvailable
M.stopTaxiJob = stopTaxiJob
M.generateJob = generateJob
M.getTaxiJob = getTaxiJob
M.prepareTaxiJob = prepareTaxiJob
M.requestTaxiState = requestTaxiState
M.isTaxiJobActive = isTaxiJobActive

M.registerPassengerType = registerPassengerType
M.getPassengerTypes = getPassengerTypes
M.getCurrentPassengerType = getCurrentPassengerType
M.selectRandomPassengerType = selectRandomPassengerType
M.getPassengerType = getPassengerType

M.updateSensorData = updateSensorData
M.returnPartsTree = returnPartsTree
M.receiveSensorData = receiveSensorData

return M
