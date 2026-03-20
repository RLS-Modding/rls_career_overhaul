-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.dependencies = {'gameplay_events_freContracts'}

local processRoad = require('gameplay/events/freeroam/processRoad')
local leaderboardManager = require('gameplay/events/freeroam/leaderboardManager')
local activeAssets = require('gameplay/events/freeroam/activeAssets')
local checkpointManager = require('gameplay/events/freeroam/checkpointManager')
local utils = require('gameplay/events/freeroam/utils')
local pits = require('gameplay/events/freeroam/pits')
local aiRacers = nil
do
    local ok, ar = pcall(function() return require('gameplay/events/freeroam/aiRacers') end)
    if ok and ar then aiRacers = ar end
end
local freConfig = require('gameplay/fre/config')
local Assets = activeAssets.ActiveAssets.new()

local loadedExtensions = {}

local timerActive = false
local mActiveRace
local staged = nil
local in_race_time = 0

local speedUnit = 2.2369362921
local lapCount = 0
local currCheckpoint = nil
local mHotlap = nil
local mAltRoute = nil
local mCurrentRouteName = nil
local mSplitTimes = {}
local isLoop = false
local checkpointsHit = 0
local totalCheckpoints = 0
local currentExpectedCheckpoint = 1
local invalidLap = false

local initialVehicleDamage = 0

local mInventoryId = nil
local newBestSession = false

local maxSpeed = 0
local mTotalRaceTime = 0
local mBestLapThisRun = nil
local mSuppressOffRoadExitUntil = 0

local races = nil
local isReplay = false

local previousGameState = nil
local saveGameState = false

-- State for the Vue "Freeroam Hub" flow: only the competitive circuit event whose race id is COMPETITIVE_HUB_RACE_ID
-- (West Coast `track` + fre_hub_track + player_stage_track + AI). Drag/drift/other freeroam events do not use this.
-- Prefs + level: whether entering fre_hub_* may open the Vue panel. Does not change how races run.
local COMPETITIVE_HUB_RACE_ID = "track"

local hubState = {
    PREFS_FILE = "career/rls_career/freeroam_hub_prefs.json",
    prefs = { autoShow = true, addedOnce = false },
    practiceMode = false,
    useAltRoute = false,
    raceSelected = false,
    showingResult = false,
    showingHistory = false,
    countdownDelay = nil,
    countdownEndTime = nil,
    countdownStartClock = nil,
    stagedAtStart = false,
    pendingStart = nil,
    stagingSubjectID = nil,
    inHubContext = false,  -- True when player entered via fre_hub_track; prevents hub cleanup from affecting other events
    sanctionedPoolRefHp = nil,  -- Passed from phone dispatch; consumed when AI spawn runs at staging enter
    sanctionedRaceLapCount = nil,  -- From phone offer (rolled laps); cleared when race or hub session ends
}

-- AI lap counting and timers: per-vehicle state when a race with AI is active (cleared on exitRace).
local mAiLapState = {}
-- Waypoint-based AI progress: navgraph checkpoint positions (set when race starts with checkpoints); used to update AI laps/checkpoints without triggers.
local mRaceWaypoints = nil
-- Per-AI last "in radius" state for each waypoint index (1..N); used to detect crossing for applyWaypointHit_AI.
local mAiWaypointState = {}
local mAiWaypointUpdateAccum = 0
-- Standings display: diff from leader at last lap or checkpoint boundary (not live); key = "player" or vehId.
local mDiffFromLeaderAtBoundary = {}
-- When result screen is deferred (track + AI): player result saved here; 50s job builds full result and then shows screen.
local mPendingTrackResult = nil
-- Competitive grid: wait for AI spawn callback, then countdown, then beginFreeroamRace (no start-line crossing required).
local mCompetitiveAwaitingAiSpawn = false
local mHubTrackParkingAiSpawnStarted = false
local mWasPlayerInHubTrackParkingSpot = false
local HUB_TRACK_STAGE_STOP_MPH = 2.5
local HUB_TRACK_PARKING_COMMIT_PADDING_M = 0.25
local mHubTrackAiSpawnWaitDeadline = nil
local HUB_TRACK_AI_SPAWN_WAIT_SEC = 12

local function resetHubTrackGridFlowFlags()
    mHubTrackParkingAiSpawnStarted = false
    mWasPlayerInHubTrackParkingSpot = false
end

local mCompetitiveCountdownJobActive = false
local mCompetitiveCountdownCancel = false

local RACE_HUD_PUSH_INTERVAL = 0.1
local frh = {
    shown = false,
    pushClock = nil,
    banner = nil,
    stagingSubjectId = nil,
    lastLapReward = nil,
    completionPayload = nil,
    completionSnapshot = nil,
}

local frs = {
    laps = {},
    raceName = nil,
    displayLabel = nil,
    mainLabel = nil,
    altLabel = nil,
    openLoop = false,
}

local function buildFreSummaryPayload()
    local mainLaps, altLaps = 0, 0
    local totalMoney, totalXp = 0, 0
    local bestMain, bestAlt = nil, nil
    for _, row in ipairs(frs.laps) do
        if row.isAlt then
            altLaps = altLaps + 1
        else
            mainLaps = mainLaps + 1
        end
        totalMoney = totalMoney + (tonumber(row.money) or 0)
        totalXp = totalXp + (tonumber(row.xp) or 0)
        if not row.invalid then
            local t = tonumber(row.time)
            if t then
                if row.isAlt then
                    bestAlt = (bestAlt == nil or t < bestAlt) and t or bestAlt
                else
                    bestMain = (bestMain == nil or t < bestMain) and t or bestMain
                end
            end
        end
    end
    local payload = {
        raceLabel = frs.displayLabel or "",
        mainLabel = frs.mainLabel or frs.displayLabel or "",
        altLabel = frs.altLabel,
        isLoop = frs.openLoop == true,
        totals = {
            laps = #frs.laps,
            mainLaps = mainLaps,
            altLaps = altLaps,
            money = totalMoney,
            xp = totalXp,
        },
        bests = {},
        laps = frs.laps,
    }
    if mainLaps > 0 and bestMain ~= nil then
        payload.bests.mainTime = bestMain
    end
    if altLaps > 0 and bestAlt ~= nil then
        payload.bests.altTime = bestAlt
    end
    return payload
end

-- Forward declaration so applyWaypointHit_AI (and others) can call it; defined later in file.
local snapshotStandingsDeltas
-- Forward declaration for prepareFreeroamAiForTrack (staging / player_stage_track when AI allowed)
local prepareFreeroamAiForTrack

-- Personal grid parking (player_stage_track): reach here to spawn AI; full staging + countdown happens in fre_staging_track once stopped.
local PLAYER_STAGING_SPOT_NAME = "player_stage_track"
local mPlayerStagingSpot = nil  -- { pos = {x,y,z}, scl = {sx,sy,sz} } when driving to stage; cleared when staged or selection cleared

-- Ground markers for navigation (pcall protected)
local core_groundMarkers = nil
do
    local ok, gm = pcall(function() return require('core/groundMarkers') end)
    if ok and gm then core_groundMarkers = gm end
end

-- Load player staging spot from competitiveRaceAI.sites.json (pos, rot, scl = full dimensions, like Rect Marker)
local function loadPlayerStagingSpot()
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

-- Half-extents from JSON scl (scl = full dimensions; white box uses same convention)
local function getStagingSpotHalfExtents(spot)
    if not spot or not spot.scl then return nil end
    local s = spot.scl
    return { (s[1] or 3) * 0.5, (s[2] or 6) * 0.5, (s[3] or 2) * 0.5 }
end

-- True if world point is inside the spot's oriented box (pos, rot, half-extents from scl/2). Spot may have no rot (use AABB).
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

-- Player center-of-mass inside staging box (matches markers; full OOBB was too strict to register).
local function isPlayerInStagingSpot(spot)
    if not spot or not spot.pos or not spot.scl then return false end
    local playerVeh = be:getPlayerVehicle(0)
    if not playerVeh then return false end
    local pos = playerVeh:getPosition()
    return isPointInStagingSpot(spot, pos.x, pos.y, pos.z)
end

local function isPlayerInHubParkingCommitSpot(spot)
    if not spot or not spot.pos or not spot.scl then return false end
    local playerVeh = be:getPlayerVehicle(0)
    if not playerVeh then return false end
    local pos = playerVeh:getPosition()
    return isPointInStagingSpotWithPadding(spot, pos.x, pos.y, pos.z, HUB_TRACK_PARKING_COMMIT_PADDING_M)
end

-- Corner markers for player_stage_track (visible when driving to stage). Cleared when staged or selection cleared.
local mPlayerStagingCornerMarkers = {}

local function clearPlayerStagingCornerMarkers()
    for _, obj in ipairs(mPlayerStagingCornerMarkers) do
        pcall(function()
            if obj and obj.delete then obj:delete() end
        end)
    end
    table.clear(mPlayerStagingCornerMarkers)
end

local function showPlayerStagingCornerMarkers(spot)
    clearPlayerStagingCornerMarkers()
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
    -- Corner positions (same order as Rect Marker: top-left, top-right, bottom-right, bottom-left)
    local corners = {
        { px - xVec.x*sx + yVec.x*sy, py - xVec.y*sx + yVec.y*sy, pz - xVec.z*sx + yVec.z*sy },
        { px + xVec.x*sx + yVec.x*sy, py + xVec.y*sx + yVec.y*sy, pz + xVec.z*sx + yVec.z*sy },
        { px + xVec.x*sx - yVec.x*sy, py + xVec.y*sx - yVec.y*sy, pz + xVec.z*sx - yVec.z*sy },
        { px - xVec.x*sx - yVec.x*sy, py - xVec.y*sx - yVec.y*sy, pz - xVec.z*sx - yVec.z*sy },
    }
    -- Per-corner Z rotation (degrees) so cones face outward like Rect Marker: 90, 180, 270, 0
    local cornerZDeg = { 90, 180, 270, 0 }
    local markerScale = math.min(spot.scl[1] or 3, spot.scl[2] or 6) * 0.2
    if markerScale < 0.15 then markerScale = 0.15 end
    if markerScale > 1.5 then markerScale = 1.5 end
    local baseName = "freeroamHub_stageCorner_" .. tostring(os and os.time and os.time() or 0) .. "_"
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

local function getFreeroamHubPrefsPath()
    if not career_saveSystem or not career_saveSystem.getCurrentSaveSlot then return nil end
    local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()
    if not savePath then return nil end
    return savePath .. "/" .. hubState.PREFS_FILE
end

local function loadFreeroamHubPrefs()
    local path = getFreeroamHubPrefsPath()
    if not path then return end
    local d = jsonReadFile(path)
    if d then
        if d.autoShow ~= nil then hubState.prefs.autoShow = d.autoShow end
        if d.addedOnce ~= nil then hubState.prefs.addedOnce = d.addedOnce end
    end
end

local function saveFreeroamHubPrefs()
    local path = getFreeroamHubPrefsPath()
    if not path or not career_saveSystem or not career_saveSystem.jsonWriteFileSafe then return end
    career_saveSystem.jsonWriteFileSafe(path, hubState.prefs, true)
end

local function competitiveTrackHubUiEnabled()
    if not aiRacers or not aiRacers.levelHasAiRacingConfig or not aiRacers.levelHasAiRacingConfig() then return false end
    loadFreeroamHubPrefs()
    return hubState.prefs.autoShow ~= false
end

local function raceAllowsAiSpawn(race)
    if not race or not aiRacers or not aiRacers.getMergedConfigForRace then return false end
    local cfg = aiRacers.getMergedConfigForRace(race)
    if not cfg or cfg.enabled == false then return false end
    if race.spawnSameVehicleAsPlayer or cfg.spawnSameVehicleAsPlayer then return true end
    local n = race.aiCount or cfg.maxSpawnCount or cfg.aiCount
    if type(n) == "number" and n > 0 then return true end
    if type(cfg.vehiclePool) == "table" then return true end
    return false
end

local function hubTrackRaceForAi()
    if not races or not races.track then return nil end
    if hubState.useAltRoute and races.track.altRoute then
        return races.track.altRoute
    end
    return races.track
end

local function hubTrackSpawnedAiCount()
    if not aiRacers or not aiRacers.getSpawnedVehicleIds then return 0 end
    local ids = aiRacers.getSpawnedVehicleIds()
    if not ids then return 0 end
    return #ids
end

local function getVehicleSpeedMph(vehId)
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

local function getDisplayTotalLapsForRace(r)
    local forced = tonumber(hubState.sanctionedRaceLapCount)
    if forced and forced > 0 and r == hubTrackRaceForAi() then
        return math.floor(forced)
    end
    if not r then return 0 end
    local c = r.lapCount
    if type(c) == "number" and c > 0 then return c end
    if r.hotlap then return 3 end
    if r.checkpointRoad then return 1 end
    return 0
end

local function getGameplayAppContainers()
    if not extensions then return nil end
    local names = { "ui_gameplayAppContainers", "ge_extensions_ui_gameplayAppContainers" }
    for _, n in ipairs(names) do
        local gc = extensions[n]
        if gc and gc.showApp then return gc end
    end
    return nil
end
local function showStagedFlashMessage()
end
local function hideStagedFlashMessage()
    if guihooks and guihooks.trigger then guihooks.trigger("ScenarioFlashMessageClear") end
    local gc = getGameplayAppContainers()
    if gc and gc.hideApp then gc.hideApp("gameplayApps", "flashMessage") gc.hideApp("gameplayApps", "countdown") end
end
local function triggerRaceCountdown()
    hideStagedFlashMessage()
end

local function rewardLabel(raceName, newBestTime)
    local raceLabel = races[raceName].label
    local timeLabel = utils.formatTime(in_race_time)
    local performanceLabel = newBestTime and "New Best Time!" or "Completion"

    local label = string.format("%s - %s: %s", raceLabel, performanceLabel, timeLabel)

    if mAltRoute then
        label = label .. " (Alternative Route)"
    end

    if mHotlap == raceName then
        label = label .. " (Hotlap)"
    end

    return label
end

local function getDriftScore()
    local finalScore = 0
    if gameplay_drift_scoring then
        local scoreData = gameplay_drift_scoring.getScore()
        if scoreData then
            finalScore = scoreData.score or 0
            if scoreData.cachedScore then
                finalScore = finalScore + math.floor(scoreData.cachedScore * scoreData.combo)
            end
            gameplay_drift_general.reset()
        end
    end
    return finalScore
end

local function getRaceLabel()
    local race = races[mActiveRace]
    local raceLabel = race.label

    if mAltRoute then
        raceLabel = race.altRoute.label
    end
    if mHotlap == mActiveRace then
        raceLabel = raceLabel .. " (Hotlap)"
    end
    return raceLabel
end

-- Race label for hub/display only (no "(Hotlap)" suffix).
local function getDisplayRaceLabel()
    local race = races[mActiveRace]
    if not race then return "" end
    local raceLabel = race.label
    if mAltRoute and race.altRoute then
        raceLabel = race.altRoute.label
    end
    return raceLabel or ""
end

local function getBusinessAccountFromVehicle(spawnedVehicleId)
    if not career_career.isActive() or not career_modules_business_businessInventory then
        return nil
    end
    
    local businessId, vehicleId = career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId(spawnedVehicleId)
    if not businessId or not vehicleId then
        return nil
    end
    
    if not career_modules_bank then
        return nil
    end
    
    local businessTypes = {"tuningShop"}
    for _, businessType in ipairs(businessTypes) do
        local businessAccount = career_modules_bank.getBusinessAccount(businessType, businessId)
        if businessAccount then
            return businessAccount, businessType, businessId
        end
    end
    
    return nil
end

