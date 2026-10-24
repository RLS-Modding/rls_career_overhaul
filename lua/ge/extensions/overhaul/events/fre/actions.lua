-- Player choices on freeroam contracts, sponsors and licenses: accept, abandon, sign, drop, acknowledge, upgrade.
-- Each action changes the shared progression state, reschedules maintenance and tells the UI what happened.
local M = {}

local freConfig = require("overhaul/events/freConfig")
local freHelpers = require("overhaul/events/fre/helpers")

-- Finds an entry by id in one list (`bucketName` is "contracts" or "sponsors", `listName` is "available" or "active").

local function findEntry(state, bucketName, listName, entryId)
  for _, discipline in ipairs(freConfig.getDisciplines()) do
    local disciplineState = state.disciplines[discipline.id]
    for entryIndex, entry in ipairs(disciplineState[bucketName][listName]) do
      if entry.id == entryId then return discipline, disciplineState, entryIndex, entry end
    end
  end
  return nil
end

local function tierIncluded(tiers, entry)
  local tier = entry.tier or "easy"
  for _, tierName in ipairs(tiers) do
    if tierName == tier then return true end
  end
  return false
end

-- Drops an offer that can no longer be taken and tells the UI.
local function expireOffer(disciplineState, bucketName, entryIndex, now, uiReason)
  table.remove(disciplineState[bucketName].available, entryIndex)
  overhaul_events_fre_state.refreshMaintenanceSchedule(now)
  overhaul_events_fre_ui.emitUiStateUpdate(uiReason)
end

local function isExpired(entry, now)
  return (tonumber(entry.expiresAt) or 0) <= now
end

local function requiredModelRejected(discipline, entry)
  local requiredModel = entry.requiredModel
  if not requiredModel or requiredModel == "" then return false end
  local vehiclePool = overhaul_events_fre_vehiclePool
  return not vehiclePool.isModelAllowedForDiscipline(discipline.id, requiredModel)
    or not vehiclePool.isValidVehicleModelKey(requiredModel)
end

local function moveToActiveContracts(discipline, disciplineState, entryIndex, entry, now)
  local tier = entry.tier or "easy"
  local contractLifetimeMinutes = tonumber(
    ((freConfig.getContractConfig(discipline.id) or {}).expiryMinutesByTier or {})[tier]
  ) or 60
  entry.expiresAt = now + contractLifetimeMinutes
  entry.acceptedAt = now
  table.insert(disciplineState.contracts.active, entry)
  table.remove(disciplineState.contracts.available, entryIndex)
end

function M.acceptContract(contractId)
  local blockMessage = freHelpers.getFreeroamEventContractBlockMessage()
  if blockMessage then return false, blockMessage end
  local state = overhaul_events_fre_state.getState()
  local now = tonumber(state.simTime) or 0
  local discipline, disciplineState, entryIndex, entry = findEntry(state, "contracts", "available", contractId)
  if not entry then return false, "Contract not found." end

  if isExpired(entry, now) then
    expireOffer(disciplineState, "contracts", entryIndex, now, "contract_offer_expired")
    return false, "Offer expired."
  end
  if requiredModelRejected(discipline, entry) then
    expireOffer(disciplineState, "contracts", entryIndex, now, "contract_offer_expired")
    return false, "Required model is invalid or blacklisted."
  end
  local skills = overhaul_events_fre_skills
  local tiers = skills.getUnlockedContractTiers(discipline.id, skills.getSkillLevel(discipline.id))
  if not tierIncluded(tiers, entry) then return false, "That contract license is not unlocked." end
  local slotCap = skills.getSharedSlotCap(discipline.id, "contracts")
  if skills.countActiveForParent(discipline.parentSkillId, "contracts") >= slotCap then
    return false, "No contract slots available."
  end

  moveToActiveContracts(discipline, disciplineState, entryIndex, entry, now)
  overhaul_events_fre_state.saveNow()
  overhaul_events_fre_state.refreshMaintenanceSchedule(now)
  overhaul_events_fre_ui.emitUiStateUpdate("contract_accepted")
  return true
end

function M.abandonContract(contractId)
  local state = overhaul_events_fre_state.getState()
  local now = tonumber(state.simTime) or 0
  local _, disciplineState, entryIndex, entry = findEntry(state, "contracts", "active", contractId)
  if not entry then return false, "Contract not found." end
  disciplineState.contracts.failed = disciplineState.contracts.failed + 1
  table.remove(disciplineState.contracts.active, entryIndex)
  overhaul_events_fre_state.refreshMaintenanceSchedule(now)
  overhaul_events_fre_ui.emitUiStateUpdate("contract_abandoned")
  return true
