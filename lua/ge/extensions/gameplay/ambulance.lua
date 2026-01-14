-- ================================
-- AMBULANCE MODULE 
-- ================================
local M = {}
M.dependencies = {'gameplay_sites_sitesManager', 'freeroam_facilities'}

-- MODULE DEPENDENCIES
local core_groundMarkers = require('core/groundMarkers')

-- CONFIGURATION
local config = {
    -- Timers (seconds)
    pickupDuration = 10,
    dropoffDuration = 6,
    stopSettleDelay = 2.5,
    minDelay = 20,
    maxDelay = 90,
    
    -- Distances (meters)
    stopRadius = 5,
    
    -- Payouts
    baseFare = 2200,
    timeBonusPerSec = 10,
    roughRidePenaltyFactor = 0.1,
    maxPenaltyFactor = 0.75,
    
    -- Physics
    maxStopSpeed = 0.5
}

-- Recursively searches through a parts tree to find a child named "paint_design".
-- @param node The current node in the parts tree to search.
-- @return The paint_design node if found, nil otherwise.
local function findPaintDesign(node)
    if not node or not node.children then
        return nil
    end
    if node.children.paint_design then
        return node.children.paint_design
    end
    for _, child in pairs(node.children) do
        local result = findPaintDesign(child)
        if result then
            return result
        end
    end
    return nil
end

-- Determines whether a vehicle uses an ambulance paint design.
-- @param vehicleId Optional vehicle id; if omitted the player's current vehicle is used.
-- @return `true` if the vehicle's paint_design config is a string containing "ambulance" (case-insensitive), `false` otherwise.
local function isAmbulancePaintDesign(vehicleId)
    local id = vehicleId
    if not id then
        local playerVehicle = be:getPlayerVehicle(0)
        if not playerVehicle then
            return false
        end
        id = playerVehicle:getId()
    end
    local vehData = core_vehicle_manager.getVehicleData(id)
    local partsTree = vehData and vehData.config and vehData.config.partsTree
    local paintDesign = findPaintDesign(partsTree)
    local chosenPaintDesign = paintDesign and paintDesign.chosenPartName
    return chosenPaintDesign and type(chosenPaintDesign) == "string" and chosenPaintDesign:lower():find("ambulance") ~= nil
end

-- STATE VARIABLES
local currentFare = nil
local state = "ready"
local parkingSpots = nil
local pickupTimer = nil
local pickupMessageShown = false
local missionTriggeredForVehicle = false
-- Stop-settle state
local stopMonitorActive = false
local stopSettleTimer = 0

-- Cached ambulance state (updated on load and vehicle switch)
local inAmbulance = false
local currentLoanerCut = 0

-- Timers
M.initDelay = nil
M.initDelayDuration = nil
M.delayTimer = nil
M.delayDuration = nil
M.minDelay = config.minDelay
M.maxDelay = config.maxDelay

M.rideData = {}

-- ================================
-- FORWARD DECLARATIONS
-- ================================
local startRide
local startNextMission
local generateFare
local updateMarkers

local function calculateLoanerCut(vehId)
    if not vehId then return 0 end
    
    if not career_modules_loanerVehicles or not career_modules_loanerVehicles.getLoaningOrgsOfVehicle then
        return 0
    end
    
    local loaningOrgs = career_modules_loanerVehicles.getLoaningOrgsOfVehicle(vehId)
    if not loaningOrgs or not next(loaningOrgs) then
        return 0
    end
    
    local totalCut = 0
    for organizationId, _ in pairs(loaningOrgs) do
        if freeroam_organizations and freeroam_organizations.getOrganization then
            local organization = freeroam_organizations.getOrganization(organizationId)
            if organization and organization.reputation and organization.reputationLevels then
                local level = organization.reputation.level
                local levelIndex = level + 2
                if organization.reputationLevels[levelIndex] and organization.reputationLevels[levelIndex].loanerCut then
                    local orgCut = organization.reputationLevels[levelIndex].loanerCut.value or 0.5
                    totalCut = totalCut + orgCut
                end
            end
        end
    end
    
    return math.min(totalCut, 1.0)
end

-- ================================
-- START RIDE
-- ================================
startRide = function(fare)
    if not fare then
        return
    end
    currentFare = fare
    local playerVehicle = be:getPlayerVehicle(0)
    if not playerVehicle then
        print("[ambulance] startRide: no player vehicle")
        return
    end

    state = "pickup"
    pickupTimer = 0
    pickupMessageShown = false

    currentFare.playerStartPos = playerVehicle:getPosition()
    
    M.rideData = {}
    M.rideData.roughEvents = 0

    if fare.pickup and fare.pickup.pos then
        core_groundMarkers.setPath(fare.pickup.pos)
    end

    ui_message("Medical assistance needed! Proceed to the pickup.", 6, "info", "info")
    print("[ambulance] new ride started - pickup set")
