-- Competitive circuit track flow: grid countdown, staging parking, sanctioned dispatch.
local M = {}

M.dependencies = { 'gameplay_events_freeroam_session' }

M.TRACK_RACE_ID = "track"

M.trackFlowState = {
    useAltRoute = false,
    inTrackFlowContext = false,
    sanctionedCareerGoToRaceActive = false,
    sanctionedPoolRefHp = nil,
    sanctionedRaceLapCount = nil,
}

local TRACK_GRID_STAGE_STOP_MPH = 2.5
local TRACK_GRID_PARKING_COMMIT_PADDING_M = 0.25
local TRACK_GRID_AI_SPAWN_WAIT_SEC = 12

local mCompetitiveAwaitingAiSpawn = false
local mTrackGridParkingAiSpawnStarted = false
local mTrackGridAiSpawnWaitDeadline = nil
local mCompetitiveCountdownJobActive = false
local mCompetitiveCountdownCancel = false
local mPlayerStagingSpot = nil

local SANCTIONED_PARKING_UI_PUSH_INTERVAL = 0.2
local SANCTIONED_PARKING_LIVE_HP_REFRESH_INTERVAL = 2
local mSanctionedParkingUiPhase = "hidden"
local mSanctionedParkingUiPushClock = nil
local mSanctionedParkingLiveRefreshClock = nil

local PLAYER_STAGING_SPOT_NAME = "player_stage_track"
local mPlayerStagingCornerMarkers = {}

local function sess()
    return gameplay_events_freeroam_session
end

local core_groundMarkers = nil
do
    local ok, gm = pcall(function() return require('core/groundMarkers') end)
    if ok and gm then core_groundMarkers = gm end
end

local function getStagingSpotHalfExtents(spot)
    if not spot or not spot.scl then return nil end
    local s = spot.scl
    return { (s[1] or 3) * 0.5, (s[2] or 6) * 0.5, (s[3] or 2) * 0.5 }
end

local function isPointInStagingSpot(spot, wx, wy, wz)
    if not spot or not spot.pos or not spot.scl then return false end
    local he = getStagingSpotHalfExtents(spot)
    if not he then return false end
    local px, py, pz = spot.pos[1], spot.pos[2], spot.pos[3]
    local sx, sy, sz = he[1], he[2], he[3]
    local dx, dy, dz = wx - px, wy - py, wz - pz
    if spot.rot and spot.rot[4] then
        local ok, localPt = pcall(function()
            local r = spot.rot
            local invQ = quat(-(r[1] or 0), -(r[2] or 0), -(r[3] or 0), r[4] or 1)
            return invQ * vec3(dx, dy, dz)
        end)
        if ok and localPt then
            return math.abs(localPt.x) <= sx and math.abs(localPt.y) <= sy and math.abs(localPt.z) <= sz
        end
    end
    return math.abs(dx) <= sx and math.abs(dy) <= sy and math.abs(dz) <= sz
end

local function isPointInStagingSpotWithPadding(spot, wx, wy, wz, pad)
    if not spot or not spot.pos or not spot.scl then return false end
    local he = getStagingSpotHalfExtents(spot)
    if not he then return false end
    local p = pad or 0
    local px, py, pz = spot.pos[1], spot.pos[2], spot.pos[3]
    local sx, sy, sz = he[1] + p, he[2] + p, he[3] + p
    local dx, dy, dz = wx - px, wy - py, wz - pz
    if spot.rot and spot.rot[4] then
        local ok, localPt = pcall(function()
            local r = spot.rot
            local invQ = quat(-(r[1] or 0), -(r[2] or 0), -(r[3] or 0), r[4] or 1)
            return invQ * vec3(dx, dy, dz)
        end)
        if ok and localPt then
            return math.abs(localPt.x) <= sx and math.abs(localPt.y) <= sy and math.abs(localPt.z) <= sz
        end
    end
    return math.abs(dx) <= sx and math.abs(dy) <= sy and math.abs(dz) <= sz
end

function M.loadPlayerStagingSpot()
    local levelPath = core_levels.getLevelByName(getCurrentLevelIdentifier())
    if not levelPath then return nil end
    local sitesPath = levelPath.misFilePath .. "/competitiveRaceAI.sites.json"
    local sitesData = jsonReadFile(sitesPath)
    if not sitesData or not sitesData.parkingSpots then return nil end
    for _, spot in ipairs(sitesData.parkingSpots) do
        if spot.name == PLAYER_STAGING_SPOT_NAME then
            return { pos = spot.pos, rot = spot.rot, scl = spot.scl }
        end
    end
    return nil
end

function M.isPlayerInStagingSpot(spot)
    if not spot or not spot.pos or not spot.scl then return false end
    local playerVeh = be:getPlayerVehicle(0)
    if not playerVeh then return false end
    local pos = playerVeh:getPosition()
    return isPointInStagingSpot(spot, pos.x, pos.y, pos.z)
