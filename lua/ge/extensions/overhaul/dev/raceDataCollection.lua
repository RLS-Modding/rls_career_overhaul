-- Race data collection: records power, weight, year and time of freeroam race runs and fits models to them.
-- Collection runs only with a valid dev key; analyzeData writes the fitted models that tuning shop generation reads.
local raceDataCatalog = require("overhaul/lib/events/raceDataCatalog")
local devScope = require("overhaul/lib/lifecycle/scopes/dev")

local M = {}

-- Config ------------------------------------------------------------------------------------------

local LOG_TAG = "dataCollection"
local DATA_DIRECTORY = "settings/RLS/FREs"
local MIN_P2W_SAMPLES = 3
local MIN_POWER_WEIGHT_YEAR_SAMPLES = 7
local FEATURE_COUNT = 7
local SINGULAR_PIVOT = 1e-10
local P2W_EXPONENT_MIN, P2W_EXPONENT_MAX, P2W_EXPONENT_STEP = 0.1, 1.5, 0.01

-- State -------------------------------------------------------------------------------------------

local isCollectingDataEnabled = false
local pendingDataEntries = {}
local races = nil

-- Helpers -----------------------------------------------------------------------------------------

local function getYear(data)
  local year
  local years = data.Years
  if years then
    if type(years) == "table" and years.min and years.max then
      year = math.floor((years.min + years.max) / 2)
    elseif type(years) == "number" then
      year = years
    end
  elseif data.Year then
    year = data.Year
  end
  return year
end

-- Model year from the vehicle model data; 2000 when unknown.
local function getYearFromModel(modelKey)
  local year

  if modelKey then
    local modelData = core_vehicles.getModel(modelKey)
    if modelData and modelData.model then
      year = getYear(modelData.model)
      if not year then
        local configs = modelData.configs
        for key, config in pairs(configs) do
          year = getYear(config)
          if year then break end
        end
      end
    end
  end

  return year or 2000
end

-- Predicted race time from fitted coefficients (predictCoefNew first, else predictCoef); nil
-- without coefficients.
local function predictRaceTime(power, weight, year, coefficients)
  if not coefficients then return nil end

  if coefficients.predictCoefNew then
    local quadraticCoefficients = coefficients.predictCoefNew
    local normalizePower = function(inputPower)
      return (inputPower - quadraticCoefficients.powerMin)
        / (quadraticCoefficients.powerMax - quadraticCoefficients.powerMin)
    end
    local normalizeWeight = function(inputWeight)
      return (inputWeight - quadraticCoefficients.weightMin)
        / (quadraticCoefficients.weightMax - quadraticCoefficients.weightMin)
    end
    local normalizeYear = function(inputYear)
      return (inputYear - quadraticCoefficients.yearMin)
        / (quadraticCoefficients.yearMax - quadraticCoefficients.yearMin)
    end

    local normalizedPower = normalizePower(power)
    local normalizedWeight = normalizeWeight(weight)
    local normalizedYear = normalizeYear(year)

    local time = quadraticCoefficients.a
      + quadraticCoefficients.b * normalizedPower
      + quadraticCoefficients.c * normalizedWeight
      + quadraticCoefficients.d * normalizedYear
      + quadraticCoefficients.e * normalizedPower * normalizedPower
      + quadraticCoefficients.f * normalizedWeight * normalizedWeight
      + quadraticCoefficients.g * normalizedYear * normalizedYear

    return time
  elseif coefficients.predictCoef then
    local legacyCoefficients = coefficients.predictCoef
    local powerToWeight = power / weight
    local clampedPowerToWeight = math.max(0.001, powerToWeight)
    local time = legacyCoefficients.a + legacyCoefficients.b / (clampedPowerToWeight ^ legacyCoefficients.c)
    return time
  end

  return nil
end


local function ensureDirectoryExists(dirPath)
  if not FS:directoryExists(dirPath) then FS:directoryCreate(dirPath, true) end
end

local function loadLevelRaces()
  if getCurrentLevelIdentifier() then
    return deepcopy(raceDataCatalog.loadRaces(getCurrentLevelIdentifier()))
  end
  return {}
end

local function getRaces()
  if not races then races = loadLevelRaces() end
  return races
end

