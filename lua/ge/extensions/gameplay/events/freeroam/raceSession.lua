local M = {}

M.dependencies = { 'gameplay_events_freeroam_session' }

local freConfig = require('gameplay/fre/config')

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

local function utils()
    return gameplay_events_freeroam_utils
end

local function leaderboardManager()
    return gameplay_events_freeroam_leaderboardManager
end

local function circuitRaceAi()
    return gameplay_events_freeroam_circuitRaceAi
end

local function competitiveTrackFlow()
    return gameplay_events_freeroam_competitiveTrackFlow
end

local function getDisplayTotalLapsForRace(r)
    return competitiveTrackFlow().getDisplayTotalLapsForRace(r)
end

local function isLapRaceConfig(r)
    if not r then return false end
    local rs = r.session
    return (r.lapCount and r.lapCount > 0) or r.hotlap or (rs and rs.lapCount and rs.lapCount > 0)
end

local function raceHasType(race, raceType)
    if not race or type(race.type) ~= "table" then return false end
    return utils().tableContains(race.type, raceType)
end

local function hudDisplayLap(completed, totalLapsVal)
    local c = completed or 0
    if type(totalLapsVal) == "number" and totalLapsVal > 0 then
        return math.min(c + 1, totalLapsVal)
    end
    return c + 1
end

local function sess()
  return gameplay_events_freeroam_session
end

local function resolveSessionInventoryFromSpawnId(subjectID)
  if not subjectID then
    return subjectID
  end
  if career_modules_business_businessInventory then
    local businessId, vehicleId = career_modules_business_businessInventory.getBusinessVehicleFromSpawnedId(subjectID)
    if businessId and vehicleId then
      local jobId = career_modules_business_businessInventory.getJobIdFromVehicle(businessId, vehicleId)
      if jobId then
        return career_modules_business_businessInventory.getBusinessJobIdentifier(businessId, jobId)
      end
      return career_modules_business_businessInventory.getBusinessVehicleIdentifier(businessId, vehicleId)
    end
    return career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId(subjectID) or subjectID
  end
  return career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId(subjectID) or subjectID
end

local function onExtensionLoaded()
end

local function notifyFreContractsFreeroamUi()
  if gameplay_events_freContracts_ui and gameplay_events_freContracts_ui.emitUiStateUpdate then
    gameplay_events_freContracts_ui.emitUiStateUpdate("freeroam_session")
  end
end

function M.setStagingSubjectId(v)
    frh.stagingSubjectId = v
end

function M.isRaceHudShown()
    return frh.shown == true
end

function M.setLastLapReward(v)
    frh.lastLapReward = v
end

function M.clearHudCompletionPayload()
    if frh.completionPayload then
        frh.completionPayload = nil
        frh.completionSnapshot = nil
    end
end

function M.clearFreSummarySession()
    frs.laps = {}
    frs.raceName = nil
end

function M.buildFreSummaryPayload()
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
    local u = utils()
    eventData = eventData or {}
    if eventKind == "topSpeed" then
        local goalSpeed = tonumber(eventData.goalSpeed) or 0
        local baseReward = tonumber(eventData.baseReward) or 0
        local raceTypes = eventData.raceTypes or {}
        local targetReward = u.topSpeedReward(goalSpeed, baseReward, goalSpeed, raceTypes)
        local actualReward = u.topSpeedReward(goalSpeed, baseReward, tonumber(eventData.actualSpeed) or 0, raceTypes)
        return safeRatio(actualReward, targetReward)
    elseif eventKind == "drift" then
        local raceStub = {
            bestTime = tonumber(eventData.goalTime) or 0,
            driftGoal = tonumber(eventData.goalDriftScore) or 0,
            reward = tonumber(eventData.baseReward) or 0,
            type = eventData.raceTypes or {}
        }
        local targetReward = u.driftReward(raceStub, raceStub.bestTime, raceStub.driftGoal)
        local actualReward = u.driftReward(raceStub, tonumber(eventData.actualTime) or 0, tonumber(eventData.actualDriftScore) or 0)
        return safeRatio(actualReward, targetReward)
    elseif eventKind == "hybrid" then
        local goalTime = tonumber(eventData.goalTime) or 0
        local baseReward = tonumber(eventData.baseReward) or 0
        local damageFactor = tonumber(eventData.damageFactor) or 0
        local raceTypes = eventData.raceTypes or {}
        local targetReward = u.hybridRaceReward(goalTime, baseReward, goalTime, damageFactor, 0, raceTypes)
        local actualReward = u.hybridRaceReward(goalTime, baseReward, tonumber(eventData.actualTime) or 0, damageFactor, tonumber(eventData.actualDamagePct) or 0, raceTypes)
        return safeRatio(actualReward, targetReward)
    end
    local goalTime = tonumber(eventData.goalTime) or 0
    local baseReward = tonumber(eventData.baseReward) or 0
    local raceTypes = eventData.raceTypes or {}
    local targetReward = u.raceReward(goalTime, baseReward, goalTime, raceTypes)
    local actualReward = u.raceReward(goalTime, baseReward, tonumber(eventData.actualTime) or 0, raceTypes)
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
                log("W", "raceSession", string.format("mergeRewardTables skipped key '%s' (already exists)", tostring(key)))
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