local function getRaceDisciplineIds(raceData)
    local disciplineIds = {}
    local seen = {}
    if type(raceData) ~= "table" then
        return disciplineIds
    end
    for _, rawType in ipairs(raceData.type or {}) do
        local disciplineId = freConfig.getDisciplineIdFromType(rawType)
        if disciplineId and not seen[disciplineId] then
            seen[disciplineId] = true
            table.insert(disciplineIds, disciplineId)
        end
    end
    return disciplineIds
end

local function getFreRewardModifiers(disciplineIds)
    local defaultModifiers = {
        moneyMultiplier = 1,
        disciplineMultipliers = {}
    }
    if not gameplay_events_freContracts_race or not gameplay_events_freContracts_race.calculateRewardModifiers then
        return defaultModifiers
    end
    local computed = gameplay_events_freContracts_race.calculateRewardModifiers(disciplineIds or {})
    if type(computed) ~= "table" then
        return defaultModifiers
    end
    computed.moneyMultiplier = tonumber(computed.moneyMultiplier) or 1
    computed.disciplineMultipliers = type(computed.disciplineMultipliers) == "table" and computed.disciplineMultipliers or {}
    return computed
end

local function resolveTierByUnlockLevel(level, unlockCfg)
    local numericLevel = math.max(0, math.floor(tonumber(level) or 0))
    local tiers = unlockCfg or {}
    local selected = "easy"
    if numericLevel >= (tonumber(tiers.medium) or math.huge) then
        selected = "medium"
    end
    if numericLevel >= (tonumber(tiers.hard) or math.huge) then
        selected = "hard"
    end
    return selected
end

local function safeRatio(numerator, denominator)
    local denom = tonumber(denominator) or 0
    if denom <= 0 then
        return 0
    end
    return math.max(0, (tonumber(numerator) or 0) / denom)
end

local function calculateEventPerformanceRatio(eventKind, eventData)
    eventData = eventData or {}
    if eventKind == "topSpeed" then
        local goalSpeed = tonumber(eventData.goalSpeed) or 0
        local baseReward = tonumber(eventData.baseReward) or 0
        local raceTypes = eventData.raceTypes or {}
        local targetReward = utils.topSpeedReward(goalSpeed, baseReward, goalSpeed, raceTypes)
        local actualReward = utils.topSpeedReward(goalSpeed, baseReward, tonumber(eventData.actualSpeed) or 0, raceTypes)
        return safeRatio(actualReward, targetReward)
    elseif eventKind == "drift" then
        local raceStub = {
            bestTime = tonumber(eventData.goalTime) or 0,
            driftGoal = tonumber(eventData.goalDriftScore) or 0,
            reward = tonumber(eventData.baseReward) or 0,
            type = eventData.raceTypes or {}
        }
        local targetReward = utils.driftReward(raceStub, raceStub.bestTime, raceStub.driftGoal)
        local actualReward = utils.driftReward(raceStub, tonumber(eventData.actualTime) or 0, tonumber(eventData.actualDriftScore) or 0)
        return safeRatio(actualReward, targetReward)
    elseif eventKind == "hybrid" then
        local goalTime = tonumber(eventData.goalTime) or 0
        local baseReward = tonumber(eventData.baseReward) or 0
        local damageFactor = tonumber(eventData.damageFactor) or 0
        local raceTypes = eventData.raceTypes or {}
        local targetReward = utils.hybridRaceReward(goalTime, baseReward, goalTime, damageFactor, 0, raceTypes)
        local actualReward = utils.hybridRaceReward(goalTime, baseReward, tonumber(eventData.actualTime) or 0, damageFactor, tonumber(eventData.actualDamagePct) or 0, raceTypes)
        return safeRatio(actualReward, targetReward)
    end
    local goalTime = tonumber(eventData.goalTime) or 0
    local baseReward = tonumber(eventData.baseReward) or 0
    local raceTypes = eventData.raceTypes or {}
    local targetReward = utils.raceReward(goalTime, baseReward, goalTime, raceTypes)
    local actualReward = utils.raceReward(goalTime, baseReward, tonumber(eventData.actualTime) or 0, raceTypes)
    return safeRatio(actualReward, targetReward)
end

local function buildDisciplineXpRewards(disciplineIds, normalizedPerformance, rewardModifiers)
    local rewards = {}
    local breakdown = {}
    local totalXp = 0
    local perDiscipline = (rewardModifiers or {}).disciplineMultipliers or {}
    for _, disciplineId in ipairs(disciplineIds or {}) do
        local skillKey = freConfig.getSkillKey(disciplineId)
        if skillKey then
            local eventXpCfg = freConfig.getEventXpConfig(disciplineId) or {}
            local level = tonumber((perDiscipline[disciplineId] or {}).level) or 0
            local tier = resolveTierByUnlockLevel(level, eventXpCfg.tierUnlockLevels or {})
            local tierCurveCfg = ((eventXpCfg.xpByTier or {})[tier]) or {}
            local baseAmount = 0
            if gameplay_events_freContracts_skills and gameplay_events_freContracts_skills.calculateXpFromTierCurve then
                baseAmount = gameplay_events_freContracts_skills.calculateXpFromTierCurve(tierCurveCfg, normalizedPerformance)
            end
            local xpMultiplier = tonumber((perDiscipline[disciplineId] or {}).xpMultiplier) or 1
            local amount = math.max(0, math.floor(baseAmount * xpMultiplier))
            rewards[skillKey] = {amount = amount}
            breakdown[disciplineId] = {
                skillKey = skillKey,
                tier = tier,
                baseAmount = baseAmount,
                amount = amount,
                xpMultiplier = xpMultiplier,
                normalizedPerformance = tonumber(normalizedPerformance) or 0
            }
            totalXp = totalXp + amount
        end
    end
    return rewards, breakdown, totalXp
end

local function mergeRewardTables(target, source, overwrite, warnOnOverwrite)
    if type(target) ~= "table" or type(source) ~= "table" then
        return
    end
    for key, value in pairs(source) do
        if target[key] ~= nil and not overwrite then
            if warnOnOverwrite then
                log("W", "freeroamEvents", string.format("mergeRewardTables skipped key '%s' (already exists)", tostring(key)))
            end
        else
            target[key] = value
        end
    end
end

local function getFreVehicleModel(vehId)
    if gameplay_events_freContracts_race and gameplay_events_freContracts_race.getCurrentVehicleModel then
        return gameplay_events_freContracts_race.getCurrentVehicleModel(vehId)
    end
    return nil
end

local function notifyFreRaceCompleted(raceName, raceData, raceLabel, finishTime, vehicleId, completionMeta)
    if not career_career.isActive() then
        return
    end
    if not gameplay_events_freContracts_race or not gameplay_events_freContracts_race.onFreeroamRaceCompleted then
        return
    end

    local disciplineIds = completionMeta and completionMeta.disciplineIds or getRaceDisciplineIds(raceData)
    local isAltRoute = mAltRoute == true
    gameplay_events_freContracts_race.onFreeroamRaceCompleted({
        raceId = raceName,
        raceName = raceName,
        raceLabel = raceLabel,
        isAltRoute = isAltRoute,
        raceRouteType = isAltRoute and "alt" or "main",
        disciplineIds = disciplineIds,
        rawTypes = raceData and raceData.type or {},
        finishTime = finishTime,
        lapCount = lapCount,
        isHotlap = mHotlap == raceName,
        invalidLap = completionMeta and completionMeta.invalidLap == true or false,
        vehicleId = vehicleId,
        vehicleModel = getFreVehicleModel(vehicleId),
        resultMetrics = {
            time = finishTime,
            maxSpeed = maxSpeed,
            lapCount = lapCount,
            driftScore = completionMeta and completionMeta.driftScore or 0,
            damagePercentage = completionMeta and completionMeta.damagePercentage or 0,
            normalizedPerformance = completionMeta and completionMeta.normalizedPerformance or 0,
            isAltRoute = isAltRoute,
            isHotlap = mHotlap == raceName,
            invalidLap = completionMeta and completionMeta.invalidLap == true or false
        },
        rewardBreakdown = completionMeta and completionMeta.rewardBreakdown or {}
    })
end

