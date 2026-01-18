local M = {}
M.dependencies = {'gameplay_sites_sitesManager', 'freeroam_facilities', 'gameplay_walk', 'gameplay_phone'}

M.config = {
    -- Driving smoothness
    roughEventThreshold = 1.6, 
    tipTiers = {
        { maxEvents = 0, percent = .75 },
        { maxEvents = 5, percent = 0.10 }
        
    },

    secondsPerMile = 80, 

    bonusPerSecondEarly = 100,
    penaltyPerSecondLate = 20,
    
    distanceMultiplier = 4.5,
    baseFareScale = 100,
    
    vehicleMultiplierMin = 0.1,
}

local config = M.config

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
local dwellTimer = 0
local dwellDuration = 3.0 

local updateTimer = 1
local uiUpdateTimer = 0
local jobOfferTimer = 0

local jobOfferInterval = math.random(5, 45)

local vehicleMultiplier = 0.1

-- Restaurant and parking spot data
local restaurants = {}
-- local restaurantIds = {"turboBurger", "diner", "chinatownRestaurant", "greenPier"} -- Removed hardcoded list
local allDeliverySpots = nil

local distanceMultiplier = config.distanceMultiplier
local suggestedSpeed = 18 
M.deliveryData = {}

-- ================================
-- FORWARD DECLARATIONS
-- ================================
local requestBeamEatsState
local startDelivery

-- ================================
-- SENSOR DATA HANDLING
-- Requests and forwards vehicle sensor readings while an active delivery is in the "dropoff" state.
-- If there is no current order, the state is not "dropoff", or the player is not in a vehicle, the function does nothing.
-- Queues a vehicle-side Lua command to read sensor values and deliver them to gameplay_beamEats.receiveSensorData.
local function updateSensorData()
    if not currentOrder or state ~= "dropoff" then
        return
    end

    local vehicle = be:getPlayerVehicle(0)
    if not vehicle then
        return
    end

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
    local grav = 9.81 
    M.deliveryData.currentSensorData = {
        gx = gx / grav,
        gy = gy / grav,
        gz = gz / grav,
        gx2 = gx2 / grav,
        gy2 = gy2 / grav,
        gz2 = gz2 / grav,
        timestamp = os.time()
    }

    if not M.deliveryData.roughEvents then
        M.deliveryData.roughEvents = 0
    end
    if not M.deliveryData.isRoughEventActive then
        M.deliveryData.isRoughEventActive = false
    end

    local peak = math.max(math.abs(gx2 / grav), math.abs(gy2 / grav), math.abs(gz2 / grav))
    
    if M.deliveryData.isRoughEventActive then
        if peak < (config.roughEventThreshold * 0.8) then
            M.deliveryData.isRoughEventActive = false
        end
    else
        if peak > config.roughEventThreshold then
            M.deliveryData.roughEvents = M.deliveryData.roughEvents + 1
            M.deliveryData.isRoughEventActive = true
        end
    end
end

-- ================================
-- RESTAURANT AND LOCATION MANAGEMENT
-- Scans game facilities for configured restaurant delivery providers and builds the module's restaurant pickup data.
-- Populates the local `restaurants` table with entries `{ id, name, pickupSpots }`, where each `pickupSpots` entry contains `pos`, `name`, `restaurantId`, and `restaurantName`.
-- Also sets `M.restaurantParkingSpotNames` to a list of discovered pickup spot names.
local function findRestaurants()
    restaurants = {}
    local facilities = freeroam_facilities.getFacilitiesByType("deliveryProvider")

    if not facilities then
        return
    end

    local restaurantParkingSpotNames = {}

    for _, fac in ipairs(facilities) do
        -- Check if facility provides food delivery, regardless of ID
        local isRestaurant = false
        if fac.manualAccessPoints then
            for _, accessPoint in ipairs(fac.manualAccessPoints) do
                if accessPoint.logisticTypesProvided then
                    for _, logisticType in ipairs(accessPoint.logisticTypesProvided) do
                        if logisticType == "food" then
                            isRestaurant = true
                            break
                        end
                    end
                end
                if isRestaurant then break end
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
                                        -- Check if byName exists before accessing
                                        if siteData.parkingSpots.byName then
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

