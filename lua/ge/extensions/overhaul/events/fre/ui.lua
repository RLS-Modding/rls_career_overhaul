-- Freeroam discipline, licence, contract and sponsor UI snapshots.
-- Read projection helpers, ordered list assembly and streaming hooks; maintenance owns state changes.
local M = {}

local freConfig = require("overhaul/events/freConfig")
local freHelpers = require("overhaul/events/fre/helpers")

-- Config --------------------------------------------------------------------------------------------

local tierOrder = {
  easy = 1,
  medium = 2,
  hard = 3,
  master = 4,
}

-- State ---------------------------------------------------------------------------------------------

local uiStreamingActive = false
local uiRevision = 0
local lastPowerHp
local POWER_REFRESH_BEFORE_EXPIRY_SECONDS = 5

-- Discipline projections ----------------------------------------------------------------------------

local function sortForUi(list, typeKey)
  table.sort(list, function(a, b)
    local levelA = tonumber(a.level) or 0
    local levelB = tonumber(b.level) or 0
    if levelA ~= levelB then return levelA > levelB end
    if typeKey == "contract" then
      local ta = tierOrder[a.tier] or 99
      local tb = tierOrder[b.tier] or 99
      if ta ~= tb then return ta < tb end
    end
    local expiresA = tonumber(a.expiresAt) or math.huge
    local expiresB = tonumber(b.expiresAt) or math.huge
    return expiresA < expiresB
  end)
end

local function disciplineSlotUiInputs(disciplineId, discipline, skills, level)
  local contractCfg = freConfig.getContractConfig(disciplineId)
  local sponsorCfg = freConfig.getSponsorConfig(disciplineId)
  local licenseCfg = freConfig.getLicenseConfig() or {}
  local contractUnlockLevel = tonumber((contractCfg.slotUnlockLevels or {}).baseLevel)
    or tonumber((licenseCfg.pointAwards or {})["5"] and 5)
    or 5
  local sponsorUnlockLevel = tonumber((sponsorCfg.slotUnlockLevels or {}).baseLevel)
    or (contractUnlockLevel + (tonumber(licenseCfg.sponsorDelayLevels) or 2))
  local contractTiers = skills.getUnlockedContractTiers(disciplineId, level)
  local sponsorTiers = skills.getUnlockedSponsorTiers(disciplineId, level)
  local contractsUnlocked = #contractTiers > 0
  local sponsorsUnlocked = #sponsorTiers > 0

  local contractSlots = skills.getSharedSlotCap(disciplineId, "contracts")
  local sponsorSlots = skills.getSharedSlotCap(disciplineId, "sponsors")
  local contractSlotsUsed = skills.countActiveForParent(discipline.parentSkillId, "contracts")
  local sponsorSlotsUsed = skills.countActiveForParent(discipline.parentSkillId, "sponsors")
  local sponsorCooldownSlots = skills.getSponsorCooldownOccupancy(discipline.parentSkillId)
  local contractOfferCap = contractsUnlocked and skills.countOfferCap(level, contractCfg) or 0
  local sponsorOfferCap = sponsorsUnlocked and skills.countOfferCap(level, sponsorCfg) or 0

  return {
    contractUnlockLevel = contractUnlockLevel,
    sponsorUnlockLevel = sponsorUnlockLevel,
    contractTiers = contractTiers,
    sponsorTiers = sponsorTiers,
    contractsUnlocked = contractsUnlocked,
    sponsorsUnlocked = sponsorsUnlocked,
    contractSlots = contractSlots,
    sponsorSlots = sponsorSlots,
    contractSlotsUsed = contractSlotsUsed,
    sponsorSlotsUsed = sponsorSlotsUsed,
    sponsorCooldownSlots = sponsorCooldownSlots,
    contractOfferCap = contractOfferCap,
    sponsorOfferCap = sponsorOfferCap,
  }
end

