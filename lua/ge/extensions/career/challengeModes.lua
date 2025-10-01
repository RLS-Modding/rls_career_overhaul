local M = {}

-- ================================
-- CHALLENGE MODES MODULE
-- ================================
-- Manages challenge discovery, creation, and execution
-- Automatically finds challenges in the challenges/ folder structure

-- ================================
-- UTILITY FUNCTIONS
-- ================================



-- Deep copy a table
local function deepcopy(original)
  local copy = {}
  for k, v in pairs(original) do
    if type(v) == "table" then
      copy[k] = deepcopy(v)
    else
      copy[k] = v
    end
  end
  return copy
end

-- (removed) formatSimulationTime

-- ================================
-- DATA STRUCTURES
-- ================================

-- Challenge storage
local discoveredChallenges = {}
local activeChallenge = nil

-- (removed) simulationTimeAccumulator

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
  simulationTimeSpent = 0 -- Total simulation time spent on this challenge
}

-- ================================
-- DISCOVERY FUNCTIONS
-- ================================

-- Recursive function to find all challenge files (similar to requiredMods approach)
local function findChallengeFiles(basePath, foundFiles)
  foundFiles = foundFiles or {}

  -- Find all .json files in current directory
  local jsonFiles = FS:findFiles(basePath, "*.json", 0, false)
  if jsonFiles then
    for _, jsonFile in ipairs(jsonFiles) do
      table.insert(foundFiles, jsonFile)
    end
  end

  -- Recursively traverse subdirectories
  local dirs = FS:findFiles(basePath, "*", 0, false, true)
  for _, dirPath in ipairs(dirs or {}) do
    local fullItemPath = basePath .. "/" .. (dirPath:match("([^/\\]+)$") or dirPath)
    if FS:directoryExists(fullItemPath) then
      findChallengeFiles(fullItemPath, foundFiles)
    end
  end

  return foundFiles
end

-- Discover all challenges from the challenges folder
local function discoverChallenges()
  discoveredChallenges = {}

  local challengesPath = "challenges"

  -- Check if challenges directory exists
  if not FS:directoryExists(challengesPath) then
    return {}
  end

  -- Ensure custom directory exists
  local customPath = challengesPath .. "/custom"
  if not FS:directoryExists(customPath) then
    FS:directoryCreate(customPath)
  end

  -- Find all challenge files using recursive approach like requiredMods
  local challengeFiles = findChallengeFiles(challengesPath)
  
  -- Process all found challenge files
  for _, jsonFile in ipairs(challengeFiles) do
    -- Try multiple ways to read JSON files
    local challengeData = nil

    -- First try global jsonReadFile (BeamNG specific)
    if jsonReadFile then
      challengeData = jsonReadFile(jsonFile)
    end

    if challengeData then
      -- Extract filename without extension for challenge ID
      local challengeId = jsonFile:match("([^/\\]+)%.json$")

      if challengeId then
        -- Add metadata
        challengeData.id = challengeId
        challengeData.filePath = jsonFile

        -- Add to discovered challenges
        discoveredChallenges[challengeId] = challengeData
      end
    end
  end

  return discoveredChallenges
end

-- Get a specific challenge by ID
local function getChallengeById(challengeId)
  if not challengeId then
    return nil
  end

  -- First check if it exists in discovered challenges
  if discoveredChallenges[challengeId] then
    return deepcopy(discoveredChallenges[challengeId])
  end

  return nil
end

-- Create custom challenge
local function createCustomChallenge(challengeData)
  if not challengeData or not challengeData.id or not challengeData.name then
    return false, nil
  end

  -- Ensure custom directory exists
  local customPath = "challenges/custom"
  if not FS:directoryExists(customPath) then
    FS:directoryCreate(customPath)
  end

  -- Set metadata
  local customChallenge = deepcopy(challengeTemplate)
  for k, v in pairs(challengeData) do
    customChallenge[k] = v
  end

  customChallenge.category = "custom"
  customChallenge.createdBy = "player"
  customChallenge.createdDate = os.date("%Y-%m-%d %H:%M:%S")

  -- Save the challenge file
  local filePath = customPath .. "/" .. challengeData.id .. ".json"
  local success = jsonWriteFile(filePath, customChallenge, true)

  if success then
    -- Add to discovered challenges
    discoveredChallenges[challengeData.id] = customChallenge
    return true, customChallenge
  else
    return false, "Failed to save challenge file"
  end
