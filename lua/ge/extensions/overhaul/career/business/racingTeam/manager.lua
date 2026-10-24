-- Racing team manager: auto-assigns eligible drivers to sanctioned offers, gated by the manager skill and saved per business.
-- Read map: config and state, the timer and its save file, assign schedule, driver matching and assignment attempts, public settings, ticks and hooks.
local businessSaveState = require("overhaul/lib/business/saveState")
local M = {}

-- Config ------------------------------------------------------------------------------------------

local UPDATE_INTERVAL = 5
local ASSIGN_RETRY_WALL_SEC = 30
local DEFAULT_ASSIGN_INTERVAL_SEC = 1800

local ASSIGN_INTERVAL_OPTIONS = {
  { sec = 600, label = "10 minutes" },
  { sec = 1200, label = "20 minutes" },
  { sec = 1800, label = "30 minutes" },
  { sec = 2700, label = "45 minutes" },
  { sec = 3600, label = "60 minutes" },
}

-- State -------------------------------------------------------------------------------------------

local accumulator = 0
local timersByBusiness = {}

-- Shared helpers ----------------------------------------------------------------------------------

local function normalizeBusinessId(businessId)
  return tonumber(businessId) or businessId
end

local function getRacingTeamModule()
  return overhaul_career_business_racingTeam_racingTeam
end

local function isAllowedAssignIntervalSec(sec)
  sec = math.floor(tonumber(sec) or 0)
  for _, option in ipairs(ASSIGN_INTERVAL_OPTIONS) do
    if option.sec == sec then
      return true, sec
    end
  end
  return false
end

local function getManagerTimerPath(businessId, currentSavePath)
  if not currentSavePath or not businessId then
    return nil
  end
  return businessSaveState.businessFilePath(businessId, "racingTeamManager.json", currentSavePath .. "")
end