end

local function isPlayerInTrackParkingCommitSpot(spot)
    if not spot or not spot.pos or not spot.scl then return false end
    local playerVeh = be:getPlayerVehicle(0)
    if not playerVeh then return false end
    local pos = playerVeh:getPosition()
    return isPointInStagingSpotWithPadding(spot, pos.x, pos.y, pos.z, TRACK_GRID_PARKING_COMMIT_PADDING_M)
end

function M.isPlayerInTrackParkingCommitArea()
    if not mPlayerStagingSpot then return false end
    return isPlayerInTrackParkingCommitSpot(mPlayerStagingSpot)
end

function M.clearPlayerStagingCornerMarkers()
    for _, obj in ipairs(mPlayerStagingCornerMarkers) do
        pcall(function()
            if obj and obj.delete then obj:delete() end
        end)
    end
    table.clear(mPlayerStagingCornerMarkers)
end

function M.showPlayerStagingCornerMarkers(spot)
    M.clearPlayerStagingCornerMarkers()
    if not spot or not spot.pos or not spot.scl then return end
    if not createObject or not scenetree then return end
    local he = getStagingSpotHalfExtents(spot)
    if not he then return end
    local sx, sy, sz = he[1], he[2], he[3]
    local px, py, pz = spot.pos[1], spot.pos[2], spot.pos[3]
    local spotQuat
    local xVec, yVec, zVec = vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1)
    if spot.rot and spot.rot[4] then
        local ok, q = pcall(function()
            local r = spot.rot
            return quat(r[1] or 0, r[2] or 0, r[3] or 0, r[4] or 1)
        end)
        if ok and q then
            spotQuat = q
            xVec = q * vec3(1, 0, 0)
            yVec = q * vec3(0, 1, 0)
            zVec = q * vec3(0, 0, 1)
        end
    end
    local corners = {
        { px - xVec.x*sx + yVec.x*sy, py - xVec.y*sx + yVec.y*sy, pz - xVec.z*sx + yVec.z*sy },
        { px + xVec.x*sx + yVec.x*sy, py + xVec.y*sx + yVec.y*sy, pz + xVec.z*sx + yVec.z*sy },
        { px + xVec.x*sx - yVec.x*sy, py + xVec.y*sx - yVec.y*sy, pz + xVec.z*sx - yVec.z*sy },
        { px - xVec.x*sx - yVec.x*sy, py - xVec.y*sx - yVec.y*sy, pz - xVec.z*sx - yVec.z*sy },
    }
    local cornerZDeg = { 90, 180, 270, 0 }
    local markerScale = math.min(spot.scl[1] or 3, spot.scl[2] or 6) * 0.2
    if markerScale < 0.15 then markerScale = 0.15 end
    if markerScale > 1.5 then markerScale = 1.5 end
    local baseName = "freeroamTrackFlow_stageCorner_" .. tostring(os and os.time and os.time() or 0) .. "_"
    for i, c in ipairs(corners) do
        local ok, marker = pcall(function()
            local m = createObject("TSStatic")
            if not m then return nil end
            m.shapeName = "art/shapes/interface/position_marker.dae"
            m.scale = vec3(markerScale, markerScale, markerScale)
            m.useInstanceRenderData = true
            m.canSave = false
            if ColorF and ColorF(1, 0.5, 0, 1) and (ColorF(1, 0.5, 0, 1):asLinear4F()) then
                m.instanceColor = ColorF(1, 0.5, 0, 1):asLinear4F()
            else
                m:setField("instanceColor", 0, "1 0.5 0 1")
            end
            local rot = spotQuat
            if quatFromEuler and rot then
                local cornerZ = quatFromEuler(0, 0, math.rad(cornerZDeg[i] or 0))
                rot = rot * cornerZ
            end
            if rot then
                m:setPosRot(c[1], c[2], c[3] + 0.1, rot.x, rot.y, rot.z, rot.w)
            else
                m:setPosRot(c[1], c[2], c[3] + 0.1, 0, 0, 0, 0)
            end
            m:registerObject(baseName .. i)
            return m
        end)
        if ok and marker then
            table.insert(mPlayerStagingCornerMarkers, marker)
        end
    end
end

function M.getPlayerStagingSpot()
    return mPlayerStagingSpot
end

function M.setPlayerStagingSpot(spot)
    mPlayerStagingSpot = spot
end

function M.setPlayerStagingSpotNil()
    mPlayerStagingSpot = nil
end

function M.ensurePlayerStagingSpotLoaded()
    if mPlayerStagingSpot then return end
    local spot = M.loadPlayerStagingSpot()
    if spot then
        M.setPlayerStagingSpot(spot)
    end
end