-- Scans level site files and populates `allDeliverySpots` with delivery parking spots available for deliveries.
-- Filters out parking spots that belong to restaurant pickup spots, excludes site files whose path contains "restaurants", and ignores spots missing a position.
-- Uses the current level sites files from `gameplay_sites_sitesManager`, falling back to the level "city" sites file if necessary.
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
local function generateValueMultiplier()
    if not career_career or not career_career.isActive() then
        return 1
    end
    local playerVehicle = be:getPlayerVehicle(0)
    if not playerVehicle then
        return 0.1
    end
    if not career_modules_inventory or not career_modules_inventory.getInventoryIdFromVehicleId then
        return 0.1
    end
    local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(playerVehicle:getID())
    if not inventoryId then
        return 0
    end
    if not career_modules_valueCalculator or not career_modules_valueCalculator.getInventoryVehicleValue then
        return 0.1
    end
    vehicleMultiplier = (career_modules_valueCalculator.getInventoryVehicleValue(inventoryId) / 30000) ^ 0.5
    vehicleMultiplier = math.max(vehicleMultiplier, 0.1)
    return vehicleMultiplier
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
    local baseFare = config.baseFareScale * orderValueMultiplier * config.distanceMultiplier
    baseFare = baseFare * (totalDistance / 1000)

    if career_career and career_career.isActive() and career_modules_hardcore and career_modules_hardcore.isHardcoreMode and
        career_modules_hardcore.isHardcoreMode() then
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
    for _, tier in ipairs(config.tipTiers) do
        if roughEvents <= tier.maxEvents then
            return baseFare * tier.percent
        end
    end
    return 0
end

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

    local vehicle = be:getPlayerVehicle(0)
    if not vehicle then
        return nil
    end

    local vehiclePos = vehicle:getPosition()

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
    
    -- Calculate distances
    local distToPickup = calculateDrivingDistance(vehiclePos, pickupSpot.pos)
    local distDelivery = calculateDrivingDistance(pickupSpot.pos, deliverySpot.pos)
    local totalDistance = distToPickup + distDelivery -- Total trip distance

    local baseFare = calculateBaseFare(totalDistance, valueMultiplier)

    -- Calculate expected time: config.secondsPerMile per mile (based on total distance)
    local metersToMiles = 0.000621371
    local miles = totalDistance * metersToMiles
    local expectedTime = miles * config.secondsPerMile
    expectedTime = math.max(expectedTime, 60) -- Minimum 60 seconds for the whole trip

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
        startTime = nil
    }

    return order
end

-- ================================
-- DELIVERY COMPLETION
local function completeDelivery()
    if not currentOrder then
        return
    end

    local elapsedTime = timer - currentOrder.startTime
    local expectedTime = currentOrder.expectedTime
    local timeDiff = expectedTime - elapsedTime -- Positive = Early, Negative = Late

    local roughEvents = M.deliveryData.roughEvents or 0
    local baseFare = currentOrder.baseFare
    local smoothDrivingTip = calculateSmoothDrivingTip(baseFare, roughEvents)
    
    local timeBonus = 0
    local timePenalty = 0

    if timeDiff > 0 then
        timeBonus = timeDiff * config.bonusPerSecondEarly
    else
        timePenalty = math.abs(timeDiff) * config.penaltyPerSecondLate
    end

    local finalPayment = math.max(0, baseFare + smoothDrivingTip + timeBonus - timePenalty)
    cumulativeReward = cumulativeReward + finalPayment
    orderStreak = orderStreak + 1

    currentOrder.totalPayment = finalPayment
    currentOrder.smoothDrivingTip = smoothDrivingTip
    currentOrder.timeBonus = timeBonus
    currentOrder.timePenalty = timePenalty
    currentOrder.roughEvents = roughEvents

    -- Display fields (string-formatted for UI)
    currentOrder.totalPaymentDisplay = string.format("%.2f", finalPayment)
    currentOrder.baseFareDisplay = string.format("%.2f", baseFare)
    currentOrder.smoothDrivingTipDisplay = string.format("%.2f", smoothDrivingTip)
    currentOrder.timeBonusDisplay = string.format("%.2f", timeBonus)
    currentOrder.timePenaltyDisplay = string.format("%.2f", timePenalty)
    currentOrder.totalDistanceDisplay = string.format("%.2f", currentOrder.totalDistance / 1000)

    state = "ready" -- Loop missions: Go back to ready state immediately
    jobOfferTimer = 0 -- Reset offer timer to start looking for new orders soon
    jobOfferInterval = math.random(5, 10) -- Quick turnaround for next offer

    -- if gameplay_phone and not gameplay_phone.isPhoneOpen() then
    --     gameplay_phone.togglePhone("You completed a delivery! Open the phone to view your earnings.")
    -- end

    local msg = string.format("Delivery Complete!\n\nPAYMENT BREAKDOWN:\nBase Fare: $%s\nTip (Smoothness): +$%s\nTime Bonus: +$%s\nTime Penalty: -$%s\n\nTOTAL: $%s", 
        currentOrder.baseFareDisplay, 
        currentOrder.smoothDrivingTipDisplay,
        currentOrder.timeBonusDisplay,
        currentOrder.timePenaltyDisplay,
        currentOrder.totalPaymentDisplay)
    
    if currentOrder.roughEvents > 0 then
        msg = msg .. string.format("\n\n(Rough driving events detected: %d)", currentOrder.roughEvents)
    end
    
    if timeBonus > 0 then
        msg = msg .. string.format("\n(Arrived %0.1fs early!)", math.abs(timeDiff))
    elseif timePenalty > 0 then
        msg = msg .. string.format("\n(Arrived %0.1fs late!)", math.abs(timeDiff))
    end

    guihooks.trigger('toastrMsg', {type="success", title="BeamEats Earnings", msg=msg, config={time=15000}})

    -- Clear Tasklist
    guihooks.trigger('ClearTasklist')

    local beamEatsDisabled, disabledReason = isBeamEatsDisabled()
    local effectiveState = beamEatsDisabled and "disabled" or state

    dataToSend = {
        state = effectiveState,
        currentOrder = currentOrder,
        vehicleMultiplier = string.format("%.1f", vehicleMultiplier),
        cumulativeReward = cumulativeReward,
        orderStreak = orderStreak,
        beamEatsDisabled = beamEatsDisabled,
        disabledReason = disabledReason
    }
    guihooks.trigger('updateBeamEatsState', dataToSend)

    local label = string.format("BeamEats delivery: $%s\nDistance: %skm | Tip: $%s", currentOrder.totalPaymentDisplay,
        currentOrder.totalDistanceDisplay, currentOrder.smoothDrivingTipDisplay)

    if not career_career or not career_career.isActive() then
        return
    end

    if career_modules_hardcore and career_modules_hardcore.isHardcoreMode and career_modules_hardcore.isHardcoreMode() then
        label = label .. "\nHardcore mode is enabled, all rewards lowered."
    end

    if career_modules_payment and type(career_modules_payment.reward) == "function" then
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
    else
        log('W', 'beamEats', 'career_modules_payment not available, skipping reward')
    end
    core_groundMarkers.resetAll()
    M.deliveryData = {}