local function shouldSkipFreContractProgressForNotify(completionMeta)
    if completionMeta and completionMeta.skipFreContractProgress == true then
        return true
    end
    if sess().freeroamPracticeStaging == true then
        return false
    end
    if sess().dragPracticeActive and sess().mActiveRace == "drag" then
        return false
    end
    return true
end

local function notifyFreRaceCompleted(raceName, raceData, raceLabel, finishTime, vehicleId, completionMeta)
    if not career_career.isActive() then
        return
    end
    if not gameplay_events_freContracts_race or not gameplay_events_freContracts_race.onFreeroamRaceCompleted then
        return
    end
    local disciplineIds = completionMeta and completionMeta.disciplineIds or getRaceDisciplineIds(raceData)
    local isAltRoute = sess().mAltRoute == true
    gameplay_events_freContracts_race.onFreeroamRaceCompleted({
        raceId = raceName,
        raceName = raceName,
        raceLabel = raceLabel,
        isAltRoute = isAltRoute,
        raceRouteType = isAltRoute and "alt" or "main",
        disciplineIds = disciplineIds,
        rawTypes = raceData and raceData.type or {},
        finishTime = finishTime,
        lapCount = sess().lapCount,
        isHotlap = sess().mHotlap == raceName,
        invalidLap = completionMeta and completionMeta.invalidLap == true or false,
        vehicleId = vehicleId,
        vehicleModel = getFreVehicleModel(vehicleId),
        resultMetrics = {
            time = finishTime,
            maxSpeed = sess().maxSpeed,
            lapCount = sess().lapCount,
            driftScore = completionMeta and completionMeta.driftScore or 0,
            damagePercentage = completionMeta and completionMeta.damagePercentage or 0,
            normalizedPerformance = completionMeta and completionMeta.normalizedPerformance or 0,
            isAltRoute = isAltRoute,
            isHotlap = sess().mHotlap == raceName,
            invalidLap = completionMeta and completionMeta.invalidLap == true or false
        },
        rewardBreakdown = completionMeta and completionMeta.rewardBreakdown or {},
        skipFreContractProgress = shouldSkipFreContractProgressForNotify(completionMeta)
    })
end

local function rewardLabel(raceName, newBestTime)
    local races = sess().races
    local timeLabel = utils().formatTime(sess().in_race_time)
    local raceLabel = races[raceName].label
    local performanceLabel = newBestTime and "New Best Time!" or "Completion"
    local label = string.format("%s - %s: %s", raceLabel, performanceLabel, timeLabel)
    if sess().mAltRoute then
        label = label .. " (Alternative Route)"
    end
    if sess().mHotlap == raceName then
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

local function peekDriftScore()
    if not gameplay_drift_scoring then return nil, nil end
    local scoreData = gameplay_drift_scoring.getScore()
    if not scoreData then return nil, nil end
    local finalScore = tonumber(scoreData.score) or 0
    local cachedScore = tonumber(scoreData.cachedScore) or 0
    local combo = tonumber(scoreData.combo)
    if cachedScore > 0 and combo and combo > 0 then
        finalScore = finalScore + math.floor(cachedScore * combo)
    end
    return finalScore, combo
end

function M.peekLiveDriftScore()
    local s = peekDriftScore()
    return s
end

