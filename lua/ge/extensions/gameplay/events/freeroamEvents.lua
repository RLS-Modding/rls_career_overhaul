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

local FREEROAM_HUB_PREFS_FILE = "career/rls_career/freeroam_hub_prefs.json"
local mFreeroamHubPrefs = { autoShow = true, addedOnce = false }
local mFreeroamHubPracticeMode = false
local mFreeroamHubUseAltRoute = false
local mFreeroamHubRaceSelected = false
local mFreeroamHubShowingResult = false
local mFreeroamHubShowingHistory = false
local mFreeroamCountdownDelay = nil
local mFreeroamCountdownEndTime = nil
local mFreeroamCountdownStartClock = nil
local mFreeroamStagedAtStart = false
local mFreeroamPendingStart = nil
local mFreeroamStagingSubjectID = nil

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

-- Forward declaration so applyWaypointHit_AI (and others) can call it; defined later in file.
local snapshotStandingsDeltas

local function getFreeroamHubPrefsPath()
    if not career_saveSystem or not career_saveSystem.getCurrentSaveSlot then return nil end
    local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()
    if not savePath then return nil end
    return savePath .. "/" .. FREEROAM_HUB_PREFS_FILE
end

local function loadFreeroamHubPrefs()
    local path = getFreeroamHubPrefsPath()
    if not path then return end
    local d = jsonReadFile(path)
    if d then
        if d.autoShow ~= nil then mFreeroamHubPrefs.autoShow = d.autoShow end
        if d.addedOnce ~= nil then mFreeroamHubPrefs.addedOnce = d.addedOnce end
    end
end

local function saveFreeroamHubPrefs()
    local path = getFreeroamHubPrefsPath()
    if not path or not career_saveSystem or not career_saveSystem.jsonWriteFileSafe then return end
    career_saveSystem.jsonWriteFileSafe(path, mFreeroamHubPrefs, true)
end

-- Add player HP and class to hub state for header display (Class X • N HP). Also trigger dedicated event so UI receives it.
local function injectPlayerPowerAndClassIntoState(state)
    if not state or not aiRacers or not aiRacers.getPlayerVehiclePowerAndClass then return end
    local hp, cl = aiRacers.getPlayerVehiclePowerAndClass()
    state.playerHp = hp
    state.playerClass = cl
    if guihooks and guihooks.trigger then
        guihooks.trigger("FreeroamHubPlayerPowerClass", { playerHp = hp, playerClass = cl })
    end
end

local function isFreeroamHubActive()
    if not career_career or not career_career.isActive() then return false end
    if not aiRacers or not aiRacers.levelHasAiRacingConfig or not aiRacers.levelHasAiRacingConfig() then return false end
    loadFreeroamHubPrefs()
    return mFreeroamHubPrefs.autoShow ~= false
end

local function isFreeroamHubRaceMode()
    return isFreeroamHubActive() and not mFreeroamHubPracticeMode
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
    local gc = getGameplayAppContainers()
    if gc and gc.showApp then gc.showApp("gameplayApps", "countdown")
    elseif guihooks and guihooks.trigger then guihooks.trigger("setGameplayAppVisibility", { appId = "countdown", visible = true }) end
    if guihooks and guihooks.trigger then guihooks.trigger("ScenarioFlashMessage", {{ "Staged", 30 }}) end
    utils.displayMessage("Staged", 5)
end
local function hideStagedFlashMessage()
    if guihooks and guihooks.trigger then guihooks.trigger("ScenarioFlashMessageClear") end
    local gc = getGameplayAppContainers()
    if gc and gc.hideApp then gc.hideApp("gameplayApps", "flashMessage") gc.hideApp("gameplayApps", "countdown") end
end
local function triggerRaceCountdown()
    hideStagedFlashMessage()
    local gc = getGameplayAppContainers()
    if gc and gc.showApp then gc.showApp("gameplayApps", "countdown")
    elseif guihooks and guihooks.trigger then guihooks.trigger("setGameplayAppVisibility", { appId = "countdown", visible = true }) end
    if guihooks and guihooks.trigger then
        guihooks.trigger("ScenarioFlashMessage", {
            { 3, 0.8, false, true },
            { 2, 0.8, false, true },
            { 1, 0.8, false, true },
            { "GO", 0.6, false, true },
        })
    end
    if core_jobsystem and core_jobsystem.create then
        core_jobsystem.create(function(job)
            utils.displayMessage("3", 0.8)
            job.sleep(0.8)
            utils.displayMessage("2", 0.8)
            job.sleep(0.8)
            utils.displayMessage("1", 0.8)
            job.sleep(0.8)
            utils.displayMessage("GO!", 0.6)
        end)
    end
    mFreeroamCountdownEndTime = 3.0
    mFreeroamCountdownStartClock = (os and os.clock) and os.clock() or nil
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
    local completionMeta = {
        disciplineIds = getRaceDisciplineIds(race),
        invalidLap = invalidLap == true,
        normalizedPerformance = normalizedPerformance,
        driftScore = driftScore,
        damagePercentage = damagePercentage,
        rewardBreakdown = {}
    }
    -- Handle career mode specific rewards
    if career_career.isActive() then
        if not newBest or mHotlap then
            reward = reward / 2
        end
        reward = invalidLap and 0 or reward
        lapCount = invalidLap and 1 or lapCount
        if race.hotlap then
            -- Hotlap Multiplier
            reward = reward * utils.hotlapMultiplier(lapCount)
            hotlapMessage = string.format("\nHotlap Multiplier: %.2f", utils.hotlapMultiplier(lapCount))
        end

        if newBest and not newBestSession then
            -- New Best Bonus
            newBestSession = true
        end

        if newBestSession then
            -- New Best Bonus
            reward = reward * 1.2
            hotlapMessage = hotlapMessage .. "\nNew Best Session Bonus: 20%"
        end

        if oldTime and (newEntry.time - (oldTime * 0.025) < oldTime) then
            -- In Range Bonus
            reward = reward * 1.05
            hotlapMessage = hotlapMessage .. "\nIn Range Bonus: 5%"
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

        if reward > 0 then
            local playerVehicleId = be:getPlayerVehicleID(0)
            local businessAccount = getBusinessAccountFromVehicle(playerVehicleId)
            
            if businessAccount then
                local businessReward = math.floor(reward * 0.5)
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
            end
            career_saveSystem.saveCurrent()
        end
    end

    notifyFreRaceCompleted(mActiveRace, race, raceLabel, in_race_time, be:getPlayerVehicleID(0), completionMeta)
    mActiveRace = nil
    utils.displayMessage(message, 20, "Reward")
    if hotlapMessage ~= "" then
        ui_message(hotlapMessage, 5, "Hotlap Multiplier")
    end
    return reward
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

