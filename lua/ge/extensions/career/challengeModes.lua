local M = {}

-- Manages challenge discovery, creation, and execution
-- Automatically finds challenges in the challenges/ folder structure

local discoveredChallenges = {}
local activeChallenge = nil
local completedChallengeData = nil

-- Challenge template
local challengeTemplate = {
  id = "",
  name = "",
  description = "",
  startingCapital = 10000,
  loans = nil,
  economyAdjuster = {},
  winCondition = "",
  targetMoney = 1000000, -- Default target for reachTargetMoney challenges
  category = "custom",
  createdBy = "",
  createdDate = "",
  version = "1.0",
  simulationTimeSpent = 0
}

-- Discovery Functions

local function findChallengeFiles(basePath, foundFiles)
  foundFiles = foundFiles or {}

  local jsonFiles = FS:findFiles(basePath, "*.json", 0, false)
  if jsonFiles then
    for _, jsonFile in ipairs(jsonFiles) do
      table.insert(foundFiles, jsonFile)
    end
  end

  local dirs = FS:findFiles(basePath, "*", 0, false, true)
  for _, dirPath in ipairs(dirs or {}) do
    local fullItemPath = basePath .. "/" .. (dirPath:match("([^/\\]+)$") or dirPath)
    if FS:directoryExists(fullItemPath) then
      findChallengeFiles(fullItemPath, foundFiles)
    end
  end

  return foundFiles
end

local function discoverChallenges()
  discoveredChallenges = {}

  local challengesPath = "challenges"

  if not FS:directoryExists(challengesPath) then
    return {}
  end

  local customPath = challengesPath .. "/custom"
  if not FS:directoryExists(customPath) then
    FS:directoryCreate(customPath)
  end

  local challengeFiles = findChallengeFiles(challengesPath)

  for _, jsonFile in ipairs(challengeFiles) do
    local challengeData = nil

    if jsonReadFile then
      challengeData = jsonReadFile(jsonFile)
    end

    if challengeData then
      local challengeId = jsonFile:match("([^/\\]+)%.json$")

      if challengeId then
        challengeData.id = challengeId
        challengeData.filePath = jsonFile

        discoveredChallenges[challengeId] = challengeData
      end
    end
  end

  return discoveredChallenges
end

-- Validation Functions

local function validateChallenge(challengeData)
  if not challengeData or type(challengeData) ~= "table" then
    return false, "Invalid challenge data"
  end

  if not challengeData.id or type(challengeData.id) ~= "string" then
    return false, "Challenge must have a valid ID"
  end

  if not challengeData.name or type(challengeData.name) ~= "string" then
    return false, "Challenge must have a name"
  end

  if not challengeData.winCondition or type(challengeData.winCondition) ~= "string" then
    return false, "Challenge must have a win condition"
  end

  if challengeData.startingCapital and type(challengeData.startingCapital) ~= "number" then
    return false, "Starting capital must be a number"
  end

  if challengeData.loans then
    if type(challengeData.loans) ~= "table" then
      return false, "Loans must be a table"
    end
    if challengeData.loans.amount and type(challengeData.loans.amount) ~= "number" then
      return false, "Loan amount must be a number"
    end
    if challengeData.loans.interest and type(challengeData.loans.interest) ~= "number" then
      return false, "Loan interest must be a number"
    end
    if challengeData.loans.payments and type(challengeData.loans.payments) ~= "number" then
      return false, "Loan payments must be a number"
    end
  end

  if challengeData.economyAdjuster and type(challengeData.economyAdjuster) ~= "table" then
    return false, "Economy adjuster must be a table"
  end

  if challengeData.winCondition == "reachTargetMoney" then
    if challengeData.targetMoney and type(challengeData.targetMoney) ~= "number" then
      return false, "Target money must be a number"
    end
    if challengeData.targetMoney and challengeData.targetMoney <= 0 then
      return false, "Target money must be greater than 0"
    end
  end

  return true, "Valid"
end

-- UI Integration

