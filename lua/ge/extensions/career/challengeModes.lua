local M = {}

-- Manages challenge discovery, creation, and execution
-- Automatically finds challenges in the challenges/ folder structure

-- ============================================================================
-- CONSTANTS AND VARIABLES
-- ============================================================================

local CHALLENGE_VERSION = "1.0"

-- Economy multiplier constraints
local ECONOMY_MULTIPLIER_STEP = 0.25
local ECONOMY_MULTIPLIER_MIN = 0.25
local ECONOMY_MULTIPLIER_MAX = 10.0

-- Loan amount constraints
local LOAN_AMOUNT_STEP = 1000
local LOAN_AMOUNT_MIN = 0
local LOAN_AMOUNT_MAX = 10000000

-- Starting capital constraints
local STARTING_CAPITAL_STEP = 500

local discoveredChallenges = {}
local activeChallenge = nil
local completedChallengeData = nil
local updateTimer = 0

-- ============================================================================
-- DATA STRUCTURES
-- ============================================================================

local challengeTemplate = {
  id = "",
  name = "",
  description = "",
  startingCapital = 10000,
  loans = nil,
  economyAdjuster = {},
  winCondition = "",
  targetMoney = 1000000, -- Default target for reachTargetMoney challenges
  targetSpeed = 100, -- Default target for reachTargetSpeed challenges
  maxSpeed = 0, -- Track maximum speed achieved
  startingGarages = {}, -- Default starting garages for challenges
  category = "custom",
  createdBy = "",
  createdDate = "",
  version = CHALLENGE_VERSION,
  simulationTimeSpent = 0
}

local winConditions = {
  {
    id = "payOffLoan",
    name = "Get out of debt",
    description = "Complete the challenge by paying off all loans",
    variables = {},
    requiresLoans = true,
    updateFrequency = 10, -- Check every 10 seconds since loan payments are infrequent
    checkCondition = function()
      if career_modules_loans then
        local activeLoans = career_modules_loans.getActiveLoans()
        return #activeLoans == 0
      end
      return false
    end
  },
  {
    id = "reachTargetMoney",
    name = "Reach Target Money",
    description = "Complete the challenge by reaching a target amount of money",
    variables = {
      targetMoney = {
        type = "number",
        label = "Target Money",
        min = 10000,
        max = 25000000,
        randomMax = 1000000,
        default = 100000,
        decimals = 0,
        step = 1000,
        order = 1
      }
    },
    updateFrequency = 3, -- Check every 3 seconds since money changes frequently
    checkCondition = function()
      if career_modules_playerAttributes then
        local currentMoney = career_modules_playerAttributes.getAttributeValue('money') or 0
        local targetMoney = activeChallenge.targetMoney or 1000000
        return currentMoney >= targetMoney
      end
      return false
    end
  },
  {
    id = "reachTargetSpeed",
    name = "Reach Target Speed",
    description = "Complete the challenge by reaching a target speed in MPH",
    variables = {
      targetSpeed = {
        type = "number",
        label = "Target Speed (MPH)",
        min = 50,
        max = 500,
        randomMax = 300,
        default = 150,
        decimals = 0,
        step = 10,
        order = 1
      }
    },
    updateFrequency = 1, -- Check every second since speed changes frequently
    checkCondition = function()
      local targetSpeed = activeChallenge.targetSpeed or 100
      local maxSpeed = activeChallenge.maxSpeed or 0
      return maxSpeed >= targetSpeed
    end
  }
}

