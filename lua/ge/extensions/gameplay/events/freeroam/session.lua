local M = {}

M.timerActive = false
M.mActiveRace = nil
M.staged = nil
M.in_race_time = 0
M.speedUnit = 2.2369362921
M.lapCount = 0
M.currCheckpoint = nil
M.mHotlap = nil
M.mAltRoute = nil
M.mCurrentRouteName = nil
M.mSplitTimes = {}
M.isLoop = false
M.checkpointsHit = 0
M.totalCheckpoints = 0
M.currentExpectedCheckpoint = 1
M.invalidLap = false
M.initialVehicleDamage = 0
M.mInventoryId = nil
M.newBestSession = false
M.maxSpeed = 0
M.mTotalRaceTime = 0
M.mBestLapThisRun = nil
M.mSuppressOffRoadExitUntil = 0
M.races = nil
M.isReplay = false
M.previousGameState = nil
M.saveGameState = false
M.mPendingTrackResult = nil
M.dragPracticeActive = false
M.dragPracticeFlow = false
M.freeroamPracticeStaging = false

function M.resetState()
  M.timerActive = false
  M.mActiveRace = nil
  M.staged = nil
  M.in_race_time = 0
  M.speedUnit = 2.2369362921
  M.lapCount = 0
  M.currCheckpoint = nil
  M.mHotlap = nil
  M.mAltRoute = nil
  M.mCurrentRouteName = nil
  M.mSplitTimes = {}
  M.isLoop = false
  M.checkpointsHit = 0
  M.totalCheckpoints = 0
  M.currentExpectedCheckpoint = 1
  M.invalidLap = false
  M.initialVehicleDamage = 0
  M.mInventoryId = nil
  M.newBestSession = false
  M.maxSpeed = 0
  M.mTotalRaceTime = 0
  M.mBestLapThisRun = nil
  M.mSuppressOffRoadExitUntil = 0
  M.races = nil
  M.isReplay = false
  M.previousGameState = nil
  M.saveGameState = false
  M.mPendingTrackResult = nil
  M.dragPracticeActive = false
  M.dragPracticeFlow = false
  M.freeroamPracticeStaging = false
end

local function onExtensionLoaded()
end

M.onExtensionLoaded = onExtensionLoaded

return M
