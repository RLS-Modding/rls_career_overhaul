-- Maintenance computer config: part categories, service items with their prices, and the wear snapshot kept per vehicle.
-- Map: category config, vehicle classification, capacities, wear defaults, snapshot normalization and public API.

local partCategories = require("common/overhaul/maintenancePartCategories")

local M = {}

-- Config --------------------------------------------------------------------------------------------

local max = math.max
local metersToMiles = 1 / 1609.344
local milesToMeters = 1609.344

local classDefaultCapacities = {
  passenger = {oil = 4, coolant = 5, transmission = 6},
  lightTruck = {oil = 6, coolant = 8, transmission = 9},
  mediumTruck = {oil = 10, coolant = 15, transmission = 14},
  heavyTruck = {oil = 18, coolant = 25, transmission = 20},
}

local categoryDefinitions = {
  engine = {
    label = "Engine",
    keywords = partCategories.definitions.engine.keywords,
    installedKeywords = partCategories.definitions.engine.installedKeywords,
    installedSlotSuffixes = partCategories.definitions.engine.installedSlotSuffixes,
    installedExcludeKeywords = partCategories.definitions.engine.installedExcludeKeywords,
    installedPowertrainDevices = partCategories.definitions.engine.installedPowertrainDevices,
    powertrainDevicesAuthoritative = true,
    items = {
      {
        name = "oilLevel",
        label = "Oil Level",
        actionLabel = "Fill",
        checkDurationSeconds = 60,
        serviceDurationSeconds = 60,
        servicePricePct = 0.5,
        servicePriceFloor = 10,
      },
      {
        name = "oilCondition",
        label = "Oil Quality",
        actionLabel = "Replace",
        fillsItem = "oilLevel",
        checkDurationSeconds = 60,
        serviceDurationSeconds = 180,
        servicePricePct = 2.0,
        servicePriceFloor = 50,
      },
      {
        name = "ignitionService",
        label = "Ignition/Injectors",
        actionLabel = "Replace",
        checkDurationSeconds = 300,
        serviceDurationSeconds = 600,
        servicePricePct = 10.0,
        servicePriceFloor = 200,
      },
    },
  },
  radiator = {
    label = "Cooling",
    keywords = partCategories.definitions.radiator.keywords,
    installedKeywords = partCategories.definitions.radiator.installedKeywords,
    installedExcludeKeywords = partCategories.definitions.radiator.installedExcludeKeywords,
    requiredPowertrainDevices = partCategories.definitions.radiator.requiredPowertrainDevices,
    items = {
      {
        name = "coolantLevel",
        label = "Coolant Level",
        actionLabel = "Fill",
        checkDurationSeconds = 60,
        serviceDurationSeconds = 60,
        servicePricePct = 10.0,
        servicePriceFloor = 10,
      },
      {
        name = "coolantIntegrity",
        label = "Coolant Quality",
        actionLabel = "Replace",
        fillsItem = "coolantLevel",
        checkDurationSeconds = 60,
        serviceDurationSeconds = 180,
        servicePricePct = 40.0,
        servicePriceFloor = 30,
      },
    },
  },
  transmission = {
    label = "Transmission",
    keywords = partCategories.definitions.transmission.keywords,
    installedKeywords = partCategories.definitions.transmission.installedKeywords,
    installedExcludeKeywords = partCategories.definitions.transmission.installedExcludeKeywords,
    installedPowertrainDevices = partCategories.definitions.transmission.installedPowertrainDevices,
    items = {
      {
        name = "fluidLevel",
        label = "Transmission Fluid Level",
        actionLabel = "Fill",
        checkDurationSeconds = 180,
        serviceDurationSeconds = 120,
        servicePricePct = 2.0,
        servicePriceFloor = 20,
      },
      {
        name = "fluidCondition",
        label = "Transmission Fluid Quality",
        actionLabel = "Replace",
        fillsItem = "fluidLevel",
        checkDurationSeconds = 180,
        serviceDurationSeconds = 300,
        servicePricePct = 10.0,
        servicePriceFloor = 75,
      },
    },
  },
}

-- Class names from the metadata a vehicle reports, lower-cased and stripped of punctuation.
local CLASS_ALIASES = {
  passenger = "passenger", car = "passenger", commuter = "passenger",
  lighttruck = "lightTruck", pickup = "lightTruck", suv = "lightTruck",
  mediumtruck = "mediumTruck", boxtruck = "mediumTruck",
  heavytruck = "heavyTruck", semi = "heavyTruck", semitruck = "heavyTruck", tractor = "heavyTruck",
}