local function buildDisciplineUiState(disciplineId, now)
  local discipline = freConfig.getDisciplineById(disciplineId)
  if not discipline then return nil end

  local skills = overhaul_events_fre_skills
  local state = overhaul_events_fre_state.getState()
  local skillProgress = skills.getSkillProgress(disciplineId)
  local level = skillProgress.level
  local slots = disciplineSlotUiInputs(disciplineId, discipline, skills, level)

  local dState = state.disciplines[disciplineId]
  local parentState = state.parentSkills and state.parentSkills[discipline.parentSkillId]
  local license = parentState and parentState.licenses and parentState.licenses[disciplineId]
  local sponsorBonuses = overhaul_events_fre_race.getSponsorBonusesForDiscipline(disciplineId)

  return {
    id = discipline.id,
    label = discipline.label or discipline.id,
    skillKey = discipline.skillKey,
    parentSkillId = discipline.parentSkillId,
    legacyOnly = discipline.legacyOnly == true,
    licenseTier = license and license.tier or nil,
    placeholderOnly = discipline.placeholderOnly == true,
    level = level,
    xpValue = skillProgress.value,
    xpProgress = skillProgress.progress,
    xpIntoLevel = skillProgress.xpIntoLevel,
    xpNeededForLevel = skillProgress.xpNeededForLevel,
    xpToNextLevel = skillProgress.xpToNextLevel,
    prevThreshold = skillProgress.prevThreshold,
    nextThreshold = skillProgress.nextThreshold,
    contractUnlockLevel = slots.contractUnlockLevel,
    sponsorUnlockLevel = slots.sponsorUnlockLevel,
    contractsUnlocked = slots.contractsUnlocked,
    sponsorsUnlocked = slots.sponsorsUnlocked,
    contractUnlockedTiers = slots.contractTiers,
    sponsorUnlockedTiers = slots.sponsorTiers,
    contractSlots = slots.contractSlots,
    contractSlotsUsed = slots.contractSlotsUsed,
    contractOfferCap = slots.contractOfferCap,
    sponsorSlots = slots.sponsorSlots,
    sponsorSlotsUsed = slots.sponsorSlotsUsed,
    sponsorCooldownSlots = slots.sponsorCooldownSlots,
    sponsorOfferCap = slots.sponsorOfferCap,
    sponsorBonusMoney = sponsorBonuses.money,
    sponsorBonusXp = sponsorBonuses.xp,
    contractCompleted = dState.contracts.completed or 0,
    contractFailed = dState.contracts.failed or 0,
    sponsorsDropped = dState.sponsors.dropped or 0,
    sanctionedRacingUnlockLevel = discipline.id == "roadracing" and freConfig.getSanctionedRacingUnlockLevel() or nil,
    racingUnlocked = discipline.id == "roadracing" and overhaul_events_fre_sanctionedRacing.isRacingUnlocked(
      discipline.id
    ) or false,
  }
end

-- Contract and sponsor rows -------------------------------------------------------------------------

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
    targetDistanceMeters = contract.targetDistanceMeters,
    requiredSledId = contract.requiredSledId,
    requiredSledLabel = contract.requiredSledLabel,
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
    level = level,
  }
end

local function formatSponsorForUi(sponsor, now, level)
  local acknowledgedAt = tonumber(sponsor.warningAcknowledgedAt)
  local issuedAt = tonumber(sponsor.warningIssuedAt)
  local upkeepMinutes = math.max(1, tonumber(sponsor.upkeepMinutes) or 120)
  local nextCheckAt = tonumber(sponsor.nextCheckAt) or now
  local lastQualifiedAt = tonumber(sponsor.lastQualifiedAt)
  local requirementSatisfied = false
  local requirementStatus = "pending"
  local windowStartAt = math.max(0, nextCheckAt - upkeepMinutes)

  if sponsor.warningIssued == true then
    requirementStatus = "warning"
  elseif sponsor.probation == true then
    requirementStatus = "probation"
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
    targetDistanceMeters = sponsor.targetDistanceMeters,
    requiredSledId = sponsor.requiredSledId,
    requiredSledLabel = sponsor.requiredSledLabel,
    expiresAt = sponsor.expiresAt,
    minutesRemaining = math.max(0, (tonumber(sponsor.expiresAt) or now) - now),
    level = level,
    warningIssued = sponsor.warningIssued == true,
    -- Acknowledgement dismisses this notice, not the grace period or a later warning.
    warningAcknowledged = sponsor.warningIssued == true
      and acknowledgedAt ~= nil and issuedAt ~= nil and acknowledgedAt >= issuedAt,
    probation = sponsor.probation == true,
    warningIssuedAt = sponsor.warningIssuedAt,
    lastQualifiedAt = lastQualifiedAt,
    lastQualifiedRaceName = sponsor.lastQualifiedRaceName,
    lastQualifiedRaceRouteType = sponsor.lastQualifiedRaceRouteType,
    lastQualifiedTime = sponsor.lastQualifiedTime,
    lastQualifiedDistanceMeters = sponsor.lastQualifiedDistanceMeters,
    lastQualifiedSledId = sponsor.lastQualifiedSledId,
    requirementSatisfied = requirementSatisfied,
    requirementStatus = requirementStatus,
    requiredEvents = 1,
    windowStartAt = windowStartAt,
    nextCheckAt = nextCheckAt,
    checkMinutesRemaining = math.max(0, nextCheckAt - now),
  }
