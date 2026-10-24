-- Challenge catalog for challengeModes: challenge template, win conditions (built in and runtime-added), validators, validation and file discovery.
-- Reading order: config, win condition checks, validators, discovery, win condition registry, validation, then M.create (per-load state).

-- Requires -------------------------------------------------------------

local challengeRounding = require('overhaul/lib/career/challengeRounding')
local levelData = require('overhaul/lib/world/levelData')

local M = {}

-- Config ---------------------------------------------------------------

local CHALLENGE_VERSION = "1.0"
local CHALLENGE_ID_MAX_LENGTH = 100
local CHALLENGES_PREFIX = "/challenges/"
local MPS_TO_MPH = 2.23694
local UNKNOWN_CONDITION_UPDATE_SECONDS = 5
-- "none" starts the challenge without any garage; "default" keeps the normal starting-garage choice.
local STARTING_GARAGE_MODES = {default = true, none = true}

M.CHALLENGE_VERSION = CHALLENGE_VERSION
M.STARTING_GARAGE_MODES = STARTING_GARAGE_MODES

-- Starter vehicles are "model/configKey" entries naming a config under /vehicles.
local function starterVehiclePath(entry)
  if type(entry) ~= "string" then return nil end
  local model, configKey = entry:match("^([^/]+)/([^/]+)$")
  if not model then return nil end
  return "/vehicles/" .. model .. "/" .. configKey .. ".pc", model, configKey
end

M.starterVehiclePath = starterVehiclePath

-- Win condition checks -------------------------------------------------

local function loansPaidOff()
  if not overhaul_career_economy_loans then return false end
  return #overhaul_career_economy_loans.getActiveLoans() == 0
end

local function reachedTargetMoney(ctx)
  local activeChallenge = ctx.getActiveChallenge()
  if not overhaul_career_economy_playerAttributes then return false end
  local currentMoney = overhaul_career_economy_playerAttributes.getAttributeValue('money') or 0
  local targetMoney = activeChallenge.targetMoney or 1000000
  return currentMoney >= targetMoney
end

-- Keeps the challenge's running peak speed in MPH.
local function recordPeakSpeed(activeChallenge)
  local playerVehicleId = be:getPlayerVehicleID(0)
  if not playerVehicleId then return end
  local vel = vec3(be:getObjectVelocityXYZ(playerVehicleId))
  local currentSpeed = vel:length() * MPS_TO_MPH
  if currentSpeed > (activeChallenge.maxSpeed or 0) then
    activeChallenge.maxSpeed = currentSpeed
  end
end

local function reachedTargetSpeed(ctx)
  local activeChallenge = ctx.getActiveChallenge()
  if gameplay_walk.isWalking() then return false end
  recordPeakSpeed(activeChallenge)
  return (activeChallenge.maxSpeed or 0) >= (activeChallenge.targetSpeed or 100)
end

local function listContains(list, value)
  for _, item in ipairs(list) do
    if item == value then return true end
  end
  return false
end

local function ownsEveryTargetGarage(ctx)
  local activeChallenge = ctx.getActiveChallenge()
  if not overhaul_career_garage_garageManager then return false end

  local targetGarages = activeChallenge.targetGarages
  if not targetGarages or type(targetGarages) ~= "table" or #targetGarages == 0 then return false end

  local purchasedGarages = overhaul_career_garage_garageManager.getPurchasedGarages()
  if not purchasedGarages then return false end

  for _, targetGarageId in ipairs(targetGarages) do
    if not listContains(purchasedGarages, targetGarageId) then return false end
  end
  return true
end

-- Built-in conditions, one builder each; runtime additions are appended after the last one.
local function payOffLoanCondition()
  return {
    id = "payOffLoan",
    name = "Get out of debt",
    description = "Complete the challenge by paying off all loans",
    variables = {},
    requiresLoans = true,
    updateFrequency = 10, -- loan payments are infrequent
    checkCondition = loansPaidOff
  }
end

local function reachTargetMoneyCondition(ctx)
  return {
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
    updateFrequency = 3, -- money changes frequently
    checkCondition = function() return reachedTargetMoney(ctx) end
  }
end