local function payoutRace(completedLapTime)
    if not mActiveRace then
        return 0
    end

    local race = races[mActiveRace]
    local time = race.bestTime
    local lapTime = (completedLapTime ~= nil and completedLapTime >= 0) and completedLapTime or in_race_time
    local reward = race.reward
    local raceLabel = race.label
    local damageFactor = race.damageFactor or 0

    -- Get appropriate time and reward values based on route type
    if mHotlap == mActiveRace then
        time = race.hotlap
    end
    if mAltRoute then
        time = race.altRoute.bestTime
        reward = race.altRoute.reward
        raceLabel = race.altRoute.label
        if mHotlap == mActiveRace then
            time = race.altRoute.hotlap
        end
    end
    if mHotlap == mActiveRace then
        raceLabel = raceLabel .. " (Hotlap)"
    end
    local rewardBaseForPerformance = reward

    -- Calculate damage percentage if damage factor is used
    local damagePercentage = 0
    if damageFactor > 0 then
        local currentDamage = utils.getVehicleDamage()
        local damageTaken = math.max(0, currentDamage - initialVehicleDamage)
        local maxDamage = 100000 -- Default max damage
        
        -- Try to get vehicle value as max damage if in career mode
        if career_career and career_career.isActive() and career_modules_valueCalculator then
            maxDamage = career_modules_valueCalculator.getInventoryVehicleValue(mInventoryId, true)
        end
        
        -- Calculate percentage of damage taken (0 = no damage, 1 = maximum damage)
        damagePercentage = math.min(1, damageTaken / maxDamage)
    end

    -- Calculate scores and rewards
    local driftScore = 0
    if race.topSpeed then
        reward = utils.topSpeedReward(race.topSpeedGoal, reward, maxSpeed, race.type)
    elseif race.driftGoal then
        driftScore = getDriftScore()
        reward = utils.driftReward(races[mActiveRace], time, driftScore)
    elseif damageFactor > 0 then
        reward = utils.hybridRaceReward(time, reward, lapTime, damageFactor, damagePercentage, race.type)
    else
        reward = utils.raceReward(time, reward, lapTime, race.type)
    end

    local normalizedPerformance = 0
    if race.topSpeed then
        normalizedPerformance = calculateEventPerformanceRatio("topSpeed", {
            goalSpeed = race.topSpeedGoal,
            baseReward = rewardBaseForPerformance,
            actualSpeed = maxSpeed,
            raceTypes = race.type
        })
    elseif race.driftGoal then
        normalizedPerformance = calculateEventPerformanceRatio("drift", {
            goalTime = race.driftTargetTime or time,
            goalDriftScore = race.driftGoal,
            baseReward = rewardBaseForPerformance,
            actualTime = in_race_time,
            actualDriftScore = driftScore,
            raceTypes = race.type
        })
    elseif damageFactor > 0 then
        normalizedPerformance = calculateEventPerformanceRatio("hybrid", {
            goalTime = time,
            baseReward = rewardBaseForPerformance,
            actualTime = in_race_time,
            damageFactor = damageFactor,
            actualDamagePct = damagePercentage,
            raceTypes = race.type
        })
    else
        normalizedPerformance = calculateEventPerformanceRatio("time", {
            goalTime = time,
            baseReward = rewardBaseForPerformance,
            actualTime = in_race_time,
            raceTypes = race.type
        })
    end

    -- Handle leaderboard
    local inventoryIdToUse = mInventoryId
    
        -- If mInventoryId is already a business job identifier, use it directly
        -- Otherwise, check if this is a business vehicle (check current player vehicle)
        if mInventoryId and tostring(mInventoryId):match("^business_.+_job_") then
            -- Already a business job identifier, use it as-is
            inventoryIdToUse = mInventoryId
        elseif career_modules_business_businessInventory then
            local playerVehicleId = be:getPlayerVehicleID(0)
            if playerVehicleId then
                local businessId, vehicleId = career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId(playerVehicleId)
                if businessId and vehicleId then
                    local jobId = career_modules_business_businessInventory.getJobIdFromVehicle(businessId, vehicleId)
                    if jobId then
                        inventoryIdToUse = career_modules_business_businessInventory.getBusinessJobIdentifier(businessId, jobId)
                    else
                        inventoryIdToUse = career_modules_business_businessInventory.getBusinessVehicleIdentifier(businessId, vehicleId)
                    end
                elseif mInventoryId and not tostring(mInventoryId):match("^business_") then
                    -- If mInventoryId is not already a business identifier, try to convert it
                    -- This handles the case where the race started with a regular vehicle but we want to check business vehicles
                    inventoryIdToUse = mInventoryId
                end
            end
        end
    
    local leaderboardEntry = leaderboardManager.getLeaderboardEntry(inventoryIdToUse, raceLabel)

    local oldTime = leaderboardEntry and leaderboardEntry.time or 0
    local oldScore = leaderboardEntry and leaderboardEntry.driftScore or 0
    local oldTopSpeedRecord = leaderboardEntry and leaderboardEntry.topSpeed or nil
    local oldDamagePctRecord = leaderboardEntry and leaderboardEntry.damagePercentage and leaderboardEntry.damagePercentage * 100 or nil

    local newEntry = {
        raceName = mActiveRace,
        raceLabel = raceLabel,
        isAltRoute = mAltRoute,
        isHotlap = mHotlap == mActiveRace,
        time = lapTime,
        splitTimes = mSplitTimes,
        driftScore = driftScore,
        inventoryId = inventoryIdToUse,
        damagePercentage = damagePercentage,
        damageFactor = damageFactor,
        topSpeed = maxSpeed,
        reward = reward
    }

    -- Only qualify lap time for leaderboard when lap is completed (not invalid)
    local newBest = false
    if not invalidLap then
        newBest = leaderboardManager.addLeaderboardEntry(newEntry)
    end

    -- Build the base message that's shown regardless of career mode
    local message = invalidLap and "Lap Invalidated\n" or ""

    if race.topSpeed then
        message = message ..
                      string.format("%s\nTop Speed: %.2f mph\nTime: %s", raceLabel, maxSpeed, utils.formatTime(lapTime))
        if oldTime then
            local oldSpeed = leaderboardEntry and leaderboardEntry.topSpeed or 0
            message = message ..
                          string.format("\nPrevious Best Speed: %.2f mph\nPrevious Best Time: %s", oldSpeed,
                    utils.formatTime(oldTime))
        end
    elseif race.driftGoal then
        message = message ..
                      string.format("%s\nDrift Score: %d\nTime: %s", raceLabel, driftScore,
                utils.formatTime(lapTime))
        if oldScore and oldTime then
            message = message ..
                          string.format("\nPrevious Best Score: %d\nPrevious Best Time: %s", oldScore,
                    utils.formatTime(oldTime))
        end
    else
        if newBest and not invalidLap then
            if damageFactor > 0 then
                message = message .. "New Best Score!\n"
            else
                message = message .. "New Best Time!\n"
            end
        end
        
        -- Build basic time information
        if race.hotlap then
            message = message ..
                          string.format("%s\nTime: %s\nLap: %d", raceLabel, utils.formatTime(lapTime), lapCount)
        else
            message = message .. string.format("%s\nTime: %s", raceLabel, utils.formatTime(lapTime))
        end
        
        -- Add damage information for damage-based races
        if damageFactor > 0 then
            message = message .. string.format("\nDamage Taken: %.1f%% | Damage Factor: %.0f%%", 
                damagePercentage * 100, damageFactor * 100)
        end
        
        -- Show previous best information
        if newBest and not invalidLap and oldTime ~= math.huge then
            if damageFactor > 0 then
                local oldDamagePercentage = leaderboardEntry and leaderboardEntry.damagePercentage or 0
                message = message .. string.format("\nPrevious Best Time: %s | Previous Best Damage: %.1f%%", 
                    utils.formatTime(oldTime), oldDamagePercentage * 100)
            else
                message = message .. string.format("\nPrevious Best: %s", utils.formatTime(oldTime))
            end
        end
    end

    local hotlapMessage = ""
    local payoutBonuses = {}
    local hudDisciplineXp = nil
    local hudMoney = nil
    local hudBusinessMoney = nil
    local completionMeta = {
        disciplineIds = getRaceDisciplineIds(race),
        invalidLap = invalidLap == true,
        normalizedPerformance = normalizedPerformance,
        driftScore = driftScore,
        damagePercentage = damagePercentage,
        rewardBreakdown = {},
        skipFreContractProgress = false
    }
    if gameplay_events_freContracts_sanctionedRacing and gameplay_events_freContracts_sanctionedRacing.shouldSuppressFrePayouts() then
        completionMeta.skipFreContractProgress = true
    end
    -- Handle career mode specific rewards
    if career_career.isActive() then
        if completionMeta.skipFreContractProgress then
            reward = 0
            lapCount = invalidLap and 1 or lapCount
            completionMeta.rewardBreakdown = {
                money = { base = 0, multiplier = 1, final = 0 },
                normalizedPerformance = normalizedPerformance,
                disciplineXp = {}
            }
            hudDisciplineXp = 0
            hudMoney = nil
            hudBusinessMoney = nil
        end
    end
    if career_career.isActive() and not completionMeta.skipFreContractProgress then
        if not newBest or mHotlap then
            reward = reward / 2
        end
        reward = invalidLap and 0 or reward
        lapCount = invalidLap and 1 or lapCount
        if race.hotlap then
            local hlMult = utils.hotlapMultiplier(lapCount)
            reward = reward * hlMult
            hotlapMessage = string.format("\nHotlap Multiplier: %.2f", hlMult)
            table.insert(payoutBonuses, { label = "Hotlap multiplier", value = string.format("×%.2f", hlMult) })
        end

        if newBest and not newBestSession then
            -- New Best Bonus
            newBestSession = true
        end

        if newBestSession then
            -- New Best Bonus
            reward = reward * 1.2
            hotlapMessage = hotlapMessage .. "\nNew Best Session Bonus: 20%"
            table.insert(payoutBonuses, { label = "New best session bonus", value = "+20%" })
        end

        if oldTime and (newEntry.time - (oldTime * 0.025) < oldTime) then
            -- In Range Bonus
            reward = reward * 1.05
            hotlapMessage = hotlapMessage .. "\nIn Range Bonus: 5%"
            table.insert(payoutBonuses, { label = "In range bonus", value = "+5%" })
        end

        local baseRewardBeforeFre = reward
        local freModifiers = getFreRewardModifiers(completionMeta.disciplineIds)
        reward = reward * (tonumber(freModifiers.moneyMultiplier) or 1)
        local disciplineXpRewards, disciplineXpBreakdown, totalDisciplineXp = buildDisciplineXpRewards(completionMeta.disciplineIds, normalizedPerformance, freModifiers)
        if career_modules_difficultyMode and career_modules_difficultyMode.scalePaymentRewardData then
            career_modules_difficultyMode.scalePaymentRewardData(disciplineXpRewards, {includeMoney = false})
            totalDisciplineXp = 0
            for _, rewardInfo in pairs(disciplineXpRewards) do
                totalDisciplineXp = totalDisciplineXp + (tonumber(rewardInfo.amount) or 0)
            end
        end
        completionMeta.rewardBreakdown = {
            money = {
                base = baseRewardBeforeFre,
                multiplier = tonumber(freModifiers.moneyMultiplier) or 1,
                final = reward
            },
            normalizedPerformance = normalizedPerformance,
            disciplineXp = disciplineXpBreakdown
        }
        hudDisciplineXp = totalDisciplineXp

        if reward > 0 then
            local playerVehicleId = be:getPlayerVehicleID(0)
            local businessAccount = getBusinessAccountFromVehicle(playerVehicleId)
            
            if businessAccount then
                local businessReward = math.floor(reward * 0.5)
                hudBusinessMoney = businessReward
                local xpReward = {}
                mergeRewardTables(xpReward, disciplineXpRewards)
                
                if next(xpReward) ~= nil then
                    career_modules_payment.reward(xpReward, {
                        label = rewardLabel(mActiveRace, newBest),
                        tags = {"gameplay", "reward", "mission"}
                    }, true)
                end
                
                if career_modules_bank then
                    career_modules_bank.rewardToAccount({
                        money = {
                            amount = businessReward
                        }
                    }, businessAccount.id, "Event Reward", rewardLabel(mActiveRace, newBest))
                end
                
                message = message .. string.format("\nDiscipline XP: %d | Business Reward: $%.2f (50%% to business account)", totalDisciplineXp, businessReward)
            else
                local totalReward = {
                    money = {
                        amount = reward
                    }
                }
                mergeRewardTables(totalReward, disciplineXpRewards)

                career_modules_payment.reward(totalReward, {
                    label = rewardLabel(mActiveRace, newBest),
                    tags = {"gameplay", "reward", "mission"}
                }, true)

                message = message .. string.format("\nDiscipline XP: %d | Reward: $%.2f", totalDisciplineXp, reward)
                hudMoney = reward
            end
            career_saveSystem.saveCurrent()
        end
    end

    local hudCompletionPayload = nil
    if race.checkpointRoad and frh.shown then
        local kind = "time"
        if race.topSpeed then
            kind = "topSpeed"
        elseif race.driftGoal then
            kind = "drift"
        elseif (damageFactor or 0) > 0 then
            kind = "hybrid"
        end
        local headline = nil
        if invalidLap then
            headline = "Lap invalidated"
        elseif newBest and not invalidLap then
            if race.topSpeed then
                headline = "New personal best"
            elseif race.driftGoal then
                headline = "New personal best"
            elseif (damageFactor or 0) > 0 then
                headline = "New Best Score!"
            else
                headline = "New Best Time!"
            end
        else
            headline = "Lap complete"
        end
        local prevTimeShow = nil
        if not invalidLap and type(oldTime) == "number" and oldTime > 0 and oldTime ~= math.huge then
            prevTimeShow = oldTime
        end
        local prevDriftShow = nil
        if not invalidLap and type(oldScore) == "number" and oldScore > 0 then
            prevDriftShow = oldScore
        end
        local prevSpeedShow = nil
        if not invalidLap and type(oldTopSpeedRecord) == "number" and oldTopSpeedRecord > 0 then
            prevSpeedShow = oldTopSpeedRecord
        end
        local prevDmgShow = nil
        if not invalidLap and type(oldDamagePctRecord) == "number" then
            prevDmgShow = oldDamagePctRecord
        end
        hudCompletionPayload = {
            invalidLap = invalidLap == true,
            headline = headline,
            raceTitle = raceLabel,
            kind = kind,
            result = {
                time = lapTime,
                lapIndex = race.hotlap and lapCount or nil,
                topSpeed = race.topSpeed and maxSpeed or nil,
                driftScore = race.driftGoal and driftScore or nil,
                damagePct = (damageFactor > 0) and (damagePercentage * 100) or nil,
                damageFactorPct = (damageFactor > 0) and (damageFactor * 100) or nil,
            },
            previous = {
                time = (not race.topSpeed and not race.driftGoal) and prevTimeShow or nil,
                topSpeed = race.topSpeed and prevSpeedShow or nil,
                driftScore = race.driftGoal and prevDriftShow or nil,
                damagePct = (damageFactor > 0) and prevDmgShow or nil,
            },
            rewards = {
                disciplineXp = hudDisciplineXp,
                money = hudMoney,
                businessMoney = hudBusinessMoney,
            },
            bonuses = payoutBonuses,
        }
    end

    if race.checkpointRoad and frs.raceName == mActiveRace then
        local lapMoney = completionMeta.skipFreContractProgress and 0 or ((tonumber(hudMoney) or 0) + (tonumber(hudBusinessMoney) or 0))
        local lapXp = completionMeta.skipFreContractProgress and 0 or (tonumber(hudDisciplineXp) or 0)
        local cleanLabel = (mAltRoute and race.altRoute and race.altRoute.label) or race.label
        table.insert(frs.laps, {
            index = #frs.laps + 1,
            isAlt = mAltRoute == true,
            time = lapTime,
            money = lapMoney,
            xp = lapXp,
            invalid = invalidLap == true,
            raceLabelShort = cleanLabel,
        })
    end

    local cpHud = race.checkpointRoad and frh.shown
    notifyFreRaceCompleted(mActiveRace, race, raceLabel, in_race_time, be:getPlayerVehicleID(0), completionMeta)
    mActiveRace = nil
    if not cpHud then
        utils.displayMessage(message, 20)
        if hotlapMessage ~= "" then
            ui_message(hotlapMessage, 5, "Hotlap Multiplier")
        end
        return reward
    end
    return reward, hudCompletionPayload
end

-- Simplified payoutRace function for drag races
local function payoutDragRace(raceName, finishTime, finishSpeed, vehId)
    -- Load the leaderboard
    local inventoryIdToUse = vehId
    
    if career_career.isActive() then
        -- Check if this is a business vehicle first
        if career_modules_business_businessInventory then
            local businessId, vehicleId = career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId(vehId)
            if businessId and vehicleId then
                local jobId = career_modules_business_businessInventory.getJobIdFromVehicle(businessId, vehicleId)
                if jobId then
                    inventoryIdToUse = career_modules_business_businessInventory.getBusinessJobIdentifier(businessId, jobId)
                else
                    inventoryIdToUse = career_modules_business_businessInventory.getBusinessVehicleIdentifier(businessId, vehicleId)
                end
            else
                inventoryIdToUse = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
            end
        else
            inventoryIdToUse = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
        end
    end

    local leaderboardEntry = leaderboardManager.getLeaderboardEntry(inventoryIdToUse, races["drag"].label)
    local oldTime = leaderboardEntry and leaderboardEntry.time or 0

    local newEntry = {
        raceLabel = races["drag"].label,
        raceName = raceName,
        time = finishTime,
        splitTimes = mSplitTimes,
        inventoryId = inventoryIdToUse
    }

    local newBestTime = leaderboardManager.addLeaderboardEntry(newEntry)

    if not career_career.isActive() then
        local message = string.format("%s\nTime: %s\nSpeed: %.2f mph", races[raceName].label, utils.formatTime(finishTime),
            finishSpeed)
        utils.displayMessage(message, 10)
        return 0
    end

    -- Get race data
    local raceData = races[raceName]
    local targetTime = raceData.bestTime
    local baseReward = raceData.reward
    local disciplineIds = getRaceDisciplineIds(raceData)
    local normalizedPerformance = calculateEventPerformanceRatio("time", {
        goalTime = targetTime,
        baseReward = baseReward,
        actualTime = finishTime,
        raceTypes = raceData.type
    })

    -- Calculate reward based on performance
    local reward = utils.raceReward(targetTime, baseReward, finishTime, raceData.type)
    if reward <= 0 then
        reward = baseReward / 2 -- Minimum reward for completion
    end

    reward = newBestTime and reward or reward / 2

    local baseRewardBeforeFre = reward
    local freModifiers = getFreRewardModifiers(disciplineIds)
    reward = reward * (tonumber(freModifiers.moneyMultiplier) or 1)
    local disciplineXpRewards, disciplineXpBreakdown, totalDisciplineXp = buildDisciplineXpRewards(disciplineIds, normalizedPerformance, freModifiers)
    if career_modules_difficultyMode and career_modules_difficultyMode.scalePaymentRewardData then
        career_modules_difficultyMode.scalePaymentRewardData(disciplineXpRewards, {includeMoney = false})
        totalDisciplineXp = 0
        for _, rewardInfo in pairs(disciplineXpRewards) do
            totalDisciplineXp = totalDisciplineXp + (tonumber(rewardInfo.amount) or 0)
        end
    end
    local completionMeta = {
        disciplineIds = disciplineIds,
        invalidLap = false,
        normalizedPerformance = normalizedPerformance,
        driftScore = 0,
        damagePercentage = 0,
        rewardBreakdown = {
            money = {
                base = baseRewardBeforeFre,
                multiplier = tonumber(freModifiers.moneyMultiplier) or 1,
                final = reward
            },
            normalizedPerformance = normalizedPerformance,
            disciplineXp = disciplineXpBreakdown
        }
    }

    -- Check if this is a business vehicle
    local businessAccount = getBusinessAccountFromVehicle(vehId)
    
    if businessAccount then
        local businessReward = math.floor(reward * 0.5)
        
        local xpReward = {}
        mergeRewardTables(xpReward, disciplineXpRewards)
        
        local reason = {
            label = raceData.label .. (newBestTime and " - New Best Time!" or " - Completion"),
            tags = {"gameplay", "reward", "drag"}
        }
        
        if next(xpReward) ~= nil then
            career_modules_payment.reward(xpReward, reason, true)
        end
        
        if career_modules_bank then
            career_modules_bank.rewardToAccount({
                money = {
                    amount = businessReward
                }
            }, businessAccount.id, "Event Reward", raceData.label .. (newBestTime and " - New Best Time!" or " - Completion"))
        end
        
        local message = string.format("%s\n%s\nTime: %s\nSpeed: %.2f mph\nDiscipline XP: %d | Business Reward: $%.2f (50%% to business account)",
            newBestTime and "Congratulations! New Best Time!" or "", raceData.label, utils.formatTime(finishTime), finishSpeed,
            totalDisciplineXp, businessReward)
        
        ui_message(message, 20, "Reward")
    else
        -- Prepare total reward
        local totalReward = {
            money = {
                amount = reward
            }
        }
        mergeRewardTables(totalReward, disciplineXpRewards)

        -- Create reason for reward
        local reason = {
            label = raceData.label .. (newBestTime and " - New Best Time!" or " - Completion"),
            tags = {"gameplay", "reward", "drag"}
        }

        -- Process the reward
        career_modules_payment.reward(totalReward, reason, true)

        -- Prepare the completion message
        local message = string.format("%s\n%s\nTime: %s\nSpeed: %.2f mph\nDiscipline XP: %d | Reward: $%.2f",
            newBestTime and "Congratulations! New Best Time!" or "", raceData.label, utils.formatTime(finishTime), finishSpeed,
            totalDisciplineXp, reward)

        -- Display the message
        ui_message(message, 20, "Reward")
    end

    -- Save the leaderboard and game state
    career_saveSystem.saveCurrent()
    notifyFreRaceCompleted(raceName, raceData, raceData.label, finishTime, vehId, completionMeta)

    return reward
end

local function getDifference(raceName, currentCheckpointIndex)
    local raceLabel = getRaceLabel()
    local leaderboardEntry = leaderboardManager.getLeaderboardEntry(mInventoryId, raceLabel)
    if not leaderboardEntry then
        return nil
    end

    local splitTimes = leaderboardEntry.splitTimes

    if not splitTimes or not splitTimes[currentCheckpointIndex] then
        return nil
    end

    -- Calculate the time difference for this split
    local currentSplitDiff
    if not mSplitTimes[currentCheckpointIndex] or not splitTimes[currentCheckpointIndex] then
        return nil
    end

    if currentCheckpointIndex == 1 then
        -- For first checkpoint, compare directly
        currentSplitDiff = mSplitTimes[currentCheckpointIndex] - splitTimes[currentCheckpointIndex]
    else
        -- Check if we have the previous checkpoint times before calculating
        if not mSplitTimes[currentCheckpointIndex - 1] or not splitTimes[currentCheckpointIndex - 1] then
            return nil
        end

        -- For subsequent checkpoints, compare the differences between splits
        local previousBestSplit = splitTimes[currentCheckpointIndex] - splitTimes[currentCheckpointIndex - 1]
        local currentSplit = mSplitTimes[currentCheckpointIndex] - mSplitTimes[currentCheckpointIndex - 1]
        currentSplitDiff = currentSplit - previousBestSplit
    end

    return currentSplitDiff