function M.payoutRace(completedLapTime)
    local u = utils()
    local lb = leaderboardManager()
    local cra = circuitRaceAi()

    if not sess().mActiveRace then
        return 0
    end
    local mActiveRace = sess().mActiveRace
    local races = sess().races
    local race = races[mActiveRace]
    local time = race.bestTime
    local lapTime = (completedLapTime ~= nil and completedLapTime >= 0) and completedLapTime or sess().in_race_time
    local reward = race.reward
    local raceLabel = race.label
    local damageFactor = race.damageFactor or 0

    if sess().mHotlap == mActiveRace then
        time = race.hotlap
    end
    if sess().mAltRoute then
        time = race.altRoute.bestTime
        reward = race.altRoute.reward
        raceLabel = race.altRoute.label
        if sess().mHotlap == mActiveRace then
            time = race.altRoute.hotlap
        end
    end
    if sess().mHotlap == mActiveRace then
        raceLabel = raceLabel .. " (Hotlap)"
    end
    local rewardBaseForPerformance = reward

    local damagePercentage = 0
    if damageFactor > 0 then
        local currentDamage = u.getVehicleDamage()
        local damageTaken = math.max(0, currentDamage - sess().initialVehicleDamage)
        local maxDamage = 100000
        if career_career and career_career.isActive() and career_modules_valueCalculator then
            maxDamage = career_modules_valueCalculator.getInventoryVehicleValue(sess().mInventoryId, true)
        end
        damagePercentage = math.min(1, damageTaken / maxDamage)
    end

    local driftScore = 0
    if race.topSpeed then
        reward = u.topSpeedReward(race.topSpeedGoal, reward, sess().maxSpeed, race.type)
    elseif race.driftGoal then
        driftScore = getDriftScore()
        reward = u.driftReward(races[mActiveRace], time, driftScore)
    elseif damageFactor > 0 then
        reward = u.hybridRaceReward(time, reward, lapTime, damageFactor, damagePercentage, race.type)
    else
        reward = u.raceReward(time, reward, lapTime, race.type)
    end

    local normalizedPerformance = 0
    if race.topSpeed then
        normalizedPerformance = calculateEventPerformanceRatio("topSpeed", {
            goalSpeed = race.topSpeedGoal,
            baseReward = rewardBaseForPerformance,
            actualSpeed = sess().maxSpeed,
            raceTypes = race.type
        })
    elseif race.driftGoal then
        normalizedPerformance = calculateEventPerformanceRatio("drift", {
            goalTime = race.driftTargetTime or time,
            goalDriftScore = race.driftGoal,
            baseReward = rewardBaseForPerformance,
            actualTime = sess().in_race_time,
            actualDriftScore = driftScore,
            raceTypes = race.type
        })
    elseif damageFactor > 0 then
        normalizedPerformance = calculateEventPerformanceRatio("hybrid", {
            goalTime = time,
            baseReward = rewardBaseForPerformance,
            actualTime = sess().in_race_time,
            damageFactor = damageFactor,
            actualDamagePct = damagePercentage,
            raceTypes = race.type
        })
    else
        normalizedPerformance = calculateEventPerformanceRatio("time", {
            goalTime = time,
            baseReward = rewardBaseForPerformance,
            actualTime = sess().in_race_time,
            raceTypes = race.type
        })
    end

    local inventoryIdToUse = sess().mInventoryId
    if inventoryIdToUse and tostring(inventoryIdToUse):match("^business_.+_job_") then
        inventoryIdToUse = inventoryIdToUse
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
            elseif inventoryIdToUse and not tostring(inventoryIdToUse):match("^business_") then
                inventoryIdToUse = inventoryIdToUse
            end
        end
    end

    local leaderboardEntry = lb.getLeaderboardEntry(inventoryIdToUse, raceLabel)
    local oldTime = leaderboardEntry and leaderboardEntry.time or 0
    local oldScore = leaderboardEntry and leaderboardEntry.driftScore or 0
    local oldTopSpeedRecord = leaderboardEntry and leaderboardEntry.topSpeed or nil
    local oldDamagePctRecord = leaderboardEntry and leaderboardEntry.damagePercentage and leaderboardEntry.damagePercentage * 100 or nil

    local newEntry = {
        raceName = mActiveRace,
        raceLabel = raceLabel,
        isAltRoute = sess().mAltRoute,
        isHotlap = sess().mHotlap == mActiveRace,
        time = lapTime,
        splitTimes = sess().mSplitTimes,
        driftScore = driftScore,
        inventoryId = inventoryIdToUse,
        damagePercentage = damagePercentage,
        damageFactor = damageFactor,
        topSpeed = sess().maxSpeed,
        reward = reward
    }

    local invalidLap = sess().invalidLap
    local newBest = false
    if not invalidLap then
        newBest = lb.addLeaderboardEntry(newEntry)
    end

    local message = invalidLap and "Lap Invalidated\n" or ""

    if race.topSpeed then
        message = message ..
            string.format("%s\nTop Speed: %.2f mph\nTime: %s", raceLabel, sess().maxSpeed, u.formatTime(lapTime))
        if oldTime then
            local oldSpeed = leaderboardEntry and leaderboardEntry.topSpeed or 0
            message = message ..
                string.format("\nPrevious Best Speed: %.2f mph\nPrevious Best Time: %s", oldSpeed, u.formatTime(oldTime))
        end
    elseif race.driftGoal then
        message = message ..
            string.format("%s\nDrift Score: %d\nTime: %s", raceLabel, driftScore, u.formatTime(lapTime))
        if oldScore and oldTime then
            message = message ..
                string.format("\nPrevious Best Score: %d\nPrevious Best Time: %s", oldScore, u.formatTime(oldTime))
        end
    else
        if newBest and not invalidLap then
            if damageFactor > 0 then
                message = message .. "New Best Score!\n"
            else
                message = message .. "New Best Time!\n"
            end
        end
        if race.hotlap then
            message = message .. string.format("%s\nTime: %s\nLap: %d", raceLabel, u.formatTime(lapTime), sess().lapCount)
        else
            message = message .. string.format("%s\nTime: %s", raceLabel, u.formatTime(lapTime))
        end
        if damageFactor > 0 then
            message = message .. string.format("\nDamage Taken: %.1f%% | Damage Factor: %.0f%%",
                damagePercentage * 100, damageFactor * 100)
        end
        if newBest and not invalidLap and oldTime ~= math.huge then
            if damageFactor > 0 then
                local oldDamagePercentage = leaderboardEntry and leaderboardEntry.damagePercentage or 0
                message = message .. string.format("\nPrevious Best Time: %s | Previous Best Damage: %.1f%%",
                    u.formatTime(oldTime), oldDamagePercentage * 100)
            else
                message = message .. string.format("\nPrevious Best: %s", u.formatTime(oldTime))
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
    if career_career.isActive() then
        if completionMeta.skipFreContractProgress then
            reward = 0
            sess().lapCount = (invalidLap and 1 or sess().lapCount)
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
        if not newBest or sess().mHotlap then
            reward = reward / 2
        end
        reward = invalidLap and 0 or reward
        sess().lapCount = (invalidLap and 1 or sess().lapCount)
        if race.hotlap then
            local hlMult = u.hotlapMultiplier(sess().lapCount)
            reward = reward * hlMult
            hotlapMessage = string.format("\nHotlap Multiplier: %.2f", hlMult)
            table.insert(payoutBonuses, { label = "Hotlap multiplier", value = string.format("×%.2f", hlMult) })
        end

        if newBest and not sess().newBestSession then
            sess().newBestSession = true
        end

        if sess().newBestSession then
            reward = reward * 1.2
            hotlapMessage = hotlapMessage .. "\nNew Best Session Bonus: 20%"
            table.insert(payoutBonuses, { label = "New best session bonus", value = "+20%" })
        end

        if oldTime and (newEntry.time - (oldTime * 0.025) < oldTime) then
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
                        money = { amount = businessReward }
                    }, businessAccount.id, "Event Reward", rewardLabel(mActiveRace, newBest))
                end
                message = message .. string.format("\nDiscipline XP: %d | Business Reward: $%.2f (50%% to business account)", totalDisciplineXp, businessReward)
            else
                local totalReward = { money = { amount = reward } }
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
    local skipMidLapHud = cra.isSanctionedTriggerOnlyLapRace() and completedLapTime ~= nil
    if M.raceHudApplies(race) and frh.shown and not skipMidLapHud then
        local isDragRace = raceHasType(race, "drag")
        local kind = "time"
        if isDragRace then
            kind = "drag"
        elseif race.topSpeed then
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
            if race.topSpeed or race.driftGoal then
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
                lapIndex = race.hotlap and sess().lapCount or nil,
                topSpeed = (race.topSpeed or isDragRace) and sess().maxSpeed or nil,
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
        local cleanLabel = (sess().mAltRoute and race.altRoute and race.altRoute.label) or race.label
        table.insert(frs.laps, {
            index = #frs.laps + 1,
            isAlt = sess().mAltRoute == true,
            time = lapTime,
            money = lapMoney,
            xp = lapXp,
            invalid = invalidLap == true,
            raceLabelShort = cleanLabel,
        })
    end

    local cpHud = race.checkpointRoad and frh.shown
    notifyFreRaceCompleted(mActiveRace, race, raceLabel, sess().in_race_time, be:getPlayerVehicleID(0), completionMeta)
    sess().mActiveRace = nil
    notifyFreContractsFreeroamUi()
    if not cpHud then
        u.displayMessage(message, 20)
        if hotlapMessage ~= "" then
            ui_message(hotlapMessage, 5, "Hotlap Multiplier")
        end
        return reward
    end
    return reward, hudCompletionPayload
