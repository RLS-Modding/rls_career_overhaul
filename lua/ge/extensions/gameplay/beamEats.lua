local M = {}
M.dependencies = {'gameplay_sites_sitesManager', 'freeroam_facilities', 'gameplay_walk', 'gameplay_phone'}

M.config = {
    -- Driving smoothness
    roughEventThreshold = 1.2, 
    tipTiers = {
        { maxEvents = 0, percent = .75 },
        { maxEvents = 5, percent = 0.10 }
        
    },

    averageSpeedMPS = 18,

    bonusPerSecondEarly = 100,
    penaltyPerSecondLate = 0,
    onTimeBonusPercent = 0.20,
    
    baseFarePerKm = 125,
    zeroTipChance = 0.03,
    stopVelocityThreshold = 0.5,
    pickupDropoffDuration = 3.0,
    
    streakMultiplierPerLevel = 0.05, -- % increase per streak
    streakMultiplierMax = 1.0,       

    -- Reputation Scaling
    reputationPayMultiplierPerStar = 1.0, 
    
    -- Job Interval (seconds)
    intervalMinRating = {min = 40, max = 60}, 
    intervalMaxRating = {min = 1, max = 3},   
    
    ratingDampeningCount = 20,
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
local dwellDuration = config.pickupDropoffDuration 

local updateTimer = 1
local uiUpdateTimer = 0
local jobOfferTimer = 0

local jobOfferInterval = math.random(3, 8)

local vehicleMultiplier = 0.1

local restaurants = {}
local allDeliverySpots = nil

local ratingSaveFile = "beamEatsRating.json"
local playerRating = 0.0 
local ratingCount = 0

local suggestedSpeed = 18 
M.deliveryData = {}

local function savePlayerRating(currentSavePath)
    if not career_career or not career_career.isActive() then return end
    if not currentSavePath then
        local slot, path = career_saveSystem.getCurrentSaveSlot()
        currentSavePath = path
        if not currentSavePath then return end
    end

    local dirPath = currentSavePath .. "/career/rls_career"
    if not FS:directoryExists(dirPath) then
        FS:directoryCreate(dirPath)
    end

    local data = {
        sum = ratingSum,
        count = ratingCount,
        average = playerRating
    }
    career_saveSystem.jsonWriteFileSafe(dirPath .. "/" .. ratingSaveFile, data, true)
end

local function loadPlayerRating()
    if not career_career or not career_career.isActive() then return end
    local slot, path = career_saveSystem.getCurrentSaveSlot()
    if not path then return end
    local filePath = path .. "/career/rls_career/" .. ratingSaveFile
    local data = jsonReadFile(filePath) or {}
    ratingSum = tonumber(data.sum or 0) or 0
    ratingCount = tonumber(data.count or 0) or 0
    
    local virtualStartCount = config.ratingDampeningCount or 20
    local virtualStartRating = 0.0
    
    local effectiveSum = ratingSum + (virtualStartCount * virtualStartRating)
    local effectiveCount = ratingCount + virtualStartCount
    
    playerRating = math.max(0.0, math.min(5.0, effectiveSum / effectiveCount))
end

-- ================================
-- FORWARD DECLARATIONS
-- ================================
local requestBeamEatsState
local startDelivery

-- ================================
-- SENSOR DATA HANDLING
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
                        if logisticType == "food" or logisticType == "takeout" then
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
                            if logisticType == "food" or logisticType == "takeout" then
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
        return startPos:distance(endPos) * 2.0
    end

    local path = map.getPath(startRoad, endRoad)
    if not path or #path == 0 then
        return startPos:distance(endPos) * 2.0
    end

    local totalDistance = 0
    local prevNodePos = startPos
    local mapData = map.getMap()
    
    if not mapData or not mapData.nodes then
        return startPos:distance(endPos) * 2.0
    end

    for i = 1, #path do
        local node = mapData.nodes[path[i]]
        if node then
            local nodePos = node.pos
            totalDistance = totalDistance + prevNodePos:distance(nodePos)
            prevNodePos = nodePos
        end
    end

    totalDistance = totalDistance + prevNodePos:distance(endPos)

    return totalDistance
end

local function calculateBaseFare(totalDistance)
    local baseFare = config.baseFarePerKm * (totalDistance / 1000)

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
    if math.random() < config.zeroTipChance then
        return 0
    end

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
    
    local distToPickup = calculateDrivingDistance(vehiclePos, pickupSpot.pos)
    local distDelivery = calculateDrivingDistance(pickupSpot.pos, deliverySpot.pos)
    local totalDistance = distToPickup + distDelivery -- Total trip distance

    local baseFare = calculateBaseFare(totalDistance)

    local repMultiplier = 1.0 + (playerRating * config.reputationPayMultiplierPerStar)
    baseFare = baseFare * repMultiplier

    local expectedTime = totalDistance / config.averageSpeedMPS
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

    order.totalPaymentDisplay = string.format("%.2f", baseFare) -- Estimated, without tips/bonuses
    order.baseFareDisplay = string.format("%.2f", baseFare)
    order.totalDistanceDisplay = string.format("%.2f", totalDistance / 1000)
    order.expectedTimeDisplay = string.format("%d min %d sec", math.floor(expectedTime / 60), math.floor(expectedTime % 60))

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
    local timeDiff = expectedTime - elapsedTime 

    local roughEvents = M.deliveryData.roughEvents or 0
    local baseFare = currentOrder.baseFare
    local smoothDrivingTip = calculateSmoothDrivingTip(baseFare, roughEvents)
    
    local timeBonus = 0
    if timeDiff >= 0 then
        timeBonus = baseFare * config.onTimeBonusPercent
    end

    local streakMultiplier = math.min(orderStreak * config.streakMultiplierPerLevel, config.streakMultiplierMax)
    local streakBonus = baseFare * streakMultiplier

    local totalTips = smoothDrivingTip + timeBonus

    local finalPayment = baseFare + streakBonus + totalTips
    cumulativeReward = cumulativeReward + finalPayment
    orderStreak = orderStreak + 1

    currentOrder.totalPayment = finalPayment
    currentOrder.smoothDrivingTip = smoothDrivingTip
    currentOrder.timeBonus = timeBonus
    currentOrder.roughEvents = roughEvents
    currentOrder.totalTips = totalTips
    currentOrder.streakBonus = streakBonus

    local rating = 5.0
    rating = rating - (roughEvents * 0.5)
    if timeDiff < 0 then -- Late
        rating = rating - 1.0
    end
    rating = math.max(1.0, math.min(5.0, rating)) -- Clamp between 1 and 5

    ratingSum = ratingSum + rating
    ratingCount = ratingCount + 1
    
    
    local virtualStartCount = config.ratingDampeningCount or 20
    local virtualStartRating = 0.0
    
    local effectiveSum = ratingSum + (virtualStartCount * virtualStartRating)
    local effectiveCount = ratingCount + virtualStartCount
    
    playerRating = math.max(0.0, math.min(5.0, effectiveSum / effectiveCount))
    
    savePlayerRating()

    currentOrder.totalPaymentDisplay = string.format("%.2f", finalPayment)
    currentOrder.baseFareDisplay = string.format("%.2f", baseFare)
    currentOrder.totalTipsDisplay = string.format("%.2f", totalTips)
    currentOrder.totalDistanceDisplay = string.format("%.2f", currentOrder.totalDistance / 1000)

    state = "completed" 

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

    if gameplay_phone and not gameplay_phone.isPhoneOpen() then
        gameplay_phone.togglePhone("Delivery complete! Open BeamEats to view earnings.")
    end
    
    local label = string.format("BeamEats delivery: $%s\nDistance: %skm | Tips: $%s", currentOrder.totalPaymentDisplay,
        currentOrder.totalDistanceDisplay, currentOrder.totalTipsDisplay)

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

local function dismissSummary()
    state = "ready"
    currentOrder = nil
    jobOfferTimer = 0
    jobOfferInterval = math.random(2, 5) 
    core_groundMarkers.resetAll()
    M.deliveryData = {}
    requestBeamEatsState()
end

-- ================================
-- ORDER MANAGEMENT
-- ================================
local function rejectOrder()
    state = "ready"
    currentOrder = nil
    jobOfferTimer = 0
    jobOfferInterval = math.random(3, 8)
    requestBeamEatsState()
end

local function stopBeamEatsJob()
    state = "start"
    if currentOrder then
        core_groundMarkers.resetAll()
    end
    currentOrder = nil
    jobOfferTimer = 0
    jobOfferInterval = math.random(3, 8)
    cumulativeReward = 0
    orderStreak = 0
    M.deliveryData = {}
    guihooks.trigger('ClearTasklist') 
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
    if vehicle:getVelocity():length() < config.stopVelocityThreshold then
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

        M.deliveryData = {
            roughEvents = 0
        }
        core_groundMarkers.setPath(currentOrder.destination.pos)
        
        ui_message("Order picked up! Don't spill it!", 6, 'beamEats_main', 'check')

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
    if vehicle:getVelocity():length() < config.stopVelocityThreshold then
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
                    dwellTimer = 0 
                end
            end
        end

        if uiUpdateTimer >= 0.5 then 
            uiUpdateTimer = 0
            local elapsedTime = timer - currentOrder.startTime
            local timeLeft = math.max(0, currentOrder.expectedTime - elapsedTime)
            local timeDiff = currentOrder.expectedTime - elapsedTime 
            local totalTime = currentOrder.expectedTime
            
            local phaseLabel = (state == "pickup") and "Pickup at: " .. currentOrder.restaurant or "Deliver to: Customer"
            
            local progressPercent = (timeLeft / totalTime) * 100
            if timeDiff < 0 then progressPercent = 0 end

            local timerText = string.format("%0.0fs", timeLeft)
            if timeDiff < 0 then
                timerText = string.format("LATE: %0.0fs", math.abs(timeDiff))
            end

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

            local t = math.min(1.0, math.max(0.0, playerRating / 5.0))
            
            local minInterval = config.intervalMinRating.min + (config.intervalMaxRating.min - config.intervalMinRating.min) * t
            local maxInterval = config.intervalMinRating.max + (config.intervalMaxRating.max - config.intervalMinRating.max) * t
            
            jobOfferInterval = math.random(minInterval, maxInterval)

            local newOrder = generateOrder()
            if newOrder then
                currentOrder = newOrder
                state = "incoming"
                requestBeamEatsState()

                local msg = string.format("New Order Available!\nPickup: %s\nBase Pay: $%0.2f | Dist: %0.1fkm", 
                    newOrder.restaurant, 
                    newOrder.baseFare, 
                    newOrder.totalDistance/1000)
                guihooks.trigger('toastrMsg', {type="info", title="BeamEats Job", msg=msg, config={time=5000}})
            else
                jobOfferTimer = 0
                jobOfferInterval = math.random(10, 20)
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
        vehicleMultiplier = string.format("%.1f", vehicleMultiplier),
        cumulativeReward = cumulativeReward,
        orderStreak = orderStreak,
        beamEatsDisabled = beamEatsDisabled,
        disabledReason = disabledReason,
        playerRating = string.format("%.1f", playerRating)
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
    currentOrder.startTime = timer
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
        disabledReason = disabledReason,
        playerRating = string.format("%.1f", playerRating)
    }
    guihooks.trigger('updateBeamEatsState', dataToSend)
