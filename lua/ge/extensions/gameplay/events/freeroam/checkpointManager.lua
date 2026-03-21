local M = {}

M.dependencies = { 'gameplay_events_freeroam_session', 'gameplay_events_freContracts_sanctionedRacing' }

local checkpoints = {}
local altCheckpoints = {}
local aiAltCheckpoints = {}
local raceName = nil
local isLoop = false
local mAltRoute = nil
local mRouteLocked = false
local mFixedAltUseMainColors = false
local activeCheckpoints = {}

local race

local function createCheckpoint(index, isAlt)
    local checkpoint
    if isAlt then
        checkpoint = altCheckpoints[index]
    else
        checkpoint = checkpoints[index]
    end
    if not checkpoint then
        log("W", "checkpointManager",
            string.format("Missing %s checkpoint data for race '%s' at index %d.", isAlt and "alt" or "main",
                tostring(raceName), tonumber(index) or -1))
        return
    end
    if not checkpoint.node then
        log("W", "checkpointManager",
            string.format("Checkpoint node missing for race '%s' at index %d.", tostring(raceName), tonumber(index) or -1))
        return
    end

    if not checkpoint.node.width then
        log("W", "checkpointManager",
            string.format("Checkpoint width missing for race '%s' at index %d. Using fallback radius 30.", tostring(raceName),
                tonumber(index) or -1))
        checkpoint.node.width = 30
    end

    local position = vec3(checkpoint.node.x, checkpoint.node.y, checkpoint.node.z)
    local radius = checkpoint.node.width

    local triggerRadius = radius

    checkpoint.object = createObject('BeamNGTrigger')
    checkpoint.object:setPosition(position)
    checkpoint.object:setScale(vec3(triggerRadius, triggerRadius, triggerRadius))
    checkpoint.object.triggerType = 0 -- Use 0 for Sphere type

    -- Naming the trigger according to the new scheme
    local triggerName
    if isAlt then
        triggerName = string.format("fre_checkpoint_%s_alt_%d", raceName, index)
    else
        triggerName = string.format("fre_checkpoint_%s_%d", raceName, index)
    end

    if scenetree.findObject(triggerName) then
        local existingTrigger = scenetree.findObject(triggerName)
        existingTrigger:delete()
    end
    checkpoint.object:registerObject(triggerName)

    --print("Checkpoint " .. index .. " created at: " .. tostring(position) .. " with radius: " .. radius)
    return checkpoint
end

local function createCheckpointMarker(index, alt)
    local checkpoint = alt and altCheckpoints[index] or checkpoints[index]
    if not checkpoint then
        log("W", "checkpointManager",
            string.format("Missing marker checkpoint data for race '%s' at index %d.", tostring(raceName), tonumber(index) or -1))
        return
    end
    if not checkpoint.node then
        log("W", "checkpointManager",
            string.format("Checkpoint marker node missing for race '%s' at index %d.", tostring(raceName), tonumber(index) or -1))
        return
    end

    local marker = createObject('TSStatic')
    marker.shapeName = "art/shapes/interface/checkpoint_marker.dae"

    marker:setPosRot(checkpoint.node.x, checkpoint.node.y, checkpoint.node.z, 0, 0, 0, 0)

    marker.scale = vec3(checkpoint.node.width, checkpoint.node.width, checkpoint.node.width)
    marker.useInstanceRenderData = true
    marker.instanceColor = ColorF(1, 0, 0, 0.5):asLinear4F() -- Default to red

    local markerName = (alt and "alt_" or "") .. "checkpoint_" .. index .. "_marker"
    if scenetree.findObject(markerName) then
        local existingMarker = scenetree.findObject(markerName)
        existingMarker:delete()
    end
    marker:registerObject(markerName)

    checkpoint.marker = marker
    table.insert(activeCheckpoints, checkpoint)
    return checkpoint
end

local function removeCheckpointMarker(index, alt)
    local checkpoint = {}
    if alt then
        checkpoint = altCheckpoints[index]
    else
        checkpoint = checkpoints[index]
    end
    if checkpoint and checkpoint.marker then
        checkpoint.marker:delete()
        checkpoint.marker = nil
    end
    return checkpoint