local function labelForRoute(race, isAltRoute)
  if isAltRoute and race.altRoute then return race.altRoute.label end
  return race.label
end

-- Hotlap labels carry a " (Hotlap)" suffix that the race label does not.
local function getRaceNameFromLabel(raceLabel, isAltRoute, isHotlap)
  local raceTable = getRaces()
  if not raceTable then return nil end

  local baseLabel = raceLabel
  if isHotlap then baseLabel = baseLabel:gsub(" %(Hotlap%)$", "") end

  for raceName, race in pairs(raceTable) do
    if labelForRoute(race, isAltRoute) == baseLabel then return raceName end
  end
  return nil
end

-- Vehicle identity --------------------------------------------------------------------------------

local function lastUnderscoreIndex(text)
  for i = #text, 1, -1 do
    if text:sub(i, i) == "_" then return i end
  end
  return 0
end

-- Business vehicle ids read "business_<businessId>_<vehicleId>"; without a spawned car the player's car stands in.
local function vehicleIdFromBusinessIdentifier(identifier)
  local lastUnderscore = lastUnderscoreIndex(identifier)
  if lastUnderscore <= 10 then return be:getPlayerVehicleID(0) end

  local businessId = identifier:sub(10, lastUnderscore - 1)
  local vehicleId = tonumber(identifier:sub(lastUnderscore + 1))
  local fleet = overhaul_career_business_fleet
  if not (businessId and vehicleId and fleet) then return be:getPlayerVehicleID(0) end
  return fleet.getSpawnedVehicleId(businessId, vehicleId) or be:getPlayerVehicleID(0)
end

local function getVehicleIdFromEntry(entry)
  local vehId = entry.inventoryId
  if vehId and type(vehId) == "string" and vehId:match("^business_") then
    vehId = vehicleIdFromBusinessIdentifier(vehId)
  elseif overhaul_career_career and overhaul_career_career.isActive() and overhaul_career_garage_inventory then
    vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(vehId) or vehId
  end
  return vehId or be:getPlayerVehicleID(0)
end

-- Sample collection -------------------------------------------------------------------------------

-- Samples for one race (or its alternate route) append to that race's JSON file.
local function appendRaceSample(raceName, isAltRoute, sample)
  ensureDirectoryExists(DATA_DIRECTORY)

  local fileName = raceName
  if isAltRoute then fileName = raceName .. "_alt" end
  local filePath = DATA_DIRECTORY .. "/" .. fileName .. ".json"
  local existingData = jsonReadFile(filePath)
  if not existingData or type(existingData) ~= "table" then existingData = {} end

  table.insert(existingData, sample)
  jsonWriteFile(filePath, existingData, true)
end

local function onVehicleRaceDataCollected(vehId, power, weight, year, raceName, time, isAltRoute)
  log('D', LOG_TAG, "onVehicleRaceDataCollected: " .. tostring(vehId) .. " power:" .. tostring(power) .. " weight:" .. tostring(weight) ..
    " year:" .. tostring(year) .. " " .. tostring(raceName) .. " time:" .. tostring(time))
  local key = tostring(vehId) .. "_" .. tostring(raceName) .. "_" .. tostring(time)
  if not pendingDataEntries[key] then return end

  if not power or not weight or not year or not time or power <= 0 or weight <= 0 then
    pendingDataEntries[key] = nil
    return
  end

  appendRaceSample(raceName, isAltRoute, { power = power, weight = weight, year = year, time = time })
  pendingDataEntries[key] = nil
end

local function onVehicleModelReceived(vehId, power, weight, model, raceName, time, isAltRoute)
  onVehicleRaceDataCollected(vehId, power, weight, getYearFromModel(model), raceName, time, isAltRoute)
end