local function reachTargetSpeedCondition(ctx)
  return {
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
    updateFrequency = 1, -- speed changes every frame
    checkCondition = function() return reachedTargetSpeed(ctx) end
  }
end

local function ownSpecificGarageCondition(ctx)
  return {
    id = "ownSpecificGarage",
    name = "Own Specific Garage",
    description = "Complete the challenge by purchasing specific garages",
    variables = {
      targetGarages = {
        type = "multiselect",
        label = "Target Garages",
        hint = "Select the garages that must be owned to complete the challenge",
        required = true,
        order = 1,
        options = function() return ctx.getAvailableGarages() end
      }
    },
    updateFrequency = 5, -- garage purchases are infrequent
    checkCondition = function() return ownsEveryTargetGarage(ctx) end
  }
end

local function buildBuiltInWinConditions(ctx)
  return {
    payOffLoanCondition(),
    reachTargetMoneyCondition(ctx),
    reachTargetSpeedCondition(ctx),
    ownSpecificGarageCondition(ctx)
  }
end

local function buildChallengeTemplate()
  return {
    id = "",
    name = "",
    description = "",
    startingCapital = 10000,
    loans = nil,
    economyAdjuster = {},
    winCondition = "",
    startingGarages = {}, -- default starting garages for challenges
    startingGarageMode = "default",
    starterVehicles = {}, -- one is picked at random and gifted on a new save
    category = "custom",
    createdBy = "",
    createdDate = "",
    version = CHALLENGE_VERSION,
    simulationTimeSpent = 0
  }
end

-- Variable validators --------------------------------------------------

-- Shared by string, array and multiselect definitions.
local function checkLengthBounds(value, definition)
  if definition.minLength and #value < definition.minLength then
    return false, string.format("Minimum length is %d", definition.minLength)
  end
  if definition.maxLength and #value > definition.maxLength then
    return false, string.format("Maximum length is %d", definition.maxLength)
  end
  return true
end

local typeValidators = {}

typeValidators.number = function(value, definition)
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
end

typeValidators.integer = function(value, definition)
  local ok, msg = typeValidators.number(value, definition)
  if not ok then return ok, msg end
  if math.floor(value) ~= value then
    return false, "Value must be an integer"
  end
  return true
end

typeValidators.string = function(value, definition)
  if type(value) ~= "string" then
    return false, "Value must be a string"
  end
  return checkLengthBounds(value, definition)
end

typeValidators.boolean = function(value)
  if type(value) ~= "boolean" then
    return false, "Value must be a boolean"
  end
  return true
end

typeValidators.array = function(value, definition)
  if type(value) ~= "table" then
    return false, "Value must be an array"
  end
  return checkLengthBounds(value, definition)
end

typeValidators.multiselect = typeValidators.array

-- Discovery ------------------------------------------------------------

local function normalizePath(path)
  if not path then return "" end
  path = path:gsub("\\", "/")
  path = path:gsub("//+", "/")
  if not path:startswith("/") then
    path = "/" .. path
  end
  return path
end

local function getZipFileMap(zipPath)
  local zip = ZipArchive()
  local fileMap = {}

  if zip:openArchiveName(zipPath, "R") then
    local fileList = zip:getFileList()
    for index, filePath in ipairs(fileList) do
      fileMap[filePath] = index
    end
    zip:close()
  end

  return fileMap
end

local function getActiveMods()
  local activeMods = {}
  local allMods = core_modmanager.getMods()

  if not allMods then
    return {}
  end

  for modName, modData in pairs(allMods) do
    if modData.active then
      activeMods[modName] = modData
    end
  end

  return activeMods
end

