-- Derby personalities, entry modes, repair insurance and reward settlement.
-- Read reward configuration, mode/insurance policy, ordered payouts and the per-load services.
local eventConfig = require("overhaul/events/derby/config")
local lib = {}

-- Config ------------------------------------------------------------------------------------------

local DEFAULT_PERSONALITY_NAME = "opportunist"
local DEFAULT_RETARGET_INTERVAL_SECONDS = 8
local MIN_RETARGET_INTERVAL_SECONDS = 0.75
local MAX_RETARGET_INTERVAL_SECONDS = 30
local MIN_RETARGET_MULTIPLIER = 0.65
local MAX_RETARGET_MULTIPLIER = 1.35
local RETARGET_JITTER_MIN = 0.9
local RETARGET_JITTER_SPREAD = 0.2

-- Helpers -----------------------------------------------------------------------------------------

-- Copies one table level deep, then lets override entries replace or extend the nested tables.
local function mergeNested(base, override)
  local merged = {}
  for key, value in pairs(base) do
    if type(value) == "table" then
      local copy = {}
      for nestedKey, nestedValue in pairs(value) do
        copy[nestedKey] = nestedValue
      end
      merged[key] = copy
    else
      merged[key] = value
    end
  end
  for key, value in pairs(override) do
    if type(value) == "table" and type(merged[key]) == "table" then
      for nestedKey, nestedValue in pairs(value) do
        merged[key][nestedKey] = nestedValue
      end
    else
      merged[key] = value
    end
  end
  return merged
end

-- The part ----------------------------------------------------------------------------------------