end

local function removeCheckpoint(index, alt)
    local checkpoint = {}
    if alt then
        checkpoint = altCheckpoints[index]
    else
        checkpoint = checkpoints[index]
    end
    if checkpoint then
        if checkpoint.object then
            checkpoint.object:delete()
            checkpoint.object = nil
        end
        if checkpoint.marker then
            checkpoint.marker:delete()
            checkpoint.marker = nil
        end
        --print("Checkpoint " .. index .. " removed")
    end
    return checkpoint
end

local function createAiAltTrigger(index, checkpointData)
    if not checkpointData or not checkpointData.node or not raceName then return end
    local w = (checkpointData.node.width and checkpointData.node.width > 0) and checkpointData.node.width or 30
    local pos = vec3(checkpointData.node.x, checkpointData.node.y, checkpointData.node.z)
    local triggerName = string.format("fre_checkpoint_%s_ai_alt_%d", raceName, index)
    if scenetree.findObject(triggerName) then
        scenetree.findObject(triggerName):delete()
    end
    local obj = createObject('BeamNGTrigger')
    obj:setPosition(pos)
    obj:setScale(vec3(w, w, w))
    obj.triggerType = 0
    obj:registerObject(triggerName)
    return { object = obj, triggerName = triggerName }
end

local function removeAiAltCheckpoints()
    for i = 1, #aiAltCheckpoints do
        local entry = aiAltCheckpoints[i]
        if entry and entry.object then
            entry.object:delete()
            entry.object = nil
        end
    end
    aiAltCheckpoints = {}
end

local function createCheckpoints(check, altCheck, aiAltCheck, routeOpts)
    routeOpts = routeOpts or {}
    checkpoints = check
    altCheckpoints = altCheck or {}
    removeAiAltCheckpoints()
    if aiAltCheck and type(aiAltCheck) == "table" and #aiAltCheck > 0 then
        for i = 1, #aiAltCheck do
            local entry = createAiAltTrigger(i, aiAltCheck[i])
            if entry then table.insert(aiAltCheckpoints, entry) end
        end
    end

    for i = 1, #checkpoints do
        removeCheckpoint(i)
    end
    if altCheckpoints and #altCheckpoints > 0 then
        for i = 1, #altCheckpoints do
            removeCheckpoint(i, true)
        end
    end

    local omitAltTriggers = routeOpts.omitAltTriggers == true
    local mergeMainStart = tonumber(routeOpts.omitMainBeforeMerge)
    if mergeMainStart and mergeMainStart < 1 then
        mergeMainStart = nil
    end

    for i = 1, #checkpoints do
        if not mergeMainStart or i >= mergeMainStart then
            createCheckpoint(i)
        end
    end

    if not omitAltTriggers and altCheckpoints and #altCheckpoints > 0 then
        for i = 1, #altCheckpoints do
            createCheckpoint(i, true)
        end
    end
    extensions.hook('onFreeroamCheckpointsBuilt', {
        raceName = raceName,
        mainCount = #checkpoints,
        altCount = altCheckpoints and #altCheckpoints or 0,
    })
end

local function resetActiveCheckpoints()
    local checkpoint
    for i = 1, #activeCheckpoints do
        checkpoint = activeCheckpoints[i]
        if checkpoint then
            checkpoint.marker:delete()
            checkpoint.marker = nil
        end
    end
    activeCheckpoints = {}
end

