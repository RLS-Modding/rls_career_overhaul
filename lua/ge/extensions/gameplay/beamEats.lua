local M = {}
M.dependencies = {'gameplay_sites_sitesManager', 'freeroam_facilities', 'gameplay_walk'}

-- ================================
-- MODULE DEPENDENCIES
-- ================================
local core_groundMarkers = require('core/groundMarkers')

-- ================================
-- STATE VARIABLES
-- ================================
local dataToSend = {}
local cumulativeReward = 0
local orderStreak = 0
local currentOrder = nil
local state = "start"
local timer = 0
local updateTimer = 1
local jobOfferTimer = 0
local jobOfferInterval = math.random(5, 45)

local vehicleMultiplier = 0.1

-- Restaurant and parking spot data
local restaurants = {}
local restaurantIds = {"turboBurger", "diner", "chinatownRestaurant", "greenPier"}
local allDeliverySpots = nil

local distanceMultiplier = 4.5
local suggestedSpeed = 18 -- m/s, similar to taxi

M.deliveryData = {}

-- ================================
-- FORWARD DECLARATIONS
-- ================================
local requestBeamEatsState
local startDelivery

-- ================================
-- SENSOR DATA HANDLING
-- ================================
local function updateSensorData()
    if not currentOrder or state ~= "dropoff" then
        return
    end
    
    local vehicle = be:getPlayerVehicle(0)
    if not vehicle then return end
    
    vehicle:queueLuaCommand([[
        local sensors = require('sensors')
        if sensors then
            local gx, gy, gz = sensors.gx or 0, sensors.gy or 0, sensors.gz or 0
            local gx2, gy2, gz2 = sensors.gx2 or 0, sensors.gy2 or 0, sensors.gz2 or 0
            obj:queueGameEngineLua('gameplay_beamEats.receiveSensorData('..gx..','..gy..','..gz..','..gx2..','..gy2..','..gz2..')')
        end
    ]])
end

local function processSensorData(gx, gy, gz, gx2, gy2, gz2)
    local grav = 9.81 -- Convert to G-force
    M.deliveryData.currentSensorData = {
        gx = gx / grav, gy = gy / grav, gz = gz / grav,
        gx2 = gx2 / grav, gy2 = gy2 / grav, gz2 = gz2 / grav,
        timestamp = os.time()
    }
    
    -- Track rough driving events
    if not M.deliveryData.roughEvents then
        M.deliveryData.roughEvents = 0
    end
    
    local peak = math.max(math.abs(gx2 / grav), math.abs(gy2 / grav), math.abs(gz2 / grav))
    if peak > 0.6 then
        M.deliveryData.roughEvents = M.deliveryData.roughEvents + 1
    end
end

-- ================================
-- RESTAURANT AND LOCATION MANAGEMENT
-- ================================
local function findRestaurants()
    restaurants = {}
    local facilities = freeroam_facilities.getFacilitiesByType("deliveryProvider")
    
    if not facilities then
        return
    end
    
    local restaurantParkingSpotNames = {}
    
    for _, fac in ipairs(facilities) do
        local isRestaurant = false
        for _, restaurantId in ipairs(restaurantIds) do
            if fac.id == restaurantId then
                isRestaurant = true
                break
            end
        end
        
        if isRestaurant then
            local pickupSpots = {}
            if fac.manualAccessPoints then
                for _, accessPoint in ipairs(fac.manualAccessPoints) do
                    if accessPoint.logisticTypesProvided then
                        for _, logisticType in ipairs(accessPoint.logisticTypesProvided) do
                            if logisticType == "food" then
                                table.insert(restaurantParkingSpotNames, accessPoint.psName)
                                
                                local sitesFile = fac.sitesFile
                                if sitesFile then
                                    local siteData = gameplay_sites_sitesManager.loadSites(sitesFile)
                                    if siteData and siteData.parkingSpots then
                                        local ps = siteData.parkingSpots.byName[accessPoint.psName]
                                        if ps and ps.pos then
                                            table.insert(pickupSpots, {
                                                pos = ps.pos,
                                                name = accessPoint.psName,
                                                restaurantId = fac.id,
                                                restaurantName = fac.name
                                            })
                                        end
                                    end
                                end
                                break
                            end
                        end
                    end
                end
            end
            
            if #pickupSpots > 0 then
                table.insert(restaurants, {
                    id = fac.id,
                    name = fac.name,
                    pickupSpots = pickupSpots
                })
            end
        end
    end
    
    M.restaurantParkingSpotNames = restaurantParkingSpotNames