end

function M.payoutDragRace(raceName, finishTime, finishSpeed, vehId)
    local u = utils()
    local lb = leaderboardManager()
    local races = sess().races
    local inventoryIdToUse = vehId
    if career_career.isActive() then
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

    local leaderboardEntry = lb.getLeaderboardEntry(inventoryIdToUse, races["drag"].label)
    local oldTime = leaderboardEntry and leaderboardEntry.time or 0
    local newEntry = {
        raceLabel = races["drag"].label,
        raceName = raceName,
        time = finishTime,
        splitTimes = sess().mSplitTimes,
        inventoryId = inventoryIdToUse
    }
    local newBestTime = lb.addLeaderboardEntry(newEntry)

    local raceData = races[raceName]
    if not career_career.isActive() then
        local message = string.format("%s\nTime: %s\nSpeed: %.2f mph", raceData.label, u.formatTime(finishTime), finishSpeed)
        if not (frh.shown and M.raceHudApplies(raceData)) then
            u.displayMessage(message, 10)
        end
        return 0
    end

    local targetTime = raceData.bestTime
    local baseReward = raceData.reward
    local disciplineIds = getRaceDisciplineIds(raceData)
    local normalizedPerformance = calculateEventPerformanceRatio("time", {
        goalTime = targetTime,
        baseReward = baseReward,
        actualTime = finishTime,
        raceTypes = raceData.type
    })
    local reward = u.raceReward(targetTime, baseReward, finishTime, raceData.type)
    if reward <= 0 then
        reward = baseReward / 2
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
    for _, rewardInfo in pairs(disciplineXpRewards) do
        if type(rewardInfo) == "table" and rewardInfo.amount ~= nil then
            rewardInfo.amount = math.max(0, math.floor((tonumber(rewardInfo.amount) or 0) * 2))
        end
    end
    for _, info in pairs(disciplineXpBreakdown) do
        if type(info) == "table" and info.amount ~= nil then
            info.amount = math.max(0, math.floor((tonumber(info.amount) or 0) * 2))
        end
    end
    totalDisciplineXp = math.max(0, math.floor((tonumber(totalDisciplineXp) or 0) * 2))
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
    local hudDisciplineXp = totalDisciplineXp
    local hudMoney, hudBusinessMoney = nil, nil
    local suppressRewardToast = frh.shown and M.raceHudApplies(raceData)
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
                money = { amount = businessReward }
            }, businessAccount.id, "Event Reward", raceData.label .. (newBestTime and " - New Best Time!" or " - Completion"))
        end
        local message = string.format("%s\n%s\nTime: %s\nSpeed: %.2f mph\nDiscipline XP: %d | Business Reward: $%.2f (50%% to business account)",
            newBestTime and "Congratulations! New Best Time!" or "", raceData.label, u.formatTime(finishTime), finishSpeed, totalDisciplineXp, businessReward)
        if not suppressRewardToast then
            ui_message(message, 20, "Reward")
        end
        hudBusinessMoney = businessReward
    else
        local totalReward = { money = { amount = reward } }
        mergeRewardTables(totalReward, disciplineXpRewards)
        local reason = {
            label = raceData.label .. (newBestTime and " - New Best Time!" or " - Completion"),
            tags = {"gameplay", "reward", "drag"}
        }
        career_modules_payment.reward(totalReward, reason, true)
        local message = string.format("%s\n%s\nTime: %s\nSpeed: %.2f mph\nDiscipline XP: %d | Reward: $%.2f",
            newBestTime and "Congratulations! New Best Time!" or "", raceData.label, u.formatTime(finishTime), finishSpeed, totalDisciplineXp, reward)
        if not suppressRewardToast then
            ui_message(message, 20, "Reward")
        end
        hudMoney = reward
    end
    career_saveSystem.saveCurrent()
    notifyFreRaceCompleted(raceName, raceData, raceData.label, finishTime, vehId, completionMeta)
    if M.raceHudApplies(raceData) and frh.shown then
        sess().maxSpeed = math.max(sess().maxSpeed or 0, finishSpeed)
        local prevTimeShow = nil
        if type(oldTime) == "number" and oldTime > 0 and oldTime ~= math.huge then
            prevTimeShow = oldTime
        end
        local headline = newBestTime and "New Best Time!" or "Lap complete"
        local hudCompletionPayload = {
            invalidLap = false,
            headline = headline,
            raceTitle = raceData.label,
            kind = "drag",
            result = {
                time = finishTime,
                topSpeed = sess().maxSpeed,
            },
            previous = {
                time = prevTimeShow,
            },
            rewards = {
                disciplineXp = hudDisciplineXp,
                money = hudMoney,
                businessMoney = hudBusinessMoney,
            },
            bonuses = {},
        }
        sess().mActiveRace = nil
        sess().timerActive = false
        sess().dragPracticeActive = false
        notifyFreContractsFreeroamUi()
        M.pushRaceHudCompletion(hudCompletionPayload, raceName, raceData.label, races["drag"].label, finishTime, true)
    end
    return reward