end

local function formatSplitDifference(diff)
    local sign = diff >= 0 and "+" or "-"
    return string.format("%s%s", sign, utils.formatTime(math.abs(diff)))
end

local function setRaceHudBanner(text, kind, ttlSeconds)
    if not text or text == "" then
        frh.banner = nil
        return
    end
    local ttl = ttlSeconds or 3
    local expireAt = nil
    if ttl > 0 and os and os.clock then
        expireAt = os.clock() + ttl
    end
    frh.banner = { text = text, kind = kind or "info", expireAt = expireAt }
end

local function clearExpiredRaceHudBanner()
    if not frh.banner or not frh.banner.expireAt then return end
    if os and os.clock and os.clock() > frh.banner.expireAt then
        frh.banner = nil
    end
end

local function bannerPayloadForHud()
    clearExpiredRaceHudBanner()
    if not frh.banner then return nil end
    return { text = frh.banner.text, kind = frh.banner.kind }
end

local function raceHudApplies(race)
    return race and race.checkpointRoad
end

local function canBuildRaceHudPayload()
    if not races then return false end
    if frh.completionSnapshot and frh.shown and not mActiveRace then return true end
    if mActiveRace and races[mActiveRace] and raceHudApplies(races[mActiveRace]) then return true end
    if staged and races[staged] and raceHudApplies(races[staged]) then return true end
    return false
end

local function buildFreeroamRaceHudPayload()
    local banner = bannerPayloadForHud()
    if frh.completionSnapshot and frh.shown and not mActiveRace then
        local s = frh.completionSnapshot
        local lastRew = frh.lastLapReward
        frh.lastLapReward = nil
        return {
            phase = "racing",
            raceLabel = s.raceLabel,
            routeName = s.routeName,
            displayLap = s.displayLap,
            totalLaps = s.totalLaps,
            isLapRace = s.isLapRace,
            goalTime = s.goalTime,
            personalBestTime = s.personalBestTime,
            currentLapTime = s.currentLapTime,
            bestLapThisRun = s.bestLapThisRun,
            invalidLap = s.invalidLap,
            totalCheckpoints = s.totalCheckpoints,
            checkpointsHit = 0,
            sectors = {},
            completion = frh.completionPayload,
            banner = banner,
            lastLapReward = lastRew,
        }
    end
    if mActiveRace and races[mActiveRace] and raceHudApplies(races[mActiveRace]) then
        local race = races[mActiveRace]
        local effectiveRace = (mAltRoute and race.altRoute) and race.altRoute or race
        local raceLabelFull = getRaceLabel()
        local displayLabel = getDisplayRaceLabel()
        local lbEntry = mInventoryId and leaderboardManager.getLeaderboardEntry(mInventoryId, raceLabelFull) or {}
        local isLapRace = (effectiveRace.lapCount and effectiveRace.lapCount > 0) or effectiveRace.hotlap
        local totalLapsVal = isLapRace and getDisplayTotalLapsForRace(effectiveRace) or 0
        local displayLapNum = isLapRace and (lapCount + 1) or 1
        local sectors = {}
        if not frh.completionPayload then
            for i = checkpointsHit, 1, -1 do
                local cum = mSplitTimes[i]
                if cum ~= nil then
                    local prev = (i > 1) and mSplitTimes[i - 1] or nil
                    local sectorTime = (prev ~= nil) and (cum - prev) or cum
                    local delta = getDifference(mActiveRace, i)
                    table.insert(sectors, {
                        index = i,
                        cumulativeTime = cum,
                        sectorTime = sectorTime,
                        deltaVsPb = delta,
                    })
                end
            end
        end
        local lastRew = frh.lastLapReward
        frh.lastLapReward = nil
        return {
            phase = "racing",
            raceLabel = displayLabel,
            routeName = mCurrentRouteName,
            displayLap = displayLapNum,
            totalLaps = totalLapsVal,
            isLapRace = isLapRace and true or false,
            goalTime = effectiveRace.bestTime,
            personalBestTime = lbEntry.time,
            currentLapTime = in_race_time,
            bestLapThisRun = mBestLapThisRun,
            invalidLap = invalidLap and true or false,
            totalCheckpoints = totalCheckpoints,
            checkpointsHit = checkpointsHit,
            sectors = sectors,
            completion = frh.completionPayload,
            banner = banner,
            lastLapReward = lastRew,
        }
    end
    if staged and races[staged] and raceHudApplies(races[staged]) then
        local raceName = staged
        local race = races[raceName]
        local effectiveStagingRace = (raceName == COMPETITIVE_HUB_RACE_ID and hubTrackRaceForAi()) or race
        local displayLabel = race.label or raceName
        local invId = frh.stagingSubjectId
        local lbEntry = invId and leaderboardManager.getLeaderboardEntry(invId, displayLabel) or {}
        local isLapRace = (effectiveStagingRace.lapCount and effectiveStagingRace.lapCount > 0) or effectiveStagingRace.hotlap
        local totalLapsVal = isLapRace and getDisplayTotalLapsForRace(effectiveStagingRace) or 0
        local stagingUi = { blocks = {} }
        if invId then
            stagingUi = utils.getStagingHudBreakdown(invId, raceName) or stagingUi
        end
        return {
            phase = "staging",
            raceLabel = displayLabel,
            routeName = nil,
            displayLap = 1,
            totalLaps = totalLapsVal,
            isLapRace = isLapRace and true or false,
            goalTime = effectiveStagingRace.bestTime,
            personalBestTime = lbEntry.time,
            currentLapTime = 0,
            bestLapThisRun = nil,
            invalidLap = false,
            totalCheckpoints = 0,
            checkpointsHit = 0,
            sectors = {},
            staging = stagingUi,
            completion = nil,
            banner = banner,
        }
    end
    return nil
end

local function pushFreeroamRaceHudState(force)
    if not frh.shown or not canBuildRaceHudPayload() then return end
    local now = (os and os.clock) and os.clock() or 0
    if not force and frh.pushClock and (now - frh.pushClock) < RACE_HUD_PUSH_INTERVAL then return end
    frh.pushClock = now
    local payload = buildFreeroamRaceHudPayload()
    if payload and guihooks and guihooks.trigger then
        guihooks.trigger("FreeroamRaceHudState", payload)
    end
end

local function showFreeroamRaceHud()
    if not guihooks or not guihooks.trigger then return end
    guihooks.trigger("FreeroamRaceHudShow")
    frh.shown = true
    frh.pushClock = nil
    pushFreeroamRaceHudState(true)
end

local function hideFreeroamRaceHud()
    frh.shown = false
    frh.pushClock = nil
    frh.banner = nil
    frh.stagingSubjectId = nil
    frh.lastLapReward = nil
    frh.completionPayload = nil
    frh.completionSnapshot = nil
    if guihooks and guihooks.trigger then guihooks.trigger("FreeroamRaceHudHide") end
end

local function pushRaceHudCompletion(completionPayload, raceName, displayLabel, leaderboardLabel, currentLapTime, freezeCard)
    if not completionPayload or type(completionPayload) ~= "table" or not frh.shown then return end
    if not raceName or not races[raceName] or not raceHudApplies(races[raceName]) then return end
    frh.completionPayload = completionPayload
    if freezeCard then
        local race = races[raceName]
        local effectiveRace = (mAltRoute and race.altRoute) and race.altRoute or race
        local isLapRace = (effectiveRace.lapCount and effectiveRace.lapCount > 0) or effectiveRace.hotlap
        local lbEntry = mInventoryId and leaderboardManager.getLeaderboardEntry(mInventoryId, leaderboardLabel or displayLabel) or {}
        frh.completionSnapshot = {
            raceLabel = displayLabel,
            routeName = mCurrentRouteName,
            displayLap = isLapRace and (lapCount + 1) or 1,
            totalLaps = isLapRace and getDisplayTotalLapsForRace(effectiveRace) or 0,
            isLapRace = isLapRace and true or false,
            goalTime = effectiveRace.bestTime,
            personalBestTime = lbEntry.time,
            currentLapTime = currentLapTime,
            bestLapThisRun = mBestLapThisRun,
            invalidLap = invalidLap and true or false,
            totalCheckpoints = totalCheckpoints,
            checkpointsHit = 0,
        }
    else
        frh.completionSnapshot = nil
    end
    pushFreeroamRaceHudState(true)
end

-- Vehicle can open the competitive-track hub zone (fre_hub_*): owned/business, not loan. Non-career / cheats: always true.
local function isVehicleEligibleForCompetitiveTrackHub(spawnedId)
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

-- Returns the display name for the route from race_data.json (label for main, altRoute.label for alt).
local function getRouteDisplayName(race, isAlt)
    if not race then return nil end
    if isAlt and race.altRoute and race.altRoute.label then
        return race.altRoute.label
    end
    return race.label
end

-- True if subjectID is one of the spawned AI race vehicles (for lap counting).
local function isAiSpawnedVehicle(subjectID)
    if not aiRacers or not aiRacers.getSpawnedVehicleIds then return false end
    for _, id in ipairs(aiRacers.getSpawnedVehicleIds()) do
        if id == subjectID then return true end
    end
    return false
end

-- Update AI lap/checkpoint/finish state from waypoint crossing or trigger. Single place for both trigger and navgraph-based detection.
local function applyWaypointHit_AI(vehId, eventType, checkpointIndex, raceTime)
    if not mActiveRace or not mAiLapState[vehId] then return end
    local state = mAiLapState[vehId]
    if state.finished then return end
    if eventType == "start" then
        if state.totalCheckpoints == 0 or state.checkpointsHit >= state.totalCheckpoints then
            local lapTime = raceTime - state.lapStartTime
            table.insert(state.lapTimes, lapTime)
            state.lapCount = state.lapCount + 1
            if state.lapCount >= state.totalLaps then
                state.finished = true
                state.finishTime = raceTime
            else
                state.lapStartTime = raceTime
                state.checkpointsHit = 0
                state.currentExpectedCheckpoint = 1
            end
            snapshotStandingsDeltas()
        elseif checkpointIndex == 1 and state.currentExpectedCheckpoint == 1 then
            state.checkpointsHit = state.checkpointsHit + 1
            state.currentExpectedCheckpoint = state.currentExpectedCheckpoint + 1
            snapshotStandingsDeltas()
        end
        return
    end
    if eventType == "checkpoint" and checkpointIndex and checkpointIndex == state.currentExpectedCheckpoint then
        state.checkpointsHit = state.checkpointsHit + 1
        state.currentExpectedCheckpoint = state.currentExpectedCheckpoint + 1
        snapshotStandingsDeltas()
        return
    end
    if eventType == "finish" then
        state.finished = true
        state.finishTime = raceTime
        snapshotStandingsDeltas()
    end
end

-- Poll AI positions vs navgraph waypoints and apply lap/checkpoint when they cross (same logic as player checkpoints).
local function updateAiWaypointsFromNavgraph()
    if not mActiveRace or not mRaceWaypoints or not mRaceWaypoints.checkpoints or #mRaceWaypoints.checkpoints == 0 then return end
    if not next(mAiLapState) or not aiRacers or not aiRacers.getSpawnedVehicleIds then return end
    local ids = aiRacers.getSpawnedVehicleIds()
    if not ids or #ids == 0 then return end
    local cps = mRaceWaypoints.checkpoints
    for _, vehId in ipairs(ids) do
        local state = mAiLapState[vehId]
        if not state or state.finished then goto continue end
        local obj = be:getObjectByID(vehId)
        if not obj or not obj.getPosition then goto continue end
        local pos = obj:getPosition()
        local px = type(pos) == "table" and (pos.x or pos[1]) or 0
        local py = type(pos) == "table" and (pos.y or pos[2]) or 0
        local pz = type(pos) == "table" and (pos.z or pos[3]) or 0
        local last = mAiWaypointState[vehId]
        if not last then last = { inRadius = {} } end
        local nowInRadius = {}
        for k, wp in ipairs(cps) do
            local dx = (wp.x or 0) - px
            local dy = (wp.y or 0) - py
            local dz = (wp.z or 0) - pz
            local r = (wp.r and wp.r > 0) and wp.r or 30
            nowInRadius[k] = (dx * dx + dy * dy + dz * dz) <= (r * r)
        end
        for k, inNow in ipairs(nowInRadius) do
            local wasIn = last.inRadius and last.inRadius[k]
            if inNow and not wasIn then
                if k == 1 then
                    applyWaypointHit_AI(vehId, "start", 1, in_race_time)
                else
                    applyWaypointHit_AI(vehId, "checkpoint", k, in_race_time)
                end
            end
        end
        mAiWaypointState[vehId] = { inRadius = nowInRadius }
        ::continue::
    end
end