function lib.create(ownerServices)
  local derbyState = ownerServices.derbyState

  -- AI personalities ------------------------------------------------------------------------------

  local function getAiPersonalityProfiles()
    local configured = derbyState.activeEventCfg and derbyState.activeEventCfg.aiPersonalityProfiles
    if type(configured) ~= "table" then return ownerServices.DEFAULT_AI_PERSONALITIES end
    return mergeNested(ownerServices.DEFAULT_AI_PERSONALITIES, configured)
  end

  local function pickAiPersonalityName()
    local profiles = getAiPersonalityProfiles()
    local totalWeight = 0
    for _, profile in pairs(profiles) do
      totalWeight = totalWeight + math.max(0, tonumber(profile.weight) or 0)
    end
    if totalWeight <= 0 then return DEFAULT_PERSONALITY_NAME end
    local roll = math.random() * totalWeight
    local accumulated = 0
    for name, profile in pairs(profiles) do
      accumulated = accumulated + math.max(0, tonumber(profile.weight) or 0)
      if roll <= accumulated then return name end
    end
    return DEFAULT_PERSONALITY_NAME
  end

  local function getAiPersonality(aiVehId)
    local info = derbyState.spawnedAiInfo[aiVehId]
    local profileName = info and info.personalityName or DEFAULT_PERSONALITY_NAME
    local profiles = getAiPersonalityProfiles()
    return profiles[profileName]
      or profiles[DEFAULT_PERSONALITY_NAME]
      or ownerServices.DEFAULT_AI_PERSONALITIES[DEFAULT_PERSONALITY_NAME]
  end

  local function getAiRetargetInterval(aiVehId)
    local configuredSeconds = tonumber(derbyState.activeEventCfg and derbyState.activeEventCfg.aiRetargetInterval)
      or DEFAULT_RETARGET_INTERVAL_SECONDS
    local baseSeconds = ownerServices.clamp(configuredSeconds, MIN_RETARGET_INTERVAL_SECONDS, MAX_RETARGET_INTERVAL_SECONDS)
    local personality = getAiPersonality(aiVehId)
    local personalityMultiplier =
      ownerServices.clamp(tonumber(personality.retargetIntervalMultiplier) or 1, MIN_RETARGET_MULTIPLIER, MAX_RETARGET_MULTIPLIER)
    local jitter = RETARGET_JITTER_MIN + (math.random() * RETARGET_JITTER_SPREAD)
    return math.max(MIN_RETARGET_INTERVAL_SECONDS, baseSeconds * personalityMultiplier * jitter)
  end

  -- Entry modes and economy -----------------------------------------------------------------------

  local function getEntryModes(cfg)
    local modes = cfg and cfg.entryModes
    if type(modes) == "table" then return modes end
    return {
      loaner = {
        label = "Register as Driver",
        entryFee = 1000,
        rewardBase = tonumber(cfg and cfg.reward) or 500,
        rewardPerAi = 250,
        playerPool = "rlsDerby100",
        aiPool = "rlsDerby100",
        loaner = true,
      },
      ownCar = {
        label = "Enter Own Car",
        entryFee = 0,
        rewardBase = 10000,
        rewardPerAi = 750,
        aiPool = "rlsDerby100",
        requireUninsured = true,
        persistDamage = true,
      },
    }
  end

  local function getEntryModeConfig(cfg, modeKey)
    local modes = getEntryModes(cfg)
    local key = tostring(modeKey or "")
    local mode = modes[key]
    if type(mode) ~= "table" then
      key = "loaner"
      mode = modes.loaner
    end
    if type(mode) ~= "table" then
      for candidateKey, candidate in pairs(modes) do
        if type(candidate) == "table" then
          key = candidateKey
          mode = candidate
          break
        end
      end
    end
    return key, mode or {}
  end

  local function getEventEconomyTypes(cfg)
    local types = cfg and cfg.type
    if type(types) ~= "table" or #types == 0 then return { "demo" } end
    return types
  end

  local function getDerbyEconomyMultiplier(cfg)
    return ownerServices.freeroamUtils.calculateAverageMultiplier(getEventEconomyTypes(cfg))
  end

  -- Winner repair insurance -----------------------------------------------------------------------

  local DEFAULT_REPAIR_CUT_PERCENT = 50

  local function getWinnerRepairInsuranceCfg(cfg)
    cfg = cfg or derbyState.activeEventCfg
    local block = cfg and cfg.winnerRepairInsurance
    if type(block) ~= "table" or block.enabled == false then return nil end
    local cutPercent = tonumber(block.rewardCutPercent) or DEFAULT_REPAIR_CUT_PERCENT
    return {
      enabled = true,
      rewardCutPercent = math.max(0, math.min(100, cutPercent)),
      defaultSelected = block.defaultSelected == true,
    }
  end

  local function isWinnerRepairInsuranceAvailable(cfg, modeKey)
    if not getWinnerRepairInsuranceCfg(cfg) then return false end
    local _, mode = getEntryModeConfig(cfg, modeKey)
    return mode and mode.persistDamage == true
  end

  local function calcWinnerRepairInsuranceFee(grossMoney, cfg)
    local insurance = getWinnerRepairInsuranceCfg(cfg)
    if not insurance or insurance.rewardCutPercent <= 0 then return 0 end
    return math.max(0, math.floor(((tonumber(grossMoney) or 0) * insurance.rewardCutPercent / 100) + 0.5))
  end

  local function buildWinnerRepairInsurancePayload(cfg, modeKey, selected)
    if not isWinnerRepairInsuranceAvailable(cfg, modeKey) then
      return {
        winnerRepairInsuranceAvailable = false,
        winnerRepairInsuranceSelected = false,
        winnerRepairInsurancePercent = 0,
      }
    end
    local insurance = getWinnerRepairInsuranceCfg(cfg)
    local isSelected = selected
    if isSelected == nil then isSelected = insurance.defaultSelected end
    return {
      winnerRepairInsuranceAvailable = true,
      winnerRepairInsuranceSelected = isSelected == true,
      winnerRepairInsurancePercent = insurance.rewardCutPercent,
    }
  end

  -- Reward amounts --------------------------------------------------------------------------------

  local function getDerbyRewardModifiers()
    local freMods = overhaul_events_fre_race and overhaul_events_fre_race.calculateRewardModifiers({ "demo" })
    local disciplineMods = freMods and freMods.disciplineMultipliers and freMods.disciplineMultipliers.demo
    return tonumber(disciplineMods and (disciplineMods.moneyMultiplier or disciplineMods.skillMultiplier)) or 1,
      tonumber(disciplineMods and disciplineMods.xpMultiplier) or 1
  end

  local function calculateDerbyGrossMoney(eventReward, cfg, moneyMultiplier)
    local economyMult = getDerbyEconomyMultiplier(cfg)
    return math.max(0, math.floor(eventReward * economyMult * moneyMultiplier + 0.5)), economyMult
  end

  local function buildModeOptions(cfg, aiCount)
    local modes = getEntryModes(cfg)
    local moneyMultiplier = getDerbyRewardModifiers()
    local options = {}
    for key, mode in pairs(modes) do
      if type(mode) == "table" then
        local base = tonumber(mode.rewardBase) or tonumber(cfg and cfg.reward) or 0
        local perAi = tonumber(mode.rewardPerAi) or 0
        local grossReward = math.max(0, base + (perAi * math.max(1, math.floor(tonumber(aiCount) or 1))))
        table.insert(options, {
          key = key,
          label = mode.label or key,
          description = mode.description or "",
          entryFee = math.max(0, math.floor(tonumber(mode.entryFee) or 0)),
          rewardBase = math.max(0, math.floor(tonumber(mode.rewardBase) or tonumber(cfg and cfg.reward) or 0)),
          rewardPerAi = math.max(0, math.floor(tonumber(mode.rewardPerAi) or 0)),
          rewardPreview = calculateDerbyGrossMoney(grossReward, cfg, moneyMultiplier),
          requireUninsured = mode.requireUninsured == true,
          loaner = mode.loaner ~= false and key == "loaner" or mode.loaner == true,
        })
      end
    end
    table.sort(options, function(first, second)
      if first.key == "loaner" then return true end
      if second.key == "loaner" then return false end
      return tostring(first.key) < tostring(second.key)
    end)
    return options
  end

  local function getModeRewardBase(participantCount)
    local modeCfg = derbyState.activeEntryModeCfg or {}
    local fallback = eventConfig.value(derbyState.activeEventCfg, "reward")
    local base = tonumber(modeCfg.rewardBase) or fallback
    local perAi = tonumber(modeCfg.rewardPerAi) or 0
    local aiCount = math.max(1, math.floor((participantCount or 1) - 1))
    return math.max(0, base + (perAi * aiCount))
  end

  local function getModeXpReward(money)
    local modeCfg = derbyState.activeEntryModeCfg or {}
    local explicitXp = tonumber(modeCfg.xpReward or modeCfg.rewardXp or modeCfg.xp)
    if explicitXp and explicitXp >= 0 then return math.floor(explicitXp + 0.5) end
    return math.max(0, math.floor(((tonumber(money) or 0) * ownerServices.constants.DEFAULT_XP_OF_MONEY) + 0.5))
  end

  -- Settlement ------------------------------------------------------------------------------------

  local function getActiveEntryFee()
    return math.max(
      0,
      math.floor(tonumber(derbyState.activeEntryModeCfg and derbyState.activeEntryModeCfg.entryFee) or 0)
    )
  end

  local function getActiveEntryModeLabel()
    return derbyState.activeEntryModeCfg and derbyState.activeEntryModeCfg.label or derbyState.activeEntryModeKey
  end

  local function startRewardSummary(playerPlace)
    local place = tonumber(playerPlace)
    if not place or place < 1 then place = derbyState.totalParticipants end
    place = math.floor(place)
    local summary = {
      money = 0,
      xp = 0,
      eligible = place == 1,
      noRewardDetail = nil,
      place = place,
      participantCount = math.max(1, math.floor(derbyState.totalParticipants or 1)),
      modeKey = derbyState.activeEntryModeKey,
      modeLabel = getActiveEntryModeLabel(),
      entryFee = getActiveEntryFee(),
    }
    derbyState.lastRewardSummary = summary
    return summary
  end

  local function declineReward(summary, detail, message)
    summary.noRewardDetail = detail
    ownerServices.pushRewardMessage(
      string.format("%s place. %s", ownerServices.ordinal(summary.place), message), "warning"
    )
    return summary
  end

  local function announceFinishedRace(summary, playerWasEliminated, eliminationReason)
    local finalizedPayload = {
      raceName = derbyState.activeEvent,
      finishTime = ownerServices.getElapsedEventTime(),
      historyPrize = summary.historyPrize or 0,
      disciplineIds = { "demo" },
      invalidLap = not summary.eligible,
      resultMetrics = {
        placement = summary.place,
        totalParticipants = summary.participantCount,
        eliminated = playerWasEliminated == true,
        eliminationReason = eliminationReason,
      },
    }
    overhaul_events_fre_race.onFreeroamRaceCompleted(finalizedPayload)
    extensions.hook("onRlsFreeroamRaceResultFinalized", finalizedPayload)
  end

  local function payOutReward(summary, eventReward, grossMoney, repairCut, money, xp, economyMult, levelMult)
    local label = string.format(
      "Demolition Derby: %s",
      tostring((derbyState.activeEventCfg and derbyState.activeEventCfg.label) or "Event")
    )
    local skillKey = ownerServices.freConfig.getSkillKey("demo") or "careerSkills-mayhem"
    local accepted = overhaul_career_economy_payment.payout(require("overhaul/lib/finance/metadata").tagPayout({
      amount = money,
      xp = { [skillKey] = xp },
      label = label,
      tags = { "gameplay", "reward", "fre", "demo" },
      reason = { canBeNegative = false },
      fullReward = true,
    }, "activity:derby", {vehicleRole = "player"}))
    summary.historyPrize = accepted == true and money or 0
    summary.money = money
    summary.grossMoney = grossMoney
    summary.repairCut = repairCut
    summary.winnerRepairInsurance = derbyState.activeWinnerRepairInsurance
    summary.xp = xp
    summary.rewardScales = {
      aiCountMultiplier = 1,
      durationMoneyMultiplier = 1,
      durationXpMultiplier = 1,
      durationLabel = "No duration scaling",
      economyMultiplier = economyMult,
      levelMultiplier = levelMult,
      modeKey = derbyState.activeEntryModeKey,
      modeLabel = getActiveEntryModeLabel(),
      entryFee = getActiveEntryFee(),
      grossRewardBase = eventReward,
    }
    local rewardMsg =
      string.format("%s place. Reward: $%d | Demo XP: %d", ownerServices.ordinal(summary.place), money, xp)
    if repairCut > 0 then
      rewardMsg = string.format(
        "%s place. Reward: $%d (repair cut $%d) | Demo XP: %d",
        ownerServices.ordinal(summary.place),
        money,
        repairCut,
        xp
      )
    end
    ownerServices.pushRewardMessage(rewardMsg, "check")
  end

  local function settleCareerRewards(playerWasEliminated, playerPlace, eliminationReason)
    if derbyState.rewardsSettled then return derbyState.lastRewardSummary end
    derbyState.rewardsSettled = true
    local summary = startRewardSummary(playerPlace)
    if not overhaul_career_career.isActive() then
      summary.noRewardDetail = "Rewards are only available in Career mode."
      return summary
    end
    local function finish()
      if overhaul_events_fre_race then announceFinishedRace(summary, playerWasEliminated, eliminationReason) end
      return summary
    end
    local function decline(detail, message)
      declineReward(summary, detail, message)
      return finish()
    end
    if not summary.eligible then
      return decline("1st place required for rewards.", "No payout (1st place required).")
    end
    local eventReward = getModeRewardBase(summary.participantCount)
    if eventReward <= 0 then
      return decline("No payout configured for this event.", "No payout configured.")
    end
    local levelMult, xpMult = getDerbyRewardModifiers()
    local grossMoney, economyMult = calculateDerbyGrossMoney(eventReward, derbyState.activeEventCfg, levelMult)
    local repairCut = 0
    if derbyState.activeWinnerRepairInsurance then
      repairCut = calcWinnerRepairInsuranceFee(grossMoney, derbyState.activeEventCfg)
    end
    local money = math.max(0, grossMoney - repairCut)
    local xpBaseMoney = math.max(0, eventReward * economyMult)
    local xp = math.max(0, math.floor((getModeXpReward(xpBaseMoney) * xpMult) + 0.5))
    if money <= 0 and xp <= 0 then return decline("No payout generated.", "No payout generated.") end
    payOutReward(summary, eventReward, grossMoney, repairCut, money, xp, economyMult, levelMult)
    return finish()
  end

  return {
    getAiPersonalityProfiles = getAiPersonalityProfiles,
    pickAiPersonalityName = pickAiPersonalityName,
    getAiPersonality = getAiPersonality,
    getAiRetargetInterval = getAiRetargetInterval,
    getEntryModeConfig = getEntryModeConfig,
    getDerbyEconomyMultiplier = getDerbyEconomyMultiplier,
    isWinnerRepairInsuranceAvailable = isWinnerRepairInsuranceAvailable,
    buildWinnerRepairInsurancePayload = buildWinnerRepairInsurancePayload,
    buildModeOptions = buildModeOptions,
    settleCareerRewards = settleCareerRewards,
  }
end

return lib