end

local function findAllDeliveryParkingSpots()
    local allSitesFiles = gameplay_sites_sitesManager.getCurrentLevelSitesFiles()
    if not allSitesFiles then
        local sitePath = gameplay_sites_sitesManager.getCurrentLevelSitesFileByName('city')
        if sitePath then
            allSitesFiles = {sitePath}
        else
            return
        end
    end
    
    local allParkingSpots = {}
    local restaurantSpotNames = M.restaurantParkingSpotNames or {}
    local restaurantSpotsLookup = {}
    for _, spotName in ipairs(restaurantSpotNames) do
        restaurantSpotsLookup[spotName] = true
    end
    
    for _, sitesFilePath in ipairs(allSitesFiles) do
        if not string.find(sitesFilePath, "restaurants") then
            local siteData = gameplay_sites_sitesManager.loadSites(sitesFilePath, true, true)
            if siteData and siteData.parkingSpots and siteData.parkingSpots.objects then
                for _, spot in pairs(siteData.parkingSpots.objects) do
                    if spot.name and not restaurantSpotsLookup[spot.name] then
                        if spot.pos then
                            table.insert(allParkingSpots, spot)
                        end
                    end
                end
            end
        end
    end
    
    allDeliverySpots = {
        objects = allParkingSpots
    }
end

-- ================================
-- DISABLED STATE CHECK
-- ================================
local function isBeamEatsDisabled()
    local disabled = false
    local reason = ""

    if gameplay_walk and gameplay_walk.isWalking() then
        disabled = true
        reason = "BeamEats is not available while walking"
        return disabled, reason
    end

    if career_economyAdjuster then
        local beamEatsMultiplier = career_economyAdjuster.getSectionMultiplier("beamEats") or 1.0
        if beamEatsMultiplier == 0 then
            disabled = true
            reason = "BeamEats multiplier is set to 0"
        end
    end

    return disabled, reason
end

-- ================================
-- VALUE AND PAYMENT CALCULATIONS
-- ================================
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

local function calculateDrivingDistance(startPos, endPos)
    local startRoad, _, startDist = map.findClosestRoad(startPos)
    local endRoad, _, endDist = map.findClosestRoad(endPos)
    
    if not startRoad or not endRoad then
        return startPos:distance(endPos)
    end
    
    local path = map.getPath(startRoad, endRoad)
    if not path or #path == 0 then
        return startPos:distance(endPos)
    end
    
    local totalDistance = 0
    local prevNodePos = startPos
    
    for i = 1, #path do
        local nodePos = map.getMap().nodes[path[i]].pos
        if nodePos then
            totalDistance = totalDistance + prevNodePos:distance(nodePos)
            prevNodePos = nodePos
        end
    end
    
    totalDistance = totalDistance + prevNodePos:distance(endPos)
    
    return totalDistance
end

local function calculateBaseFare(totalDistance, orderValueMultiplier)
    local baseFare = 100 * orderValueMultiplier * distanceMultiplier
    baseFare = baseFare * (totalDistance / 1000)

    if career_career and career_career.isActive() and career_modules_hardcore.isHardcoreMode() then
        baseFare = baseFare * 0.66
    end

    if career_economyAdjuster then
        local multiplier = career_economyAdjuster.getSectionMultiplier("beamEats") or 1.0
        baseFare = baseFare * multiplier
        baseFare = math.floor(baseFare + 0.5)
    end

    return baseFare
end

