-- Movie studio rentals: park a high-value car at a studio stage and get paid while it is away.
-- Studio and stage identities come from facilities; inventory records own the saved rental location.
-- Flow: the offer trigger opens a prompt -> accepting stages that exact stage (route + marker) -> stopping
-- on it pays up front and freezes the car -> walking away hands it over. The studio UI
-- (StudioRentalOverlay.vue) renders the StudioRentalState payload only: a prompt card, a staged-route
-- status chip and short notices (returns). Its actions call acceptOffer / dismissPrompt / dismissNotice.
local M = {}

local activityAccess = require("overhaul/lib/activity/access")
local levelData = require("overhaul/lib/world/levelData")
local statePush = require("overhaul/lib/ui/statePush")
local stageRoute = require("overhaul/lib/activity/routeLease").new()

M.dependencies = {"overhaul_career_garage_inventory"}

local LOG_TAG = "rlsRentals"
local STATE_EVENT = "StudioRentalState"
local MIN_VEHICLE_VALUE = 100000
local MIN_RENTAL_MINUTES = 60
local MAX_RENTAL_MINUTES = 480
local REWARD_VALUE_FRACTION = 0.25
local FULL_DAY_RENTAL_SECONDS = 480 * 60
local PARKED_RELEASE_DISTANCE_M = 15
local STOPPED_SPEED = 1
local AVAILABILITY_CHECK_INTERVAL_S = 60
local MAX_NOTICES = 5

local stagedRental = nil
local vehicleValue = 0
local rentalTime = 0
local studios, stagesByTrigger, studiosByOffer = {}, {}, {}
local availableStudios = {} -- map/studio/stage key -> inventory id
local loadedMap, selectedStage, selectedStudio
local isRented
local frequency = 0
local occupiedStage
local isParked
local pendingOffer -- {vehicleId, studio, stage, seconds, value} while its prompt is open

-- What the studio UI shows. Changed only through the helpers below so every change is published.
local view = {prompt = nil, status = nil, notices = {}}
local nextNoticeId = 0

local function publish()
    local visible = view.prompt ~= nil or view.status ~= nil or #view.notices > 0
    statePush.send(STATE_EVENT, {visible = visible, prompt = view.prompt, status = view.status, notices = view.notices})
end

local function showPrompt(prompt)
    view.prompt = prompt
    publish()
end

local function addNotice(notice)
    nextNoticeId = nextNoticeId + 1
    notice.id = nextNoticeId
    table.insert(view.notices, notice)
    while #view.notices > MAX_NOTICES do table.remove(view.notices, 1) end
    publish()
end

local function rentalReward(value, seconds)
    local vehicleIndex = overhaul_career_economy_globalEconomy.getVehicleMarketIndex() or 1.0
    return math.floor((value * REWARD_VALUE_FRACTION) * (seconds / FULL_DAY_RENTAL_SECONDS) * vehicleIndex)
end

local function stageKey(mapId, studioId, stageId)
    return mapId .. "|" .. studioId .. "|" .. stageId
end

