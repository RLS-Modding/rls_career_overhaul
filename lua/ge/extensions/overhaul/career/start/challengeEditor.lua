-- Challenge editor for challengeModes: challenge creation from the UI or a seed, editing, deletion, seed encode/decode/generation and UI projections.
-- Reading order: config, garage selection, activity projections, win condition projections, creation, seeds, then M.create. Challenges live in the catalog.

-- Requires -------------------------------------------------------------

local challengeRounding = require('overhaul/lib/career/challengeRounding')
local challengeCatalog = require('overhaul/career/start/challengeCatalog')
local challengeStartRules = require('overhaul/career/start/challengeStartRules')
local activityTaxonomy = require('overhaul/lib/career/activityTaxonomy')

local M = {}

-- Config ---------------------------------------------------------------

local CHALLENGE_VERSION = challengeCatalog.CHALLENGE_VERSION
local CUSTOM_CHALLENGE_DIR = "challenges/custom"
local DEFAULT_STARTING_CAPITAL = 10000
local DEFAULT_LOAN_AMOUNT = 50000
local DEFAULT_LOAN_INTEREST = 0.10
local DEFAULT_LOAN_PAYMENTS = 12
local DEFAULT_TARGET_MONEY = 1000000
local DEFAULT_DIFFICULTY = "Medium"
local DEFAULT_MULTIPLIER = 1.0

-- Bookkeeping fields the edit form must not send back as challenge data.
local NON_EDITABLE_FIELDS = {
  filePath = true,
  isLocal = true,
  isBaseGame = true,
  startedAt = true,
  simulationTimeSpent = true,
  maxSpeed = true,
}

-- Garage selection -----------------------------------------------------

-- Starting eligibility is declared by the facility, independently of its name.
local function isPublicTuningStation(garage)
  return garage and (garage.notPurchasable or garage.selectableAsStartingGarage == false)
end

local function pushSelectableGarage(availableGarages, garage, map)
  if not garage or not garage.id or isPublicTuningStation(garage) then
    return
  end
  table.insert(availableGarages, {
    id = garage.id,
    name = garage.name,
    mapId = map.id,
    mapName = map.name,
    price = garage.defaultPrice or 0,
    capacity = garage.capacity or 0,
    starterGarage = garage.starterGarage or false
  })
end

local function pushGaragesFromFile(availableGarages, data, map)
  if not (data and data.garages) then return end
  for _, garage in ipairs(data.garages) do
    pushSelectableGarage(availableGarages, garage, map)
  end
end

-- Level info.json plus every *.facilities.json under the level's facilities folder.
local function pushLevelGarages(availableGarages, map)
  local levelInfo = core_levels.getLevelByName(map.id)
  if not levelInfo then return end

  local infoFile = levelInfo.dir .. "/info.json"
  if FS:fileExists(infoFile) then
    pushGaragesFromFile(availableGarages, jsonReadFile(infoFile), map)
  end

  local facilityFiles = FS:findFiles(levelInfo.dir .. "/facilities/", '*.facilities.json', -1, false, true)
  for _, file in ipairs(facilityFiles) do
    pushGaragesFromFile(availableGarages, jsonReadFile(file), map)
  end
end

local function getAvailableGarages()
  local availableGarages = {}
  local compatibleMaps = overhaul_world_maps.getCompatibleMaps() or {}

  local careerMaps = {}
  for mapId, mapName in pairs(compatibleMaps) do
    table.insert(careerMaps, {id = mapId, name = mapName})
  end

  for _, map in ipairs(careerMaps) do
    pushLevelGarages(availableGarages, map)
  end

  return availableGarages
end

-- Activity projections -------------------------------------------------

local function getActivityTypeInfo(state, activityType)
  state.taxonomy = state.taxonomy or activityTaxonomy.load()
  return activityTaxonomy.typeInfo(state.taxonomy, activityType)
end

local function activityTypeWithMultiplier(state, activityType)
  local activityInfo = getActivityTypeInfo(state, activityType)
  activityInfo.currentMultiplier = overhaul_career_economyAdjuster.getSectionMultiplier(activityType) or DEFAULT_MULTIPLIER
  return activityInfo
end

