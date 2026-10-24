-- Owns the freeroam progression save (contracts, sponsors, licenses) and the maintenance wake-up schedule.
-- The clock is sim minutes; offers, skills and sanctioned racing read and mutate the table from getState().
local M = {}

local freHelpers = require("overhaul/events/fre/helpers")
local freConfig = require("overhaul/events/freConfig")

-- Config ------------------------------------------------------------------------------------------

local SAVE_FILE = "/career/fre/freContractsSponsors.json"
local STATE_VERSION = 3
-- A pass that leaves the scheduler due "now" waits this long, so a stale overdue time cannot rebuild offers every frame.
local MAINTENANCE_SPIN_BACKOFF_MINUTES = 0.25

-- State -------------------------------------------------------------------------------------------

local state = nil
local stateLoaded = false
local nextMaintenanceAt = nil
local saveFeature

-- Helpers -----------------------------------------------------------------------------------------

local function newSanctionedRacingState()
  return { offer = nil, nextGenAt = 0, lastSkillGateOk = false }
end

local function newDisciplineState(disciplineId)
  return {
    id = disciplineId,
    contracts = { available = {}, active = {}, completed = 0, failed = 0, seeded = false, nextOfferAt = 0 },
    sponsors = { available = {}, active = {}, dropped = 0, seeded = false, nextOfferAt = 0 },
  }
end

local function buildDefaultState()
  local disciplines = {}
  for _, discipline in ipairs(freConfig.getDisciplines()) do
    disciplines[discipline.id] = newDisciplineState(discipline.id)
  end
  return {
    version = STATE_VERSION,
    simTime = 0,
    nextId = 1,
    disciplines = disciplines,
    parentSkills = {},
    sanctionedRacing = newSanctionedRacingState(),
  }
end

-- Load validation ---------------------------------------------------------------------------------

local function tableOrEmpty(value)
  return type(value) == "table" and value or {}
end

local function validateParentSkills()
  state.parentSkills = tableOrEmpty(state.parentSkills)
  local now = tonumber(state.simTime) or 0
  for _, parent in ipairs(freConfig.getParentSkills()) do
    local parentState = tableOrEmpty(state.parentSkills[parent.id])
    parentState.licenses = tableOrEmpty(parentState.licenses)
    local activeCooldowns = {}
    for _, expiry in ipairs(tableOrEmpty(parentState.sponsorSlotCooldowns)) do
      expiry = tonumber(expiry) or 0
      if expiry > now then table.insert(activeCooldowns, expiry) end
    end
    parentState.sponsorSlotCooldowns = activeCooldowns
    for laneId, license in pairs(parentState.licenses) do
      if type(license) ~= "table" then
        parentState.licenses[laneId] = nil
      else
        license.tier = license.tier or "easy"
        license.unlockLevels = tableOrEmpty(license.unlockLevels)
      end
    end
    state.parentSkills[parent.id] = parentState
  end
end

local function validateSanctionedRacing()
  local sanctioned = state.sanctionedRacing
  if type(sanctioned) ~= "table" then
    state.sanctionedRacing = newSanctionedRacingState()
    return
  end
  sanctioned.nextGenAt = tonumber(sanctioned.nextGenAt) or 0
  sanctioned.dispatchUiActive = nil
  if sanctioned.lastSkillGateOk ~= true and sanctioned.lastSkillGateOk ~= false then
    sanctioned.lastSkillGateOk = nil
  end
  if sanctioned.offer ~= nil and type(sanctioned.offer) ~= "table" then sanctioned.offer = nil end
end

-- Contracts and sponsors share the shape: offer lists, a lifetime counter, a seeded flag and the next offer time.
local function validateOfferBucket(bucket, counterKey)
  bucket.available = tableOrEmpty(bucket.available)
  bucket.active = tableOrEmpty(bucket.active)
  bucket[counterKey] = tonumber(bucket[counterKey]) or 0
  bucket.seeded = bucket.seeded == true
  bucket.nextOfferAt = tonumber(bucket.nextOfferAt) or 0
end