-- Body style and model family words that imply a class, checked in this order.
local BODY_STYLE_CLASSES = {
  {"heavyTruck", {"semi", "tractor", "bus"}},
  {"mediumTruck", {"medium truck", "box truck"}},
  {"lightTruck", {"pickup", "suv", "van", "off-road"}},
}

local MODEL_FAMILY_CLASSES = {
  {"heavyTruck", {"tseries", "semi"}},
  {"mediumTruck", {"mdseries"}},
  {"lightTruck", {"pickup", "dseries", "roamer", "hopper", "van"}},
}

-- Helpers -------------------------------------------------------------------------------------------

local function clamp(value, minValue, maxValue)
  if value < minValue then
    return minValue
  end
  if value > maxValue then
    return maxValue
  end
  return value
end

local function linearScale(value, valueA, valueB, scaleA, scaleB)
  if valueA == valueB then
    return scaleB
  end
  local t = clamp((value - valueA) / (valueB - valueA), 0, 1)
  return scaleA + ((scaleB - scaleA) * t)
end

local function getWearBandName(avgMiles)
  avgMiles = max(tonumber(avgMiles) or 0, 0)
  if avgMiles <= 100000 then
    return "fresh"
  elseif avgMiles <= 200000 then
    return "aged"
  end
  return "worn"
end

local function normalizeClassName(value)
  local text = string.lower(tostring(value or "")):gsub("[^%w]", "")
  return CLASS_ALIASES[text]
end

-- Every key and string value of a table (or the value itself), lower-cased and joined with spaces.
local function flattenMetadata(value, result)
  result = result or {}
  if type(value) == "table" then
    for key, nested in pairs(value) do
      if type(key) == "string" then
        table.insert(result, string.lower(key))
      end
      flattenMetadata(nested, result)
    end
  elseif value ~= nil then
    table.insert(result, string.lower(tostring(value)))
  end
  return table.concat(result, " ")
end

local function containsAny(text, words)
  for _, word in ipairs(words) do
    if text:find(word, 1, true) then return true end
  end
  return false
end

-- Vehicle profile -----------------------------------------------------------------------------------

local function classFromWords(text, rules)
  for _, rule in ipairs(rules) do
    if containsAny(text, rule[2]) then return rule[1] end
  end
end

local function classFromCurbWeight(curbWeightKg)
  if curbWeightKg >= 8000 then return "heavyTruck" end
  if curbWeightKg >= 3500 then return "mediumTruck" end
  if curbWeightKg >= 2300 then return "lightTruck" end
  return "passenger"
end

-- The stored weight wins when it is positive, else the certified weight, else the plain weight.
local function curbWeightOf(vehicleData, existingProfile)
  local existingCurbWeightKg = tonumber(existingProfile.curbWeightKg) or 0
  if existingCurbWeightKg > 0 then return existingCurbWeightKg end
  return tonumber(vehicleData.certifications and vehicleData.certifications.weight) or tonumber(vehicleData.weight) or 0
end

-- Explicit class takes precedence; reuse a stored class only when its source still applies.
local function chooseClass(explicitClass, existingProfile, bodyText, modelText, curbWeightKg)
  local className = explicitClass
  local classSource = explicitClass and "maintenanceClass" or nil

  if not className and (existingProfile.classSource == "maintenanceClass" or existingProfile.classSource == "bodyStyle") then
    className = normalizeClassName(existingProfile.class)
    classSource = existingProfile.classSource
  end
  if not className then
    className = classFromWords(bodyText, BODY_STYLE_CLASSES)
    if className then classSource = "bodyStyle" end
  end
  if not className then
    className = classFromWords(modelText, MODEL_FAMILY_CLASSES)
    if className then classSource = "modelFamily" end
  end
  if not className and curbWeightKg > 0 then
    return classFromCurbWeight(curbWeightKg), "curbWeight"
  end
  return className, classSource
end

-- Overrides each capacity with a positive value from the source and keeps the default otherwise.
local function applyCapacityOverrides(capacities, source)
  for kind, defaultValue in pairs(capacities) do
    local value = tonumber(source[kind])
    capacities[kind] = value and value > 0 and value or defaultValue
  end
end

local function capacitiesFor(vehicleData, information, existingProfile, className)
  local capacities = deepcopy(classDefaultCapacities[className])
  if existingProfile.class == className and type(existingProfile.capacities) == "table" then
    applyCapacityOverrides(capacities, existingProfile.capacities)
  end
  local explicitCapacities = vehicleData.maintenanceCapacities or information.maintenanceCapacities
  if type(explicitCapacities) == "table" then
    applyCapacityOverrides(capacities, explicitCapacities)
  end
  return capacities