-- Returns the activity list and a type-to-multiplier map for every type the economy adjuster lists.
local function availableActivityProjection(state)
  local activityTypes = {}
  local currentMultipliers = {}
  local availableTypes = overhaul_career_economyAdjuster.getAvailableTypes()
  if availableTypes and type(availableTypes) == "table" then
    for _, activityType in ipairs(availableTypes) do
      local activityInfo = activityTypeWithMultiplier(state, activityType)
      table.insert(activityTypes, activityInfo)
      currentMultipliers[activityType] = activityInfo.currentMultiplier
    end
  end
  return activityTypes, currentMultipliers
end

local function activityTypesBySourceProjection(state)
  local activityTypesBySource = {}
  local typesBySource = overhaul_career_economyAdjuster.getTypesBySource()
  if typesBySource then
    for sourceName, types in pairs(typesBySource) do
      activityTypesBySource[sourceName] = {}
      for _, activityType in ipairs(types) do
        table.insert(activityTypesBySource[sourceName], activityTypeWithMultiplier(state, activityType))
      end
    end
  end
  return activityTypesBySource
end

local function countKeys(tbl)
  local count = 0
  for _ in pairs(tbl) do count = count + 1 end
  return count
end

-- Win condition projections --------------------------------------------

-- Serializes conditions for the UI; option functions are called once here so the payload holds plain lists.
local function serializeWinConditions(winConditions)
  local serialized = {}
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
        local variable = deepcopy(definition)
        entry.variables[variableName] = variable
        if type(variable.options) == "function" then
          variable.options = variable.options()
        end
      end
    end
    table.insert(serialized, entry)
  end
  return serialized
end

-- Editor data ----------------------------------------------------------

local function editorDefaults()
  return {
    startingCapital = DEFAULT_STARTING_CAPITAL,
    loanAmount = DEFAULT_LOAN_AMOUNT,
    loanInterest = DEFAULT_LOAN_INTEREST,
    loanPayments = DEFAULT_LOAN_PAYMENTS,
    targetMoney = DEFAULT_TARGET_MONEY,
    startingGarages = {},
    startingGarageMode = "default",
    starterVehicles = {}
  }
end

local function getChallengeEditorData(state)
  local activityTypes, currentMultipliers = availableActivityProjection(state)
  local availableGarages = getAvailableGarages()
  local activityTypesBySource = activityTypesBySourceProjection(state)

  return {
    winConditions = serializeWinConditions(state.catalog.getWinConditions()),
    activityTypes = activityTypes,
    activityTypesBySource = activityTypesBySource,
    currentMultipliers = currentMultipliers,
    availableGarages = availableGarages,
    availableStarterVehicles = challengeStartRules.getAvailableStarterVehicles(),
    loanTerms = {6, 12, 18, 24, 36, 48, 60},
    defaults = editorDefaults(),
    stats = {
      totalActivityTypes = #activityTypes,
      activitySources = countKeys(activityTypesBySource),
      totalGarages = #availableGarages
    }
  }
end

local function getEditorDataLight(state)
  local winConditions = serializeWinConditions(state.catalog.getWinConditions())

  local activityTypes = {}
  local availableTypes = overhaul_career_economyAdjuster.getAvailableTypes()
  if availableTypes and type(availableTypes) == "table" then
    for _, activityType in ipairs(availableTypes) do
      table.insert(activityTypes, getActivityTypeInfo(state, activityType))
    end
  end

  return {
    winConditions = winConditions,
    activityTypes = activityTypes,
    availableGarages = getAvailableGarages(),
    availableStarterVehicles = challengeStartRules.getAvailableStarterVehicles(),
    defaults = {
      startingCapital = DEFAULT_STARTING_CAPITAL,
      loanAmount = DEFAULT_LOAN_AMOUNT,
      loanInterest = DEFAULT_LOAN_INTEREST,
      loanPayments = DEFAULT_LOAN_PAYMENTS,
      difficulty = DEFAULT_DIFFICULTY
    }
  }
end

-- Challenge creation ---------------------------------------------------

local function failure(message)
  return { ok = false, msg = message }
end

-- Rounds the editor's inputs in place before validation; the defaults come from the win condition.
local function roundChallengeInput(state, challengeData)
  state.catalog.applyVariableDefaults(challengeData)

  if challengeData.economyAdjuster then
    for activityType, multiplier in pairs(challengeData.economyAdjuster) do
      challengeData.economyAdjuster[activityType] = challengeRounding.roundEconomyMultiplier(multiplier)
    end
  end

  if challengeData.loans and challengeData.loans.amount then
    challengeData.loans.amount = challengeRounding.roundLoanAmount(challengeData.loans.amount)
  end

  if challengeData.startingCapital then
    challengeData.startingCapital = challengeRounding.roundStartingCapital(challengeData.startingCapital)
  end