local function validateDisciplines()
  for _, discipline in ipairs(freConfig.getDisciplines()) do
    if not state.disciplines[discipline.id] then
      state.disciplines[discipline.id] = newDisciplineState(discipline.id)
    end
    local disciplineState = state.disciplines[discipline.id]
    disciplineState.contracts = tableOrEmpty(disciplineState.contracts)
    validateOfferBucket(disciplineState.contracts, "completed")
    disciplineState.contracts.failed = tonumber(disciplineState.contracts.failed) or 0
    disciplineState.sponsors = tableOrEmpty(disciplineState.sponsors)
    validateOfferBucket(disciplineState.sponsors, "dropped")
  end
end

local function validateLoadedState()
  state.nextId = tonumber(state.nextId) or 1
  state.version = STATE_VERSION
  state.simTime = tonumber(state.simTime) or 0
  state.disciplines = tableOrEmpty(state.disciplines)
  validateParentSkills()
  validateSanctionedRacing()
  validateDisciplines()
end

-- Save files ----------------------------------------------------------------------------------------

local function getSaveFeature()
  if not saveFeature then
    saveFeature = assert(require("overhaul/lib/save/store").feature("events.freSponsors", {
      owner = "overhaul_events_fre_state",
      files = { SAVE_FILE:sub(2) },
      root = "slot",
      phase = "profile",
      required = true,
      writer = { pretty = true },
    }))
  end
  return saveFeature
end

local function getCurrentSavePath()
  if not overhaul_career_saveSystem then return nil end
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  return savePath
end

local function ensureSaveDirectory(savePath, writer)
  if type(savePath) ~= "string" or savePath == "" then return end
  local relativeSaveDirectory = SAVE_FILE:match("^(.+)/[^/]+$")
  if not relativeSaveDirectory or relativeSaveDirectory == "" then return end
  local saveDirectory = savePath .. relativeSaveDirectory
  if not writer.exists(saveDirectory) then writer.mkdir(saveDirectory, true) end
end

-- Maintenance schedule ------------------------------------------------------------------------------

-- Offer generation is gated by purchased license tiers, not raw skill level: a tierUnlockLevels check here
-- once kept locked disciplines due "now" forever and ran the full maintenance pass every frame.
local function earliestDisciplineWake(wakeAt, skills)
  local pickEarlierTime = freHelpers.pickEarlierTime
  for _, discipline in ipairs(freConfig.getDisciplines()) do
    local disciplineState = state.disciplines[discipline.id]
    if disciplineState then
      local level = skills.getSkillLevel(discipline.id)
      local contractConfig = freConfig.getContractConfig(discipline.id)
      local sponsorConfig = freConfig.getSponsorConfig(discipline.id)
      local contractsUnlocked = #skills.getUnlockedContractTiers(discipline.id, level) > 0
      local sponsorsUnlocked = #skills.getUnlockedSponsorTiers(discipline.id, level) > 0

      if
        contractsUnlocked
        and #(disciplineState.contracts.available or {}) < skills.countOfferCap(level, contractConfig)
      then
        wakeAt = pickEarlierTime(wakeAt, disciplineState.contracts.nextOfferAt)
      end
      if
        sponsorsUnlocked and #(disciplineState.sponsors.available or {}) < skills.countOfferCap(level, sponsorConfig)
      then
        wakeAt = pickEarlierTime(wakeAt, disciplineState.sponsors.nextOfferAt)
      end
      for _, entry in ipairs(disciplineState.contracts.available or {}) do
        wakeAt = pickEarlierTime(wakeAt, entry.expiresAt)
      end
      for _, entry in ipairs(disciplineState.contracts.active or {}) do
        wakeAt = pickEarlierTime(wakeAt, entry.expiresAt)
      end
      for _, entry in ipairs(disciplineState.sponsors.available or {}) do
        wakeAt = pickEarlierTime(wakeAt, entry.expiresAt)
      end
      for _, sponsor in ipairs(disciplineState.sponsors.active or {}) do
        wakeAt = pickEarlierTime(wakeAt, sponsor.nextCheckAt)
      end
    end
  end
  return wakeAt
end

