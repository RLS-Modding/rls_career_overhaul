local M = {}

local freConfig = require('gameplay/fre/config')

local SAVE_FILE = "/career/fre/freContractsSponsors.json"

local state = nil
local nextMaintenanceAt = nil

local function isCareerActive()
  local career = career_career
  return career and type(career.isActive) == "function" and career.isActive()
end

local function getCurrentLevelId()
  if getCurrentLevelIdentifier then
    local id = getCurrentLevelIdentifier()
    if id then return id end
  end
  if core_levels and getMissionFilename then
    local mf = getMissionFilename()
    if mf and mf ~= '' then
      return core_levels.getLevelName(mf)
    end
  end
  return nil
end

local function getCurrentSavePath()
  if not career_saveSystem or not career_saveSystem.getCurrentSaveSlot then
    return nil
  end
  local _, savePath = career_saveSystem.getCurrentSaveSlot()
  return savePath
end

local function ensureSaveDirectory(savePath)
  if type(savePath) ~= "string" or savePath == "" then
    return
  end
  local relDir = SAVE_FILE:match("^(.+)/[^/]+$")
  if not relDir or relDir == "" then
    return
  end
  local fullDir = savePath .. relDir
  if FS and not FS:directoryExists(fullDir) then
    FS:directoryCreate(fullDir, true)
  end
end

local function initDisciplineState(disciplineId)
  return {
    id = disciplineId,
    contracts = {
      available = {},
      active = {},
      completed = 0,
      failed = 0,
      seeded = false,
      nextOfferAt = 0
    },
    sponsors = {
      available = {},
      active = {},
      dropped = 0,
      seeded = false,
      nextOfferAt = 0
    }
  }
end

local function buildDefaultState()
  local cfg = freConfig.getConfig()
  local disciplines = {}
  for _, discipline in ipairs(cfg.disciplines or {}) do
    disciplines[discipline.id] = initDisciplineState(discipline.id)
  end
  return {
    simTime = 0,
    nextId = 1,
    disciplines = disciplines,
    sanctionedRacing = { offer = nil, nextGenAt = 0, lastSkillGateOk = false }
  }
end

local function validateLoadedState()
  local cfg = freConfig.getConfig()
  state.nextId = tonumber(state.nextId) or 1
  state.simTime = tonumber(state.simTime) or 0
  state.disciplines = type(state.disciplines) == "table" and state.disciplines or {}
  if not state.sanctionedRacing or type(state.sanctionedRacing) ~= "table" then
    state.sanctionedRacing = { offer = nil, nextGenAt = 0, lastSkillGateOk = false }
  else
    state.sanctionedRacing.nextGenAt = tonumber(state.sanctionedRacing.nextGenAt) or 0
    state.sanctionedRacing.dispatchUiActive = nil
    if state.sanctionedRacing.lastSkillGateOk ~= true and state.sanctionedRacing.lastSkillGateOk ~= false then
      state.sanctionedRacing.lastSkillGateOk = nil
    end
    if state.sanctionedRacing.offer ~= nil and type(state.sanctionedRacing.offer) ~= "table" then
      state.sanctionedRacing.offer = nil
    end
  end

  for _, discipline in ipairs(cfg.disciplines or {}) do
    if not state.disciplines[discipline.id] then
      state.disciplines[discipline.id] = initDisciplineState(discipline.id)
    end
    local dState = state.disciplines[discipline.id]
    dState.contracts = type(dState.contracts) == "table" and dState.contracts or {}
    dState.contracts.available = type(dState.contracts.available) == "table" and dState.contracts.available or {}
    dState.contracts.active = type(dState.contracts.active) == "table" and dState.contracts.active or {}
    dState.contracts.completed = tonumber(dState.contracts.completed) or 0
    dState.contracts.failed = tonumber(dState.contracts.failed) or 0
    dState.contracts.seeded = dState.contracts.seeded == true
    dState.contracts.nextOfferAt = tonumber(dState.contracts.nextOfferAt) or 0

    dState.sponsors = type(dState.sponsors) == "table" and dState.sponsors or {}
    dState.sponsors.available = type(dState.sponsors.available) == "table" and dState.sponsors.available or {}
    dState.sponsors.active = type(dState.sponsors.active) == "table" and dState.sponsors.active or {}
    dState.sponsors.dropped = tonumber(dState.sponsors.dropped) or 0
    dState.sponsors.seeded = dState.sponsors.seeded == true
    dState.sponsors.nextOfferAt = tonumber(dState.sponsors.nextOfferAt) or 0
  end