-- Asks the vehicle for its engine power, mass and model; the reply comes back through onVehicleModelReceived.
local function collectVehicleRaceData(entry)
  if not isCollectingDataEnabled then return end
  local inventoryId = entry.inventoryId
  if not inventoryId then return end

  local raceLabel = entry.raceLabel
  local time = entry.time
  if not raceLabel or not time then return end

  local raceName = entry.raceName or getRaceNameFromLabel(raceLabel, entry.isAltRoute, entry.isHotlap)
  if not raceName then return end

  local vehId = getVehicleIdFromEntry(entry)
  if not vehId then return end

  local vehObj = getObjectByID(vehId)
  if not vehObj then vehObj = be:getPlayerVehicle(0) end
  if not vehObj then return end

  local key = tostring(vehId) .. "_" .. tostring(raceName) .. "_" .. tostring(time)
  pendingDataEntries[key] = { raceName = raceName, time = time, isAltRoute = entry.isAltRoute or false }

  log('D', LOG_TAG, "collectVehicleRaceData: Querying vehicle for power/weight/year - " .. raceName .. " time:" .. time)

  local luaCommand = [[
            local engine = powertrain.getDevicesByCategory("engine")[1]
            if engine then
                local power = engine.maxPower
                local weight = obj:calcBeamStats().total_weight
                if power and weight and weight > 0 then
                    local model = v.config.model or ""
                    obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(]] .. require('overhaul/lib/vehicles/callbacks').open('raceDataVehicleModel', {owner = 'raceData', vehId = vehObj:getID()}) .. [[, 'raceDataVehicleModel', "]] ..
    tostring(vehId) .. [[, " .. power .. ", " .. weight .. ", '" .. model .. "', ']] ..
    raceName .. [[', ]] .. tostring(time) .. [[, ]] ..
    tostring(entry.isAltRoute or false) .. [["))
                end
            end
        ]]
  vehObj:queueLuaCommand(luaCommand)
end

-- Model fitting -----------------------------------------------------------------------------------

-- A sample gives a power-to-weight ratio and a time, either stored directly or derived from power and weight.
local function powerToWeightSample(sample)
  if sample.p2w and sample.time then return sample.p2w, sample.time end
  if sample.power and sample.weight and sample.time then return sample.power / sample.weight, sample.time end
  return nil
end

-- Least-squares fit of time = a + b * x with x = 1 / ratio^c for one exponent c; nil when it is degenerate.
local function fitPowerToWeightExponent(samples, c)
  local n, sumX, sumY, sumXX, sumXY = 0, 0, 0, 0, 0
  for _, sample in ipairs(samples) do
    local ratio, time = powerToWeightSample(sample)
    if ratio and time and ratio > 0 then
      local x = 1 / (ratio ^ c)
      sumX = sumX + x
      sumY = sumY + time
      sumXX = sumXX + x * x
      sumXY = sumXY + x * time
      n = n + 1
    end
  end
  if n < MIN_P2W_SAMPLES then return nil end

  local denom = n * sumXX - sumX * sumX
  if denom == 0 then return nil end
  local b = (n * sumXY - sumX * sumY) / denom
  local a = (sumY - b * sumX) / n

  local err = 0
  for _, sample in ipairs(samples) do
    local ratio, time = powerToWeightSample(sample)
    if ratio and time and ratio > 0 then
      local x = 1 / (ratio ^ c)
      local diff = time - (a + b * x)
      err = err + diff * diff
    end
  end
  return { a = a, b = b, c = c, err = err }
end

-- Keeps the exponent with the smallest error whose slope is positive.
local function fitPowerToWeightModel(samples)
  if not samples or #samples < MIN_P2W_SAMPLES then return nil, "not_enough_samples" end

  local best = { err = math.huge, a = 0, b = 0, c = 0 }
  for c = P2W_EXPONENT_MIN, P2W_EXPONENT_MAX, P2W_EXPONENT_STEP do
    local fit = fitPowerToWeightExponent(samples, c)
    if fit and fit.b > 0 and fit.err < best.err then best = fit end
  end

  if best.err == math.huge then return nil, "fit_failed" end
  return { a = best.a, b = best.b, c = best.c, err = best.err }
end

-- Keeps only samples with positive power and weight, as parallel value lists.
local function validPowerWeightYearColumns(samples)
  local columns = { power = {}, weight = {}, year = {}, time = {} }
  for _, sample in ipairs(samples) do
    if sample.power and sample.weight and sample.year and sample.time and sample.power > 0 and sample.weight > 0 then
      table.insert(columns.power, sample.power)
      table.insert(columns.weight, sample.weight)
      table.insert(columns.year, sample.year)
      table.insert(columns.time, sample.time)
    end
  end
  return columns
end

local function rangeOf(values)
  local low, high = math.huge, -math.huge
  for _, value in ipairs(values) do
    if value < low then low = value end
    if value > high then high = value end
  end
  return low, high
end

-- One design row: intercept, the three normalized inputs, then their squares.
local function designRow(p, w, y)
  return { 1, p, w, y, p * p, w * w, y * y }
end

-- Reject singular fits instead of emitting unusable coefficients.
local function solveNormalEquations(featureRows, targetTimes, n)
  local XtX, XtY = {}, {}
  for i = 1, FEATURE_COUNT do
    XtX[i] = {}
    for j = 1, FEATURE_COUNT do
      XtX[i][j] = 0
      for k = 1, n do XtX[i][j] = XtX[i][j] + featureRows[k][i] * featureRows[k][j] end
    end
  end
  for i = 1, FEATURE_COUNT do
    XtY[i] = 0
    for k = 1, n do XtY[i] = XtY[i] + featureRows[k][i] * targetTimes[k] end
  end

  for i = 1, FEATURE_COUNT do
    local pivot = XtX[i][i]
    if math.abs(pivot) < SINGULAR_PIVOT then return nil end
    for j = i + 1, FEATURE_COUNT do
      local factor = XtX[j][i] / pivot
      for k = i, FEATURE_COUNT do XtX[j][k] = XtX[j][k] - factor * XtX[i][k] end
      XtY[j] = XtY[j] - factor * XtY[i]
    end
  end

  local coef = {}
  for i = FEATURE_COUNT, 1, -1 do
    coef[i] = XtY[i]
    for j = i + 1, FEATURE_COUNT do coef[i] = coef[i] - XtX[i][j] * coef[j] end
    coef[i] = coef[i] / XtX[i][i]
  end
  return coef
end

local function residualSumSquares(featureRows, targetTimes, coef, n)
  local err = 0
  for i = 1, n do
    local pred = coef[1] + coef[2] * featureRows[i][2] + coef[3] * featureRows[i][3] + coef[4] * featureRows[i][4]
      + coef[5] * featureRows[i][5] + coef[6] * featureRows[i][6] + coef[7] * featureRows[i][7]
    local diff = targetTimes[i] - pred
    err = err + diff * diff
  end
  return err
end

-- Fits time against power, weight and year, each normalized to its range in the samples.
local function fitPowerWeightYearModel(samples)
  if not samples or #samples < MIN_POWER_WEIGHT_YEAR_SAMPLES then return nil, "not_enough_samples" end

  local columns = validPowerWeightYearColumns(samples)
  local n = #columns.power
  if n < MIN_POWER_WEIGHT_YEAR_SAMPLES then return nil, "not_enough_valid_samples" end

  local powerMin, powerMax = rangeOf(columns.power)
  local weightMin, weightMax = rangeOf(columns.weight)
  local yearMin, yearMax = rangeOf(columns.year)
  if powerMax == powerMin or weightMax == weightMin or yearMax == yearMin then
    return nil, "no_variation_in_data"
  end

  local featureRows, targetTimes = {}, {}
  for i = 1, n do
    local p = (columns.power[i] - powerMin) / (powerMax - powerMin)
    local w = (columns.weight[i] - weightMin) / (weightMax - weightMin)
    local y = (columns.year[i] - yearMin) / (yearMax - yearMin)
    featureRows[i] = designRow(p, w, y)
    targetTimes[i] = columns.time[i]
  end

  local coef = solveNormalEquations(featureRows, targetTimes, n)
  if not coef then return nil, "singular_matrix" end

  return {
    a = coef[1], b = coef[2], c = coef[3], d = coef[4], e = coef[5], f = coef[6], g = coef[7],
    err = residualSumSquares(featureRows, targetTimes, coef, n),
    powerMin = powerMin, powerMax = powerMax,
    weightMin = weightMin, weightMax = weightMax,
    yearMin = yearMin, yearMax = yearMax,
  }
end

-- Analysis ----------------------------------------------------------------------------------------

local function analysisPathFor(levelIdentifier)
  return DATA_DIRECTORY .. "/analysis/" .. levelIdentifier .. "/race_data.json"
end

local function newPredictCoefNew(coefNew)
  return {
    a = coefNew.a, b = coefNew.b, c = coefNew.c, d = coefNew.d, e = coefNew.e, f = coefNew.f, g = coefNew.g,
    powerMin = coefNew.powerMin, powerMax = coefNew.powerMax,
    weightMin = coefNew.weightMin, weightMax = coefNew.weightMax,
    yearMin = coefNew.yearMin, yearMax = coefNew.yearMax,
  }
end

-- Alternate-route samples fit the alternate route; main-route samples fit the race itself.
local function fitTargetFor(race, isAltRoute)
  if isAltRoute then return race.altRoute end
  return race
end

-- Returns true when the race (or its alternate route) received fitted coefficients.
local function fitRaceSamples(race, isAltRoute, samples)
  local coefOld = fitPowerToWeightModel(samples)
  local coefNew = fitPowerWeightYearModel(samples)
  local target = fitTargetFor(race, isAltRoute)
  if not (coefOld and target) then return false end

  target.predictCoef = { a = coefOld.a, b = coefOld.b, c = coefOld.c }
  if coefNew then target.predictCoefNew = newPredictCoefNew(coefNew) end
  return true
end

-- Sample files are "<race>.json", or "<race>_alt.json" for the alternate route.
local function fitSampleFile(races, filePath)
  local _, filename = path.split(filePath)
  local baseName = string.sub(filename, 1, -6)
  local isAltRoute = string.sub(baseName, -4) == "_alt"
  local raceName = isAltRoute and string.sub(baseName, 1, -5) or baseName

  local race = races[raceName]
  if not race then return false end
  local samples = jsonReadFile(filePath)
  if not (samples and type(samples) == "table" and #samples > 0) then return false end
  return fitRaceSamples(race, isAltRoute, samples)
end

local function analyzeData()
  local levelIdentifier = getCurrentLevelIdentifier()
  if not levelIdentifier then return false, "no_level" end
  if not FS:directoryExists(DATA_DIRECTORY) then return false, "no_data_directory" end

  local raceData = raceDataCatalog.read("levels/" .. levelIdentifier .. "/race_data.json")
  if not raceData or not raceData.races then return false, "no_race_data" end

  local files = FS:findFiles(DATA_DIRECTORY, "*.json", 0, false, false)
  if not files or #files == 0 then return false, "no_data_files" end

  local updated = false
  for _, filePath in ipairs(files) do
    if fitSampleFile(raceData.races, filePath) then updated = true end
  end
  if not updated then return false, "no_updates" end

  local analysisPath = analysisPathFor(levelIdentifier)
  ensureDirectoryExists(analysisPath:match("^(.*)/[^/]+$"))
  jsonWriteFile(analysisPath, raceData, true)
  log("I", LOG_TAG, "Saved fitted race data to " .. analysisPath)
  return true, analysisPath
end

-- Lifecycle ---------------------------------------------------------------------------------------

-- Collection starts on by default for a valid dev key.
local function enableCollectionIfDevKeyValid()
  if not devScope.isKeyValid() then return end
  isCollectingDataEnabled = true
  log('D', LOG_TAG, "Data collection enabled by default (dev mode active)")
end

-- Public API --------------------------------------------------------------------------------------

local function collectDataFromEntry(entry)
  if not entry then return end
  collectVehicleRaceData(entry)
end

local function collectData(enabled)
  isCollectingDataEnabled = enabled or false
end

local function isCollectingData()
  return isCollectingDataEnabled
end

M.onVehicleRaceDataCollected = onVehicleRaceDataCollected
M.onVehicleModelReceived = onVehicleModelReceived
M.collectDataFromEntry = collectDataFromEntry
M.collectData = collectData
M.isCollectingData = isCollectingData
M.analyzeData = analyzeData
M.getYearFromModel = getYearFromModel
M.predictRaceTime = predictRaceTime

-- Game hooks --------------------------------------------------------------------------------------

-- A new world forgets the cached race table; collection follows the dev key again.
function M.onWorldReadyState(worldReadyState)
  if worldReadyState ~= 2 then return end
  races = nil
  enableCollectionIfDevKeyValid()
end

function M.onExtensionLoaded()
  enableCollectionIfDevKeyValid()
end

return M