end

-- ================================
-- GENERATE FARE
-- ================================
generateFare = function()
    if not parkingSpots then
        local sitePath = gameplay_sites_sitesManager.getCurrentLevelSitesFileByName('city')
        if sitePath then
            local siteData = gameplay_sites_sitesManager.loadSites(sitePath, true, true)
            parkingSpots = siteData and siteData.parkingSpots
        end
    end
    if not parkingSpots or not parkingSpots.objects then
        print("[ambulance] generateFare: no city parking spots")
        return nil
    end

    local validPickups = {}
    local playerVehicle = be:getPlayerVehicle(0)
    if not playerVehicle then
        return nil
    end

    for _, spot in pairs(parkingSpots.objects) do
        if spot.pos then
            table.insert(validPickups, spot)
        end
    end
    if #validPickups == 0 then
        print("[ambulance] generateFare: no valid pickups")
        return nil
    end
    local pickupSpot = validPickups[math.random(#validPickups)]

    local hospitalSitePath = gameplay_sites_sitesManager.getCurrentLevelSitesFileByName('roleplay')
    local dropoffSpot = nil
    if hospitalSitePath then
        local hospitalSiteData = gameplay_sites_sitesManager.loadSites(hospitalSitePath, true, true)
        if hospitalSiteData and hospitalSiteData.parkingSpots and hospitalSiteData.parkingSpots.objects then
            for _, spot in pairs(hospitalSiteData.parkingSpots.objects) do
                if spot.name == "Hospital Entrance" then
                    dropoffSpot = spot
                    break
                end
            end
        end
    end

    if not dropoffSpot then
        log('W', 'ambulance',
            'No "Hospital Entrance" found in site data. Path: ' .. tostring(hospitalSitePath) .. ' Pickup: ' ..
                (pickupSpot and pickupSpot.name or tostring(pickupSpot)))
        return nil
    end

    return {
        pickup = {
            pos = pickupSpot.pos
        },
        destination = {
            pos = dropoffSpot.pos
        },
        baseFare = config.baseFare,
        passengers = 1,
        passengerType = "STANDARD",
        passengerTypeName = "Standard",
        passengerDescription = "Patient"
    }
end

-- ================================
-- START NEXT MISSION
-- ================================
startNextMission = function()
    -- Check if ambulance multiplier is 0 (if economy adjuster supports it)
    if career_economyAdjuster then
        local ambulanceMultiplier = career_economyAdjuster.getSectionMultiplier("ambulance") or 1.0
        if ambulanceMultiplier == 0 then
            ui_message("Ambulance missions are currently disabled.", 5, "error", "error")
            print("[ambulance] Ambulance multiplier is set to 0, mission generation cancelled")
            return
        end
    end

    currentFare = nil
    state = "ready"
    pickupTimer = nil
    pickupMessageShown = false
    core_groundMarkers.resetAll()
    local fare = generateFare()
    if fare then
        startRide(fare)
    else
        ui_message("No valid ambulance missions available!", 5, "info", "info")
        print("[ambulance] startNextMission: no fare generated")
    end
end

-- ================================
-- UPDATE MARKERS & STATE
-- ================================

-- ================================
-- SENSOR DATA HANDLING
-- ================================
local function updateSensorData()
    if not currentFare or state ~= "enRoute" then
        return
    end
    
    local vehicle = be:getPlayerVehicle(0)
    if not vehicle then return end
    
    vehicle:queueLuaCommand([[
        local sensors = require('sensors')
        if sensors then
            local gx, gy, gz = sensors.gx or 0, sensors.gy or 0, sensors.gz or 0
            local gx2, gy2, gz2 = sensors.gx2 or 0, sensors.gy2 or 0, sensors.gz2 or 0
            obj:queueGameEngineLua('gameplay_ambulance.receiveSensorData('..gx..','..gy..','..gz..','..gx2..','..gy2..','..gz2..')')
        end
    ]])
end

local function processSensorData(gx, gy, gz, gx2, gy2, gz2)
    local grav = 9.81
    M.rideData.currentSensorData = {
        gx = gx / grav, gy = gy / grav, gz = gz / grav,
        gx2 = gx2 / grav, gy2 = gy2 / grav, gz2 = gz2 / grav,
        timestamp = os.time()
    }
    
    if not M.rideData.roughEvents then
        M.rideData.roughEvents = 0
    end
    
    local peak = math.max(math.abs(gx2 / grav), math.abs(gy2 / grav), math.abs(gz2 / grav))
    if peak > 1.2 then
        M.rideData.roughEvents = M.rideData.roughEvents + 1
    end
end

-- Helper: Handle Pickup State
local function handlePickup(dtSim, vehiclePos, speed)
    if not currentFare or not currentFare.pickup then return end

    local distToPickup = (vehiclePos - currentFare.pickup.pos):length()
    
    -- 1. Check Distance
    if distToPickup > config.stopRadius then
        pickupTimer = 0
        stopMonitorActive = false
        stopSettleTimer = 0
        return
    end

    -- 2. Check Speed (Must be stopped)
    if speed > config.maxStopSpeed then
        ui_message("Come to a complete stop before securing the patient.", 2, "info", "info")
        pickupTimer = nil
        stopMonitorActive = false
        stopSettleTimer = 0
        return
    end

    -- 3. Handle Settling (Stop Monitor)
    if not stopMonitorActive then
        stopMonitorActive = true
        stopSettleTimer = 0
        ui_message("Hold still to secure the patient...", config.stopSettleDelay, "info", "info")
        return
    end

    stopSettleTimer = stopSettleTimer + (dtSim or 0)
    if stopSettleTimer < config.stopSettleDelay then
        return
    end

    -- 4. Handle Pickup Countdown
    if not pickupMessageShown then
        pickupMessageShown = true
        currentFare.elapsedTime = 0
    end
    if not pickupTimer then
        pickupTimer = 0
    end
    pickupTimer = pickupTimer + (dtSim or 0)
    
    local totalTime = config.pickupDuration
    if pickupTimer < totalTime then
        local remaining = math.ceil(math.max(0, totalTime - pickupTimer))
        ui_message(string.format("Securing patient... %ds", remaining), 1, "info", "info")
        return
    end

    -- 5. Completion
    state = "enRoute"
    core_groundMarkers.resetAll()
    if currentFare.destination and currentFare.destination.pos then
        core_groundMarkers.setPath(currentFare.destination.pos)
    end
    ui_message("Patient picked up, now enRoute", 8, "info", "info")
    pickupTimer = nil
    stopMonitorActive = false
    stopSettleTimer = 0
    M.rideData.roughEvents = 0
end

-- Helper: Handle Dropoff (EnRoute) State
local function handleDropoff(dtSim, vehiclePos, speed)
    if not currentFare or not currentFare.destination then return end

    -- Accumulate elapsed time using dtSim for precision
    currentFare.elapsedTime = (currentFare.elapsedTime or 0) + (dtSim or 0)
    local distToDropoff = (vehiclePos - currentFare.destination.pos):length()
    
    if distToDropoff > config.stopRadius then -- Increased radius slightly
        currentFare.dropoffTimer = nil
        stopMonitorActive = false
        stopSettleTimer = 0
        return
    end

    -- Must be fully stopped before dropoff
    if speed > config.maxStopSpeed then
        ui_message("Come to a complete stop to offload the patient.", 2, "info", "info")
        currentFare.dropoffTimer = nil
        stopMonitorActive = false
        stopSettleTimer = 0
        return
    end

    if not stopMonitorActive then
        stopMonitorActive = true
        stopSettleTimer = 0
        ui_message("Hold still to offload the patient...", 2.5, "info", "info")
        return
    else
        stopSettleTimer = stopSettleTimer + (dtSim or 0)
        if stopSettleTimer < config.stopSettleDelay then
            return
        end
    end

    -- extra dropoff dwell after settling
    currentFare.dropoffTimer = (currentFare.dropoffTimer or 0) + (dtSim or 0)
    local dropoffDuration = config.dropoffDuration
    if currentFare.dropoffTimer < dropoffDuration then
        local remaining = math.ceil(math.max(0, dropoffDuration - currentFare.dropoffTimer))
        ui_message(string.format("Stabilizing patient... %ds", remaining), 1, "info", "info")
        return
    end

    -- Calculate Payouts
    local distToPickup = (currentFare.playerStartPos - currentFare.pickup.pos):length()
    local distToHospital = (currentFare.pickup.pos - currentFare.destination.pos):length()
    local distanceKM = (distToPickup + distToHospital) / 1000
    local basePayout = math.floor(config.baseFare * distanceKM)

    -- Apply economy adjuster multiplier if available
    if career_economyAdjuster then
        local multiplier = career_economyAdjuster.getSectionMultiplier("ambulance") or 1.0
        basePayout = math.floor(basePayout * multiplier + 0.5)
    end

    -- Time bonus for fast delivery (60 seconds expected per km)
    local timeBonus = 0
    if currentFare.elapsedTime then
        local expectedTime = math.max(60, distanceKM * 60) -- 60 sec/km, minimum 60 sec
        if currentFare.elapsedTime < expectedTime then
            local timeSaved = expectedTime - currentFare.elapsedTime
            timeBonus = math.floor(timeSaved * config.timeBonusPerSec)
            timeBonus = math.min(timeBonus, math.floor(basePayout * 0.5)) -- Cap at 50% of base
        end
    end

    local roughEvents = M.rideData.roughEvents or 0
    local penalty = math.floor(roughEvents * config.roughRidePenaltyFactor * 100)
    -- Cap penalty at 75% of the total payout (base + time bonus)
    local maxPenalty = math.floor((basePayout + timeBonus) * config.maxPenaltyFactor)
    penalty = math.min(penalty, maxPenalty)
    local finalPayout = math.max(0, basePayout + timeBonus - penalty)

    -- Apply Loaner Cut
    local loanerCutAmount = 0
    if currentLoanerCut > 0 then
        loanerCutAmount = math.floor(finalPayout * currentLoanerCut)
        finalPayout = finalPayout - loanerCutAmount
    end

    if career_career and career_career.isActive() and career_modules_payment and career_modules_payment.reward then
        career_modules_payment.reward({
            money = {
                amount = finalPayout
            },
            beamXP = {
                amount = math.floor(finalPayout / 10)
            },
            wcuParamedicWorkReputation = {
                amount = math.floor(finalPayout / 100)
            }
        }, {
            label = string.format("Gross Earnings: $%d | Time bonus: $%d | Rough ride penalty: $%d | Loaner Cut: -$%d", finalPayout + loanerCutAmount, timeBonus, penalty, loanerCutAmount),
            tags = {"transport", "ambulance", "gameplay"}
        }, true)
    end

    local repGain = math.floor(finalPayout / 100)

    local msg = string.format(
        "Patient delivered!\nDistance: %.2f km\nBase: $%d\nTime Bonus: $%d\nPenalty: -$%d",
        distanceKM, basePayout, timeBonus, penalty)
    
    if loanerCutAmount > 0 then
        msg = msg .. string.format("\nLoaner cut: -$%d", loanerCutAmount)
    end
    
    msg = msg .. string.format("\nEarned: $%d\nReputation +%d", finalPayout, repGain)

    ui_message(msg, 6, "info", "info")

    print(string.format(
        "[ambulance] Patient delivered. Distance: %.2f km Base: $%d Time Bonus: $%d Penalty: $%d LoanerCut: $%d Earned: $%d Reputation +%d",
        distanceKM, basePayout, timeBonus, penalty, loanerCutAmount, finalPayout, repGain))
    currentFare.dropoffTimer = nil
    state = "completed"
    core_groundMarkers.resetAll()
    stopMonitorActive = false
    stopSettleTimer = 0
    if not M.delayTimer then
        M.delayTimer = 0
        M.delayDuration = math.random(M.minDelay, M.maxDelay)
        print("[ambulance] next mission will start in " .. M.delayDuration .. " seconds")
    end
end

updateMarkers = function(_dtReal, dtSim, _dtRaw)
    if not currentFare then
        return
    end
    local playerVehicle = be:getPlayerVehicle(0)
    if not playerVehicle then
        return
    end
    local vehiclePos = playerVehicle:getPosition()
    local velocity = playerVehicle:getVelocity()
    local speed = velocity:length()

    if state == "enRoute" then
        updateSensorData()
    end

    -- PICKUP PHASE
    if state == "pickup" then
        handlePickup(dtSim, vehiclePos, speed)
    -- DROPOFF PHASE (enRoute)
    elseif state == "enRoute" then
        handleDropoff(dtSim, vehiclePos, speed)
    -- POST-DROPOFF RANDOM DELAY
    elseif state == "completed" and M.delayTimer then
        M.delayTimer = M.delayTimer + (dtSim or 0)
        if M.delayTimer >= M.delayDuration then
            core_groundMarkers.resetAll()
            startNextMission()
            -- Only set state to ready if startNextMission didn't change it (e.g. early return)
            if state == "completed" then
                state = "ready"
            end
            M.delayTimer = nil
            M.delayDuration = nil
            missionTriggeredForVehicle = false
            print("[ambulance] next mission started after random delay")
        end
    end
end

-- ================================
-- EXTENSION LOADED
-- Handles extension load: notifies the player that the Ambulance module is active and logs readiness for vehicle-triggered missions.
-- Displays a brief UI message and prints a diagnostic notice to the console.
local function onExtensionLoaded()
    inAmbulance = isAmbulancePaintDesign()
    if inAmbulance then
        local vehicle = be:getPlayerVehicle(0)
        if vehicle then
            currentLoanerCut = calculateLoanerCut(vehicle:getId())
        end
    end
    ui_message("Ambulance module loaded. Waiting for 911 vehicle...", 3, "info", "info")
    print("[ambulance] extension loaded and waiting for vehicle trigger")
end

-- ================================
-- EXTENSION UNLOADED (cleanup)
-- Reset the Ambulance module to its initial state and clear any active markers when the extension is unloaded.
-- This clears mission state and timers, resets tracking variables used during a ride, resets public init/delay timers, clears ground markers, and prints an unload notice.
local function onExtensionUnloaded()
    -- Reset all state variables to prevent stale state on reload
    currentFare = nil
    state = "ready"
    parkingSpots = nil
    pickupTimer = nil
    pickupMessageShown = false
    missionTriggeredForVehicle = false
    stopMonitorActive = false
    stopSettleTimer = 0
    M.rideData = {}
    inAmbulance = false
    currentLoanerCut = 0

    -- Reset timers
    M.initDelay = nil
    M.initDelayDuration = nil
    M.delayTimer = nil
    M.delayDuration = nil

    -- Clear any active markers
    core_groundMarkers.resetAll()

    print("[ambulance] extension unloaded, state cleaned up")
end

-- ================================
-- VEHICLE SWITCHED
-- Updates the cached ambulance paint design state when the player switches vehicles.
local function onVehicleSwitched(oldId, newId, player)
    inAmbulance = isAmbulancePaintDesign(newId)
    if inAmbulance then
        currentLoanerCut = calculateLoanerCut(newId)
    else
        currentLoanerCut = 0
    end
end

-- ================================
-- EXPORTS
-- ================================
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onVehicleSwitched = onVehicleSwitched
M.isAmbulancePaintDesign = isAmbulancePaintDesign
M.updateSensorData = updateSensorData
M.receiveSensorData = processSensorData

-- Returns the cached ambulance state (updated on load and vehicle switch)
function M.isInAmbulance()
    return inAmbulance
end

-- Called each update tick to manage ambulance mission lifecycle and per-frame state.
-- Handles triggering missions when entering an ambulance-design vehicle, assigning the EMT role via the traffic system when available, abandoning active missions on exit, managing the initial mission start delay, and delegating marker/state updates.
-- @param dtReal Real-world frame time delta (seconds).
-- @param dtSim Simulation time delta (seconds); used for mission timers and delays.
-- @param dtRaw Raw frame delta (engine-specific, may be nil).
function M.onUpdate(dtReal, dtSim, dtRaw)
    local playerVehicle = be:getPlayerVehicle(0)

    -- Trigger mission and assign EMT role
    if playerVehicle and inAmbulance and not missionTriggeredForVehicle then
        missionTriggeredForVehicle = true
        M.initDelay = 0
        M.initDelayDuration = 0.1
        print("[ambulance] mission triggered by entering 911 vehicle, initializing...")

        -- Assign EMT role via traffic vehicle wrapper
        local trafficVehicle = gameplay_traffic.getTrafficData()[playerVehicle:getId()]
        if trafficVehicle then
            trafficVehicle:setRole("emt")
        end
    end

    -- Abandon mission when leaving ambulance vehicle
    if not inAmbulance and missionTriggeredForVehicle then
        missionTriggeredForVehicle = false

        if currentFare then
            currentFare = nil
            state = "ready"
            pickupTimer = nil
            pickupMessageShown = false
            core_groundMarkers.resetAll()
            ui_message("Ambulance mission abandoned.", 4, "warning", "warning")
            print("[ambulance] mission abandoned because player exited 911 vehicle")
        end
    end

    -- Handle initial mission delay after vehicle enter
    if M.initDelay ~= nil then
        M.initDelay = M.initDelay + (dtSim or 0)
        if M.initDelay >= M.initDelayDuration then
            startNextMission()
            M.initDelay = nil
            M.initDelayDuration = nil
            print("[ambulance] initial mission started after vehicle enter")
        end
    end

    -- Run marker & state updates
    updateMarkers(dtReal, dtSim, dtRaw)
end

return M