end

-- Diesel, power and torque. Stored figures win when positive, then the certifications, then zero.
local function powertrainOf(vehicleData, information, existingProfile)
  local fuelText = flattenMetadata({information["Fuel Type"], information.fuelType, vehicleData.fuelType,
                                    existingProfile.fuelType})
  local isDiesel = fuelText:find("diesel", 1, true) ~= nil or existingProfile.isDiesel == true
  local existingPowerHp = tonumber(existingProfile.powerHp) or 0
  local existingTorqueNm = tonumber(existingProfile.torqueNm) or 0
  local powerHp = existingPowerHp > 0 and existingPowerHp or tonumber(vehicleData.certifications and vehicleData.certifications.power) or 0
  local torqueNm = existingTorqueNm > 0 and existingTorqueNm or tonumber(vehicleData.certifications and vehicleData.certifications.torque) or 0
  return isDiesel, powerHp, torqueNm
end

local function classifyVehicleProfile(vehicleData, existingProfile)
  vehicleData = type(vehicleData) == "table" and vehicleData or {}
  existingProfile = type(existingProfile) == "table" and existingProfile or {}
  local information = vehicleData.vdata and vehicleData.vdata.information or {}
  local explicitClass = normalizeClassName(vehicleData.maintenanceClass or information.maintenanceClass or
                                             information["Maintenance Class"])
  local bodyText = flattenMetadata({information["Body Style"], information.BodyStyle, information.Type,
                                     vehicleData.bodyStyle, vehicleData.vehicleType})
  local modelText = string.lower(tostring(vehicleData.model or existingProfile.modelFamily or ""))
  local curbWeightKg = curbWeightOf(vehicleData, existingProfile)

  local className, classSource = chooseClass(explicitClass, existingProfile, bodyText, modelText, curbWeightKg)
  className = className or normalizeClassName(existingProfile.class) or "passenger"
  classSource = classSource or existingProfile.classSource or "default"

  local isDiesel, powerHp, torqueNm = powertrainOf(vehicleData, information, existingProfile)
  return {
    class = className,
    classSource = classSource,
    capacities = capacitiesFor(vehicleData, information, existingProfile, className),
    fuelType = isDiesel and "diesel" or "gasoline",
    isDiesel = isDiesel,
    curbWeightKg = max(curbWeightKg, 0),
    engineMassKg = max(tonumber(existingProfile.engineMassKg) or 0, 0),
    powerHp = max(powerHp, 0),
    torqueNm = max(torqueNm, 0),
    modelFamily = vehicleData.model or existingProfile.modelFamily,
  }
end

-- Snapshots -----------------------------------------------------------------------------------------

local function convertMileageToMeters(mileage, unit)
  mileage = max(tonumber(mileage) or 0, 0)
  if unit == "miles" then
    return mileage * milesToMeters
  end
  return mileage
end

local function buildDefaultSnapshot(vehicleData)
  local categories = {}
  for _, categoryName in ipairs(partCategories.categoryOrder) do
    local maintenance = {}
    for _, itemDefinition in ipairs(categoryDefinitions[categoryName].items) do
      maintenance[itemDefinition.name] = 1
    end

    categories[categoryName] = {
      avgOdometer = 0,
      wearBand = "fresh",
      lastFailureTime = 0,
      lastFailureType = nil,
      persistentCareerDamage = false,
      persistentDamageReason = nil,
      rootPartId = nil,
      cachedPartIds = {},
      maintenance = maintenance,
    }
  end

  return {
    version = 3,
    lastSyncMileage = 0,
    lastHardFailureTime = 0,
    profile = classifyVehicleProfile(vehicleData),
    categories = categories,
  }
end

-- A maintenance value is a fraction of life left: missing becomes 1, anything else is clamped into [0, 1].
local function clampMaintenanceValue(value)
  if value == nil then return 1 end
  if value < 0 then return 0 end
  if value > 1 then return 1 end
  return value
end

