-- Free-roam race records per vehicle and map: best times, drift scores, top speeds, tractor pulls and derby stats.
-- Saved with the career profile through the save store; other extensions reach it as the raceRecords capability.
local M = {}

local raceDataCatalog = require("overhaul/lib/events/raceDataCatalog")
local raceScoring = require("overhaul/lib/events/raceScoring")

-- Config ------------------------------------------------------------------------------------------

local LEADERBOARD_FILE = "career/rls_career/races_leaderboard.json"
local SAVE_FEATURE_ID = "events.leaderboards"
local SAVE_OWNER = "overhaul_events_leaderboards"
local PULL_DISTANCE_TOLERANCE_M = 0.001
local PODIUM_PLACES = 3

-- State -------------------------------------------------------------------------------------------

-- Records by map id, then inventory id (as a string), then race label.
local leaderboard = {}
local leaderboardLoaded = false
local saveFeature

-- Helpers -----------------------------------------------------------------------------------------

local function getSaveFeature()
  if not saveFeature then
    saveFeature = assert(require("overhaul/lib/save/store").feature(SAVE_FEATURE_ID, {
      owner = SAVE_OWNER,
      files = { LEADERBOARD_FILE },
      root = "slot",
      phase = "profile",
      required = true,
      writer = { pretty = true },
    }))
  end
  return saveFeature
end

local function loadLeaderboard()
  if leaderboardLoaded then return end
  if not overhaul_career_career or not overhaul_career_career.isActive() then return end
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if not savePath then return end
  leaderboard = jsonReadFile(savePath .. "/" .. LEADERBOARD_FILE) or {}
  if type(leaderboard) ~= "table" then leaderboard = {} end
  leaderboardLoaded = true
end

local function saveLeaderboard(currentSavePath)
  if not currentSavePath then return end
  getSaveFeature().write(currentSavePath, leaderboard)
end

-- Ranking -----------------------------------------------------------------------------------------

-- Tractor pulling is distance-first: a full pull always outranks a partial one, and time only breaks ties between full pulls.
local function isBetterPull(entry, previous)
  local newDistance = math.max(0, tonumber(entry.pullDistance) or 0)
  local oldDistance = math.max(0, tonumber(previous.pullDistance) or 0)
  local newFull = entry.fullPull == true
  local oldFull = previous.fullPull == true
  if newFull ~= oldFull then return newFull end
  if math.abs(newDistance - oldDistance) > PULL_DISTANCE_TOLERANCE_M then return newDistance > oldDistance end
  if newFull then return (tonumber(entry.time) or math.huge) < (tonumber(previous.time) or math.huge) end
  return false
end

local function isBetterDriftScore(entry, previous)
  local previousScore = tonumber(previous.driftScore)
  if previousScore and (previousScore < 0 or previousScore >= math.huge or previousScore ~= previousScore) then
    previousScore = nil
  end
  if not previousScore then return true end
  return (tonumber(entry.driftScore) or 0) > previousScore
end

local function isScoreResult(entry, previous, levelId)
  if (tonumber(entry.driftScore) or 0) > 0 or (tonumber(previous.driftScore) or 0) > 0 then return true end
  if entry.scoreMode ~= nil then return entry.scoreMode == true end
  if entry.driftScore == nil then return false end
  local race = raceDataCatalog.loadRaces(levelId)[entry.raceName]
  return race and (race.driftGoal or race.burnoutComp) and true or false
end

-- Returns nil when the race is not a top speed race, so the next ranking rule decides.
local function topSpeedVerdict(entry, previous, levelId)
  local race = raceDataCatalog.loadRaces(levelId)[entry.raceName]
  if not (race and race.topSpeed) then return nil end
  if not previous.topSpeed then return true end
  return entry.topSpeed > previous.topSpeed
end

-- Damage races compare the reward each run would earn from the goal time and its own damage.
local function isBetterDamageScore(entry, previous, levelId)
  local race = raceDataCatalog.loadRaces(levelId)[entry.raceName]
  if not race then return true end

  local goalTime = race.bestTime
  local baseReward = race.reward
  if entry.isAltRoute and race.altRoute then
    goalTime = race.altRoute.bestTime
    baseReward = race.altRoute.reward
  end
  if entry.isHotlap and race.hotlap then goalTime = race.hotlap end

  local currentScore =
    raceScoring.hybridRaceReward(goalTime, baseReward, entry.time, entry.damageFactor, entry.damagePercentage)
  if not previous.time then return true end
  local existingScore = raceScoring.hybridRaceReward(
    goalTime,
    baseReward,
    previous.time,
    entry.damageFactor,
    previous.damagePercentage or 0
  )
  return currentScore > existingScore
end