local typeValidators = {
  number = function(value, definition)
    if type(value) ~= "number" then
      return false, "Value must be a number"
    end
    if definition.min and value < definition.min then
      return false, string.format("Value must be >= %s", tostring(definition.min))
    end
    if definition.max and value > definition.max then
      return false, string.format("Value must be <= %s", tostring(definition.max))
    end
    return true
  end,
  integer = function(value, definition)
    local ok, msg = typeValidators.number(value, definition)
    if not ok then return ok, msg end
    if math.floor(value) ~= value then
      return false, "Value must be an integer"
    end
    return true
  end,
  string = function(value, definition)
    if type(value) ~= "string" then
      return false, "Value must be a string"
    end
    if definition.minLength and #value < definition.minLength then
      return false, string.format("Minimum length is %d", definition.minLength)
    end
    if definition.maxLength and #value > definition.maxLength then
      return false, string.format("Maximum length is %d", definition.maxLength)
    end
    return true
  end,
  boolean = function(value)
    if type(value) ~= "boolean" then
      return false, "Value must be a boolean"
    end
    return true
  end
}

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

local function validateEconomyMultiplier(value)
  if not value or type(value) ~= "number" then
    return false, "Invalid multiplier value"
  end
  
  if value < 0.0 or value > ECONOMY_MULTIPLIER_MAX then
    return false, string.format("Multiplier must be between 0.0 and %.2f", ECONOMY_MULTIPLIER_MAX)
  end
  
  -- Allow 0.0 (disabled) without step validation
  if value == 0.0 then
    return true
  end
  
  local remainder = value % ECONOMY_MULTIPLIER_STEP
  if math.abs(remainder) > 0.01 and math.abs(remainder - ECONOMY_MULTIPLIER_STEP) > 0.01 then
    return false, string.format("Multiplier must be a multiple of %.2f", ECONOMY_MULTIPLIER_STEP)
  end
  
  return true
end

local function roundEconomyMultiplier(value)
  if not value or type(value) ~= "number" then
    return 1.0
  end
  
  local rounded = math.floor((value / ECONOMY_MULTIPLIER_STEP) + 0.5) * ECONOMY_MULTIPLIER_STEP
  rounded = math.max(ECONOMY_MULTIPLIER_MIN, math.min(ECONOMY_MULTIPLIER_MAX, rounded))
  return rounded
end

local function validateLoanAmount(value)
  if not value or type(value) ~= "number" then
    return false, "Invalid loan amount value"
  end
  
  if value < LOAN_AMOUNT_MIN or value > LOAN_AMOUNT_MAX then
    return false, string.format("Loan amount must be between %d and %d", LOAN_AMOUNT_MIN, LOAN_AMOUNT_MAX)
  end
  
  local remainder = value % LOAN_AMOUNT_STEP
  if math.abs(remainder) > 0.01 and math.abs(remainder - LOAN_AMOUNT_STEP) > 0.01 then
    return false, string.format("Loan amount must be a multiple of %d", LOAN_AMOUNT_STEP)
  end
  
  return true
end

local function roundLoanAmount(value)
  if not value or type(value) ~= "number" then
    return LOAN_AMOUNT_MIN
  end
  
  local rounded = math.floor((value / LOAN_AMOUNT_STEP) + 0.5) * LOAN_AMOUNT_STEP
  rounded = math.max(LOAN_AMOUNT_MIN, math.min(LOAN_AMOUNT_MAX, rounded))
  return rounded
end

local function validateStartingCapital(value)
  if not value or type(value) ~= "number" then
    return false, "Invalid starting capital value"
  end
  
  if value < 0 then
    return false, "Starting capital must be non-negative"
  end
  
  local remainder = value % STARTING_CAPITAL_STEP
  if math.abs(remainder) > 0.01 and math.abs(remainder - STARTING_CAPITAL_STEP) > 0.01 then
    return false, string.format("Starting capital must be a multiple of %d", STARTING_CAPITAL_STEP)
  end
  
  return true
end

local function roundStartingCapital(value)
  if not value or type(value) ~= "number" then
    return 0
  end
  
  local rounded = math.floor((value / STARTING_CAPITAL_STEP) + 0.5) * STARTING_CAPITAL_STEP
  return math.max(0, rounded)
end

-- ============================================================================
-- DISCOVERY FUNCTIONS
-- ============================================================================

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