-- Fills a category's missing or malformed fields from its default, then clamps each item.
local function normalizeCategory(categoryState, defaultCategoryState, categoryName)
  categoryState.avgOdometer = tonumber(categoryState.avgOdometer) or defaultCategoryState.avgOdometer
  categoryState.wearBand = categoryState.wearBand or defaultCategoryState.wearBand
  categoryState.lastFailureTime = tonumber(categoryState.lastFailureTime) or defaultCategoryState.lastFailureTime
  categoryState.lastFailureType = categoryState.lastFailureType
  categoryState.persistentCareerDamage = categoryState.persistentCareerDamage == true
  categoryState.persistentDamageReason = categoryState.persistentDamageReason
  categoryState.rootPartId = categoryState.rootPartId
  categoryState.cachedPartIds = type(categoryState.cachedPartIds) == "table" and categoryState.cachedPartIds or {}
  categoryState.maintenance = type(categoryState.maintenance) == "table" and categoryState.maintenance or {}

  for _, itemDefinition in ipairs(categoryDefinitions[categoryName].items) do
    local name = itemDefinition.name
    categoryState.maintenance[name] = clampMaintenanceValue(tonumber(categoryState.maintenance[name]))
  end
  return categoryState
end

local function normalizeSnapshot(snapshot, vehicleData)
  local normalized = deepcopy(snapshot)
  if type(normalized) ~= "table" then
    normalized = buildDefaultSnapshot(vehicleData)
  end

  normalized.version = 3
  normalized.lastSyncMileage = tonumber(normalized.lastSyncMileage) or 0
  normalized.lastHardFailureTime = tonumber(normalized.lastHardFailureTime) or 0
  normalized.categories = type(normalized.categories) == "table" and normalized.categories or {}
  normalized.profile = classifyVehicleProfile(vehicleData, normalized.profile)

  local defaultSnapshot = buildDefaultSnapshot(vehicleData)
  for _, categoryName in ipairs(partCategories.categoryOrder) do
    local categoryState = type(normalized.categories[categoryName]) == "table" and normalized.categories[categoryName] or {}
    normalized.categories[categoryName] = normalizeCategory(categoryState, defaultSnapshot.categories[categoryName], categoryName)
  end

  return normalized
end

-- Initial wear --------------------------------------------------------------------------------------

-- Seeded wear is new (1) up to the seed start, then falls toward the seed minimum over the full range.
local function seededMinimumFor(avgMiles)
  if avgMiles <= partCategories.initialWearSeedStartMiles then return 1 end
  return linearScale(avgMiles, partCategories.initialWearSeedStartMiles, partCategories.initialWearSeedFullRangeMiles, 1, partCategories.initialWearSeedMinimumValue)
end

local function seedCategories(snapshot, mileageMeters, avgMiles, seededMinimum)
  for _, categoryName in ipairs(partCategories.categoryOrder) do
    local categoryState = snapshot.categories[categoryName]
    categoryState.avgOdometer = mileageMeters
    categoryState.wearBand = getWearBandName(avgMiles)

    for _, itemDefinition in ipairs(categoryDefinitions[categoryName].items) do
      if avgMiles <= partCategories.initialWearSeedStartMiles then
        categoryState.maintenance[itemDefinition.name] = 1
      else
        categoryState.maintenance[itemDefinition.name] = clamp(
          seededMinimum + (math.random() * (1 - seededMinimum)),
          seededMinimum,
          1
        )
      end
    end
  end
end

-- Age-equivalent miles: a heavy truck at 350k is seeded like a car at 100k.
local function buildInitialSnapshotForMileage(mileage, unit, vehicleData)
  local mileageMeters = convertMileageToMeters(mileage, unit)
  local snapshot = buildDefaultSnapshot(vehicleData)
  local avgMiles = partCategories.getClassAgeMiles(mileageMeters * metersToMiles, snapshot.profile)

  snapshot.lastSyncMileage = mileageMeters
  seedCategories(snapshot, mileageMeters, avgMiles, seededMinimumFor(avgMiles))
  return normalizeSnapshot(snapshot, vehicleData)
end

-- Lookups -------------------------------------------------------------------------------------------

local function getItemDefinition(categoryName, itemName)
  local categoryDefinition = categoryDefinitions[categoryName]
  if not categoryDefinition then
    return nil
  end

  for _, itemDefinition in ipairs(categoryDefinition.items) do
    if itemDefinition.name == itemName then
      return itemDefinition
    end
  end

  return nil
end

-- Public API ----------------------------------------------------------------------------------------

M.categoryOrder = partCategories.categoryOrder
M.categoryDefinitions = categoryDefinitions
M.buildDefaultSnapshot = buildDefaultSnapshot
M.buildInitialSnapshotForMileage = buildInitialSnapshotForMileage
M.normalizeSnapshot = normalizeSnapshot
M.getItemDefinition = getItemDefinition
M.classifyVehicleProfile = classifyVehicleProfile

return M