end

-- ================================
-- ORDER MANAGEMENT
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
    guihooks.trigger('ClearTasklist') -- Clear UI on stop
    requestBeamEatsState()
end

local function setAvailable()
    state = "ready"
    requestBeamEatsState()
end

local function prepareBeamEatsJob(dt)
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
        -- Check if vehicle is stopped
        if vehicle:getVelocity():length() < 0.1 then
            dwellTimer = dwellTimer + dt
            if dwellTimer < dwellDuration then
                ui_message(string.format("Picking up order... %0.1fs", dwellDuration - dwellTimer), 0.1, 'beamEats_dwell', 'timer')
                return
            end
        else
            dwellTimer = 0
            ui_message("Stop to pick up order", 1, 'beamEats_dwell', 'info')
            return
        end
        
        dwellTimer = 0
        state = "dropoff"
        -- currentOrder.startTime is NOT reset here, it continues from acceptance
        
        -- Reset sensor data strictly on pickup
        M.deliveryData = {
            roughEvents = 0
        }
        core_groundMarkers.setPath(currentOrder.destination.pos)
        
        ui_message("Order picked up! Drive carefully!", 3, 'beamEats_main', 'check')

        local beamEatsDisabled, disabledReason = isBeamEatsDisabled()
        local effectiveState = beamEatsDisabled and "disabled" or state

        dataToSend = {
            state = effectiveState,
            currentOrder = currentOrder,
            vehicleMultiplier = string.format("%.1f", vehicleMultiplier),
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
local updateInterval = 1.0
local function update(_, dt)
    timer = timer + dt
    updateTimer = updateTimer + dt
    uiUpdateTimer = uiUpdateTimer + dt

    if updateTimer >= updateInterval then
        updateTimer = 0
        requestBeamEatsState()
    end

    if currentOrder and (state == "pickup" or state == "dropoff") then
        if state == "pickup" then
            prepareBeamEatsJob(dt)
        elseif state == "dropoff" then
            updateSensorData()
            local vehicle = be:getPlayerVehicle(0)
            if vehicle then
                local vehiclePos = vehicle:getPosition()
                local destDist = (vehiclePos - currentOrder.destination.pos):length()

                if destDist < 5 then
                    -- Check if vehicle is stopped
                    if vehicle:getVelocity():length() < 0.1 then
                        dwellTimer = dwellTimer + dt
                        if dwellTimer < dwellDuration then
                            ui_message(string.format("Dropping off order... %0.1fs", dwellDuration - dwellTimer), 0.1, 'beamEats_dwell', 'timer')
                        else
                            dwellTimer = 0
                            completeDelivery()
                        end
                    else
                        dwellTimer = 0
                        ui_message("Stop to drop off order", 0.1, 'beamEats_dwell', 'info')
                    end
                else
                    dwellTimer = 0 -- Reset if they drive away
                end
            end
        end

        -- Persistent UI: Tasklist Update (throttled)
        if uiUpdateTimer >= 0.5 then -- Faster update rate for smoother timer
            uiUpdateTimer = 0
            local elapsedTime = timer - currentOrder.startTime
            local timeLeft = math.max(0, currentOrder.expectedTime - elapsedTime)
            local timeDiff = currentOrder.expectedTime - elapsedTime 
            local totalTime = currentOrder.expectedTime
            
            local phaseLabel = (state == "pickup") and "Pickup at: " .. currentOrder.restaurant or "Deliver to: Customer"
            
            -- Progress bar logic: Full at start, empty at 0
            local progressPercent = (timeLeft / totalTime) * 100
            if timeDiff < 0 then progressPercent = 0 end

            local timerText = string.format("%0.0fs", timeLeft)
            if timeDiff < 0 then
                timerText = string.format("LATE: %0.0fs", math.abs(timeDiff))
            end

            -- Ensure header is set every frame to prevent other mods/game logic from clearing it
            guihooks.trigger('SetTasklistHeader', {label = "BeamEats Delivery"})
            
            guihooks.trigger('SetTasklistTask', {
                id = "beamEats_phase",
                label = phaseLabel,
                done = false,
                active = true,
                type = "message",
                clear = false
            })
            guihooks.trigger('SetTasklistTask', {
                id = "beamEats_timer",
                label = "Time Limit",
                subtext = timerText,
                percent = progressPercent,
                done = false,
                active = true,
                type = "goal",
                clear = false
            })
        end
    end

    if state == "ready" then
        local beamEatsDisabled, disabledReason = isBeamEatsDisabled()
        if beamEatsDisabled then
            state = "start"
            requestBeamEatsState()
            return
        end

        jobOfferTimer = jobOfferTimer + dt
        if jobOfferTimer >= jobOfferInterval then
            local newOrder = generateOrder()
            if newOrder then
                startDelivery(newOrder)

                local msg = string.format("New Order Assigned!\nPickup: %s\nPay: $%0.2f | Dist: %0.1fkm", 
                    newOrder.restaurant, 
                    newOrder.baseFare, 
                    newOrder.totalDistance/1000)
                guihooks.trigger('toastrMsg', {type="info", title="BeamEats Job", msg=msg, config={time=5000}})
            else
                jobOfferTimer = 0
                jobOfferInterval = math.random(5, 45)
            end
        end
    end
end

-- ================================
-- STATE REQUEST
function requestBeamEatsState()
    local beamEatsDisabled, disabledReason = isBeamEatsDisabled()
    local effectiveState = beamEatsDisabled and "disabled" or state

    dataToSend = {
        state = effectiveState,
        currentOrder = currentOrder,
        vehicleMultiplier = string.format("%.1f", vehicleMultiplier),
        cumulativeReward = cumulativeReward,
        orderStreak = orderStreak,
        beamEatsDisabled = beamEatsDisabled,
        disabledReason = disabledReason
    }
    guihooks.trigger('updateBeamEatsState', dataToSend)
end

-- ================================
-- DELIVERY START
function startDelivery(order)
    if not order then
        order = currentOrder
    end

    if not order then
        return
    end

    state = "pickup"
    currentOrder = order
    currentOrder.startTime = timer -- Start timer immediately upon acceptance
    core_groundMarkers.setPath(order.pickup.pos)

    local beamEatsDisabled, disabledReason = isBeamEatsDisabled()
    local effectiveState = beamEatsDisabled and "disabled" or state

    dataToSend = {
        state = effectiveState,
        currentOrder = currentOrder,
        vehicleMultiplier = string.format("%.1f", vehicleMultiplier),
        cumulativeReward = cumulativeReward,
        orderStreak = orderStreak,
        beamEatsDisabled = beamEatsDisabled,
        disabledReason = disabledReason
    }
    guihooks.trigger('updateBeamEatsState', dataToSend)
end

-- ================================
-- EVENT HANDLERS
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

    if be:getPlayerVehicle(0) and (not gameplay_walk or not gameplay_walk.isWalking()) then
        generateValueMultiplier()
    end
    local beamEatsDisabled, disabledReason = isBeamEatsDisabled()
    local effectiveState = beamEatsDisabled and "disabled" or state

    dataToSend = {
        state = effectiveState,
        currentOrder = currentOrder,
        vehicleMultiplier = string.format("%.1f", vehicleMultiplier),
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