-- Snapshot standings at current moment and store per-vehicle diff from leader for display (lap/checkpoint boundary only, not live).
snapshotStandingsDeltas = function()
    if not mActiveRace or not next(mAiLapState) then return end
    local race = races[mActiveRace]
    local effectiveRace = (mAltRoute and race and race.altRoute) and race.altRoute or race
    local combined = {}
    local playerTotalTime = (mTotalRaceTime or 0) + in_race_time
    table.insert(combined, {
        key = "player",
        isPlayer = true,
        lapCount = lapCount,
        checkpointsHit = checkpointsHit or 0,
        currentLapTime = in_race_time,
        finished = false,
        finishTime = nil,
        totalTime = playerTotalTime,
    })
    local aiIds = aiRacers and aiRacers.getSpawnedVehicleIds() or {}
    for i, vehId in ipairs(aiIds) do
        local s = mAiLapState[vehId]
        if s then
            local currentLapTime = (not s.finished) and (in_race_time - s.lapStartTime) or nil
            local aiTotal = s.finishTime
            if not aiTotal then
                if s.lapTimes and #s.lapTimes > 0 then
                    aiTotal = 0
                    for _, t in ipairs(s.lapTimes) do aiTotal = aiTotal + t end
                    aiTotal = aiTotal + (in_race_time - s.lapStartTime)
                else
                    aiTotal = in_race_time - s.lapStartTime
                end
            end
            table.insert(combined, {
                key = vehId,
                isPlayer = false,
                lapCount = s.lapCount,
                checkpointsHit = s.checkpointsHit or 0,
                currentLapTime = currentLapTime or 0,
                finished = s.finished,
                finishTime = s.finishTime,
                totalTime = aiTotal or 0,
            })
        end
    end
    table.sort(combined, function(a, b)
        if a.lapCount ~= b.lapCount then return a.lapCount > b.lapCount end
        if a.finished ~= b.finished then return a.finished end
        if a.finished and b.finished then
            local at, bt = a.finishTime or 0, b.finishTime or 0
            if at ~= bt then return at < bt end
        end
        if a.checkpointsHit ~= b.checkpointsHit then return a.checkpointsHit > b.checkpointsHit end
        return (a.currentLapTime or 0) > (b.currentLapTime or 0)
    end)
    local leaderTime = (#combined > 0 and combined[1].totalTime) and combined[1].totalTime or 0
    for _, e in ipairs(combined) do
        mDiffFromLeaderAtBoundary[e.key] = (e.totalTime or 0) - leaderTime
    end
end

-- Build AI lap state for display (hub or getAiLapState). Returns { inRaceTime, leaderTime, vehicles = { player + AI with place, totalTime, diffFromLeader }, ... }.
-- [AI-PLACE-LUA-1] begin: compute place by position (player + AI sorted by laps, then finished/finishTime, then checkpoints, then currentLapTime)
local function getAiLapStateForDisplay()
    if not mActiveRace or not next(mAiLapState) then return nil end
    local race = races[mActiveRace]
    local effectiveRace = (mAltRoute and race and race.altRoute) and race.altRoute or race
    local totalLaps = getDisplayTotalLapsForRace(effectiveRace)
    if totalLaps < 1 then totalLaps = 3 end
    local combined = {}
    -- Player total time so far
    local playerTotalTime = (mTotalRaceTime or 0) + in_race_time
    table.insert(combined, {
        isPlayer = true,
        index = 0,
        lapCount = lapCount,
        checkpointsHit = checkpointsHit or 0,
        currentLapTime = in_race_time,
        finished = false,
        finishTime = nil,
        totalTime = playerTotalTime,
    })
    local aiIds = aiRacers and aiRacers.getSpawnedVehicleIds() or {}
    for i, vehId in ipairs(aiIds) do
        local s = mAiLapState[vehId]
        if s then
            local currentLapTime = (not s.finished) and (in_race_time - s.lapStartTime) or nil
            local aiTotal = s.finishTime
            if not aiTotal then
                if s.lapTimes and #s.lapTimes > 0 then
                    aiTotal = 0
                    for _, t in ipairs(s.lapTimes) do aiTotal = aiTotal + t end
                    aiTotal = aiTotal + (in_race_time - s.lapStartTime)
                else
                    aiTotal = in_race_time - s.lapStartTime
                end
            end
            table.insert(combined, {
                isPlayer = false,
                index = i,
                lapCount = s.lapCount,
                checkpointsHit = s.checkpointsHit or 0,
                currentLapTime = currentLapTime or 0,
                finished = s.finished,
                finishTime = s.finishTime,
                totalTime = aiTotal or 0,
                totalLaps = s.totalLaps,
                lapTimes = s.lapTimes,
            })
        end
    end
    -- Sort by position: more laps first; then finished first; then lower finishTime; then more checkpoints; then higher currentLapTime (further on lap)
    table.sort(combined, function(a, b)
        if a.lapCount ~= b.lapCount then return a.lapCount > b.lapCount end
        if a.finished ~= b.finished then return a.finished end
        if a.finished and b.finished then
            local at, bt = a.finishTime or 0, b.finishTime or 0
            if at ~= bt then return at < bt end
        end
        if a.checkpointsHit ~= b.checkpointsHit then return a.checkpointsHit > b.checkpointsHit end
        return (a.currentLapTime or 0) > (b.currentLapTime or 0)
    end)
    for place = 1, #combined do combined[place].place = place end
    local leaderTime = (#combined > 0 and combined[1].totalTime) and combined[1].totalTime or 0
    local vehicles = {}
    for _, e in ipairs(combined) do
        local boundaryKey = e.isPlayer and "player" or (aiIds[e.index])
        local diffFromLeader = (boundaryKey and mDiffFromLeaderAtBoundary[boundaryKey]) or nil
        local row = {
            place = e.place,
            isPlayer = e.isPlayer,
            index = e.index,
            lapCount = e.lapCount,
            totalLaps = e.totalLaps or totalLaps,
            totalTime = e.totalTime,
            diffFromLeader = diffFromLeader,
            finished = e.finished,
            finishTime = e.finishTime,
            currentLapTime = e.currentLapTime,
            checkpointsHit = e.checkpointsHit or 0,
        }
        if not e.isPlayer and e.lapTimes and #e.lapTimes > 0 then
            row.lastLapTime = e.lapTimes[#e.lapTimes]
        end
        table.insert(vehicles, row)
    end
    if #vehicles == 0 then return nil end
    return { inRaceTime = in_race_time, leaderTime = leaderTime, vehicles = vehicles, totalCheckpoints = totalCheckpoints }
end
-- [AI-PLACE-LUA-1] end

-- Start the race (staging -> start line).
local function beginFreeroamRace(raceNameArg, subjectID)
    if not races[raceNameArg] then return end
    local raceName = raceNameArg
    staged = nil
    frh.stagingSubjectId = nil
    if aiRacers and aiRacers.setPlayerFreeze then aiRacers.setPlayerFreeze(false) end
    if career_career.isActive() then
        career_modules_pauseTime.enablePauseCounter(true)
    end
    initialVehicleDamage = utils.getVehicleDamage()
    utils.saveAndSetTrafficAmount(0)
    checkpointManager.setRace(races[raceName], raceName)
    Assets:displayAssets({ subjectID = subjectID, triggerName = "fre_start_" .. raceName })
    timerActive = true
    in_race_time = 0
    maxSpeed = 0
    mActiveRace = raceName
    if gameplay_events_freContracts_sanctionedRacing and gameplay_events_freContracts_sanctionedRacing.onRaceBegin then
        gameplay_events_freContracts_sanctionedRacing.onRaceBegin(raceName)
    end
    frh.completionPayload = nil
    frh.completionSnapshot = nil
    frs.laps = {}
    frs.raceName = raceName
    frs.displayLabel = races[raceName].label or raceName
    frs.mainLabel = races[raceName].label or raceName
    frs.altLabel = (races[raceName].altRoute and races[raceName].altRoute.label) or nil
    frs.openLoop = races[raceName].checkpointRoad == true and not utils.hasFinishTrigger(raceName)
    lapCount = 0
    mCurrentRouteName = nil
    mTotalRaceTime = 0
    mBestLapThisRun = nil
    -- Suppress off-road exit briefly at race start so we don't exit (and clear AI) on first frame
    mSuppressOffRoadExitUntil = os.time() + 5
    if career_modules_business_businessInventory then
        local businessId, vehicleId = career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId(subjectID)
        if businessId and vehicleId then
            local jobId = career_modules_business_businessInventory.getJobIdFromVehicle(businessId, vehicleId)
            if jobId then
                mInventoryId = career_modules_business_businessInventory.getBusinessJobIdentifier(businessId, jobId)
            else
                mInventoryId = career_modules_business_businessInventory.getBusinessVehicleIdentifier(businessId, vehicleId)
            end
        else
            mInventoryId = career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId(subjectID) or subjectID
        end
    else
        mInventoryId = career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId(subjectID) or subjectID
    end
    invalidLap = false
    if raceHudApplies(races[raceName]) then
        setRaceHudBanner(utils.getRaceStartBannerText(raceName), "good", 5)
    else
        utils.displayStartMessage(raceName)
    end
    utils.setActiveLight(raceName, "green")
    if races[raceName].type and utils.tableContains(races[raceName].type, "drift") then
        gameplay_drift_general.setContext("inChallenge")
        gameplay_drift_general.reset()
        if gameplay_drift_drift then gameplay_drift_drift.setVehId(subjectID) end
    end
    if races[raceName].checkpointRoad then
        processRoad.reset()
        processRoad.setStationaryTimeout(races[raceName].timeout)
        local checkpoints, altCheckpoints = processRoad.getCheckpoints(races[raceName])
        if checkpointManager.setRouteLocked then checkpointManager.setRouteLocked(false) end
        checkpointManager.createCheckpoints(checkpoints, altCheckpoints, nil, nil)
        -- Cache main-route waypoint positions for waypoint-based AI lap/checkpoint detection (same as player checkpoint positions).
        mRaceWaypoints = { checkpoints = {} }
        for i, cp in ipairs(checkpoints) do
            local n = cp and cp.node
            if n and n.x and n.y and n.z then
                table.insert(mRaceWaypoints.checkpoints, {
                    x = n.x, y = n.y, z = n.z,
                    r = (type(n.width) == "number" and n.width > 0) and n.width or 30
                })
            end
        end
        if #mRaceWaypoints.checkpoints == 0 then mRaceWaypoints = nil end
        isLoop = processRoad.isLoop()
        currCheckpoint = 0
        checkpointsHit = 0
        totalCheckpoints = checkpointManager.calculateTotalCheckpoints()
        currentExpectedCheckpoint = 1
        mAltRoute = (raceName == COMPETITIVE_HUB_RACE_ID and hubState.useAltRoute == true and (hubState.inHubContext or hubState.raceSelected)) or false
        checkpointManager.setAltRoute(mAltRoute)
        currentExpectedCheckpoint = checkpointManager.enableCheckpoint(0, mAltRoute)
            if aiRacers and aiRacers.getSpawnedVehicleIds and aiRacers.releaseAndDrive then
            local ids = aiRacers.getSpawnedVehicleIds() or {}
            if #ids > 0 then
                local mainRace = races[raceName]
                local raceForAi = (mAltRoute and mainRace.altRoute and mainRace.altRoute.checkpointRoad) and mainRace.altRoute or mainRace
                local aiLaps = getDisplayTotalLapsForRace(raceForAi)
                if aiLaps < 1 then aiLaps = (raceForAi.lapCount and raceForAi.lapCount > 0) and raceForAi.lapCount or 3 end
                aiRacers.releaseAndDrive(raceForAi, aiLaps)
                local aiTotalCheckpoints = totalCheckpoints
                if raceForAi == mainRace.altRoute then
                    if checkpointManager.getAiAltCheckpointCount and checkpointManager.getAiAltCheckpointCount() > 0 then
                        aiTotalCheckpoints = checkpointManager.getAiAltCheckpointCount()
                    elseif checkpointManager.getAltCheckpointCount then
                        local altCount = checkpointManager.getAltCheckpointCount()
                        if altCount and altCount > 0 then aiTotalCheckpoints = altCount end
                    end
                end
                mAiLapState = {}
                mAiWaypointState = {}
                mDiffFromLeaderAtBoundary = {}
                for _, vehId in ipairs(ids) do
                    mAiLapState[vehId] = {
                        lapCount = 0,
                        lapStartTime = in_race_time,
                        totalLaps = aiLaps,
                        totalCheckpoints = aiTotalCheckpoints,
                        checkpointsHit = 0,
                        currentExpectedCheckpoint = 1,
                        lapTimes = {},
                        finished = false,
                        finishTime = nil,
                    }
                    mAiWaypointState[vehId] = { inRadius = {} }
                end
            end
        end
    end
    if races[raceName].checkpointRoad then
        showFreeroamRaceHud()
    end
end

local function cancelCompetitiveGridFlow()
    mCompetitiveCountdownCancel = true
    mCompetitiveAwaitingAiSpawn = false
    mCompetitiveCountdownJobActive = false
    mHubTrackAiSpawnWaitDeadline = nil
    resetHubTrackGridFlowFlags()
    if guihooks and guihooks.trigger then
        guihooks.trigger('ScenarioFlashMessageReset')
    end
    if aiRacers and aiRacers.setPlayerFreeze then aiRacers.setPlayerFreeze(false) end
end

local function startCompetitiveTrackCountdownAndRace()
    if mActiveRace then return false end
    if mCompetitiveCountdownJobActive then return false end
    if staged ~= COMPETITIVE_HUB_RACE_ID then return false end
    if not hubState.inHubContext and not hubState.raceSelected then return false end
    mPlayerStagingSpot = nil
    clearPlayerStagingCornerMarkers()
    if core_groundMarkers and core_groundMarkers.resetAll then core_groundMarkers.resetAll() end
    mCompetitiveCountdownJobActive = true
    mCompetitiveCountdownCancel = false
    if aiRacers and aiRacers.setPlayerFreeze then aiRacers.setPlayerFreeze(true) end
    if not core_jobsystem or not core_jobsystem.create then
        mCompetitiveCountdownJobActive = false
        local vid = be and be:getPlayerVehicleID(0)
        if vid and races and races[COMPETITIVE_HUB_RACE_ID] then
            beginFreeroamRace(COMPETITIVE_HUB_RACE_ID, vid)
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
        if vid and races and races[COMPETITIVE_HUB_RACE_ID] then
            beginFreeroamRace(COMPETITIVE_HUB_RACE_ID, vid)
        elseif aiRacers and aiRacers.setPlayerFreeze then
            aiRacers.setPlayerFreeze(false)
        end
    end)
    return true
end

local function buildFreRaceCompletionCelebrationEntry(finalResult, hudCompletionPl)
    local place, fieldSize = 1, 1
    if finalResult.aiResults then
        fieldSize = #finalResult.aiResults
        for i, r in ipairs(finalResult.aiResults) do
            if r.isPlayer then
                place = i
                break
            end
        end
    end
    local money = tonumber(finalResult.reward) or 0
    local xp = tonumber(finalResult.xp) or 0
    if hudCompletionPl and type(hudCompletionPl) == "table" and hudCompletionPl.rewards then
        local rev = hudCompletionPl.rewards
        if rev.money ~= nil then money = math.floor(tonumber(rev.money) or money) end
        if rev.businessMoney ~= nil then money = money + math.floor(tonumber(rev.businessMoney) or 0) end
        if rev.disciplineXp ~= nil then xp = math.floor(tonumber(rev.disciplineXp) or xp) end
    end
    fieldSize = math.max(fieldSize, place, 1)
    local lines = {
        string.format("Finish position: %d / %d", place, fieldSize),
        string.format("Race time: %s", utils.formatTime(finalResult.totalTime or 0)),
    }
    if finalResult.bestLap then
        table.insert(lines, string.format("Best lap: %s", utils.formatTime(finalResult.bestLap)))
    end
    if finalResult.lapsCompleted and finalResult.lapsTotal then
        table.insert(lines, string.format("Laps completed: %d / %d", finalResult.lapsCompleted, finalResult.lapsTotal))
    end
    for _, lap in ipairs(frs.laps or {}) do
        table.insert(lines, string.format("Lap %d: %s%s", lap.index, utils.formatTime(lap.time), lap.invalid and " (invalid)" or ""))
    end
    return {
        raceLabel = finalResult.raceLabel or "Race",
        rewardMoney = money,
        rewardXp = xp,
        summaryLines = lines,
    }
end

local function exitRace(isCompletion, customMessage, raceData, subjectID)
    -- While we're waiting for the 50s deferred result (track+AI), ignore a later exitRace(false) so we don't clear state and show "drive to stage"
    if isCompletion == false and mPendingTrackResult then
        return
    end
    cancelCompetitiveGridFlow()
    -- Clear hub countdown state whenever we exit (race or staging)
    hubState.countdownDelay = nil
    hubState.countdownEndTime = nil
    hubState.countdownStartClock = nil
    hubState.stagedAtStart = false
    hubState.pendingStart = nil
    hubState.stagingSubjectID = nil
    if mActiveRace then
        local raceName = mActiveRace
        local cpRoad = races[raceName] and races[raceName].checkpointRoad
        if cpRoad and not isCompletion then
            hideFreeroamRaceHud()
        end
        local mainRace = races[raceName]
        -- Use effective race (alt route when on Short Track) so lap/timer and results use correct route data
        local effectiveRace = (mainRace and mAltRoute and mainRace.altRoute) and mainRace.altRoute or (raceData or mainRace or {})
        local raceLabel = getRaceLabel()
        local displayLabel = getDisplayRaceLabel()
        local isLapRace = effectiveRace and ((effectiveRace.lapCount and effectiveRace.lapCount > 0) or effectiveRace.hotlap)

        local finalResult = nil
        local hudCompletionPl = nil

        if isCompletion then
            -- Include last lap in best when finishing via finish line (no lap-complete block ran for it)
            if in_race_time and (mBestLapThisRun == nil or in_race_time < mBestLapThisRun) then
                mBestLapThisRun = in_race_time
            end
            local rewardData
            rewardData, hudCompletionPl = payoutRace()
            local rewardAmt = 0
            if type(rewardData) == "number" then rewardAmt = rewardData end

            local totalTime = (mTotalRaceTime or 0) + in_race_time
            local lapsTotalVal = 1
            if isLapRace then
                lapsTotalVal = getDisplayTotalLapsForRace(effectiveRace)
                if lapsTotalVal < 1 then
                    lapsTotalVal = (effectiveRace.lapCount and effectiveRace.lapCount > 0) and effectiveRace.lapCount or lapCount
                end
                if lapsTotalVal < 1 then lapsTotalVal = lapCount end
            end

            finalResult = {
                raceLabel = displayLabel,
                lapsCompleted = isLapRace and lapCount or 1,
                lapsTotal = lapsTotalVal,
                totalTime = totalTime,
                bestLap = mBestLapThisRun,
                newBest = newBestSession,
                invalidLap = invalidLap,
                reward = rewardAmt,
                xp = 0,
                leaderboard = {}
            }
            -- [AI-RESULTS-LUA-1] begin: add aiResults (player + AI sorted by place) for results screen
            if next(mAiLapState) and aiRacers and aiRacers.getSpawnedVehicleIds then
                local MIN_LAP_SECONDS = 15  -- ignore values below this (sector/delta junk in lapTimes)
                local list = {}
                table.insert(list, { isPlayer = true, lapsCompleted = isLapRace and lapCount or 1, lapsTotal = lapsTotalVal, totalTime = totalTime, bestLap = mBestLapThisRun })
                for i, vehId in ipairs(aiRacers.getSpawnedVehicleIds()) do
                    local s = mAiLapState[vehId]
                    if s then
                        local bestLap = nil
                        if s.lapTimes and #s.lapTimes > 0 then
                            for _, t in ipairs(s.lapTimes) do
                                if type(t) == "number" and t >= MIN_LAP_SECONDS then
                                    bestLap = (bestLap == nil or t < bestLap) and t or bestLap
                                end
                            end
                        end
                        local aiTotal = nil
                        if s.finished and s.lapTimes and #s.lapTimes >= (s.totalLaps or 1) then
                            aiTotal = 0
                            for _, t in ipairs(s.lapTimes) do aiTotal = aiTotal + (type(t) == "number" and t or 0) end
                        end
                        if not aiTotal then
                            aiTotal = s.finishTime
                        end
                        if not aiTotal and s.lapTimes and #s.lapTimes > 0 then
                            aiTotal = 0
                            for _, t in ipairs(s.lapTimes) do aiTotal = aiTotal + (type(t) == "number" and t or 0) end
                            aiTotal = aiTotal + (in_race_time - s.lapStartTime)
                        end
                        table.insert(list, { isPlayer = false, index = i, lapsCompleted = s.lapCount, lapsTotal = s.totalLaps, totalTime = aiTotal, bestLap = bestLap })
                    end
                end
                table.sort(list, function(a, b)
                    if a.lapsCompleted ~= b.lapsCompleted then return a.lapsCompleted > b.lapsCompleted end
                    local at = a.totalTime or 999999
                    local bt = b.totalTime or 999999
                    return at < bt
                end)
                local leaderTime = (#list > 0 and list[1].totalTime) and list[1].totalTime or 0
                local aiResults = {}
                for place, row in ipairs(list) do
                    local r = { place = place, isPlayer = row.isPlayer, lapsCompleted = row.lapsCompleted, lapsTotal = row.lapsTotal, totalTime = row.totalTime, bestLap = row.bestLap }
                    if not row.isPlayer then r.index = row.index end
                    r.diffFromLeader = (row.totalTime or 0) - leaderTime
                    table.insert(aiResults, r)
                end
                finalResult.aiResults = aiResults
            end
            -- [AI-RESULTS-LUA-1] end
            if hudCompletionPl and hudCompletionPl.rewards and hudCompletionPl.rewards.disciplineXp then
                finalResult.xp = math.floor(tonumber(hudCompletionPl.rewards.disciplineXp) or 0)
            end

            -- Race-specific completion handling
            if raceName == "drag" and effectiveRace and subjectID then
                local side = "l"
                utils.updateDisplay(side, in_race_time, math.abs(be:getObjectVelocityXYZ(subjectID)) * speedUnit)
            end

            if effectiveRace and effectiveRace.type and utils.tableContains(effectiveRace.type, "drift") then
                local finalScore = getDriftScore()
                if gameplay_drift_general.getContext() == "inChallenge" then
                    gameplay_drift_general.setContext("inFreeRoam")
                end
            end

            if customMessage then
                utils.displayMessage(customMessage, 10)
            end
        else
            -- Race cancellation logic; if at least one lap completed, still show result screen + Next
            local message = customMessage or "You exited the race zone, Race cancelled"
            utils.displayMessage(message, 3)
            if lapCount >= 1 and effectiveRace then
                local rd = effectiveRace
                local isLap = rd and ((rd.lapCount and rd.lapCount > 0) or rd.hotlap)
                local totalTimePartial = (mTotalRaceTime or 0) + in_race_time
                local lapsTotalVal = 1
                if isLap then
                    lapsTotalVal = getDisplayTotalLapsForRace(rd)
                    if lapsTotalVal < 1 then lapsTotalVal = (rd.lapCount and rd.lapCount > 0) and rd.lapCount or lapCount end
                    if lapsTotalVal < 1 then lapsTotalVal = lapCount end
                end
                finalResult = {
                    raceLabel = displayLabel,
                    lapsCompleted = isLap and lapCount or 1,
                    lapsTotal = lapsTotalVal,
                    totalTime = totalTimePartial,
                    bestLap = mBestLapThisRun,
                    newBest = false,
                    invalidLap = invalidLap,
                    reward = 0,
                    xp = 0,
                    leaderboard = {}
                }
                -- [AI-RESULTS-LUA-1] begin: add aiResults for partial/cancelled result
                if next(mAiLapState) and aiRacers and aiRacers.getSpawnedVehicleIds then
                    local MIN_LAP_SECONDS = 15
                    local list = {}
                    table.insert(list, { isPlayer = true, lapsCompleted = isLap and lapCount or 1, lapsTotal = lapsTotalVal, totalTime = totalTimePartial, bestLap = mBestLapThisRun })
                    for i, vehId in ipairs(aiRacers.getSpawnedVehicleIds()) do
                        local s = mAiLapState[vehId]
                        if s then
                            local bestLap = nil
                            if s.lapTimes and #s.lapTimes > 0 then
                                for _, t in ipairs(s.lapTimes) do
                                    if type(t) == "number" and t >= MIN_LAP_SECONDS then
                                        bestLap = (bestLap == nil or t < bestLap) and t or bestLap
                                    end
                                end
                            end
                            local aiTotal = nil
                            if s.finished and s.lapTimes and #s.lapTimes >= (s.totalLaps or 1) then
                                aiTotal = 0
                                for _, t in ipairs(s.lapTimes) do aiTotal = aiTotal + (type(t) == "number" and t or 0) end
                            end
                            if not aiTotal then aiTotal = s.finishTime end
                            if not aiTotal and s.lapTimes and #s.lapTimes > 0 then
                                aiTotal = 0
                                for _, t in ipairs(s.lapTimes) do aiTotal = aiTotal + (type(t) == "number" and t or 0) end
                                aiTotal = aiTotal + (in_race_time - s.lapStartTime)
                            end
                            table.insert(list, { isPlayer = false, index = i, lapsCompleted = s.lapCount, lapsTotal = s.totalLaps, totalTime = aiTotal, bestLap = bestLap })
                        end
                    end
                    table.sort(list, function(a, b)
                        if a.lapsCompleted ~= b.lapsCompleted then return a.lapsCompleted > b.lapsCompleted end
                        local at = a.totalTime or 999999
                        local bt = b.totalTime or 999999
                        return at < bt
                    end)
                    local leaderTime = (#list > 0 and list[1].totalTime) and list[1].totalTime or 0
                    local aiResults = {}
                    for place, row in ipairs(list) do
                        local r = { place = place, isPlayer = row.isPlayer, lapsCompleted = row.lapsCompleted, lapsTotal = row.lapsTotal, totalTime = row.totalTime, bestLap = row.bestLap }
                        if not row.isPlayer then r.index = row.index end
                        r.diffFromLeader = (row.totalTime or 0) - leaderTime
                        table.insert(aiResults, r)
                    end
                    finalResult.aiResults = aiResults
                end
                -- [AI-RESULTS-LUA-1] end
            end
        end

        if gameplay_events_freContracts_sanctionedRacing then
            if isCompletion and finalResult and finalResult.aiResults then
                gameplay_events_freContracts_sanctionedRacing.settleFromAiResults(finalResult.aiResults)
            elseif not isCompletion then
                gameplay_events_freContracts_sanctionedRacing.onRaceAborted()
            elseif isCompletion then
                gameplay_events_freContracts_sanctionedRacing.settleFromAiResults(nil)
            end
        end

        local hasSpawnedAi = (aiRacers and aiRacers.getSpawnedVehicleIds and (#(aiRacers.getSpawnedVehicleIds() or {}) > 0)) or (next(mAiLapState) ~= nil)
        local deferResultScreen = isCompletion and hasSpawnedAi and finalResult
        local deferCpHudHide = isCompletion and cpRoad and not deferResultScreen

        if isCompletion and hudCompletionPl and not deferResultScreen then
            pushRaceHudCompletion(hudCompletionPl, raceName, displayLabel, raceLabel, in_race_time, true)
        end

        if finalResult then
            hubState.showingResult = true
            hubState.raceSelected = false
        end

        if deferResultScreen and guihooks and guihooks.trigger then
            guihooks.trigger("OpenFreRaceCompletionCelebration", {
                entry = buildFreRaceCompletionCelebrationEntry(finalResult, hudCompletionPl)
            })
            guihooks.trigger("ScenarioFlashMessageReset")
            hideStagedFlashMessage()
        end
        mPendingTrackResult = nil

        if cpRoad and frs.openLoop and not isCompletion and #frs.laps > 0
            and not deferResultScreen and guihooks and guihooks.trigger then
            guihooks.trigger("FreerunSummaryShow", buildFreSummaryPayload())
            frs.laps = {}
            frs.raceName = nil
        end

        utils.setActiveLight(raceName, "red")
        lapCount = 0
        timerActive = false
        mHotlap = nil
        currCheckpoint = nil
        mSplitTimes = {}
        mAltRoute = false
        mCurrentRouteName = nil
        invalidLap = false
        mInventoryId = nil
        maxSpeed = 0
        mTotalRaceTime = 0
        mBestLapThisRun = nil
        mSuppressOffRoadExitUntil = 0

        mActiveRace = nil
        local hideHudNow = deferResultScreen or not (isCompletion and cpRoad)
        if hideHudNow then
            hideFreeroamRaceHud()
        end
        mAiLapState = {}
        mRaceWaypoints = nil
        mAiWaypointState = {}
        mDiffFromLeaderAtBoundary = {}
        Assets:hideAllAssets()
        checkpointManager.removeCheckpoints()

        if aiRacers and aiRacers.setDnfCallback then aiRacers.setDnfCallback(nil) end
        if deferResultScreen and aiRacers and aiRacers.scheduleDelayedDespawn then
            aiRacers.scheduleDelayedDespawn(50)
            core_jobsystem.create(function(job)
                job.sleep(50)
                if aiRacers and aiRacers.clearSpawned then aiRacers.clearSpawned() end
                core_jobsystem.create(function(innerJob)
                    innerJob.sleep(10)
                    utils.restoreTrafficAmount()
                end)
            end)
        else
            if aiRacers and aiRacers.clearSpawned then aiRacers.clearSpawned() end
            core_jobsystem.create(function(job)
                job.sleep(10)
                utils.restoreTrafficAmount()
            end)
        end

        pits.clearSpeedLimit()
        newBestSession = false
        hubState.sanctionedRaceLapCount = nil
        if gameplay_drift_general.getContext() == "inChallenge" then
            gameplay_drift_general.setContext("inFreeRoam")
            gameplay_drift_general.reset()
        end
        if career_career.isActive() then
            career_modules_pauseTime.enablePauseCounter()
        end
        if deferCpHudHide then
            core_jobsystem.create(function(job)
                job.sleep(18)
                hideFreeroamRaceHud()
            end)
        end
        if previousGameState and not hubState.showingResult then
            core_gamestate.setGameState(previousGameState.state, previousGameState.appLayout, previousGameState.menuItems, previousGameState.options)
            previousGameState = nil
            saveGameState = false
        end
    end
end

local function tryCommitHubTrackGridStaging(spawnVehId)
    local raceName = COMPETITIVE_HUB_RACE_ID
    if not races or not races[raceName] then return false end
    if not staged and not mActiveRace and mCompetitiveCountdownJobActive then
        mCompetitiveCountdownJobActive = false
        mCompetitiveCountdownCancel = false
    end
    if not mPlayerStagingSpot or not isPlayerInHubParkingCommitSpot(mPlayerStagingSpot) then return false end
    if utils.isPlayerInPursuit() then
        utils.displayMessage("You cannot stage for an event while in a pursuit.", 2)
        return false
    end
    local vehicleSpeed = getVehicleSpeedMph(spawnVehId)
    if vehicleSpeed > HUB_TRACK_STAGE_STOP_MPH then
        return false
    end

    local raceForAi = hubTrackRaceForAi()
    if raceForAi and raceAllowsAiSpawn(raceForAi) then
        if mCompetitiveAwaitingAiSpawn then
            return false
        end
        if not mHubTrackParkingAiSpawnStarted and hubTrackSpawnedAiCount() == 0 then
            return false
        end
    end

    saveGameState = true
    core_gamestate.requestGameState()

    mHotlap = nil
    Assets:hideAllAssets()
    lapCount = 0

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
        utils.displayMessage(string.format("%s is disabled due to %s multiplier(s) being set to 0.", races[raceName].label, typesString), 5)
        return false
    end

    staged = raceName
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
    frh.stagingSubjectId = vehId
    if raceHudApplies(race) then
        showFreeroamRaceHud()
    else
        utils.displayStagedMessage(vehId, raceName)
    end
    utils.setActiveLight(raceName, "yellow")

    if not startCompetitiveTrackCountdownAndRace() then
        staged = nil
        frh.stagingSubjectId = nil
        utils.setActiveLight(raceName, "red")
        hideFreeroamRaceHud()
        hideStagedFlashMessage()
        return false
    end
    return true
end

-- Commit staged state: non-track races use fre_staging_*; hub circuit uses competitiveRaceAI.sites parking only (AI there, then stopped in same spot for countdown). fre_staging_track is ignored for hub track.
local function tryCommitStagingEnter(raceName, spawnVehId)
    if not races or not races[raceName] then return false end
    if utils.isPlayerInPursuit() then
        utils.displayMessage("You cannot stage for an event while in a pursuit.", 2)
        return false
    end

    saveGameState = true
    core_gamestate.requestGameState()

    local vehicleSpeed = math.abs(be:getObjectVelocityXYZ(spawnVehId)) * speedUnit
    if vehicleSpeed > 5 and mActiveRace then
        return false
    end
    mHotlap = nil
    if vehicleSpeed > 5 then
        if races[raceName].runningStart then
            if raceHudApplies(races[raceName]) then
                setRaceHudBanner("Hotlap staged — roll to start", "info", 3)
            else
                utils.displayMessage("Hotlap Staged", 2)
            end
            if races[raceName].hotlap then
                mHotlap = raceName
            end
        else
            utils.displayMessage("You are too fast to stage.\nPlease back up and slow down to stage.", 2)
            staged = nil
            return false
        end
    end
    Assets:hideAllAssets()
    lapCount = 0

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
        utils.displayMessage(string.format("%s is disabled due to %s multiplier(s) being set to 0.", races[raceName].label, typesString), 5)
        return false
    end

    if raceName == "drag" then
        utils.initDisplays()
        utils.resetDisplays()
    end

    staged = raceName
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
    frh.stagingSubjectId = vehId
    if raceHudApplies(race) then
        showFreeroamRaceHud()
    else
        utils.displayStagedMessage(vehId, raceName)
    end
    utils.setActiveLight(raceName, "yellow")
    return true
end

local function onBeamNGTrigger(data)
    if isReplay then return end
    local isPlayer = (be:getPlayerVehicleID(0) == data.subjectID)
    if not isPlayer and not isAiSpawnedVehicle(data.subjectID) then
        return
    end
    if gameplay_walk.isWalking() then return end

    local triggerName = data.triggerName
    local event = data.event

    if not triggerName:match("^fre_") then
        -- Not a free roam event trigger, ignore
        return
    end

    -- Remove the 'fre_' prefix for processing
    triggerName = triggerName:sub(5)

    -- Extract trigger information
    local triggerType, raceName, rest = triggerName:match("^([^_]+)_([^_]+)(.*)$")

    if not triggerType or not raceName then
        -- print("Trigger name doesn't match expected pattern.")
        return
    end

    -- Initialize altFlag, index, and aiAlt (trigger is for AI alt route from config pathRoad; no world display)
    local altFlag = nil
    local index = nil
    local isAiAlt = false

    -- Process the rest of the trigger name
    if rest ~= "" then
        -- Remove leading underscores
        rest = rest:gsub("^_+", "")

        -- Check for AI alt checkpoint (fre_checkpoint_<race>_ai_alt_<index>)
        if rest:sub(1, 6) == "ai_alt" then
            isAiAlt = true
            rest = rest:sub(7):gsub("^_+", "")
        elseif rest:sub(1, 3) == "alt" then
            altFlag = "alt"
            rest = rest:sub(4) -- Remove 'alt' and move forward
            rest = rest:gsub("^_+", "") -- Remove any additional underscores
        end

        -- If there's still something left, it's the index
        if rest ~= "" then
            index = rest
        end
    end

    -- Convert index to number if it exists
    local checkpointIndex = index and tonumber(index) or nil

    local isAlt = altFlag == "alt" -- TEMP must change to acount for alt routes that intersect with the main route multiple times

    -- AI lap counting and timers: handle start/checkpoint/finish for spawned AI (triggers if engine fires them; otherwise updated by waypoint polling).
    if not isPlayer and mActiveRace == raceName and mAiLapState[data.subjectID] and event == "enter" then
        if triggerType == "start" then
            applyWaypointHit_AI(data.subjectID, "start", 1, in_race_time)
            return
        end
        if triggerType == "checkpoint" and checkpointIndex then
            local useForAi = isAiAlt or not isAlt or not (checkpointManager.getAiAltCheckpointCount and checkpointManager.getAiAltCheckpointCount() > 0)
            if useForAi then
                applyWaypointHit_AI(data.subjectID, "checkpoint", checkpointIndex, in_race_time)
            end
            return
        end
        if triggerType == "finish" then
            applyWaypointHit_AI(data.subjectID, "finish", nil, in_race_time)
            return
        end
    end

    -- Player-only from here: staging/start/checkpoint/finish always run; hub trigger checks eligibility only for hub
    if not isPlayer then return end

    -- Hub trigger (fre_hub_track): opens/closes the hub when player enters/exits the zone (eligibility only for hub)
    if triggerType == "hub" and raceName == COMPETITIVE_HUB_RACE_ID then
        if not isVehicleEligibleForCompetitiveTrackHub(data.subjectID) then return end
        if event == "enter" then
            if competitiveTrackHubUiEnabled() then
                hubState.inHubContext = true
                -- Clear any lingering result/history flags
                hubState.showingResult = false
                hubState.showingHistory = false
                saveGameState = true
                core_gamestate.requestGameState()
            end
        elseif event == "exit" then
            -- Only hide hub if no race/practice selected and not in race
            if not hubState.raceSelected and not mActiveRace then
                hubState.inHubContext = false  -- Clear hub context when leaving without a race
                mPlayerStagingSpot = nil
                if core_groundMarkers and core_groundMarkers.resetAll then core_groundMarkers.resetAll() end
            end
        end
        return
    end

    if triggerType == "staging" then
        if raceName == COMPETITIVE_HUB_RACE_ID and (hubState.raceSelected or hubState.inHubContext) then
            return
        end
        if event == "enter" and mActiveRace == nil then
            if raceName ~= COMPETITIVE_HUB_RACE_ID then
                tryCommitStagingEnter(raceName, data.subjectID)
            end
        elseif event == "exit" then
            if mActiveRace ~= raceName then
                if raceName == COMPETITIVE_HUB_RACE_ID then
                    cancelCompetitiveGridFlow()
                end
                local r = races[raceName]
                local useHud = r and raceHudApplies(r)
                if useHud then
                    setRaceHudBanner("You exited the staging zone", "warn", 4)
                    pushFreeroamRaceHudState(true)
                end
                staged = nil
                frh.stagingSubjectId = nil
                hideStagedFlashMessage()
                if not useHud then
                    utils.displayMessage("You exited the staging zone", 4)
                end
                utils.setActiveLight(raceName, "red")
                if useHud then
                    core_jobsystem.create(function(job)
                        job.sleep(2.5)
                        hideFreeroamRaceHud()
                    end)
                end
                if raceName == COMPETITIVE_HUB_RACE_ID and gameplay_events_freContracts_sanctionedRacing then
                    gameplay_events_freContracts_sanctionedRacing.onRaceAborted()
                end
            end
        end
    elseif triggerType == "start" then
        if event == "enter" and mActiveRace == raceName and not utils.hasFinishTrigger(raceName) then
            if not currCheckpoint or checkpointsHit < totalCheckpoints then
                -- Player hasn't completed all checkpoints yet
                if not invalidLap then
                    if frh.shown then
                        setRaceHudBanner("Complete all checkpoints before crossing the line", "warn", 5)
                        pushFreeroamRaceHudState(true)
                    else
                        utils.displayMessage("You have not completed all checkpoints!", 5)
                    end
                    return
                end
            end
            -- Freeze lap time at completion so we don't count time after you stop
            local completedLapTime = in_race_time
            timerActive = false
            -- Suppress off-road exit briefly so crossing start line doesn't trigger exitRace
            mSuppressOffRoadExitUntil = os.time() + 2
            if not invalidLap then
                mTotalRaceTime = (mTotalRaceTime or 0) + completedLapTime
                if mBestLapThisRun == nil or completedLapTime < mBestLapThisRun then
                    mBestLapThisRun = completedLapTime
                end
            end
            initialVehicleDamage = utils.getVehicleDamage()
            processRoad.setStationaryTimeout(races[raceName].timeout)
            checkpointManager.setRace(races[raceName], raceName)
            if not data.triggerName then data.triggerName = "fre_start_" .. raceName end
            Assets:displayAssets(data)
            utils.playCheckpointSound()
            lapCount = lapCount + 1
            snapshotStandingsDeltas()
            local race = races[raceName]
            local effectiveRace = (mAltRoute and race.altRoute) and race.altRoute or race
            local lapTotalGoal = getDisplayTotalLapsForRace(effectiveRace)
            if lapTotalGoal < 1 then lapTotalGoal = (effectiveRace.lapCount and effectiveRace.lapCount > 0) and effectiveRace.lapCount or 0 end
            if lapTotalGoal > 0 and lapCount >= lapTotalGoal then
                exitRace(true, nil, effectiveRace, data.subjectID)
                return
            end
            local snapshotLabel = getDisplayRaceLabel()
            local snapshotRaceLabel = getRaceLabel()
            local reward, hudMsg = payoutRace(completedLapTime)
            if type(reward) == "number" and reward > 0 and races[raceName].checkpointRoad then
                frh.lastLapReward = reward
            end
            currCheckpoint = nil
            mSplitTimes = {}
            mActiveRace = raceName
            checkpointManager.setAltRoute(false)
            mAltRoute = false
            in_race_time = 0
            maxSpeed = 0
            timerActive = true
            checkpointsHit = 0
            totalCheckpoints = checkpointManager.calculateTotalCheckpoints()
            currentExpectedCheckpoint = 0
            if races[raceName].hotlap then
                mHotlap = raceName
                currentExpectedCheckpoint = checkpointManager.enableCheckpoint(0, mAltRoute)
            end
            invalidLap = false
            if hudMsg then
                pushRaceHudCompletion(hudMsg, raceName, snapshotLabel, snapshotRaceLabel, 0, false)
            else
                pushFreeroamRaceHudState(true)
            end
        elseif event == "enter" and staged == raceName and mActiveRace ~= raceName then
            if raceName == COMPETITIVE_HUB_RACE_ID and (mCompetitiveCountdownJobActive or mCompetitiveAwaitingAiSpawn) then
                return
            end
            beginFreeroamRace(raceName, data.subjectID)
        else
            -- Player is not staged or race is not active
            utils.setActiveLight(raceName, "red")
        end
    elseif triggerType == "checkpoint" and checkpointIndex then
        if event == "enter" and mActiveRace == raceName then
            -- Already have full lap; don't count another (lets start-trigger handle lap complete / finish)
            if checkpointsHit >= totalCheckpoints then return end
            -- Ensure that the checkpoint is the expected one
            if (checkpointIndex == currentExpectedCheckpoint) or (checkpointIndex == 1 and isAlt) or
                (isAlt and (currentExpectedCheckpoint == races[raceName].altRoute.mergeCheckpoints[1])) then
                -- Route-switch detection (end run + start other route) disabled: alt route merges with main
                -- and shares checkpoints, so (checkpointIndex, isAlt) alone is unreliable. Would need to use
                -- race_data.json checkpoint/altRoute definitions to know which checkpoints belong to which route.
                checkpointsHit = checkpointsHit + 1
                if frh.completionPayload then
                    frh.completionPayload = nil
                    frh.completionSnapshot = nil
                end
                currCheckpoint = checkpointIndex
                mSplitTimes[checkpointsHit] = in_race_time
                if checkpointsHit == 1 then
                    mCurrentRouteName = getRouteDisplayName(races[raceName], isAlt)
                end
                utils.playCheckpointSound()

                -- Prepare the next checkpoint
                if isAlt then
                    currentExpectedCheckpoint = checkpointIndex
                end

                currentExpectedCheckpoint = checkpointManager.enableCheckpoint(checkpointIndex, isAlt)
                if isAlt and not mAltRoute then
                    mAltRoute = true
                    checkpointManager.setAltRoute(true)
                    totalCheckpoints = checkpointManager.calculateTotalCheckpoints()
                end
                snapshotStandingsDeltas()

                -- Display checkpoint message
                local checkpointMessage = ""
                local splitDiff = getDifference(raceName, checkpointsHit)
                if splitDiff then
                    local totalDiff = nil
                    local raceLabel = getRaceLabel()
                    local leaderboardEntry = leaderboardManager.getLeaderboardEntry(mInventoryId, raceLabel)
                    totalDiff = in_race_time - (leaderboardEntry.splitTimes[checkpointsHit] or 0)

                    checkpointMessage = string.format("Checkpoint %d/%d - Time: %s\nSplit: %s | Total: %s",
                        checkpointsHit, totalCheckpoints, utils.formatTime(in_race_time), formatSplitDifference(splitDiff),
                        formatSplitDifference(totalDiff))
                else
                    checkpointMessage = string.format("Checkpoint %d/%d - Time: %s", checkpointsHit, totalCheckpoints,
                        utils.formatTime(in_race_time))
                end
                if not races[raceName].checkpointRoad then
                    utils.displayMessage(checkpointMessage, 7)
                end
                pushFreeroamRaceHudState(true)
                if not data.triggerName then
                    data.triggerName = "fre_checkpoint_" .. raceName .. (isAlt and "_alt_" or "_") .. checkpointIndex
                end
                Assets:displayAssets(data)
            else
                local missedCheckpoints = checkpointIndex - currentExpectedCheckpoint
                if missedCheckpoints > 0 then
                    -- Mark lap as invalid but continue with correct checkpoints
                    invalidLap = true

                    -- Update current checkpoint and hit count
                    currCheckpoint = checkpointIndex
                    currentExpectedCheckpoint = currentExpectedCheckpoint + missedCheckpoints
                    checkpointsHit = math.min(checkpointsHit + missedCheckpoints + 1, totalCheckpoints)
                    if frh.completionPayload then
                        frh.completionPayload = nil
                        frh.completionSnapshot = nil
                    end

                    -- Enable next checkpoint
                    currentExpectedCheckpoint = checkpointManager.enableCheckpoint(checkpointIndex, isAlt)

                    -- Display message about invalid lap but continuing
                    local message = string.format("Missed a checkpoint\nLap Invalidated.", checkpointIndex)
                    local checkpointMessage = string.format("Checkpoint %d/%d - Time: %s", checkpointsHit,
                        totalCheckpoints, utils.formatTime(in_race_time))
                    message = message .. "\n" .. checkpointMessage
                    if races[raceName].checkpointRoad and frh.shown then
                        setRaceHudBanner("Missed checkpoint — lap invalidated", "warn", 8)
                    elseif not frh.shown then
                        utils.displayMessage(message, 10)
                    end
                    pushFreeroamRaceHudState(true)
                end
            end
        end

    elseif triggerType == "finish" then
        if event == "enter" and mActiveRace == raceName then
            local race = races[raceName]
            local effectiveRace = (race and mAltRoute and race.altRoute) and race.altRoute or race
            exitRace(true, nil, effectiveRace, data.subjectID)
        end
    elseif triggerType == "pits" then
        if event == "enter" and mActiveRace == raceName then
            -- Handle pit entry
            local obj = be:getPlayerVehicle(0)
            if obj then
                obj:queueLuaCommand("obj:setGhostEnabled(true)")
            end
            if races[raceName].pitSpeedLimit then
                pits.stopThenLimit(races[raceName].pitSpeedLimit, races[raceName].pitSpeedLimitUnit)
            else
                pits.stopThenLimit(37, "MPH")
            end
        elseif event == "exit" and mActiveRace == raceName then
            -- Handle pit exit
            pits.toggleSpeedLimit()
            local obj = be:getPlayerVehicle(0)
            if obj then
                obj:queueLuaCommand("obj:setGhostEnabled(false)")
            end
        end    
    else
        -- print("Unknown trigger type: " .. triggerType)
    end
end

-- Preload AI paths for track (and alt) when level has track race with AI config (e.g. west_coast_usa).
local function preloadFreeroamAiPathsForTrack()
    if not aiRacers or not aiRacers.preloadPathForRace then return end
    local levelId = getCurrentLevelIdentifier()
    if not levelId or not races or not races.track then return end
    aiRacers.preloadPathForRace(races.track)
    if races.track.altRoute and races.track.altRoute.checkpointRoad then
        aiRacers.preloadPathForRace(races.track.altRoute)
    end
end

local function onWorldReadyState(state)
    if state == 2 then
        races = utils.loadRaceData()
        preloadFreeroamAiPathsForTrack()
    end
end

local function loadExtensions()
    local freeroamPath = "/lua/ge/extensions/gameplay/events/freeroam/"
    local files = FS:findFiles(freeroamPath, "*.lua", -1, true, false)
    
    if files then
        for _, filePath in ipairs(files) do
            local filename = string.match(filePath, "([^/]+)%.lua$")

            if filename then
                local extensionName = "gameplay_events_freeroam_" .. filename
                setExtensionUnloadMode(extensionName, "manual")
                extensions.unload(extensionName)
                table.insert(loadedExtensions, extensionName)
            end
        end
    end
    loadManualUnloadExtensions()
end

local function unloadExtensions()
    for _, extensionName in ipairs(loadedExtensions) do
        extensions.unload(extensionName)
    end
end

local function onExtensionLoaded()
    loadExtensions()
    if getCurrentLevelIdentifier() then
        races = utils.loadRaceData()
        preloadFreeroamAiPathsForTrack()
    end
end

local function onExtensionUnloaded()
    hideFreeroamRaceHud()
    unloadExtensions()
end

local function onUpdate(dtReal, dtSim, dtRaw)
    if aiRacers and aiRacers.onUpdate then aiRacers.onUpdate(dtReal or 0) end

    if mCompetitiveAwaitingAiSpawn and mHubTrackAiSpawnWaitDeadline and os.time() >= mHubTrackAiSpawnWaitDeadline then
        log("W", "freeroamEvents", "AI spawn wait timed out; clearing await flag.")
        mCompetitiveAwaitingAiSpawn = false
        mHubTrackAiSpawnWaitDeadline = nil
    end

    if not mActiveRace and hubState.raceSelected and hubState.inHubContext and mPlayerStagingSpot and not staged then
        local pv = be:getPlayerVehicle(0)
        local nowInParking = (pv and isPlayerInStagingSpot(mPlayerStagingSpot)) or false
        local enteredParkingNow = nowInParking and not mWasPlayerInHubTrackParkingSpot
        mWasPlayerInHubTrackParkingSpot = nowInParking
        local raceForAi = hubTrackRaceForAi()
        if nowInParking and raceForAi and raceAllowsAiSpawn(raceForAi) and hubTrackSpawnedAiCount() > 0
            and not mHubTrackParkingAiSpawnStarted then
            mHubTrackParkingAiSpawnStarted = true
            mCompetitiveAwaitingAiSpawn = false
            mHubTrackAiSpawnWaitDeadline = nil
        end
        if enteredParkingNow then
            if raceForAi and raceAllowsAiSpawn(raceForAi) and not mHubTrackParkingAiSpawnStarted and not mCompetitiveAwaitingAiSpawn then
                prepareFreeroamAiForTrack(nil, true)
                if mCompetitiveAwaitingAiSpawn then
                    mHubTrackParkingAiSpawnStarted = true
                end
            end
        end
        if pv and nowInParking then
            tryCommitHubTrackGridStaging(pv:getID())
        end
    end

    if mActiveRace and races[mActiveRace].checkpointRoad then
        if os.time() >= mSuppressOffRoadExitUntil and processRoad.checkPlayerOnRoad() == false then
            exitRace(false)
        end
    end
    if timerActive == true then
        in_race_time = in_race_time + dtSim
        mAiWaypointUpdateAccum = mAiWaypointUpdateAccum + (dtSim or 0)
        if mAiWaypointUpdateAccum >= 0.1 then
            updateAiWaypointsFromNavgraph()
            mAiWaypointUpdateAccum = 0
        end
        local playerVehicleId = be:getPlayerVehicleID(0)
        if playerVehicleId then
            local currentSpeed = math.abs(be:getObjectVelocityXYZ(playerVehicleId)) * speedUnit
            if currentSpeed > maxSpeed then
                maxSpeed = currentSpeed
            end
        end
        pushFreeroamRaceHudState(false)
    else
        in_race_time = 0
        if frh.shown and staged and races[staged] and raceHudApplies(races[staged]) and not mActiveRace then
            pushFreeroamRaceHudState(false)
        end
    end
end

local function formatEventPoi(raceName, race)
    local startObj = scenetree.findObject("fre_start_" .. raceName)
    local pos = startObj and startObj:getPosition() or nil
    
    if not pos then return nil end

    local levelIdentifier = getCurrentLevelIdentifier()
    local preview = "/levels/" .. levelIdentifier .. "/facilities/freeroamEvents/" .. raceName .. ".jpg"

    local vehId = be:getPlayerVehicleID(0) or 0
    if career_career.isActive() then
        vehId = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
    end

    return {
        id = raceName,
        data = {
            type = "events",
            facility = {}
        },
        markerInfo = {
            bigmapMarker = {
                pos = pos,
                icon = "mission_cup_triangle",
                name = race.label,
                description = utils.displayStagedMessage(vehId, raceName, true),
                previews = {preview},
                thumbnail = preview
            }
        }
    }
end

function M.onGetRawPoiListForLevel(levelIdentifier, elements)
    if not races then
        return
    end
    for raceName, race in pairs(races) do
        local poi = formatEventPoi(raceName, race)
        if poi then
            table.insert(elements, poi)
        end
    end
end

local function onReplayStateChanged(state)
    if not isReplay and state.state == "playback" then
        isReplay = true
    elseif isReplay and state.state == "inactive" then
        isReplay = false
    end
end

local function onGameStateUpdate(state)
    if saveGameState then
        saveGameState = false
        previousGameState = state
    end
end

M.onGameStateUpdate = onGameStateUpdate

M.onReplayStateChanged = onReplayStateChanged
M.onBeamNGTrigger = onBeamNGTrigger
M.onUpdate = onUpdate

M.payoutRace = payoutRace
M.payoutDragRace = payoutDragRace
M.onWorldReadyState = onWorldReadyState
M.getRace = function(raceName) return races[raceName] end
-- AI lap counting: returns { inRaceTime, vehicles = { { index, lapCount, totalLaps, lapTimes, lastLapTime, finished, finishTime, currentLapTime }, ... } } or nil. Use from console to gauge AI times.
M.getAiLapState = getAiLapStateForDisplay

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

M.onFreeroamHubRequestRaceHistory = function()
    hubState.showingResult = false
    hubState.showingHistory = true
end

M.onFreeroamHubReady = function()
    loadFreeroamHubPrefs()
end

M.onFreeroamHubSetAutoShow = function(enable)
    if not getFreeroamHubPrefsPath() then return end
    loadFreeroamHubPrefs()
    hubState.prefs.autoShow = (enable == true)
    if not hubState.prefs.autoShow then
        hubState.prefs.addedOnce = false
    end
    saveFreeroamHubPrefs()
end

M.onFreeroamHubEndEvent = function()
    if not mActiveRace then return end
    exitRace(false)
end

-- Freeroam hub: set route to practice (unlimited laps, current behavior)
M.onFreeroamHubSelectPractice = function()
    hubState.practiceMode = true
    hubState.useAltRoute = false
    hubState.raceSelected = false
end

-- Freeroam hub: set route to main track (e.g. set laps event, main route)
-- Spawn AI racers for track when player selects Track or Short Track and is staged at track (west_coast_usa style).
prepareFreeroamAiForTrack = function(poolReferenceHpOverride, deferCountdown)
    if not races then races = utils.loadRaceData() end
    local raceForAi = hubTrackRaceForAi()
    if not aiRacers or not raceForAi or not raceAllowsAiSpawn(raceForAi) then return end
    if mActiveRace and timerActive then return end
    if hubTrackSpawnedAiCount() > 0 then
        mCompetitiveAwaitingAiSpawn = false
        mHubTrackAiSpawnWaitDeadline = nil
        mHubTrackParkingAiSpawnStarted = true
        return
    end
    if aiRacers.clearSpawned then aiRacers.clearSpawned() end
    mCompetitiveAwaitingAiSpawn = true
    mHubTrackAiSpawnWaitDeadline = os.time() + HUB_TRACK_AI_SPAWN_WAIT_SEC
    local refHp = type(poolReferenceHpOverride) == "number" and poolReferenceHpOverride > 0 and poolReferenceHpOverride or nil
    if not refHp and type(hubState.sanctionedPoolRefHp) == "number" and hubState.sanctionedPoolRefHp > 0 then
        refHp = hubState.sanctionedPoolRefHp
    end
    hubState.sanctionedPoolRefHp = nil
    if not refHp and gameplay_events_freContracts_sanctionedRacing and gameplay_events_freContracts_sanctionedRacing.getAiPoolReferenceHp then
        refHp = gameplay_events_freContracts_sanctionedRacing.getAiPoolReferenceHp()
    end
    local function afterAiSpawnCommit()
        mCompetitiveAwaitingAiSpawn = false
        mHubTrackAiSpawnWaitDeadline = nil
        if deferCountdown then return end
        if staged ~= COMPETITIVE_HUB_RACE_ID or mActiveRace then return end
        if hubState.inHubContext or hubState.raceSelected then
            startCompetitiveTrackCountdownAndRace()
        end
    end
    if aiRacers.spawnForStagingWithPlayerHp then
        aiRacers.spawnForStagingWithPlayerHp(COMPETITIVE_HUB_RACE_ID, raceForAi, COMPETITIVE_HUB_RACE_ID, function(spawned)
            local count = tonumber(spawned) or 0
            if count <= 0 then
                log("W", "freeroamEvents", string.format("Sanctioned AI spawn returned %d, retrying with base pool.", count))
                if aiRacers.spawnForStaging then
                    local fallbackCount = tonumber(aiRacers.spawnForStaging(COMPETITIVE_HUB_RACE_ID, raceForAi, COMPETITIVE_HUB_RACE_ID)) or 0
                    if fallbackCount <= 0 then
                        log("W", "freeroamEvents", "Fallback sanctioned AI spawn also returned 0.")
                    end
                end
            end
            afterAiSpawnCommit()
        end, refHp)
    elseif aiRacers.spawnForStaging then
        local spawned = tonumber(aiRacers.spawnForStaging(COMPETITIVE_HUB_RACE_ID, raceForAi, COMPETITIVE_HUB_RACE_ID)) or 0
        if spawned <= 0 then
            log("W", "freeroamEvents", "Sanctioned AI spawn returned 0.")
        end
        afterAiSpawnCommit()
    else
        afterAiSpawnCommit()
    end
end

M.onFreeroamHubSelectTrack = function()
    hubState.practiceMode = false
    hubState.useAltRoute = false
    hubState.raceSelected = true
    mWasPlayerInHubTrackParkingSpot = false
    -- Load staging spot and set nav to it
    local spot = loadPlayerStagingSpot()
    if spot and spot.pos then
        mPlayerStagingSpot = spot
        if core_groundMarkers and core_groundMarkers.setPath then
            core_groundMarkers.setPath(vec3(spot.pos[1], spot.pos[2], spot.pos[3]), { clearPathOnReachingTarget = false })
        end
        showPlayerStagingCornerMarkers(spot)
    end
end

-- Freeroam hub: set route to short track / alt route
M.onFreeroamHubSelectShortTrack = function()
    hubState.practiceMode = false
    hubState.useAltRoute = true
    hubState.raceSelected = true
    mWasPlayerInHubTrackParkingSpot = false
    -- Load staging spot and set nav to it
    local spot = loadPlayerStagingSpot()
    if spot and spot.pos then
        mPlayerStagingSpot = spot
        if core_groundMarkers and core_groundMarkers.setPath then
            core_groundMarkers.setPath(vec3(spot.pos[1], spot.pos[2], spot.pos[3]), { clearPathOnReachingTarget = false })
        end
        showPlayerStagingCornerMarkers(spot)
    end
end

-- Freeroam hub: Back button / clear selection
M.onFreeroamHubClearSelection = function()
    cancelCompetitiveGridFlow()
    -- Reset hub UI state
    hubState.raceSelected = false
    hubState.useAltRoute = false
    hubState.practiceMode = false
    hubState.showingResult = false
    hideStagedFlashMessage()
    hubState.countdownDelay = nil
    hubState.countdownEndTime = nil
    hubState.countdownStartClock = nil
    hubState.stagedAtStart = false
    hubState.pendingStart = nil
    hubState.stagingSubjectID = nil
    hubState.sanctionedPoolRefHp = nil
    hubState.sanctionedRaceLapCount = nil
    if hubState.inHubContext and gameplay_events_freContracts_sanctionedRacing then
        gameplay_events_freContracts_sanctionedRacing.onRaceAborted()
    end

    -- Only clear staged/AI if we're in hub context (prevents affecting other freeroam events)
    if hubState.inHubContext then
        staged = nil
        mPlayerStagingSpot = nil
        clearPlayerStagingCornerMarkers()
        if core_groundMarkers and core_groundMarkers.resetAll then core_groundMarkers.resetAll() end
        if aiRacers and aiRacers.setPlayerFreeze then aiRacers.setPlayerFreeze(false) end
        if aiRacers and aiRacers.clearSpawned then aiRacers.clearSpawned() end
        hideFreeroamRaceHud()
    end
end

M.onFreeroamHubClosed = function()
    cancelCompetitiveGridFlow()
    -- If they turned off auto show, mark hub as not added for prefs-only flows
    if not hubState.prefs.autoShow then
        hubState.prefs.addedOnce = false
        saveFreeroamHubPrefs()
    end
    -- Reset hub UI state
    hubState.showingResult = false
    hubState.showingHistory = false
    hubState.raceSelected = false
    hubState.useAltRoute = false
    hubState.practiceMode = false
    hubState.countdownDelay = nil
    hubState.countdownEndTime = nil
    hubState.countdownStartClock = nil
    hubState.stagedAtStart = false
    hubState.pendingStart = nil
    hubState.stagingSubjectID = nil
    hubState.sanctionedPoolRefHp = nil
    hubState.sanctionedRaceLapCount = nil
    -- Only do full cleanup (staged, AI, game state) if we're in a hub context
    if hubState.inHubContext then
        staged = nil
        mPlayerStagingSpot = nil
        if core_groundMarkers and core_groundMarkers.resetAll then core_groundMarkers.resetAll() end
        if aiRacers and aiRacers.setPlayerFreeze then aiRacers.setPlayerFreeze(false) end
        if aiRacers and aiRacers.clearSpawned then aiRacers.clearSpawned() end
        hideFreeroamRaceHud()
        if previousGameState then
            core_gamestate.setGameState(previousGameState.state, previousGameState.appLayout, previousGameState.menuItems, previousGameState.options)
            previousGameState = nil
            saveGameState = false
        end
    end
    hubState.inHubContext = false
end

M.clearFreSummarySession = function()
    frs.laps = {}
    frs.raceName = nil
end

M.startSanctionedRaceDispatch = function(useAltRoute, poolReferenceHpOverride)
    if not races then
        races = utils.loadRaceData()
    end
    preloadFreeroamAiPathsForTrack()
    staged = nil
    resetHubTrackGridFlowFlags()
    hubState.sanctionedPoolRefHp = (type(poolReferenceHpOverride) == "number" and poolReferenceHpOverride > 0) and poolReferenceHpOverride or nil
    hubState.sanctionedRaceLapCount = nil
    if gameplay_events_freContracts_sanctionedRacing and gameplay_events_freContracts_sanctionedRacing.getSanctionedOfferLapCount then
        local lc = gameplay_events_freContracts_sanctionedRacing.getSanctionedOfferLapCount()
        if lc then hubState.sanctionedRaceLapCount = lc end
    end
    hubState.inHubContext = true
    hubState.practiceMode = false
    hubState.useAltRoute = useAltRoute == true
    hubState.raceSelected = true
    hubState.showingResult = false
    hubState.showingHistory = false
    hubState.pendingStart = nil
    hubState.stagedAtStart = false
    hubState.stagingSubjectID = nil
    hideStagedFlashMessage()
    if core_groundMarkers and core_groundMarkers.resetAll then
        core_groundMarkers.resetAll()
    end
    saveGameState = true
    core_gamestate.requestGameState()
    local spot = loadPlayerStagingSpot()
    if spot and spot.pos then
        mPlayerStagingSpot = spot
        if core_groundMarkers and core_groundMarkers.setPath then
            core_groundMarkers.setPath(vec3(spot.pos[1], spot.pos[2], spot.pos[3]), { clearPathOnReachingTarget = false })
        end
        showPlayerStagingCornerMarkers(spot)
    end
    if mPlayerStagingSpot and isPlayerInStagingSpot(mPlayerStagingSpot) then
        local pv = be:getPlayerVehicle(0)
        if pv then
            local raceForAi = hubTrackRaceForAi()
            if raceForAi and raceAllowsAiSpawn(raceForAi) and not mHubTrackParkingAiSpawnStarted and not mCompetitiveAwaitingAiSpawn then
                prepareFreeroamAiForTrack(nil, true)
                if mCompetitiveAwaitingAiSpawn then
                    mHubTrackParkingAiSpawnStarted = true
                end
            end
            mWasPlayerInHubTrackParkingSpot = true
        end
    end
end

return M