-- ============================================================================
-- VALIDATION FUNCTIONS
-- ============================================================================

local function getWinConditionById(winConditionId)
  if not winConditionId then return nil end
  for _, condition in ipairs(winConditions) do
    if condition.id == winConditionId then
      return condition
    end
  end
  return nil
end

local function applyVariableDefaults(challengeData)
  local condition = getWinConditionById(challengeData.winCondition)
  local variables = condition and condition.variables or {}
  for variableName, definition in pairs(variables) do
    if challengeData[variableName] == nil then
      if definition.default ~= nil then
        if definition.type == "boolean" then
          challengeData[variableName] = definition.default == true
        elseif definition.type == "integer" then
          challengeData[variableName] = math.floor(definition.default + 0.5)
        else
          challengeData[variableName] = definition.default
        end
      end
    end
  end
end

local function validateWinConditionVariables(challengeData)
  local condition = getWinConditionById(challengeData.winCondition)
  local variables = condition and condition.variables or {}

  for variableName, definition in pairs(variables) do
    local value = challengeData[variableName]
    if definition.required ~= false then
      if value == nil then
        return false, string.format("Missing required variable '%s'", variableName)
      end
    end

    if value ~= nil then
      local validator = typeValidators[definition.type or "number"]
      if validator then
        local isValid, message = validator(value, definition)
        if not isValid then
          return false, string.format("Invalid value for '%s': %s", variableName, message)
        end
      end
    end
  end

  return true
end

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
  
  -- Validate starting capital constraints
  if challengeData.startingCapital then
    local valid, message = validateStartingCapital(challengeData.startingCapital)
    if not valid then
      return false, message
    end
  end

  local condition = getWinConditionById(challengeData.winCondition)
  if condition and condition.requiresLoans then
    if not challengeData.loans or type(challengeData.loans) ~= "table" then
      return false, "This win condition requires a loan to be configured"
    end
    if not challengeData.loans.amount or challengeData.loans.amount <= 0 then
      return false, "Loan amount must be greater than 0 for this win condition"
    end
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
    
    -- Validate loan amount constraints
    if challengeData.loans.amount then
      local valid, message = validateLoanAmount(challengeData.loans.amount)
      if not valid then
        return false, message
      end
    end
  end

  if challengeData.economyAdjuster and type(challengeData.economyAdjuster) ~= "table" then
    return false, "Economy adjuster must be a table"
  end

  -- Validate economy multipliers
  if challengeData.economyAdjuster then
    for activityType, multiplier in pairs(challengeData.economyAdjuster) do
      local valid, message = validateEconomyMultiplier(multiplier)
      if not valid then
        return false, string.format("Economy multiplier for %s: %s", activityType, message)
      end
    end
  end

  local ok, message = validateWinConditionVariables(challengeData)
  if not ok then
    return false, message
  end

  return true, "Valid"
end

-- ============================================================================
-- UI INTEGRATION FUNCTIONS
-- ============================================================================

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
  for _, condition in ipairs(winConditions) do
    if condition.id == winConditionId then
      return condition
    end
  end

  return {
    id = winConditionId,
    name = winConditionId,
    description = "Unknown win condition",
    updateFrequency = 5, -- Default update frequency
    checkCondition = function()
      return false
    end
  }
end