local function loadStudios()
    local mapId = getCurrentLevelIdentifier()
    if loadedMap == mapId then return end
    stageRoute.clear()
    loadedMap = mapId
    studios, stagesByTrigger, studiosByOffer = {}, {}, {}
    selectedStage, selectedStudio, stagedRental, pendingOffer = nil, nil, nil, nil
    occupiedStage, isParked = nil, nil
    view.prompt, view.status = nil, nil
    if not mapId then return end
    for _, definition in ipairs(overhaul_world_facilities.getFacilitiesByType("studioRental", mapId) or {}) do
        if type(definition.id) == "string" and type(definition.name) == "string"
            and type(definition.offerTrigger) == "string" and type(definition.stages) == "table"
            and #definition.stages > 0
            and not studiosByOffer[definition.offerTrigger] then
            local studio = {id = definition.id, name = definition.name, mapId = mapId, offerTrigger = definition.offerTrigger,
                stages = {}, legacyRentalRestore = definition.legacyRentalRestore}
            local stageIds = {}
            for _, stage in ipairs(definition.stages) do
                if type(stage.id) == "string" and type(stage.triggerName) == "string"
                    and not stagesByTrigger[stage.triggerName] and not stageIds[stage.id] then
                    local entry = {id = stage.id, triggerName = stage.triggerName, studio = studio,
                        label = type(stage.label) == "string" and stage.label ~= "" and stage.label or stage.id,
                        key = stageKey(mapId, studio.id, stage.id)}
                    stageIds[stage.id] = true
                    studio.stages[#studio.stages + 1] = entry
                    stagesByTrigger[stage.triggerName] = entry
                else
                    log("W", LOG_TAG, "Ignoring stage without id/trigger in " .. studio.id)
                end
            end
            studios[#studios + 1] = studio
            studiosByOffer[definition.offerTrigger] = studio
        else
            log("W", LOG_TAG, "Ignoring studio without id/name/offer/stages: " .. tostring(definition.id))
        end
    end
    if #studios == 0 then log("I", LOG_TAG, "No studio rental facilities on " .. mapId) end
end

local function firstFreeStudio(studio)
    for _, stage in ipairs(studio.stages) do
        if not availableStudios[stage.key] then return stage end
    end
end

-- Seconds until the first rented stage of a full studio frees up, or nil when unknown.
local function nextStageFreeSeconds(studio)
    local soonest
    for _, stage in ipairs(studio.stages) do
        local occupant = availableStudios[stage.key]
        local seconds = occupant and tonumber(overhaul_career_garage_inventory.getVehicleTimeToAccess(occupant))
        if seconds and seconds > 0 and (not soonest or seconds < soonest) then soonest = seconds end
    end
    return soonest and math.ceil(soonest)
end

local function studioName(location)
    for _, studio in ipairs(studios) do
        if type(location) == "table" and studio.mapId == location.mapId and studio.id == location.studioId then
            return studio.name
        end
    end
end

local function setStudioTriggerHidden(stage, hidden)
    local trigger = scenetree.findObject(stage.triggerName)
    if trigger then trigger:setHidden(hidden) end
    return trigger
end

-- Why a car cannot go to the studio (the UI words each reason), or nil when it can.
local function rentalBlock(vehicle)
    if vehicle.owned ~= true then return "notOwned" end
    if vehicle.loanType then return "loaner" end
    if vehicle.listedForAuction then return "listed" end
    if vehicle.timeToAccess then return "unavailable" end
end

local function canRentVehicle(vehicle)
    return vehicle ~= nil and rentalBlock(vehicle) == nil
end

local function stagedStatus(kind)
    return {kind = kind, studioName = selectedStudio.name, stageLabel = selectedStage.label,
        seconds = rentalTime, payout = rentalReward(vehicleValue, rentalTime)}
end

local function startRental()
    local inventoryId = overhaul_career_garage_inventory.getCurrentVehicle()
    log("D", LOG_TAG, "Starting movie rental for inventory id " .. tostring(inventoryId))
    if not inventoryId or not selectedStage or occupiedStage ~= selectedStage
        or stagedRental ~= be:getPlayerVehicleID(0) or availableStudios[selectedStage.key] then
        return false
    end
    local playerVeh = be:getPlayerVehicle(0)
    if not playerVeh or playerVeh:getVelocity():length() >= STOPPED_SPEED then return false end
    local vehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
    if not canRentVehicle(vehicle) then return false end
    vehicle.studioRentalLocation = {version = 1, mapId = selectedStudio.mapId,
        studioId = selectedStudio.id, stageId = selectedStage.id}
    overhaul_career_garage_inventory.setVehicleDirty(inventoryId)
    availableStudios[selectedStage.key] = inventoryId
    occupiedStage = nil
    setStudioTriggerHidden(selectedStage, true)
    overhaul_career_garage_inventory.delayVehicleAccess(inventoryId, rentalTime, "rented")
    overhaul_career_garage_inventory.addMovieRental(inventoryId)
    stageRoute.clear()

    local reward = rentalReward(vehicleValue, rentalTime)
    overhaul_career_economy_payment.reward({
        money = {
            amount = reward
        }
    }, require("overhaul/lib/finance/metadata").tag({category = "business",
        label = "You rented your vehicle!"
    }, "business", {vehicleId = inventoryId, locationId = selectedStudio.id, locationName = selectedStudio.name}), true)
    view.status = nil
    showPrompt({kind = "started", studioName = selectedStudio.name, vehicleName = vehicle.niceName,
        seconds = rentalTime, payout = reward})
    log("D", LOG_TAG, string.format("Rented inventory id %s for %d s, paid %d", tostring(inventoryId), rentalTime, reward))
    return true
end

local function parkAtStudioStage(data)
    if stagedRental ~= data.subjectID or not selectedStage or data.triggerName ~= selectedStage.triggerName then return end
    if availableStudios[selectedStage.key] then return end
    occupiedStage = selectedStage
    isRented = true
    view.status = stagedStatus("onStage")
    publish()
end

local function offerStudioRental(data, studio)
    local inventoryId = overhaul_career_garage_inventory.getCurrentVehicle()
    local vehicle = inventoryId and overhaul_career_garage_inventory.getVehicles()[inventoryId]
    if not vehicle then return end
    local blocked = rentalBlock(vehicle)
    if blocked then
        showPrompt({kind = "notRentable", reason = blocked, studioName = studio.name, vehicleName = vehicle.niceName})
        return
    end
    local value = overhaul_career_market_valueCalculator.getInventoryVehicleValue(inventoryId)
    if not (value and value > MIN_VEHICLE_VALUE) then
        showPrompt({kind = "tooCheap", studioName = studio.name, vehicleName = vehicle.niceName,
            minValue = MIN_VEHICLE_VALUE, vehicleValue = math.floor(tonumber(value) or 0)})
        return
    end
    local studioStage = firstFreeStudio(studio)
    if not studioStage then
        showPrompt({kind = "studioFull", studioName = studio.name, stageCount = #studio.stages,
            nextFreeSeconds = nextStageFreeSeconds(studio)})
        return
    end
    local seconds = math.random(MIN_RENTAL_MINUTES, MAX_RENTAL_MINUTES) * 60
    pendingOffer = {vehicleId = data.subjectID, studio = studio, stage = studioStage, seconds = seconds, value = value}
    showPrompt({kind = "offer", studioName = studio.name, vehicleName = vehicle.niceName,
        stageLabel = studioStage.label, seconds = seconds, payout = rentalReward(value, seconds)})
end

-- Accepting stages the offered stage: marker shown, route set. Stale offers (another car, prompt gone) are ignored.
local function acceptOffer()
    local offer = pendingOffer
    if not offer or not view.prompt or view.prompt.kind ~= "offer" then return false end
    pendingOffer = nil
    if be:getPlayerVehicleID(0) ~= offer.vehicleId then
        showPrompt(nil)
        return false
    end
    if getCurrentLevelIdentifier() ~= offer.studio.mapId then
        loadStudios()
        publish()
        return false
    end
    local stage = offer.stage
    if availableStudios[stage.key] then
        if firstFreeStudio(offer.studio) then
            showPrompt({kind = "stageTaken", studioName = offer.studio.name})
        else
            showPrompt({kind = "studioFull", studioName = offer.studio.name, stageCount = #offer.studio.stages,
                nextFreeSeconds = nextStageFreeSeconds(offer.studio)})
        end
        return false
    end
    if selectedStage and not availableStudios[selectedStage.key] then setStudioTriggerHidden(selectedStage, true) end
    occupiedStage = nil
    stagedRental = offer.vehicleId
    selectedStage, selectedStudio = stage, offer.studio
    rentalTime, vehicleValue = offer.seconds, offer.value
    local trigger = setStudioTriggerHidden(stage, false)
    stageRoute.clear()
    if trigger then
        stageRoute.set(trigger:getPosition())
    end
    view.prompt = nil
    view.status = stagedStatus("staged")
    publish()
    return true
end

local function dismissPrompt()
    if not view.prompt then return end
    pendingOffer = nil
    showPrompt(nil)
end

local function dismissNotice(id)
    for index, notice in ipairs(view.notices) do
        if notice.id == id then
            table.remove(view.notices, index)
            publish()
            return
        end
    end
end

local function requestState()
    loadStudios()
    publish()
end

local function onBeamNGTrigger(data)
    if data.event == "exit" then
        if pendingOffer and data.subjectID == pendingOffer.vehicleId
            and data.triggerName == pendingOffer.studio.offerTrigger then
            pendingOffer = nil
            showPrompt(nil)
        end
        if stagedRental == data.subjectID and occupiedStage and data.triggerName == occupiedStage.triggerName then
            occupiedStage = nil
            view.status = stagedStatus("staged")
            publish()
        end
        return
    end
    if be:getPlayerVehicleID(0) ~= data.subjectID or data.event ~= "enter" then
        return
    end
    if gameplay_walk.isWalking() then
        return
    end
    if #activityAccess.get().blocking('studioRentals') > 0 then
        return
    end

    loadStudios()
    local stage = stagesByTrigger[data.triggerName]
    local studio = studiosByOffer[data.triggerName]
    if stage then
        parkAtStudioStage(data)
    elseif studio and not (pendingOffer and pendingOffer.vehicleId == data.subjectID)
        and (not stagedRental or data.subjectID ~= stagedRental or selectedStudio ~= studio) then
        offerStudioRental(data, studio)
    end
end

local function releaseParkedVehicle()
    local stagedVeh = stagedRental and getObjectByID(stagedRental)
    local playerVeh = be:getPlayerVehicle(0)
    if not stagedVeh then
        stagedRental = nil
        isParked = nil
    elseif playerVeh and (playerVeh:getPosition() - stagedVeh:getPosition()):length() >= PARKED_RELEASE_DISTANCE_M then
        overhaul_career_garage_inventory.removeVehicleObject(overhaul_career_garage_inventory.getInventoryIdFromVehicleId(
            stagedRental))
        stagedRental = nil
        isParked = nil
        overhaul_career_saveSystem.saveCurrent()
    end
end

-- Returns false when the rest of the update must be skipped.
local function startRentalOnceStopped()
    local playerVeh = be:getPlayerVehicle(0)
    if not playerVeh or stagedRental ~= be:getPlayerVehicleID(0) then
        return false
    end
    if playerVeh:getVelocity():length() < STOPPED_SPEED then
        if startRental() then
            core_vehicleBridge.executeAction(playerVeh, "setFreeze", true)
            isParked = true
        end
    end
    return true
end

local function freeFinishedStudios()
    isRented = false
    for key, occupant in pairs(availableStudios) do
        if occupant then
            local vehicle = overhaul_career_garage_inventory.getVehicles()[occupant]
            local timeToAccess = vehicle and overhaul_career_garage_inventory.getVehicleTimeToAccess(occupant)
            if not timeToAccess or timeToAccess <= 0 then
                availableStudios[key] = nil
                if vehicle then
                    vehicle.studioRentalLocation = nil
                    overhaul_career_garage_inventory.setVehicleDirty(occupant)
                end
            else
                isRented = true
            end
        end
    end
end

local function onUpdate(dtReal, dtSim, dtRaw)
    if isParked then
        releaseParkedVehicle()
    end
    if occupiedStage and not startRentalOnceStopped() then
        return
    end
    if not isRented then
        return
    end
    if frequency and frequency < AVAILABILITY_CHECK_INTERVAL_S then
        frequency = frequency + dtSim
    else
        freeFinishedStudios()
        frequency = 0
    end
end

local function returnUnplaceableRental(inventoryId, vehicle)
    -- Rent is paid in full at start; returning an unplaceable rental owes no further payment.
    local name = studioName(vehicle.studioRentalLocation)
    vehicle.timeToAccess, vehicle.delayReason, vehicle.repairTimeTotal = nil, nil, nil
    vehicle.studioRentalLocation = nil
    overhaul_career_garage_inventory.setVehicleDirty(inventoryId)
    addNotice({kind = "returnedEarly", studioName = name, vehicleName = vehicle.niceName})
end

-- Studio occupancy follows the saved rental delays, so it survives a reload and never leaks between profiles.
local function onCareerActivated()
    stageRoute.clear()
    availableStudios = {}
    loadedMap = nil
    stagedRental, selectedStage, selectedStudio, pendingOffer = nil, nil, nil, nil
    occupiedStage, isParked, isRented = nil, nil, nil
    frequency = 0
    view = {prompt = nil, status = nil, notices = {}}
    loadStudios()
    local vehicles = overhaul_career_garage_inventory.getVehicles() or {}
    local legacyIds = {}
    for inventoryId, vehicle in pairs(vehicles) do
        if vehicle.delayReason == "rented" and (tonumber(vehicle.timeToAccess) or 0) > 0 then
            local location = vehicle.studioRentalLocation
            if type(location) == "table" and location.version == 1 and type(location.mapId) == "string"
                and type(location.studioId) == "string" and type(location.stageId) == "string" then
                local mapId = levelData.resolveAlias("map", location.mapId)
                local studioId = levelData.resolveAlias("studioRental", location.studioId,
                    {levelId = mapId, saveVersion = location.version})
                local stageId = levelData.resolveAlias("studioRentalStage", location.stageId,
                    {levelId = mapId, facilityId = studioId, saveVersion = location.version})
                local locationLoaded = false
                for _, studio in ipairs(studios) do
                    if studio.mapId == mapId and studio.id == studioId then
                        for _, stage in ipairs(studio.stages) do
                            if stage.id == stageId then
                                locationLoaded = true
                                break
                            end
                        end
                        break
                    end
                end
                if locationLoaded then
                    if mapId ~= location.mapId or studioId ~= location.studioId or stageId ~= location.stageId then
                        location.mapId, location.studioId, location.stageId = mapId, studioId, stageId
                        overhaul_career_garage_inventory.setVehicleDirty(inventoryId)
                    end
                    availableStudios[stageKey(mapId, studioId, stageId)] = inventoryId
                    isRented = true
                else
                    returnUnplaceableRental(inventoryId, vehicle)
                end
            else
                legacyIds[#legacyIds + 1] = inventoryId
            end
        elseif vehicle.studioRentalLocation then
            vehicle.studioRentalLocation = nil
            overhaul_career_garage_inventory.setVehicleDirty(inventoryId)
        end
    end
    -- Only a data-declared legacy studio may adopt rentals written before location metadata.
    table.sort(legacyIds, function(a, b) return tostring(a) < tostring(b) end)
    local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
    local career = savePath and jsonReadFile(savePath .. "/career/general.json") or {}
    local ownerMap = levelData.resolveAlias("map", career.level or loadedMap)
    local legacyStudio
    for _, studio in ipairs(studios) do
        if studio.legacyRentalRestore and studio.mapId == ownerMap then
            legacyStudio = studio
            break
        end
    end
    for _, inventoryId in ipairs(legacyIds) do
        local vehicle = vehicles[inventoryId]
        local stage = legacyStudio and firstFreeStudio(legacyStudio)
        if stage then
            availableStudios[stage.key] = inventoryId
            vehicle.studioRentalLocation = {version = 1, mapId = legacyStudio.mapId,
                studioId = legacyStudio.id, stageId = stage.id}
            isRented = true
            overhaul_career_garage_inventory.setVehicleDirty(inventoryId)
        else
            returnUnplaceableRental(inventoryId, vehicle)
        end
    end
    publish()
end

local function cancelStagedRental()
    stageRoute.clear()
    if selectedStage and not availableStudios[selectedStage.key] then setStudioTriggerHidden(selectedStage, true) end
    stagedRental, selectedStage, selectedStudio, occupiedStage, pendingOffer = nil, nil, nil, nil, nil
    if view.status or (view.prompt and view.prompt.kind == "offer") then
        view.status = nil
        if view.prompt and view.prompt.kind == "offer" then view.prompt = nil end
        publish()
    end
end

local function clearSession()
    cancelStagedRental()
    view = {prompt = nil, status = nil, notices = {}}
    publish()
end

local function onOverhaulActive(active)
    if not active then clearSession() end
end

local function onVehicleDestroyed(vehicleId)
    if vehicleId == stagedRental or (pendingOffer and vehicleId == pendingOffer.vehicleId) then
        cancelStagedRental()
    end
end

-- Leaving the staged car before the shoot starts withdraws the offer; a handed-over car (isParked) stays.
local function onVehicleSwitched(_, newId)
    if isParked then return end
    if (stagedRental and newId ~= stagedRental) or (pendingOffer and newId ~= pendingOffer.vehicleId) then
        cancelStagedRental()
    end
end

local function onOverhaulVehicleRemoved(inventoryId)
    for key, occupant in pairs(availableStudios) do
        if tostring(occupant) == tostring(inventoryId) then availableStudios[key] = nil end
    end
end

local function onOverhaulVehicleAccessRestored(inventoryId, reason)
    if reason ~= "rented" then return end
    local vehicle = (overhaul_career_garage_inventory.getVehicles() or {})[inventoryId] or {}
    addNotice({kind = "returned", studioName = studioName(vehicle.studioRentalLocation), vehicleName = vehicle.niceName})
end

M.onBeamNGTrigger = onBeamNGTrigger
M.onCareerActivated = onCareerActivated
M.onClientStartMission = onCareerActivated
M.startRental = startRental
M.acceptOffer = acceptOffer
M.dismissPrompt = dismissPrompt
M.dismissNotice = dismissNotice
M.requestState = requestState
M.onUpdate = onUpdate
M.onOverhaulActive = onOverhaulActive
M.onVehicleDestroyed = onVehicleDestroyed
M.onVehicleSwitched = onVehicleSwitched
M.onOverhaulVehicleRemoved = onOverhaulVehicleRemoved
M.onOverhaulVehicleAccessRestored = onOverhaulVehicleAccessRestored
M.onExtensionUnloaded = clearSession

return M