end

-- Delete custom challenge
local function deleteCustomChallenge(challengeId)
  if not challengeId then
    return false
  end

  local challenge = discoveredChallenges[challengeId]
  if not challenge or challenge.category ~= "custom" then
    return false
  end

  -- Delete the file
  if FS:fileExists(challenge.filePath) then
    FS:removeFile(challenge.filePath)
    -- Refresh challenges
    discoverChallenges()
    return true
  end

  return false
end

-- VALIDATION FUNCTIONS

-- Validate challenge data structure
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

  -- Validate starting capital
  if challengeData.startingCapital and type(challengeData.startingCapital) ~= "number" then
    return false, "Starting capital must be a number"
  end

  -- Validate loans structure
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

  -- Validate economy adjuster
  if challengeData.economyAdjuster and type(challengeData.economyAdjuster) ~= "table" then
    return false, "Economy adjuster must be a table"
  end

  -- Validate target money (only required for reachTargetMoney win condition)
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

-- UI INTEGRATION FUNCTIONS

-- Get activity type display information
local function getActivityTypeInfo(activityType)
  local typeInfo = {
    id = activityType,
    name = activityType,
    category = "Other"
  }

  -- Categorize based on type prefix
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

-- Get win condition display information
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

  -- Return default if not found
  return {
    id = winConditionId,
    name = winConditionId,
    description = "Unknown win condition"
  }
end

-- Get all available challenge templates and configurations for UI
local function getChallengeEditorData()
  local activityTypes = {}

  -- Get activity types and current multipliers from economy adjuster if available
  local currentMultipliers = {}
  if career_economyAdjuster then
    local availableTypes = career_economyAdjuster.getAvailableTypes()
    if availableTypes and type(availableTypes) == "table" then
      for _, activityType in ipairs(availableTypes) do
        local activityInfo = getActivityTypeInfo(activityType)
        -- Get current multiplier (default to 1.0 if not adjusted)
        local currentMultiplier = career_economyAdjuster.getSectionMultiplier and
                                    career_economyAdjuster.getSectionMultiplier(activityType) or 1.0
        activityInfo.currentMultiplier = currentMultiplier
        table.insert(activityTypes, activityInfo)
        currentMultipliers[activityType] = currentMultiplier
      end
    end
  end


  -- Get activity types grouped by source for better UI organization
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
    currentMultipliers = currentMultipliers, -- All current multiplier values (including unmodified at 1.0)
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
        if not tbl or type(tbl) ~= "table" then
          return 0
        end
        local count = 0
        for _ in pairs(tbl) do
          count = count + 1
        end
        return count
      end)(activityTypesBySource)
    }
  }
end

-- Create a new challenge from UI data
local function createChallengeFromUI(challengeData)
  if not challengeData or not challengeData.id or not challengeData.name then
    return false, "Challenge must have a valid ID and name", nil
  end

  -- Validate the challenge data
  local valid, message = validateChallenge(challengeData)
  if not valid then
    return false, message, nil
  end

  -- Ensure custom directory exists
  local customPath = "challenges/custom"
    if not FS:directoryExists(customPath) then
      FS:directoryCreate(customPath)
    end

  -- Create challenge with metadata
  local newChallenge = deepcopy(challengeTemplate)
  for k, v in pairs(challengeData) do
    newChallenge[k] = v
  end

  newChallenge.category = "custom"
  newChallenge.createdBy = "player"
  newChallenge.createdDate = os.date("%Y-%m-%d %H:%M:%S")
  newChallenge.version = "1.0"

  -- Save to custom folder
  local filePath = customPath .. "/" .. challengeData.id .. ".json"
  local success = jsonWriteFile(filePath, newChallenge, true)

  if success then
    discoverChallenges() -- Refresh challenges
    -- Return success, message, and the challenge ID
    return true, "Challenge created successfully", challengeData.id
  else
    return false, "Failed to save challenge file", nil
      end
    end