function M.raceAllowsAiSpawn(race)
    local aiRacers = gameplay_events_freeroam_aiRacers
    if not race or not aiRacers or not aiRacers.getMergedConfigForRace then return false end
    local cfg = aiRacers.getMergedConfigForRace(race)
    if not cfg or cfg.enabled == false then return false end
    if race.spawnSameVehicleAsPlayer or cfg.spawnSameVehicleAsPlayer then return true end
    local n = race.aiCount or cfg.maxSpawnCount or cfg.aiCount
    if type(n) == "number" and n > 0 then return true end
    if type(cfg.vehiclePool) == "table" then return true end
    return false
end

function M.trackRaceForAi()
    local races = sess().races
    if not races or not races.track then return nil end
    if M.trackFlowState.useAltRoute and races.track.altRoute then
        return races.track.altRoute
    end
    return races.track
end

function M.isSanctionedCareerGoToRaceActive()
    return M.trackFlowState.sanctionedCareerGoToRaceActive == true
end

function M.isSanctionedRaceStagingUiActive()
    return mSanctionedParkingUiPhase ~= "hidden"
end

function M.raceUsesSanctionedParkingStaging(raceName)
    return raceName == M.TRACK_RACE_ID
end

function M.shouldBlockFreeroamStagingPractice(raceName)
    if not M.isSanctionedRaceStagingUiActive() then
        return false
    end
    return M.raceUsesSanctionedParkingStaging(raceName)
end

function M.resolveEffectiveStagingRace(raceName, race)
    if M.raceUsesSanctionedParkingStaging(raceName) then
        return M.trackRaceForAi() or race
    end
    return race
end

function M.resolveStagingHudTotalLaps(raceName, sess, hotlapRaceName, effectiveStagingRace, isLapRace)
    if sess.freeroamPracticeStaging then
        return 0
    end
    if hotlapRaceName == raceName then
        return 0
    end
    local base = isLapRace and M.getDisplayTotalLapsForRace(effectiveStagingRace) or 0
    if not M.isSanctionedCareerGoToRaceActive() then
        if M.raceUsesSanctionedParkingStaging(raceName) then
            return 0
        end
        return base
    end
    if M.raceUsesSanctionedParkingStaging(raceName) then
        local sr = gameplay_events_freContracts_sanctionedRacing
        local lc = sr and sr.getSanctionedOfferLapCount and sr.getSanctionedOfferLapCount()
        if lc and lc > 0 then
            return lc
        end
    end
    return base
end

function M.resolveRacingHudTotalLaps(mActiveRaceName, sess, effectiveRace, isLapRace)
    local totalLapsVal = isLapRace and M.getDisplayTotalLapsForRace(effectiveRace) or 0
    if sess.freeroamPracticeStaging then
        return 0
    end
    local sr = gameplay_events_freContracts_sanctionedRacing
    if M.raceUsesSanctionedParkingStaging(mActiveRaceName) and sr and not sr.shouldSuppressFrePayouts() then
        return 0
    end
    return totalLapsVal
end

function M.setSanctionedCareerGoToRaceActive(v)
    M.trackFlowState.sanctionedCareerGoToRaceActive = v == true
end

function M.clearSanctionedCareerGoToRaceActive()
    M.trackFlowState.sanctionedCareerGoToRaceActive = false
end

function M.getDisplayTotalLapsForRace(r)
    local fs = gameplay_events_freeroam_session
    if not (fs and fs.freeroamPracticeStaging) then
        local forced = tonumber(M.trackFlowState.sanctionedRaceLapCount)
        if forced and forced > 0 and r == M.trackRaceForAi() then
            local sr = gameplay_events_freContracts_sanctionedRacing
            if sr and sr.shouldSuppressFrePayouts and sr.shouldSuppressFrePayouts() then
                return math.floor(forced)
            end
        end
    end
    if not r then return 0 end
    local lc = tonumber(r.lapCount)
    if lc and lc > 0 then
        return math.floor(lc)
    end
    local rs = r.session
    local slc = rs and tonumber(rs.lapCount)
    if slc and slc > 0 then
        return math.floor(slc)
    end
    if r.hotlap then return 3 end
    if r.checkpointRoad then return 1 end
    return 0
end

function M.spawnedTrackAiCount()
    local aiRacers = gameplay_events_freeroam_aiRacers
    if not aiRacers or not aiRacers.getSpawnedVehicleIds then return 0 end
    local ids = aiRacers.getSpawnedVehicleIds()
    if not ids then return 0 end
    return #ids
end

function M.resetTrackGridFlowFlags()
    mTrackGridParkingAiSpawnStarted = false
    mCompetitiveAwaitingAiSpawn = false
    mTrackGridAiSpawnWaitDeadline = nil
end

