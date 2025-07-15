local M = {}

M.dependencies = {'career_career', 'gameplay_sites_sitesManager', 'util_configListGenerator', 'gameplay_traffic', 'career_saveSystem'}

local carmeetLocations = {}
local carMeetVehicles = {}
local spawnedMeetVehicles = {}
local pendingVehicles = {}
local usedConfigs = {}

local meetData = nil
local attendanceLevel = 1
local saveFile = "carmeets.json"
local lastGenerationTime = 0
local generationInterval = 1800
local rsvpData = nil
local meetStartTime = 0.417
local meetTimes = {0.417, 0.771, 0.188, 0.243}
local meetTimeWindow = 0.01
local lastUpdateCheck = 0
local updateInterval = 5

local careerActive = false
local previousTrafficAmount = nil

local meetState = {
    active = false,
    type = nil,
    location = nil,
    playerSpot = nil,
    startTime = 0,
    arrivalTime = 0,
    flags = {},
    phase = "waiting"
}

local attendanceLevels = {
    LOW = 1,
    MEDIUM = 2,
    HIGH = 3
}

local MEET_CLEANUP_DISTANCE = 100
local MEET_LEAVE_INTERVAL = 5
local VEHICLE_SPAWN_DISTANCE = 150
local VEHICLE_VISIBLE_DISTANCE = 100
local VEHICLE_UPDATE_INTERVAL = 0.25

local function saveAndReduceTraffic(reductionPercent)
    if gameplay_traffic then
        previousTrafficAmount = gameplay_traffic.getNumOfTraffic()
        local newAmount = math.floor(previousTrafficAmount * (1 - reductionPercent))
        gameplay_traffic.setActiveAmount(newAmount)
    end
end

local function restoreTrafficAmount()
    if gameplay_traffic and previousTrafficAmount then
        local settingsAmount = settings.getValue('trafficAmount') == 0 and getMaxVehicleAmount() or
                               settings.getValue('trafficAmount')
        local trafficAmount = settingsAmount or previousTrafficAmount
        local pooledAmount = settings.getValue('trafficExtraAmount') or 0
        gameplay_traffic.setActiveAmount(trafficAmount + pooledAmount, trafficAmount)
        previousTrafficAmount = nil
    end
end

