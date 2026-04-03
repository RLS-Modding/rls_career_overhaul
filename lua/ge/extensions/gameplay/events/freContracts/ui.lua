local M = {}

local freConfig = require('gameplay/fre/config')
local freHelpers = require('gameplay/events/freContracts/helpers')

local uiStreamingActive = false
local uiRevision = 0

local tierOrder = {
  easy = 1,
  medium = 2,
  hard = 3
}

local function sortForUi(list, typeKey)
  table.sort(list, function(a, b)
    local levelA = tonumber(a.level) or 0
    local levelB = tonumber(b.level) or 0
    if levelA ~= levelB then
      return levelA > levelB
    end
    if typeKey == "contract" then
      local ta = tierOrder[a.tier] or 99
      local tb = tierOrder[b.tier] or 99
      if ta ~= tb then
        return ta < tb
      end
    end
    local expiresA = tonumber(a.expiresAt) or math.huge
    local expiresB = tonumber(b.expiresAt) or math.huge
    return expiresA < expiresB
  end)
end

local function buildDisciplineUiState(disciplineId, now)
  local discipline = freConfig.getDisciplineById(disciplineId)
  if not discipline then
    return nil
  end

  local skills = gameplay_events_freContracts_skills
  local state = gameplay_events_freContracts_state.getState()
  local skillProgress = skills.getSkillProgress(disciplineId)
  local level = skillProgress.level
  local contractCfg = freConfig.getContractConfig(disciplineId)
  local sponsorCfg = freConfig.getSponsorConfig(disciplineId)
  local contractUnlockLevel = tonumber((contractCfg.tierUnlockLevels or {}).easy) or 0
  local sponsorUnlockLevel = tonumber((sponsorCfg.tierUnlockLevels or {}).easy) or 0
  local contractsUnlocked = level >= contractUnlockLevel
  local sponsorsUnlocked = level >= sponsorUnlockLevel

  local contractSlots = skills.countSlotCap(level, contractCfg.slotUnlockLevels)
  local sponsorSlots = skills.countSlotCap(level, sponsorCfg.slotUnlockLevels)
  local contractOfferCap = contractsUnlocked and skills.countOfferCap(level, contractCfg) or 0
  local sponsorOfferCap = sponsorsUnlocked and skills.countOfferCap(level, sponsorCfg) or 0

  local dState = state.disciplines[disciplineId]
  local sponsorBonuses = gameplay_events_freContracts_race.getSponsorBonusesForDiscipline(disciplineId)

  return {
    id = discipline.id,
    label = discipline.label or discipline.id,
    skillKey = discipline.skillKey,
    placeholderOnly = discipline.placeholderOnly == true,
    level = level,
    xpValue = skillProgress.value,
    xpProgress = skillProgress.progress,
    xpIntoLevel = skillProgress.xpIntoLevel,
    xpNeededForLevel = skillProgress.xpNeededForLevel,
    xpToNextLevel = skillProgress.xpToNextLevel,
    prevThreshold = skillProgress.prevThreshold,
    nextThreshold = skillProgress.nextThreshold,
    contractUnlockLevel = contractUnlockLevel,
    sponsorUnlockLevel = sponsorUnlockLevel,
    contractsUnlocked = contractsUnlocked,
    sponsorsUnlocked = sponsorsUnlocked,
    contractUnlockedTiers = skills.getUnlockedContractTiers(disciplineId, level),
    sponsorUnlockedTiers = skills.getUnlockedSponsorTiers(disciplineId, level),
    contractSlots = contractSlots,
    contractSlotsUsed = #(dState.contracts.active or {}),
    contractOfferCap = contractOfferCap,
    sponsorSlots = sponsorSlots,
    sponsorSlotsUsed = #(dState.sponsors.active or {}),
    sponsorOfferCap = sponsorOfferCap,
    sponsorBonusMoney = sponsorBonuses.money,
    sponsorBonusXp = sponsorBonuses.xp,
    contractCompleted = dState.contracts.completed or 0,
    contractFailed = dState.contracts.failed or 0,
    sponsorsDropped = dState.sponsors.dropped or 0,
    sanctionedRacingUnlockLevel = discipline.id == "roadracing" and freConfig.getSanctionedRacingUnlockLevel() or nil,
    racingUnlocked = discipline.id == "roadracing" and gameplay_events_freContracts_sanctionedRacing.isRacingUnlocked(discipline.id) or
      false
  }
end

local function formatContractForUi(contract, now, level)
  return {
    id = contract.id,
    disciplineId = contract.disciplineId,
    tier = contract.tier,
    raceName = contract.raceName,
    raceLabel = contract.raceLabel,
    raceRouteType = contract.raceRouteType,
    targetType = contract.targetType,
    targetTime = contract.targetTime,
    targetDriftScore = contract.targetDriftScore,
    targetDamagePctMax = contract.targetDamagePctMax,
    requiredModel = contract.requiredModel,
    requiredModelFamily = contract.requiredModel,
    requiredModelLabel = contract.requiredModelLabel,
    modelSource = contract.modelSource,
    objectiveType = contract.objectiveType,
    requiredCount = contract.requiredCount,
    progress = contract.progress,
    rewardMoney = contract.rewardMoney,
    rewardXp = contract.rewardXp,
    expiresAt = contract.expiresAt,
    minutesRemaining = math.max(0, (tonumber(contract.expiresAt) or now) - now),
    level = level
  }
end