function M.cancelCompetitiveGridFlow()
    mCompetitiveCountdownCancel = true
    mCompetitiveCountdownJobActive = false
    M.resetTrackGridFlowFlags()
    if guihooks and guihooks.trigger then
        guihooks.trigger('ScenarioFlashMessageReset')
    end
    local aiRacers = gameplay_events_freeroam_aiRacers
    if aiRacers and aiRacers.setPlayerFreeze then aiRacers.setPlayerFreeze(false) end
end

function M.clearSanctionedNavigateVisuals()
    M.clearPlayerStagingCornerMarkers()
    local gm = core_groundMarkers
    if not gm then
        local ok, mod = pcall(function() return require('core/groundMarkers') end)
        if ok then gm = mod end
    end
    if gm then
        if gm.resetAll then
            gm.resetAll()
        elseif gm.setPath then
            gm.setPath(nil)
        end
    end
end

function M.leaveTrackFlowAfterRace()
    mSanctionedParkingUiPhase = "hidden"
    mSanctionedParkingUiPushClock = nil
    mSanctionedParkingLiveRefreshClock = nil
    if guihooks and guihooks.trigger then
        guihooks.trigger("SanctionedParkingStagingUi", { visible = false })
    end
    M.trackFlowState.inTrackFlowContext = false
    M.clearSanctionedCareerGoToRaceActive()
    M.trackFlowState.sanctionedPoolRefHp = nil
    M.trackFlowState.sanctionedRaceLapCount = nil
    M.trackFlowState.useAltRoute = false
    M.resetTrackGridFlowFlags()
    M.setPlayerStagingSpotNil()
    M.clearSanctionedNavigateVisuals()
end

function M.isVehicleEligibleForCompetitiveTrack(spawnedId)
    if career_modules_cheats and career_modules_cheats.isCheatsMode and career_modules_cheats.isCheatsMode() then return true end
    if not career_career or not career_career.isActive() then return true end
    local function checkId(id)
        if not id then return false end
        if career_modules_business_businessInventory then
            local b, v = career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId(id)
            if b and v then return true end
        end
        if career_modules_inventory then
            local invId = career_modules_inventory.getInventoryIdFromVehicleId(id)
            if invId then
                local vehicle = career_modules_inventory.getVehicles()[invId]
                if vehicle and not vehicle.loanType then return true end
            end
        end
        return false
    end
    if checkId(spawnedId) then return true end
    local currentId = be and be:getPlayerVehicleID(0)
    if currentId and currentId ~= spawnedId then
        if checkId(currentId) then return true end
    end
    return false
end

local function getVehicleSpeedMph(vehId)
    local speedUnit = sess().speedUnit
    if not vehId or not be or not be.getObjectVelocityXYZ then return 0 end
    local a, b, c = be:getObjectVelocityXYZ(vehId)
    if type(a) == "number" and type(b) == "number" and type(c) == "number" then
        return math.sqrt(a * a + b * b + c * c) * speedUnit
    end
    if type(a) == "number" then
        return math.abs(a) * speedUnit
    end
    if a ~= nil and type(a.length) == "function" then
        return a:length() * speedUnit
    end
    return 0
end

function M.startCompetitiveTrackCountdownAndRace()
    if sess().mActiveRace then return false end
    if mCompetitiveCountdownJobActive then return false end
    if sess().staged ~= M.TRACK_RACE_ID then return false end
    if not M.trackFlowState.inTrackFlowContext then return false end
    if not M.trackFlowState.sanctionedCareerGoToRaceActive then return false end
    M.setPlayerStagingSpotNil()
    M.clearPlayerStagingCornerMarkers()
    if core_groundMarkers and core_groundMarkers.resetAll then core_groundMarkers.resetAll() end
    mCompetitiveCountdownJobActive = true
    mCompetitiveCountdownCancel = false
    local aiRacers = gameplay_events_freeroam_aiRacers
    if aiRacers and aiRacers.setPlayerFreeze then aiRacers.setPlayerFreeze(true) end
    if not core_jobsystem or not core_jobsystem.create then
        mCompetitiveCountdownJobActive = false
        local vid = be and be:getPlayerVehicleID(0)
        local races = sess().races
        if vid and races and races[M.TRACK_RACE_ID] then
            gameplay_events_freeroamEvents.beginFreeroamRace(M.TRACK_RACE_ID, vid)
            return true
        end
        if aiRacers and aiRacers.setPlayerFreeze then aiRacers.setPlayerFreeze(false) end
        return false
    end
    core_jobsystem.create(function(job)
        if mCompetitiveCountdownCancel then
            mCompetitiveCountdownJobActive = false
            if aiRacers and aiRacers.setPlayerFreeze then aiRacers.setPlayerFreeze(false) end
            return
        end
        if guihooks and guihooks.trigger then
            guihooks.trigger('ScenarioFlashMessageReset')
            guihooks.trigger('ScenarioFlashMessage', {{3, 1, "Engine.Audio.playOnce('AudioGui', 'event:UI_Countdown1')", true},
                {2, 1, "Engine.Audio.playOnce('AudioGui', 'event:UI_Countdown2')", true},
                {1, 1, "Engine.Audio.playOnce('AudioGui', 'event:UI_Countdown3')", true}})
        end
        job.sleep(3)
        if mCompetitiveCountdownCancel then
            mCompetitiveCountdownJobActive = false
            if aiRacers and aiRacers.setPlayerFreeze then aiRacers.setPlayerFreeze(false) end
            if guihooks and guihooks.trigger then guihooks.trigger('ScenarioFlashMessageReset') end
            return
        end
        if guihooks and guihooks.trigger then
            guihooks.trigger('ScenarioFlashMessageReset')
            guihooks.trigger('ScenarioFlashMessage', {{"ui.scenarios.go", 1, "Engine.Audio.playOnce('AudioGui', 'event:UI_CountdownGo')", true}})
        end
        job.sleep(0.35)
        mCompetitiveCountdownJobActive = false
        if mCompetitiveCountdownCancel then
            if aiRacers and aiRacers.setPlayerFreeze then aiRacers.setPlayerFreeze(false) end
            return
        end
        local vid = be and be:getPlayerVehicleID(0)
        local races = sess().races
        if vid and races and races[M.TRACK_RACE_ID] then
            gameplay_events_freeroamEvents.beginFreeroamRace(M.TRACK_RACE_ID, vid)
        elseif aiRacers and aiRacers.setPlayerFreeze then
            aiRacers.setPlayerFreeze(false)
        end
    end)
    return true