end

-- ================================
-- EVENT HANDLERS
-- ================================
local function onEnterVehicleFinished()
    findRestaurants()
    findAllDeliveryParkingSpots()
    loadPlayerRating()
end

local function onVehicleSwitched()

    state = "start"
    if currentOrder then
        core_groundMarkers.resetAll()
    end
    currentOrder = nil
    jobOfferTimer = 0
    jobOfferInterval = math.random(10, 20)
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
        disabledReason = disabledReason,
        playerRating = string.format("%.1f", playerRating)
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
    
    if be:getPlayerVehicle(0) then
        findRestaurants()
        findAllDeliveryParkingSpots()
    end
end

local function isBeamEatsJobActive()
    return state ~= "start" and state ~= "disabled"
end

local function onSaveCurrentSaveSlot(currentSavePath)
    savePlayerRating(currentSavePath)
end

-- ================================
-- MODULE EXPORTS
-- ================================
M.onExtensionLoaded = onExtensionLoaded
M.onEnterVehicleFinished = onEnterVehicleFinished
M.onUpdate = update
M.onVehicleSwitched = onVehicleSwitched
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

M.acceptOrder = startDelivery
M.rejectOrder = rejectOrder
M.setAvailable = setAvailable
M.stopBeamEatsJob = stopBeamEatsJob
M.generateOrder = generateOrder
M.requestBeamEatsState = requestBeamEatsState
M.isBeamEatsJobActive = isBeamEatsJobActive

M.dismissSummary = dismissSummary
M.receiveSensorData = receiveSensorData

return M