end

function M.getDifference(raceName, currentCheckpointIndex)
    local raceLabel = gameplay_events_freeroamEvents.getFreeroamRaceLabel()
    local lb = leaderboardManager()
    local leaderboardEntry = lb.getLeaderboardEntry(sess().mInventoryId, raceLabel)
    if not leaderboardEntry then
        return nil
    end
    local splitTimes = leaderboardEntry.splitTimes
    if not splitTimes or not splitTimes[currentCheckpointIndex] then
        return nil
    end
    local mSplitTimes = sess().mSplitTimes
    if not mSplitTimes[currentCheckpointIndex] or not splitTimes[currentCheckpointIndex] then
        return nil
    end
    local races = sess().races
    local race = races and races[raceName]
    local effectiveRace = race and ((sess().mAltRoute and race.altRoute) and race.altRoute or race) or nil
    local useDriftScoreSplits = effectiveRace and effectiveRace.driftGoal
    local currentSplitDiff
    if currentCheckpointIndex == 1 then
        if useDriftScoreSplits then
            currentSplitDiff = splitTimes[currentCheckpointIndex] - mSplitTimes[currentCheckpointIndex]
        else
            currentSplitDiff = mSplitTimes[currentCheckpointIndex] - splitTimes[currentCheckpointIndex]
        end
    else
        if not mSplitTimes[currentCheckpointIndex - 1] or not splitTimes[currentCheckpointIndex - 1] then
            return nil
        end
        local previousBestSplit = splitTimes[currentCheckpointIndex] - splitTimes[currentCheckpointIndex - 1]
        local currentSplit = mSplitTimes[currentCheckpointIndex] - mSplitTimes[currentCheckpointIndex - 1]
        if useDriftScoreSplits then
            currentSplitDiff = previousBestSplit - currentSplit
        else
            currentSplitDiff = currentSplit - previousBestSplit
        end
    end
    return currentSplitDiff
end

local function iroundDiff(x)
    if x >= 0 then return math.floor(x + 0.5) end
    return math.ceil(x - 0.5)
end

function M.formatSplitDifference(diff, asScore)
    if asScore then
        local r = iroundDiff(diff)
        if r > 0 then return string.format("+%d", r) end
        return string.format("%d", r)
    end
    local sign = diff >= 0 and "+" or "-"
    return string.format("%s%s", sign, utils().formatTime(math.abs(diff)))