end

local function ensureCustomChallengeDir()
  if not FS:directoryExists(CUSTOM_CHALLENGE_DIR) then
    FS:directoryCreate(CUSTOM_CHALLENGE_DIR)
  end
end

local function copyConditionVariables(state, newChallenge, challengeData)
  local condition = state.catalog.getWinConditionById(challengeData.winCondition)
  if condition and condition.variables then
    for variableName in pairs(condition.variables) do
      if challengeData[variableName] ~= nil then
        newChallenge[variableName] = challengeData[variableName]
      end
    end
  end
end

-- Keeps only multipliers that differ from the neutral value.
local function filteredEconomyAdjuster(economyAdjuster)
  local filteredAdjuster = {}
  for activityType, multiplier in pairs(economyAdjuster) do
    if multiplier ~= DEFAULT_MULTIPLIER then
      filteredAdjuster[activityType] = challengeRounding.roundEconomyMultiplier(multiplier)
    end
  end
  return filteredAdjuster
end

-- Only essential fields are written; optional blocks appear only when they carry a value.
local function buildChallengeRecord(state, challengeData)
  local newChallenge = {}
  newChallenge.id = challengeData.id
  newChallenge.name = challengeData.name
  newChallenge.description = challengeData.description
  newChallenge.difficulty = challengeData.difficulty or DEFAULT_DIFFICULTY
  newChallenge.startingCapital = challengeData.startingCapital
  newChallenge.winCondition = challengeData.winCondition
  newChallenge.version = CHALLENGE_VERSION

  copyConditionVariables(state, newChallenge, challengeData)

  if challengeData.startingGarages and type(challengeData.startingGarages) == "table" and #challengeData.startingGarages > 0 then
    newChallenge.startingGarages = challengeData.startingGarages
  end

  if challengeData.startingGarageMode == "none" then
    newChallenge.startingGarageMode = "none"
  end

  if type(challengeData.starterVehicles) == "table" and #challengeData.starterVehicles > 0 then
    newChallenge.starterVehicles = challengeData.starterVehicles
  end

  if challengeData.map then
    newChallenge.map = challengeData.map
  end

  if challengeData.loans and challengeData.loans.amount and challengeData.loans.amount > 0 then
    newChallenge.loans = challengeData.loans
  end

  if challengeData.economyAdjuster then
    local filteredAdjuster = filteredEconomyAdjuster(challengeData.economyAdjuster)
    if next(filteredAdjuster) then
      newChallenge.economyAdjuster = filteredAdjuster
    end
  end

  return newChallenge
end

local function writeFailureMessage(pcallOk, writeResult)
  if not pcallOk and writeResult then
    return tostring(writeResult)
  end
  if not FS:directoryExists(CUSTOM_CHALLENGE_DIR) then
    return "Directory " .. tostring(CUSTOM_CHALLENGE_DIR) .. " does not exist or cannot be created"
  end
  return "Failed to save challenge file"
end

local function announceCreatedChallenge(state, newChallenge)
  guihooks.trigger('challengeCreated', {
    id = newChallenge.id,
    name = newChallenge.name,
    description = newChallenge.description or "",
    difficulty = newChallenge.difficulty or DEFAULT_DIFFICULTY,
    isLocal = true,
    startingCapital = newChallenge.startingCapital or DEFAULT_STARTING_CAPITAL,
    winConditionName = state.catalog.getWinConditionInfo(newChallenge.winCondition).name,
    map = newChallenge.map,
    hasLoans = newChallenge.loans ~= nil,
    loanAmount = newChallenge.loans and newChallenge.loans.amount or 0,
  })
end

local function createChallengeFromUI(state, challengeData)
  if not challengeData or not challengeData.id or not challengeData.name then
    return failure("Challenge must have a valid ID and name")
  end

  local idOk, idErr = state.catalog.validateChallengeId(challengeData.id)
  if not idOk then return failure(idErr) end

  roundChallengeInput(state, challengeData)

  local valid, message = state.catalog.validateChallenge(challengeData)
  if not valid then return failure(message) end

  ensureCustomChallengeDir()
  local newChallenge = buildChallengeRecord(state, challengeData)

  local filePath = CUSTOM_CHALLENGE_DIR .. "/" .. challengeData.id .. ".json"
  local pcallOk, writeResult = pcall(function()
    return jsonWriteFile(filePath, newChallenge, true)
  end)
  if not (pcallOk and writeResult) then
    return failure(writeFailureMessage(pcallOk, writeResult))
  end

  newChallenge.filePath = filePath
  newChallenge.isLocal = true
  state.catalog.storeChallenge(challengeData.id, newChallenge)
  announceCreatedChallenge(state, newChallenge)
  return { ok = true, msg = "Challenge created successfully", id = challengeData.id }
