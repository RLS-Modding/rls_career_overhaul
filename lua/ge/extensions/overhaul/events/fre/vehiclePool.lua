-- Vehicle model lookups for freeroam contracts: validity, ownership, discipline eligibility and best event times.
-- Owns the cached model list; contract offers pick their required model through it.
local M = {}
local freHelpers = require("overhaul/events/fre/helpers")

local freConfig = require("overhaul/events/freConfig")
local core_vehicles = require("core/vehicles")

local cachedModelList = nil

-- Vehicle model discovery ---------------------------------------------------------------------------

local function getModelListCached()
  if cachedModelList then return cachedModelList end
  if not core_vehicles or not core_vehicles.getModelList then return {} end
  cachedModelList = core_vehicles.getModelList() or {}
  return cachedModelList
end

local function getModelInfo(modelKey)
  if not core_vehicles or type(modelKey) ~= "string" or modelKey == "" then return nil end
  local modelList = getModelListCached()
  local models = modelList.models or {}
  if type(models[modelKey]) == "table" then return models[modelKey] end
  local lower = string.lower(modelKey)
  if type(models[lower]) == "table" then return models[lower] end
  for key, info in pairs(models) do
    if type(key) == "string" and string.lower(key) == lower and type(info) == "table" then return info end
  end
  return nil
end

local function isTrailerVehicleModel(modelInfo)
  if type(modelInfo) ~= "table" then return false end

  local hints = {
    modelInfo.Type,
    modelInfo.type,
    modelInfo.Category,
    modelInfo.category,
    modelInfo.Class,
    modelInfo.class,
  }

  for _, hint in ipairs(hints) do
    local value = string.lower(tostring(hint or ""))
    if value ~= "" and string.find(value, "trailer", 1, true) then return true end
  end

  return false
end

local function isValidVehicleModelKey(modelKey)
  local normalized = type(modelKey) == "string" and string.lower(modelKey) or nil
  if not normalized or normalized == "" then return false end

  if core_vehicles and core_vehicles.getModelList then
    local modelInfo = getModelInfo(normalized)
    if not modelInfo then return false end
    if isTrailerVehicleModel(modelInfo) then return false end
    local typeHint =
      string.lower(tostring(modelInfo.Type or modelInfo.type or modelInfo.Category or modelInfo.category or ""))
    local classHint = string.lower(tostring(modelInfo.Class or modelInfo.class or ""))
    if string.find(typeHint, "prop", 1, true) or string.find(typeHint, "device", 1, true) then return false end
    if string.find(classHint, "prop", 1, true) or string.find(classHint, "device", 1, true) then return false end
  end

  return true
end

local function getOwnedVehicleModels()
  local models = {}
  local seen = {}
  local vehicles = overhaul_career_garage_inventory
      and overhaul_career_garage_inventory.getVehicles
      and overhaul_career_garage_inventory.getVehicles()
    or {}
  for _, vehicle in pairs(vehicles or {}) do
    local model = type(vehicle.model) == "string" and string.lower(vehicle.model) or nil
    if model and model ~= "" and isValidVehicleModelKey(model) and not seen[model] then
      seen[model] = true
      table.insert(models, model)
    end
  end
  return models
end

local function getKnownVehicleModels()
  local models = {}
  local seen = {}

  local modelList = getModelListCached()
  local source = modelList.models or {}
  for modelKey, _ in pairs(source) do
    if type(modelKey) == "string" and modelKey ~= "" then
      local key = string.lower(modelKey)
      if isValidVehicleModelKey(key) and not seen[key] then
        seen[key] = true
        table.insert(models, key)
      end
    end
  end

  return models
end

local function getConfiguredContractModels()
  local models = {}
  local seen = {}
  for _, model in ipairs(freConfig.getContractVehicleModels() or {}) do
    local key = type(model) == "string" and string.lower(model) or nil
    if key and key ~= "" and isValidVehicleModelKey(key) and not seen[key] then
      seen[key] = true
      table.insert(models, key)
    end
  end
  return models
end

-- Model labels and contract eligibility -------------------------------------------------------------

local function prettifyModelKey(modelKey)
  if type(modelKey) ~= "string" or modelKey == "" then return "Unknown Model" end
  local words = {}
  for token in modelKey:gsub("_", " "):gmatch("%S+") do
    local trimmedToken = token:gsub("%d+$", "")
    if trimmedToken == "" then trimmedToken = token end
    local first = trimmedToken:sub(1, 1)
    local rest = trimmedToken:sub(2)
    table.insert(words, string.upper(first) .. string.lower(rest))
  end
  return #words > 0 and table.concat(words, " ") or modelKey