local function isBestTime(entry)
  local levelId = getCurrentLevelIdentifier()
  local previous = ((leaderboard[levelId] or {})[tostring(entry.inventoryId)] or {})[entry.raceLabel] or {}

  if entry.pullDistance ~= nil then return isBetterPull(entry, previous) end
  if isScoreResult(entry, previous, levelId) then return isBetterDriftScore(entry, previous) end
  if entry.topSpeed and entry.topSpeed > 0 then
    local verdict = topSpeedVerdict(entry, previous, levelId)
    if verdict ~= nil then return verdict end
  end
  if entry.damageFactor and entry.damageFactor > 0 then return isBetterDamageScore(entry, previous, levelId) end

  if not previous.time then return true end
  return entry.time < previous.time
end

-- Records -----------------------------------------------------------------------------------------

local function vehicleRecords(levelId, inventoryId)
  leaderboard[levelId] = leaderboard[levelId] or {}
  local key = tostring(inventoryId)
  leaderboard[levelId][key] = leaderboard[levelId][key] or {}
  return leaderboard[levelId][key]
end

local function storeBestEntry(record, entry)
  record.time = entry.time
  record.splitTimes = entry.splitTimes
  record.driftScore = entry.driftScore
  record.damagePercentage = entry.damagePercentage
  record.damageFactor = entry.damageFactor
  record.topSpeed = entry.topSpeed
  if entry.pullDistance ~= nil then
    record.pullDistance = entry.pullDistance
    record.fullPull = entry.fullPull == true
    record.sledId = entry.sledId
  end
  record.reward = entry.reward
end

local function addLeaderboardEntry(entry)
  local levelId = getCurrentLevelIdentifier()
  local previous = ((leaderboard[levelId] or {})[tostring(entry.inventoryId)] or {})[entry.raceLabel] or {}
  if overhaul_career_career.isActive() and entry.pullDistance == nil then
    overhaul_career_garage_inventory.saveFRETimeToVehicle(
      entry.raceLabel,
      entry.inventoryId,
      entry.time,
      entry.driftScore,
      isScoreResult(entry, previous, levelId),
      previous
    )
  end
  if not overhaul_dev_raceDataCollection then extensions.load("overhaul_dev_raceDataCollection") end
  if entry.pullDistance == nil then overhaul_dev_raceDataCollection.collectDataFromEntry(entry) end

  local records = vehicleRecords(levelId, entry.inventoryId)
  if not isBestTime(entry) then return false end
  records[entry.raceLabel] = records[entry.raceLabel] or {}
  storeBestEntry(records[entry.raceLabel], entry)
  return true
end

local function nonNegativeInteger(value)
  return math.max(0, math.floor(tonumber(value) or 0))
end

local function isValidPlacement(placement)
  return placement and placement == placement and placement ~= math.huge and placement ~= -math.huge and placement >= 1
end

local function addDemoRun(record, place, survivalTime, fastestEliminationTime)
  local runs = nonNegativeInteger(record.demoRuns) + 1
  local wins = nonNegativeInteger(record.demoWins)
  local podiums = nonNegativeInteger(record.demoPodiums)
  local placementSum = math.max(0, tonumber(record.demoPlacementSum) or 0)
  local totalSurvivalTime = math.max(0, tonumber(record.demoTotalSurvivalTime) or 0)

  if place == 1 then wins = wins + 1 end
  if place <= PODIUM_PLACES then podiums = podiums + 1 end
  placementSum = placementSum + place
  totalSurvivalTime = totalSurvivalTime + survivalTime

  record.demoRuns = runs
  record.demoWins = wins
  record.demoPodiums = podiums
  record.demoPlacementSum = placementSum
  record.demoAveragePlacement = placementSum / runs
  record.demoPodiumRate = podiums / runs
  record.demoAverageSurvivalTime = totalSurvivalTime / runs
  record.demoTotalSurvivalTime = totalSurvivalTime
  record.demoBestPlacement = math.min(math.max(1, math.floor(tonumber(record.demoBestPlacement) or place)), place)
  record.demoLongestSurvivalTime = math.max(tonumber(record.demoLongestSurvivalTime) or 0, survivalTime)

  if fastestEliminationTime and fastestEliminationTime > 0 then
    local previousFastest = tonumber(record.demoFastestEliminationTime)
    if not previousFastest or previousFastest <= 0 then
      record.demoFastestEliminationTime = fastestEliminationTime
    else
      record.demoFastestEliminationTime = math.min(previousFastest, fastestEliminationTime)
    end
  end
end

local function updateDemoDerbyStats(inventoryId, raceLabel, result)
  if not inventoryId or not raceLabel then return nil end

  local records = vehicleRecords(getCurrentLevelIdentifier(), inventoryId)
  local record = records[raceLabel] or {}
  records[raceLabel] = record

  local placement = tonumber(result and result.placement)
  if not isValidPlacement(placement) then return nil end
  local survivalTime = math.max(0, tonumber(result and result.survivalTime) or 0)
  addDemoRun(record, math.floor(placement), survivalTime, tonumber(result and result.fastestEliminationTime))
  return record