end

-- Challenge lists and single-challenge projections ---------------------

local function getChallengeOptionsForCareerCreation(state)
  local options = {}
  local allActivityTypes, currentMultipliers = availableActivityProjection(state)

  for _, challenge in pairs(state.catalog.getDiscovered()) do
    local winConditionInfo = state.catalog.getWinConditionInfo(challenge.winCondition)
    local condition = state.catalog.getWinConditionById(challenge.winCondition)

    local variables = {}
    if condition and condition.variables then
      for variableName, definition in pairs(condition.variables) do
        variables[variableName] = {
          value = challenge[variableName],
          definition = deepcopy(definition)
        }
      end
    end

    table.insert(options, {
      id = challenge.id,
      name = challenge.name,
      description = challenge.description or "",
      difficulty = challenge.difficulty or DEFAULT_DIFFICULTY,
      category = challenge.category or "",
      startingCapital = challenge.startingCapital or DEFAULT_STARTING_CAPITAL,
      hasLoans = challenge.loans ~= nil,
      loanAmount = challenge.loans and challenge.loans.amount or 0,
      loanInterest = challenge.loans and challenge.loans.interest or nil,
      loanPayments = challenge.loans and challenge.loans.payments or nil,
      winCondition = challenge.winCondition,
      winConditionName = winConditionInfo.name,
      winConditionDescription = winConditionInfo.description,
      variables = variables,
      startingGarages = challenge.startingGarages or {},
      startingGarageMode = challenge.startingGarageMode or "default",
      starterVehicles = challenge.starterVehicles or {},
      economyAdjuster = challenge.economyAdjuster or {},
      allActivityTypes = allActivityTypes,
      currentMultipliers = currentMultipliers,
      isBaseGame = challenge.isBaseGame or false,
      isLocal = challenge.isLocal or false,
      simulationTimeSpent = challenge.simulationTimeSpent or 0,
      map = challenge.map
    })
  end

  table.sort(options, function(left, right)
    local leftCategory = tostring((left and left.category) or "")
    local rightCategory = tostring((right and right.category) or "")
    if leftCategory ~= rightCategory then return leftCategory < rightCategory end
    local leftName = tostring((left and left.name) or "")
    local rightName = tostring((right and right.name) or "")
    return leftName < rightName
  end)

  return options
end

local function getChallengeDropdownData(state)
  state.catalog.discoverChallenges()
  return {
    editorData = getChallengeEditorData(state),
    challenges = getChallengeOptionsForCareerCreation(state)
  }
end

local function getChallengeListLight(state)
  state.catalog.discoverChallenges()

  local list = {}
  for _, challenge in pairs(state.catalog.getDiscovered()) do
    local winConditionInfo = state.catalog.getWinConditionInfo(challenge.winCondition)
    table.insert(list, {
      id = challenge.id,
      name = challenge.name,
      difficulty = challenge.difficulty or DEFAULT_DIFFICULTY,
      description = challenge.description or "",
      isLocal = challenge.isLocal or false,
      startingCapital = challenge.startingCapital or DEFAULT_STARTING_CAPITAL,
      winConditionName = winConditionInfo.name,
      map = challenge.map,
      hasLoans = challenge.loans ~= nil,
      loanAmount = challenge.loans and challenge.loans.amount or 0,
    })
  end

  table.sort(list, function(left, right)
    return (left.name or "") < (right.name or "")
  end)

  return list
end

local function getChallengeDropdownDataLight(state)
  state.catalog.discoverChallenges()
  return {
    challenges = getChallengeListLight(state),
    editorData = getEditorDataLight(state)
  }
end