end

local function appendDisciplineOfferUiEntries(dState, now, level, activeContracts, availableContracts, activeSponsors, availableSponsors)
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

local function parentSkillUiSnapshot(parent)
  local summary = overhaul_events_fre_skills.getLicenseSummary(parent.id)
  if summary then
    local lanes = {}
    for _, laneId in ipairs(parent.laneIds or {}) do
      local lane = freConfig.getDisciplineById(laneId)
      local license = summary.licenses[laneId]
      local canUpgrade, reason, nextTier = overhaul_events_fre_skills.canUpgradeLicense(laneId, summary)
      table.insert(lanes, {
        id = laneId,
        label = lane and lane.label or laneId,
        tier = license and license.tier or nil,
        unlockLevels = license and license.unlockLevels or {},
        canUpgrade = canUpgrade,
        upgradeBlockedReason = reason,
        nextTier = nextTier,
      })
    end
    summary.lanes = lanes
    summary.licenses = nil
    return summary
  end
end

-- UI snapshots --------------------------------------------------------------------------------------

local function requestVehiclePowerRefresh()
  local racers = overhaul_events_aiRacers
  if racers and racers.requestStagingUiLivePowerRefresh then racers.requestStagingUiLivePowerRefresh() end
end

local function getVehiclePowerReadout()
  local racers = overhaul_events_aiRacers
  if not racers or not racers.getPlayerVehicleLivePowerWeight then return nil end
  local hp = racers.getPlayerVehicleLivePowerWeight()
  return hp and math.floor(hp + 0.5) or nil
end

