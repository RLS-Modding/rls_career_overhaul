-- ================================
-- AMBULANCE MODULE 
-- ================================

local M = {}
M.dependencies = {'gameplay_sites_sitesManager', 'freeroam_facilities'}

-- MODULE DEPENDENCIES
local core_groundMarkers = require('core/groundMarkers')
local core_vehicles = require('core/vehicles')

-- STATE VARIABLES
local currentFare = nil
local state = "ready"         
local parkingSpots = nil
local pickupTimer = nil
local pickupMessageShown = false
local missionTriggeredForVehicle = false
-- Stop-settle state
local stopMonitorActive       = false
local stopSettleTimer         = 0
local stopSettleDelay         = 2.5

-- Timers
M.initDelay = nil
M.initDelayDuration = nil
M.delayTimer = nil
M.delayDuration = nil
M.minDelay = 20
M.maxDelay = 90

-- Track rough ride metrics
local roughRide = 0
local lastVehiclePos = nil
local lastVelocity = nil  -- 

-- ================================
-- FORWARD DECLARATIONS
-- ================================
local startRide
local startNextMission
local generateFare
local updateMarkers

-- ================================
-- START RIDE
-- ================================
startRide = function(fare)
    if not fare then return end
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
    lastVehiclePos = playerVehicle:getPosition()
    roughRide = 0
    lastVelocity = nil

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
    if not playerVehicle then return nil end

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
    local dropoffSpot = pickupSpot
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

    return {
        pickup = {pos = pickupSpot.pos},
        destination = {pos = dropoffSpot.pos},
        baseFare = 2200,
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
updateMarkers = function(dtReal, dtSim, dtRaw)
    if not currentFare then return end
    local playerVehicle = be:getPlayerVehicle(0)
    if not playerVehicle then return end
    local vehiclePos = playerVehicle:getPosition()

    local velocity = playerVehicle:getVelocity()
    local speed = velocity:length()
    if lastVelocity then
        local deltaVel = velocity - lastVelocity
        local safeDt = (dtSim and dtSim > 0) and dtSim or 0.01  
        local accel = deltaVel:length() / safeDt

        local accelThreshold = 2
        if accel > accelThreshold then
            roughRide = roughRide + (accel - accelThreshold) * safeDt * 10
        end
    end
    lastVelocity = velocity

    -- PICKUP PHASE
    if state == "pickup" and currentFare.pickup then
        local distToPickup = (vehiclePos - currentFare.pickup.pos):length()
        if distToPickup <= 5 then
            -- Must be fully stopped (reuse bus settle logic)
            if speed > 0.5 then
                ui_message("Come to a complete stop before securing the patient.", 2, "info", "info")
                pickupTimer = nil
                stopMonitorActive = false
                stopSettleTimer = 0
                return
            end

            if not stopMonitorActive then
                stopMonitorActive = true
                stopSettleTimer = 0
                ui_message("Hold still to secure the patient...", 2.5, "info", "info")
            else
                stopSettleTimer = stopSettleTimer + (dtSim or 0)
            end

            if stopSettleTimer < stopSettleDelay then
                pickupTimer = nil
                return
            end

            if not pickupMessageShown then
                ui_message("Securing patient!", 12, "info", "info")
                pickupMessageShown = true
                currentFare.startTime = os.time()
            end
            if not pickupTimer then pickupTimer = 0 end
            pickupTimer = pickupTimer + (dtSim or 0)
            if pickupTimer >= 12 then 
                state = "enRoute"
                core_groundMarkers.resetAll()
                if currentFare.destination and currentFare.destination.pos then
                    core_groundMarkers.setPath(currentFare.destination.pos)
                end
                ui_message("Patient picked up, now enRoute", 8, "info", "info")
                pickupTimer = nil
                stopMonitorActive = false
                stopSettleTimer = 0
            end
        else
            pickupTimer = 0
            stopMonitorActive = false
            stopSettleTimer = 0
        end
    end
    -- DROPOFF PHASE
    if state == "enRoute" and currentFare.destination then
        local distToDropoff = (vehiclePos - currentFare.destination.pos):length()
        if distToDropoff > 3 then
            currentFare.dropoffTimer = nil
            stopMonitorActive = false
            stopSettleTimer = 0
            return
        end

        -- Must be fully stopped before dropoff
        if speed > 0.5 then
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
            if stopSettleTimer < stopSettleDelay then
                return
            end
        end

        -- extra dropoff dwell after settling; adjust 6 to your desired seconds
        currentFare.dropoffTimer = (currentFare.dropoffTimer or 0) + (dtSim or 0)
        if currentFare.dropoffTimer < 6 then
            ui_message(string.format("Stabilizing patient... %.1fs", math.max(0, 6 - currentFare.dropoffTimer)), 1, "info", "info")
            return
        end

        -- compute payout (original logic restored)
        local distToPickup = (currentFare.playerStartPos - currentFare.pickup.pos):length()
        local distToHospital = (currentFare.pickup.pos - currentFare.destination.pos):length()
        local distanceKM = (distToPickup + distToHospital) / 1000
        local basePayout = math.floor(2200 * distanceKM)
        
        -- Apply economy adjuster multiplier if available
        if career_economyAdjuster then
            local multiplier = career_economyAdjuster.getSectionMultiplier("ambulance") or 1.0
            basePayout = math.floor(basePayout * multiplier + 0.5)
        end
        
        local penalty = math.floor(roughRide * 0.1)
        local finalPayout = math.max(0, basePayout - penalty)

        if career_career and career_career.isActive() and career_modules_payment and career_modules_payment.reward then
            career_modules_payment.reward({
                money = { amount = finalPayout },
                beamXP = { amount = math.floor(finalPayout / 10) },
                paramedicWorkReputation = { amount = math.floor(finalPayout / 100) }
            }, {
                label = string.format("Ambulance fare: $%d | Rough ride penalty: $%d", finalPayout, penalty),
                tags = {"transport", "ambulance", "gameplay"}
            }, true)
        end

        local repGain = math.floor(finalPayout / 100)

        ui_message(string.format(
            "Patient delivered!\nDistance: %.2f km\nBase: $%d\nPenalty: $%d\nEarned: $%d\nReputation +%d",
            distanceKM, basePayout, penalty, finalPayout, repGain
        ), 6, "info", "info")

        print(string.format(
            "[ambulance] Patient delivered. Distance: %.2f km Base: $%d Penalty: $%d Earned: $%d Reputation +%d",
            distanceKM, basePayout, penalty, finalPayout, repGain
        ))
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

    -- POST-DROPOFF RANDOM DELAY
    if state == "completed" and M.delayTimer then
        M.delayTimer = M.delayTimer + (dtSim or 0)
        if M.delayTimer >= M.delayDuration then
            core_groundMarkers.resetAll()
            startNextMission()
            state = "ready"
            M.delayTimer = nil
            M.delayDuration = nil
            missionTriggeredForVehicle = false
            print("[ambulance] next mission started after random delay")
        end
    end
end

-- ================================
-- EXTENSION LOADED
-- ================================
local function onExtensionLoaded()
    ui_message("Ambulance module loaded. Waiting for 911 vehicle...", 3, "info", "info")
    print("[ambulance] extension loaded and waiting for vehicle trigger")
end

-- ================================
-- EXPORTS
-- ================================
M.onExtensionLoaded = onExtensionLoaded

function M.onUpdate(dtReal, dtSim, dtRaw)
    local playerVehicle = be:getPlayerVehicle(0)
    local in911 = playerVehicle and core_vehicles.getVehicleLicenseText(playerVehicle) == "911"

    -- Trigger mission and assign EMT role
    if in911 and not missionTriggeredForVehicle then
        missionTriggeredForVehicle = true
        M.initDelay = 0
        M.initDelayDuration = 0.1
        print("[ambulance] mission triggered by entering 911 vehicle, initializing...")

        -- Assign EMT role through traffic system if possible
        if gameplay_traffic and gameplay_traffic.getTrafficData then
            local trafficData = gameplay_traffic.getTrafficData()
            for _, vehRole in pairs(trafficData) do
                if vehRole.role and vehRole.role.name == "emt" then
                    vehRole.role:assignRoleToVehicle(playerVehicle)
                end
            end
        end
    end

    -- Abandon mission when leaving 911 vehicle
    if not in911 and missionTriggeredForVehicle then
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
        if M.initDelayDuration == nil then
            M.initDelayDuration = math.random(M.minDelay, M.maxDelay)
            print("[ambulance] mission trigger delay set to " .. M.initDelayDuration .. " seconds")
        end
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