-- True if the vehicle is eligible for freeroam hub (show for owned or business; hide for loan or other). Tries subjectID first, then current player vehicle so hub still shows after modify/respawn.
local function isVehicleEligibleForFreeroamHub(spawnedId)
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
    local totalLaps = (effectiveRace and effectiveRace.lapCount and effectiveRace.lapCount > 0) and effectiveRace.lapCount or 3
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

-- Start the race (staging -> start line). Used by both trigger and onUpdate (countdown-finished). Keeps original logic; hub-only behavior is guarded by isFreeroamHubRaceMode/isFreeroamHubActive.
local function beginFreeroamRace(raceNameArg, subjectID)
    if not races[raceNameArg] then return end
    local raceName = raceNameArg
    if career_career.isActive() then
        career_modules_pauseTime.enablePauseCounter(true)
    end
    initialVehicleDamage = utils.getVehicleDamage()
    utils.saveAndSetTrafficAmount(0)
    checkpointManager.setRace(races[raceName], raceName)
    -- Staged/start assets only in practice when hub active; for Track/Short Track the hub shows the race
    if not (isFreeroamHubActive() and raceName == "track" and not mFreeroamHubPracticeMode) then
        Assets:displayAssets({ subjectID = subjectID, triggerName = "fre_start_" .. raceName })
    end
    timerActive = true
    in_race_time = 0
    maxSpeed = 0
    mActiveRace = raceName
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
    if not (isFreeroamHubActive() and raceName == "track" and not mFreeroamHubPracticeMode) then
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
        local aiAltCheckpoints = nil
        local useAltRoute = isFreeroamHubActive() and mFreeroamHubUseAltRoute and races[raceName].altRoute
        if useAltRoute and aiRacers and aiRacers.getMergedConfigForRace and processRoad.getCheckpointsFromRoad then
            local cfg = aiRacers.getMergedConfigForRace(races[raceName].altRoute)
            if cfg and type(cfg.pathRoad) == "string" and cfg.pathRoad ~= "" then
                local minDist = (races[raceName].altRoute and races[raceName].altRoute.minCheckpointDistance) or races[raceName].minCheckpointDistance or 90
                aiAltCheckpoints = processRoad.getCheckpointsFromRoad(cfg.pathRoad, minDist)
            end
        end
        local routeOnly = nil
        if isFreeroamHubActive() and not mFreeroamHubPracticeMode then
            routeOnly = useAltRoute and "alt" or "main"
        end
        local isLocked = isFreeroamHubActive() and not mFreeroamHubPracticeMode
        if checkpointManager.setRouteLocked then checkpointManager.setRouteLocked(isLocked) end
        checkpointManager.createCheckpoints(checkpoints, altCheckpoints, routeOnly, aiAltCheckpoints)
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
        mAltRoute = false
        checkpointManager.setAltRoute(mAltRoute)
        if isFreeroamHubActive() and mFreeroamHubUseAltRoute and races[raceName].altRoute then
            mAltRoute = true
            checkpointManager.setAltRoute(true)
            totalCheckpoints = checkpointManager.calculateTotalCheckpoints()
        end
        currentExpectedCheckpoint = checkpointManager.enableCheckpoint(0, mAltRoute)
    end
end