local function calculateTimeFactor()
    if not currentOrder or not currentOrder.startTime then
        return 0
    end
    
    local elapsedTime = timer - currentOrder.startTime
    local expectedTime = currentOrder.expectedTime or 300
    local speedFactor = (expectedTime - elapsedTime) / expectedTime
    
    return math.max(-1.0, math.min(1.0, speedFactor))
end

local function calculateSmoothDrivingTip(baseFare, roughEvents)
    if roughEvents == 0 then
        return baseFare * 0.2
    elseif roughEvents <= 2 then
        return baseFare * 0.1
    else
        return 0
    end
end

-- ================================
-- ORDER GENERATION
-- ================================
local function generateOrder()
    local beamEatsDisabled, disabledReason = isBeamEatsDisabled()
    if beamEatsDisabled then
        return nil
    end

    if #restaurants == 0 then
        return nil
    end

    if not allDeliverySpots or not allDeliverySpots.objects or #allDeliverySpots.objects == 0 then
        return nil
    end

    local restaurant = restaurants[math.random(#restaurants)]
    local pickupSpot = restaurant.pickupSpots[math.random(#restaurant.pickupSpots)]
    
    local deliverySpots = {}
    local minDistance = 600
    for _, spot in pairs(allDeliverySpots.objects) do
        if spot.pos and pickupSpot.pos:distance(spot.pos) >= minDistance then
            table.insert(deliverySpots, spot)
        end
    end

    if #deliverySpots == 0 then
        return nil
    end

    local deliverySpot = deliverySpots[math.random(#deliverySpots)]

    local valueMultiplier = generateValueMultiplier()
    local totalDistance = calculateDrivingDistance(pickupSpot.pos, deliverySpot.pos)
    local baseFare = calculateBaseFare(totalDistance, valueMultiplier)
    
    local expectedTime = (totalDistance / suggestedSpeed) + 60
    local orderValue = 1.0 + (math.random() * 0.5)

    local order = {
        restaurant = restaurant.name,
        restaurantId = restaurant.id,
        pickup = {
            pos = pickupSpot.pos,
            name = pickupSpot.name
        },
        destination = {
            pos = deliverySpot.pos,
            name = deliverySpot.name or "Delivery Location"
        },
        baseFare = baseFare,
        totalDistance = totalDistance,
        expectedTime = expectedTime,
        orderValue = orderValue,
        startTime = nil
    }

    return order
end

-- ================================
-- DELIVERY COMPLETION
-- ================================
local function completeDelivery()
    if not currentOrder then
        return
    end

    local elapsedTime = timer - currentOrder.startTime
    local speedFactor = calculateTimeFactor()
    local roughEvents = M.deliveryData.roughEvents or 0
    
    local baseFare = currentOrder.baseFare
    local smoothDrivingTip = calculateSmoothDrivingTip(baseFare, roughEvents)
    local timeBonus = speedFactor > 0 and (speedFactor * baseFare * 0.3) or 0
    local timePenalty = speedFactor < 0 and (math.abs(speedFactor) * baseFare * 0.2) or 0
    
    local finalPayment = baseFare + smoothDrivingTip + timeBonus - timePenalty
    cumulativeReward = cumulativeReward + finalPayment
    orderStreak = orderStreak + 1

    currentOrder.totalPayment = string.format("%.2f", finalPayment)
    currentOrder.baseFare = string.format("%.2f", baseFare)
    currentOrder.smoothDrivingTip = string.format("%.2f", smoothDrivingTip)
    currentOrder.timeBonus = string.format("%.2f", timeBonus)
    currentOrder.timePenalty = string.format("%.2f", timePenalty)
    currentOrder.totalDistance = string.format("%.2f", currentOrder.totalDistance / 1000)
    currentOrder.roughEvents = roughEvents

    state = "complete"
    if not gameplay_phone.isPhoneOpen() then
        gameplay_phone.togglePhone("You completed a delivery! Open the phone to view your earnings.")
    end

    local beamEatsDisabled, disabledReason = isBeamEatsDisabled()
    local effectiveState = beamEatsDisabled and "disabled" or state

    dataToSend = {
        state = effectiveState,
        currentOrder = currentOrder,
        vehicleMultiplier = vehicleMultiplier,
        cumulativeReward = cumulativeReward,
        orderStreak = orderStreak,
        beamEatsDisabled = beamEatsDisabled,
        disabledReason = disabledReason
    }
    guihooks.trigger('updateBeamEatsState', dataToSend)

    local label = string.format("BeamEats delivery: $%s\nDistance: %skm | Tip: $%s", 
        currentOrder.totalPayment, currentOrder.totalDistance, currentOrder.smoothDrivingTip)
    
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
        tags = {"transport", "beamEats"}
    }, true)
    
    core_groundMarkers.resetAll()
    M.deliveryData = {}
end

-- ================================
-- ORDER MANAGEMENT
-- ================================
local function rejectOrder()
    state = "ready"
    currentOrder = nil
    jobOfferTimer = 0
    jobOfferInterval = math.random(5, 45)
    requestBeamEatsState()
end

local function stopBeamEatsJob()
    state = "start"
    if currentOrder then
        core_groundMarkers.resetAll()
    end
    currentOrder = nil
    jobOfferTimer = 0
    jobOfferInterval = math.random(5, 45)
    cumulativeReward = 0
    orderStreak = 0
    M.deliveryData = {}
    requestBeamEatsState()
end

local function setAvailable()
    state = "ready"
    requestBeamEatsState()
end

local function prepareBeamEatsJob()
    if not currentOrder then
        return
    end

    local vehicle = be:getPlayerVehicle(0)
    if not vehicle then
        return
    end

    local vehiclePos = vehicle:getPosition()
    local pickupDist = (vehiclePos - currentOrder.pickup.pos):length()

    if pickupDist < 5 then
        state = "dropoff"
        currentOrder.startTime = timer
        M.deliveryData = {roughEvents = 0}
        core_groundMarkers.setPath(currentOrder.destination.pos)
        
        local beamEatsDisabled, disabledReason = isBeamEatsDisabled()
        local effectiveState = beamEatsDisabled and "disabled" or state

        dataToSend = {
            state = effectiveState,
            currentOrder = currentOrder,
            vehicleMultiplier = vehicleMultiplier,
            cumulativeReward = cumulativeReward,
            orderStreak = orderStreak,
            beamEatsDisabled = beamEatsDisabled,
            disabledReason = disabledReason
        }
        guihooks.trigger('updateBeamEatsState', dataToSend)
    end
end

-- ================================
-- MAIN UPDATE LOOP
-- ================================
local function update(_, dt)
    timer = timer + dt
    updateTimer = updateTimer + dt

    if updateTimer >= 1 then
        updateTimer = 0
        requestBeamEatsState()
    end

    if currentOrder and state == "pickup" then
        prepareBeamEatsJob()
    end

    if currentOrder and state == "dropoff" then
        updateSensorData()
        
        local vehicle = be:getPlayerVehicle(0)
        local vehiclePos = vehicle:getPosition()
        local destDist = (vehiclePos - currentOrder.destination.pos):length()

        if destDist < 5 then
            completeDelivery()
        end
    end

    if state == "ready" then
        local beamEatsDisabled, disabledReason = isBeamEatsDisabled()
        if beamEatsDisabled then
            state = "start"
            requestBeamEatsState()
            return
        end

        jobOfferTimer = jobOfferTimer + 1
        if jobOfferTimer >= jobOfferInterval then
            local newOrder = generateOrder()
            if newOrder then
                state = "accept"
                if not gameplay_phone.isPhoneOpen() then
                    gameplay_phone.togglePhone("You have a new delivery order! Open the phone to view the details.")
                end
            else
                jobOfferTimer = 0
                jobOfferInterval = math.random(5, 45)
            end

            if newOrder then
                local beamEatsDisabled, disabledReason = isBeamEatsDisabled()
                local effectiveState = beamEatsDisabled and "disabled" or state

                dataToSend = {
                    state = effectiveState,
                    currentOrder = newOrder,
                    vehicleMultiplier = vehicleMultiplier,
                    cumulativeReward = cumulativeReward,
                    orderStreak = orderStreak,
                    beamEatsDisabled = beamEatsDisabled,
                    disabledReason = disabledReason
                }
                guihooks.trigger('updateBeamEatsState', dataToSend)
            end
        end
    end
end

-- ================================
-- STATE REQUEST
-- ================================
function requestBeamEatsState()
    local beamEatsDisabled, disabledReason = isBeamEatsDisabled()
    local effectiveState = beamEatsDisabled and "disabled" or state

    dataToSend = {
        state = effectiveState,
        currentOrder = currentOrder,
        vehicleMultiplier = vehicleMultiplier,
        cumulativeReward = cumulativeReward,
        orderStreak = orderStreak,
        beamEatsDisabled = beamEatsDisabled,
        disabledReason = disabledReason
    }
    guihooks.trigger('updateBeamEatsState', dataToSend)
end

-- ================================
-- DELIVERY START
-- ================================
function startDelivery(order)
    if not order then
        order = currentOrder
    end
    
    if not order then
        return
    end

    state = "pickup"
    currentOrder = order
    core_groundMarkers.setPath(order.pickup.pos)
    
    local beamEatsDisabled, disabledReason = isBeamEatsDisabled()
    local effectiveState = beamEatsDisabled and "disabled" or state

    dataToSend = {
        state = effectiveState,
        currentOrder = currentOrder,
        vehicleMultiplier = vehicleMultiplier,
        cumulativeReward = cumulativeReward,
        orderStreak = orderStreak,
        beamEatsDisabled = beamEatsDisabled,
        disabledReason = disabledReason
    }
    guihooks.trigger('updateBeamEatsState', dataToSend)
end

-- ================================
-- EVENT HANDLERS
-- ================================
local function onEnterVehicleFinished()
    findRestaurants()
    findAllDeliveryParkingSpots()
end

local function onVehicleSwitched()
    state = "start"
    if currentOrder then
        core_groundMarkers.resetAll()
    end
    currentOrder = nil
    jobOfferTimer = 0
    jobOfferInterval = math.random(5, 45)
    cumulativeReward = 0
    orderStreak = 0
    
    vehicleMultiplier = 0.1
    
    if be:getPlayerVehicle(0) and not gameplay_walk.isWalking() then
        generateValueMultiplier()
    end
    
    local beamEatsDisabled, disabledReason = isBeamEatsDisabled()
    local effectiveState = beamEatsDisabled and "disabled" or state

    dataToSend = {
        state = effectiveState,
        currentOrder = currentOrder,
        vehicleMultiplier = vehicleMultiplier,
        cumulativeReward = cumulativeReward,
        orderStreak = orderStreak,
        beamEatsDisabled = beamEatsDisabled,
        disabledReason = disabledReason
    }
    guihooks.trigger('updateBeamEatsState', dataToSend)
end

local function receiveSensorData(gx, gy, gz, gx2, gy2, gz2)
    processSensorData(gx, gy, gz, gx2, gy2, gz2)
end

-- ================================
-- MODULE LOADING
-- ================================
local function onExtensionLoaded()
    print("BeamEats module loaded")
end

local function isBeamEatsJobActive()
    return state ~= "start" and state ~= "disabled"
end

-- ================================
-- MODULE EXPORTS
-- ================================
M.onExtensionLoaded = onExtensionLoaded
M.onEnterVehicleFinished = onEnterVehicleFinished
M.onUpdate = update
M.onVehicleSwitched = onVehicleSwitched

M.acceptOrder = startDelivery
M.rejectOrder = rejectOrder
M.setAvailable = setAvailable
M.stopBeamEatsJob = stopBeamEatsJob
M.generateOrder = generateOrder
M.requestBeamEatsState = requestBeamEatsState
M.isBeamEatsJobActive = isBeamEatsJobActive

M.receiveSensorData = receiveSensorData

return M