-- Update an existing custom challenge
local function updateCustomChallenge(challengeId, challengeData)
  if not challengeId then
    return false, "No challenge ID provided", nil
  end

  local existingChallenge = discoveredChallenges[challengeId]
  if not existingChallenge or existingChallenge.category ~= "custom" then
    return false, "Can only update custom challenges", nil
  end

  -- Validate the updated data
  local valid, message = validateChallenge(challengeData)
  if not valid then
    return false, message, nil
  end

  -- Merge with existing challenge data
  local updatedChallenge = deepcopy(existingChallenge)
  for k, v in pairs(challengeData) do
    updatedChallenge[k] = v
  end

  updatedChallenge.modifiedDate = os.date("%Y-%m-%d %H:%M:%S")
  updatedChallenge.version = tostring(tonumber(updatedChallenge.version or "1.0") + 0.1)

  -- Save the updated challenge
  local filePath = existingChallenge.filePath
  local success = jsonWriteFile(filePath, updatedChallenge, true)

  if success then
    discoverChallenges() -- Refresh challenges
    return true, "Challenge updated successfully", challengeId
  else
    return false, "Failed to save updated challenge", nil
  end
end

-- Get challenge data for editing in UI
local function getChallengeForEditing(challengeId)
  if not challengeId then
    return nil
  end

  local challenge = discoveredChallenges[challengeId]
  if not challenge then
    return nil
  end

  -- Get win condition info
  local winConditionInfo = getWinConditionInfo(challenge.winCondition)

  -- Get current multipliers for all available activity types
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


  -- Check if this is the active challenge to include current simulation time
  local simulationTimeSpent = challenge.simulationTimeSpent or 0
  if activeChallenge and activeChallenge.id == challenge.id then
    simulationTimeSpent = activeChallenge.simulationTimeSpent or 0
  end

  -- Return editable data (without internal metadata)
  return {
    id = challenge.id,
    name = challenge.name,
    description = challenge.description or "",
    startingCapital = challenge.startingCapital or 10000,
    loans = challenge.loans and deepcopy(challenge.loans) or nil,
    economyAdjuster = challenge.economyAdjuster and deepcopy(challenge.economyAdjuster) or {},
    winCondition = challenge.winCondition,
    winConditionName = winConditionInfo.name,
    winConditionDescription = winConditionInfo.description,
    targetMoney = challenge.winCondition == "reachTargetMoney" and (challenge.targetMoney or 1000000) or nil,
    allActivityTypes = allActivityTypes, -- All available activity types with current multipliers
    currentMultipliers = currentMultipliers, -- All current multiplier values
    isEditable = challenge.category == "custom",
    category = challenge.category,
    createdBy = challenge.createdBy,
    createdDate = challenge.createdDate,
    modifiedDate = challenge.modifiedDate,
    version = challenge.version,
    simulationTimeSpent = simulationTimeSpent
  }
end

-- Get challenge summary for UI
local function getChallengeSummary(challengeId)
  if not challengeId then
    return nil
  end

  local challenge = discoveredChallenges[challengeId]
  if not challenge then
    return nil
  end

  -- Get win condition info
  local winConditionInfo = getWinConditionInfo(challenge.winCondition)

  -- Check if this is the active challenge to include current simulation time
  local simulationTimeSpent = challenge.simulationTimeSpent or 0
  if activeChallenge and activeChallenge.id == challengeId then
    simulationTimeSpent = activeChallenge.simulationTimeSpent or 0
  end

  return {
    id = challenge.id,
    name = challenge.name,
    description = challenge.description or "",
    category = challenge.category,
    winCondition = challenge.winCondition,
    winConditionName = winConditionInfo.name,
    winConditionDescription = winConditionInfo.description,
    targetMoney = challenge.winCondition == "reachTargetMoney" and (challenge.targetMoney or 1000000) or nil,
    startingCapital = challenge.startingCapital or 10000,
    hasLoans = challenge.loans ~= nil,
    loanAmount = challenge.loans and challenge.loans.amount or 0,
    isBaseGame = challenge.isBaseGame or false,
    createdBy = challenge.createdBy or "",
    createdDate = challenge.createdDate or "",
    simulationTimeSpent = simulationTimeSpent
  }
end

-- CHALLENGE EXECUTION & MANAGEMENT

-- Save active challenge to career save
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

