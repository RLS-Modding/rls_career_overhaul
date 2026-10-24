-- Owns challenge execution, saved progress and completion for one career.
-- Read config, state, catalog and editor parts, save handling, challenge actions, updates, lifecycle and public API in order.

-- Requires ----------------------------------------------------------------------------------------

local saveStore = require('overhaul/lib/save/store')
local challengeCatalog = require('overhaul/career/start/challengeCatalog')
local challengeEditor = require('overhaul/career/start/challengeEditor')
local M = {}

-- Save keys over the file this module writes (metadata only).
saveStore.registerKeys({
  {key = "rules.challengeModes", owner = "overhaul_career_challengeModes", files = {"career/rls_career/challengeModes.json"}, phase = "profile", required = true},
})

-- Config ------------------------------------------------------------------------------------------

local SAVE_FILE_SUFFIX = "/career/rls_career/challengeModes.json"
local SAVE_DIR_SUFFIX = "/career/rls_career"
local GENERAL_SAVE_FILE_SUFFIX = "/career/general.json"
local MPS_TO_MPH = 2.23694
local DEFAULT_UPDATE_SECONDS = 5
local DEFAULT_TARGET_MONEY = 1000000
local DEFAULT_LOAN_PAYMENTS = 12
local DEFAULT_LOAN_INTEREST = 0.10

-- State -------------------------------------------------------------------------------------------

local activeChallenge = nil
local completedChallengeData = nil
local updateTimer = 0

-- Helpers -----------------------------------------------------------------------------------------

local function getSeedEncoder()
  return require('overhaul/career/challengeModes/seed')
end

local function challengeFilePath(savePath)
  return savePath .. SAVE_FILE_SUFFIX
end

local function clearChallengeRuntime()
  activeChallenge = nil
  completedChallengeData = nil
  updateTimer = 0
end

-- Difficulty reads whether a challenge is running, so it is told whenever that changes.
local function notifyDifficultyMode(active)
  local difficultyMode = overhaul_career_economy_difficultyMode
  if difficultyMode then
    difficultyMode.onChallengeModeStateChanged(active)
  end
end

local function applyChallengeEconomy(economyAdjuster)
  overhaul_career_economyAdjuster.resetToDefaults()
  if economyAdjuster then
    overhaul_career_economyAdjuster.setAllTypeMultipliers(economyAdjuster)
  end
end

-- A new save has an empty general.json; anything else is a save with progress to restore.
local function isNewCareerSave(savePath)
  return tableIsEmpty(jsonReadFile(savePath .. GENERAL_SAVE_FILE_SUFFIX) or {})
end

-- Returns false when the lender refuses the loan, which stops the challenge from starting.
local function takeStartingLoan(challenge)
  local loanConfig = challenge.loans
  local loans = overhaul_career_economy_loans
  if not loanConfig or not loans then return true end
  if not (loanConfig.amount and loanConfig.amount > 0) then return true end

  loans.clearAllLoans()
  local result = loans.takeLoan("moneyGrabLogistics", loanConfig.amount, loanConfig.payments or DEFAULT_LOAN_PAYMENTS,
    loanConfig.interest or DEFAULT_LOAN_INTEREST, true)
  if not result or result.error then return false end
  return true
end

-- Moves the player's money to the challenge's starting capital.
local function applyStartingCapital(challenge)
  local attributes = overhaul_career_economy_playerAttributes
  if not (challenge.startingCapital and attributes) then return end
  -- Resetting capital in a cheat career would log the gap from $1T as spending.
  if overhaul_career_economy_cheats and overhaul_career_economy_cheats.isCheatsMode() then return end

  local currentMoney = attributes.getAttributeValue("money") or 0
  local targetMoney = challenge.startingCapital
  if currentMoney == targetMoney then return end
  attributes.addAttributes({money = targetMoney - currentMoney}, {
    label = "Challenge starting capital: " .. challenge.name,
    tags = {"startingFunds"}, finance = {category = "starting_funds", vehicleRelated = false},
  })
end