end

function M.prepareFreeroamAiForTrack(poolReferenceHpOverride, deferCountdown)
    local races = sess().races
    if not races then
        sess().races = gameplay_events_freeroam_utils.loadRaceData()
        races = sess().races
    end
    local raceForAi = M.trackRaceForAi()
    local aiRacers = gameplay_events_freeroam_aiRacers
    if not aiRacers or not raceForAi or not M.raceAllowsAiSpawn(raceForAi) then return end
    if sess().mActiveRace and sess().timerActive then return end
    if mCompetitiveAwaitingAiSpawn then return end
    if M.spawnedTrackAiCount() > 0 then
        mCompetitiveAwaitingAiSpawn = false
        mTrackGridAiSpawnWaitDeadline = nil
        mTrackGridParkingAiSpawnStarted = true
        return
    end
    if aiRacers.clearSpawned then aiRacers.clearSpawned() end
    mTrackGridParkingAiSpawnStarted = true
    mCompetitiveAwaitingAiSpawn = true
    mTrackGridAiSpawnWaitDeadline = os.time() + TRACK_GRID_AI_SPAWN_WAIT_SEC
    local refHp = type(poolReferenceHpOverride) == "number" and poolReferenceHpOverride > 0 and poolReferenceHpOverride or nil
    if not refHp and type(M.trackFlowState.sanctionedPoolRefHp) == "number" and M.trackFlowState.sanctionedPoolRefHp > 0 then
        refHp = M.trackFlowState.sanctionedPoolRefHp
    end
    M.trackFlowState.sanctionedPoolRefHp = nil
    if not refHp and gameplay_events_freContracts_sanctionedRacing and gameplay_events_freContracts_sanctionedRacing.getAiPoolReferenceHp then
        refHp = gameplay_events_freContracts_sanctionedRacing.getAiPoolReferenceHp()
    end
    local sanctionedSpawnCtx = nil
    if gameplay_events_freContracts_sanctionedRacing and gameplay_events_freContracts_sanctionedRacing.getAiSpawnSanctionedContext then
        sanctionedSpawnCtx = gameplay_events_freContracts_sanctionedRacing.getAiSpawnSanctionedContext()
    end
    local function afterAiSpawnCommit()
        mCompetitiveAwaitingAiSpawn = false
        mTrackGridAiSpawnWaitDeadline = nil
        if deferCountdown then return end
        if sess().staged ~= M.TRACK_RACE_ID or sess().mActiveRace then return end
        if M.trackFlowState.inTrackFlowContext and M.trackFlowState.sanctionedCareerGoToRaceActive then
            M.startCompetitiveTrackCountdownAndRace()
        end
    end
    if aiRacers.spawnForStagingWithPlayerHp then
        aiRacers.spawnForStagingWithPlayerHp(M.TRACK_RACE_ID, raceForAi, M.TRACK_RACE_ID, function(spawned)
            local count = tonumber(spawned) or 0
            if count <= 0 then
                log("W", "competitiveTrackFlow", string.format("Sanctioned AI spawn returned %d, retrying with base pool.", count))
                if aiRacers.spawnForStaging then
                    local fallbackCount = tonumber(aiRacers.spawnForStaging(M.TRACK_RACE_ID, raceForAi, M.TRACK_RACE_ID)) or 0
                    if fallbackCount <= 0 then
                        log("W", "competitiveTrackFlow", "Fallback sanctioned AI spawn also returned 0.")
                    end
                end
            end
            afterAiSpawnCommit()
        end, refHp, sanctionedSpawnCtx)
    elseif aiRacers.spawnForStaging then
        local spawned = tonumber(aiRacers.spawnForStaging(M.TRACK_RACE_ID, raceForAi, M.TRACK_RACE_ID)) or 0
        if spawned <= 0 then
            log("W", "competitiveTrackFlow", "Sanctioned AI spawn returned 0.")
        end
        afterAiSpawnCommit()
    else
        afterAiSpawnCommit()
    end