local function getAvailableGarages()
  local availableGarages = {}
  
  -- Get all available career maps
  local compatibleMaps = overhaul_maps.getCompatibleMaps() or {}
  
  local careerMaps = {}
  
  -- Convert compatible maps to the format we need
  for mapId, mapName in pairs(compatibleMaps) do
    table.insert(careerMaps, {id = mapId, name = mapName})
  end
  
  -- Parse facility files for each career map
  for _, map in ipairs(careerMaps) do
    local levelInfo = core_levels.getLevelByName(map.id)
    if levelInfo then
      -- Parse info.json of the level
      local infoFile = levelInfo.dir .. "/info.json"
      
      if FS:fileExists(infoFile) then
        local data = jsonReadFile(infoFile)
        
        if data and data.garages then
          for _, garage in ipairs(data.garages) do
            table.insert(availableGarages, {
              id = garage.id,
              name = garage.name,
              price = garage.defaultPrice or 0,
              capacity = garage.capacity or 0,
              starterGarage = garage.starterGarage or false
            })
          end
        end
      end
      
      -- Parse any other facility files inside the levels /facilities folder
      local facilitiesDir = levelInfo.dir .. "/facilities/"
      
      local facilityFiles = FS:findFiles(facilitiesDir, '*.facilities.json', -1, false, true)
      
      for _, file in ipairs(facilityFiles) do
        local data = jsonReadFile(file)
        
        if data and data.garages then
          for _, garage in ipairs(data.garages) do
            table.insert(availableGarages, {
              id = garage.id,
              name = garage.name,
              price = garage.defaultPrice or 0,
              capacity = garage.capacity or 0,
              starterGarage = garage.starterGarage or false
            })
          end
        end
      end
    end
  end
  
  return availableGarages
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

  -- Get available garages for selection
  local availableGarages = getAvailableGarages()

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

  local serializedWinConditions = {}
  for _, condition in ipairs(winConditions) do
    local entry = {
      id = condition.id,
      name = condition.name,
      description = condition.description,
      variables = {},
      requiresLoans = condition.requiresLoans or false
    }
    if condition.variables then
      for variableName, definition in pairs(condition.variables) do
        entry.variables[variableName] = deepcopy(definition)
      end
    end
    table.insert(serializedWinConditions, entry)
  end

  return {
    winConditions = serializedWinConditions,
    activityTypes = activityTypes,
    activityTypesBySource = activityTypesBySource,
    currentMultipliers = currentMultipliers,
    availableGarages = availableGarages,
    loanTerms = {6, 12, 18, 24, 36, 48, 60},
    defaults = {
      startingCapital = 10000,
      loanAmount = 50000,
      loanInterest = 0.10,
      loanPayments = 12,
      targetMoney = 1000000,
      startingGarages = {}
    },
    stats = {
      totalActivityTypes = #activityTypes,
      activitySources = (function(tbl)
        if not tbl or type(tbl) ~= "table" then return 0 end
        local count = 0
        for _ in pairs(tbl) do count = count + 1 end
        return count
      end)(activityTypesBySource),
      totalGarages = #availableGarages
    }
  }
end

local function createChallengeFromUI(challengeData)
  if not challengeData or not challengeData.id or not challengeData.name then
    return false, "Challenge must have a valid ID and name", nil
  end

  applyVariableDefaults(challengeData)

  -- Round economy multipliers before validation
  if challengeData.economyAdjuster then
    for activityType, multiplier in pairs(challengeData.economyAdjuster) do
      challengeData.economyAdjuster[activityType] = roundEconomyMultiplier(multiplier)
    end
  end

  -- Round loan amounts before validation
  if challengeData.loans and challengeData.loans.amount then
    challengeData.loans.amount = roundLoanAmount(challengeData.loans.amount)
  end

  -- Round starting capital before validation
  if challengeData.startingCapital then
    challengeData.startingCapital = roundStartingCapital(challengeData.startingCapital)
  end

  local valid, message = validateChallenge(challengeData)
  if not valid then
    return false, message, nil
  end

  local customPath = "challenges/custom"
  if not FS:directoryExists(customPath) then
    FS:directoryCreate(customPath)
  end

  local newChallenge = {}

  -- Only include essential fields
  newChallenge.id = challengeData.id
  newChallenge.name = challengeData.name
  newChallenge.description = challengeData.description
  newChallenge.startingCapital = challengeData.startingCapital
  newChallenge.winCondition = challengeData.winCondition
  newChallenge.version = CHALLENGE_VERSION

  -- Include win condition variables
  local condition = getWinConditionById(challengeData.winCondition)
  if condition and condition.variables then
    for variableName, definition in pairs(condition.variables) do
      if challengeData[variableName] ~= nil then
        newChallenge[variableName] = challengeData[variableName]
      end
    end
  end

  -- Include starting garages if present
  if challengeData.startingGarages and type(challengeData.startingGarages) == "table" and #challengeData.startingGarages > 0 then
    newChallenge.startingGarages = challengeData.startingGarages
  end

  -- Include loans if present
  if challengeData.loans and challengeData.loans.amount and challengeData.loans.amount > 0 then
    newChallenge.loans = challengeData.loans
  end

  -- Only include economy adjustments that are not 1, with step enforcement
  if challengeData.economyAdjuster then
    local filteredAdjuster = {}
    for activityType, multiplier in pairs(challengeData.economyAdjuster) do
      if multiplier ~= 1.0 then
        local roundedMultiplier = roundEconomyMultiplier(multiplier)
        filteredAdjuster[activityType] = roundedMultiplier
      end
    end
    if next(filteredAdjuster) then
      newChallenge.economyAdjuster = filteredAdjuster
    end
  end

  local filePath = customPath .. "/" .. challengeData.id .. ".json"
  local success = jsonWriteFile(filePath, newChallenge, true)

  if success then
    discoverChallenges()
    return true, "Challenge created successfully", challengeData.id
  else
    return false, "Failed to save challenge file", nil
  end