end

function M.setRaceHudBanner(text, kind, ttlSeconds)
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

function M.raceUsesProcessRoadExit(race)
    return race and race.checkpointRoad
end

function M.raceHudApplies(race)
    if not race then return false end
    if race.checkpointRoad then return true end
    if race.driftGoal then return true end
    if raceHasType(race, "drift") or raceHasType(race, "drag") then return true end
    return false
end

local function canBuildRaceHudPayload()
    local races = sess().races
    if not races then return false end
    if frh.completionSnapshot and frh.shown and not sess().mActiveRace then return true end
    if sess().mActiveRace and races[sess().mActiveRace] and M.raceHudApplies(races[sess().mActiveRace]) then return true end
    if sess().staged and races[sess().staged] and M.raceHudApplies(races[sess().staged]) then return true end
    return false
end

function M.buildFreeroamRaceHudPayload()
    local u = utils()
    local ctf = competitiveTrackFlow()
    local cra = circuitRaceAi()
    local banner = bannerPayloadForHud()
    local races = sess().races
    if frh.completionSnapshot and frh.shown and not sess().mActiveRace then
        local s = frh.completionSnapshot
        local lastRew = frh.lastLapReward
        frh.lastLapReward = nil
        local standingsSnap = (not frh.completionPayload) and cra.buildSanctionedHudStandingsPayload() or nil
        return {
            phase = "racing",
            raceLabel = s.raceLabel,
            routeName = s.routeName,
            displayLap = s.displayLap,
            totalLaps = s.totalLaps,
            isLapRace = s.isLapRace,
            goalTime = s.goalTime,
            personalBestTime = s.personalBestTime,
            driftGoal = s.driftGoal,
            personalBestDriftScore = s.personalBestDriftScore,
            sectorSplitsUseScore = s.sectorSplitsUseScore,
            currentLapTime = s.currentLapTime,
            bestLapThisRun = s.bestLapThisRun,
            invalidLap = s.invalidLap,
            totalCheckpoints = s.totalCheckpoints,
            checkpointsHit = 0,
            sectors = {},
            standings = standingsSnap,
            completion = frh.completionPayload,
            banner = banner,
            lastLapReward = lastRew,
        }
    end
    if sess().mActiveRace and races[sess().mActiveRace] and M.raceHudApplies(races[sess().mActiveRace]) then
        local race = races[sess().mActiveRace]
        local effectiveRace = (sess().mAltRoute and race.altRoute) and race.altRoute or race
        local raceLabelFull = gameplay_events_freeroamEvents.getFreeroamRaceLabel()
        local displayLabel = gameplay_events_freeroamEvents.getFreeroamDisplayRaceLabel()
        local lbEntry = sess().mInventoryId and leaderboardManager().getLeaderboardEntry(sess().mInventoryId, raceLabelFull) or {}
        local isLapRace = isLapRaceConfig(effectiveRace)
        local isDragRace = raceHasType(effectiveRace, "drag")
        local totalLapsVal = ctf.resolveRacingHudTotalLaps(sess().mActiveRace, sess(), effectiveRace, isLapRace)
        local displayLapNum = isLapRace and hudDisplayLap(sess().lapCount, totalLapsVal) or 1
        local sectors = {}
        if not frh.completionPayload then
            for i = sess().checkpointsHit, 1, -1 do
                local cum = sess().mSplitTimes[i]
                if cum ~= nil then
                    local prev = (i > 1) and sess().mSplitTimes[i - 1] or nil
                    local sectorTime = (prev ~= nil) and (cum - prev) or cum
                    local delta = M.getDifference(sess().mActiveRace, i)
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
        local standingsLive = (not frh.completionPayload) and cra.buildSanctionedHudStandingsPayload() or nil
        local driftScoreLive, driftComboLive = nil, nil
        if effectiveRace and effectiveRace.driftGoal then
            driftScoreLive, driftComboLive = peekDriftScore()
        end
        local sectorSplitsUseScore = effectiveRace and effectiveRace.driftGoal and
            (tonumber(sess().totalCheckpoints) or 0) > 0
        local isDriftRace = effectiveRace and effectiveRace.driftGoal
        local personalBestDriftScore = nil
        if isDriftRace and type(lbEntry.driftScore) == "number" then
            personalBestDriftScore = lbEntry.driftScore
        end
        local goalTimePb = not isDriftRace and effectiveRace.bestTime or nil
        local personalBestTimePb = not isDriftRace and lbEntry.time or nil
        return {
            phase = "racing",
            raceLabel = displayLabel,
            routeName = sess().mCurrentRouteName,
            displayLap = displayLapNum,
            totalLaps = totalLapsVal,
            isLapRace = isLapRace and true or false,
            goalTime = goalTimePb,
            personalBestTime = personalBestTimePb,
            personalBestDriftScore = personalBestDriftScore,
            currentLapTime = sess().in_race_time,
            bestLapThisRun = sess().mBestLapThisRun,
            invalidLap = sess().invalidLap and true or false,
            totalCheckpoints = sess().totalCheckpoints,
            checkpointsHit = sess().checkpointsHit,
            sectors = sectors,
            standings = standingsLive,
            completion = frh.completionPayload,
            banner = banner,
            lastLapReward = lastRew,
            driftGoal = isDriftRace and effectiveRace.driftGoal or nil,
            driftScoreLive = driftScoreLive,
            driftComboLive = driftComboLive,
            dragSpeedLive = isDragRace and sess().maxSpeed or nil,
            sectorSplitsUseScore = sectorSplitsUseScore and true or false,
        }
    end
    local staged = sess().staged
    if staged and races[staged] and M.raceHudApplies(races[staged]) then
        local raceName = staged
        local race = races[raceName]
        local effectiveStagingRace = ctf.resolveEffectiveStagingRace(raceName, race)
        local displayLabel = race.label or raceName
        local invId = frh.stagingSubjectId
        local lbEntry = invId and leaderboardManager().getLeaderboardEntry(invId, displayLabel) or {}
        local isLapRace = isLapRaceConfig(effectiveStagingRace)
        local totalLapsVal = ctf.resolveStagingHudTotalLaps(raceName, sess(), sess().mHotlap, effectiveStagingRace, isLapRace)
        local stagingUi = { blocks = {} }
        if invId then
            stagingUi = u.getStagingHudBreakdown(invId, raceName) or stagingUi
        end
        local stDrift = effectiveStagingRace and effectiveStagingRace.driftGoal
        local stPbDrift = nil
        if stDrift and type(lbEntry.driftScore) == "number" then
            stPbDrift = lbEntry.driftScore
        end
        return {
            phase = "staging",
            raceLabel = displayLabel,
            routeName = nil,
            displayLap = 1,
            totalLaps = totalLapsVal,
            isLapRace = isLapRace and true or false,
            goalTime = not stDrift and effectiveStagingRace.bestTime or nil,
            personalBestTime = not stDrift and lbEntry.time or nil,
            personalBestDriftScore = stPbDrift,
            driftGoal = stDrift and effectiveStagingRace.driftGoal or nil,
            sectorSplitsUseScore = false,
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

function M.pushFreeroamRaceHudState(force)
    if not frh.shown or not canBuildRaceHudPayload() then return end
    local now = (os and os.clock) and os.clock() or 0
    if not force and frh.pushClock and (now - frh.pushClock) < RACE_HUD_PUSH_INTERVAL then return end
    frh.pushClock = now
    local payload = M.buildFreeroamRaceHudPayload()
    if payload and guihooks and guihooks.trigger then
        guihooks.trigger("FreeroamRaceHudState", payload)
    end
end

function M.showFreeroamRaceHud()
    if not guihooks or not guihooks.trigger then return end
    guihooks.trigger("FreeroamRaceHudShow")
    frh.shown = true
    frh.pushClock = nil
    M.pushFreeroamRaceHudState(true)
end

function M.hideFreeroamRaceHud(force)
    if not force and sess().mActiveRace then
        return
    end
    frh.shown = false
    frh.pushClock = nil
    frh.banner = nil
    frh.stagingSubjectId = nil
    frh.lastLapReward = nil
    frh.completionPayload = nil
    frh.completionSnapshot = nil
    if guihooks and guihooks.trigger then guihooks.trigger("FreeroamRaceHudHide") end
end

function M.beginDragPracticeFreeroamHud(vehId)
    local races = sess().races
    if not races or not races["drag"] or not vehId then
        return
    end
    sess().dragPracticeFlow = true
    sess().staged = "drag"
    M.prepareNewRaceHudState("drag")
    M.setStagingSubjectId(resolveSessionInventoryFromSpawnId(vehId))
    M.showFreeroamRaceHud()
    notifyFreContractsFreeroamUi()
end

function M.beginDragPracticeFreeroamRace(vehId)
    local races = sess().races
    if not races or not races["drag"] or not vehId then
        return
    end
    sess().staged = nil
    M.setStagingSubjectId(nil)
    if career_career and career_career.isActive and career_career.isActive() and career_modules_pauseTime then
        career_modules_pauseTime.enablePauseCounter(true)
    end
    sess().timerActive = true
    sess().in_race_time = 0
    sess().maxSpeed = 0
    sess().mActiveRace = "drag"
    sess().dragPracticeActive = true
    sess().mInventoryId = resolveSessionInventoryFromSpawnId(vehId)
    sess().invalidLap = false
    local u = utils()
    M.setRaceHudBanner(u.getRaceStartBannerText("drag"), "good", 5)
    M.pushFreeroamRaceHudState(true)
    notifyFreContractsFreeroamUi()
end

function M.endDragPracticeFreeroamHud()
    if not sess().dragPracticeFlow then
        return
    end
    sess().dragPracticeFlow = false
    sess().dragPracticeActive = false
    sess().staged = nil
    sess().mActiveRace = nil
    sess().timerActive = false
    sess().in_race_time = 0
    M.setStagingSubjectId(nil)
    M.hideFreeroamRaceHud()
    notifyFreContractsFreeroamUi()
end

function M.pushRaceHudCompletion(completionPayload, raceName, displayLabel, leaderboardLabel, currentLapTime, freezeCard)
    local races = sess().races
    if not completionPayload or type(completionPayload) ~= "table" or not frh.shown then return end
    if not raceName or not races[raceName] or not M.raceHudApplies(races[raceName]) then return end
    frh.completionPayload = completionPayload
    if freezeCard then
        local race = races[raceName]
        local effectiveRace = (sess().mAltRoute and race.altRoute) and race.altRoute or race
        local isLapRace = isLapRaceConfig(effectiveRace)
        local totalLapsSnap = isLapRace and getDisplayTotalLapsForRace(effectiveRace) or 0
        local lbEntry = sess().mInventoryId and leaderboardManager().getLeaderboardEntry(sess().mInventoryId, leaderboardLabel or displayLabel) or {}
        local snapDrift = effectiveRace and effectiveRace.driftGoal
        local snapPbDrift = nil
        if snapDrift and type(lbEntry.driftScore) == "number" then
            snapPbDrift = lbEntry.driftScore
        end
        frh.completionSnapshot = {
            raceLabel = displayLabel,
            routeName = sess().mCurrentRouteName,
            displayLap = isLapRace and hudDisplayLap(sess().lapCount, totalLapsSnap) or 1,
            totalLaps = totalLapsSnap,
            isLapRace = isLapRace and true or false,
            goalTime = not snapDrift and effectiveRace.bestTime or nil,
            personalBestTime = not snapDrift and lbEntry.time or nil,
            driftGoal = snapDrift and effectiveRace.driftGoal or nil,
            personalBestDriftScore = snapPbDrift,
            sectorSplitsUseScore = snapDrift and (tonumber(sess().totalCheckpoints) or 0) > 0 or false,
            currentLapTime = currentLapTime,
            bestLapThisRun = sess().mBestLapThisRun,
            invalidLap = sess().invalidLap and true or false,
            totalCheckpoints = sess().totalCheckpoints,
            checkpointsHit = 0,
        }
    else
        frh.completionSnapshot = nil
    end
    M.pushFreeroamRaceHudState(true)
end

function M.prepareNewRaceHudState(raceName)
    local races = sess().races
    frh.stagingSubjectId = nil
    frh.completionPayload = nil
    frh.completionSnapshot = nil
    frs.laps = {}
    frs.raceName = raceName
    frs.displayLabel = races[raceName].label or raceName
    frs.mainLabel = races[raceName].label or raceName
    frs.altLabel = (races[raceName].altRoute and races[raceName].altRoute.label) or nil
    frs.openLoop = races[raceName].checkpointRoad == true and not utils().hasFinishTrigger(raceName)
end

function M.buildFreRaceCompletionCelebrationEntry(finalResult, hudCompletionPl)
    local u = utils()
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
    local lapRows = {}
    for _, lap in ipairs(frs.laps or {}) do
        table.insert(lapRows, {
            index = lap.index,
            time = u.formatTime(lap.time),
            invalid = lap.invalid == true,
        })
    end
    local bestIdx = nil
    if #lapRows > 1 then
        local best = math.huge
        for _, lap in ipairs(frs.laps or {}) do
            if not lap.invalid and lap.time < best then
                best = lap.time
                bestIdx = lap.index
            end
        end
    end
    for _, lr in ipairs(lapRows) do
        lr.isBest = (bestIdx ~= nil and lr.index == bestIdx)
    end
    local sanctionedNoRewardDetail = nil
    if type(finalResult.sanctionedNoRewardDetail) == "string" and finalResult.sanctionedNoRewardDetail ~= "" then
        sanctionedNoRewardDetail = finalResult.sanctionedNoRewardDetail
    elseif hudCompletionPl and type(hudCompletionPl.sanctionedNoRewardDetail) == "string" and
        hudCompletionPl.sanctionedNoRewardDetail ~= "" then
        sanctionedNoRewardDetail = hudCompletionPl.sanctionedNoRewardDetail
    end
    return {
        raceLabel = finalResult.raceLabel or "Race",
        rewardMoney = money,
        rewardXp = xp,
        position = place,
        fieldSize = fieldSize,
        raceTime = u.formatTime(finalResult.totalTime or 0),
        bestLap = finalResult.bestLap and u.formatTime(finalResult.bestLap) or nil,
        lapsCompleted = finalResult.lapsCompleted,
        lapsTotal = finalResult.lapsTotal,
        lapRows = lapRows,
        summaryLines = {},
        sanctionedNoRewardDetail = sanctionedNoRewardDetail,
    }
end

function M.maybeShowFreerunSummary(cpRoad, isCompletion, deferResultScreen)
    if not (cpRoad and not isCompletion and not deferResultScreen) then return end
    if not sess().freeroamPracticeStaging then return end
    if #frs.laps <= 1 then return end
    if guihooks and guihooks.trigger then
        guihooks.trigger("FreerunSummaryShow", M.buildFreSummaryPayload())
    end
    frs.laps = {}
    frs.raceName = nil
end

M.onExtensionLoaded = onExtensionLoaded

return M