end

local function getState()
  if not state then
    state = buildDefaultState()
  end
  return state
end

local function loadState()
  local savePath = getCurrentSavePath()
  if not savePath then
    state = buildDefaultState()
    return state
  end

  local loaded = jsonReadFile(savePath .. SAVE_FILE)
  if type(loaded) ~= "table" then
    state = buildDefaultState()
    return state
  end
  state = loaded
  validateLoadedState()
  return state
end

local function saveState(forcePath)
  if not state then
    return false
  end
  local savePath = forcePath or getCurrentSavePath()
  if not savePath then
    return false
  end
  ensureSaveDirectory(savePath)
  return career_saveSystem.jsonWriteFileSafe(savePath .. SAVE_FILE, state, true)
end

local function nextId(prefix)
  local s = getState()
  local id = string.format("%s-%d", prefix or "fre", s.nextId)
  s.nextId = s.nextId + 1
  return id
end

local function updateSimTime(dtSim)
  local dt = tonumber(dtSim) or 0
  if dt < 0 then
    dt = 0
  end
  local s = getState()
  s.simTime = tonumber(s.simTime) or 0
  s.simTime = s.simTime + dt / 60
end

local function getSimTime()
  return getState().simTime
end

local function getNextMaintenanceAt()
  return nextMaintenanceAt
end

local function refreshMaintenanceSchedule(now)
  local s = getState()
  local pickEarlierTime = gameplay_events_freContracts_helpers.pickEarlierTime
  local skills = gameplay_events_freContracts_skills
  local nextAt = nil
  local currentTime = tonumber(now) or s.simTime

  for _, discipline in ipairs(freConfig.getDisciplines()) do
    local dState = s.disciplines[discipline.id]
    if dState then
      local level = skills.getSkillLevel(discipline.id)
      local contractCfg = freConfig.getContractConfig(discipline.id)
      local sponsorCfg = freConfig.getSponsorConfig(discipline.id)
      local contractUnlockLevel = tonumber((contractCfg.tierUnlockLevels or {}).easy) or math.huge
      local sponsorUnlockLevel = tonumber((sponsorCfg.tierUnlockLevels or {}).easy) or math.huge
      local contractsUnlocked = level >= contractUnlockLevel
      local sponsorsUnlocked = level >= sponsorUnlockLevel

      if contractsUnlocked and #(dState.contracts.available or {}) < skills.countOfferCap(level, contractCfg) then
        nextAt = pickEarlierTime(nextAt, dState.contracts.nextOfferAt)
      end
      if sponsorsUnlocked and #(dState.sponsors.available or {}) < skills.countOfferCap(level, sponsorCfg) then
        nextAt = pickEarlierTime(nextAt, dState.sponsors.nextOfferAt)
      end

      for _, entry in ipairs(dState.contracts.available or {}) do
        nextAt = pickEarlierTime(nextAt, entry.expiresAt)
      end
      for _, entry in ipairs(dState.contracts.active or {}) do
        nextAt = pickEarlierTime(nextAt, entry.expiresAt)
      end
      for _, entry in ipairs(dState.sponsors.available or {}) do
        nextAt = pickEarlierTime(nextAt, entry.expiresAt)
      end
      for _, sponsor in ipairs(dState.sponsors.active or {}) do
        nextAt = pickEarlierTime(nextAt, sponsor.nextCheckAt)
      end
    end
  end

  local sr = state.sanctionedRacing
  if sr and gameplay_events_freContracts_sanctionedRacing and gameplay_events_freContracts_sanctionedRacing.isRacingUnlocked("roadracing") then
    nextAt = pickEarlierTime(nextAt, sr.nextGenAt)
    local offer = sr.offer
    if offer then
      nextAt = pickEarlierTime(nextAt, offer.visibleExpiresAt)
      if offer.phase == "committed" and offer.startDeadlineAt then
        nextAt = pickEarlierTime(nextAt, offer.startDeadlineAt)
      end
    end
  end

  if nextAt and nextAt < currentTime then
    nextAt = currentTime
  end
  nextMaintenanceAt = nextAt
  return nextAt
end

M.isCareerActive = isCareerActive
M.getCurrentLevelId = getCurrentLevelId
M.getState = getState
M.loadState = loadState
M.saveState = saveState
M.nextId = nextId
M.updateSimTime = updateSimTime
M.getSimTime = getSimTime
M.getNextMaintenanceAt = getNextMaintenanceAt
M.refreshMaintenanceSchedule = refreshMaintenanceSchedule

return M