local function exitRace(isCompletion, customMessage, raceData, subjectID)
    -- While we're waiting for the 50s deferred result (track+AI), ignore a later exitRace(false) so we don't clear state and show "drive to stage"
    if isCompletion == false and mPendingTrackResult then
        return
    end
    -- Clear hub countdown state whenever we exit (race or staging)
    mFreeroamCountdownDelay = nil
    mFreeroamCountdownEndTime = nil
    mFreeroamCountdownStartClock = nil
    mFreeroamStagedAtStart = false
    mFreeroamPendingStart = nil
    mFreeroamStagingSubjectID = nil
    if mActiveRace then
        local raceName = mActiveRace
        local mainRace = races[raceName]
        -- Use effective race (alt route when on Short Track) so lap/timer and results use correct route data
        local effectiveRace = (mainRace and mAltRoute and mainRace.altRoute) and mainRace.altRoute or (raceData or mainRace or {})
        local raceLabel = getRaceLabel()
        local displayLabel = getDisplayRaceLabel()
        
        -- Build final UI state before we clear mActiveRace (display label has no "(Hotlap)" for hub title)
        local isLapRace = effectiveRace and ((effectiveRace.lapCount and effectiveRace.lapCount > 0) or effectiveRace.hotlap)
        local sectorDeltas = {}
        for i = 1, checkpointsHit do
            local d = getDifference(raceName, i)
            if d then sectorDeltas[i] = d end
        end
        local lbEntry = mInventoryId and leaderboardManager.getLeaderboardEntry(mInventoryId, raceLabel) or {}
        local lapNum = isLapRace and (lapCount + 1) or 1
        local finalState = {
            inRace = false,
            staged = false,
            raceId = raceName,
            raceLabel = displayLabel,
            currentLap = isLapRace and lapCount or 0,
            displayLap = lapNum,
            totalLaps = isLapRace and effectiveRace.lapCount or 1,
            totalCheckpoints = totalCheckpoints,
            currentLapTime = in_race_time,
            topSpeedThisLap = maxSpeed,
            bestLapFromHistory = lbEntry.time,
            invalidLap = invalidLap,
            routeName = mCurrentRouteName,
            splits = mSplitTimes,
            sectorDeltas = sectorDeltas
        }
        
        local finalResult = nil

        if isCompletion then
            -- Include last lap in best when finishing via finish line (no lap-complete block ran for it)
            if in_race_time and (mBestLapThisRun == nil or in_race_time < mBestLapThisRun) then
                mBestLapThisRun = in_race_time
            end
            -- Race completion logic
            local rewardData = payoutRace()
            
            -- If payoutRace() returned something useful we can put it in the result ticket
            local rewardAmt = 0
            if type(rewardData) == "number" then rewardAmt = rewardData end

            local totalTime = (mTotalRaceTime or 0) + in_race_time
            local lapsTotalVal = isLapRace and (effectiveRace.lapCount and effectiveRace.lapCount > 0 and effectiveRace.lapCount or lapCount) or 1

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
                utils.displayMessage(customMessage, 10, "Reward")
            end
        else
            -- Race cancellation logic; if at least one lap completed, still show result screen + Next
            local message = customMessage or "You exited the race zone, Race cancelled"
            utils.displayMessage(message, 3)
            if lapCount >= 1 and effectiveRace then
                local rd = effectiveRace
                local isLap = rd and ((rd.lapCount and rd.lapCount > 0) or rd.hotlap)
                local totalTimePartial = (mTotalRaceTime or 0) + in_race_time
                local lapsTotalVal = isLap and (rd.lapCount and rd.lapCount > 0 and rd.lapCount or lapCount) or 1
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

        -- Defer result screen when track + AI: show result after 50s so AI stay and can finish; until then show "waiting for others"
        local isTrackCompletionWithAi = isCompletion and (raceName == "track")
        -- Use "had AI in race" (mAiLapState has entries) so we defer even if spawned list was cleared before we read it
        local hasSpawnedAi = (aiRacers and aiRacers.getSpawnedVehicleIds and (#(aiRacers.getSpawnedVehicleIds() or {}) > 0)) or (next(mAiLapState) ~= nil)
        local deferResultScreen = isTrackCompletionWithAi and hasSpawnedAi and finalResult

        -- Push the final state and result to the UI app (only when hub is active)
        if isFreeroamHubActive() then
            injectPlayerPowerAndClassIntoState(finalState)
            if deferResultScreen then
                finalState.waitingForResults = true
                mPendingTrackResult = {
                    displayLabel = finalResult.raceLabel,
                    lapsTotalVal = finalResult.lapsTotal,
                    lapsCompleted = finalResult.lapsCompleted,
                    totalTime = finalResult.totalTime,
                    bestLap = finalResult.bestLap,
                    newBest = finalResult.newBest,
                    invalidLap = finalResult.invalidLap,
                    rewardAmt = finalResult.reward or 0,
                    isLapRace = isLapRace,
                    raceEndTime = in_race_time,
                }
            else
                if finalResult then
                    mFreeroamHubShowingResult = true
                    mFreeroamHubRaceSelected = false
                    guihooks.trigger("FreeroamHubRaceResult", finalResult)
                end
            end
            guihooks.trigger("FreeroamHubRaceState", finalState)
            -- Hub is only closed by the user via the Close button; we do not hide it from Lua
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

        -- Track race completion with AI: delay despawn 50s so AI can finish laps; keep mActiveRace/mAiLapState so their triggers still update. Result screen is shown from this job after 50s.
        if isTrackCompletionWithAi and hasSpawnedAi and aiRacers.scheduleDelayedDespawn then
            if aiRacers.setDnfCallback then aiRacers.setDnfCallback(nil) end
            aiRacers.scheduleDelayedDespawn(50)
            core_jobsystem.create(function(job)
                job.sleep(50)
                -- Build and show result from final mAiLapState (AI may have finished during the 50s; use mAiLapState so we include all AI even if already despawned)
                if mPendingTrackResult and isFreeroamHubActive() then
                    local MIN_LAP_SECONDS = 15
                    local pr = mPendingTrackResult
                    local list = {}
                    table.insert(list, { isPlayer = true, lapsCompleted = pr.lapsCompleted, lapsTotal = pr.lapsTotalVal, totalTime = pr.totalTime, bestLap = pr.bestLap })
                    local aiIndex = 0
                    for vehId, s in pairs(mAiLapState) do
                        if s and type(s) == "table" then
                            aiIndex = aiIndex + 1
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
                                aiTotal = aiTotal + ((pr.raceEndTime or 0) - s.lapStartTime)
                            end
                            table.insert(list, { isPlayer = false, index = aiIndex, lapsCompleted = s.lapCount, lapsTotal = s.totalLaps, totalTime = aiTotal, bestLap = bestLap })
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
                    local finalResult = {
                        raceLabel = pr.displayLabel,
                        lapsCompleted = pr.lapsCompleted,
                        lapsTotal = pr.lapsTotalVal,
                        totalTime = pr.totalTime,
                        bestLap = pr.bestLap,
                        newBest = pr.newBest,
                        invalidLap = pr.invalidLap,
                        reward = pr.rewardAmt,
                        xp = 0,
                        leaderboard = {},
                        aiResults = aiResults,
                    }
                    mFreeroamHubShowingResult = true
                    mFreeroamHubRaceSelected = false
                    guihooks.trigger("FreeroamHubRaceResult", finalResult)
                end
                mPendingTrackResult = nil
                mActiveRace = nil
                mAiLapState = {}
                mRaceWaypoints = nil
                mAiWaypointState = {}
                mDiffFromLeaderAtBoundary = {}
                if aiRacers and aiRacers.clearSpawned then aiRacers.clearSpawned() end
                Assets:hideAllAssets()
                checkpointManager.removeCheckpoints()
                core_jobsystem.create(function(innerJob)
                    innerJob.sleep(10)
                    utils.restoreTrafficAmount()
                end)
                pits.clearSpeedLimit()
                newBestSession = false
                if gameplay_drift_general.getContext() == "inChallenge" then
                    gameplay_drift_general.setContext("inFreeRoam")
                    gameplay_drift_general.reset()
                end
                if career_career.isActive() then
                    career_modules_pauseTime.enablePauseCounter()
                end
            end)
        else
            mActiveRace = nil
            mAiLapState = {}
            mRaceWaypoints = nil
            mAiWaypointState = {}
            mDiffFromLeaderAtBoundary = {}
            if aiRacers then
                if aiRacers.setDnfCallback then aiRacers.setDnfCallback(nil) end
                if aiRacers.clearSpawned then aiRacers.clearSpawned() end
            end
            Assets:hideAllAssets()
            checkpointManager.removeCheckpoints()

            -- Common cleanup tasks
            core_jobsystem.create(function(job)
                job.sleep(10)
                utils.restoreTrafficAmount()
            end)
            pits.clearSpeedLimit()
            newBestSession = false
            if gameplay_drift_general.getContext() == "inChallenge" then
                gameplay_drift_general.setContext("inFreeRoam")
                gameplay_drift_general.reset()
            end
            if career_career.isActive() then
                career_modules_pauseTime.enablePauseCounter()
            end
        end
        if previousGameState and not mFreeroamHubShowingResult then
            core_gamestate.setGameState(previousGameState.state, previousGameState.appLayout, previousGameState.menuItems, previousGameState.options)
            previousGameState = nil
            saveGameState = false
        end
    end
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

    -- Player-only from here: hub eligibility and staging/start/checkpoint/finish
    if not isPlayer then return end
    if not isVehicleEligibleForFreeroamHub(data.subjectID) then
        return
    end

    if triggerType == "staging" then
        if event == "enter" and mActiveRace == nil then
            -- Clear result/history flags when re-entering staging so hub shows again after tow/repair or leaving
            if isFreeroamHubActive() and (mFreeroamHubShowingResult or mFreeroamHubShowingHistory) then
                mFreeroamHubShowingResult = false
                mFreeroamHubShowingHistory = false
            end
            if utils.isPlayerInPursuit() then
                utils.displayMessage("You cannot stage for an event while in a pursuit.", 2)
                return
            end

            saveGameState = true
            core_gamestate.requestGameState()

            local vehicleSpeed = math.abs(be:getObjectVelocityXYZ(data.subjectID)) * speedUnit
            if vehicleSpeed > 5 and mActiveRace then
                return
            end
            mHotlap = nil
            if vehicleSpeed > 5 then
                if races[raceName].runningStart then
                    utils.displayMessage("Hotlap Staged", 2)
                    if races[raceName].hotlap then
                        mHotlap = raceName
                    end
                else
                    utils.displayMessage("You are too fast to stage.\nPlease back up and slow down to stage.", 2)
                    staged = nil
                    return
                end
            end
            Assets:hideAllAssets()
            lapCount = 0

            -- Check if ALL race types are disabled (only disable if every type is 0)
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

                -- Only disable if ALL types are disabled
                allTypesDisabled = totalTypes > 0 and disabledCount == totalTypes
            end

            if allTypesDisabled then
                -- Don't allow staging for disabled races
                local typesString = table.concat(disabledTypes, ", ")
                utils.displayMessage(string.format("%s is disabled due to %s multiplier(s) being set to 0.", races[raceName].label, typesString), 5)
                return
            end

            -- Initialize displays if drag race
            if raceName == "drag" then
                utils.initDisplays()
                utils.resetDisplays()
            end

            -- Set staged race
            staged = raceName
            -- Hub: only buttons (Track/Short track) trigger flash/countdown; entering the zone never does
            if isFreeroamHubActive() then
                mFreeroamHubRaceSelected = false
            end
            -- print("Staged race: " .. raceName)
            local vehId = data.subjectID
            if career_career.isActive() then
                -- Check if it's a business vehicle first
                if career_modules_business_businessInventory then
                    local businessId, vehicleId = career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId(data.subjectID)
                    if businessId and vehicleId then
                        vehId = career_modules_business_businessInventory.getBusinessVehicleIdentifier(businessId, vehicleId)
                    else
                        vehId = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
                    end
                else
                    vehId = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
                end
            end
            
            local race = races[raceName] or {}
            local raceLabel = race.label or raceName
            local state = { inRace = false, staged = true, raceId = raceName, raceLabel = raceLabel }
            state.stagedMessage = utils.displayStagedMessage(vehId, raceName, true)
            state.showRaceSelection = isFreeroamHubActive() and not mFreeroamHubRaceSelected

            -- Hub only for track (competitive circuit with AI); never show for drag or other events
            if isFreeroamHubActive() and raceName == "track" then
                guihooks.trigger("FreeroamHubAddApp")
                guihooks.trigger("appContainer:addApp", "freeroamEventHub")
                guihooks.trigger("FreeroamHubSetAvailable", { available = true })
                if not mFreeroamHubPrefs.addedOnce then
                    mFreeroamHubPrefs.addedOnce = true
                    saveFreeroamHubPrefs()
                end
                -- Use guihooks only; engine container has no freeroamEventHub registered
                guihooks.trigger("setGameplayAppVisibility", { appId = "freeroamEventHub", visible = true })
                injectPlayerPowerAndClassIntoState(state)
                guihooks.trigger("FreeroamHubRaceState", state)
            end

            -- Staged freeroam event info only in practice; for Track/Short Track the hub is the only UI
            if not (isFreeroamHubActive() and raceName == "track" and not mFreeroamHubPracticeMode) then
                utils.displayStagedMessage(vehId, raceName)
            end
            utils.setActiveLight(raceName, "yellow")
        elseif event == "exit" then
            -- If they chose a race and are driving to the start line (or are already in the race), don't clear staged/countdown/AI when exiting staging
            local drivingToStart = (mFreeroamHubRaceSelected and (mFreeroamCountdownDelay or mFreeroamCountdownEndTime or mFreeroamPendingStart)) or (mActiveRace == raceName)
                or (staged == raceName and not (isFreeroamHubRaceMode() and raceName == "track"))
            if not drivingToStart then
                staged = nil
                mFreeroamHubRaceSelected = false
                if isFreeroamHubRaceMode() then
                    hideStagedFlashMessage()
                    mFreeroamCountdownDelay = nil
                    mFreeroamCountdownEndTime = nil
                    mFreeroamCountdownStartClock = nil
                    mFreeroamStagedAtStart = false
                    mFreeroamPendingStart = nil
                    if aiRacers then
                        if aiRacers.setPlayerFreeze then aiRacers.setPlayerFreeze(false) end
                        if aiRacers.clearSpawned then aiRacers.clearSpawned() end
                    end
                end
                if not mActiveRace and not mFreeroamHubShowingResult and not mFreeroamHubShowingHistory then
                    if isFreeroamHubActive() and raceName == "track" then
                        guihooks.trigger("FreeroamHubSetAvailable", { available = false })
                        guihooks.trigger("FreeroamHubRaceState", { inRace = false })
                        -- Hub is only closed by the user via the Close button
                    end
                    utils.displayMessage("You exited the staging zone", 4)
                    utils.setActiveLight(raceName, "red")
                end
            end
        end
    elseif triggerType == "start" then
        if event == "enter" and mActiveRace == raceName and not utils.hasFinishTrigger(raceName) then
            if not currCheckpoint or checkpointsHit < totalCheckpoints then
                -- Player hasn't completed all checkpoints yet
                if not invalidLap then
                    utils.displayMessage("You have not completed all checkpoints!", 5)
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
            if not (isFreeroamHubActive() and not mFreeroamHubPracticeMode and raceName == "track") then
                Assets:displayAssets(data)
            end
            utils.playCheckpointSound()
            lapCount = lapCount + 1
            snapshotStandingsDeltas()
            -- Hub race mode: if we have a required lap count and just reached it, complete the race and show result screen
            if isFreeroamHubActive() and not mFreeroamHubPracticeMode then
                local race = races[raceName]
                local effectiveRace = (mAltRoute and race.altRoute) and race.altRoute or race
                local requiredLaps = (effectiveRace.lapCount and effectiveRace.lapCount > 0) and effectiveRace.lapCount or 3
                if lapCount >= requiredLaps then
                    exitRace(true, nil, effectiveRace, data.subjectID)
                    return
                end
            end
            local reward = payoutRace(completedLapTime)
            currCheckpoint = nil
            mSplitTimes = {}
            mActiveRace = raceName
            -- Next lap: keep alt route if hub selected Short track, else reset to main
            if not (isFreeroamHubActive() and mFreeroamHubUseAltRoute) then
                checkpointManager.setAltRoute(false)
                mAltRoute = false
            end
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
        elseif event == "enter" and staged == raceName and mActiveRace ~= raceName then
            -- Only require hub button selection for track (competitive circuit); drag/other events start without hub
            if isFreeroamHubRaceMode() and raceName == "track" and not mFreeroamHubRaceSelected then
                utils.setActiveLight(raceName, "red")
                return
            end
            -- Hub race mode (track only): Staged flash + countdown. Drag/other events start immediately.
            if isFreeroamHubRaceMode() and raceName == "track" then
                if mFreeroamCountdownEndTime and mFreeroamCountdownEndTime > 0 and mFreeroamCountdownStartClock and os and os.clock then
                    local elapsed = os.clock() - mFreeroamCountdownStartClock
                    if elapsed < 3.0 then
                        utils.displayMessage("False start! Wait for the countdown.", 4)
                        hideStagedFlashMessage()
                        mFreeroamCountdownDelay = nil
                        mFreeroamCountdownEndTime = nil
                        mFreeroamCountdownStartClock = nil
                        mFreeroamStagedAtStart = false
                        mFreeroamPendingStart = nil
                        staged = nil
                        if aiRacers and aiRacers.setPlayerFreeze then aiRacers.setPlayerFreeze(false) end
                        return
                    end
                end
                if mFreeroamCountdownEndTime == nil or not mFreeroamCountdownStartClock then
                    -- Countdown not run yet: wait at start line; countdown will run from onUpdate, then we start from onUpdate when 3s elapsed
                    mFreeroamStagedAtStart = true
                    mFreeroamPendingStart = { raceName = raceName, subjectID = data.subjectID }
                    return
                end
                -- Countdown finished and 3s elapsed: clear and proceed with start below
                mFreeroamCountdownEndTime = nil
                mFreeroamCountdownStartClock = nil
                mFreeroamStagedAtStart = false
                mFreeroamPendingStart = nil
            end
            -- Start the race (original logic in beginFreeroamRace; hub-only route/lap behavior is guarded there)
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
                utils.displayMessage(checkpointMessage, 7)
                if not data.triggerName then
                    data.triggerName = "fre_checkpoint_" .. raceName .. (isAlt and "_alt_" or "_") .. checkpointIndex
                end
                if not (isFreeroamHubActive() and not mFreeroamHubPracticeMode and raceName == "track") then
                    Assets:displayAssets(data)
                end
            else
                local missedCheckpoints = checkpointIndex - currentExpectedCheckpoint
                if missedCheckpoints > 0 then
                    -- Mark lap as invalid but continue with correct checkpoints
                    invalidLap = true

                    -- Update current checkpoint and hit count
                    currCheckpoint = checkpointIndex
                    currentExpectedCheckpoint = currentExpectedCheckpoint + missedCheckpoints
                    checkpointsHit = math.min(checkpointsHit + missedCheckpoints + 1, totalCheckpoints)

                    -- Enable next checkpoint
                    currentExpectedCheckpoint = checkpointManager.enableCheckpoint(checkpointIndex, isAlt)

                    -- Display message about invalid lap but continuing
                    local message = string.format("Missed a checkpoint\nLap Invalidated.", checkpointIndex)
                    local checkpointMessage = string.format("Checkpoint %d/%d - Time: %s", checkpointsHit,
                        totalCheckpoints, utils.formatTime(in_race_time))
                    message = message .. "\n" .. checkpointMessage
                    utils.displayMessage(message, 10)
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
    unloadExtensions()
end

local function onUpdate(dtReal, dtSim, dtRaw)
    -- Only suppress normal UI messages when hub is showing (track event); drag and other events keep their messages
    -- When hub is active and not in practice (Track/Short Track selected), suppress freeroam messages so only hub UI shows; in practice allow staged/checkpoint messages
    _G.freeroamHubSuppressUIMessages = isFreeroamHubActive() and not mFreeroamHubPracticeMode
    if aiRacers and aiRacers.onUpdate then aiRacers.onUpdate(dtReal or 0) end
    -- Hub race mode: staged flash + countdown (American Road style); use dtReal so it advances when paused
    if mFreeroamCountdownDelay then
        mFreeroamCountdownDelay = mFreeroamCountdownDelay - (dtReal or 0)
        if mFreeroamCountdownDelay <= 0 then
            mFreeroamCountdownDelay = nil
            if staged == "track" and aiRacers and aiRacers.startEnginesForSpawned then
                aiRacers.startEnginesForSpawned()
            end
            if aiRacers and aiRacers.setPlayerFreeze then aiRacers.setPlayerFreeze(true) end
            triggerRaceCountdown()
        end
    end
    if mFreeroamCountdownEndTime then
        mFreeroamCountdownEndTime = mFreeroamCountdownEndTime - (dtReal or 0)
        if mFreeroamCountdownEndTime <= 0 then
            mFreeroamCountdownEndTime = nil
            mFreeroamCountdownStartClock = nil
            local rn, sid
            if mFreeroamPendingStart and races[mFreeroamPendingStart.raceName] then
                rn = mFreeroamPendingStart.raceName
                sid = mFreeroamPendingStart.subjectID
            elseif staged and mFreeroamHubRaceSelected then
                rn = staged
                if not races[rn] and mFreeroamHubUseAltRoute then
                    for raceId, raceData in pairs(races) do
                        if raceData.altRoute then
                            rn = raceId
                            break
                        end
                    end
                end
                if races[rn] then
                    sid = mFreeroamStagingSubjectID or (be and be:getPlayerVehicleID(0))
                else
                    rn = nil
                end
            end
            mFreeroamPendingStart = nil
            mFreeroamStagedAtStart = false
            mFreeroamStagingSubjectID = nil
            if rn and sid then
                staged = nil
                beginFreeroamRace(rn, sid)
                -- Release AI racers on GO (any race with checkpointRoad; alt route when hub selected alt)
                if rn and races[rn] and races[rn].checkpointRoad and aiRacers and aiRacers.releaseAndDrive then
                    local mainRace = races[rn]
                    local raceForAi = mainRace
                    if mFreeroamHubUseAltRoute and mainRace.altRoute and mainRace.altRoute.checkpointRoad then
                        raceForAi = mainRace.altRoute
                    end
                    local aiLaps = (raceForAi.lapCount and raceForAi.lapCount > 0) and raceForAi.lapCount or 3
                    aiRacers.releaseAndDrive(raceForAi, aiLaps)
                    if aiRacers.setPlayerFreeze then aiRacers.setPlayerFreeze(true) end
                    -- Init AI lap state. When alt route has pathRoad in config, AI use ai_alt triggers (count from getAiAltCheckpointCount).
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
                    local aiIds = aiRacers.getSpawnedVehicleIds()
                    mDiffFromLeaderAtBoundary = {}
                    for _, vehId in ipairs(aiIds or {}) do
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
    end
    if mActiveRace and races[mActiveRace].checkpointRoad then
        if os.time() >= mSuppressOffRoadExitUntil and processRoad.checkPlayerOnRoad() == false then
            exitRace(false)
        end
    end
    -- While waiting for 50s result (deferred track+AI finish), re-push waiting state so hub stays on "Waiting for others" and isn't overwritten by another push
    if not timerActive and mActiveRace and mPendingTrackResult and isFreeroamHubActive() and (os.clock() % 0.5) < (dtSim or 0) then
        guihooks.trigger("FreeroamHubAddApp")
        guihooks.trigger("appContainer:addApp", "freeroamEventHub")
        guihooks.trigger("FreeroamHubSetAvailable", { available = true })
        local pr = mPendingTrackResult
        local state = {
            inRace = false,
            staged = false,
            raceId = "track",
            raceLabel = pr.displayLabel or "Track",
            waitingForResults = true,
        }
        injectPlayerPowerAndClassIntoState(state)
        guihooks.trigger("FreeroamHubRaceState", state)
        guihooks.trigger("setGameplayAppVisibility", { appId = "freeroamEventHub", visible = true })
    end
    -- When staged at track and not in race, re-add hub if it was closed (e.g. from practice screen) so it reopens when entering staging
    if not mActiveRace and staged == "track" and isFreeroamHubActive() and (os.clock() % 0.5) < dtSim then
        guihooks.trigger("FreeroamHubAddApp")
        guihooks.trigger("appContainer:addApp", "freeroamEventHub")
        guihooks.trigger("FreeroamHubSetAvailable", { available = true })
        local race = races["track"] or {}
        local raceLabel = race.label or "track"
        local vehId = be and be:getPlayerVehicleID(0) or nil
        if vehId and career_career.isActive() then
            if career_modules_business_businessInventory then
                local businessId, vehicleId = career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId(vehId)
                if businessId and vehicleId then
                    vehId = career_modules_business_businessInventory.getBusinessVehicleIdentifier(businessId, vehicleId)
                else
                    vehId = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
                end
            else
                vehId = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
            end
        end
        local state = { inRace = false, staged = true, raceId = "track", raceLabel = raceLabel }
        state.stagedMessage = utils.displayStagedMessage(vehId, "track", true)
        state.showRaceSelection = not mFreeroamHubRaceSelected
        injectPlayerPowerAndClassIntoState(state)
        guihooks.trigger("FreeroamHubRaceState", state)
        guihooks.trigger("setGameplayAppVisibility", { appId = "freeroamEventHub", visible = true })
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
        
        -- Push live UI state: hub title uses display label (no "(Hotlap)"); leaderboard lookup uses full label
        -- Use effective race (alt route when on Short Track) so lap counter and totalLaps match current route
        local race = races[mActiveRace] or {}
        local effectiveRace = (mAltRoute and race.altRoute) and race.altRoute or race
        local isLapRace = (effectiveRace.lapCount and effectiveRace.lapCount > 0) or effectiveRace.hotlap
        local raceLabel = getRaceLabel()
        local displayLabel = getDisplayRaceLabel()
        local leaderboardEntry = mInventoryId and leaderboardManager.getLeaderboardEntry(mInventoryId, raceLabel) or {}
        local bestLapFromHistory = leaderboardEntry.time

        -- Only push state periodically (e.g. every ~100ms) to avoid lagging the UI (only when hub active)
        if isFreeroamHubActive() and (in_race_time % 0.1) < dtSim then
            -- Re-add hub app if it was closed (e.g. from practice screen) so it reopens when back in zone/staging
            guihooks.trigger("FreeroamHubAddApp")
            guihooks.trigger("appContainer:addApp", "freeroamEventHub")
            guihooks.trigger("FreeroamHubSetAvailable", { available = true })
            local sectorDeltas = {}
            for i = 1, checkpointsHit do
                local d = getDifference(mActiveRace, i)
                if d then sectorDeltas[i] = d end
            end
            -- displayLap = current lap number as shown in game (lapCount + 1); currentLap = lapCount for compatibility
            local lapNum = isLapRace and (lapCount + 1) or 1
            local state = {
                inRace = true,
                isPractice = false, -- freeroam events are always races
                staged = false,
                raceId = mActiveRace,
                raceLabel = displayLabel,
                currentLap = isLapRace and lapCount or 0,
                displayLap = lapNum,
                totalLaps = isLapRace and effectiveRace.lapCount or 1,
                totalCheckpoints = totalCheckpoints,
                currentLapTime = in_race_time,
                topSpeedThisLap = maxSpeed,
                bestLapThisRun = mBestLapThisRun,
                bestLapFromHistory = bestLapFromHistory,
                invalidLap = invalidLap,
                routeName = mCurrentRouteName,
                splits = mSplitTimes,
                sectorDeltas = sectorDeltas,
                aiLapState = getAiLapStateForDisplay()
            }
            injectPlayerPowerAndClassIntoState(state)
            guihooks.trigger("FreeroamHubRaceState", state)
            guihooks.trigger("setGameplayAppVisibility", { appId = "freeroamEventHub", visible = true })
        end
    else
        in_race_time = 0
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
    mFreeroamHubShowingResult = false
    mFreeroamHubShowingHistory = true
    if not isFreeroamHubActive() then return end
    local inventoryId = mInventoryId
    if not inventoryId and career_modules_inventory then
        local vehId = be:getPlayerVehicleID(0)
        if vehId then
            inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
        end
    end
    local entries = {}
    if inventoryId then
        entries = leaderboardManager.getLeaderboardEntriesForVehicle(inventoryId)
    end
    guihooks.trigger("FreeroamHubRaceHistory", { entries = entries })
end

M.onFreeroamHubReady = function()
    loadFreeroamHubPrefs()
    -- Always send prefs so UI can show checkbox (e.g. opt back in when app opened from menu)
    guihooks.trigger("FreeroamHubPrefs", { autoShow = mFreeroamHubPrefs.autoShow })
    -- Only push hub state when hub is active and we're in track context (not drag/other events)
    if not isFreeroamHubActive() then return end
    if mActiveRace == "track" then
        local race = races[mActiveRace] or {}
        local isLapRace = (race.lapCount and race.lapCount > 0) or race.hotlap
        local raceLabel = getRaceLabel()
        local displayLabel = getDisplayRaceLabel()
        local sectorDeltas = {}
        for i = 1, checkpointsHit do
            local d = getDifference(mActiveRace, i)
            if d then sectorDeltas[i] = d end
        end
        local leaderboardEntry = mInventoryId and leaderboardManager.getLeaderboardEntry(mInventoryId, raceLabel) or {}
        local bestLapFromHistory = leaderboardEntry.time
        local lapNum = isLapRace and (lapCount + 1) or 1
        local state = {
            inRace = true,
            isPractice = false,
            staged = false,
            raceId = mActiveRace,
            raceLabel = displayLabel,
            currentLap = isLapRace and lapCount or 0,
            displayLap = lapNum,
            totalLaps = isLapRace and race.lapCount or 1,
            totalCheckpoints = totalCheckpoints,
            currentLapTime = in_race_time,
            topSpeedThisLap = maxSpeed,
            bestLapThisRun = mBestLapThisRun,
            bestLapFromHistory = bestLapFromHistory,
            invalidLap = invalidLap,
            routeName = mCurrentRouteName,
            splits = mSplitTimes,
            sectorDeltas = sectorDeltas
        }
        injectPlayerPowerAndClassIntoState(state)
        guihooks.trigger("FreeroamHubSetAvailable", { available = true })
        guihooks.trigger("FreeroamHubRaceState", state)
    elseif staged == "track" then
        local race = races[staged] or {}
        local raceLabel = race.label or staged
        local state = { inRace = false, staged = true, raceId = staged, raceLabel = raceLabel }
        local vehId = be:getPlayerVehicleID(0)
        if vehId then
            state.stagedMessage = utils.displayStagedMessage(vehId, staged, true)
        end
        state.showRaceSelection = not mFreeroamHubRaceSelected
        injectPlayerPowerAndClassIntoState(state)
        guihooks.trigger("FreeroamHubSetAvailable", { available = true })
        guihooks.trigger("FreeroamHubRaceState", state)
    end
end

M.onFreeroamHubSetAutoShow = function(enable)
    if not getFreeroamHubPrefsPath() then return end
    loadFreeroamHubPrefs()
    mFreeroamHubPrefs.autoShow = (enable == true)
    saveFreeroamHubPrefs()
    if not mFreeroamHubPrefs.autoShow then
        utils.displayMessage("You can add the app later from the UI menu", 5, true)
    end
end

M.onFreeroamHubEndEvent = function()
    if not mActiveRace then return end
    if isFreeroamHubActive() then
        exitRace(false)
    end
end

-- Freeroam hub: set route to practice (unlimited laps, current behavior)
M.onFreeroamHubSelectPractice = function()
    mFreeroamHubPracticeMode = true
    mFreeroamHubUseAltRoute = false
    mFreeroamHubRaceSelected = false
end

-- Freeroam hub: set route to main track (e.g. set laps event, main route)
-- Spawn AI racers for track when player selects Track or Short Track and is staged at track (west_coast_usa style).
local function prepareFreeroamAiForTrack()
    if not races then races = utils.loadRaceData() end
    if not aiRacers or not races or not races.track then return end
    if aiRacers.spawnForStagingWithPlayerHp then
        aiRacers.spawnForStagingWithPlayerHp("track", races.track, "track", function() end)
    elseif aiRacers.spawnForStaging then
        aiRacers.spawnForStaging("track", races.track, "track")
    end
end

M.onFreeroamHubSelectTrack = function()
    mFreeroamHubPracticeMode = false
    mFreeroamHubUseAltRoute = false
    mFreeroamHubRaceSelected = true
    if staged == "track" then
        prepareFreeroamAiForTrack()
    end
    -- If already in staging zone, show Staged and start countdown now (only path that triggers flash/countdown)
    if staged then
        showStagedFlashMessage()
        if aiRacers and aiRacers.setPlayerFreeze then aiRacers.setPlayerFreeze(true) end
        mFreeroamCountdownDelay = 1.0
        mFreeroamStagedAtStart = false
        mFreeroamPendingStart = nil
        mFreeroamStagingSubjectID = be and be:getPlayerVehicleID(0) or nil
    end
end

-- Freeroam hub: set route to short track / alt route
M.onFreeroamHubSelectShortTrack = function()
    mFreeroamHubPracticeMode = false
    mFreeroamHubUseAltRoute = true
    mFreeroamHubRaceSelected = true
    if staged == "track" then
        prepareFreeroamAiForTrack()
    end
    -- If already in staging zone, show Staged and start countdown now (only path that triggers flash/countdown)
    if staged then
        showStagedFlashMessage()
        if aiRacers and aiRacers.setPlayerFreeze then aiRacers.setPlayerFreeze(true) end
        mFreeroamCountdownDelay = 1.0
        mFreeroamStagedAtStart = false
        mFreeroamPendingStart = nil
        mFreeroamStagingSubjectID = be and be:getPlayerVehicleID(0) or nil
    end
end

-- Freeroam hub: Back button / clear selection
M.onFreeroamHubClearSelection = function()
    mFreeroamHubRaceSelected = false
    mFreeroamHubShowingResult = false
    hideStagedFlashMessage()
    mFreeroamCountdownDelay = nil
    mFreeroamCountdownEndTime = nil
    mFreeroamCountdownStartClock = nil
    mFreeroamStagedAtStart = false
    mFreeroamPendingStart = nil
    mFreeroamStagingSubjectID = nil
    if aiRacers and aiRacers.clearSpawned then aiRacers.clearSpawned() end
end

M.onFreeroamHubClosed = function()
    mFreeroamHubShowingResult = false
    mFreeroamHubShowingHistory = false
    if previousGameState then
        core_gamestate.setGameState(previousGameState.state, previousGameState.appLayout, previousGameState.menuItems, previousGameState.options)
        previousGameState = nil
        saveGameState = false
    end
end

return M