-- Load active challenge from career save
local function loadChallengeData(currentSavePath)
  if not currentSavePath then
    return
  end

  local filePath = currentSavePath .. "/career/rls_career/challengeModes.json"
  local challengeData = jsonReadFile(filePath) or {}

  if challengeData.activeChallenge then
    activeChallenge = deepcopy(challengeData.activeChallenge)

    -- Reapply challenge settings
    if activeChallenge.economyAdjuster and career_economyAdjuster then
      career_economyAdjuster.setAllTypeMultipliers(activeChallenge.economyAdjuster)
    end

    -- Trigger UI update
    if guihooks and guihooks.trigger then
      local winConditionInfo = getWinConditionInfo(activeChallenge.winCondition)
      guihooks.trigger('challenge:started', {
        id = activeChallenge.id,
        name = activeChallenge.name,
        description = activeChallenge.description,
        winCondition = activeChallenge.winCondition,
        winConditionName = winConditionInfo.name,
        winConditionDescription = winConditionInfo.description,
        targetMoney = activeChallenge.winCondition == "reachTargetMoney" and (activeChallenge.targetMoney or 1000000) or
          nil
      })
    end
            end
          end

-- End the current challenge
local function endChallenge()
  if not activeChallenge then
    return false
  end

  -- Reset economy adjuster to defaults
  if career_economyAdjuster then
    career_economyAdjuster.resetToDefaults()
  end

  -- Clear active challenge
  local endedChallenge = deepcopy(activeChallenge)
  activeChallenge = nil

  -- Save updated data (no active challenge)
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if currentSavePath then
    saveChallengeData(currentSavePath)
  end

  -- Trigger UI update
  if guihooks and guihooks.trigger then
    local winConditionInfo = getWinConditionInfo(endedChallenge.winCondition)
    guihooks.trigger('challenge:ended', {
      id = endedChallenge.id,
      name = endedChallenge.name,
      winCondition = endedChallenge.winCondition,
      winConditionName = winConditionInfo.name,
      winConditionDescription = winConditionInfo.description,
      targetMoney = endedChallenge.winCondition == "reachTargetMoney" and (endedChallenge.targetMoney or 1000000) or nil,
      simulationTimeSpent = endedChallenge.simulationTimeSpent or 0
    })
  end

  return true
end

-- Hook into career save system
local function onSaveCurrentSaveSlot(currentSavePath)
  saveChallengeData(currentSavePath)
end

-- Hook into career activation
local function onCareerActivated()
  -- Load challenge data when career is activated
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if currentSavePath then
    loadChallengeData(currentSavePath)
  end
end

-- Hook into career deactivation
local function onCareerDeactivated()
  -- End any active challenge when career is deactivated
  if activeChallenge then
    endChallenge()
  end
end

local function onExtensionLoaded()
  discoverChallenges()
end

-- Force refresh challenges (useful after creating new ones)
local function refreshChallenges()
  return discoverChallenges()
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

  -- Validate the challenge
  local valid, message = validateChallenge(challenge)
  if not valid then
    return false
  end

  if challenge.loans and career_modules_loans then
    local loanConfig = challenge.loans
    if loanConfig.amount and loanConfig.amount > 0 then
      -- Clear any existing loans before taking the challenge loan
      -- This prevents loan accumulation across saves/challenges
      if career_modules_loans.clearAllLoans then
        career_modules_loans.clearAllLoans()
      end

      local result = career_modules_loans.takeLoan("moneyGrabLogistics", loanConfig.amount, loanConfig.payments or 12,
        loanConfig.interest or 0.10, true)

      dump(result)

      if not result or result.error then
        return false
      end
    end
  end

  -- Set starting capital if specified
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

  -- Apply economy adjuster if specified
  if challenge.economyAdjuster and career_economyAdjuster then
    career_economyAdjuster.setAllTypeMultipliers(challenge.economyAdjuster)
  end

  -- Take loan if specified

  -- Set as active challenge
  activeChallenge = deepcopy(challenge)
  activeChallenge.startedAt = os.time()
  activeChallenge.simulationTimeSpent = 0

  -- Save challenge data immediately
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if currentSavePath then
    saveChallengeData(currentSavePath)
  end

  -- Trigger UI update
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

-- Get currently active challenge
local function getActiveChallenge()
  if activeChallenge then
    local challengeCopy = deepcopy(activeChallenge)
    -- Include current accumulated simulation time
    challengeCopy.simulationTimeSpent = (challengeCopy.simulationTimeSpent or 0)
    return challengeCopy
  end
  return nil
end

-- Check if a challenge is active
local function isChallengeActive()
  return activeChallenge ~= nil
end