-- Mod paths contain Lua pattern characters; match prefixes literally.
local function stripPathPrefix(fullPath, prefix)
  local full = tostring(fullPath or ""):gsub("\\", "/")
  local pre = tostring(prefix or ""):gsub("\\", "/"):gsub("/+$", "")
  if pre ~= "" and full:sub(1, #pre):lower() == pre:lower() then
    return full:sub(#pre + 1)
  end
  return full
end

local function addChallengePath(set, path)
  local normalized = normalizePath(path):lower()
  if normalized:sub(1, #CHALLENGES_PREFIX) == CHALLENGES_PREFIX then
    set[normalized] = true
  end
end

local function addModChallengeFiles(set, modData)
  if modData.modData and modData.modData.hashes then
    for _, hashData in ipairs(modData.modData.hashes) do
      addChallengePath(set, hashData[1])
    end
  elseif modData.unpackedPath and FS:directoryExists(modData.unpackedPath) then
    local challengeDir = tostring(modData.unpackedPath):gsub("\\", "/"):gsub("/+$", "") .. "/challenges"
    if FS:directoryExists(challengeDir) then
      for _, fullPath in ipairs(FS:findFiles(challengeDir, '*', -1, true, false)) do
        addChallengePath(set, stripPathPrefix(fullPath, modData.unpackedPath))
      end
    end
  elseif modData.fullpath and FS:fileExists(modData.fullpath) then
    for filePath, _ in pairs(getZipFileMap(modData.fullpath)) do
      addChallengePath(set, filePath)
    end
  end
end

local function buildModChallengeFileSet()
  local set = {}
  for _, modData in pairs(getActiveMods()) do
    local ok, err = pcall(addModChallengeFiles, set, modData)
    if not ok then
      log('W', 'challengeModes', 'Failed to list mod files: ' .. tostring(err))
    end
  end
  return set
end

local function isChallengeFileInMod(challengeFilePath, modFileSet)
  return modFileSet[normalizePath(challengeFilePath):lower()] == true
end

local function discoverChallengeFile(state, jsonFile, modFileSet)
  local challengeData = jsonReadFile(jsonFile)
  if not challengeData then return end

  local challengeId = jsonFile:match("([^/\\]+)%.json$")
  if not challengeId then return end

  challengeData.id = challengeId
  challengeData.filePath = jsonFile
  challengeData.isLocal = not isChallengeFileInMod(jsonFile, modFileSet)
  state.discovered[challengeId] = challengeData
end

-- Rescans challenges/*.json; the table is replaced on each refresh, so callers read it via getDiscovered.
local function discoverChallenges(state, forceRefresh)
  if state.discoveredReady and not forceRefresh then
    return state.discovered
  end

  state.discovered = {}

  local challengesPath = "challenges"
  if not FS:directoryExists(challengesPath) then
    state.discoveredReady = true
    return {}
  end

  local customPath = challengesPath .. "/custom"
  if not FS:directoryExists(customPath) then
    FS:directoryCreate(customPath)
  end

  local challengeFiles = FS:findFiles(challengesPath, "*.json", -1, false)
  local modFileSet = {}
  if #challengeFiles > 0 then
    modFileSet = buildModChallengeFileSet()
  end

  for _, jsonFile in ipairs(challengeFiles) do
    discoverChallengeFile(state, jsonFile, modFileSet)
  end

  state.discoveredReady = true
  return state.discovered
end

-- Win condition registry -----------------------------------------------

local function getWinConditionById(state, winConditionId)
  if not winConditionId then return nil end
  for _, condition in ipairs(state.winConditions) do
    if condition.id == winConditionId then
      return condition
    end
  end
  return nil
end

local function unknownWinConditionInfo(winConditionId)
  return {
    id = winConditionId,
    name = winConditionId,
    description = "Unknown win condition",
    updateFrequency = UNKNOWN_CONDITION_UPDATE_SECONDS,
    checkCondition = function()
      return false
    end
  }
end

local function getWinConditionInfo(state, winConditionId)
  return getWinConditionById(state, winConditionId) or unknownWinConditionInfo(winConditionId)
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

local function hasValidWinConditionShape(winCondition)
  if not winCondition or type(winCondition) ~= "table" then return false end
  if not winCondition.id or type(winCondition.id) ~= "string" then return false end
  if not winCondition.name or type(winCondition.name) ~= "string" then return false end
  if not winCondition.description or type(winCondition.description) ~= "string" then return false end
  if not winCondition.checkCondition or type(winCondition.checkCondition) ~= "function" then return false end
  return true
end

local function addWinCondition(state, winCondition)
  if not hasValidWinConditionShape(winCondition) then return false end
  if getWinConditionById(state, winCondition.id) then return false end

  if winCondition.variables then
    local mergedVariables = {}
    for variableId, definition in pairs(winCondition.variables) do
      mergedVariables[variableId] = mergeVariableDefinition(variableId, definition)
    end
    winCondition.variables = mergedVariables
  end

  table.insert(state.winConditions, winCondition)
  return true
end

-- Validation -----------------------------------------------------------

local function validateChallengeId(id)
  if type(id) ~= "string" or id == "" then
    return false, "Challenge must have a valid ID"
  end
  if #id > CHALLENGE_ID_MAX_LENGTH then
    return false, string.format("Challenge ID must be at most %d characters", CHALLENGE_ID_MAX_LENGTH)
  end
  if id:find('[/\\:%*%?"<>|%c]') or id:find("..", 1, true) or id:match("^[%s%.]") or id:match("[%s%.]$") then
    return false, "Challenge ID may not contain path characters (/ \\ : * ? \" < > |), '..', or start/end with a space or dot"
  end
  return true
end

local function defaultValueFor(definition)
  if definition.type == "boolean" then
    return definition.default == true
  elseif definition.type == "integer" then
    return math.floor(definition.default + 0.5)
  end
  return definition.default
end

local function applyVariableDefaults(state, challengeData)
  local condition = getWinConditionById(state, challengeData.winCondition)
  local variables = condition and condition.variables or {}
  for variableName, definition in pairs(variables) do
    if challengeData[variableName] == nil and definition.default ~= nil then
      challengeData[variableName] = defaultValueFor(definition)
    end
  end
end

local function validateWinConditionVariables(state, challengeData)
  local condition = getWinConditionById(state, challengeData.winCondition)
  local variables = condition and condition.variables or {}

  for variableName, definition in pairs(variables) do
    local value = challengeData[variableName]
    if definition.required ~= false and value == nil then
      return false, string.format("Missing required variable '%s'", variableName)
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

local function checkRequiredFields(challengeData)
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
  return true
end

local function checkStartingCapitalField(challengeData)
  if challengeData.startingCapital and type(challengeData.startingCapital) ~= "number" then
    return false, "Starting capital must be a number"
  end
  if challengeData.startingCapital then
    return challengeRounding.validateStartingCapital(challengeData.startingCapital)
  end
  return true
end

local function checkRequiredLoan(challengeData, condition)
  if not (condition and condition.requiresLoans) then return true end
  if not challengeData.loans or type(challengeData.loans) ~= "table" then
    return false, "This win condition requires a loan to be configured"
  end
  if not challengeData.loans.amount or challengeData.loans.amount <= 0 then
    return false, "Loan amount must be greater than 0 for this win condition"
  end
  return true
end

local function checkLoanFields(loans)
  if type(loans) ~= "table" then
    return false, "Loans must be a table"
  end
  if loans.amount and type(loans.amount) ~= "number" then
    return false, "Loan amount must be a number"
  end
  if loans.interest and type(loans.interest) ~= "number" then
    return false, "Loan interest must be a number"
  end
  if loans.payments and type(loans.payments) ~= "number" then
    return false, "Loan payments must be a number"
  end
  if loans.amount then
    return challengeRounding.validateLoanAmount(loans.amount)
  end
  return true
end

local function checkEconomyAdjusterField(economyAdjuster)
  if economyAdjuster and type(economyAdjuster) ~= "table" then
    return false, "Economy adjuster must be a table"
  end
  if economyAdjuster then
    for activityType, multiplier in pairs(economyAdjuster) do
      local valid, message = challengeRounding.validateEconomyMultiplier(multiplier)
      if not valid then
        return false, string.format("Economy multiplier for %s: %s", activityType, message)
      end
    end
  end
  return true
end

local function checkStartingGarageFields(challengeData)
  local mode = challengeData.startingGarageMode
  if mode ~= nil and not STARTING_GARAGE_MODES[mode] then
    return false, "Starting garage mode must be 'default' or 'none'"
  end
  local startingGarages = challengeData.startingGarages
  if startingGarages ~= nil and type(startingGarages) ~= "table" then
    return false, "Starting garages must be a list"
  end
  if mode == "none" and startingGarages and #startingGarages > 0 then
    return false, "A challenge without a starting garage cannot list starting garages"
  end
  return true
end

-- Missing config files are skipped when the gift is granted, so content from absent mods does not block a challenge.
local function checkStarterVehiclesField(starterVehicles)
  if starterVehicles == nil then return true end
  if type(starterVehicles) ~= "table" then
    return false, "Starter vehicles must be a list"
  end
  for _, entry in ipairs(starterVehicles) do
    if not starterVehiclePath(entry) then
      return false, string.format("Invalid starter vehicle '%s'; expected model/config", tostring(entry))
    end
  end
  return true
end

local function garageIdsOnMap(state, mapId)
  local onMap = {}
  for _, garage in ipairs(state.ctx.getAvailableGarages() or {}) do
    if garage.mapId == mapId then onMap[garage.id] = true end
  end
  return onMap
end

-- Garage ids only resolve on the map the challenge loads; ids from another map could never be granted or owned.
local function checkGaragesOnChallengeMap(state, challengeData)
  local lists = {}
  for _, field in ipairs({"startingGarages", "targetGarages"}) do
    local ids = challengeData[field]
    if type(ids) == "table" and #ids > 0 then lists[field] = ids end
  end
  if not next(lists) or not (state.ctx and state.ctx.getAvailableGarages) then return true end

  local mapId = challengeData.map or levelData.defaultMap()
  if not mapId then return true end
  local onMap = garageIdsOnMap(state, mapId)
  -- An unreadable or uninstalled map cannot be judged here; starting the career reports it instead.
  if not next(onMap) then return true end

  for _, ids in pairs(lists) do
    for _, garageId in ipairs(ids) do
      if not onMap[garageId] then
        return false, string.format("Garage '%s' is not available on map '%s'", tostring(garageId), mapId)
      end
    end
  end
  return true
end

local function validateChallenge(state, challengeData)
  local ok, message = checkRequiredFields(challengeData)
  if not ok then return false, message end

  ok, message = checkStartingCapitalField(challengeData)
  if not ok then return false, message end

  local condition = getWinConditionById(state, challengeData.winCondition)
  ok, message = checkRequiredLoan(challengeData, condition)
  if not ok then return false, message end

  if challengeData.loans then
    ok, message = checkLoanFields(challengeData.loans)
    if not ok then return false, message end
  end

  ok, message = checkEconomyAdjusterField(challengeData.economyAdjuster)
  if not ok then return false, message end

  ok, message = validateWinConditionVariables(state, challengeData)
  if not ok then return false, message end

  ok, message = checkStartingGarageFields(challengeData)
  if not ok then return false, message end

  ok, message = checkStarterVehiclesField(challengeData.starterVehicles)
  if not ok then return false, message end

  ok, message = checkGaragesOnChallengeMap(state, challengeData)
  if not ok then return false, message end

  return true, "Valid"
end

-- Lifecycle ------------------------------------------------------------

-- Public API. challengeModes creates one catalog per extension load, so this state resets with the extension.
function M.create(ctx)
  local state = {
    winConditions = buildBuiltInWinConditions(ctx),
    discovered = {},
    discoveredReady = false,
    ctx = ctx,
  }
  local challengeTemplate = buildChallengeTemplate()

  local api = {}
  api.challengeTemplate = challengeTemplate
  api.getWinConditions = function() return state.winConditions end
  api.getWinConditionById = function(winConditionId) return getWinConditionById(state, winConditionId) end
  api.getWinConditionInfo = function(winConditionId) return getWinConditionInfo(state, winConditionId) end
  api.applyVariableDefaults = function(challengeData) return applyVariableDefaults(state, challengeData) end
  api.validateChallengeId = validateChallengeId
  api.validateChallenge = function(challengeData) return validateChallenge(state, challengeData) end
  api.addWinCondition = function(winCondition) return addWinCondition(state, winCondition) end
  api.discoverChallenges = function(forceRefresh) return discoverChallenges(state, forceRefresh) end
  -- discoverChallenges replaces the table on a refresh; always read it through this accessor.
  api.getDiscovered = function() return state.discovered end
  api.storeChallenge = function(challengeId, challenge)
    state.discovered[challengeId] = challenge
    state.discoveredReady = true
  end
  api.forgetChallenge = function(challengeId)
    state.discovered[challengeId] = nil
  end
  return api
end

return M