local function getActivityTypeInfo(activityType)
  local typeInfo = {
    id = activityType,
    name = activityType,
    category = "Other"
  }

  if string.match(activityType, "^taxi") then
    typeInfo.category = "Transport"
    if activityType == "taxi" then
      typeInfo.name = "Taxi Service"
    else
      typeInfo.name = "Taxi - " .. string.sub(activityType, 6):gsub("^%l", string.upper)
    end
  elseif string.match(activityType, "^repo") then
    typeInfo.category = "Transport"
    typeInfo.name = "Vehicle Repossession"
  elseif string.match(activityType, "^delivery_") then
    typeInfo.category = "Delivery"
    local deliveryType = string.sub(activityType, 10)
    typeInfo.name = "Delivery - " .. deliveryType:gsub("^%l", string.upper)
  elseif string.match(activityType, "^rally") then
    typeInfo.category = "Racing"
    typeInfo.name = "Rally Racing"
  elseif string.match(activityType, "^drift") then
    typeInfo.category = "Racing"
    typeInfo.name = "Drift Racing"
  elseif string.match(activityType, "^motorsport") then
    typeInfo.category = "Racing"
    typeInfo.name = "Motorsport"
  elseif string.match(activityType, "^offroad") then
    typeInfo.category = "Racing"
    typeInfo.name = "Offroad Racing"
  elseif string.match(activityType, "^freeroam") then
    typeInfo.category = "Activity"
    typeInfo.name = "Freeroam Activities"
  end

  return typeInfo
end

local function getWinConditionInfo(winConditionId)
  local winConditions = {
    {
      id = "payOffLoan",
      name = "Pay Off Loan",
      description = "Complete the challenge by paying off all loans"
    },
    {
      id = "reachTargetMoney",
      name = "Reach Target Money",
      description = "Complete the challenge by reaching a target amount of money"
    }
  }

  for _, condition in ipairs(winConditions) do
    if condition.id == winConditionId then
      return condition
    end
  end

  return {
    id = winConditionId,
    name = winConditionId,
    description = "Unknown win condition"
  }
end

local function getChallengeEditorData()
  local activityTypes = {}

  local currentMultipliers = {}
  if career_economyAdjuster then
    local availableTypes = career_economyAdjuster.getAvailableTypes()
    if availableTypes and type(availableTypes) == "table" then
      for _, activityType in ipairs(availableTypes) do
        local activityInfo = getActivityTypeInfo(activityType)
        local currentMultiplier = career_economyAdjuster.getSectionMultiplier and
                                    career_economyAdjuster.getSectionMultiplier(activityType) or 1.0
        activityInfo.currentMultiplier = currentMultiplier
        table.insert(activityTypes, activityInfo)
        currentMultipliers[activityType] = currentMultiplier
      end
    end
  end

  local activityTypesBySource = {}
  if career_economyAdjuster and career_economyAdjuster.getTypesBySource then
    local typesBySource = career_economyAdjuster.getTypesBySource()
    if typesBySource then
      for sourceName, types in pairs(typesBySource) do
        activityTypesBySource[sourceName] = {}
        for _, activityType in ipairs(types) do
          local activityInfo = getActivityTypeInfo(activityType)
          local currentMultiplier = career_economyAdjuster.getSectionMultiplier and
                                      career_economyAdjuster.getSectionMultiplier(activityType) or 1.0
          activityInfo.currentMultiplier = currentMultiplier
          table.insert(activityTypesBySource[sourceName], activityInfo)
        end
      end
    end
  end

  return {
    winConditions = {
      {
        id = "payOffLoan",
        name = "Pay Off Loan",
        description = "Complete the challenge by paying off all loans"
      },
      {
        id = "reachTargetMoney",
        name = "Reach Target Money",
        description = "Complete the challenge by reaching a target amount of money"
      }
    },
    activityTypes = activityTypes,
    activityTypesBySource = activityTypesBySource,
    currentMultipliers = currentMultipliers,
    loanTerms = {6, 12, 18, 24, 36, 48, 60},
    defaults = {
      startingCapital = 10000,
      loanAmount = 50000,
      loanInterest = 0.10,
      loanPayments = 12,
      targetMoney = 1000000
    },
    stats = {
      totalActivityTypes = #activityTypes,
      activitySources = (function(tbl)
        if not tbl or type(tbl) ~= "table" then return 0 end
        local count = 0
        for _ in pairs(tbl) do count = count + 1 end
        return count
      end)(activityTypesBySource)
    }
  }
end

local function createChallengeFromUI(challengeData)
  if not challengeData or not challengeData.id or not challengeData.name then
    return false, "Challenge must have a valid ID and name", nil
  end

  local valid, message = validateChallenge(challengeData)
  if not valid then
    return false, message, nil
  end

  local customPath = "challenges/custom"
  if not FS:directoryExists(customPath) then
    FS:directoryCreate(customPath)
  end

  local newChallenge = deepcopy(challengeTemplate)
  for k, v in pairs(challengeData) do
    newChallenge[k] = v
  end

  newChallenge.category = "custom"
  newChallenge.createdBy = "player"
  newChallenge.createdDate = os.date("%Y-%m-%d %H:%M:%S")
  newChallenge.version = "1.0"

  local filePath = customPath .. "/" .. challengeData.id .. ".json"
  local success = jsonWriteFile(filePath, newChallenge, true)

  if success then
    discoverChallenges()
    return true, "Challenge created successfully", challengeData.id
  else
    return false, "Failed to save challenge file", nil
  end