local function getUiState(filterDisciplineId)
  local state = overhaul_events_fre_state.getState()
  local now = state.simTime
  -- Keep this snapshot read-only; scheduled maintenance owns generation and expiry.

  local activeContracts = {}
  local availableContracts = {}
  local activeSponsors = {}
  local availableSponsors = {}
  local disciplinesUi = {}
  local parentSkillsUi = {}

  local allowed = {}
  if type(filterDisciplineId) == "string" and filterDisciplineId ~= "" then
    local normalized = freConfig.getDisciplineIdFromType(filterDisciplineId) or string.lower(filterDisciplineId)
    allowed[normalized] = true
  end

  for _, discipline in ipairs(freConfig.getDisciplines()) do
    local dState = state.disciplines[discipline.id]
    local hasActiveLegacy = discipline.legacyOnly == true
      and (#(dState.contracts.active or {}) > 0 or #(dState.sponsors.active or {}) > 0)
    local showDiscipline = discipline.legacyOnly ~= true or hasActiveLegacy
    if showDiscipline and (next(allowed) == nil or allowed[discipline.id]) then
      local disciplineUi = buildDisciplineUiState(discipline.id, now)
      table.insert(disciplinesUi, disciplineUi)
      local level = disciplineUi.level

      appendDisciplineOfferUiEntries(dState, now, level, activeContracts, availableContracts, activeSponsors, availableSponsors)
    end
  end

  for _, parent in ipairs(freConfig.getParentSkills()) do
    local summary = parentSkillUiSnapshot(parent)
    if summary then table.insert(parentSkillsUi, summary) end
  end

  sortForUi(activeContracts, "contract")
  sortForUi(availableContracts, "contract")
  sortForUi(activeSponsors, "sponsor")
  sortForUi(availableSponsors, "sponsor")

  local racers = overhaul_events_aiRacers
  if uiStreamingActive and racers and racers.getPlayerVehicleLivePowerWeight then
    local hp, _, remainingSeconds = racers.getPlayerVehicleLivePowerWeight()
    -- Refresh lazily at snapshot boundaries; idle frames never queue beam-stat work.
    if not hp or (remainingSeconds and remainingSeconds <= POWER_REFRESH_BEFORE_EXPIRY_SECONDS) then
      requestVehiclePowerRefresh()
    end
  end
  local sanctionedRacing = overhaul_events_fre_sanctionedRacing.getOfferUiSnapshot(now)
  -- Remember blanks too, so completion restores an expired readout even at the same HP.
  if uiStreamingActive then lastPowerHp = sanctionedRacing and sanctionedRacing.playerCatalogHp end

  return {
    simTimeMinutes = now,
    levelId = overhaul_events_fre_raceCache.getRaceCache().levelId,
    disciplines = disciplinesUi,
    parentSkills = parentSkillsUi,
    activeContracts = activeContracts,
    availableContracts = availableContracts,
    activeSponsors = activeSponsors,
    availableSponsors = availableSponsors,
    sanctionedRacing = sanctionedRacing,
    sanctionedRacingOfferPeriodMinutes = overhaul_events_fre_sanctionedRacing.getOfferGenerationPeriodMinutes(),
    freeroamEventContractBlockReason = freHelpers.getFreeroamEventContractBlockMessage(),
  }
end

-- UI streaming --------------------------------------------------------------------------------------

local function setUiStreamingActive(active)
  local wasActive = uiStreamingActive
  uiStreamingActive = active == true
  if not uiStreamingActive then
    local racers = overhaul_events_aiRacers
    if racers and racers.cancelStagingUiLivePowerRefresh then racers.cancelStagingUiLivePowerRefresh() end
  end
  if uiStreamingActive and not wasActive then
    lastPowerHp = getVehiclePowerReadout()
    requestVehiclePowerRefresh()
    local now = overhaul_events_fre_state.getSimTime()
    overhaul_events_fre_offers.purgeExpiredEntries(now)
    overhaul_events_fre_offers.syncAllOffers(now)
    overhaul_events_fre_sanctionedRacing.syncGeneration(now)
    overhaul_events_fre_state.refreshMaintenanceSchedule(now)
  end
end

local function emitUiStateUpdate(reason)
  if not uiStreamingActive then return false end
  local state = overhaul_events_fre_state.getState()
  uiRevision = uiRevision + 1
  local payload = getUiState()
  payload.updateReason = reason or "state_changed"
  payload.revision = uiRevision
  local nextMaintenanceAt = overhaul_events_fre_state.getNextMaintenanceAt()
  payload.nextMaintenanceAt = nextMaintenanceAt
  payload.nextMaintenanceInMinutes = nextMaintenanceAt and math.max(0, nextMaintenanceAt - state.simTime) or nil
  guihooks.trigger("phoneFreContractsData", payload)
  return true
end

local function onOverhaulPlayerLivePowerSample(vehId)
  if not uiStreamingActive or not overhaul_events_fre_state.isCareerActive() then return end
  if vehId ~= be:getPlayerVehicleID(0) then return end
  local hp = getVehiclePowerReadout()
  -- Weight can drift as fuel burns; only a changed visible HP readout warrants clearing action feedback.
  if hp == lastPowerHp then return end
  lastPowerHp = hp
  emitUiStateUpdate("vehicle_power")
end

local function onPlayerVehicleChanged(vehId)
  if not uiStreamingActive or vehId ~= be:getPlayerVehicleID(0) then return end
  requestVehiclePowerRefresh()
  -- Clear the previous car immediately; the completion hook publishes the new readout.
  onOverhaulPlayerLivePowerSample(vehId)
end

local function onVehicleSwitched(_, newVehId, player)
  if player ~= nil and player ~= 0 then return end
  onPlayerVehicleChanged(newVehId)
end

local function onOverhaulTuningApplied()
  onPlayerVehicleChanged(be:getPlayerVehicleID(0))
end

-- Public API --------------------------------------------------------------------------------------

M.getUiState = getUiState
M.setUiStreamingActive = setUiStreamingActive
M.emitUiStateUpdate = emitUiStateUpdate
M.onOverhaulPlayerLivePowerSample = onOverhaulPlayerLivePowerSample
M.onVehicleSwitched = onVehicleSwitched
-- Part changes rebuild the vehicle and raise these same GE lifecycle hooks.
M.onVehicleSpawned = onPlayerVehicleChanged
M.onVehicleReplaced = onPlayerVehicleChanged
M.onVehicleResetted = onPlayerVehicleChanged
M.onOverhaulTuningApplied = onOverhaulTuningApplied

return M