local function enableCheckpoint(checkpointIndex, alt)
    resetActiveCheckpoints()
    local ALT = {alt, alt}
    local index = {checkpointIndex, checkpointIndex + 1}
    if isLoop then
        index = {index[1] % #checkpoints + 1, index[2] % #checkpoints + 1}
    else
        index = {index[1] + 1, index[2] + 1}
    end
    for i = 1, 2 do
        if ALT[i] then
            if #altCheckpoints < index[i] then
                index[i] = race.altRoute.mergeCheckpoints[2] + ((index[i] - 1) - #altCheckpoints)
                ALT[i] = false
            end
        end
    end
    local currentExpectedCheckpoint = index[1]
    local checkpoint = {}
    if ALT[1] then
        checkpoint = altCheckpoints[index[1]]
    else
        checkpoint = checkpoints[index[1]]
    end
    local nextCheckpoint = nil
    local checkpointCount = ALT[2] and #altCheckpoints or #checkpoints
    if checkpointCount > 1 then
        if ALT[2] then
            nextCheckpoint = altCheckpoints[index[2]]
        else
            nextCheckpoint = checkpoints[index[2]]
        end
    end

    if checkpoint then
        if not checkpoint.marker then
            checkpoint = createCheckpointMarker(index[1], ALT[1])
        end
        local currentMainStyle = not ALT[1] or mFixedAltUseMainColors
        if currentMainStyle then
            checkpoint.marker.instanceColor = ColorF(0, 1, 0, 0.7):asLinear4F() -- Green
        else
            checkpoint.marker.instanceColor = ColorF(0, 0, 1, 0.7):asLinear4F() -- Blue
        end

        if not mRouteLocked and race.altRoute and altCheckpoints and race.altRoute.mergeCheckpoints[1] == index[1] then
            if not altCheckpoints[1].marker then
                local altCheckpoint = createCheckpointMarker(1, true)
                if mFixedAltUseMainColors then
                    altCheckpoint.marker.instanceColor = ColorF(0, 1, 0, 0.7):asLinear4F()
                else
                    altCheckpoint.marker.instanceColor = ColorF(0, 0, 1, 0.7):asLinear4F() -- Blue
                end
            end
        end

        if nextCheckpoint then
            if not nextCheckpoint.marker then
                nextCheckpoint = createCheckpointMarker(index[2], ALT[2])
            end
            nextCheckpoint.marker.instanceColor = ColorF(1, 0, 0, 0.5):asLinear4F() -- Red
        end
    end
    return currentExpectedCheckpoint
end

local function removeCheckpoints()
    local function removeCheckpointList(checkpointList)
        if not checkpointList or #checkpointList == 0 then
            return
        end

        for i = 1, #checkpointList do
            local checkpoint = checkpointList[i]
            if checkpoint then
                -- Remove the checkpoint object
                if checkpoint.object then
                    checkpoint.object:delete()
                    checkpoint.object = nil
                end

                -- Remove the checkpoint marker
                if checkpoint.marker then
                    checkpoint.marker:delete()
                    checkpoint.marker = nil
                end
            end
        end

        -- Clear the checkpoint list
        for i = 1, #checkpointList do
            checkpointList[i] = nil
        end
    end

    resetActiveCheckpoints()
    removeAiAltCheckpoints()

    -- Remove main checkpoints
    removeCheckpointList(checkpoints)

    -- Remove alternative checkpoints
    removeCheckpointList(altCheckpoints)

    -- Reset the checkpoint tables
    checkpoints = {}
    altCheckpoints = {}
    race = nil
    mAltRoute = nil
    mRouteLocked = false
    mFixedAltUseMainColors = false
end

local function calculateTotalCheckpoints()
    local mainCount = #checkpoints
    local altCount = altCheckpoints and #altCheckpoints or 0
    local mergePoints = race.altRoute and race.altRoute.mergeCheckpoints or {0, 0}

    -- If the player is on the alt route, adjust total checkpoints accordingly
    local total
    if mAltRoute then
        total = altCount + (mainCount - mergePoints[2] + mergePoints[1])
    else
        total = mainCount
    end

    return total
end

local function setRouteLocked(locked)
    mRouteLocked = locked
end

local function setAltRoute(altRoute)
    mAltRoute = altRoute
end

local function setRace(inputRace, inputRaceName)
    race = inputRace
    raceName = inputRaceName
end

local function getAltCheckpointCount()
    return altCheckpoints and #altCheckpoints or 0
end

local function getAiAltCheckpointCount()
    return aiAltCheckpoints and #aiAltCheckpoints or 0
end

local function notifyCheckpointEntered(payload)
    extensions.hook('onFreeroamCheckpointEntered', payload)
end

function M.onFreeroamSessionStarted(payload)
    if not payload or not payload.checkpointRoad then return end
    local rn = payload.raceName
    local subjectID = payload.subjectID
    local racePayload = payload.race
    if not racePayload then return end

    local session = gameplay_events_freeroam_session
    local processRoad = gameplay_events_freeroam_processRoad
    local circuitRaceAi = gameplay_events_freeroam_circuitRaceAi
    local competitiveTrackFlow = gameplay_events_freeroam_competitiveTrackFlow
    local trackFlowState = competitiveTrackFlow and competitiveTrackFlow.trackFlowState
    local TRACK_RACE_ID = competitiveTrackFlow and competitiveTrackFlow.TRACK_RACE_ID

    circuitRaceAi.resetForRaceBegin()
    processRoad.reset()
    processRoad.setStationaryTimeout(racePayload.timeout)
    local cps, altCps = processRoad.getCheckpoints(racePayload)
    local sr = gameplay_events_freContracts_sanctionedRacing
    local sanctionedCircuit = sr and sr.isSanctionedCircuitRaceActive and sr.isSanctionedCircuitRaceActive() and
        rn == TRACK_RACE_ID
    mFixedAltUseMainColors = false
    local routeOpts = nil
    if sanctionedCircuit then
        routeOpts = {}
        setRouteLocked(true)
        local useAltOffer = sr.isSanctionedCircuitRaceUseAltRoute and sr.isSanctionedCircuitRaceUseAltRoute()
        if useAltOffer then
            mFixedAltUseMainColors = true
            local mc = racePayload.altRoute and racePayload.altRoute.mergeCheckpoints
            local m2 = mc and tonumber(mc[2])
            if m2 and m2 > 0 then
                routeOpts.omitMainBeforeMerge = math.floor(m2)
            end
        else
            routeOpts.omitAltTriggers = true
        end
    else
        setRouteLocked(false)
    end
    createCheckpoints(cps, altCps, nil, routeOpts)
    circuitRaceAi.setWaypointsFromCheckpoints(cps, altCps)

    session.isLoop = processRoad.isLoop()
    session.currCheckpoint = 0
    session.checkpointsHit = 0

    local useAlt = (rn == TRACK_RACE_ID and trackFlowState and trackFlowState.useAltRoute == true
        and trackFlowState.inTrackFlowContext) or false
    if sanctionedCircuit and sr and sr.isSanctionedCircuitRaceUseAltRoute then
        useAlt = sr.isSanctionedCircuitRaceUseAltRoute()
    end
    session.mAltRoute = useAlt
    setAltRoute(useAlt)
    local totalCp = calculateTotalCheckpoints()
    session.totalCheckpoints = totalCp
    session.currentExpectedCheckpoint = enableCheckpoint(0, useAlt)

    local aiRacers = gameplay_events_freeroam_aiRacers
    if aiRacers and aiRacers.getSpawnedVehicleIds and aiRacers.releaseAndDrive then
        local raceForAi = (useAlt and racePayload.altRoute and racePayload.altRoute.checkpointRoad) and racePayload.altRoute or racePayload
        circuitRaceAi.setupAfterAiSpawn(rn, subjectID, totalCp, racePayload, raceForAi)
    end

    gameplay_events_freeroam_raceSession.showFreeroamRaceHud()
end

function M.onFreeroamSessionExiting(payload)
    if not payload or not payload.checkpointRoad then return end
    gameplay_events_freeroam_circuitRaceAi.clearAll()
    removeCheckpoints()
end

local function onExtensionLoaded()
    print("Initializing Checkpoint Manager")
end

M.notifyCheckpointEntered = notifyCheckpointEntered
M.onExtensionLoaded = onExtensionLoaded
M.createCheckpoints = createCheckpoints
M.enableCheckpoint = enableCheckpoint
M.removeCheckpoints = removeCheckpoints
M.setRouteLocked = setRouteLocked
M.setAltRoute = setAltRoute
M.setRace = setRace
M.calculateTotalCheckpoints = calculateTotalCheckpoints
M.getAltCheckpointCount = getAltCheckpointCount
M.getAiAltCheckpointCount = getAiAltCheckpointCount

return M