end

local function getModelDisplayName(modelKey)
  local normalized = type(modelKey) == "string" and string.lower(modelKey) or nil
  if not normalized or normalized == "" then return "Unknown Model" end

  local modelInfo = getModelInfo(normalized)
  if modelInfo then
    local modelName = modelInfo.Name or modelInfo.name
    if type(modelName) == "string" and modelName ~= "" then return modelName end
  end

  return prettifyModelKey(normalized)
end

local function buildVehicleBlacklistLookup(disciplineId)
  local lookup = {}
  for _, model in ipairs(freConfig.getContractVehicleBlacklist(disciplineId) or {}) do
    if type(model) == "string" and model ~= "" then lookup[string.lower(model)] = true end
  end
  return lookup
end

local function filterModelPool(models, blacklistLookup)
  local filtered = {}
  local seen = {}
  for _, model in ipairs(models or {}) do
    local normalized = type(model) == "string" and string.lower(model) or nil
    if normalized and normalized ~= "" and not blacklistLookup[normalized] and not seen[normalized] then
      seen[normalized] = true
      table.insert(filtered, normalized)
    end
  end
  return filtered
end

local function getContractVehicleConfigTypeWhitelistLookup(disciplineId)
  local cfg = freConfig.getContractConfig(disciplineId)
  local wl = cfg and cfg.contractVehicleConfigTypeWhitelist
  if type(wl) ~= "table" then return nil end
  local lookup = {}
  for _, entry in ipairs(wl) do
    if type(entry) == "string" and entry ~= "" then lookup[string.lower(entry)] = true end
  end
  if not next(lookup) then return nil end
  return lookup
end

local function modelHasWhitelistedConfigType(normalizedModelKey, lookup)
  if not lookup then return false end
  local modelInfo = getModelInfo(normalizedModelKey)
  local configTypes = modelInfo and modelInfo.aggregates and modelInfo.aggregates["Config Type"]
  if type(configTypes) ~= "table" then return false end
  for configType, available in pairs(configTypes) do
    if available and type(configType) == "string" and lookup[string.lower(configType)] then return true end
  end
  return false
end

local function leaderboardEntryHasStats(entry)
  return type(entry) == "table" and (entry.time or entry.driftScore or entry.topSpeed or entry.pullDistance)
end