-- Get current simulation time for active challenge
local function getCurrentSimulationTime()
  return activeChallenge and (activeChallenge.simulationTimeSpent or 0) or 0
end

-- Check win condition for active challenge
local function checkWinCondition()
  if not activeChallenge then
    return false
  end

  local winCondition = activeChallenge.winCondition

  if winCondition == "payOffLoan" then
    -- Check if all loans are paid off
    if career_modules_loans then
      local activeLoans = career_modules_loans.getActiveLoans()
      return #activeLoans == 0
    end
    return false

  elseif winCondition == "reachTargetMoney" then
    -- Check if player has reached target money (this would need to be defined in challenge)
    if career_modules_playerAttributes then
      local currentMoney = career_modules_playerAttributes.getAttributeValue('money') or 0
      local targetMoney = activeChallenge.targetMoney or 1000000 -- Default 1M if not specified
      return currentMoney >= targetMoney
    end
    return false
  end

  -- Unknown win condition
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
    if guihooks and guihooks.trigger then
      local winConditionInfo = getWinConditionInfo(activeChallenge.winCondition)
      guihooks.trigger('challenge:completed', {
        id = activeChallenge.id,
        name = activeChallenge.name,
        winCondition = activeChallenge.winCondition,
        winConditionName = winConditionInfo.name,
        winConditionDescription = winConditionInfo.description,
        targetMoney = activeChallenge.winCondition == "reachTargetMoney" and (activeChallenge.targetMoney or 1000000) or
          nil,
        simulationTimeSpent = activeChallenge.simulationTimeSpent or 0
      })
    end

    endChallenge()
  end
end

-- CAREER CREATION INTEGRATION

-- Get challenge summary for career creation UI
local function getChallengeOptionsForCareerCreation()
  local options = {}

  for challengeId, challenge in pairs(discoveredChallenges) do
    -- Get win condition info
    local winConditionInfo = getWinConditionInfo(challenge.winCondition)

    -- Get current multipliers for all available activity types
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
      allActivityTypes = allActivityTypes, -- All available activity types with current multipliers
      currentMultipliers = currentMultipliers, -- All current multiplier values
      isBaseGame = challenge.isBaseGame or false,
      simulationTimeSpent = challenge.simulationTimeSpent or 0
    })
  end

  -- Sort by category then name (handle nils robustly)
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

-- Check if a save has an active challenge
local function doesSaveHaveActiveChallenge(saveSlotName)
  local savePath = career_saveSystem.getSaveRootDirectory() .. saveSlotName
  local filePath = savePath .. "/career/rls_career/challengeModes.json"

  if not FS:directoryExists(savePath) then
    return false
  end

  local challengeData = jsonReadFile(filePath) or {}
  return challengeData.activeChallenge ~= nil
end

-- MODULE EXPORTS

-- Core functionality
M.startChallenge = startChallenge
M.endChallenge = endChallenge
M.getActiveChallenge = getActiveChallenge
M.isChallengeActive = isChallengeActive
M.checkWinCondition = checkWinCondition

M.getCurrentSimulationTime = getCurrentSimulationTime

-- Challenge discovery and information
M.discoverChallenges = discoverChallenges
M.refreshChallenges = refreshChallenges
M.getChallengeSummary = getChallengeSummary
M.getChallengeById = getChallengeById

-- Custom challenge management
M.createCustomChallenge = createCustomChallenge
M.deleteCustomChallenge = deleteCustomChallenge
M.validateChallenge = validateChallenge

-- UI integration functions
M.getChallengeEditorData = getChallengeEditorData
M.createChallengeFromUI = createChallengeFromUI
M.updateCustomChallenge = updateCustomChallenge
M.getChallengeForEditing = getChallengeForEditing

-- Career creation integration
M.getChallengeOptionsForCareerCreation = getChallengeOptionsForCareerCreation
M.doesSaveHaveActiveChallenge = doesSaveHaveActiveChallenge
-- Data access (read-only)
M.getDiscoveredChallenges = function()
  return deepcopy(discoveredChallenges)
end

-- Lifecycle and system integration
M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate
M.onCareerActive = function(started)
  if started then
    onCareerActivated()
  else
    onCareerDeactivated()
  end
end

-- Save/load system (internal use)
M.saveChallengeData = saveChallengeData
M.loadChallengeData = loadChallengeData
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

return M