-- Only timestamps the maintenance pass consumes count: an expired visibleExpiresAt on a committed or racing
-- offer once pinned the wake time to "now" and rebuilt every contract offer table each frame.
local function earliestSanctionedWake(wakeAt)
  local sanctioned = state.sanctionedRacing
  if
    not (
      sanctioned
      and overhaul_events_fre_sanctionedRacing
      and overhaul_events_fre_sanctionedRacing.isRacingUnlocked("roadracing")
    )
  then
    return wakeAt
  end
  local offer = sanctioned.offer
  local phase = offer and offer.phase or nil
  if phase == "available" then
    return freHelpers.pickEarlierTime(wakeAt, offer.visibleExpiresAt)
  elseif phase == "committed" then
    local skipDeadline = offer.racingTeamBusinessOffer == true or offer.league1PlayerRace == true
    if skipDeadline then return wakeAt end
    return freHelpers.pickEarlierTime(wakeAt, offer.startDeadlineAt)
  elseif phase == "racing" then
    return wakeAt -- race hooks settle in-progress races, not the offer timer
  end
  local nextGenAt = tonumber(sanctioned.nextGenAt)
  if nextGenAt and nextGenAt > 0 then return freHelpers.pickEarlierTime(wakeAt, nextGenAt) end
  return wakeAt
end

-- Public API: state -------------------------------------------------------------------------------

function M.isCareerActive()
  local career = overhaul_career_career
  return career and career.isActive()
end

function M.getCurrentLevelId()
  local id = getCurrentLevelIdentifier()
  if id then return id end
  local missionFilename = getMissionFilename()
  if missionFilename and missionFilename ~= "" then return core_levels.getLevelName(missionFilename) end
  return nil
end

function M.getState()
  if not state then state = buildDefaultState() end
  return state
end

function M.loadState()
  local savePath = getCurrentSavePath()
  if not savePath then
    state = buildDefaultState()
    stateLoaded = false
    return state
  end
  stateLoaded = true
  local loaded = jsonReadFile(savePath .. SAVE_FILE)
  if type(loaded) ~= "table" then
    state = buildDefaultState()
    return state
  end
  state = loaded
  validateLoadedState()
  return state
end

function M.saveState(forcePath, writer)
  if not state or not forcePath then return false end
  ensureSaveDirectory(forcePath, writer or overhaul_career_saveSystem.getSaveWriter())
  return getSaveFeature().write(forcePath, state)
end

-- Callers save through the profile save hook; this stays so older call sites keep working.
function M.saveNow()
  return true
end

function M.isStateLoaded()
  return stateLoaded
end

function M.nextId(prefix)
  local currentState = M.getState()
  local id = string.format("%s-%d", prefix or "fre", currentState.nextId)
  currentState.nextId = currentState.nextId + 1
  return id
end

-- Public API: clock and maintenance ---------------------------------------------------------------

function M.updateSimTime(dtSim)
  local elapsedSeconds = math.max(tonumber(dtSim) or 0, 0)
  local currentState = M.getState()
  currentState.simTime = (tonumber(currentState.simTime) or 0) + elapsedSeconds / 60
end

function M.getSimTime()
  return M.getState().simTime
end

function M.getNextMaintenanceAt()
  return nextMaintenanceAt
end

function M.refreshMaintenanceSchedule(now)
  local currentState = M.getState()
  local skills = overhaul_events_fre_skills
  local currentTime = tonumber(now) or currentState.simTime
  local wakeAt = earliestDisciplineWake(nil, skills)
  wakeAt = freHelpers.pickEarlierTime(wakeAt, skills.getEarliestSponsorCooldownExpiry(currentTime))
  wakeAt = earliestSanctionedWake(wakeAt)
  if wakeAt and wakeAt < currentTime then wakeAt = currentTime end
  nextMaintenanceAt = wakeAt
  return wakeAt
end

function M.preventImmediateRetrigger(now)
  local currentTime = tonumber(now) or M.getSimTime()
  if nextMaintenanceAt and nextMaintenanceAt <= currentTime then
    nextMaintenanceAt = currentTime + MAINTENANCE_SPIN_BACKOFF_MINUTES
  end
  return nextMaintenanceAt
end

-- Game hooks --------------------------------------------------------------------------------------

function M.onExtensionUnloaded()
  if saveFeature then
    saveFeature.dispose()
    saveFeature = nil
  end
end

return M