local function formatSponsorForUi(sponsor, now, level)
  local upkeepMinutes = math.max(1, tonumber(sponsor.upkeepMinutes) or 120)
  local nextCheckAt = tonumber(sponsor.nextCheckAt) or now
  local lastQualifiedAt = tonumber(sponsor.lastQualifiedAt)
  local requirementSatisfied = false
  local requirementStatus = "pending"
  local windowStartAt = math.max(0, nextCheckAt - upkeepMinutes)

  if sponsor.warningIssued == true then
    requirementStatus = "warning"
  elseif lastQualifiedAt and lastQualifiedAt >= windowStartAt then
    requirementSatisfied = true
    requirementStatus = "satisfied"
  end

  return {
    id = sponsor.id,
    disciplineId = sponsor.disciplineId,
    tier = sponsor.tier,
    name = sponsor.name,
    bonusType = sponsor.bonusType,
    bonusPercent = sponsor.bonusPercent,
    upkeepMinutes = upkeepMinutes,
    requirement = sponsor.requirement,
    requiredRaceName = sponsor.requiredRaceName,
    requiredRaceLabel = sponsor.requiredRaceLabel,
    requiredRaceRouteType = sponsor.requiredRaceRouteType,
    targetType = sponsor.targetType,
    targetTime = sponsor.targetTime,
    targetDriftScore = sponsor.targetDriftScore,
    targetDamagePctMax = sponsor.targetDamagePctMax,
    expiresAt = sponsor.expiresAt,
    minutesRemaining = math.max(0, (tonumber(sponsor.expiresAt) or now) - now),
    level = level,
    warningIssued = sponsor.warningIssued == true,
    warningIssuedAt = sponsor.warningIssuedAt,
    lastQualifiedAt = lastQualifiedAt,
    lastQualifiedRaceName = sponsor.lastQualifiedRaceName,
    lastQualifiedRaceRouteType = sponsor.lastQualifiedRaceRouteType,
    lastQualifiedTime = sponsor.lastQualifiedTime,
    requirementSatisfied = requirementSatisfied,
    requirementStatus = requirementStatus,
    requiredEvents = 1,
    windowStartAt = windowStartAt,
    nextCheckAt = nextCheckAt,
    checkMinutesRemaining = math.max(0, nextCheckAt - now)
  }
end

local function getUiState(filterDisciplineId)
  local state = gameplay_events_freContracts_state.getState()
  local now = state.simTime
  gameplay_events_freContracts_state.refreshMaintenanceSchedule(now)
  gameplay_events_freContracts_offers.purgeExpiredEntries(now)
  gameplay_events_freContracts_offers.syncAllOffers(now)
  gameplay_events_freContracts_sanctionedRacing.syncGeneration(now)

  local activeContracts = {}
  local availableContracts = {}
  local activeSponsors = {}
  local availableSponsors = {}
  local disciplinesUi = {}

  local allowed = {}
  if type(filterDisciplineId) == "string" and filterDisciplineId ~= "" then
    local normalized = freConfig.getDisciplineIdFromType(filterDisciplineId) or string.lower(filterDisciplineId)
    allowed[normalized] = true
  end

  for _, discipline in ipairs(freConfig.getDisciplines()) do
    if next(allowed) == nil or allowed[discipline.id] then
      local dState = state.disciplines[discipline.id]
      local disciplineUi = buildDisciplineUiState(discipline.id, now)
      table.insert(disciplinesUi, disciplineUi)
      local level = disciplineUi.level

      for _, entry in ipairs(dState.contracts.active or {}) do
        table.insert(activeContracts, formatContractForUi(entry, now, level))
      end
      for _, entry in ipairs(dState.contracts.available or {}) do
        table.insert(availableContracts, formatContractForUi(entry, now, level))
      end

      for _, entry in ipairs(dState.sponsors.active or {}) do
        table.insert(activeSponsors, formatSponsorForUi(entry, now, level))
      end
      for _, entry in ipairs(dState.sponsors.available or {}) do
        table.insert(availableSponsors, formatSponsorForUi(entry, now, level))
      end
    end
  end

  sortForUi(activeContracts, "contract")
  sortForUi(availableContracts, "contract")
  sortForUi(activeSponsors, "sponsor")
  sortForUi(availableSponsors, "sponsor")

  return {
    simTimeMinutes = now,
    levelId = gameplay_events_freContracts_raceCache.getRaceCache().levelId,
    disciplines = disciplinesUi,
    activeContracts = activeContracts,
    availableContracts = availableContracts,
    activeSponsors = activeSponsors,
    availableSponsors = availableSponsors,
    sanctionedRacing = gameplay_events_freContracts_sanctionedRacing.getOfferUiSnapshot(now),
    sanctionedRacingOfferPeriodMinutes = gameplay_events_freContracts_sanctionedRacing.getOfferGenerationPeriodMinutes(),
    freeroamEventContractBlockReason = freHelpers.getFreeroamEventContractBlockMessage(),
  }
end

local function setUiStreamingActive(active)
  uiStreamingActive = active == true
end

local function emitUiStateUpdate(reason)
  if not uiStreamingActive or not guihooks or not guihooks.trigger then
    return false
  end
  local state = gameplay_events_freContracts_state.getState()
  uiRevision = uiRevision + 1
  local payload = getUiState()
  payload.updateReason = reason or "state_changed"
  payload.revision = uiRevision
  local nextMaintenanceAt = gameplay_events_freContracts_state.getNextMaintenanceAt()
  payload.nextMaintenanceAt = nextMaintenanceAt
  payload.nextMaintenanceInMinutes = nextMaintenanceAt and
                                       math.max(0, nextMaintenanceAt - state.simTime) or nil
  guihooks.trigger("phoneFreContractsData", payload)
  return true
end

M.getUiState = getUiState
M.setUiStreamingActive = setUiStreamingActive
M.emitUiStateUpdate = emitUiStateUpdate

return M