end

-- ============================================================================
-- CHALLENGE EXECUTION & MANAGEMENT FUNCTIONS
-- ============================================================================

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
  if activeChallenge and career_economyAdjuster then
    career_economyAdjuster.resetToDefaults()
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

  applyVariableDefaults(challenge)

  local valid, message = validateChallenge(challenge)
  if not valid then
    return false
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

  -- Set starting garages if specified
  if challenge.startingGarages and type(challenge.startingGarages) == "table" and #challenge.startingGarages > 0 then
    if career_modules_garageManager then
      for _, garageId in ipairs(challenge.startingGarages) do
        career_modules_garageManager.addPurchasedGarage(garageId)
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

  guihooks.trigger('challenge:started', {
    id = challenge.id,
    name = challenge.name,
    description = challenge.description,
    winCondition = challenge.winCondition,
    simulationTimeSpent = 0
  })

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

  local winConditionInfo = getWinConditionInfo(winCondition)
  return winConditionInfo.checkCondition()
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if activeChallenge then
    activeChallenge.simulationTimeSpent = (activeChallenge.simulationTimeSpent or 0) + (dtSim or 0)
    
    -- Track max speed for reachTargetSpeed challenges
    if activeChallenge.winCondition == "reachTargetSpeed" then
      local playerVehicleId = be:getPlayerVehicleID(0)
      if playerVehicleId then
        local currentSpeed = math.abs(be:getObjectVelocityXYZ(playerVehicleId)) * 2.23694 -- Convert m/s to MPH
        if currentSpeed > (activeChallenge.maxSpeed or 0) then
          activeChallenge.maxSpeed = currentSpeed
        end
      end
    end
  end

  updateTimer = updateTimer + dtRaw
  
  -- Get update frequency from win condition, default to 5 seconds
  local updateFrequency = 5
  if activeChallenge then
    local winConditionInfo = getWinConditionInfo(activeChallenge.winCondition)
    updateFrequency = winConditionInfo.updateFrequency or 5
  end
  
  if updateTimer < updateFrequency then
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
      targetSpeed = activeChallenge.winCondition == "reachTargetSpeed" and (activeChallenge.targetSpeed or 100) or nil,
      maxSpeed = activeChallenge.winCondition == "reachTargetSpeed" and (activeChallenge.maxSpeed or 0) or nil,
      simulationTimeSpent = activeChallenge.simulationTimeSpent or 0,
      startingCapital = activeChallenge.startingCapital,
      loans = activeChallenge.loans
    }
    
    guihooks.trigger('ChangeState', {state = 'challenge-completed'})

    endChallenge()
  end
