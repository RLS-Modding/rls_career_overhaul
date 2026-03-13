local M = {}

local freConfig = require('gameplay/fre/config')
local core_vehicles = require('core/vehicles')

local function isValidVehicleModelKey(modelKey)
  local normalized = type(modelKey) == "string" and string.lower(modelKey) or nil
  if not normalized or normalized == "" then
    return false
  end

  if core_vehicles and core_vehicles.getModel then
    local modelData = core_vehicles.getModel(normalized)
    if type(modelData) ~= "table" then
      return false
    end
    local modelInfo = type(modelData.model) == "table" and modelData.model or {}
    local typeHint = string.lower(tostring(
      modelInfo.Type or modelInfo.type or modelInfo.Category or modelInfo.category or ""))
    local classHint = string.lower(tostring(modelInfo.Class or modelInfo.class or ""))
    if string.find(typeHint, "prop", 1, true) or string.find(typeHint, "device", 1, true) then
      return false
    end
    if string.find(classHint, "prop", 1, true) or string.find(classHint, "device", 1, true) then
      return false
    end

    local tableHasAnyEntries = gameplay_events_freContracts_helpers.tableHasAnyEntries
    if modelData.configs ~= nil and not tableHasAnyEntries(modelData.configs) then
      return false
    end
  end

  return true
end

local function getOwnedVehicleModels()
  local models = {}
  local seen = {}
  local vehicles = career_modules_inventory and career_modules_inventory.getVehicles and
                     career_modules_inventory.getVehicles() or {}
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

  if core_vehicles and core_vehicles.getModelList then
    local modelList = core_vehicles.getModelList() or {}
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

local function prettifyModelKey(modelKey)
  if type(modelKey) ~= "string" or modelKey == "" then
    return "Unknown Model"
  end
  local words = {}
  for token in modelKey:gsub("_", " "):gmatch("%S+") do
    local trimmedToken = token:gsub("%d+$", "")
    if trimmedToken == "" then
      trimmedToken = token
    end
    local first = trimmedToken:sub(1, 1)
    local rest = trimmedToken:sub(2)
    table.insert(words, string.upper(first) .. string.lower(rest))
  end
  return #words > 0 and table.concat(words, " ") or modelKey
end

local function getModelDisplayName(modelKey)
  local normalized = type(modelKey) == "string" and string.lower(modelKey) or nil
  if not normalized or normalized == "" then
    return "Unknown Model"
  end

  if core_vehicles and core_vehicles.getModel then
    local modelData = core_vehicles.getModel(normalized)
    local modelInfo = modelData and modelData.model
    if type(modelInfo) == "table" then
      local modelName = modelInfo.Name or modelInfo.name
      if type(modelName) == "string" and modelName ~= "" then
        return modelName
      end
    end
  end

  return prettifyModelKey(normalized)
end

local function buildVehicleBlacklistLookup(disciplineId)
  local lookup = {}
  for _, model in ipairs(freConfig.getContractVehicleBlacklist(disciplineId) or {}) do
    if type(model) == "string" and model ~= "" then
      lookup[string.lower(model)] = true
    end
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

local function getOwnedContractModelPool(disciplineId)
  local blacklist = buildVehicleBlacklistLookup(disciplineId)
  return filterModelPool(getOwnedVehicleModels(), blacklist)
end

local function getRandomContractModelPool(disciplineId)
  local blacklist = buildVehicleBlacklistLookup(disciplineId)
  local configured = getConfiguredContractModels()
  if #configured > 0 then
    return filterModelPool(configured, blacklist)
  end
  return filterModelPool(getKnownVehicleModels(), blacklist)
end

local function isModelAllowedForDiscipline(disciplineId, model)
  local normalized = type(model) == "string" and string.lower(model) or nil
  if not normalized or normalized == "" then
    return false
  end
  local blacklist = buildVehicleBlacklistLookup(disciplineId)
  return blacklist[normalized] ~= true
end

local function pickContractModel(disciplineId)
  local contractCfg = freConfig.getContractConfig() or {}
  local ownedChance = tonumber(contractCfg.modelSourceOwnedChance)
  if ownedChance == nil then
    ownedChance = 0.5
  end
  ownedChance = math.max(0, math.min(1, ownedChance))

  local ownedPool = getOwnedContractModelPool(disciplineId)
  local randomPool = getRandomContractModelPool(disciplineId)
  local useOwned = #ownedPool > 0 and (#randomPool == 0 or math.random() < ownedChance)
  local source = useOwned and "owned" or "random"
  local pool = useOwned and ownedPool or randomPool

  if #pool == 0 then
    if #ownedPool > 0 then
      pool = ownedPool
      source = "owned"
    elseif #randomPool > 0 then
      pool = randomPool
      source = "random"
    end
  end

  if #pool == 0 then
    return nil, nil
  end

  local pickRandomFromList = gameplay_events_freContracts_helpers.pickRandomFromList
  return pickRandomFromList(pool), source
end

local function normalizeModelFamilyToken(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  local normalized = string.lower(value):gsub("[^%w]", "")
  if normalized == "" then
    return nil
  end
  return normalized
end

local function modelFamilyMatches(requiredModel, actualModel)
  if type(requiredModel) ~= "string" or requiredModel == "" then
    return true
  end
  local requiredToken = normalizeModelFamilyToken(requiredModel)
  local actualToken = normalizeModelFamilyToken(actualModel)
  if not requiredToken or not actualToken then
    return false
  end
  if requiredToken == actualToken then
    return true
  end
  if string.find(actualToken, requiredToken, 1, true) or string.find(requiredToken, actualToken, 1, true) then
    return true
  end
  return false
end

local function getCurrentVehicleModel(vehId)
  local vehicleId = vehId or be:getPlayerVehicleID(0)
  if not vehicleId then
    return nil
  end

  if career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId and
    career_modules_inventory.getVehicles then
    local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehicleId)
    if inventoryId then
      local vehicleData = (career_modules_inventory.getVehicles() or {})[inventoryId]
      if vehicleData and type(vehicleData.model) == "string" and vehicleData.model ~= "" then
        return string.lower(vehicleData.model)
      end
    end
  end
  return nil
end

M.isValidVehicleModelKey = isValidVehicleModelKey
M.getModelDisplayName = getModelDisplayName
M.isModelAllowedForDiscipline = isModelAllowedForDiscipline
M.pickContractModel = pickContractModel
M.modelFamilyMatches = modelFamilyMatches
M.getCurrentVehicleModel = getCurrentVehicleModel

return M
