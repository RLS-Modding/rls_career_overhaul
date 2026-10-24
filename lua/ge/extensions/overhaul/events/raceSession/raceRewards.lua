-- Race performance, leaderboard updates, discipline XP, payouts and HUD results.
-- Read per-load policy helpers, ordered result/settlement steps and the payout service.
local capabilities = require("overhaul/lib/platform/capabilities")
local eventHelpers = require("overhaul/lib/events/helpers")
local driftScoreReader = require("overhaul/lib/events/driftScore")

local lib = {}

function lib.create(ownerServices)
  local M = ownerServices.M
  local freConfig = ownerServices.freConfig
  local raceHud = ownerServices.raceHud
  local raceSummary = ownerServices.raceSummary

  -- allowNetDebit lets a wallet leg end net negative (imported race data can carry a signed base reward).
  local function payoutReward(rewards, reason, accountId, allowNetDebit)
    local xp = {}
    for key, info in pairs(rewards) do
      if key ~= "money" then xp[key] = info.amount end
    end
    local accepted, problem = overhaul_career_economy_payment.payout(require("overhaul/lib/finance/metadata").tagPayout({
      amount = rewards.money and rewards.money.amount,
      allowNetDebit = allowNetDebit,
      xp = next(xp) and xp or nil,
      reason = reason,
      fullReward = true,
      destination = accountId and { kind = "account", accountId = accountId } or nil,
    }, "activity:racing", {vehicleRole = "player"}))
    -- Race completion historically proceeds on refusal; never retry a potentially posted leg.
    if accepted ~= true then return false, problem end
    return true
  end

  local function getRaceDisciplineIds(raceData)
    local disciplineIds = {}
    local seen = {}
    if type(raceData) ~= "table" then return disciplineIds end
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
      disciplineMultipliers = {},
    }
    if not overhaul_events_fre_race or not overhaul_events_fre_race.calculateRewardModifiers then
      return defaultModifiers
    end
    local computed = overhaul_events_fre_race.calculateRewardModifiers(disciplineIds or {})
    if type(computed) ~= "table" then return defaultModifiers end
    computed.moneyMultiplier = tonumber(computed.moneyMultiplier) or 1
    computed.disciplineMultipliers = type(computed.disciplineMultipliers) == "table" and computed.disciplineMultipliers
      or {}
    return computed
  end

  local function resolveTierByUnlockLevel(level, unlockCfg)
    local numericLevel = math.max(0, math.floor(tonumber(level) or 0))
    local tiers = unlockCfg or {}
    local selected = "easy"
    if numericLevel >= (tonumber(tiers.medium) or math.huge) then selected = "medium" end
    if numericLevel >= (tonumber(tiers.hard) or math.huge) then selected = "hard" end
    return selected
  end

  local function safeRatio(numerator, denominator)
    local numericDenominator = tonumber(denominator) or 0
    if numericDenominator <= 0 then return 0 end
    return math.max(0, (tonumber(numerator) or 0) / numericDenominator)
  end

  local function calculateEventPerformanceRatio(eventKind, eventData)
    local raceUtils = ownerServices.utils()
    eventData = eventData or {}
    if eventKind == "topSpeed" then
      local goalSpeed = tonumber(eventData.goalSpeed) or 0
      local baseReward = tonumber(eventData.baseReward) or 0
      local raceTypes = eventData.raceTypes or {}
      local targetReward = raceUtils.topSpeedReward(goalSpeed, baseReward, goalSpeed, raceTypes)
      local actualReward =
        raceUtils.topSpeedReward(goalSpeed, baseReward, tonumber(eventData.actualSpeed) or 0, raceTypes)
      return safeRatio(actualReward, targetReward)
    elseif eventKind == "drift" then
      local raceStub = {
        bestTime = tonumber(eventData.goalTime) or 0,
        driftGoal = tonumber(eventData.goalDriftScore) or 0,
        reward = tonumber(eventData.baseReward) or 0,
        type = eventData.raceTypes or {},
      }
      local targetReward = raceUtils.driftReward(raceStub, raceStub.bestTime, raceStub.driftGoal)
      local actualReward =
        raceUtils.driftReward(raceStub, tonumber(eventData.actualTime) or 0, tonumber(eventData.actualDriftScore) or 0)
      return safeRatio(actualReward, targetReward)
    elseif eventKind == "hybrid" then
      local goalTime = tonumber(eventData.goalTime) or 0
      local baseReward = tonumber(eventData.baseReward) or 0
      local damageFactor = tonumber(eventData.damageFactor) or 0
      local raceTypes = eventData.raceTypes or {}
      local targetReward = raceUtils.hybridRaceReward(goalTime, baseReward, goalTime, damageFactor, 0, raceTypes)
      local actualReward = raceUtils.hybridRaceReward(
        goalTime,
        baseReward,
        tonumber(eventData.actualTime) or 0,
        damageFactor,
        tonumber(eventData.actualDamagePct) or 0,
        raceTypes
      )
      return safeRatio(actualReward, targetReward)
    end
    local goalTime = tonumber(eventData.goalTime) or 0
    local baseReward = tonumber(eventData.baseReward) or 0
    local raceTypes = eventData.raceTypes or {}
    local targetReward = raceUtils.raceReward(goalTime, baseReward, goalTime, raceTypes)
    local actualReward = raceUtils.raceReward(goalTime, baseReward, tonumber(eventData.actualTime) or 0, raceTypes)
    return safeRatio(actualReward, targetReward)
  end

  local function buildDisciplineXpRewards(disciplineIds, normalizedPerformance, rewardModifiers)
    local rewards = {}
    local breakdown = {}
    local totalXp = 0
    local perDiscipline = (rewardModifiers or {}).disciplineMultipliers or {}
    local seenSkillKeys = {}
    for _, disciplineId in ipairs(disciplineIds or {}) do
      local skillKey = freConfig.getSkillKey(disciplineId)
      if skillKey and not seenSkillKeys[skillKey] then
        seenSkillKeys[skillKey] = true
        local eventXpCfg = freConfig.getEventXpConfig(disciplineId) or {}
        local level = tonumber((perDiscipline[disciplineId] or {}).level) or 0
        local tier = resolveTierByUnlockLevel(level, eventXpCfg.tierUnlockLevels or {})
        local tierCurveCfg = (eventXpCfg.xpByTier or {})[tier] or {}
        local baseAmount = 0
        if overhaul_events_fre_skills and overhaul_events_fre_skills.calculateXpFromTierCurve then
          baseAmount = overhaul_events_fre_skills.calculateXpFromTierCurve(tierCurveCfg, normalizedPerformance)
        end
        local xpMultiplier = tonumber((perDiscipline[disciplineId] or {}).xpMultiplier) or 1
        local amount = math.max(0, math.floor(baseAmount * xpMultiplier))
        rewards[skillKey] = rewards[skillKey] or { amount = 0 }
        rewards[skillKey].amount = rewards[skillKey].amount + amount
        breakdown[disciplineId] = {
          skillKey = skillKey,
          tier = tier,
          baseAmount = baseAmount,
          amount = amount,
          xpMultiplier = xpMultiplier,
          normalizedPerformance = tonumber(normalizedPerformance) or 0,
        }
        totalXp = totalXp + amount
      end
    end
    return rewards, breakdown, totalXp
  end

  local function mergeRewardTables(target, source, overwrite, warnOnOverwrite)
    if type(target) ~= "table" or type(source) ~= "table" then return end
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
    if overhaul_events_fre_race and overhaul_events_fre_race.getCurrentVehicleModel then
      return overhaul_events_fre_race.getCurrentVehicleModel(vehId)
    end
    return nil
  end

  local function getBusinessAccountFromVehicle(spawnedVehicleId)
    if not overhaul_career_career.isActive() then return nil end
    local businessId, vehicleId = overhaul_career_business_fleet.getBusinessVehicleFromSpawnedId(spawnedVehicleId)
    if not businessId or not vehicleId then return nil end
    local businessTypes = { "tuningShop", "racingTeam" }
    for _, businessType in ipairs(businessTypes) do
      local owned = overhaul_career_business_manager.isPurchasedBusiness(businessType, businessId)
      if owned then
        local businessAccount = overhaul_career_economy_bank.getBusinessAccount(businessType, businessId)
        if businessAccount then return businessAccount, businessType, businessId end
      end
    end
    return nil
  end

  local function shouldSkipFreContractProgressForNotify(completionMeta)
    if completionMeta and completionMeta.skipFreContractProgress == true then return true end
    if ownerServices.sess().freeroamPracticeStaging == true then return false end
    if ownerServices.sess().dragPracticeActive and ownerServices.raceHasType(
      ownerServices.sess().races[ownerServices.sess().mActiveRace], "drag") then return false end
    return true
  end

  local function notifyFreRaceCompleted(raceName, raceData, raceLabel, finishTime, vehicleId, completionMeta, resultId)
    if not overhaul_career_career.isActive() then return end
    if not overhaul_events_fre_race or not overhaul_events_fre_race.onFreeroamRaceCompleted then return end
    local disciplineIds = completionMeta and completionMeta.disciplineIds or getRaceDisciplineIds(raceData)
    local isAltRoute = ownerServices.sess().mAltRoute == true
    local finalizedPayload = {
      raceId = raceName,
      raceName = raceName,
      raceLabel = raceLabel,
      isAltRoute = isAltRoute,
      raceRouteType = isAltRoute and "alt" or "main",
      disciplineIds = disciplineIds,
      rawTypes = raceData and raceData.type or {},
      finishTime = finishTime,
      lapCount = ownerServices.sess().lapCount,
      isHotlap = ownerServices.sess().mHotlap == raceName,
      invalidLap = completionMeta and completionMeta.invalidLap == true or false,
      vehicleId = vehicleId,
      vehicleModel = getFreVehicleModel(vehicleId),
      resultMetrics = {
        time = finishTime,
        maxSpeed = ownerServices.sess().maxSpeed,
        lapCount = ownerServices.sess().lapCount,
        driftScore = completionMeta and completionMeta.driftScore or 0,
        damagePercentage = completionMeta and completionMeta.damagePercentage or 0,
        normalizedPerformance = completionMeta and completionMeta.normalizedPerformance or 0,
        isAltRoute = isAltRoute,
        isHotlap = ownerServices.sess().mHotlap == raceName,
        invalidLap = completionMeta and completionMeta.invalidLap == true or false,
      },
      rewardBreakdown = completionMeta and completionMeta.rewardBreakdown or {},
      historyPrize = completionMeta and completionMeta.historyPrize,
      skipHistory = completionMeta and completionMeta.skipHistory,
      businessReward = completionMeta and completionMeta.businessReward,
      skipFreContractProgress = shouldSkipFreContractProgressForNotify(completionMeta),
      resultId = resultId,
    }
    overhaul_events_fre_race.onFreeroamRaceCompleted(finalizedPayload)
    extensions.hook("onRlsFreeroamRaceResultFinalized", finalizedPayload)
  end

  local function rewardLabel(raceName, newBestTime)
    local races = ownerServices.sess().races
    local timeLabel = eventHelpers.formatTime(ownerServices.sess().in_race_time)
    local raceLabel = races[raceName].label
    local performanceLabel = newBestTime and "New Best Time!" or "Completion"
    local label = string.format("%s - %s: %s", raceLabel, performanceLabel, timeLabel)
    if ownerServices.sess().mAltRoute then label = label .. " (Alternative Route)" end
    if ownerServices.sess().mHotlap == raceName then label = label .. " (Hotlap)" end
    return label
  end

  local function getDriftScore()
    return driftScoreReader.take(gameplay_drift_scoring, gameplay_drift_general)
  end

  local function peekDriftScore()
    return driftScoreReader.read(gameplay_drift_scoring)
  end

  function M.peekLiveDriftScore()
    local driftScore = peekDriftScore()
    return driftScore
  end

  local function normalizedRacePerformance(race, time, rewardBaseForPerformance, driftScore, damageFactor, damagePercentage)
    local normalizedPerformance = 0
    if race.topSpeed then
      normalizedPerformance = calculateEventPerformanceRatio("topSpeed", {
        goalSpeed = race.topSpeedGoal,
        baseReward = rewardBaseForPerformance,
        actualSpeed = ownerServices.sess().maxSpeed,
        raceTypes = race.type,
      })
    elseif race.driftGoal then
      normalizedPerformance = calculateEventPerformanceRatio("drift", {
        goalTime = race.driftTargetTime or time,
        goalDriftScore = race.driftGoal,
        baseReward = rewardBaseForPerformance,
        actualTime = ownerServices.sess().in_race_time,
        actualDriftScore = driftScore,
        raceTypes = race.type,
      })
    elseif damageFactor > 0 then
      normalizedPerformance = calculateEventPerformanceRatio("hybrid", {
        goalTime = time,
        baseReward = rewardBaseForPerformance,
        actualTime = ownerServices.sess().in_race_time,
        damageFactor = damageFactor,
        actualDamagePct = damagePercentage,
        raceTypes = race.type,
      })
    else
      normalizedPerformance = calculateEventPerformanceRatio("time", {
        goalTime = time,
        baseReward = rewardBaseForPerformance,
        actualTime = ownerServices.sess().in_race_time,
        raceTypes = race.type,
      })
    end

    return normalizedPerformance
  end

  local function calculateRacePerformance(
    raceUtils,
    race,
    races,
    mActiveRace,
    time,
    reward,
    lapTime,
    damageFactor,
    rewardBaseForPerformance
  )
    local damagePercentage = 0
    if damageFactor > 0 then
      local currentDamage = raceUtils.getVehicleDamage()
      local damageTaken = math.max(0, currentDamage - ownerServices.sess().initialVehicleDamage)
      local maxDamage = 100000
      if overhaul_career_career.isActive() then
        local vehicleValue =
          overhaul_career_market_valueCalculator.getInventoryVehicleValue(ownerServices.sess().mInventoryId, true)
        if type(vehicleValue) == "number" and vehicleValue > 0 then maxDamage = vehicleValue end
      end
      damagePercentage = math.min(1, damageTaken / maxDamage)
    end

    local driftScore = 0
    if race.topSpeed then
      reward = raceUtils.topSpeedReward(race.topSpeedGoal, reward, ownerServices.sess().maxSpeed, race.type)
    elseif race.driftGoal then
      driftScore = getDriftScore()
      reward = raceUtils.driftReward(races[mActiveRace], time, driftScore)
    elseif damageFactor > 0 then
      reward = raceUtils.hybridRaceReward(time, reward, lapTime, damageFactor, damagePercentage, race.type)
    else
      reward = raceUtils.raceReward(time, reward, lapTime, race.type)
    end

    local normalizedPerformance = normalizedRacePerformance(
      race, time, rewardBaseForPerformance, driftScore, damageFactor, damagePercentage
    )
    return reward, damagePercentage, driftScore, normalizedPerformance
  end

  local function captureRaceProofIfBest(newBest, inventoryIdToUse, resultId)
    if newBest and inventoryIdToUse and overhaul_career_career.isActive() then
      capabilities.get("raceResultProof").onOverhaulRaceResult({
        phase = "proof", inventoryId = inventoryIdToUse, newBestTime = newBest, resultId = resultId,
      })
      return true
    end
  end

  local function resolveLeaderboardInventoryId()
    local inventoryIdToUse = ownerServices.sess().mInventoryId
    local playerVehicleId = be:getPlayerVehicleID(0)
    if playerVehicleId and overhaul_career_career.isActive() then
      inventoryIdToUse = overhaul_career_business_fleet.resolveFreeroamLeaderboardInventoryId(playerVehicleId)
    end

    return inventoryIdToUse
  end

  local function updateRaceLeaderboard(
    leaderboards,
    mActiveRace,
    raceLabel,
    lapTime,
    driftScore,
    damagePercentage,
    damageFactor,
    reward,
    resultId
  )
    local inventoryIdToUse = resolveLeaderboardInventoryId()

    local leaderboardEntry = leaderboards.getLeaderboardEntry(inventoryIdToUse, raceLabel)
    local oldTime = leaderboardEntry and leaderboardEntry.time or 0
    local oldScore = leaderboardEntry and leaderboardEntry.driftScore or 0
    local oldTopSpeedRecord = leaderboardEntry and leaderboardEntry.topSpeed or nil
    local oldDamagePercentRecord = leaderboardEntry
        and leaderboardEntry.damagePercentage
        and leaderboardEntry.damagePercentage * 100
      or nil

    local newEntry = {
      raceName = mActiveRace,
      raceLabel = raceLabel,
      isAltRoute = ownerServices.sess().mAltRoute,
      isHotlap = ownerServices.sess().mHotlap == mActiveRace,
      time = lapTime,
      splitTimes = ownerServices.sess().mSplitTimes,
      driftScore = driftScore,
      scoreMode = ownerServices.sess().races[mActiveRace].driftGoal and true or false,
      inventoryId = inventoryIdToUse,
      damagePercentage = damagePercentage,
      damageFactor = damageFactor,
      topSpeed = ownerServices.sess().maxSpeed,
      reward = reward,
    }

    local invalidLap = ownerServices.sess().invalidLap
    local newBest = false
    local proofObserved = false
    if not invalidLap then
      newBest = leaderboards.addLeaderboardEntry(newEntry)
      proofObserved = captureRaceProofIfBest(newBest, inventoryIdToUse, resultId) == true
    end

    return {
      inventoryIdToUse = inventoryIdToUse,
      leaderboardEntry = leaderboardEntry,
      oldTime = oldTime,
      oldScore = oldScore,
      oldTopSpeedRecord = oldTopSpeedRecord,
      oldDamagePercentRecord = oldDamagePercentRecord,
      newEntry = newEntry,
      invalidLap = invalidLap,
      newBest = newBest,
      proofObserved = proofObserved,
    }
  end

  local function formatTimeRaceRewardMessage(message, race, raceLabel, lapTime, newBest, invalidLap, damageFactor, damagePercentage, leaderboardEntry, oldTime)
    if newBest and not invalidLap then
      if damageFactor > 0 then
        message = message .. "New Best Score!\n"
      else
        message = message .. "New Best Time!\n"
      end
    end
    if race.hotlap then
      message = message
        .. string.format("%s\nTime: %s\nLap: %d", raceLabel, eventHelpers.formatTime(lapTime), ownerServices.sess().lapCount)
    else
      message = message .. string.format("%s\nTime: %s", raceLabel, eventHelpers.formatTime(lapTime))
    end
    if damageFactor > 0 then
      message = message
        .. string.format("\nDamage Taken: %.1f%% | Damage Factor: %.0f%%", damagePercentage * 100, damageFactor * 100)
    end
    if newBest and not invalidLap and oldTime ~= math.huge then
      if damageFactor > 0 then
        local oldDamagePercentage = leaderboardEntry and leaderboardEntry.damagePercentage or 0
        message = message
          .. string.format(
            "\nPrevious Best Time: %s | Previous Best Damage: %.1f%%",
            eventHelpers.formatTime(oldTime),
            oldDamagePercentage * 100
          )
      else
        message = message .. string.format("\nPrevious Best: %s", eventHelpers.formatTime(oldTime))
      end
    end      return message
  end

  local function buildRaceRewardMessage(
    race,
    raceLabel,
    lapTime,
    driftScore,
    damageFactor,
    damagePercentage,
    leaderboard
  )
    local invalidLap = leaderboard.invalidLap
    local newBest = leaderboard.newBest
    local leaderboardEntry = leaderboard.leaderboardEntry
    local oldTime = leaderboard.oldTime
    local oldScore = leaderboard.oldScore
    local message = invalidLap and "Lap Invalidated\n" or ""

    if race.topSpeed then
      message = message
        .. string.format(
          "%s\nTop Speed: %.2f mph\nTime: %s",
          raceLabel,
          ownerServices.sess().maxSpeed,
          eventHelpers.formatTime(lapTime)
        )
      if leaderboardEntry then
        local oldSpeed = leaderboardEntry.topSpeed or 0
        message = message
          .. string.format(
            "\nPrevious Best Speed: %.2f mph\nPrevious Best Time: %s",
            oldSpeed,
            eventHelpers.formatTime(oldTime)
          )
      end
    elseif race.driftGoal then
      message = message
        .. string.format("%s\nDrift Score: %d\nTime: %s", raceLabel, driftScore, eventHelpers.formatTime(lapTime))
      if leaderboardEntry then
        message = message
          .. string.format("\nPrevious Best Score: %d\nPrevious Best Time: %s", oldScore, eventHelpers.formatTime(oldTime))
      end
    else
      message = formatTimeRaceRewardMessage(message, race, raceLabel, lapTime, newBest, invalidLap,
        damageFactor, damagePercentage, leaderboardEntry, oldTime)
    end

    return message
  end

  local function applyLapRewardBonuses(race, reward, newBest, invalidLap, oldTime, newEntry, payoutBonuses)
    local hotlapMessage = ""
      if not newBest or ownerServices.sess().mHotlap then reward = reward / 2 end
      reward = invalidLap and 0 or reward
      ownerServices.sess().lapCount = (invalidLap and 1 or ownerServices.sess().lapCount)
      if race.hotlap then
        local hotlapMultiplier = eventHelpers.hotlapMultiplier(ownerServices.sess().lapCount)
        reward = reward * hotlapMultiplier
        hotlapMessage = string.format("\nHotlap Multiplier: %.2f", hotlapMultiplier)
        table.insert(payoutBonuses, { label = "Hotlap multiplier", value = string.format("×%.2f", hotlapMultiplier) })
      end

      if newBest and not ownerServices.sess().newBestSession then ownerServices.sess().newBestSession = true end

      if ownerServices.sess().newBestSession then
        reward = reward * 1.2
        hotlapMessage = hotlapMessage .. "\nNew Best Session Bonus: 20%"
        table.insert(payoutBonuses, { label = "New best session bonus", value = "+20%" })
      end

      if oldTime and (newEntry.time - (oldTime * 0.025) < oldTime) then
        reward = reward * 1.05
        hotlapMessage = hotlapMessage .. "\nIn Range Bonus: 5%"
        table.insert(payoutBonuses, { label = "In range bonus", value = "+5%" })
      end

      return reward, hotlapMessage
  end

  local function applyFreerunRewardModifiers(reward, normalizedPerformance, completionMeta)
    local baseRewardBeforeFre = reward
    local freModifiers = getFreRewardModifiers(completionMeta.disciplineIds)
    reward = reward * (tonumber(freModifiers.moneyMultiplier) or 1)
    local disciplineXpRewards, disciplineXpBreakdown, totalDisciplineXp =
      buildDisciplineXpRewards(completionMeta.disciplineIds, normalizedPerformance, freModifiers)
    overhaul_career_economy_difficultyMode.scalePaymentRewardData(disciplineXpRewards, { includeMoney = false })
    totalDisciplineXp = 0
    for _, rewardInfo in pairs(disciplineXpRewards) do
      totalDisciplineXp = totalDisciplineXp + (tonumber(rewardInfo.amount) or 0)
    end
    completionMeta.rewardBreakdown = {
      money = {
        base = baseRewardBeforeFre,
        multiplier = tonumber(freModifiers.moneyMultiplier) or 1,
        final = reward,
      },
      normalizedPerformance = normalizedPerformance,
      disciplineXp = disciplineXpBreakdown,
    }

    return reward, disciplineXpRewards, totalDisciplineXp
  end

  local function settleRaceRewardMoney(mActiveRace, reward, newBest, disciplineXpRewards, totalDisciplineXp, message)
    local hudMoney, hudBusinessMoney = nil, nil
      if reward > 0 then
        local playerVehicleId = be:getPlayerVehicleID(0)
        local businessAccount = getBusinessAccountFromVehicle(playerVehicleId)
        if businessAccount then
          local businessReward = math.floor(reward * 0.5)
          hudBusinessMoney = nil
          local xpReward = {}
          mergeRewardTables(xpReward, disciplineXpRewards)
          if next(xpReward) ~= nil then
            payoutReward(xpReward, {
              label = rewardLabel(mActiveRace, newBest),
              tags = { "gameplay", "reward", "mission", "race" },
            })
          end
          local accepted = payoutReward({
            money = { amount = businessReward },
          }, { label = "Event Reward", description = rewardLabel(mActiveRace, newBest) }, businessAccount.id)
          if accepted then hudBusinessMoney = businessReward end
          message = message
            .. string.format(
              "\nDiscipline XP: %d | Business Reward: $%.2f (50%% to business account)",
              totalDisciplineXp,
              businessReward
            )
        else
          local totalReward = { money = { amount = reward } }
          mergeRewardTables(totalReward, disciplineXpRewards)
          local accepted = payoutReward(totalReward, {
            label = rewardLabel(mActiveRace, newBest),
            tags = { "gameplay", "reward", "mission", "race" },
          })
          message = message .. string.format("\nDiscipline XP: %d | Reward: $%.2f", totalDisciplineXp, reward)
          if accepted then hudMoney = reward end
        end
        require("overhaul/lib/save/store").request("raceSession:payoutRace")
      end    return message, hudMoney, hudBusinessMoney
  end

  local function payRaceRewards(
    race, mActiveRace, reward, normalizedPerformance,
    driftScore, damagePercentage, leaderboard, message
  )
    local invalidLap = leaderboard.invalidLap
    local newBest = leaderboard.newBest
    local oldTime = leaderboard.oldTime
    local newEntry = leaderboard.newEntry
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
      skipFreContractProgress = false,
    }
    if overhaul_events_fre_sanctionedRacing and overhaul_events_fre_sanctionedRacing.shouldSuppressFrePayouts() then
      completionMeta.skipFreContractProgress = true
      completionMeta.skipHistory = true
    end
    if overhaul_career_career.isActive() then
      if completionMeta.skipFreContractProgress then
        reward = 0
        completionMeta.rewardBreakdown = {
          money = { base = 0, multiplier = 1, final = 0 },
          normalizedPerformance = normalizedPerformance,
          disciplineXp = {},
        }
        hudDisciplineXp = 0
        hudMoney = nil
        hudBusinessMoney = nil
      end
    end
    if overhaul_career_career.isActive() and not completionMeta.skipFreContractProgress then
      reward, hotlapMessage = applyLapRewardBonuses(race, reward, newBest, invalidLap, oldTime, newEntry, payoutBonuses)
      local disciplineXpRewards, totalDisciplineXp
      reward, disciplineXpRewards, totalDisciplineXp = applyFreerunRewardModifiers(reward, normalizedPerformance, completionMeta)
      hudDisciplineXp = totalDisciplineXp
      message, hudMoney, hudBusinessMoney = settleRaceRewardMoney(
        mActiveRace, reward, newBest, disciplineXpRewards, totalDisciplineXp, message
      )
    end

    completionMeta.historyPrize = hudBusinessMoney or hudMoney or 0
    completionMeta.businessReward = hudBusinessMoney ~= nil
    return reward,
      message,
      {
        hotlapMessage = hotlapMessage,
        payoutBonuses = payoutBonuses,
        hudDisciplineXp = hudDisciplineXp,
        hudMoney = hudMoney,
        hudBusinessMoney = hudBusinessMoney,
        completionMeta = completionMeta,
      }
  end

  local function raceRewardHudLabels(race, damageFactor, invalidLap, newBest)
    local isDragRace = ownerServices.raceHasType(race, "drag")
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
    return isDragRace, kind, headline
  end

  local function previousRaceHudValues(invalidLap, oldTime, oldScore, oldTopSpeedRecord, oldDamagePercentRecord)
    local previousTimeForHud = nil
    if not invalidLap and type(oldTime) == "number" and oldTime > 0 and oldTime ~= math.huge then
      previousTimeForHud = oldTime
    end
    local previousDriftScoreForHud = nil
    if not invalidLap and type(oldScore) == "number" and oldScore > 0 then previousDriftScoreForHud = oldScore end
    local previousTopSpeedForHud = nil
    if not invalidLap and type(oldTopSpeedRecord) == "number" and oldTopSpeedRecord > 0 then
      previousTopSpeedForHud = oldTopSpeedRecord
    end
    local previousDamagePercentForHud = nil
    if not invalidLap and type(oldDamagePercentRecord) == "number" then
      previousDamagePercentForHud = oldDamagePercentRecord
    end
    return previousTimeForHud, previousDriftScoreForHud, previousTopSpeedForHud, previousDamagePercentForHud
  end

  local function buildRaceRewardHud(
    race,
    raceLabel,
    lapTime,
    driftScore,
    damageFactor,
    damagePercentage,
    leaderboard,
    payment,
    showHud
  )
    local invalidLap, newBest = leaderboard.invalidLap, leaderboard.newBest
    local oldTime, oldScore = leaderboard.oldTime, leaderboard.oldScore
    local oldTopSpeedRecord, oldDamagePercentRecord = leaderboard.oldTopSpeedRecord, leaderboard.oldDamagePercentRecord
    local hudDisciplineXp, hudMoney = payment.hudDisciplineXp, payment.hudMoney
    local hudBusinessMoney, payoutBonuses = payment.hudBusinessMoney, payment.payoutBonuses
    local hudCompletionPayload = nil
    if showHud then
      local isDragRace, kind, headline = raceRewardHudLabels(race, damageFactor, invalidLap, newBest)
      local previousTimeForHud, previousDriftScoreForHud, previousTopSpeedForHud, previousDamagePercentForHud =
        previousRaceHudValues(invalidLap, oldTime, oldScore, oldTopSpeedRecord, oldDamagePercentRecord)
      hudCompletionPayload = {
        invalidLap = invalidLap == true,
        headline = headline,
        raceTitle = raceLabel,
        kind = kind,
        result = {
          time = lapTime,
          lapIndex = race.hotlap and ownerServices.sess().lapCount or nil,
          topSpeed = (race.topSpeed or isDragRace) and ownerServices.sess().maxSpeed or nil,
          driftScore = race.driftGoal and driftScore or nil,
          damagePct = (damageFactor > 0) and (damagePercentage * 100) or nil,
          damageFactorPct = (damageFactor > 0) and (damageFactor * 100) or nil,
        },
        previous = {
          time = (not race.topSpeed and not race.driftGoal) and previousTimeForHud or nil,
          topSpeed = race.topSpeed and previousTopSpeedForHud or nil,
          driftScore = race.driftGoal and previousDriftScoreForHud or nil,
          damagePct = (damageFactor > 0) and previousDamagePercentForHud or nil,
        },
        rewards = {
          disciplineXp = hudDisciplineXp,
          money = hudMoney,
          businessMoney = hudBusinessMoney,
        },
        bonuses = payoutBonuses,
      }
    end

    return hudCompletionPayload
  end

  -- resultId: the producer's id for this lap/finish, passed on to the FRE notification.
  local function resolveRaceRewardInputs(race, mActiveRace, completedLapTime)
    local time = race.bestTime
    local lapTime = (completedLapTime ~= nil and completedLapTime >= 0) and completedLapTime
      or ownerServices.sess().in_race_time
    local reward = race.reward
    local raceLabel = race.label
    local damageFactor = race.damageFactor or 0

    if ownerServices.sess().mHotlap == mActiveRace then time = race.hotlap end
    if ownerServices.sess().mAltRoute then
      time = race.altRoute.bestTime
      reward = race.altRoute.reward
      raceLabel = race.altRoute.label
      if ownerServices.sess().mHotlap == mActiveRace then time = race.altRoute.hotlap end
    end
    if ownerServices.sess().mHotlap == mActiveRace then raceLabel = raceLabel .. " (Hotlap)" end
    local rewardBaseForPerformance = reward

    return time, lapTime, reward, raceLabel, damageFactor, rewardBaseForPerformance
  end

  local function recordFreerunRewardLap(mActiveRace, race, lapTime, leaderboard, payment)
    local invalidLap = leaderboard.invalidLap
    local completionMeta = payment.completionMeta
    local hudMoney, hudBusinessMoney = payment.hudMoney, payment.hudBusinessMoney
    local hudDisciplineXp = payment.hudDisciplineXp
    if race.checkpointRoad and raceSummary.raceName == mActiveRace then
      local lapMoney = completionMeta.skipFreContractProgress and 0
        or ((tonumber(hudMoney) or 0) + (tonumber(hudBusinessMoney) or 0))
      local lapXp = completionMeta.skipFreContractProgress and 0 or (tonumber(hudDisciplineXp) or 0)
      local cleanLabel = (ownerServices.sess().mAltRoute and race.altRoute and race.altRoute.label) or race.label
      table.insert(raceSummary.laps, {
        index = #raceSummary.laps + 1,
        isAlt = ownerServices.sess().mAltRoute == true,
        time = lapTime,
        money = lapMoney,
        xp = lapXp,
        invalid = invalidLap == true,
        raceLabelShort = cleanLabel,
      })
    end
  end

  local function notifyLapResultAndClear(mActiveRace, race, raceLabel, leaderboard, damagePercentage, damageFactor, completionMeta, resultId)
    local inventoryIdToUse = leaderboard.inventoryIdToUse
    local invalidLap = leaderboard.invalidLap
    if overhaul_career_career.isActive() then
      extensions.hook("onOverhaulRaceResult", {
        phase = "settled",
        resultId = resultId,
        newBestTime = leaderboard.newBest,
        proofStage = leaderboard.proofObserved and "dispatched" or "skipped",
        inventoryId = inventoryIdToUse,
        raceLabel = raceLabel,
        isAltRoute = ownerServices.sess().mAltRoute == true,
        isHotlap = ownerServices.sess().mHotlap == mActiveRace,
        invalidLap = invalidLap == true,
        damagePercentage = damagePercentage,
        damageFactor = damageFactor or 0,
        playerVehicleId = be:getPlayerVehicleID(0),
      })
    end
    notifyFreRaceCompleted(
      mActiveRace,
      race,
      raceLabel,
      ownerServices.sess().in_race_time,
      be:getPlayerVehicleID(0),
      completionMeta,
      resultId
    )
    ownerServices.sess().mActiveRace = nil
    ownerServices.notifyFreContractsFreeroamUi()
  end

  function M.payoutRace(completedLapTime, resultId)
    local raceUtils = ownerServices.utils()
    local leaderboards = ownerServices.leaderboardManager()
    local circuitAi = ownerServices.circuitRaceAi()
    if not ownerServices.sess().mActiveRace then return 0 end
    local mActiveRace = ownerServices.sess().mActiveRace
    local races = ownerServices.sess().races
    local race = races[mActiveRace]
    -- Bound strips settle from the stock racer's final state in payoutDragRace.
    -- Legacy FRE finish triggers must not pay or record an earlier, unchecked result.
    if race.dragStripId then return 0 end
    local time, lapTime, reward, raceLabel, damageFactor, rewardBaseForPerformance =
      resolveRaceRewardInputs(race, mActiveRace, completedLapTime)
    local damagePercentage, driftScore, normalizedPerformance
    reward, damagePercentage, driftScore, normalizedPerformance = calculateRacePerformance(
      raceUtils, race, races, mActiveRace, time, reward, lapTime, damageFactor, rewardBaseForPerformance
    )
    local leaderboard = updateRaceLeaderboard(
      leaderboards, mActiveRace, raceLabel, lapTime, driftScore, damagePercentage, damageFactor, reward, resultId
    )
    local message = buildRaceRewardMessage(
      race, raceLabel, lapTime, driftScore, damageFactor, damagePercentage, leaderboard
    )
    local payment
    reward, message, payment = payRaceRewards(
      race, mActiveRace, reward, normalizedPerformance, driftScore, damagePercentage, leaderboard, message
    )
    local hotlapMessage = payment.hotlapMessage
    local completionMeta = payment.completionMeta
    local skipMidLapHud = circuitAi.isSanctionedTriggerOnlyLapRace() and completedLapTime ~= nil
    local showHud = M.raceHudApplies(race) and raceHud.shown and not skipMidLapHud
    local hudCompletionPayload = buildRaceRewardHud(
      race, raceLabel, lapTime, driftScore, damageFactor, damagePercentage, leaderboard, payment, showHud
    )
    recordFreerunRewardLap(mActiveRace, race, lapTime, leaderboard, payment)
    local checkpointHudShown = race.checkpointRoad and raceHud.shown
    notifyLapResultAndClear(mActiveRace, race, raceLabel, leaderboard, damagePercentage, damageFactor, completionMeta, resultId)
    if not checkpointHudShown then
      raceUtils.displayMessage(message, 20)
      if hotlapMessage ~= "" then ui_message(hotlapMessage, 5, "Hotlap Multiplier") end
      return reward
    end
    return reward, hudCompletionPayload
  end

  return {
    payoutReward = payoutReward,
    getRaceDisciplineIds = getRaceDisciplineIds,
    getFreRewardModifiers = getFreRewardModifiers,
    calculateEventPerformanceRatio = calculateEventPerformanceRatio,
    buildDisciplineXpRewards = buildDisciplineXpRewards,
    mergeRewardTables = mergeRewardTables,
    getBusinessAccountFromVehicle = getBusinessAccountFromVehicle,
    notifyFreRaceCompleted = notifyFreRaceCompleted,
    peekDriftScore = peekDriftScore,
  }
end

return lib