end

-- Challenge Execution & Management

local function saveChallengeData(currentSavePath)
  if not currentSavePath then
    return
  end

  local challengeData = {}
  if activeChallenge then
    challengeData.activeChallenge = deepcopy(activeChallenge)
    challengeData.activeChallenge.startedAt = activeChallenge.startedAt
  end

  local filePath = currentSavePath .. "/career/rls_career/challengeModes.json"
  local dirPath = currentSavePath .. "/career/rls_career"

  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end

  career_saveSystem.jsonWriteFileSafe(filePath, challengeData, true)
end

local function loadChallengeData(currentSavePath)
  if not currentSavePath then
    return
  end

  local filePath = currentSavePath .. "/career/rls_career/challengeModes.json"
  local challengeData = jsonReadFile(filePath) or {}

  if challengeData.activeChallenge then
    activeChallenge = deepcopy(challengeData.activeChallenge)

    if activeChallenge.economyAdjuster and career_economyAdjuster then
      career_economyAdjuster.setAllTypeMultipliers(activeChallenge.economyAdjuster)
    end

    if guihooks and guihooks.trigger then
      local winConditionInfo = getWinConditionInfo(activeChallenge.winCondition)
      guihooks.trigger('challenge:started', {
        id = activeChallenge.id,
        name = activeChallenge.name,
        description = activeChallenge.description,
        winCondition = activeChallenge.winCondition,
        winConditionName = winConditionInfo.name,
        winConditionDescription = winConditionInfo.description,
        targetMoney = activeChallenge.winCondition == "reachTargetMoney" and (activeChallenge.targetMoney or 1000000) or nil
      })
    end
  end
end

local function endChallenge()
  if not activeChallenge then
    return false
  end

  if career_economyAdjuster then
    career_economyAdjuster.resetToDefaults()
  end

  local endedChallenge = deepcopy(activeChallenge)
  activeChallenge = nil

  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if currentSavePath then
    saveChallengeData(currentSavePath)
  end

  career_saveSystem.saveCurrent()
  return true
end

local function onSaveCurrentSaveSlot(currentSavePath)
  saveChallengeData(currentSavePath)
end

local function onCareerActivated()
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if currentSavePath then
    loadChallengeData(currentSavePath)
  end
end

local function onCareerDeactivated()
  if activeChallenge then
    endChallenge()
  end
end

local function onExtensionLoaded()
  discoverChallenges()
end

-- Start a challenge by ID
local function startChallenge(challengeId)
  if not challengeId then
    return false
  end

  local challenge = discoveredChallenges[challengeId]
  if not challenge then
    return false
  end

  local valid, message = validateChallenge(challenge)
  if not valid then
    return false
  end

  if challenge.startingCapital and career_modules_playerAttributes then
    local currentMoney = career_modules_playerAttributes.getAttributeValue('money') or 0
    local targetMoney = challenge.startingCapital

    if currentMoney ~= targetMoney then
      local difference = targetMoney - currentMoney
      career_modules_playerAttributes.addAttributes({
        money = difference
      }, {
        label = "Challenge starting capital: " .. challenge.name
      })
    end
  end

  if challenge.loans and career_modules_loans then
    local loanConfig = challenge.loans
    if loanConfig.amount and loanConfig.amount > 0 then
      if career_modules_loans.clearAllLoans then
        career_modules_loans.clearAllLoans()
      end

      local result = career_modules_loans.takeLoan("moneyGrabLogistics", loanConfig.amount, loanConfig.payments or 12,
        loanConfig.interest or 0.10, true)

      if not result or result.error then
        return false
      end
    end
  end

  if challenge.economyAdjuster and career_economyAdjuster then
    career_economyAdjuster.setAllTypeMultipliers(challenge.economyAdjuster)
  end

  activeChallenge = deepcopy(challenge)
  activeChallenge.startedAt = os.time()
  activeChallenge.simulationTimeSpent = 0

  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if currentSavePath then
    saveChallengeData(currentSavePath)
  end

  if guihooks and guihooks.trigger then
    guihooks.trigger('challenge:started', {
      id = challenge.id,
      name = challenge.name,
      description = challenge.description,
      winCondition = challenge.winCondition,
      simulationTimeSpent = 0
    })
  end

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