local function getSingleChallengeForUI(state, challengeId)
  if not challengeId then return nil end

  local challenge = state.catalog.getDiscovered()[challengeId]
  if not challenge then return nil end

  local winConditionInfo = state.catalog.getWinConditionInfo(challenge.winCondition)
  return {
    id = challenge.id,
    name = challenge.name,
    description = challenge.description or "",
    difficulty = challenge.difficulty or DEFAULT_DIFFICULTY,
    category = challenge.category or "",
    startingCapital = challenge.startingCapital or DEFAULT_STARTING_CAPITAL,
    hasLoans = challenge.loans ~= nil,
    loanAmount = challenge.loans and challenge.loans.amount or 0,
    loanInterest = challenge.loans and challenge.loans.interest or nil,
    loanPayments = challenge.loans and challenge.loans.payments or nil,
    winCondition = challenge.winCondition,
    winConditionName = winConditionInfo.name,
    winConditionDescription = winConditionInfo.description,
    isLocal = challenge.isLocal or false,
    map = challenge.map,
    startingGarages = challenge.startingGarages or {},
    startingGarageMode = challenge.startingGarageMode or "default",
    starterVehicles = challenge.starterVehicles or {}
  }
end

-- Seed encoding and decoding -------------------------------------------

local function encodeChallengeSafe(state, challenge)
  local encoder = state.getSeedEncoder()
  if not encoder then
    return nil, "Seed encoder not available"
  end
  local ok, seed, err = pcall(encoder.encodeChallengeToSeed, challenge)
  if not ok then
    return nil, "Encoding error: " .. tostring(seed)
  end
  if not seed then
    return nil, err or "Failed to encode seed"
  end
  return seed
end

local function getChallengeSeeded(state, challengeId)
  local challenge = state.catalog.getDiscovered()[challengeId]
  if not challenge then
    return nil, "Challenge not found"
  end
  return encodeChallengeSafe(state, challenge)
end

local function decodeSeedToChallengeData(state, seed)
  local encoder = state.getSeedEncoder()
  if not encoder then
    return false, "Seed encoder not available"
  end

  local ok, decoded, err = pcall(encoder.decodeSeedToChallenge, seed)
  if not ok then
    return false, "Invalid seed: " .. tostring(decoded)
  end
  if not decoded then
    return false, err or "Failed to decode seed"
  end

  local resolveOk, resolved, resolveErr = pcall(encoder.resolveHashesToNames, decoded)
  if not resolveOk then
    return false, "Failed to resolve seed data: " .. tostring(resolved)
  end
  if not resolved then
    return false, resolveErr or "Failed to resolve seed data"
  end

  return true, resolved
end

local function requestChallengeDataForEdit(state, challengeId)
  local challenge = state.catalog.getDiscovered()[challengeId]
  if not challenge then
    guihooks.trigger('challengeEditDataResponse', {
      challengeId = challengeId,
      success = false,
      error = "Challenge not found"
    })
    return
  end

  -- Seed round-trips lose unresolved fields and snap values, so the seed is attached separately.
  local data = {}
  for key, value in pairs(challenge) do
    if not NON_EDITABLE_FIELDS[key] then
      data[key] = deepcopy(value)
    end
  end
  data.id = challenge.id
  data.name = challenge.name
  data.description = challenge.description or ""
  data.difficulty = challenge.difficulty or DEFAULT_DIFFICULTY
  state.catalog.applyVariableDefaults(data)

  local seed = encodeChallengeSafe(state, challenge)
  if seed then
    data.seed = seed
  end

  guihooks.trigger('challengeEditDataResponse', {
    challengeId = challengeId,
    success = true,
    data = data
  })
end

local function deleteChallenge(state, challengeId)
  local challenge = state.catalog.getDiscovered()[challengeId]
  if not challenge then
    return false, "Challenge not found"
  end

  if not challenge.isLocal then
    return false, "Can only delete local challenges"
  end

  if not challenge.filePath then
    return false, "Challenge file path not found"
  end

  if FS:fileExists(challenge.filePath) then
    if not FS:remove(challenge.filePath) then
      return false, "Failed to delete challenge file"
    end
  end

  -- Remove from cache instead of re-scanning
  state.catalog.forgetChallenge(challengeId)
  return true, "Challenge deleted successfully"
end

local function createChallengeFromSeedUI(state, seed, name, description)
  if not seed or seed == "" then
    return false, "No seed provided", nil
  end

  local encoder = state.getSeedEncoder()
  if not encoder then
    return false, "Seed encoder not available", nil
  end

  local ok, result = pcall(encoder.createChallengeFromSeed, seed, name, description)
  if not ok then
    return false, "Invalid seed: " .. tostring(result), nil
  end
  if type(result) ~= "table" then
    return false, "Failed to create challenge from seed", nil
  end
  return result.ok == true, result.msg, result.id