local function addStartingGarages(challenge)
  local garageIds = challenge.startingGarages
  if not (garageIds and type(garageIds) == "table" and #garageIds > 0) then return end
  local garageManager = overhaul_career_garage_garageManager
  if not garageManager then return end

  for _, garageId in ipairs(garageIds) do
    garageManager.addPurchasedGarage(garageId)
  end
end

-- Tracks the top speed while driving; walking is excluded, and the peak is kept between update ticks.
local function recordDrivingTopSpeed()
  local vehicleId = be:getPlayerVehicleID(0)
  if not vehicleId or vehicleId < 0 then return end

  local vx, vy, vz = be:getObjectVelocityXYZ(vehicleId)
  local speedMph = math.sqrt(vx * vx + vy * vy + vz * vz) * MPS_TO_MPH
  activeChallenge.maxSpeed = math.max(activeChallenge.maxSpeed or 0, speedMph)
end

-- The completion screen gets the challenge facts, its win-condition variables and the top speed reached.
local function buildCompletionData(winConditionInfo)
  local completed = {
    id = activeChallenge.id,
    name = activeChallenge.name,
    description = activeChallenge.description,
    winCondition = activeChallenge.winCondition,
    winConditionName = winConditionInfo.name,
    winConditionDescription = winConditionInfo.description,
    simulationTimeSpent = activeChallenge.simulationTimeSpent or 0,
    startingCapital = activeChallenge.startingCapital,
    loans = activeChallenge.loans,
  }
  for variableName in pairs(winConditionInfo.variables or {}) do
    if activeChallenge[variableName] ~= nil then
      completed[variableName] = activeChallenge[variableName]
    end
  end
  if activeChallenge.maxSpeed then
    completed.maxSpeed = activeChallenge.maxSpeed
  end
  return completed
end

-- Parts -------------------------------------------------------------------------------------------

-- The catalog and editor share one lookup: the catalog reads the editor's garage list through `parts`.
local parts = {}
parts.catalog = challengeCatalog.create({
  getActiveChallenge = function() return activeChallenge end,
  getAvailableGarages = function() return parts.editor.getAvailableGarages() end,
})
parts.editor = challengeEditor.create({getSeedEncoder = getSeedEncoder}, parts.catalog)

-- Save and load ----------------------------------------------------------------------------------

local function saveChallengeData(currentSavePath, writer)
  if not currentSavePath then
    return
  end

  local challengeData = {}
  if activeChallenge then
    challengeData.activeChallenge = deepcopy(activeChallenge)
    challengeData.activeChallenge.startedAt = activeChallenge.startedAt
  end

  local dirPath = currentSavePath .. SAVE_DIR_SUFFIX
  if not writer.exists(dirPath) then
    writer.mkdir(dirPath)
  end

  overhaul_career_saveSystem.jsonWriteFileSafe(challengeFilePath(currentSavePath), challengeData, true)
end

local function loadChallengeData(currentSavePath)
  if not currentSavePath then
    return
  end

  local filePath = challengeFilePath(currentSavePath)
  if not FS:fileExists(filePath) then
    return
  end

  local challengeData = jsonReadFile(filePath) or {}
  if not challengeData.activeChallenge then
    return
  end

  activeChallenge = deepcopy(challengeData.activeChallenge)
  notifyDifficultyMode(true)
  applyChallengeEconomy(activeChallenge.economyAdjuster)

  local winConditionInfo = parts.catalog.getWinConditionInfo(activeChallenge.winCondition)
  guihooks.trigger("challenge:started", {
    id = activeChallenge.id,
    name = activeChallenge.name,
    description = activeChallenge.description,
    winCondition = activeChallenge.winCondition,
    winConditionName = winConditionInfo.name,
    winConditionDescription = winConditionInfo.description,
    targetMoney = activeChallenge.winCondition == "reachTargetMoney" and (activeChallenge.targetMoney or DEFAULT_TARGET_MONEY) or nil,
  })
end

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  saveChallengeData(currentSavePath, writer)
end

-- Challenge start and end ------------------------------------------------------------------------

-- Starts a discovered challenge by id; returns false when it is unknown, invalid or its loan is refused.
local function startChallenge(challengeId)
  if not challengeId then
    return false
  end

  local challenge = parts.catalog.getDiscovered()[challengeId]
  if not challenge then
    return false
  end

  parts.catalog.applyVariableDefaults(challenge)
  if not parts.catalog.validateChallenge(challenge) then
    return false
  end
  if not takeStartingLoan(challenge) then
    return false
  end

  applyStartingCapital(challenge)
  addStartingGarages(challenge)

  activeChallenge = deepcopy(challenge)
  activeChallenge.startedAt = os.time()
  activeChallenge.simulationTimeSpent = 0
  notifyDifficultyMode(true)
  applyChallengeEconomy(challenge.economyAdjuster)

  guihooks.trigger("challenge:started", {
    id = challenge.id,
    name = challenge.name,
    description = challenge.description,
    winCondition = challenge.winCondition,
    simulationTimeSpent = 0,
  })
  return true
end

-- Clears the running challenge; the economy policy refuses to rebuild while one is active, so it is cleared first.
local function endChallenge()
  if not activeChallenge then
    return false
  end

  activeChallenge = nil
  overhaul_career_economyAdjuster.resetToDefaults()
  notifyDifficultyMode(false)

  -- The current profile path points to the last completed save.
  saveStore.request("challengeModes:endChallenge")
  return true
end

local function getActiveChallenge()
  if activeChallenge then
    local challengeCopy = deepcopy(activeChallenge)
    challengeCopy.simulationTimeSpent = (challengeCopy.simulationTimeSpent or 0)
    return challengeCopy
  end
  return nil
end

local function isChallengeActive()
  return activeChallenge ~= nil
end

-- The flag is saved with the active challenge, so a reload never gifts the starter vehicle twice.
local function markStarterVehicleGranted()
  if not activeChallenge then return false end
  activeChallenge.starterVehicleGranted = true
  return true
end

local function checkWinCondition()
  if not activeChallenge then
    return false
  end
  return parts.catalog.getWinConditionInfo(activeChallenge.winCondition).checkCondition()
end

-- Per-frame update -------------------------------------------------------------------------------

local function onUpdate(_, dtSim, dtRaw)
  if not activeChallenge then return end

  if activeChallenge.winCondition == "reachTargetSpeed" and not gameplay_walk.isWalking() then
    recordDrivingTopSpeed()
  end

  activeChallenge.simulationTimeSpent = (activeChallenge.simulationTimeSpent or 0) + (dtSim or 0)
  updateTimer = updateTimer + (dtRaw or 0)

  -- The win condition sets how often it is checked; five seconds by default.
  local winConditionInfo = parts.catalog.getWinConditionInfo(activeChallenge.winCondition)
  local updateFrequency = winConditionInfo.updateFrequency or DEFAULT_UPDATE_SECONDS
  if updateTimer < updateFrequency then
    return
  end
  updateTimer = 0

  if checkWinCondition() then
    completedChallengeData = buildCompletionData(winConditionInfo)
    extensions.ui_router.navigate("challenge-completed")
    endChallenge()
  end
end

-- Career lifecycle -------------------------------------------------------------------------------

local function onCareerActivated()
  local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
  if not currentSavePath then
    if not activeChallenge then clearChallengeRuntime() end
    return
  end

  if not isNewCareerSave(currentSavePath) then
    loadChallengeData(currentSavePath)
  elseif not activeChallenge then
    clearChallengeRuntime()
  end
end

local function onCareerDeactivated()
  local hadChallenge = activeChallenge ~= nil
  activeChallenge = nil
  if hadChallenge then
    overhaul_career_economyAdjuster.resetToDefaults()
    notifyDifficultyMode(false)
  end
  completedChallengeData = nil
  updateTimer = 0
end

local function onOverhaulActive(started)
  if started then
    onCareerActivated()
  else
    onCareerDeactivated()
  end
end

local function onExtensionLoaded()
  getSeedEncoder()
  parts.catalog.discoverChallenges()
end

-- Public API --------------------------------------------------------------------------------------

local function requestChallengeCompleteData()
  if completedChallengeData then
    guihooks.trigger("challengeCompleteData", completedChallengeData)
    completedChallengeData = nil
  end
end

M.addWinCondition = parts.catalog.addWinCondition
M.getWinConditions = parts.catalog.getWinConditions
M.startChallenge = startChallenge
M.getActiveChallenge = getActiveChallenge
M.isChallengeActive = isChallengeActive
M.markStarterVehicleGranted = markStarterVehicleGranted
M.discoverChallenges = parts.catalog.discoverChallenges
M.getChallengeEditorData = parts.editor.getChallengeEditorData
M.getChallengeDropdownData = parts.editor.getChallengeDropdownData
M.getChallengeDropdownDataLight = parts.editor.getChallengeDropdownDataLight
M.getChallengeListLight = parts.editor.getChallengeListLight
M.createChallengeFromUI = parts.editor.createChallengeFromUI
M.getChallengeOptionsForCareerCreation = parts.editor.getChallengeOptionsForCareerCreation
M.getSingleChallengeForUI = parts.editor.getSingleChallengeForUI
M.requestChallengeCompleteData = requestChallengeCompleteData
M.getChallengeSeeded = parts.editor.getChallengeSeeded
M.requestChallengeDataForEdit = parts.editor.requestChallengeDataForEdit
M.getChallengeDataForEdit = getChallengeDataForEdit
M.deleteChallenge = parts.editor.deleteChallenge
M.createChallengeFromSeedUI = parts.editor.createChallengeFromSeedUI
M.requestGenerateRandomSeed = parts.editor.requestGenerateRandomSeed
M.requestSeedEncode = parts.editor.requestSeedEncode
M.requestSeedDecode = parts.editor.requestSeedDecode
M.requestChallengeSeeded = parts.editor.requestChallengeSeeded
M.generateRandomChallengeData = parts.editor.generateRandomChallengeData
M.encodeChallengeDataToSeed = parts.editor.encodeChallengeDataToSeed
M.decodeSeedToChallengeData = parts.editor.decodeSeedToChallengeData
M.getAvailableGarages = parts.editor.getAvailableGarages

-- Game hooks --------------------------------------------------------------------------------------

M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate
M.onOverhaulActive = onOverhaulActive
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile

return M