end

local function requestChallengeCompleteData()
  if completedChallengeData then
    guihooks.trigger('challengeCompleteData', completedChallengeData)
    completedChallengeData = nil
  end
end

-- ============================================================================
-- CAREER CREATION INTEGRATION FUNCTIONS
-- ============================================================================

local function getChallengeOptionsForCareerCreation()
  local options = {}

  for challengeId, challenge in pairs(discoveredChallenges) do
    local winConditionInfo = getWinConditionInfo(challenge.winCondition)
    local condition = getWinConditionById(challenge.winCondition)

    local variables = {}
    if condition and condition.variables then
      for variableName, definition in pairs(condition.variables) do
        variables[variableName] = {
          value = challenge[variableName],
          definition = deepcopy(definition)
        }
      end
    end

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
      variables = variables,
      targetMoney = challenge.winCondition == "reachTargetMoney" and (challenge.targetMoney or 1000000) or nil,
      startingGarages = challenge.startingGarages or {},
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

local function mergeVariableDefinition(variableId, definition)
  if not definition then return nil end
  local merged = {
    type = definition.type or "number",
    label = definition.label or variableId,
    hint = definition.hint,
    min = definition.min,
    max = definition.max,
    minLength = definition.minLength,
    maxLength = definition.maxLength,
    placeholder = definition.placeholder,
    step = definition.step,
    decimals = definition.decimals,
    order = definition.order,
    default = definition.default,
    required = definition.required ~= false
  }
  if merged.type == "integer" then
    merged.decimals = 0
    merged.step = merged.step or 1
  end
  return merged
end

local function addWinCondition(winCondition)
  if not winCondition or type(winCondition) ~= "table" then
    print("Invalid win condition")
    return false
  end
  if not winCondition.id or type(winCondition.id) ~= "string" then
    print("Win condition must have an ID")
    return false
  end
  if not winCondition.name or type(winCondition.name) ~= "string" then
    print("Win condition must have a name")
    return false
  end
  if not winCondition.description or type(winCondition.description) ~= "string" then
    print("Win condition must have a description")
    return false
  end
  if not winCondition.checkCondition or type(winCondition.checkCondition) ~= "function" then
    print("Win condition must have a check condition function")
    return false
  end
  if winConditions[winCondition.id] then
    print("Win condition already exists")
    return false
  end

  if winCondition.variables then
    local mergedVariables = {}
    for variableId, definition in pairs(winCondition.variables) do
      mergedVariables[variableId] = mergeVariableDefinition(variableId, definition)
    end
    winCondition.variables = mergedVariables
  end

  table.insert(winConditions, winCondition)
end

-- ============================================================================
-- SEED ENCODING/DECODING FUNCTIONS
-- ============================================================================

local function getChallengeSeeded(challengeId)
  local challenge = discoveredChallenges[challengeId]
  if not challenge then
    return nil, "Challenge not found"
  end
  
  if not career_challengeSeedEncoder then
    return nil, "Seed encoder not available"
  end
  
  local success, seed, err = pcall(career_challengeSeedEncoder.encodeChallengeToSeed, challenge)
  if not success then
    return nil, "Encoding error: " .. tostring(seed)
  end
  
  if not seed then
    return nil, err or "Failed to encode seed"
  end
  
  return seed
end

local function createChallengeFromSeedUI(seed, name, description)
  if not seed or seed == "" then
    return false, "No seed provided", nil
  end
  
  if career_challengeSeedEncoder then
    local success, message, challengeId = career_challengeSeedEncoder.createChallengeFromSeed(seed, name, description)
    if success then
      discoverChallenges()
    end
    return success, message, challengeId
  end
  
  return false, "Seed encoder not available", nil
end

local function getWinConditions()
  return winConditions
end