local function getManagerSkillLevel(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return 0
  end
  local skillTree = overhaul_career_business_skillTree
  return math.max(0, math.floor(tonumber(skillTree.getNodeProgress(businessId, "team-operations", "manager")) or 0))
end

local function hasManagerSkill(businessId)
  return getManagerSkillLevel(businessId) > 0
end

-- Manager timer and its save file -----------------------------------------------------------------

local function loadManagerTimer(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { elapsed = 0, autoAssignEnabled = false, assignIntervalSec = DEFAULT_ASSIGN_INTERVAL_SEC, nextAssignWallEpoch = nil }
  end
  if timersByBusiness[businessId] then
    return timersByBusiness[businessId]
  end
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  local path = getManagerTimerPath(businessId, savePath)
  local data = path and jsonReadFile(path) or {}
  local elapsed = math.max(0, tonumber(data.elapsed) or 0)
  local fileExisted = path and FS:fileExists(path) == true
  local autoAssignEnabled
  if data.autoAssignEnabled ~= nil then
    autoAssignEnabled = data.autoAssignEnabled == true
  elseif fileExisted then
    autoAssignEnabled = true
  else
    autoAssignEnabled = false
  end
  local assignIntervalSec = DEFAULT_ASSIGN_INTERVAL_SEC
  local okInterval, normalized = isAllowedAssignIntervalSec(data.assignIntervalSec)
  if okInterval then
    assignIntervalSec = normalized
  end
  local nextAssignWallEpoch = tonumber(data.nextAssignWallEpoch)
  if not nextAssignWallEpoch and autoAssignEnabled then
    nextAssignWallEpoch = os.time() + math.max(0, assignIntervalSec - elapsed)
  end
  timersByBusiness[businessId] = {
    elapsed = elapsed,
    autoAssignEnabled = autoAssignEnabled,
    assignIntervalSec = assignIntervalSec,
    nextAssignWallEpoch = nextAssignWallEpoch,
  }
  return timersByBusiness[businessId]
end

local function writeManagerTimerFile(path, payload)
  overhaul_career_saveSystem.jsonWriteFileSafe(path, payload, true)
end

local function saveManagerTimer(businessId, currentSavePath, writer)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not timersByBusiness[businessId] or not currentSavePath then
    return
  end
  local path = getManagerTimerPath(businessId, currentSavePath)
  if not path then
    return
  end
  local dirPath = string.match(path, "^(.*)/[^/]+$")
  if dirPath and not writer.exists(dirPath) then
    writer.mkdir(dirPath)
  end
  local timer = timersByBusiness[businessId]
  writeManagerTimerFile(path, {
    elapsed = timer.elapsed or 0,
    autoAssignEnabled = timer.autoAssignEnabled == true,
    assignIntervalSec = timer.assignIntervalSec or DEFAULT_ASSIGN_INTERVAL_SEC,
    nextAssignWallEpoch = timer.nextAssignWallEpoch,
  })
end

local function persistManagerTimer(businessId, triggerCareerSave)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return false
  end
  local timer = timersByBusiness[businessId] or loadManagerTimer(businessId)
  if not timer then
    return false
  end
  timersByBusiness[businessId] = timer
  if triggerCareerSave then
    overhaul_career_saveSystem.saveCurrent()
  end
  return true
end

-- Assign schedule ---------------------------------------------------------------------------------

local function getManagerAssignmentInterval(businessId)
  businessId = normalizeBusinessId(businessId)
  if getManagerSkillLevel(businessId) < 2 then
    return DEFAULT_ASSIGN_INTERVAL_SEC
  end
  local timer = loadManagerTimer(businessId)
  local ok, sec = isAllowedAssignIntervalSec(timer.assignIntervalSec)
  if ok then
    return sec
  end
  return DEFAULT_ASSIGN_INTERVAL_SEC
end

local function scheduleNextAssignWall(businessId, delaySec)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return
  end
  local timer = loadManagerTimer(businessId)
  timer.nextAssignWallEpoch = os.time() + math.max(1, math.floor(tonumber(delaySec) or 1))
  timersByBusiness[businessId] = timer
end

local function ensureNextAssignWallEpoch(businessId)
  businessId = normalizeBusinessId(businessId)
  local timer = loadManagerTimer(businessId)
  local due = tonumber(timer.nextAssignWallEpoch)
  if due and due > 0 then
    return due
  end
  local interval = getManagerAssignmentInterval(businessId)
  local elapsed = tonumber(timer.elapsed) or 0
  timer.nextAssignWallEpoch = os.time() + math.max(0, math.floor(interval - elapsed))
  timersByBusiness[businessId] = timer
  return timer.nextAssignWallEpoch
end

local function triggerManagerSettingsUpdated(businessId, extra)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return
  end
  local payload = {
    businessId = tostring(businessId),
    autoAssignEnabled = M.getManagerAutoAssignEnabled(businessId),
    assignIntervalSec = M.getManagerAssignIntervalSec(businessId),
    assignIntervalRemainingSec = M.getManagerAssignIntervalRemainingSec(businessId),
    nextAssignWallEpoch = M.getManagerNextAssignWallEpoch(businessId),
  }
  if type(extra) == "table" then
    for k, v in pairs(extra) do
      payload[k] = v
    end
  end
  guihooks.trigger("racingTeamManagerSettingsUpdated", payload)
end

-- Driver and offer match --------------------------------------------------------------------------

local function driverEligibleForAutoRace(businessId, tech)
  if not tech or tech.fired then
    return false
  end
  if tech.jobId or tech.pendingRaceOffer then
    return false
  end
  if (tech.currentAction or "idle") ~= "idle" then
    return false
  end
  if not tech.fleetVehicleId then
    return false
  end
  local racingTeamModule = getRacingTeamModule()
  if racingTeamModule then
    if racingTeamModule.getRacingTeamDriverPostRaceCooldownRemainingSec(businessId, tech) > 0 then
      return false
    end
  end
  return true
end

local function offerMatchesDriverFleet(businessId, racingTeamModule, tech, offer, requireBracketMatch)
  if not requireBracketMatch then
    return true
  end
  return racingTeamModule.fleetVehicleEligibleForOffer(businessId, tech.fleetVehicleId, offer)
    and not racingTeamModule.fleetVehicleOverpoweredForOffer(businessId, tech.fleetVehicleId, offer)
end

-- Assign attempt and due queue --------------------------------------------------------------------


-- Tries each idle driver against each board offer once; true when one was accepted.
local function tryManagerAssignOnce(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return false
  end
  if not M.getManagerAutoAssignEnabled(businessId) then
    return false
  end
  local racingTeamModule = getRacingTeamModule()
  if not racingTeamModule then
    return false
  end
  if not racingTeamModule.isCurrentLeagueAtLeast(businessId, 2) then
    return false
  end

  local businessManager = overhaul_career_business_manager
  local obj = businessManager.getBusinessObject("racingTeam")
  if not obj or not obj.getTechsForBusiness then
    return false
  end

  local board = racingTeamModule.ensureSanctionedRaceOffersBoard(businessId)
  local offers = board and board.offers
  if type(offers) ~= "table" or #offers == 0 then
    return false
  end

  local techs = obj.getTechsForBusiness(businessId) or {}
  local requireDriverBracketMatch = getManagerSkillLevel(businessId) >= 2

  for _, tech in ipairs(techs) do
    if driverEligibleForAutoRace(businessId, tech) then
      for _, offer in ipairs(offers) do
        if type(offer) == "table" and offer.id ~= nil then
          if offerMatchesDriverFleet(businessId, racingTeamModule, tech, offer, requireDriverBracketMatch) then
            if racingTeamModule.acceptRacingTeamRaceOffer(businessId, offer.id, tech.id) == true then
              return true
            end
          end
        end
      end
    end
  end
  return false
end

local function processManagerAssignDue(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not hasManagerSkill(businessId) or not M.getManagerAutoAssignEnabled(businessId) then
    return
  end
  local due = ensureNextAssignWallEpoch(businessId)
  if os.time() < due then
    return
  end
  local interval = getManagerAssignmentInterval(businessId)
  local assigned = tryManagerAssignOnce(businessId)
  if assigned then
    scheduleNextAssignWall(businessId, interval)
  else
    scheduleNextAssignWall(businessId, ASSIGN_RETRY_WALL_SEC)
  end
  triggerManagerSettingsUpdated(businessId, { assignSucceeded = assigned })
  if assigned then
    local racingTeamModule = getRacingTeamModule()
    if racingTeamModule then
      -- The assignment is settled; a toast failure must not restart it.
      pcall(racingTeamModule.tickScheduledRaceReadyToasts)
    end
  end
end

-- Per-frame update --------------------------------------------------------------------------------

function M.tickAccumulated(dtSim)
  if not dtSim or dtSim <= 0 then
    return
  end
  if not overhaul_career_career or not overhaul_career_career.isActive() then
    return
  end
  accumulator = accumulator + dtSim
  if accumulator < UPDATE_INTERVAL then
    return
  end
  accumulator = 0

  local businessManager = overhaul_career_business_manager
  local purchased = businessManager.getPurchasedBusinesses("racingTeam")
  if type(purchased) ~= "table" then
    return
  end

  for bid, owned in pairs(purchased) do
    if owned and hasManagerSkill(bid) then
      processManagerAssignDue(normalizeBusinessId(bid))
    end
  end
end

-- Career lifecycle --------------------------------------------------------------------------------

function M.onCareerActivated()
  accumulator = 0
  timersByBusiness = {}
end

function M.clearManagerTimer(businessId)
  timersByBusiness[normalizeBusinessId(businessId)] = {
    elapsed = 0, autoAssignEnabled = false, assignIntervalSec = DEFAULT_ASSIGN_INTERVAL_SEC
  }
end

function M.onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  if not currentSavePath then
    return
  end
  local businessManager = overhaul_career_business_manager
  local purchased = businessManager.getPurchasedBusinesses("racingTeam")
  if type(purchased) ~= "table" then
    return
  end
  for bid, owned in pairs(purchased) do
    if owned and hasManagerSkill(bid) then
      local id = normalizeBusinessId(bid)
      loadManagerTimer(id)
      saveManagerTimer(id, currentSavePath, writer)
    end
  end
end

-- Public API: interval and auto-assign settings ---------------------------------------------------

function M.getAssignIntervalOptionsForUI()
  local options = {}
  for _, option in ipairs(ASSIGN_INTERVAL_OPTIONS) do
    table.insert(options, { sec = option.sec, label = option.label })
  end
  return options
end

function M.getManagerAssignmentInterval(businessId)
  return getManagerAssignmentInterval(businessId)
end

function M.getManagerAssignIntervalSec(businessId)
  return M.getManagerAssignmentInterval(businessId)
end

function M.getManagerNextAssignWallEpoch(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not hasManagerSkill(businessId) or not M.getManagerAutoAssignEnabled(businessId) then
    return nil
  end
  return ensureNextAssignWallEpoch(businessId)
end

function M.getManagerAssignIntervalRemainingSec(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not hasManagerSkill(businessId) then
    return nil
  end
  if not M.getManagerAutoAssignEnabled(businessId) then
    return nil
  end
  local due = ensureNextAssignWallEpoch(businessId)
  return math.max(0, math.floor(due - os.time() + 0.5))
end

function M.setManagerAssignIntervalSec(businessId, intervalSec)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return false
  end
  if getManagerSkillLevel(businessId) < 2 then
    return false
  end
  local ok, normalized = isAllowedAssignIntervalSec(intervalSec)
  if not ok then
    return false
  end
  local timer = loadManagerTimer(businessId)
  timer.assignIntervalSec = normalized
  if timer.autoAssignEnabled then
    scheduleNextAssignWall(businessId, normalized)
  end
  timersByBusiness[businessId] = timer
  persistManagerTimer(businessId, true)
  triggerManagerSettingsUpdated(businessId)
  return true, normalized
end

function M.getManagerAutoAssignEnabled(businessId)
  local timer = loadManagerTimer(normalizeBusinessId(businessId))
  return timer and timer.autoAssignEnabled == true
end

function M.setManagerAutoAssignEnabled(businessId, enabled)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return false
  end
  if not hasManagerSkill(businessId) then
    return false
  end
  local timer = loadManagerTimer(businessId)
  timer.autoAssignEnabled = enabled == true
  if timer.autoAssignEnabled then
    scheduleNextAssignWall(businessId, getManagerAssignmentInterval(businessId))
  else
    timer.nextAssignWallEpoch = nil
  end
  timersByBusiness[businessId] = timer
  persistManagerTimer(businessId, true)
  triggerManagerSettingsUpdated(businessId)
  return true, timer.autoAssignEnabled
end

-- Public API: dev and assign triggers -------------------------------------------------------------

function M.processAssignDueNow(businessId)
  processManagerAssignDue(normalizeBusinessId(businessId))
end

function M.devSkipAssignWait(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not hasManagerSkill(businessId) then
    return false
  end
  local timer = loadManagerTimer(businessId)
  timer.nextAssignWallEpoch = os.time()
  timersByBusiness[businessId] = timer
  processManagerAssignDue(businessId)
  return true
end

return M