local function checkWinCondition()
  if not activeChallenge then
    return false
  end

  local winCondition = activeChallenge.winCondition

  if winCondition == "payOffLoan" then
    if career_modules_loans then
      local activeLoans = career_modules_loans.getActiveLoans()
      return #activeLoans == 0
    end
    return false

  elseif winCondition == "reachTargetMoney" then
    if career_modules_playerAttributes then
      local currentMoney = career_modules_playerAttributes.getAttributeValue('money') or 0
      local targetMoney = activeChallenge.targetMoney or 1000000
      return currentMoney >= targetMoney
    end
    return false
  end

  return false
end

local updateTimer = 0
local function onUpdate(dtReal, dtSim, dtRaw)
  if activeChallenge then
    activeChallenge.simulationTimeSpent = (activeChallenge.simulationTimeSpent or 0) + (dtSim or 0)
  end

  updateTimer = updateTimer + dtRaw
  if updateTimer < 5 then
    return
  end
  updateTimer = 0

  if activeChallenge and checkWinCondition() then
    local winConditionInfo = getWinConditionInfo(activeChallenge.winCondition)
    
    completedChallengeData = {
      id = activeChallenge.id,
      name = activeChallenge.name,
      description = activeChallenge.description,
      winCondition = activeChallenge.winCondition,
      winConditionName = winConditionInfo.name,
      winConditionDescription = winConditionInfo.description,
      targetMoney = activeChallenge.winCondition == "reachTargetMoney" and (activeChallenge.targetMoney or 1000000) or nil,
      simulationTimeSpent = activeChallenge.simulationTimeSpent or 0,
      startingCapital = activeChallenge.startingCapital,
      loans = activeChallenge.loans
    }
    
    if guihooks and guihooks.trigger then
      guihooks.trigger('ChangeState', {state = 'challenge-completed'})
    end

    endChallenge()
  end
end

local function requestChallengeCompleteData()
  if completedChallengeData and guihooks and guihooks.trigger then
    guihooks.trigger('challengeCompleteData', completedChallengeData)
    completedChallengeData = nil
  end
end

-- Career Creation Integration

local function getChallengeOptionsForCareerCreation()
  local options = {}

  for challengeId, challenge in pairs(discoveredChallenges) do
    local winConditionInfo = getWinConditionInfo(challenge.winCondition)

    local currentMultipliers = {}
    local allActivityTypes = {}
    if career_economyAdjuster then
      local availableTypes = career_economyAdjuster.getAvailableTypes()
      if availableTypes and type(availableTypes) == "table" then
        for _, activityType in ipairs(availableTypes) do
          local activityInfo = getActivityTypeInfo(activityType)
          local currentMultiplier = career_economyAdjuster.getSectionMultiplier and
                                      career_economyAdjuster.getSectionMultiplier(activityType) or 1.0
          activityInfo.currentMultiplier = currentMultiplier
          table.insert(allActivityTypes, activityInfo)
          currentMultipliers[activityType] = currentMultiplier
        end
      end
    end

    table.insert(options, {
      id = challenge.id,
      name = challenge.name,
      description = challenge.description or "",
      category = challenge.category or "",
      startingCapital = challenge.startingCapital or 10000,
      hasLoans = challenge.loans ~= nil,
      loanAmount = challenge.loans and challenge.loans.amount or 0,
      loanInterest = challenge.loans and challenge.loans.interest or nil,
      loanPayments = challenge.loans and challenge.loans.payments or nil,
      winCondition = challenge.winCondition,
      winConditionName = winConditionInfo.name,
      winConditionDescription = winConditionInfo.description,
      targetMoney = challenge.winCondition == "reachTargetMoney" and (challenge.targetMoney or 1000000) or nil,
      economyAdjuster = challenge.economyAdjuster or {},
      allActivityTypes = allActivityTypes,
      currentMultipliers = currentMultipliers,
      isBaseGame = challenge.isBaseGame or false,
      simulationTimeSpent = challenge.simulationTimeSpent or 0
    })
  end

  table.sort(options, function(a, b)
    local ac = tostring((a and a.category) or "")
    local bc = tostring((b and b.category) or "")
    if ac ~= bc then return ac < bc end
    local an = tostring((a and a.name) or "")
    local bn = tostring((b and b.name) or "")
    return an < bn
  end)

  return options
end

-- Module Exports
M.startChallenge = startChallenge
M.getActiveChallenge = getActiveChallenge
M.isChallengeActive = isChallengeActive
M.discoverChallenges = discoverChallenges
M.getChallengeEditorData = getChallengeEditorData
M.createChallengeFromUI = createChallengeFromUI
M.getChallengeOptionsForCareerCreation = getChallengeOptionsForCareerCreation
M.requestChallengeCompleteData = requestChallengeCompleteData

M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate
M.onCareerActive = function(started)
  if started then
    onCareerActivated()
  else
    onCareerDeactivated()
  end
end
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

return M