end

local function encodeChallengeDataToSeed(state, challengeData)
  local payload = deepcopy(state.catalog.challengeTemplate)
  payload.id = payload.id ~= "" and payload.id or "seedTemplate"
  payload.name = payload.name ~= "" and payload.name or "Seed Template"
  payload.description = payload.description or ""
  payload.category = payload.category or "custom"

  for key, value in pairs(challengeData or {}) do
    if value ~= nil then
      payload[key] = value
    end
  end

  local seed, err = encodeChallengeSafe(state, payload)
  if not seed then
    return false, err
  end
  return true, seed
end

local function requestGenerateRandomSeed(state, options)
  options = options or {}

  local encoder = state.getSeedEncoder()
  if not encoder then
    guihooks.trigger('challengeSeedGenerated', {
      success = false,
      error = "Seed encoder not available"
    })
    return
  end

  local ok, seed, data = pcall(encoder.generateRandomSeed, options)
  if not ok or not seed then
    local err = not ok and ("Failed to generate seed: " .. tostring(seed)) or data
    guihooks.trigger('challengeSeedGenerated', {
      success = false,
      error = err or "Failed to generate seed"
    })
    return
  end

  guihooks.trigger('challengeSeedGenerated', {
    success = true,
    seed = seed,
    data = data
  })
end

local function generateRandomChallengeData(state, options)
  options = options or {}
  local encoder = state.getSeedEncoder()
  if not encoder then
    return false, "Seed encoder not available"
  end

  local data, err = encoder.generateRandomChallengeData(options)
  if not data then
    return false, err or "Failed to generate challenge data"
  end

  return true, data
end

local function requestSeedEncode(state, requestId, challengeData)
  local ok, seedOrErr = encodeChallengeDataToSeed(state, challengeData)
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

local function requestSeedDecode(state, requestId, seed)
  local ok, dataOrErr = decodeSeedToChallengeData(state, seed)
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

local function requestChallengeSeeded(state, challengeId)
  local challenge = state.catalog.getDiscovered()[challengeId]
  if not challenge then
    guihooks.trigger('challengeSeedResponse', {
      challengeId = challengeId,
      success = false,
      error = "Challenge not found"
    })
    return
  end

  local seed, err = encodeChallengeSafe(state, challenge)
  if not seed then
    guihooks.trigger('challengeSeedResponse', {
      challengeId = challengeId,
      success = false,
      error = err
    })
    return
  end

  guihooks.trigger('challengeSeedResponse', {
    challengeId = challengeId,
    success = true,
    seed = seed
  })
end

-- Lifecycle ------------------------------------------------------------

-- Public API. Every function takes the editor state first; bind() supplies it, so callers see plain functions.
function M.create(ctx, catalog)
  local state = {
    getSeedEncoder = ctx.getSeedEncoder,
    catalog = catalog,
    taxonomy = nil,
  }

  local function bind(fn)
    return function(...) return fn(state, ...) end
  end

  return {
    getAvailableGarages = getAvailableGarages,
    getAvailableStarterVehicles = challengeStartRules.getAvailableStarterVehicles,
    getChallengeEditorData = bind(getChallengeEditorData),
    createChallengeFromUI = bind(createChallengeFromUI),
    getChallengeOptionsForCareerCreation = bind(getChallengeOptionsForCareerCreation),
    getChallengeDropdownData = bind(getChallengeDropdownData),
    getChallengeListLight = bind(getChallengeListLight),
    getChallengeDropdownDataLight = bind(getChallengeDropdownDataLight),
    getSingleChallengeForUI = bind(getSingleChallengeForUI),
    getChallengeSeeded = bind(getChallengeSeeded),
    decodeSeedToChallengeData = bind(decodeSeedToChallengeData),
    requestChallengeDataForEdit = bind(requestChallengeDataForEdit),
    deleteChallenge = bind(deleteChallenge),
    createChallengeFromSeedUI = bind(createChallengeFromSeedUI),
    encodeChallengeDataToSeed = bind(encodeChallengeDataToSeed),
    requestGenerateRandomSeed = bind(requestGenerateRandomSeed),
    generateRandomChallengeData = bind(generateRandomChallengeData),
    requestSeedEncode = bind(requestSeedEncode),
    requestSeedDecode = bind(requestSeedDecode),
    requestChallengeSeeded = bind(requestChallengeSeeded),
  }
end

return M