end

local function moveToActiveSponsors(discipline, disciplineState, entryIndex, entry, now)
  entry.warningIssued = false
  entry.warningIssuedAt = nil
  entry.probation = true
  local sponsorConfig = freConfig.getSponsorConfig(discipline.id) or {}
  local probationMinutes = tonumber((sponsorConfig.probationMinutesByTier or {})[entry.tier]) or 30
  entry.nextCheckAt = now + probationMinutes
  table.insert(disciplineState.sponsors.active, entry)
  table.remove(disciplineState.sponsors.available, entryIndex)
end

function M.signSponsor(sponsorId)
  local state = overhaul_events_fre_state.getState()
  local now = tonumber(state.simTime) or 0
  local discipline, disciplineState, entryIndex, entry = findEntry(state, "sponsors", "available", sponsorId)
  if not entry then return false, "Sponsor not found." end

  if isExpired(entry, now) then
    expireOffer(disciplineState, "sponsors", entryIndex, now, "sponsor_offer_expired")
    return false, "Offer expired."
  end
  local skills = overhaul_events_fre_skills
  local tiers = skills.getUnlockedSponsorTiers(discipline.id, skills.getSkillLevel(discipline.id))
  if not tierIncluded(tiers, entry) then return false, "That sponsor tier is not unlocked." end
  if not skills.hasFreeSponsorSlot(discipline.id) then return false, "No sponsor slots available." end

  moveToActiveSponsors(discipline, disciplineState, entryIndex, entry, now)
  overhaul_events_fre_state.saveNow()
  overhaul_events_fre_state.refreshMaintenanceSchedule(now)
  overhaul_events_fre_ui.emitUiStateUpdate("sponsor_signed")
  return true
end

function M.dropSponsor(sponsorId)
  local state = overhaul_events_fre_state.getState()
  local now = tonumber(state.simTime) or 0
  local discipline, disciplineState, entryIndex, entry = findEntry(state, "sponsors", "active", sponsorId)
  if not entry then return false, "Sponsor not found." end
  disciplineState.sponsors.dropped = disciplineState.sponsors.dropped + 1
  table.remove(disciplineState.sponsors.active, entryIndex)
  local parentState = overhaul_events_fre_skills.getParentSkillState(discipline.parentSkillId)
  parentState.sponsorSlotCooldowns = parentState.sponsorSlotCooldowns or {}
  local droppedSlotCooldownMinutes = tonumber(
    (freConfig.getSponsorConfig(discipline.id) or {}).droppedSlotCooldownMinutes
  ) or 15
  table.insert(parentState.sponsorSlotCooldowns, now + droppedSlotCooldownMinutes)
  overhaul_events_fre_state.saveNow()
  overhaul_events_fre_state.refreshMaintenanceSchedule(now)
  overhaul_events_fre_ui.emitUiStateUpdate("sponsor_dropped")
  return true
end

function M.acknowledgeSponsorWarning(sponsorId)
  local state = overhaul_events_fre_state.getState()
  local now = tonumber(state.simTime) or 0
  local _, _, _, entry = findEntry(state, "sponsors", "active", sponsorId)
  if not entry then return false, "Sponsor not found." end
  entry.warningAcknowledgedAt = now
  overhaul_events_fre_state.refreshMaintenanceSchedule(now)
  overhaul_events_fre_ui.emitUiStateUpdate("sponsor_warning_acknowledged")
  return true
end

function M.upgradeLicense(disciplineId)
  local upgraded, errorMessage, tier = overhaul_events_fre_skills.upgradeLicense(disciplineId)
  if not upgraded then return false, errorMessage end
  local now = overhaul_events_fre_state.getSimTime()
  local offerGenerated, offerMessage = false, nil
  if overhaul_events_fre_offers.generateImmediateContractOffer then
    offerGenerated, offerMessage = overhaul_events_fre_offers.generateImmediateContractOffer(disciplineId, now)
  end
  overhaul_events_fre_state.refreshMaintenanceSchedule(now)
  overhaul_events_fre_ui.emitUiStateUpdate("license_upgraded")
  return true, nil, tier, offerGenerated, offerMessage
end

return M