end

function M.tryCommitTrackGridStaging(spawnVehId, opts)
    opts = type(opts) == "table" and opts or {}
    local skipAiPrereq = opts.skipAiPrereq == true
    if not M.trackFlowState.sanctionedCareerGoToRaceActive then return false end
    local raceName = M.TRACK_RACE_ID
    local races = sess().races
    if not races or not races[raceName] then return false end
    if not sess().staged and not sess().mActiveRace and mCompetitiveCountdownJobActive then
        mCompetitiveCountdownJobActive = false
        mCompetitiveCountdownCancel = false
    end
    if not mPlayerStagingSpot or not isPlayerInTrackParkingCommitSpot(mPlayerStagingSpot) then return false end
    if gameplay_events_freeroam_utils.isPlayerInPursuit() then
        gameplay_events_freeroam_utils.displayMessage("You cannot stage for an event while in a pursuit.", 2)
        return false
    end
    local vehicleSpeed = getVehicleSpeedMph(spawnVehId)
    if vehicleSpeed > TRACK_GRID_STAGE_STOP_MPH then
        return false
    end

    local raceForAi = M.trackRaceForAi()
    if raceForAi and M.raceAllowsAiSpawn(raceForAi) and not skipAiPrereq then
        if mCompetitiveAwaitingAiSpawn then
            return false
        end
        if not mTrackGridParkingAiSpawnStarted and M.spawnedTrackAiCount() == 0 then
            return false
        end
    end

    sess().saveGameState = true
    core_gamestate.requestGameState()

    sess().mHotlap = nil
    gameplay_events_freeroamEvents.hideAllFreeroamAssets()
    sess().lapCount = 0

    local allTypesDisabled = false
    local disabledTypes = {}
    if career_economyAdjuster and races[raceName].type then
        local totalTypes = 0
        local disabledCount = 0
        for _, raceType in ipairs(races[raceName].type) do
            totalTypes = totalTypes + 1
            local multiplier = career_economyAdjuster.getEffectiveSectionMultiplier({raceType})
            if multiplier == 0 then
                disabledCount = disabledCount + 1
                table.insert(disabledTypes, raceType)
            end
        end
        allTypesDisabled = totalTypes > 0 and disabledCount == totalTypes
    end

    if allTypesDisabled then
        local typesString = table.concat(disabledTypes, ", ")
        gameplay_events_freeroam_utils.displayMessage(string.format("%s is disabled due to %s multiplier(s) being set to 0.", races[raceName].label, typesString), 5)
        return false
    end

    sess().staged = raceName
    sess().freeroamPracticeStaging = false
    local vehId = spawnVehId
    if career_career and career_career.isActive and career_career.isActive() then
        if career_modules_business_businessInventory and career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId then
            local businessId, vehicleId = career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId(spawnVehId)
            if businessId and vehicleId then
                vehId = career_modules_business_businessInventory.getBusinessVehicleIdentifier(businessId, vehicleId)
            elseif career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId then
                vehId = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
            end
        elseif career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId then
            vehId = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
        end
    end

    local race = races[raceName] or {}
    gameplay_events_freeroam_raceSession.setStagingSubjectId(vehId)
    if gameplay_events_freeroam_raceSession.raceHudApplies(race) then
        gameplay_events_freeroam_raceSession.showFreeroamRaceHud()
    else
        gameplay_events_freeroam_utils.displayStagedMessage(vehId, raceName)
    end
    gameplay_events_freeroam_utils.setActiveLight(raceName, "yellow")

    if not M.startCompetitiveTrackCountdownAndRace() then
        sess().staged = nil
        gameplay_events_freeroam_raceSession.setStagingSubjectId(nil)
        gameplay_events_freeroam_utils.setActiveLight(raceName, "red")
        gameplay_events_freeroam_raceSession.hideFreeroamRaceHud()
        gameplay_events_freeroamEvents.hideStagedFlashMessage()
        return false
    end
    return true
end

local function pushSanctionedParkingGui()
    if not guihooks or not guihooks.trigger then return end
    if mSanctionedParkingUiPhase == "hidden" then
        guihooks.trigger("SanctionedParkingStagingUi", { visible = false })
        return
    end
    guihooks.trigger("SanctionedParkingStagingUi", {
        visible = true,
        payload = M.buildSanctionedParkingUiPayload(),
    })