local meetTypes = {
    SHOWCASE = {
        name = "Showcase",
        description = "Show off your ride and admire others",
        baseReputationMultiplier = 1.0,
        showcaseDuration = 60,
        preferredTimes = {0.417, 0.458, 0.500},
        timeWindow = 0.02,
        vehicleFilters = {
            whiteList = {
                ["Config Type"] = {"CarmeetRLS", "Custom"},
                ["Body Style"] = {"Sedan", "Hatchbook", "SUV", "Coupe"}
            }
        },
        actions = {
            onArrival = function(reputation)
                return "Welcome to the car meet!\nCommunity liked your car!\nVehicle value increased by " .. reputation .. "%"
            end,
            onShowcaseEnd = function(state)
                state.phase = "ending"
                state.flags.dispersalStarted = false
                ui_message("Car meet is over, vehicles starting to leave!", 10, "info", "info")
            end,
            onLeave = function()
                return "Car meet is over, Thanks for coming!"
            end
        },
        onUpdate = nil
    },
    STREET_CRUISE = {
        name = "Street Cruise",
        description = "High-performance cruising meet",
        baseReputationMultiplier = 1.5,
        showcaseDuration = 20,
        preferredTimes = {0.875, 0.917, 0.958},
        timeWindow = 0.025,
        vehicleFilters = {
            whiteList = {
                ["Config Type"] = {"Sport", "Race", "CarmeetRLS"},
                ["Body Style"] = {"Coupe", "Sedan", "Hatchback"}
            }
        },
        actions = {
            onArrival = function(reputation)
                saveAndReduceTraffic(0.5)
                return "Ready to cruise!\nCruisers respect your ride!\nVehicle performance reputation increased by " .. reputation .. "%"
            end,
            onShowcaseEnd = function(state)
                state.phase = "cruise"
                state.flags.cruiseStarted = false
                state.flags.playerReachedDestination = false
                state.flags.cruiseDestinationRadius = 15
            end,
            onLeave = function()
                core_jobsystem.create(function(job)
                    job.sleep(10)
                    restoreTrafficAmount()
                end)
                return "Cruise complete! Drive safe out there!"
            end
        },
        onUpdate = function(state, currentTime)
            local function getCruiseDestination(meetLocation)
                if not meetLocation then return nil end
                
                local meetCenter = meetLocation.position
                local minDistance = 2000
                local maxDistance = 10000
                
                local otherMeets = M.getCarMeetLocations()
                local validDestinations = {}
                
                for name, location in pairs(otherMeets) do
                    if name ~= meetLocation.zone.name then
                        local distance = (location.position - meetCenter):length()
                        if distance >= minDistance and distance <= maxDistance then
                            table.insert(validDestinations, location.position)
                        end
                    end
                end
                
                if #validDestinations > 0 then
                    return validDestinations[math.random(#validDestinations)]
                end
                
                local mapData = map.getMap()
                if mapData and mapData.nodes then
                    local validNodes = {}
                    
                    for nodeId, node in pairs(mapData.nodes) do
                        if node.pos then
                            local distance = (node.pos - meetCenter):length()
                            if distance >= minDistance and distance <= maxDistance then
                                table.insert(validNodes, node.pos)
                            end
                        end
                    end
                    
                    if #validNodes > 0 then
                        return validNodes[math.random(#validNodes)]
                    end
                end
                
                return nil
            end
            
            if state.phase == "cruise" then
                if not state.flags.cruiseStarted then
                    state.flags.cruiseDestination = getCruiseDestination(state.location)
                    if state.flags.cruiseDestination then
                        local message = "Follow the group to the cruise destination!"
                        ui_message(message, 10, "info", "info")
                        
                        local options = {
                            color = {0, 1, 0.4},
                            step = 4,
                            renderDecals = true
                        }
                        core_groundMarkers.setPath(state.flags.cruiseDestination, options)
                        
                        for _, vehID in ipairs(spawnedMeetVehicles) do
                            local veh = getObjectByID(vehID)
                            if veh then
                                veh:queueLuaCommand('extensions.load("driver")')
                                core_jobsystem.create(function(job)
                                    job.sleep(0.5)
                                    veh:queueLuaCommand('driver.returnTargetPosition(' .. serialize(state.flags.cruiseDestination) .. ', nil, "off")')
                                end)
                            end
                        end
                        state.flags.cruiseStarted = true
                    else
                        state.phase = "ending"
                    end
                elseif not state.flags.playerReachedDestination then
                    local playerVeh = be:getPlayerVehicle(0)
                    if playerVeh and state.flags.cruiseDestination then
                        local distance = (playerVeh:getPosition() - state.flags.cruiseDestination):length()
                        if distance < state.flags.cruiseDestinationRadius then
                            state.flags.playerReachedDestination = true
                            
                            local cruiseReputation = math.floor(math.random() * 50) / 10
                            if career_modules_hardcore.isHardcoreMode() then
                                cruiseReputation = cruiseReputation / 2
                            end
                            cruiseReputation = cruiseReputation * 1.2
                            cruiseReputation = math.max(cruiseReputation, 0.5)
                            
                            local message = "Great cruise!\nYou kept up with the group!\nBonus reputation: " .. cruiseReputation .. "%"
                            ui_message(message, 10, "info", "info")
                            
                            local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(be:getPlayerVehicleID(0))
                            if inventoryId then
                                career_modules_inventory.addMeetReputation(inventoryId, cruiseReputation)
                            end
                            
                            core_groundMarkers.resetAll()
                            career_saveSystem.saveCurrent()
                            
                            state.phase = "ending"
                            state.flags.dispersalStarted = false
                        end
                    end
                end
            end
        end
    }
}

local function getMeetType(typeKey)
    return meetTypes[typeKey]
end

local function cleanupPreviousMeet()
    for _, vehId in ipairs(spawnedMeetVehicles) do
        gameplay_traffic.removeTraffic(vehId)
        local veh = getObjectByID(vehId)
        if veh then
            veh:delete()
        end
    end
    spawnedMeetVehicles = {}
    pendingVehicles = {}
    core_groundMarkers.resetAll()
    
    restoreTrafficAmount()
    
    meetState.active = false
    meetState.type = nil
    meetState.location = nil
    meetState.playerSpot = nil
    meetState.startTime = 0
    meetState.arrivalTime = 0
    meetState.flags = {}
    meetState.phase = "waiting"
end

local function loadCarMeetData()
    if not career_career.isActive() then return end
    local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
    if not currentSavePath then return end
    
    local filePath = currentSavePath .. "/career/rls_career/" .. saveFile
    local data = jsonReadFile(filePath)
    
    if data then
        lastGenerationTime = data.lastGenerationTime or 0
        rsvpData = data.rsvpData
    end
end

local function getCarMeetVehicles(meetType)
    local vehicles = {}
    local eligibleVehicles = util_configListGenerator.getEligibleVehicles(false, false)
    
    local filters = meetType and meetType.vehicleFilters or meetTypes.SHOWCASE.vehicleFilters
    
    local vehicleInfos = util_configListGenerator.getRandomVehicleInfos(
        {filter = filters},
        100,
        eligibleVehicles,
        "Population"
    )

    for _, vehicleInfo in ipairs(vehicleInfos) do
        local pcPath = '/vehicles/' .. vehicleInfo.model_key .. '/configurations/' .. vehicleInfo.key .. '.pc'
        table.insert(vehicles, {
            model = vehicleInfo.model_key,
            config = pcPath
        })
    end
    
    return vehicles
end

local function getRandomVehicle(meetType)
    if #carMeetVehicles == 0 then 
        carMeetVehicles = getCarMeetVehicles(meetType)
        if #carMeetVehicles == 0 then
            print("No carmeet vehicles found for type: " .. (meetType and meetType.name or "unknown"))
            return nil
        end
    end
    
    local availableVehicles = {}
    for _, vehicle in ipairs(carMeetVehicles) do
        if not usedConfigs[vehicle.config] then
            table.insert(availableVehicles, vehicle)
        end
    end
    
    if #availableVehicles == 0 then
        print("No unused vehicle configs available")
        return nil
    end
    
    local vehicle = availableVehicles[math.random(#availableVehicles)]
    usedConfigs[vehicle.config] = true
    
    print("Selected vehicle: " .. vehicle.model .. " with config: " .. vehicle.config)
    return vehicle.model, vehicle.config
end

local function spawnVehicleOptimized(spot, meetType, forceVisible)
    local vehicleName, configPath = getRandomVehicle(meetType)
    if not vehicleName then return nil end
    
    local options = {
        config = configPath,
        autoEnterVehicle = false,
        autoFlip = true,
        pos = vec3(spot.pos),
        rot = quat(spot.rot)
    }
    
    local vehicle = core_vehicles.spawnNewVehicle(vehicleName, options)
    
    if vehicle then
        local vehId = vehicle:getID()
        gameplay_traffic.insertTraffic(vehId, true)
        vehicle.playerUsable = false
        vehicle:queueLuaCommand('electrics.setLightsState(1)')
        vehicle:queueLuaCommand('electrics.setIgnitionLevel(1)')
        
        if not forceVisible then
            vehicle:setHidden(true)
            vehicle:queueLuaCommand('obj:setCollisionEnabled(false)')
        end
        
        table.insert(spawnedMeetVehicles, vehId)
        
        return {
            id = vehId,
            pos = vec3(spot.pos),
            visible = forceVisible or false,
            hasCollision = forceVisible or false
        }
    end
    
    return nil
end

local function checkVehicleVisible(playerPos, vehiclePos)
    local startPos = playerPos + vec3(0, 0, 1.5)
    local endPos = vehiclePos + vec3(0, 0, 1)
    local direction = endPos - startPos
    local distance = direction:length()
    
    if distance > VEHICLE_VISIBLE_DISTANCE then
        return false
    end
    
    direction:normalize()
    local hitDistance = castRayStatic(startPos, direction, distance)
    return hitDistance >= distance * 0.95
end

local function updateVehicleVisibility()
    if not meetState.active then return end
    
    local playerVeh = be:getPlayerVehicle(0)
    if not playerVeh then return end
    local playerPos = playerVeh:getPosition()
    
    for i = #spawnedMeetVehicles, 1, -1 do
        local vehId = spawnedMeetVehicles[i]
        local veh = getObjectByID(vehId)
        
        if veh then
            local vehiclePos = veh:getPosition()
            local shouldBeVisible = checkVehicleVisible(playerPos, vehiclePos)
            
            if shouldBeVisible and veh:isHidden() then
                veh:setHidden(false)
                veh:queueLuaCommand('obj:setCollisionEnabled(true)')
            elseif not shouldBeVisible and not veh:isHidden() then
                veh:setHidden(true)
                veh:queueLuaCommand('obj:setCollisionEnabled(false)')
            end
        else
            table.remove(spawnedMeetVehicles, i)
        end
    end
    
    for spotData in pairs(pendingVehicles) do
        local distance = (spotData.pos - playerPos):length()
        if distance <= VEHICLE_SPAWN_DISTANCE then
            local shouldBeVisible = checkVehicleVisible(playerPos, spotData.pos)
            local vehicleData = spawnVehicleOptimized(spotData, spotData.meetType, shouldBeVisible)
            pendingVehicles[spotData] = nil
        end
    end
end

local function onExtensionLoaded()
    print("Carmeets module initialized")
end

local function getCarMeetLocations()
    local locations = {}
    
    local sitePath = gameplay_sites_sitesManager.getCurrentLevelSitesFileByName('carmeet')
    if not sitePath then 
        print("No carmeet sites file found")
        return locations 
    end
    
    local siteData = gameplay_sites_sitesManager.loadSites(sitePath)
    if not siteData then 
        print("Could not load carmeet sites data")
        return locations 
    end

    for _, zone in ipairs(siteData.zones.sorted) do
        local meetName = zone.name
        locations[meetName] = {
            zone = zone,
            parkingSpots = {},
            position = vec3(zone.top.pos),
            tags = zone.customFields.sortedTags
        }

        for _, spot in ipairs(siteData.parkingSpots.sorted) do
            for _, tag in ipairs(spot.customFields.sortedTags) do
                if tag == meetName then
                    table.insert(locations[meetName].parkingSpots, spot)
                end
            end
        end
    end

    carmeetLocations = locations

    return locations
end

local function onWorldReadyState(state)
    if state == 2 and careerActive then
        carmeetLocations = getCarMeetLocations()
        loadCarMeetData()
    end
end

local function startCarMeet(meetName, meetTypeKey, attendanceLevel)
    usedConfigs = {}
    
    cleanupPreviousMeet()
    
    local meets = (not carmeetLocations or next(carmeetLocations) == nil) and getCarMeetLocations() or carmeetLocations
    local meet = meets[meetName]
    if not meet then
        print("Car meet location not found: " .. meetName)
        return
    end
    
    local meetType = getMeetType(meetTypeKey)
    if not meetType then
        print("Meet type not found: " .. meetTypeKey)
        return
    end
    
    meetState.active = true
    meetState.type = meetTypeKey
    meetState.location = meet
    meetState.startTime = os.time()
    meetState.arrivalTime = 0
    meetState.phase = "waiting"
    meetState.flags = {}
    
    local maxSpots = #meet.parkingSpots - 1
    local spotCount
    if attendanceLevel == 1 then
        spotCount = 2
    elseif attendanceLevel == 2 then
        spotCount = math.ceil(maxSpots / 2)
    elseif attendanceLevel == 3 then
        spotCount = maxSpots
    end
    
    spotCount = math.min(spotCount, maxSpots)
    
    carMeetVehicles = getCarMeetVehicles(meetType)
    
    local spawnedVehicles = {}
    
    local availableSpots = deepcopy(meet.parkingSpots)

    meetState.playerSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(be:getPlayerVehicleID(0), availableSpots)
    for i, spot in ipairs(availableSpots) do
        if spot == meetState.playerSpot then
            table.remove(availableSpots, i)
            break
        end
    end

    local options = {
        color = {1, 0.4, 0},
        step = 4,
        renderDecals = true
    }
    core_groundMarkers.setPath(meetState.playerSpot.pos, options)
    
    local playerPos = be:getPlayerVehicle(0):getPosition()
    
    core_jobsystem.create(function(job)
        for i = 1, spotCount do
            local randomIndex = math.random(#availableSpots)
            local spot = availableSpots[randomIndex]
            table.remove(availableSpots, randomIndex)
            
            local distance = (vec3(spot.pos) - playerPos):length()
            
            if distance <= VEHICLE_SPAWN_DISTANCE then
                local forceVisible = checkVehicleVisible(playerPos, vec3(spot.pos))
                local vehicleData = spawnVehicleOptimized(spot, meetType, forceVisible)
                if vehicleData then
                    table.insert(spawnedVehicles, vehicleData)
                end
            else
                local spotData = {
                    pos = vec3(spot.pos),
                    rot = quat(spot.rot),
                    meetType = meetType
                }
                pendingVehicles[spotData] = true
            end
            job.sleep(0.1)
        end
    end)
    
    return
end

local function shouldGenerateNewMeet()
    local currentTime = os.time()
    return (currentTime - lastGenerationTime) >= generationInterval
end

local function checkAvailableMeets()
    if not shouldGenerateNewMeet() then
        return meetData
    end

    local meets = (not carmeetLocations or next(carmeetLocations) == nil) and getCarMeetLocations() or carmeetLocations
    if not meets or tableSize(meets) == 0 then
        return nil
    end

    local meetArray = {}
    for name, data in pairs(meets) do
        table.insert(meetArray, {name = name, data = data})
    end

    local selectedMeet = meetArray[math.random(#meetArray)]
    
    local typeKeys = {}
    for typeKey, _ in pairs(meetTypes) do
        table.insert(typeKeys, typeKey)
    end
    local selectedTypeKey = typeKeys[math.random(#typeKeys)]
    local selectedType = meetTypes[selectedTypeKey]
    
    local selectedTime = selectedType.preferredTimes[math.random(#selectedType.preferredTimes)]
    
    lastGenerationTime = os.time()

    local levelIdentifier = getCurrentLevelIdentifier()
    local preview = "/levels/" .. levelIdentifier .. "/facilities/carmeets/" .. selectedMeet.name .. ".jpg"

    meetData = {
        time = selectedTime,
        location = selectedMeet.name,
        type = selectedTypeKey,
        typeName = selectedType.name,
        description = selectedType.description,
        preview = preview,
        timeWindow = selectedType.timeWindow
    }
    generationInterval = 1800
    return meetData
end

local function rsvpToMeet(level)
    rsvpData = meetData
    rsvpData.attendance = attendanceLevels[level] or 2
    meetData = nil
end

local function updateAttendance(level)
    rsvpData.attendance = attendanceLevels[level] or 2
end

local function decline()
    rsvpData = nil
    meetData = nil
    core_groundMarkers.resetAll()
    cleanupPreviousMeet()
    generationInterval = 120
    lastGenerationTime = os.time()
end

local function cancelRSVP()
    rsvpData = nil
    meetData = nil
    core_groundMarkers.resetAll()
    cleanupPreviousMeet()
    generationInterval = 120
    lastGenerationTime = os.time()
end

local function setRoute()
    local meets = (not carmeetLocations or next(carmeetLocations) == nil) and getCarMeetLocations() or carmeetLocations
    local meet = meets[rsvpData.location]
    if not meet then
        print("Car meet location not found: " .. rsvpData.location)
        return
    end

    local availableSpots = deepcopy(meet.parkingSpots)

    local playerSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(be:getPlayerVehicleID(0), availableSpots)

    local options = {
        color = {1, 0.4, 0},
        step = 4,
        renderDecals = true
    }
    core_groundMarkers.setPath(playerSpot.pos, options)
end

local function checkMeetStart()
    if not rsvpData then return end

    local currentTime = scenetree.tod and scenetree.tod.time or 0
    local timeUntilMeet = math.abs(currentTime - rsvpData.time)
    local timeWindow = rsvpData.timeWindow or 0.01

    if timeUntilMeet <= timeWindow then
        local meet = carmeetLocations[rsvpData.location]
        if meet then
            ui_message("Car meet starting at " .. rsvpData.location, 10, "info", "info")
            startCarMeet(rsvpData.location, rsvpData.type, rsvpData.attendance)
        end
        rsvpData = nil
    end
end

local function onUpdate(dtReal, dtSim, dtRaw)
    if not career_career.isActive() then return end
    
    local currentTime = os.time()
    if currentTime - lastUpdateCheck >= updateInterval then
        lastUpdateCheck = currentTime
        checkMeetStart()
        
        if meetState.active and currentTime % VEHICLE_UPDATE_INTERVAL == 0 then
            updateVehicleVisibility()
        end
        
        if meetState.active and meetState.phase == "waiting" then
            local playerVeh = be:getPlayerVehicle(0)
            if playerVeh and meetState.playerSpot and (playerVeh:getPosition() - meetState.playerSpot.pos):length() < 10 then
                local meetType = meetTypes[meetState.type]
                if not meetType then return end
                
                local reputation = math.floor(math.random() * 100) / 10
                if career_modules_hardcore.isHardcoreMode() then
                    reputation = reputation / 2
                end
                
                reputation = reputation * meetType.baseReputationMultiplier
                reputation = math.max(reputation, 1)

                local message = meetType.actions.onArrival(reputation)
                ui_message(message, 10, "info", "info")
                
                local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(be:getPlayerVehicleID(0))
                if inventoryId then
                    career_modules_inventory.addMeetReputation(inventoryId, reputation)
                end
                core_groundMarkers.resetAll()
                
                meetState.phase = "showcase"
                meetState.arrivalTime = currentTime
                career_saveSystem.saveCurrent()
            end
        end
        
        if meetState.active and meetState.phase == "showcase" then
            local meetType = meetTypes[meetState.type]
            if meetType and currentTime - meetState.arrivalTime > meetType.showcaseDuration then
                if meetType.actions and meetType.actions.onShowcaseEnd then
                    meetType.actions.onShowcaseEnd(meetState)
                end
            end
        end
        
        if meetState.active and meetState.type then
            local meetType = meetTypes[meetState.type]
            if meetType and meetType.onUpdate then
                meetType.onUpdate(meetState, currentTime)
            end
        end
        
        if meetState.active and meetState.phase == "ending" then
            local meetType = meetTypes[meetState.type]
            
            if not meetState.flags.dispersalStarted then
                meetState.flags.vehiclesToLeave = {}
                for _, vehID in ipairs(spawnedMeetVehicles) do
                    table.insert(meetState.flags.vehiclesToLeave, vehID)
                end
                meetState.flags.lastVehicleLeaveTime = currentTime
                meetState.flags.dispersalStarted = true
            end
            
            if #meetState.flags.vehiclesToLeave > 0 and currentTime - meetState.flags.lastVehicleLeaveTime >= MEET_LEAVE_INTERVAL then
                local vehID = table.remove(meetState.flags.vehiclesToLeave, 1)
                local veh = getObjectByID(vehID)
                if veh then
                    veh:queueLuaCommand('ai.setMode("traffic")')
                    veh:queueLuaCommand('ai.setSpeedMode("legal")')
                end
                meetState.flags.lastVehicleLeaveTime = currentTime
            end
            
            if #meetState.flags.vehiclesToLeave == 0 then
                if meetType and meetType.actions and meetType.actions.onLeave then
                    local message = meetType.actions.onLeave()
                    ui_message(message, 10, "info", "info")
                end
                meetState.phase = "cleanup"
            end
        end
        
        if meetState.phase == "cleanup" then
            local playerVeh = be:getPlayerVehicle(0)
            if playerVeh then
                for i = #spawnedMeetVehicles, 1, -1 do
                    local vehID = spawnedMeetVehicles[i]
                    local veh = getObjectByID(vehID)
                    if veh then
                        local distance = (playerVeh:getPosition() - veh:getPosition()):length()
                        if distance > MEET_CLEANUP_DISTANCE then
                            table.remove(spawnedMeetVehicles, i)
                            gameplay_traffic.removeTraffic(vehID)
                            veh:delete()
                        end
                    else
                        table.remove(spawnedMeetVehicles, i)
                    end
                end
            end
            
            if #spawnedMeetVehicles == 0 then
                cleanupPreviousMeet()
            end
        end
    end
end

M.requestRSVPData = function()
    print("requestRSVPData")
    guihooks.trigger('onRSVPData', rsvpData)
end

local function getMeetTypes()
    local types = {}
    for typeKey, meetType in pairs(meetTypes) do
        table.insert(types, {
            key = typeKey,
            name = meetType.name,
            description = meetType.description,
            reputationMultiplier = meetType.baseReputationMultiplier,
            showcaseDuration = meetType.showcaseDuration,
            preferredTimes = meetType.preferredTimes,
            timeWindow = meetType.timeWindow
        })
    end
    return types
end

local function getCurrentMeetType()
    if meetState.active and meetState.type then
        return getMeetType(meetState.type)
    elseif rsvpData and rsvpData.type then
        return getMeetType(rsvpData.type)
    end
    return nil
end

local function getMeetState()
    return meetState
end

M.registerMeetType = function(key, meetTypeData)
    meetTypeData.showcaseDuration = meetTypeData.showcaseDuration or 60
    
    meetTypeData.preferredTimes = meetTypeData.preferredTimes or {0.417, 0.458, 0.500}
    meetTypeData.timeWindow = meetTypeData.timeWindow or 0.02
    
    if not meetTypeData.actions then
        meetTypeData.actions = {}
    end
    if not meetTypeData.actions.onShowcaseEnd then
        meetTypeData.actions.onShowcaseEnd = function(state)
            state.phase = "ending"
            state.flags.dispersalStarted = false
            ui_message("Meet is over, vehicles starting to leave!", 10, "info", "info")
        end
    end
    
    meetTypes[key] = meetTypeData
    print("Registered new meet type: " .. meetTypeData.name)
end

local function onSaveCurrentSaveSlot(currentSavePath)
    if not currentSavePath then return end

    local dirPath = currentSavePath .. "/career/rls_career"
    if not FS:directoryExists(dirPath) then
        FS:directoryCreate(dirPath)
    end

    local data = {
        lastGenerationTime = lastGenerationTime,
        rsvpData = rsvpData
    }
    career_saveSystem.jsonWriteFileSafe(dirPath .. "/" .. saveFile, data, true)
end

local function onCareerActive(active)
    careerActive = active
end

local function openMenu()
    guihooks.trigger('ChangeState', {state = 'carMeets'})
end

local function closeMenu()
    guihooks.trigger('ChangeState', {state = 'play'})
end

M.onExtensionLoaded = onExtensionLoaded
M.getCarMeetLocations = getCarMeetLocations
M.onWorldReadyState = onWorldReadyState
M.onUpdate = onUpdate
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onCareerActive = onCareerActive

M.checkAvailableMeets = checkAvailableMeets
M.rsvpToMeet = rsvpToMeet
M.decline = decline
M.cancelRSVP = cancelRSVP
M.updateAttendance = updateAttendance
M.setRoute = setRoute
M.cleanupPreviousMeet = cleanupPreviousMeet

M.requestRSVPData = M.requestRSVPData
M.openMenu = openMenu
M.closeMenu = closeMenu

M.startCarMeet = startCarMeet

return M