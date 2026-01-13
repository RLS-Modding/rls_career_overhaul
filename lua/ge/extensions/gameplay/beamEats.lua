local M = {}
M.dependencies = {'gameplay_sites_sitesManager', 'freeroam_facilities', 'gameplay_walk', 'gameplay_phone'}

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

-- Processes raw accelerometer readings (m/s^2), converts them to G-force, records the latest sensor snapshot, and counts rough driving events.
-- Updates M.deliveryData.currentSensorData with fields `gx`, `gy`, `gz`, `gx2`, `gy2`, `gz2` (all in G) and `timestamp`.
-- Increments M.deliveryData.roughEvents when the peak G from the second sensor set (`gx2`, `gy2`, `gz2`) exceeds 0.6; initializes `roughEvents` to 0 if absent.
-- @param gx Acceleration on X axis (m/s^2) from the primary sensor.
-- @param gy Acceleration on Y axis (m/s^2) from the primary sensor.
-- @param gz Acceleration on Z axis (m/s^2) from the primary sensor.
-- @param gx2 Acceleration on X axis (m/s^2) from the secondary/peak sensor.
-- @param gy2 Acceleration on Y axis (m/s^2) from the secondary/peak sensor.
-- @param gz2 Acceleration on Z axis (m/s^2) from the secondary/peak sensor.
local function processSensorData(gx, gy, gz, gx2, gy2, gz2)
    local grav = 9.81 -- Convert to G-force
    M.deliveryData.currentSensorData = {
        gx = gx / grav,
        gy = gy / grav,
        gz = gz / grav,
        gx2 = gx2 / grav,
        gy2 = gy2 / grav,
        gz2 = gz2 / grav,
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
-- Determines whether the BeamEats service is currently unavailable and why.
-- Checks whether the player is walking or whether the BeamEats economy multiplier is set to zero.
-- @return disabled `true` if BeamEats is disabled, `false` otherwise.
-- @return reason A human-readable explanation for the disabled state, or an empty string when enabled.
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
-- Compute a vehicle-based multiplier used to scale order value.
-- If the career system is inactive, returns 1.
-- If the player has no vehicle or required inventory/value modules are unavailable, returns 0.1.
-- If the player's vehicle exists but has no inventory id, returns 0.
-- Otherwise returns sqrt(vehicleValue / 30000) clamped to a minimum of 0.1.
-- @return The computed vehicle multiplier as described above.
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

-- Compute the travel distance between two positions following mapped roads when possible; falls back to straight-line distance if no road path exists.
-- @param startPos Vector position of the trip origin.
-- @param endPos Vector position of the trip destination.
-- @return The distance between `startPos` and `endPos` following map roads if a path is available, otherwise the straight-line (Euclidean) distance.
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

-- Calculate the base fare for a delivery order.
-- Applies distance, order-value, hardcore-mode reduction, and any economy section multipliers.
-- @param totalDistance Distance between pickup and dropoff in meters.
-- @param orderValueMultiplier Multiplier derived from vehicle value or other order-value factors.
-- @return The computed base fare amount in in-game currency.
local function calculateBaseFare(totalDistance, orderValueMultiplier)
    local baseFare = 100 * orderValueMultiplier * distanceMultiplier
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

-- Compute a time-based factor representing how the current delivery's elapsed time compares to its expected duration.
-- If there is no active order or the order has no start time, the function returns 0.
-- @return A number clamped to the range [-1, 1]: positive values indicate the delivery is ahead of schedule (elapsed < expected), negative values indicate it is behind schedule (elapsed > expected), and 0 represents on-time or no active timed delivery.
local function calculateTimeFactor()
    if not currentOrder or not currentOrder.startTime then
        return 0
    end

    local elapsedTime = timer - currentOrder.startTime
    local expectedTime = currentOrder.expectedTime or 300
    local speedFactor = (expectedTime - elapsedTime) / expectedTime

    return math.max(-1.0, math.min(1.0, speedFactor))
end

-- Compute a smooth-driving tip based on the count of rough driving events.
-- @param baseFare The base fare amount used to calculate the tip.
-- @param roughEvents The number of detected rough driving events for the delivery.
-- @return The tip amount: `baseFare * 0.2` if `roughEvents == 0`, `baseFare * 0.1` if `roughEvents <= 2`, or `0` otherwise.
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
-- Creates a new delivery order by selecting a random restaurant pickup and a distant delivery spot.
-- @return A table representing the order with fields:
-- `restaurant` (string) — restaurant name;
-- `restaurantId` (string|number) — facility identifier;
-- `pickup` (table) — `{ pos = Vector, name = string }` for the pickup spot;
-- `destination` (table) — `{ pos = Vector, name = string }` for the delivery spot;
-- `baseFare` (number) — computed base fare for the delivery;
-- `totalDistance` (number) — driving distance between pickup and destination (meters);
-- `expectedTime` (number) — expected delivery duration (seconds);
-- `startTime` (nil|number) — delivery start timestamp (nil until started).
-- Returns `nil` if BeamEats is disabled or no valid restaurants/delivery spots are available.
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
-- Finalizes the active delivery, computes payments and bonuses, updates state/UI, issues rewards, and clears delivery data.
-- If there is no active order, the function returns immediately.
-- Updates:
--   - Computes final payment from base fare, smooth-driving tip, and time-based bonus/penalty.
--   - Increments `cumulativeReward` and `orderStreak`.
--   - Populates `currentOrder` with payment, tip, time adjustments, rough event count, and formatted display strings.
--   - Sets module `state` to "complete" and may open the in-game phone with a completion message.
--   - Sends an updated BeamEats state payload to the UI (including disability status and vehicle multiplier).
--   - If career/payment modules are available and the career is active, issues a reward (money and beamXP) with a descriptive label; otherwise logs a warning.
--   - Resets ground markers and clears `M.deliveryData`.
-- Note: The function has observable side effects on module-level state and external systems; it does not return a value.
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

    state = "complete"
    if gameplay_phone and not gameplay_phone.isPhoneOpen() then
        gameplay_phone.togglePhone("You completed a delivery! Open the phone to view your earnings.")
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
-- Rejects the active order and returns the system to the "ready" state.
-- Clears the current order, resets the job offer timer, randomizes the next offer interval, and requests a state update.
local function rejectOrder()
    state = "ready"
    currentOrder = nil
    jobOfferTimer = 0
    jobOfferInterval = math.random(5, 45)
    requestBeamEatsState()
end

-- Stops the BeamEats job and resets all job-related state.
-- Clears any active order and its ground markers (if present), resets timers, cumulative rewards, order streak, delivery data, and sets the module state to "start". Triggers an updated UI/state push via requestBeamEatsState().
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

-- Sets the BeamEats workflow to the "ready" state and pushes an updated state to the UI.
-- This makes the system available to receive new delivery offers.
local function setAvailable()
    state = "ready"
    requestBeamEatsState()
end

-- Transition the active BeamEats order from pickup to dropoff when the player's vehicle is at the pickup location and initialize delivery state.
-- 
-- When the player is in a vehicle within 5 units of the order's pickup position, this function:
-- - sets the module state to "dropoff",
-- - records the delivery start time,
-- - initializes delivery sensor data (roughEvents),
-- - places the destination ground marker,
-- - prepares a UI update payload that includes the effective state (respecting BeamEats being disabled) and current metrics, and triggers an update event.
-- 
-- No parameters or return value.
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
        M.deliveryData = {
            roughEvents = 0
        }
        core_groundMarkers.setPath(currentOrder.destination.pos)

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
-- Advance BeamEats timers and progress the delivery state machine.
-- Handles periodic state requests, transitions between pickup/dropoff/accept/ready states,
-- processes sensor updates and completes deliveries when the player vehicle reaches the destination,
-- and generates new order offers while available (including opening the phone and pushing UI updates).
-- @param dt The elapsed time in seconds since the last update.
local function update(_, dt)
    timer = timer + dt
    updateTimer = updateTimer + dt

    if updateTimer >= updateInterval then
        updateTimer = 0
        requestBeamEatsState()
    end

    if currentOrder and state == "pickup" then
        prepareBeamEatsJob()
    end

    if currentOrder and state == "dropoff" then
        updateSensorData()

        local vehicle = be:getPlayerVehicle(0)
        if vehicle then
            local vehiclePos = vehicle:getPosition()
            local destDist = (vehiclePos - currentOrder.destination.pos):length()

            if destDist < 5 then
                completeDelivery()
            end
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
                currentOrder = newOrder
                state = "accept"
                if not gameplay_phone.isPhoneOpen() then
                    gameplay_phone.togglePhone("You have a new delivery order! Open the phone to view the details.")
                end

                dataToSend = {
                    state = state,
                    currentOrder = newOrder,
                    vehicleMultiplier = string.format("%.1f", vehicleMultiplier),
                    cumulativeReward = cumulativeReward,
                    orderStreak = orderStreak,
                    beamEatsDisabled = beamEatsDisabled,
                    disabledReason = disabledReason
                }
                guihooks.trigger('updateBeamEatsState', dataToSend)
            else
                jobOfferTimer = 0
                jobOfferInterval = math.random(5, 45)
            end
        end
    end
end

-- ================================
-- STATE REQUEST
-- Publishes the current BeamEats session state to the UI.
-- Assembles the effective state (including whether BeamEats is disabled and the reason), current order, vehicle multiplier, cumulative reward, and order streak, then triggers a UI update with that payload.
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
-- Starts a delivery: sets the module state to "pickup", assigns the given order (or uses the existing currentOrder), places the pickup ground marker, and pushes an updated BeamEats state to the UI.
-- @param order Optional table representing the order to start; if omitted the module's currentOrder is used. The order must include pickup.pos (a world position) for marker placement.
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
-- Refresh cached restaurant and delivery parking spot data after the player finishes entering a vehicle.
-- Updates internal lists used for order generation and delivery target selection.
local function onEnterVehicleFinished()
    findRestaurants()
    findAllDeliveryParkingSpots()
end

-- Handles switching the player's vehicle: settles any pending BeamEats payout, resets job state and timers, recomputes vehicle multiplier when appropriate, clears markers/orders, and pushes an updated BeamEats state to the UI.
-- Pays out `cumulativeReward` through `career_modules_payment.reward` when a career is active and a nonzero reward exists.
-- Resets `state` to "start", clears `currentOrder` and related timers/counters (`jobOfferTimer`, `jobOfferInterval`, `cumulativeReward`, `orderStreak`), and resets `vehicleMultiplier`.
-- If there was an active `currentOrder`, clears ground markers.
-- Recomputes the value multiplier via `generateValueMultiplier()` when the player is in a vehicle and not walking.
-- Determines whether BeamEats should be disabled and sends the composed `dataToSend` object via `guihooks.trigger('updateBeamEatsState', dataToSend)`.
local function onVehicleSwitched()
    -- Note: Rewards are already paid per-delivery in completeDelivery()
    -- cumulativeReward is only used for tracking/display purposes

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

-- Forward two raw sensor samples to the sensor data processor.
-- @param gx X component of the first sensor sample.
-- @param gy Y component of the first sensor sample.
-- @param gz Z component of the first sensor sample.
-- @param gx2 X component of the second sensor sample.
-- @param gy2 Y component of the second sensor sample.
-- @param gz2 Z component of the second sensor sample.
local function receiveSensorData(gx, gy, gz, gx2, gy2, gz2)
    processSensorData(gx, gy, gz, gx2, gy2, gz2)
end

-- ================================
-- MODULE LOADING
-- Called when the BeamEats extension is loaded; logs a module-loaded message.
-- (Lifecycle hook invoked by the host when the extension is initialized.)
local function onExtensionLoaded()
    print("BeamEats module loaded")
end

-- Determines whether the BeamEats job is currently active.
-- @return `true` if the BeamEats job is active, `false` otherwise.
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