local function encodeChallengeDataToSeed(challengeData)
  if not career_challengeSeedEncoder then
    return false, "Seed encoder not available"
  end

  local payload = deepcopy(challengeTemplate)
  payload.id = payload.id ~= "" and payload.id or "seedTemplate"
  payload.name = payload.name ~= "" and payload.name or "Seed Template"
  payload.description = payload.description or ""
  payload.category = payload.category or "custom"

  for k, v in pairs(challengeData or {}) do
    if v ~= nil then
      payload[k] = v
    end
  end

  local success, seed, err = pcall(career_challengeSeedEncoder.encodeChallengeToSeed, payload)
  if not success then
    return false, "Encoding error: " .. tostring(seed)
  end
  
  if not seed then
    return false, err or "Failed to encode seed"
  end

  return true, seed
end

local function decodeSeedToChallengeData(seed)
  if not career_challengeSeedEncoder then
    return false, "Seed encoder not available"
  end

  local decoded, err = career_challengeSeedEncoder.decodeSeedToChallenge(seed)
  if not decoded then
    return false, err or "Failed to decode seed"
  end

  local resolved, resolveErr = career_challengeSeedEncoder.resolveHashesToNames(decoded)
  if not resolved then
    return false, resolveErr or "Failed to resolve seed data"
  end

  return true, resolved
end

local function requestGenerateRandomSeed(options)
  options = options or {}

  local seed, data = career_challengeSeedEncoder.generateRandomSeed(options)
  if not seed then
    guihooks.trigger('challengeSeedGenerated', {
      success = false,
      error = data or "Failed to generate seed"
    })
    return
  end

  guihooks.trigger('challengeSeedGenerated', {
    success = true,
    seed = seed,
    data = data
  })
end

local function generateRandomChallengeData(options, ...)
  options = options or {}
  if not career_challengeSeedEncoder then
    return false, "Seed encoder not available"
  end

  local data, err = career_challengeSeedEncoder.generateRandomChallengeData(options)
  if not data then
    return false, err or "Failed to generate challenge data"
  end

  return true, data
end

local function requestSeedEncode(requestId, challengeData)
  local ok, seedOrErr = encodeChallengeDataToSeed(challengeData)
  local response = {
    requestId = requestId,
    success = ok == true
  }

  if ok then
    response.seed = seedOrErr
  else
    response.error = seedOrErr or "Failed to encode seed"
  end

  guihooks.trigger('challengeSeedEncodeResponse', response)

  return response.success, response.seed or response.error
end

local function requestSeedDecode(requestId, seed)
  local ok, dataOrErr = decodeSeedToChallengeData(seed)
  local response = {
    requestId = requestId,
    seed = seed,
    success = ok == true
  }

  if ok then
    response.data = dataOrErr
  else
    response.error = dataOrErr or "Failed to decode seed"
  end

  guihooks.trigger('challengeSeedDecodeResponse', response)

  return response.success, response.data or response.error
end

-- ============================================================================
-- EXPORTS
-- ============================================================================

M.addWinCondition = addWinCondition
M.getWinConditions = getWinConditions
M.startChallenge = startChallenge
M.getActiveChallenge = getActiveChallenge
M.isChallengeActive = isChallengeActive
M.discoverChallenges = discoverChallenges
M.getChallengeEditorData = getChallengeEditorData
M.createChallengeFromUI = createChallengeFromUI
M.getChallengeOptionsForCareerCreation = getChallengeOptionsForCareerCreation
M.requestChallengeCompleteData = requestChallengeCompleteData
M.getChallengeSeeded = getChallengeSeeded
M.createChallengeFromSeedUI = createChallengeFromSeedUI
M.requestGenerateRandomSeed = requestGenerateRandomSeed
M.requestSeedEncode = requestSeedEncode
M.requestSeedDecode = requestSeedDecode
M.generateRandomChallengeData = generateRandomChallengeData
M.encodeChallengeDataToSeed = encodeChallengeDataToSeed
M.decodeSeedToChallengeData = decodeSeedToChallengeData
M.getAvailableGarages = getAvailableGarages
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