end

function M.buildSanctionedParkingUiPayload()
    local sr = gameplay_events_freContracts_sanctionedRacing
    local hp, hpSource = nil, nil
    local ar = career_modules_competitiveRace_aiRacers
    if ar and ar.getPlayerVehiclePowerForStagingUi then
        hp, hpSource = ar.getPlayerVehiclePowerForStagingUi()
    elseif ar and ar.getPlayerVehiclePower then
        hp = ar.getPlayerVehiclePower()
        hpSource = "sync"
    end
    local out = {
        phase = mSanctionedParkingUiPhase,
        awaitingSpawn = mCompetitiveAwaitingAiSpawn,
        spawnedAiCount = M.spawnedTrackAiCount(),
        playerHp = hp,
        playerHpSource = hpSource,
    }
    if not sr or not sr.getOfferUiSnapshot then
        return out
    end
    local state = gameplay_events_freContracts_state.getState()
    local now = state and tonumber(state.simTime) or 0
    local snap = sr.getOfferUiSnapshot(now)
    if not snap then
        local raceForAiEarly = M.trackRaceForAi()
        out.requiresAiSpawn = raceForAiEarly and M.raceAllowsAiSpawn(raceForAiEarly) or false
        return out
    end
    out.raceLabel = snap.raceLabel
    out.stageNumber = tonumber(snap.stageNumber) or 1
    out.hpBracketBranch = snap.hpBracketBranch
    out.hpBracketLabel = snap.hpBracketLabel
    out.classHpMin = tonumber(snap.classHpMin)
    out.classHpMax = tonumber(snap.classHpMax)
    out.lapCount = tonumber(snap.lapCount) or 0
    out.payoutFirst = snap.payoutFirst
    out.payoutSecond = snap.payoutSecond
    out.payoutThird = snap.payoutThird
    local raceForAi = M.trackRaceForAi()
    out.requiresAiSpawn = raceForAi and M.raceAllowsAiSpawn(raceForAi) or false
    return out
end

function M.sanctionedParkingAbortStaging()
    if mSanctionedParkingUiPhase == "hidden" then return end
    mSanctionedParkingUiPhase = "hidden"
    mSanctionedParkingUiPushClock = nil
    mSanctionedParkingLiveRefreshClock = nil
    if guihooks and guihooks.trigger then
        guihooks.trigger("SanctionedParkingStagingUi", { visible = false })
    end
    local aiRacers = gameplay_events_freeroam_aiRacers
    if aiRacers and aiRacers.clearSpawned then
        aiRacers.clearSpawned()
    end
    M.cancelCompetitiveGridFlow()
end

function M.clearSanctionedParkingStagingUi()
    mSanctionedParkingUiPhase = "hidden"
    mSanctionedParkingUiPushClock = nil
    mSanctionedParkingLiveRefreshClock = nil
    if guihooks and guihooks.trigger then
        guihooks.trigger("SanctionedParkingStagingUi", { visible = false })
    end
end

function M.sanctionedParkingStageAndSpawn()
    if not M.trackFlowState.sanctionedCareerGoToRaceActive then return false end
    if mSanctionedParkingUiPhase ~= "prompt" then return false end
    if not mPlayerStagingSpot or not isPlayerInTrackParkingCommitSpot(mPlayerStagingSpot) then return false end
    if gameplay_events_freeroam_utils.isPlayerInPursuit() then
        gameplay_events_freeroam_utils.displayMessage("You cannot stage for an event while in a pursuit.", 2)
        return false
    end
    local aiRacers = gameplay_events_freeroam_aiRacers
    if aiRacers and aiRacers.setPlayerFreeze then
        aiRacers.setPlayerFreeze(true)
    end
    mSanctionedParkingUiPhase = "spawned_ready"
    M.prepareFreeroamAiForTrack(nil, true)
    pushSanctionedParkingGui()
    return true
end