local function getDisciplineRaceLabels(disciplineId)
  local rCache = overhaul_events_fre_raceCache
  if not rCache or not rCache.refreshRaceCache then return {} end
  local cache = rCache.refreshRaceCache()
  local list = (cache and cache.byDiscipline or {})[disciplineId] or {}
  local labels = {}
  local seen = {}
  for _, raceEntry in ipairs(list) do
    local lbl = raceEntry.raceLabel
    if type(lbl) == "string" and lbl ~= "" and not seen[lbl] then
      seen[lbl] = true
      labels[#labels + 1] = lbl
    end
  end
  return labels
end

local function ownedModelHasDisciplineLeaderboard(disciplineId, modelKey)
  local normalized = type(modelKey) == "string" and string.lower(modelKey) or nil
  if not normalized then return false end
  local labels = getDisciplineRaceLabels(disciplineId)
  if #labels == 0 then return false end
  local lb = overhaul_events_leaderboards
  if not lb or type(lb.getLeaderboardEntry) ~= "function" then return false end
  local vehicles = overhaul_career_garage_inventory
      and overhaul_career_garage_inventory.getVehicles
      and overhaul_career_garage_inventory.getVehicles()
    or {}
  for invId, vehicle in pairs(vehicles) do
    local vm = type(vehicle.model) == "string" and string.lower(vehicle.model) or nil
    if vm == normalized then
      for _, raceLabel in ipairs(labels) do
        if leaderboardEntryHasStats(lb.getLeaderboardEntry(invId, raceLabel)) then return true end
      end
    end
  end
  return false
end

local function contractModelPassesConfigWhitelist(disciplineId, normalizedModelKey)
  local lookup = getContractVehicleConfigTypeWhitelistLookup(disciplineId)
  if not lookup then return true end
  if modelHasWhitelistedConfigType(normalizedModelKey, lookup) then return true end
  if ownedModelHasDisciplineLeaderboard(disciplineId, normalizedModelKey) then return true end
  return false
end

local function filterPoolByVehicleConfigWhitelist(models, disciplineId)
  local lookup = getContractVehicleConfigTypeWhitelistLookup(disciplineId)
  if not lookup then return models end
  local out = {}
  local seen = {}
  for _, model in ipairs(models or {}) do
    local n = type(model) == "string" and string.lower(model) or nil
    if n and n ~= "" and not seen[n] and contractModelPassesConfigWhitelist(disciplineId, n) then
      seen[n] = true
      out[#out + 1] = n
    end
  end
  return out
end

local function playerOwnsModel(normalizedModelKey)
  if not normalizedModelKey or normalizedModelKey == "" then return false end
  local vehicles = overhaul_career_garage_inventory
      and overhaul_career_garage_inventory.getVehicles
      and overhaul_career_garage_inventory.getVehicles()
    or {}
  for _, vehicle in pairs(vehicles or {}) do
    local model = type(vehicle.model) == "string" and string.lower(vehicle.model) or nil
    if model == normalizedModelKey then return true end
  end
  return false
end

local function getOwnedContractModelPool(disciplineId)
  local blacklist = buildVehicleBlacklistLookup(disciplineId)
  return filterModelPool(getOwnedVehicleModels(), blacklist)
end

local function getRandomContractModelPool(disciplineId)
  local blacklist = buildVehicleBlacklistLookup(disciplineId)
  local configured = getConfiguredContractModels()
  local pool
  if #configured > 0 then
    pool = filterModelPool(configured, blacklist)
  else
    pool = filterModelPool(getKnownVehicleModels(), blacklist)
  end
  return filterPoolByVehicleConfigWhitelist(pool, disciplineId)
end

local function isModelAllowedForDiscipline(disciplineId, model)
  local normalized = type(model) == "string" and string.lower(model) or nil
  if not normalized or normalized == "" then return false end
  if not isValidVehicleModelKey(normalized) then return false end
  local blacklist = buildVehicleBlacklistLookup(disciplineId)
  if blacklist[normalized] == true then return false end
  if playerOwnsModel(normalized) then return true end
  return filterPoolByVehicleConfigWhitelist({ normalized }, disciplineId)[1] ~= nil
end


-- Leaderboard targets and contract selection --------------------------------------------------------

local function getBestEventPbTimeSeconds(modelKey, raceEntry)
  local normalized = type(modelKey) == "string" and string.lower(modelKey) or nil
  if not normalized or type(raceEntry) ~= "table" then return nil end
  local mainLabel = raceEntry.raceLabel
  if type(mainLabel) ~= "string" or mainLabel == "" then return nil end
  local lb = overhaul_events_leaderboards
  if not lb or type(lb.getLeaderboardEntry) ~= "function" then return nil end
  local vehicles = overhaul_career_garage_inventory
      and overhaul_career_garage_inventory.getVehicles
      and overhaul_career_garage_inventory.getVehicles()
    or {}
  local hotlapLabel = raceEntry.isLapEvent and (mainLabel .. " (Hotlap)") or nil
  local best = nil
  for invId, vehicle in pairs(vehicles) do
    local vm = type(vehicle.model) == "string" and string.lower(vehicle.model) or nil
    if vm == normalized then
      local tBest = nil
      if hotlapLabel then
        local eH = lb.getLeaderboardEntry(invId, hotlapLabel)
        if type(eH) == "table" and tonumber(eH.time) and tonumber(eH.time) > 0 then tBest = tonumber(eH.time) end
      end
      if not tBest then
        local e = lb.getLeaderboardEntry(invId, mainLabel)
        if type(e) == "table" and tonumber(e.time) and tonumber(e.time) > 0 then tBest = tonumber(e.time) end
      end
      if tBest then best = best and math.min(best, tBest) or tBest end
    end
  end
  return best
end

local function getBestPullDistanceMeters(modelKey, raceEntry)
  local normalized = type(modelKey) == "string" and string.lower(modelKey) or nil
  local raceLabel = type(raceEntry) == "table" and raceEntry.raceLabel or nil
  if not normalized or type(raceLabel) ~= "string" or raceLabel == "" then return nil end
  local lb = overhaul_events_leaderboards
  if not lb or type(lb.getLeaderboardEntry) ~= "function" then return nil end
  local vehicles = overhaul_career_garage_inventory
      and overhaul_career_garage_inventory.getVehicles
      and overhaul_career_garage_inventory.getVehicles()
    or {}
  local best
  for invId, vehicle in pairs(vehicles) do
    local vehicleModel = type(vehicle.model) == "string" and string.lower(vehicle.model) or nil
    if vehicleModel == normalized then
      local entry = lb.getLeaderboardEntry(invId, raceLabel)
      local distance = type(entry) == "table" and tonumber(entry.pullDistance) or nil
      if distance and distance > 0 then best = best and math.max(best, distance) or distance end
    end
  end
  return best
end


local function pickContractModel(disciplineId, contractCfg)
  local cfg = type(contractCfg) == "table" and contractCfg or freConfig.getContractConfig(disciplineId) or {}
  local pw = cfg.contractVehiclePickWeights or {}
  local wExp = math.max(0, tonumber(pw.experiencedOwned) or 0.5)
  local wNov = math.max(0, tonumber(pw.otherOwned) or 0.3)
  local wRand = math.max(0, tonumber(pw.notOwned) or 0.2)
  local pm = cfg.contractVehicleRewardMultipliers or {}
  local mExp = tonumber(pm.experiencedOwned) or 1
  local mNov = tonumber(pm.otherOwned) or 1
  local mRand = tonumber(pm.notOwned) or 1.25

  local ownedPool = getOwnedContractModelPool(disciplineId)
  local randomPool = getRandomContractModelPool(disciplineId)
  local experienced = {}
  local novice = {}
  for _, model in ipairs(ownedPool) do
    if ownedModelHasDisciplineLeaderboard(disciplineId, model) then
      experienced[#experienced + 1] = model
    else
      novice[#novice + 1] = model
    end
  end

  local pickRandomFromList = freHelpers.pickRandomFromList
  local candidates = {}
  if #experienced > 0 and wExp > 0 then
    candidates[#candidates + 1] = { pool = experienced, w = wExp, source = "owned_tracked", mult = mExp }
  end
  if #novice > 0 and wNov > 0 then
    candidates[#candidates + 1] = { pool = novice, w = wNov, source = "owned", mult = mNov }
  end
  if #randomPool > 0 and wRand > 0 then
    candidates[#candidates + 1] = { pool = randomPool, w = wRand, source = "random", mult = mRand }
  end

  if #candidates == 0 then return nil, nil, 1 end

  local totalW = 0
  for _, c in ipairs(candidates) do
    totalW = totalW + c.w
  end
  if totalW <= 0 then return nil, nil, 1 end

  local roll = math.random() * totalW
  for _, c in ipairs(candidates) do
    roll = roll - c.w
    if roll <= 0 then return pickRandomFromList(c.pool), c.source, c.mult end
  end

  local last = candidates[#candidates]
  return pickRandomFromList(last.pool), last.source, last.mult
end

-- Vehicle identity ----------------------------------------------------------------------------------

local function normalizeModelFamilyToken(value)
  if type(value) ~= "string" or value == "" then return nil end
  local normalized = string.lower(value):gsub("[^%w]", "")
  if normalized == "" then return nil end
  return normalized
end

local function modelFamilyMatches(requiredModel, actualModel)
  if type(requiredModel) ~= "string" or requiredModel == "" then return true end
  local requiredToken = normalizeModelFamilyToken(requiredModel)
  local actualToken = normalizeModelFamilyToken(actualModel)
  if not requiredToken or not actualToken then return false end
  if requiredToken == actualToken then return true end
  if string.find(actualToken, requiredToken, 1, true) or string.find(requiredToken, actualToken, 1, true) then
    return true
  end
  return false
end

local function getCurrentVehicleModel(vehId)
  local vehicleId = vehId or be:getPlayerVehicleID(0)
  if not vehicleId then return nil end

  if
    overhaul_career_garage_inventory
    and overhaul_career_garage_inventory.getInventoryIdFromVehicleId
    and overhaul_career_garage_inventory.getVehicles
  then
    local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehicleId)
    if inventoryId then
      local vehicleData = (overhaul_career_garage_inventory.getVehicles() or {})[inventoryId]
      if vehicleData and type(vehicleData.model) == "string" and vehicleData.model ~= "" then
        return string.lower(vehicleData.model)
      end
    end
  end
  return nil
end

-- Public API --------------------------------------------------------------------------------------

M.isValidVehicleModelKey = isValidVehicleModelKey
M.getModelDisplayName = getModelDisplayName
M.isModelAllowedForDiscipline = isModelAllowedForDiscipline
M.getBestEventPbTimeSeconds = getBestEventPbTimeSeconds
M.getBestPullDistanceMeters = getBestPullDistanceMeters
M.pickContractModel = pickContractModel
M.modelFamilyMatches = modelFamilyMatches
M.getCurrentVehicleModel = getCurrentVehicleModel

return M