end

local function clearLeaderboardForVehicle(inventoryId)
  local levelRecords = leaderboard[getCurrentLevelIdentifier()]
  if not levelRecords then return end
  levelRecords[tostring(inventoryId)] = nil
end

local function clearLeaderboardInventoriesBatchAtAllLevels(inventoryIds)
  if type(inventoryIds) ~= "table" or #inventoryIds == 0 then return end
  if not overhaul_career_career.isActive() then return end
  loadLeaderboard()
  for _, inventoryId in ipairs(inventoryIds) do
    local key = tostring(inventoryId or "")
    if key ~= "" then
      for _, levelRecords in pairs(leaderboard) do
        if type(levelRecords) == "table" then levelRecords[key] = nil end
      end
    end
  end
end

local function clearLeaderboardInventoryAtAllLevels(inventoryId)
  if not inventoryId or inventoryId == "" then return end
  clearLeaderboardInventoriesBatchAtAllLevels({ inventoryId })
end

local function getLeaderboardEntryAtLevel(levelId, inventoryId, raceLabel)
  if not levelId or levelId == "" or not inventoryId or not raceLabel then return {} end
  local records = leaderboard[levelId] and leaderboard[levelId][tostring(inventoryId)]
  if not records then return {} end
  return records[raceLabel] or {}
end

local function getLeaderboardEntry(inventoryId, raceLabel)
  return getLeaderboardEntryAtLevel(getCurrentLevelIdentifier(), inventoryId, raceLabel)
end

local function hasRecordedResult(record)
  return type(record) == "table"
    and (
      record.time
      or record.driftScore
      or record.topSpeed
      or record.pullDistance
      or (tonumber(record.demoRuns) or 0) > 0
    )
end

local function summarizeRecord(raceLabel, record)
  return {
    raceLabel = raceLabel,
    time = record.time,
    driftScore = record.driftScore,
    damagePercentage = record.damagePercentage,
    topSpeed = record.topSpeed,
    pullDistance = record.pullDistance,
    fullPull = record.fullPull == true,
    sledId = record.sledId,
    reward = record.reward,
    demoRuns = record.demoRuns,
    demoWins = record.demoWins,
    demoPodiums = record.demoPodiums,
    demoAveragePlacement = record.demoAveragePlacement,
    demoPodiumRate = record.demoPodiumRate,
    demoFastestEliminationTime = record.demoFastestEliminationTime,
    demoAverageSurvivalTime = record.demoAverageSurvivalTime,
    demoLongestSurvivalTime = record.demoLongestSurvivalTime,
  }
end

local function getLeaderboardEntriesForVehicle(inventoryId)
  local levelId = getCurrentLevelIdentifier()
  local records = levelId and leaderboard[levelId] and leaderboard[levelId][tostring(inventoryId)]
  if not records then return {} end
  local list = {}
  for raceLabel, record in pairs(records) do
    if hasRecordedResult(record) then list[#list + 1] = summarizeRecord(raceLabel, record) end
  end
  return list
end

-- Public API --------------------------------------------------------------------------------------

M.addLeaderboardEntry = addLeaderboardEntry
M.updateDemoDerbyStats = updateDemoDerbyStats
M.isBestTime = isBestTime
M.getLeaderboardEntry = getLeaderboardEntry
M.getLeaderboardEntryAtLevel = getLeaderboardEntryAtLevel
M.getLeaderboardEntriesForVehicle = getLeaderboardEntriesForVehicle
M.clearLeaderboardForVehicle = clearLeaderboardForVehicle
M.clearLeaderboardInventoryAtAllLevels = clearLeaderboardInventoryAtAllLevels
M.clearLeaderboardInventoriesBatchAtAllLevels = clearLeaderboardInventoriesBatchAtAllLevels

-- Game hooks --------------------------------------------------------------------------------------

M.onOverhaulVehicleRemoved = clearLeaderboardForVehicle

function M.onOverhaulActive(active)
  if active then
    loadLeaderboard()
  else
    leaderboard = {}
    leaderboardLoaded = false
  end
end

function M.onExtensionLoaded()
  if getCurrentLevelIdentifier() then loadLeaderboard() end
end

function M.onExtensionUnloaded()
  if saveFeature then
    saveFeature.dispose()
    saveFeature = nil
  end
end

function M.onWorldReadyState(worldReadyState)
  if worldReadyState == 2 then loadLeaderboard() end
end

function M.onOverhaulSaveCurrentProfile(currentSavePath)
  loadLeaderboard()
  saveLeaderboard(currentSavePath)
end

return M