function M.sanctionedParkingStartEvent()
    if not M.trackFlowState.sanctionedCareerGoToRaceActive then return false end
    if mSanctionedParkingUiPhase ~= "spawned_ready" then return false end
    local pv = be:getPlayerVehicle(0)
    if not pv then return false end
    local vid = pv:getID()
    if not mPlayerStagingSpot or not isPlayerInTrackParkingCommitSpot(mPlayerStagingSpot) then return false end
    if gameplay_events_freeroam_utils.isPlayerInPursuit() then
        gameplay_events_freeroam_utils.displayMessage("You cannot stage for an event while in a pursuit.", 2)
        return false
    end
    local raceForAi = M.trackRaceForAi()
    if raceForAi and M.raceAllowsAiSpawn(raceForAi) then
        if mCompetitiveAwaitingAiSpawn then
            gameplay_events_freeroam_utils.displayMessage("Wait for AI to finish loading.", 3)
            return false
        end
        if M.spawnedTrackAiCount() == 0 then
            gameplay_events_freeroam_utils.displayMessage("No AI on grid. Try staging again.", 4)
            return false
        end
    end
    mSanctionedParkingUiPhase = "hidden"
    mSanctionedParkingUiPushClock = nil
    mSanctionedParkingLiveRefreshClock = nil
    if guihooks and guihooks.trigger then
        guihooks.trigger("SanctionedParkingStagingUi", { visible = false })
    end
    local ok = M.tryCommitTrackGridStaging(vid, { skipAiPrereq = true })
    if not ok then
        mSanctionedParkingUiPhase = "spawned_ready"
        pushSanctionedParkingGui()
    end
    return ok
end

function M.beamngTrigger_trackBuilding(data, event)
    if not M.isVehicleEligibleForCompetitiveTrack(data.subjectID) then return end
    local aiRacers = gameplay_events_freeroam_aiRacers
    if event == "enter" then
        if not aiRacers or not aiRacers.levelHasAiRacingConfig or not aiRacers.levelHasAiRacingConfig() then return end
        M.trackFlowState.inTrackFlowContext = true
        M.ensurePlayerStagingSpotLoaded()
        sess().saveGameState = true
        core_gamestate.requestGameState()
    elseif event == "exit" then
        if not sess().mActiveRace then
            M.trackFlowState.inTrackFlowContext = false
            M.setPlayerStagingSpotNil()
            if core_groundMarkers and core_groundMarkers.resetAll then core_groundMarkers.resetAll() end
        end
    end
end

function M.onUpdateParkingResolve()
    if mCompetitiveAwaitingAiSpawn and mTrackGridAiSpawnWaitDeadline and os.time() >= mTrackGridAiSpawnWaitDeadline then
        log("W", "competitiveTrackFlow", "AI spawn wait timed out; clearing await flag.")
        mCompetitiveAwaitingAiSpawn = false
        mTrackGridAiSpawnWaitDeadline = nil
        mTrackGridParkingAiSpawnStarted = false
    end
end

function M.onUpdateParkingLoop()
    if not sess().mActiveRace and M.trackFlowState.inTrackFlowContext and M.trackFlowState.sanctionedCareerGoToRaceActive and
        not sess().staged then
        M.ensurePlayerStagingSpotLoaded()
        if not mPlayerStagingSpot then return end
        local pv = be:getPlayerVehicle(0)
        local nowInParking = (pv and mPlayerStagingSpot and isPlayerInTrackParkingCommitSpot(mPlayerStagingSpot)) or false
        if not nowInParking then
            if mSanctionedParkingUiPhase ~= "hidden" then
                M.sanctionedParkingAbortStaging()
            end
            return
        end
        if mSanctionedParkingUiPhase == "hidden" then
            mSanctionedParkingUiPhase = "prompt"
        end
        local clk = (os and os.clock) and os.clock() or 0
        if not mSanctionedParkingLiveRefreshClock or (clk - mSanctionedParkingLiveRefreshClock) >= SANCTIONED_PARKING_LIVE_HP_REFRESH_INTERVAL then
            mSanctionedParkingLiveRefreshClock = clk
            local ar = career_modules_competitiveRace_aiRacers
            if ar and ar.requestStagingUiLivePowerRefresh then
                ar.requestStagingUiLivePowerRefresh()
            end
        end
        if not mSanctionedParkingUiPushClock or (clk - mSanctionedParkingUiPushClock) >= SANCTIONED_PARKING_UI_PUSH_INTERVAL then
            mSanctionedParkingUiPushClock = clk
            pushSanctionedParkingGui()
        end
    end
end

function M.preloadAiPathsForTrack()
    local aiRacers = gameplay_events_freeroam_aiRacers
    if not aiRacers or not aiRacers.preloadPathForRace then return end
    local levelId = getCurrentLevelIdentifier()
    local races = sess().races
    if not levelId or not races or not races.track then return end
    aiRacers.preloadPathForRace(races.track)
    if races.track.altRoute and races.track.altRoute.checkpointRoad then
        aiRacers.preloadPathForRace(races.track.altRoute)
    end
end

function M.getCompetitiveAwaitingAiSpawn()
    return mCompetitiveAwaitingAiSpawn
end

function M.getCompetitiveCountdownJobActive()
    return mCompetitiveCountdownJobActive
end

function M.getTrackGridParkingAiSpawnStarted()
    return mTrackGridParkingAiSpawnStarted
end

function M.setTrackGridParkingAiSpawnStarted(v)
    mTrackGridParkingAiSpawnStarted = v
end

local function onExtensionLoaded()
end

M.onExtensionLoaded = onExtensionLoaded

return M
