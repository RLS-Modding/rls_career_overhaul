-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/valueCalculator.lua (BeamNG 0.40).
-- Values vehicles and parts from catalog data, age, mileage and condition; also estimates crash repairs.
-- Read config/cache state, part values and catalog profiles, then valuation steps, repair estimates and exports.

local M = {}

local jbeamIO = require('jbeam/io')
local partDifference = require('overhaul/career/market/valueCalculator/partDifference')
local brokenParts = require('overhaul/career/market/valueCalculator/brokenParts')

-- Config ------------------------------------------------------------------------------------------

local ASSEMBLED_VEHICLE_FACTOR = 0.72
local USED_PART_SELLER_RECOVERY = 0.55
local ADDED_PART_VALUE_FACTOR = 0.60
local PARTS_DERIVED_VALUE_FLOOR = 0.30
local MIN_PC_PARTS_FOR_PARTS_CATALOG = 3
local CLASSIC_MODEL_YEAR = 1985
local EXPECTED_ANNUAL_MILES = 10000
local EXPECTED_MILEAGE_CAP_MILES = 250000
local CLASSIC_BASE_RETENTION_FLOOR = 0.31
local CLASSIC_PRESERVATION_MAX_FACTOR = 0.90
local CLASSIC_TIME_CAPSULE_PREMIUM = 0.35
local CLASSIC_TIME_CAPSULE_DECAY_MILES = 30000
local CLASSIC_LOW_MILEAGE_PREMIUM = 0.18
local CLASSIC_LOW_MILEAGE_DECAY_MILES = 100000
local CUSTOM_CLASSIC_BASE_FLOOR = 0.65
local CUSTOM_CLASSIC_MAX_FLOOR = 1.20
local LOW_MILEAGE_PRESERVATION_START_AGE = 25
local LOW_MILEAGE_PRESERVATION_FULL_AGE = 45
local LOW_MILEAGE_PRESERVATION_MAX_FACTOR = 0.72
local LOW_MILEAGE_PRESERVATION_DECAY_MILES = 60000
local METERS_PER_MILE = 1609.344
-- Bound age-relative adjustments so an unusual odometer cannot dominate absolute wear.
local RELATIVE_MILEAGE_FACTOR_MIN = 0.45
local RELATIVE_MILEAGE_FACTOR_MAX = 1.30
-- Retain commercial value at high mileage because repeated heavy work is normal for those vehicles.
local COMMERCIAL_DUTY_CYCLE_BASE_FACTOR = 0.75
local COMMERCIAL_DUTY_CYCLE_SPAN_FACTOR = 0.40
local COMMERCIAL_DUTY_CYCLE_DECAY_MILES = 500000
local COMMERCIAL_DURABILITY_START_AGE = 12
local COMMERCIAL_DURABILITY_FULL_AGE = 25
local COMMERCIAL_AGE_RETENTION_FLOOR = 0.46
local DIESEL_TRUCK_AGE_RETENTION_FLOOR = 0.42
local DIESEL_TRUCK_VALUE_MODIFIER = 1.06
local DIESEL_TRUCK_VALUE_START_AGE = 5
local DIESEL_TRUCK_VALUE_FULL_AGE = 15
local MANUAL_TRANSMISSION_MODIFIER = 1.01
local HIGH_PERFORMANCE_POWER_START = 600
local HIGH_PERFORMANCE_POWER_SPAN = 600
local HIGH_PERFORMANCE_DENSITY_START = 0.30
local HIGH_PERFORMANCE_DENSITY_FULL = 0.48
local HIGH_PERFORMANCE_RETENTION_GAIN = 1.50
local HIGH_PERFORMANCE_SCORE_EXPONENT = 1.20
local HIGH_PERFORMANCE_FACTORY_MAX_FLOOR = 1.10
local HIGH_PERFORMANCE_START_AGE = 1
local HIGH_PERFORMANCE_FULL_AGE = 5
local ANTIQUE_APPRECIATION_START_AGE = 55
local ANTIQUE_APPRECIATION_FULL_AGE = 70
local ANTIQUE_AGE_RETENTION_FLOOR = 0.39

-- Crash-repair estimates
local repairTimePerPartSeconds = 60
local brokenPartsThreshold = 3 -- a vehicle is considered to need repair after x broken parts
-- A broken part with no catalog or durable record still costs a typical part, so it is never priced at zero.
local unknownPartRepairValue = 700

-- Keep significance overrides small and keyed by model so metadata drives most values.
local haloOverrides = {
}

local AGE_RETENTION_POINTS = {
  {0, 1.00},
  {1, 0.92},
  {3, 0.84},
  {5, 0.75},
  {10, 0.58},
  {15, 0.46},
  {20, 0.37},
  {30, 0.27},
  {40, 0.22},
  {60, 0.18},
}

local MILEAGE_RETENTION_POINTS = {
  {0, 1.00},
  {50000, 0.95},
  {150000, 0.80},
  {300000, 0.55},
  {500000, 0.35},
}

-- State -------------------------------------------------------------------------------------------

local pcPartsCatalogCache = {}
local pcPartsCatalogBadLogOnce = {}
local vehicleCatalogProfileCache = {}
local configInfoIndex
local configInfosByModel

-- PC part sums only depend on the installed vehicle files, so they persist across sessions in the temp folder, keyed by a stamp of those files; any stamp change rebuilds them from the jbeam.
local PC_STATS_CACHE_DIR = "/temp/rls_career/valueCalculator/"
local PC_STATS_CACHE_FILE = PC_STATS_CACHE_DIR .. "pcPartsStats.txt"
local PC_STATS_CACHE_FORMAT = 1
local persistedPcStats
local persistedPcStatsStamp
local persistedPcStatsDirty = false

-- Math helpers ------------------------------------------------------------------------------------

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function smoothstep(value, edge0, edge1)
  if edge0 == edge1 then return value >= edge1 and 1 or 0 end
  local t = clamp((value - edge0) / (edge1 - edge0), 0, 1)
  return t * t * (3 - 2 * t)
end

local function interpolateRetention(points, value, logLinear)
  value = math.max(0, tonumber(value) or 0)
  for i = 1, #points - 1 do
    local left, right = points[i], points[i + 1]
    if value <= right[1] then
      local t = (value - left[1]) / (right[1] - left[1])
      if logLinear then
        return math.exp(math.log(left[2]) + (math.log(right[2]) - math.log(left[2])) * t)
      end
      return left[2] + (right[2] - left[2]) * t
    end
  end
  return points[#points][2]
end

local function isHardcoreMode()
  return overhaul_career_economy_difficultyMode.isHardcoreMode()
end

local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function getTableSize(values)
  local count = 0
  if not values then return 0 end
  for _ in pairs(values) do
    count = count + 1
  end
  return count
end

-- Age and mileage curves --------------------------------------------------------------------------

local function getOrdinaryAgeRetention(age)
  age = math.max(0, tonumber(age) or 0)
  if age <= AGE_RETENTION_POINTS[#AGE_RETENTION_POINTS][1] then
    return interpolateRetention(AGE_RETENTION_POINTS, age, true)
  end
  local yearsPastSixty = age - AGE_RETENTION_POINTS[#AGE_RETENTION_POINTS][1]
  return math.max(0.15, AGE_RETENTION_POINTS[#AGE_RETENTION_POINTS][2] * (0.995 ^ yearsPastSixty))
end

local function getMileageRetention(mileageMeters)
  local mileageMiles = math.max(0, tonumber(mileageMeters) or 0) / METERS_PER_MILE
  return interpolateRetention(MILEAGE_RETENTION_POINTS, mileageMiles, false)
end

local function getClassicActivation(age)
  local currentYear = tonumber(os.date("%Y")) or 2026
  local classicThresholdAge = math.max(0, currentYear - CLASSIC_MODEL_YEAR)
  return smoothstep(tonumber(age) or 0, classicThresholdAge, classicThresholdAge + 7)
end

local function getExpectedMileageMiles(age)
  return math.min(EXPECTED_MILEAGE_CAP_MILES, math.max(0, tonumber(age) or 0) * EXPECTED_ANNUAL_MILES)
end

-- Mileage on a late-model vehicle remains absolute. As a vehicle ages, the same odometer reading is judged increasingly against the mileage normally accumulated over its lifetime. This avoids charging an old car twice for both age and ordinary-for-its-age mileage while remaining monotonic.
local function getVehicleMileageRetention(mileageMeters, age, commercialDurable)
  local absoluteFactor = getMileageRetention(mileageMeters)
  local mileageMiles = math.max(0, tonumber(mileageMeters) or 0) / METERS_PER_MILE
  local expectedMiles = getExpectedMileageMiles(age)
  if expectedMiles <= 0 then
    return absoluteFactor, absoluteFactor, expectedMiles, absoluteFactor, absoluteFactor
  end

  local expectedFactor = interpolateRetention(MILEAGE_RETENTION_POINTS, expectedMiles, false)
  local relativeFactor = clamp(absoluteFactor / math.max(0.01, expectedFactor),
    RELATIVE_MILEAGE_FACTOR_MIN, RELATIVE_MILEAGE_FACTOR_MAX)
  local relativeBlend = smoothstep(tonumber(age) or 0, 8, 25)
  local effectiveFactor = absoluteFactor + (relativeFactor - absoluteFactor) * relativeBlend
  -- Age-relative mileage prevents an ordinary older car from being charged twice for age and use, but it must not erase genuinely high odometer wear. Preserve existing prices below 100k, then phase that relief out by 200k.
  local highMileageWearActivation = smoothstep(mileageMiles, 100000, 200000)
  effectiveFactor = effectiveFactor +
    (absoluteFactor - effectiveFactor) * highMileageWearActivation
  local commercialMileageFactor = effectiveFactor
  if commercialDurable then
    local commercialActivation = smoothstep(
      tonumber(age) or 0, COMMERCIAL_DURABILITY_START_AGE, COMMERCIAL_DURABILITY_FULL_AGE)
    local dutyCycleFactor = COMMERCIAL_DUTY_CYCLE_BASE_FACTOR +
      COMMERCIAL_DUTY_CYCLE_SPAN_FACTOR * math.exp(-mileageMiles / COMMERCIAL_DUTY_CYCLE_DECAY_MILES)
    commercialMileageFactor = effectiveFactor +
      (math.max(effectiveFactor, dutyCycleFactor) - effectiveFactor) * commercialActivation
    effectiveFactor = commercialMileageFactor
  end
  return effectiveFactor, absoluteFactor, expectedMiles, relativeFactor, commercialMileageFactor
end

local function getLowMileagePreservationFloor(age, mileageMeters, baseAgeFactor, haloScore, targetFactor)
  local activation = smoothstep(
    tonumber(age) or 0, LOW_MILEAGE_PRESERVATION_START_AGE, LOW_MILEAGE_PRESERVATION_FULL_AGE)
  if activation <= 0 then return 0, activation, 0 end

  local mileageMiles = math.max(0, tonumber(mileageMeters) or 0) / METERS_PER_MILE
  local strength = math.exp(-mileageMiles / LOW_MILEAGE_PRESERVATION_DECAY_MILES)
  targetFactor = tonumber(targetFactor) or
    (LOW_MILEAGE_PRESERVATION_MAX_FACTOR + 0.15 * clamp(tonumber(haloScore) or 0, 0, 1))
  baseAgeFactor = math.max(0, tonumber(baseAgeFactor) or 0)
  local preservationFloor = baseAgeFactor +
    math.max(0, targetFactor - baseAgeFactor) * activation * strength
  return preservationFloor, activation, strength
end

local function getCommercialAgeFloor(age, baseAgeFactor, commercialDurable, retentionFloor)
  if not commercialDurable then return 0, 0 end
  local activation = smoothstep(
    tonumber(age) or 0, COMMERCIAL_DURABILITY_START_AGE, COMMERCIAL_DURABILITY_FULL_AGE)
  baseAgeFactor = math.max(0, tonumber(baseAgeFactor) or 0)
  retentionFloor = tonumber(retentionFloor) or COMMERCIAL_AGE_RETENTION_FLOOR
  local commercialFloor = baseAgeFactor +
    math.max(0, retentionFloor - baseAgeFactor) * activation
  return commercialFloor, activation
end

local function getDieselTruckAgeFloor(age, baseAgeFactor, dieselTruck)
  if not dieselTruck then return 0, 0 end
  local activation = smoothstep(
    tonumber(age) or 0, COMMERCIAL_DURABILITY_START_AGE, COMMERCIAL_DURABILITY_FULL_AGE)
  baseAgeFactor = math.max(0, tonumber(baseAgeFactor) or 0)
  local dieselTruckFloor = baseAgeFactor +
    math.max(0, DIESEL_TRUCK_AGE_RETENTION_FLOOR - baseAgeFactor) * activation
  return dieselTruckFloor, activation
end

local function getAntiqueAgeFloor(age, baseAgeFactor)
  local activation = smoothstep(
    tonumber(age) or 0, ANTIQUE_APPRECIATION_START_AGE, ANTIQUE_APPRECIATION_FULL_AGE)
  baseAgeFactor = math.max(0, tonumber(baseAgeFactor) or 0)
  local floor = baseAgeFactor +
    math.max(0, ANTIQUE_AGE_RETENTION_FLOOR - baseAgeFactor) * activation
  return floor, activation
end

local function getClassicAgeFloor(age, mileageMeters, baseAgeFactor, customClassicScore)
  local activation = getClassicActivation(age)
  if activation <= 0 then
    return 0, activation, 0, 0
  end

  local mileageMiles = math.max(0, tonumber(mileageMeters) or 0) / METERS_PER_MILE
  -- Use a broad absolute-mileage curve so low-mileage classics do not fall into unrelated price ranges.
  local timeCapsulePremium =
    CLASSIC_TIME_CAPSULE_PREMIUM *
    math.exp(-mileageMiles / CLASSIC_TIME_CAPSULE_DECAY_MILES)
  local lowMileagePremium =
    CLASSIC_LOW_MILEAGE_PREMIUM *
    math.exp(-mileageMiles / CLASSIC_LOW_MILEAGE_DECAY_MILES)
  local preservationStrength = clamp(
    (timeCapsulePremium + lowMileagePremium) /
    math.max(0.001, CLASSIC_PRESERVATION_MAX_FACTOR - CLASSIC_BASE_RETENTION_FLOOR),
    0, 1)
  local preservationRatio = preservationStrength
  local targetFloor =
    CLASSIC_BASE_RETENTION_FLOOR + timeCapsulePremium + lowMileagePremium

  if customClassicScore ~= nil then
    local customFloor = CUSTOM_CLASSIC_BASE_FLOOR +
      (CUSTOM_CLASSIC_MAX_FLOOR - CUSTOM_CLASSIC_BASE_FLOOR) *
      clamp(tonumber(customClassicScore) or 0, 0, 1)
    targetFloor = math.max(targetFloor, customFloor)
  end

  baseAgeFactor = math.max(0, tonumber(baseAgeFactor) or 0)
  local classicFloor = baseAgeFactor
  if targetFloor > baseAgeFactor then
    classicFloor = baseAgeFactor + (targetFloor - baseAgeFactor) * activation
  end
  return classicFloor, activation, preservationRatio, preservationStrength
end

-- Powertrain and performance modifiers ------------------------------------------------------------

local function getPowertrainValueModifiers(age, transmission, dieselTruck)
  local transmissionLower = string.lower(tostring(transmission or ""))
  local manualModifier =
    string.find(transmissionLower, "manual", 1, true) and MANUAL_TRANSMISSION_MODIFIER or 1
  local dieselActivation = dieselTruck and smoothstep(
    tonumber(age) or 0, DIESEL_TRUCK_VALUE_START_AGE, DIESEL_TRUCK_VALUE_FULL_AGE) or 0
  local dieselModifier = 1 + (DIESEL_TRUCK_VALUE_MODIFIER - 1) * dieselActivation
  return manualModifier, dieselModifier, dieselActivation
end

local function getHighPerformanceScore(hp, weight, configType)
  -- Installed parts already value modifications; another power-to-weight premium would double-count them.
  if configType ~= "Factory" then return 0 end
  hp = tonumber(hp)
  weight = tonumber(weight)
  if not hp or not weight or hp <= 0 or weight <= 0 then return 0 end

  local powerScore = clamp(
    (hp - HIGH_PERFORMANCE_POWER_START) / HIGH_PERFORMANCE_POWER_SPAN, 0, 1)
  local powerDensity = hp / weight
  local densityEligibility = smoothstep(
    powerDensity, HIGH_PERFORMANCE_DENSITY_START, HIGH_PERFORMANCE_DENSITY_FULL)
  return powerScore * densityEligibility
end

local function getHighPerformanceRetentionFloor(
  age, baseAgeFactor, highPerformanceScore, configType)
  highPerformanceScore = clamp(tonumber(highPerformanceScore) or 0, 0, 1)
  if configType ~= "Factory" or highPerformanceScore <= 0 then return 0, 0 end

  local activation = smoothstep(
    tonumber(age) or 0, HIGH_PERFORMANCE_START_AGE, HIGH_PERFORMANCE_FULL_AGE)
  if activation <= 0 then return 0, activation end

  baseAgeFactor = math.max(0, tonumber(baseAgeFactor) or 0)
  local targetFloor = math.min(
    HIGH_PERFORMANCE_FACTORY_MAX_FLOOR,
    baseAgeFactor +
      HIGH_PERFORMANCE_RETENTION_GAIN *
      (highPerformanceScore ^ HIGH_PERFORMANCE_SCORE_EXPONENT))
  local floor = baseAgeFactor + math.max(0, targetFloor - baseAgeFactor) * activation
  return floor, activation
end

local function getCommodityDepreciationMultiplier(age, haloScore, factoryConfig)
  if not factoryConfig then return 1, 0 end
  local activation =
    smoothstep(tonumber(age) or 0, 10, 16) *
    (1 - smoothstep(tonumber(age) or 0, 22, 28))
  local haloProtection = clamp(tonumber(haloScore) or 0, 0, 1)
  local multiplier = 1 - activation * 0.55 * (1 - haloProtection)
  return multiplier, activation
end

local function getAgeRetention(age, haloScore)
  local ordinary = getOrdinaryAgeRetention(age)
  haloScore = clamp(tonumber(haloScore) or 0, 0, 1)
  local haloExponent = 1 - 0.55 * haloScore
  local haloAgeFactor = ordinary ^ haloExponent
  local collectorActivation = smoothstep(tonumber(age) or 0, 18, 35)
  local collectorFloor = collectorActivation * haloScore * (0.25 + 0.25 * haloScore)
  return math.max(haloAgeFactor, collectorFloor), ordinary, collectorFloor
end

local function getVehicleListingPriceRange(range)
  range = type(range) == "table" and range or {0.70, 0.88, 1.12, 1.30}
  local normalLowSource = tonumber(range[2]) or 0.88
  local normalHighSource = tonumber(range[3]) or 1.12
  local center = clamp((normalLowSource + normalHighSource) * 0.5, 0.95, 1.05)
  return {
    tailLow = 0.70,
    normalLow = math.max(0.88, center - 0.12),
    normalHigh = math.min(1.12, center + 0.12),
    tailHigh = 1.30,
    center = center
  }
end

local function getAdjustedVehicleBaseValue(value, vehicleCondition)
  vehicleCondition = vehicleCondition or {}
  local baseValue = tonumber(value) or 10000
  local age = vehicleCondition.age or 0
  local mileage = vehicleCondition.mileage or 0
  local ageFactor = getAgeRetention(age, vehicleCondition.haloScore or 0)
  local preservationFloor = getLowMileagePreservationFloor(
    age, mileage, ageFactor, vehicleCondition.haloScore or 0)
  local classicFloor = getClassicAgeFloor(age, mileage, ageFactor)
  local dieselTruckFloor = getDieselTruckAgeFloor(
    age, ageFactor, vehicleCondition.dieselTruck)
  local highPerformanceFloor = getHighPerformanceRetentionFloor(
    age, ageFactor, vehicleCondition.highPerformanceScore, vehicleCondition.configType)
  ageFactor = math.max(
    ageFactor, preservationFloor, classicFloor, dieselTruckFloor, highPerformanceFloor)
  local mileageFactor = getVehicleMileageRetention(mileage, age, vehicleCondition.commercialDurable)
  local manualModifier, dieselModifier = getPowertrainValueModifiers(
    age, vehicleCondition.transmission, vehicleCondition.dieselTruck)
  return math.max(0, baseValue * ageFactor * mileageFactor * manualModifier * dieselModifier)
end

-- Part values -------------------------------------------------------------------------------------

local function getPartDifference(originalParts, newParts, changedSlots)
  return partDifference.getPartDifference(originalParts, newParts, changedSlots)
end

local function getDepreciatedPartValue(value, mileage)
  local mileageMiles = math.max(0, tonumber(mileage) or 0) / METERS_PER_MILE
  local mileageFactor = 0.25 + 0.75 * math.exp(-mileageMiles / 120000)
  return math.max(0, tonumber(value) or 0) * mileageFactor
end

local function getVehicleBuyMarketMultiplier()
  return overhaul_career_economy_globalEconomy.getVehicleBuyMultiplier()
end

local function getVehicleSellMarketMultiplier()
  return overhaul_career_economy_globalEconomy.getVehicleSellMultiplier()
end

local function applyVehicleBuyMarketToMoney(amount)
  local mult = getVehicleBuyMarketMultiplier()
  return math.floor((tonumber(amount) or 0) * mult + 0.5)
end

local function getPartMarketMultiplier()
  return overhaul_career_economy_globalEconomy.getPartPriceMultiplier()
end

-- Keep a fitted part's own production year even when the donor model year changes.
local function partManufacturedYear(part)
  local tags = type(part.tags) == "table" and part.tags or {}
  return tonumber(part.manufacturedYear)
    or ((part.engineShopManufactured == true or tags.engineShopManufactured == true)
      and tonumber(tags.manufacturedYear))
    or tonumber(part.year)
end

local function applyPartAge(part, value)
  local partYear = partManufacturedYear(part)
  if not partYear then return value end
  local currentYear = tonumber(os.date("%Y")) or 2026
  local partAge = math.max(0, currentYear - partYear)
  local ageMarketFactor = 0.15 + 0.85 * getOrdinaryAgeRetention(partAge)
  return value * ageMarketFactor
end

local function applyPartIntegrity(part, value)
  if part.primered then
    value = value * 0.95
  end
  if part.repairCount then
    value = value - value * (part.repairCount / (part.repairCount + 1)) * 0.2
  end
  local integrity = part.partCondition and part.partCondition.integrityValue
  if integrity == nil then integrity = part.integrityValue end
  if integrity ~= nil then
    value = value * (clamp(tonumber(integrity) or 0, 0, 1) ^ 1.5)
  end
  return value
end

local function applyTireCondition(part, value)
  local tireState = part.rlsTireState or (part.tags and part.tags.rlsTireState)
  if type(tireState) ~= "table" or type(tireState.wheels) ~= "table" then return value end
  local total, count = 0, 0
  for _, wheel in pairs(tireState.wheels) do
    if type(wheel) == "table" then
      count = count + 1
      if wheel.flat ~= true then
        total = total + clamp(tonumber(wheel.remaining) or 1, 0, 1)
      end
    end
  end
  if count > 0 then
    value = value * math.max(0.05, total / count)
  end
  return value
end

local function getPartValue(part, sell)
  part = part or {}
  local mileage = part.partCondition and part.partCondition.odometer or 0
  local value = getDepreciatedPartValue(part.value or 0, mileage)
  value = applyPartAge(part, value)
  value = applyPartIntegrity(part, value)
  value = applyTireCondition(part, value)

  value = value * getPartMarketMultiplier()

  if sell then
    value = value * USED_PART_SELLER_RECOVERY
    if isHardcoreMode() then
      value = value * 0.66
    end
  end

  return value
end

local function getPartResaleValue(part)
  return getPartValue(part, true)
end

-- Persisted PC part sums --------------------------------------------------------------------------

local function stampChecksum(text, factor, modulus)
  local sum = #text
  local byte = string.byte
  for i = 1, #text do sum = (sum * factor + byte(text, i)) % modulus end
  return sum
end

local function getVehicleFilesStamp()
  local parts = {"format=" .. PC_STATS_CACHE_FORMAT}
  local service = overhaul_vehicleFilesCache
  local function gameVersion()
    local integrity = readFile("integrity.json") or ""
    return "game=" .. tostring(integrity:match('"version"%s*:%s*"([^"]*)"')) .. "|" ..
      tostring(integrity:match('"buildinfo"%s*:%s*"([^"]*)"'))
  end
  parts[#parts + 1] = service and service.getGameVersion(gameVersion) or gameVersion()
  local modVersion = jsonReadFile("/gameplay/overhaul/version.json")
  parts[#parts + 1] = "mod=" .. tostring(type(modVersion) == "table" and modVersion.version_string or nil)
  local mods = core_modmanager.getMods() or {}
  local modNames = {}
  for name, mod in pairs(mods) do
    if type(mod) == "table" and mod.active ~= false then modNames[#modNames + 1] = tostring(name) end
  end
  table.sort(modNames)
  for _, name in ipairs(modNames) do
    local mod = mods[name]
    local stat = type(mod.stat) == "table" and mod.stat or {}
    parts[#parts + 1] = "m|" .. name .. "|" .. tostring(mod.fullpath) .. "|" .. tostring(stat.filesize) .. "|" ..
      tostring(stat.modtime)
  end
  local function scan()
    local files = {}
    for _, pattern in ipairs({"*.jbeam", "*.pc"}) do
      for _, file in ipairs(FS:findFiles("/vehicles/", pattern, -1, false, false) or {}) do files[#files + 1] = file end
    end
    table.sort(files)
    for _, file in ipairs(files) do
      local stat = FS:stat(file)
      parts[#parts + 1] = "f|" .. file .. "|" .. tostring(type(stat) == "table" and stat.filesize or nil) .. "|" ..
        tostring(type(stat) == "table" and stat.modtime or nil)
    end
    local text = table.concat(parts, "\n")
    return string.format("%d:%d:%d", #files, stampChecksum(text, 31, 4294967291), stampChecksum(text, 131, 2147483629))
  end
  if service and service.getStamp then return service.getStamp(table.concat(parts, "\n"), scan) end
  -- Standalone/module-only use has no lifetime file-change listener.
  return scan()
end

local function getPersistedPcStats()
  if persistedPcStats then return persistedPcStats end
  persistedPcStats = {}
  persistedPcStatsDirty = false
  local startTime = os.clock()
  local ok, stamp = pcall(getVehicleFilesStamp)
  if not ok then
    persistedPcStatsStamp = nil
    log("W", "valueCalculator", "Vehicle file stamp failed, PC part sums are not persisted: " .. tostring(stamp))
    return persistedPcStats
  end
  persistedPcStatsStamp = stamp
  local text = FS:fileExists(PC_STATS_CACHE_FILE) and readFile(PC_STATS_CACHE_FILE) or nil
  local loaded = 0
  if text and text:match("^[^\n]*") == stamp then
    for key, total, highest, count in text:gmatch("\n([^\t\n]+)\t([^\t\n]+)\t([^\t\n]+)\t([^\t\n]+)") do
      total, highest, count = tonumber(total), tonumber(highest), tonumber(count)
      if isFiniteNumber(total) and isFiniteNumber(highest) and isFiniteNumber(count) then
        persistedPcStats[key] = {total = total, highest = highest, count = count}
        loaded = loaded + 1
      end
    end
  end
  log("I", "valueCalculator", string.format("PC part sums: %d cached for stamp %s (%s), %.3fs", loaded, stamp,
    text and (loaded > 0 and "hit" or "stale") or "none", os.clock() - startTime))
  return persistedPcStats
end

local function rememberPcStats(cacheKey, stats)
  pcPartsCatalogCache[cacheKey] = stats
  if persistedPcStatsStamp and not cacheKey:find("[\t\n]") and isFiniteNumber(stats.total)
      and isFiniteNumber(stats.highest) and isFiniteNumber(stats.count) then
    persistedPcStats[cacheKey] = {total = stats.total, highest = stats.highest, count = stats.count}
    persistedPcStatsDirty = true
  end
  return stats
end

local function saveCatalogCache()
  if not persistedPcStatsDirty or not persistedPcStatsStamp then return false end
  local keys = {}
  for key in pairs(persistedPcStats) do keys[#keys + 1] = key end
  table.sort(keys)
  local lines = {persistedPcStatsStamp}
  for _, key in ipairs(keys) do
    local stats = persistedPcStats[key]
    lines[#lines + 1] = string.format("%s\t%.17g\t%.17g\t%.17g", key, stats.total, stats.highest, stats.count)
  end
  if not FS:directoryExists(PC_STATS_CACHE_DIR) then FS:directoryCreate(PC_STATS_CACHE_DIR, true) end
  if not writeFile(PC_STATS_CACHE_FILE, table.concat(lines, "\n") .. "\n") then return false end
  persistedPcStatsDirty = false
  return true
end

local function clearVehiclePcPartsCatalogSumCache()
  saveCatalogCache()
  table.clear(pcPartsCatalogCache)
  table.clear(pcPartsCatalogBadLogOnce)
  table.clear(vehicleCatalogProfileCache)
  configInfoIndex = nil
  configInfosByModel = nil
  persistedPcStats = nil
  persistedPcStatsStamp = nil
end

-- Catalog profiles --------------------------------------------------------------------------------

-- True only the first time a cache key reaches this warning, so a broken vehicle logs once.
local function firstWarning(cacheKey, reason)
  local logKey = cacheKey .. "|" .. reason
  if pcPartsCatalogBadLogOnce[logKey] then return false end
  pcPartsCatalogBadLogOnce[logKey] = true
  return true
end

local function getVehiclePartsCatalogValue(partsCatalogSum)
  local partsBase = tonumber(partsCatalogSum) or 0
  if partsBase <= 0 then
    return 0
  end
  return math.floor(partsBase * ASSEMBLED_VEHICLE_FACTOR + 0.5)
end

local function readPcPartsFile(modelName, configKey)
  local candidatePcPaths = {
    "/vehicles/" .. modelName .. "/" .. configKey .. ".pc",
    "/vehicles/" .. modelName .. "/configurations/" .. configKey .. ".pc",
  }
  for _, candidate in ipairs(candidatePcPaths) do
    local data = jsonReadFile(candidate)
    if data and type(data.parts) == "table" then
      return data, candidatePcPaths
    end
  end
  return nil, candidatePcPaths
end

local function sumPcPartValues(ioCtx, pcData)
  local accumulatedValue = 0
  local highestValue = 0
  local partCount = 0
  for _, partName in pairs(pcData.parts) do
    if partName and partName ~= "" then
      local partData = jbeamIO.getPart(ioCtx, partName)
      if partData and partData.information and partData.information.value then
        local partValue = math.max(0, tonumber(partData.information.value) or 0)
        accumulatedValue = accumulatedValue + partValue
        highestValue = math.max(highestValue, partValue)
        partCount = partCount + 1
      end
    end
  end
  return {total = accumulatedValue, highest = highestValue, count = partCount}
end

local function getVehiclePcPartsCatalogStats(modelName, configKey, logContext)
  if not modelName or not configKey then
    return {total = 0, highest = 0, count = 0}
  end
  local cacheKey = tostring(modelName) .. "|" .. tostring(configKey)
  if pcPartsCatalogCache[cacheKey] ~= nil then
    return pcPartsCatalogCache[cacheKey]
  end
  local persisted = getPersistedPcStats()[cacheKey]
  if persisted then
    local stats = {total = persisted.total, highest = persisted.highest, count = persisted.count}
    pcPartsCatalogCache[cacheKey] = stats
    return stats
  end
  local ioCtx = jbeamIO.startLoading({
    "/vehicles/" .. modelName .. "/",
    "/vehicles/common/"
  })
  local pcData, candidatePcPaths = readPcPartsFile(modelName, configKey)
  if not pcData then
    if firstWarning(cacheKey, "partsMissing") then
      log("W", "valueCalculator", string.format(
        "PC parts unreadable for %s during %s (%s)",
        cacheKey, tostring(logContext or "pcParts"), table.concat(candidatePcPaths, ", ")))
    end
    return rememberPcStats(cacheKey, {total = 0, highest = 0, count = 0})
  end
  local valueOk, stats = pcall(sumPcPartValues, ioCtx, pcData)
  if not valueOk then
    if firstWarning(cacheKey, "partsValueError") then
      log("W", "valueCalculator", string.format(
        "PC parts jbeam lookup failed for %s (%s): %s",
        cacheKey, tostring(logContext or "pcParts"), tostring(stats)))
    end
    return rememberPcStats(cacheKey, {total = 0, highest = 0, count = 0})
  end
  return rememberPcStats(cacheKey, stats)
end

local function getVehiclePcPartsCatalogSum(modelName, configKey, logContext)
  return getVehiclePcPartsCatalogStats(modelName, configKey, logContext).total
end

local function median(values)
  if not values or #values == 0 then return nil end
  table.sort(values)
  local middle = math.floor(#values / 2)
  if #values % 2 == 1 then
    return values[middle + 1]
  end
  return (values[middle] + values[middle + 1]) * 0.5
end

local function getConfigType(configInfo)
  if type(configInfo) ~= "table" then return nil end
  local direct = configInfo.configType or configInfo["Config Type"]
  if type(direct) == "string" then return direct end
  if type(direct) == "table" then
    for key, enabled in pairs(direct) do
      if enabled then return key end
    end
  end
  local aggregate = configInfo.aggregates and configInfo.aggregates["Config Type"]
  if type(aggregate) == "string" then return aggregate end
  if type(aggregate) == "table" then
    for key, enabled in pairs(aggregate) do
      if enabled then return key end
    end
  end
  return nil
end

local function getConfigYears(configInfo)
  if type(configInfo) ~= "table" then return nil end
  local years = configInfo.Years or (configInfo.aggregates and configInfo.aggregates.Years)
  if type(years) ~= "table" then return nil end
  local minYear = tonumber(years.min)
  local maxYear = tonumber(years.max)
  if not minYear or not maxYear then return nil end
  if minYear > maxYear then minYear, maxYear = maxYear, minYear end
  return {min = minYear, max = maxYear}
end

local function yearsOverlap(left, right)
  return left and right and left.min <= right.max and right.min <= left.max
end

local function getConfigInfoIndex()
  if configInfoIndex then return configInfoIndex end
  configInfoIndex = {}
  local configList = core_vehicles.getConfigList() or {}
  local configs = configList.configs or configList
  for _, configInfo in pairs(configs or {}) do
    if type(configInfo) == "table" and configInfo.model_key and configInfo.key then
      configInfoIndex[tostring(configInfo.model_key) .. "|" .. tostring(configInfo.key)] = configInfo
    end
  end
  return configInfoIndex
end

local function getConfigInfosOfModel(modelName)
  if not configInfosByModel then
    configInfosByModel = {}
    for _, configInfo in pairs(getConfigInfoIndex()) do
      local list = configInfosByModel[configInfo.model_key]
      if not list then
        list = {}
        configInfosByModel[configInfo.model_key] = list
      end
      list[#list + 1] = configInfo
    end
  end
  return configInfosByModel[modelName] or {}
end

local function getConfigInfo(modelName, configKey, suppliedInfo)
  if type(suppliedInfo) == "table" then return suppliedInfo end
  return getConfigInfoIndex()[tostring(modelName) .. "|" .. tostring(configKey)]
end

local function getConfigNumber(configInfo, key)
  if type(configInfo) ~= "table" then return nil end
  local value = tonumber(configInfo[key])
  if value then return value end
  local aggregate = configInfo.aggregates and configInfo.aggregates[key]
  if type(aggregate) == "table" then
    return tonumber(aggregate.max) or tonumber(aggregate.min)
  end
  return tonumber(aggregate)
end

local function getConfigString(configInfo, key)
  if type(configInfo) ~= "table" then return nil end
  local direct = configInfo[key]
  if type(direct) == "string" then return direct end
  local aggregate = configInfo.aggregates and configInfo.aggregates[key]
  if type(aggregate) == "string" then return aggregate end
  if type(aggregate) == "table" then
    for value, enabled in pairs(aggregate) do
      if enabled == true then return tostring(value) end
    end
  end
  return nil
end

local function inferBodyStyle(configInfo)
  local bodyStyle = getConfigString(configInfo, "Body Style")
  if bodyStyle then return bodyStyle end
  local name = string.lower(tostring(configInfo and configInfo.Name or ""))
  if string.find(name, "wagon", 1, true) then return "Wagon" end
  if string.find(name, "coupe", 1, true) then return "Coupe" end
  if string.find(name, "sedan", 1, true) then return "Sedan" end
  if string.find(name, "mixer", 1, true) or string.find(name, "cement", 1, true) then
    return "Mixer Truck"
  end
  return nil
end

local function getFactoryPeerInfos(modelName, configInfo)
  if getConfigType(configInfo) ~= "Factory" then return {} end
  local candidateYears = getConfigYears(configInfo)
  if not candidateYears then return {} end
  local peers = {}
  -- Only the peer set matters: every value taken from it is reduced to a count or a median.
  for _, peer in ipairs(getConfigInfosOfModel(modelName)) do
    if peer.model_key == modelName
      and getConfigType(peer) == "Factory"
      and yearsOverlap(candidateYears, getConfigYears(peer)) then
      table.insert(peers, peer)
    end
  end
  return peers
end

-- The catalog value is the parts sum when the PC is trustworthy, otherwise the config's own listed value.
local function catalogValueFor(cacheKey, partsStats, fallbackValue, mixerUpfit)
  local rawPartsCatalogValue = getVehiclePartsCatalogValue(partsStats.total)
  local sparsePartsCatalog =
    partsStats.count < MIN_PC_PARTS_FOR_PARTS_CATALOG and
    fallbackValue and fallbackValue > 0
  if sparsePartsCatalog then
    if firstWarning(cacheKey, "sparsePartsCatalogFallback") then
      log("W", "valueCalculator", string.format(
        "Using config Value fallback for %s because the PC provided only %d valued parts (parts-derived %.0f, config %.0f)",
        cacheKey, partsStats.count, rawPartsCatalogValue, fallbackValue))
    end
    return fallbackValue, "configFallbackSparseParts", rawPartsCatalogValue
  end
  if partsStats.total > 0 then
    if mixerUpfit and fallbackValue and fallbackValue > 0 and rawPartsCatalogValue > fallbackValue * 1.10 then
      local cappedValue = math.floor(fallbackValue * 1.10 + 0.5)
      if firstWarning(cacheKey, "vocationalCatalogCap") then
        log("W", "valueCalculator", string.format(
          "Capped anomalous mixer catalog for %s from %.0f to %.0f (config reference %.0f)",
          cacheKey, rawPartsCatalogValue, cappedValue, fallbackValue))
      end
      return cappedValue, "partsCappedVocationalOutlier", rawPartsCatalogValue
    end
    return rawPartsCatalogValue, "parts", rawPartsCatalogValue
  end
  if fallbackValue and fallbackValue > 0 then
    if firstWarning(cacheKey, "catalogFallback") then
      log("W", "valueCalculator", string.format(
        "Using config Value fallback for %s because no valid parts-derived catalog was available", cacheKey))
    end
    return fallbackValue, "configFallback", rawPartsCatalogValue
  end
  return 0, "missing", rawPartsCatalogValue
end

-- Halo signals say how far a factory config stands out from its factory peers (same model, overlapping years).
local function haloSignalsFor(modelName, configInfo, partsStats, catalogValue)
  local signals = {
    hpDistinct = 0,
    powerWeight = 0,
    performance = 0,
    catalogDistinct = 0,
    partDistinct = 0,
    rarity = 0,
    distinctiveness = 0
  }
  local peers = getFactoryPeerInfos(modelName, configInfo)
  if #peers < 3 then return signals, #peers end

  local hpValues, powerWeightValues, catalogValues, highestPartValues, populationValues = {}, {}, {}, {}, {}
  for _, peer in ipairs(peers) do
    local hp = getConfigNumber(peer, "Power")
    local weight = getConfigNumber(peer, "Weight")
    local population = getConfigNumber(peer, "Population")
    local peerStats = getVehiclePcPartsCatalogStats(peer.model_key, peer.key, "haloPeer")
    if hp and hp > 0 then table.insert(hpValues, hp) end
    if hp and hp > 0 and weight and weight > 0 then table.insert(powerWeightValues, hp / weight) end
    if peerStats.total > 0 then
      table.insert(catalogValues, getVehiclePartsCatalogValue(peerStats.total))
      if peerStats.highest > 0 then table.insert(highestPartValues, peerStats.highest) end
    end
    if population and population > 0 then table.insert(populationValues, population) end
  end

  local hp = getConfigNumber(configInfo, "Power")
  local weight = getConfigNumber(configInfo, "Weight")
  local population = getConfigNumber(configInfo, "Population")
  local medianHp = #hpValues >= 3 and median(hpValues) or nil
  local medianPowerWeight = #powerWeightValues >= 3 and median(powerWeightValues) or nil
  local medianCatalog = #catalogValues >= 3 and median(catalogValues) or nil
  local medianHighestPart = #highestPartValues >= 3 and median(highestPartValues) or nil
  local medianPopulation = #populationValues >= 3 and median(populationValues) or nil

  if hp and hp > 0 and medianHp and medianHp > 0 then
    signals.hpDistinct = clamp(((hp / medianHp) - 1) / 0.60, 0, 1)
  end
  if hp and hp > 0 and weight and weight > 0 and medianPowerWeight and medianPowerWeight > 0 then
    signals.powerWeight = clamp((((hp / weight) / medianPowerWeight) - 1) / 0.50, 0, 1)
  end
  signals.performance = 0.30 * signals.hpDistinct + 0.70 * signals.powerWeight
  if partsStats.total > 0 and medianCatalog and medianCatalog > 0 then
    signals.catalogDistinct = clamp(((catalogValue / medianCatalog) - 1) / 0.75, 0, 1)
  end
  if partsStats.highest > 0 and medianHighestPart and medianHighestPart > 0 then
    signals.partDistinct = clamp(((partsStats.highest / medianHighestPart) - 1) / 1.50, 0, 1)
  end
  if population and population > 0 and medianPopulation and medianPopulation > 0 then
    signals.rarity = clamp(1 - population / medianPopulation, 0, 1)
  end
  signals.distinctiveness =
    0.50 * signals.catalogDistinct +
    0.25 * signals.partDistinct +
    0.25 * signals.rarity
  return signals, #peers
end

local function haloScoreFor(cacheKey, signals)
  local haloScore = clamp(
    0.25 * signals.performance +
    0.55 * signals.distinctiveness +
    0.20 * math.sqrt(signals.performance * signals.distinctiveness),
    0, 1)
  local haloOverride = haloOverrides[cacheKey]
  if haloOverride then
    if haloOverride.score ~= nil then haloScore = clamp(tonumber(haloOverride.score) or haloScore, 0, 1) end
    if haloOverride.add ~= nil then haloScore = clamp(haloScore + (tonumber(haloOverride.add) or 0), 0, 1) end
  end
  return haloScore
end

-- Commercial durability needs diesel and real weight; a diesel truck is a diesel pickup, tractor or heavy vehicle.
local function vehicleClassFlags(fuelType, bodyStyleLower, weight, vocationalUpfit)
  local dieselFuel = string.lower(tostring(fuelType or "")) == "diesel"
  local commercialDurable =
    dieselFuel and
    weight ~= nil and weight >= 4500 and
    not vocationalUpfit
  local truckBody =
    string.find(bodyStyleLower, "truck", 1, true) ~= nil or
    string.find(bodyStyleLower, "pickup", 1, true) ~= nil or
    string.find(bodyStyleLower, "tractor", 1, true) ~= nil
  local dieselTruck =
    dieselFuel and not vocationalUpfit and
    (commercialDurable or truckBody or (weight ~= nil and weight >= 2500))
  return commercialDurable, dieselTruck
end

-- Preservation follows age and rarity; parts and factory halo already account for power.
local function preservationTargetFor(haloScore, drivetrain)
  local preservationTargetFactor = 0.62 + 0.18 * haloScore
  local isFwd = string.lower(tostring(drivetrain or "")) == "fwd"
  if isFwd then
    preservationTargetFactor = preservationTargetFactor * 0.68
  end
  return clamp(preservationTargetFactor, 0.45, 0.80)
end

-- Mixers and dump or tanker bodies are upfits: their parts sum overstates what the chassis is worth.
local function upfitFlags(bodyStyleLower)
  local mixerUpfit =
    string.find(bodyStyleLower, "mixer", 1, true) ~= nil or
    string.find(bodyStyleLower, "cement", 1, true) ~= nil
  local vocationalUpfit =
    string.find(bodyStyleLower, "dump", 1, true) ~= nil or
    mixerUpfit or
    string.find(bodyStyleLower, "tanker", 1, true) ~= nil
  return mixerUpfit, vocationalUpfit
end

local function commercialRetentionFloorFor(commercialDurable, weight)
  if commercialDurable and weight then
    return COMMERCIAL_AGE_RETENTION_FLOOR + 0.12 * clamp((weight - 6000) / 1800, 0, 1)
  end
  return COMMERCIAL_AGE_RETENTION_FLOOR
end

local function getVehicleCatalogProfile(modelName, configKey, configInfo)
  if not modelName or not configKey then return nil end
  local cacheKey = tostring(modelName) .. "|" .. tostring(configKey)
  if vehicleCatalogProfileCache[cacheKey] then
    return vehicleCatalogProfileCache[cacheKey]
  end

  configInfo = getConfigInfo(modelName, configKey, configInfo)
  local partsStats = getVehiclePcPartsCatalogStats(modelName, configKey, "catalogProfile")
  local fallbackValue = configInfo and tonumber(configInfo.Value) or 0
  local configType = getConfigType(configInfo)
  local fuelType = getConfigString(configInfo, "Fuel Type")
  local bodyStyle = inferBodyStyle(configInfo)
  local drivetrain = getConfigString(configInfo, "Drivetrain")
  local transmission = getConfigString(configInfo, "Transmission")
  local hp = getConfigNumber(configInfo, "Power")
  local weight = getConfigNumber(configInfo, "Weight")
  local bodyStyleLower = string.lower(tostring(bodyStyle or ""))
  local mixerUpfit, vocationalUpfit = upfitFlags(bodyStyleLower)

  local catalogValue, catalogSource, rawPartsCatalogValue =
    catalogValueFor(cacheKey, partsStats, fallbackValue, mixerUpfit)
  local signals, cohortSize = haloSignalsFor(modelName, configInfo, partsStats, catalogValue)
  local haloScore = haloScoreFor(cacheKey, signals)
  local commercialDurable, dieselTruck = vehicleClassFlags(fuelType, bodyStyleLower, weight, vocationalUpfit)

  local profile = {
    partsRetailValue = partsStats.total,
    highestPartValue = partsStats.highest,
    installedPartCount = partsStats.count,
    catalogValue = catalogValue,
    catalogSource = catalogSource,
    rawPartsCatalogValue = rawPartsCatalogValue,
    haloScore = haloScore,
    haloSignals = signals,
    cohortSize = cohortSize,
    configType = configType,
    classicCustomScore = 0,
    preservationTargetFactor = preservationTargetFor(haloScore, drivetrain),
    fuelType = fuelType,
    bodyStyle = bodyStyle,
    drivetrain = drivetrain,
    transmission = transmission,
    power = hp,
    weight = weight,
    highPerformanceScore = getHighPerformanceScore(hp, weight, configType),
    commercialDurable = commercialDurable,
    dieselTruck = dieselTruck,
    commercialRetentionFloor = commercialRetentionFloorFor(commercialDurable, weight),
    vocationalUpfit = vocationalUpfit,
    mixerUpfit = mixerUpfit
  }
  vehicleCatalogProfileCache[cacheKey] = profile
  return profile
end

-- Valuation ---------------------------------------------------------------------------------------

local function catalogValueForValuation(opts, profile)
  local catalogValue = profile and tonumber(profile.catalogValue) or 0
  if catalogValue <= 0 then catalogValue = tonumber(opts.catalogBaseValue) or 0 end
  return catalogValue
end

-- Every age-driven floor and modifier; the result names are the ones the profile screen reads.
local function valuationAgeParts(opts, profile, age, mileageMeters, haloScore)
  local parts = {}
  local baseAgeFactor
  baseAgeFactor, parts.ordinaryAgeFactor, parts.collectorFloor = getAgeRetention(age, haloScore)
  local commodityMultiplier, commodityActivation = getCommodityDepreciationMultiplier(
    age, haloScore, profile and profile.configType == "Factory")
  baseAgeFactor = baseAgeFactor * commodityMultiplier
  parts.commodityMultiplier = commodityMultiplier
  parts.commodityActivation = commodityActivation
  parts.preservationFloor, parts.preservationActivation, parts.lowMileagePreservationStrength =
    getLowMileagePreservationFloor(
      age, mileageMeters, baseAgeFactor, haloScore, profile and profile.preservationTargetFactor)
  parts.classicFloor, parts.classicActivation, parts.preservationRatio, parts.preservationStrength =
    getClassicAgeFloor(age, mileageMeters, baseAgeFactor, nil)
  parts.antiqueFloor, parts.antiqueActivation = getAntiqueAgeFloor(age, baseAgeFactor)
  parts.commercialDurable = opts.commercialDurable
  if parts.commercialDurable == nil then parts.commercialDurable = profile and profile.commercialDurable or false end
  parts.commercialAgeFloor, parts.commercialActivation =
    getCommercialAgeFloor(
      age, baseAgeFactor, parts.commercialDurable, profile and profile.commercialRetentionFloor)
  parts.dieselTruck = opts.dieselTruck
  if parts.dieselTruck == nil then parts.dieselTruck = profile and profile.dieselTruck or false end
  parts.dieselTruckAgeFloor, parts.dieselTruckAgeActivation =
    getDieselTruckAgeFloor(age, baseAgeFactor, parts.dieselTruck)
  parts.highPerformanceScore = tonumber(opts.highPerformanceScore) or
    (profile and profile.highPerformanceScore) or 0
  local highPerformanceConfigType = opts.configType or (profile and profile.configType)
  parts.highPerformanceFloor, parts.highPerformanceActivation =
    getHighPerformanceRetentionFloor(
      age, baseAgeFactor, parts.highPerformanceScore, highPerformanceConfigType)
  parts.ageFactor = math.max(
    baseAgeFactor, parts.preservationFloor, parts.classicFloor, parts.antiqueFloor,
    parts.commercialAgeFloor, parts.dieselTruckAgeFloor, parts.highPerformanceFloor)
  return parts
end

local function valuationMileage(mileageMeters, age, commercialDurable)
  local mileageFactor, absoluteMileageFactor, expectedMileageMiles, relativeMileageFactor,
    commercialMileageFactor = getVehicleMileageRetention(mileageMeters, age, commercialDurable)
  return {
    mileageFactor = mileageFactor,
    absoluteMileageFactor = absoluteMileageFactor,
    expectedMileageMiles = expectedMileageMiles,
    relativeMileageFactor = relativeMileageFactor,
    commercialMileageFactor = commercialMileageFactor,
  }
end

local function valuationPowertrain(opts, profile, age, dieselTruck)
  local transmission = opts.transmission or (profile and profile.transmission)
  local manualModifier, dieselTruckModifier, dieselTruckValueActivation =
    getPowertrainValueModifiers(age, transmission, dieselTruck)
  return {
    transmission = transmission,
    manualModifier = manualModifier,
    dieselTruckModifier = dieselTruckModifier,
    dieselTruckValueActivation = dieselTruckValueActivation,
  }
end

-- Book value is the depreciated value, floored, then adjusted for modifications and damage.
local function valuationBookValue(opts, profile, catalogValue, ageFactor, mileageFactor, powertrain)
  local modificationAdjustment = tonumber(opts.modificationAdjustment) or 0
  local damageAdjustment = math.max(0, tonumber(opts.damageAdjustment) or 0)
  local depreciatedValue =
    catalogValue * ageFactor * mileageFactor * powertrain.manualModifier * powertrain.dieselTruckModifier
  -- Use reliable installed parts as a floor without adding config-type or power bonuses.
  local partsValueFloor = profile and profile.catalogSource == "parts" and
    catalogValue * PARTS_DERIVED_VALUE_FLOOR or 0
  local preDamageFloor = math.max(
    500, catalogValue * 0.05, partsValueFloor, tonumber(opts.minBookValue) or 0)
  local preDamageValue = math.max(preDamageFloor, depreciatedValue + modificationAdjustment)
  local bookValue = math.max(0, preDamageValue - damageAdjustment)
  if opts.applyVehicleBuyMarket then
    bookValue = bookValue * getVehicleBuyMarketMultiplier()
  end
  return {
    bookValue = bookValue,
    partsValueFloor = partsValueFloor,
    preDamageValue = preDamageValue,
    modificationAdjustment = modificationAdjustment,
    damageAdjustment = damageAdjustment,
  }
end

-- The valuation record the profile screen and vehicle values read; its field names are a contract.
local function valuationReport(opts, profile, catalogValue, haloScore, parts, mileage, powertrain, book)
  return {
    catalogValue = catalogValue,
    catalogSource = profile and profile.catalogSource or "providedFallback",
    partsRetailValue = profile and profile.partsRetailValue or tonumber(opts.partsCatalogSum) or 0,
    haloScore = haloScore,
    haloSignals = profile and profile.haloSignals or nil,
    cohortSize = profile and profile.cohortSize or 0,
    ordinaryAgeFactor = parts.ordinaryAgeFactor,
    collectorFloor = parts.collectorFloor,
    commodityMultiplier = parts.commodityMultiplier,
    commodityActivation = parts.commodityActivation,
    preservationFloor = parts.preservationFloor,
    preservationActivation = parts.preservationActivation,
    lowMileagePreservationStrength = parts.lowMileagePreservationStrength,
    classicFloor = parts.classicFloor,
    classicActivation = parts.classicActivation,
    preservationRatio = parts.preservationRatio,
    preservationStrength = parts.preservationStrength,
    classicCustomScore = 0,
    antiqueFloor = parts.antiqueFloor,
    antiqueActivation = parts.antiqueActivation,
    commercialDurable = parts.commercialDurable,
    commercialAgeFloor = parts.commercialAgeFloor,
    commercialActivation = parts.commercialActivation,
    dieselTruck = parts.dieselTruck,
    dieselTruckAgeFloor = parts.dieselTruckAgeFloor,
    dieselTruckAgeActivation = parts.dieselTruckAgeActivation,
    dieselTruckModifier = powertrain.dieselTruckModifier,
    dieselTruckValueActivation = powertrain.dieselTruckValueActivation,
    transmission = powertrain.transmission,
    manualModifier = powertrain.manualModifier,
    highPerformanceScore = parts.highPerformanceScore,
    highPerformanceFloor = parts.highPerformanceFloor,
    highPerformanceActivation = parts.highPerformanceActivation,
    ageFactor = parts.ageFactor,
    mileageFactor = mileage.mileageFactor,
    absoluteMileageFactor = mileage.absoluteMileageFactor,
    relativeMileageFactor = mileage.relativeMileageFactor,
    commercialMileageFactor = mileage.commercialMileageFactor,
    expectedMileageMiles = mileage.expectedMileageMiles,
    modificationAdjustment = book.modificationAdjustment,
    damageAdjustment = book.damageAdjustment,
    partsValueFloor = book.partsValueFloor,
    preDamageValue = book.preDamageValue,
    bookValue = book.bookValue,
  }
end

local function getVehicleValuation(opts)
  if type(opts) ~= "table" then return nil end
  local profile
  if opts.modelName and opts.configKey then
    profile = getVehicleCatalogProfile(opts.modelName, opts.configKey, opts.configInfo)
  end
  local catalogValue = catalogValueForValuation(opts, profile)
  if catalogValue <= 0 then return nil end

  local age = math.max(0, tonumber(opts.age) or 0)
  local mileageMeters = math.max(0, tonumber(opts.mileageMeters) or tonumber(opts.mileage) or 0)
  local haloScore = clamp(tonumber(opts.haloScore) or (profile and profile.haloScore) or 0, 0, 1)
  local parts = valuationAgeParts(opts, profile, age, mileageMeters, haloScore)
  local mileage = valuationMileage(mileageMeters, age, parts.commercialDurable)
  local powertrain = valuationPowertrain(opts, profile, age, parts.dieselTruck)
  local book = valuationBookValue(opts, profile, catalogValue, parts.ageFactor, mileage.mileageFactor, powertrain)
  return valuationReport(opts, profile, catalogValue, haloScore, parts, mileage, powertrain, book)
end

local function getVehicleCatalogIntrinsicBookValue(opts)
  local valuation = getVehicleValuation(opts)
  if not valuation then return nil end
  return math.floor(valuation.bookValue + 0.5)
end

-- Keep off-world records' age datum next to the curve that uses it.
local function getQuickVehicleValue(baseValue, year, mileageMeters)
  local currentYear = tonumber(os.date("%Y"))
  local valuation = getVehicleValuation({
    catalogBaseValue = tonumber(baseValue) or 0,
    mileageMeters = tonumber(mileageMeters) or 0,
    age = math.max(0, currentYear - (tonumber(year) or currentYear)),
  })
  return valuation and valuation.bookValue or 0
end

-- Repair estimates -------------------------------------------------------------------------------

-- Hardcore mode charges more for each replaced part; both repair estimates use this rule.
local function addPartRepairCost(total, partPrice)
  if isHardcoreMode() then
    return math.floor((total + partPrice * 1.25) * 100) / 100
  end
  return math.floor((total + partPrice * 0.9) * 100) / 100
end

local function getDamagedParts(vehicle)
  return brokenParts.find(vehicle, overhaul_career_parts_partInventory)
end

local function getRepairDetails(invVehInfo)
  local details = {
    price = 0,
    repairTime = 0,
    partsCountToBeReplaced = 0
  }

  local damagedParts = getDamagedParts(invVehInfo)
  for _, part in pairs(damagedParts.partsToBeReplaced) do
    local price = (part.value or unknownPartRepairValue) * getPartMarketMultiplier()
    details.price = addPartRepairCost(details.price, price)
    details.repairTime = details.repairTime + repairTimePerPartSeconds
    details.partsCountToBeReplaced = details.partsCountToBeReplaced + 1
  end

  return details
end

local function getNumberOfBrokenParts(partConditions)
  if not partConditions then return 0 end
  local counter = 0
  for _, info in pairs(partConditions) do
    if info.integrityValue and info.integrityValue == 0 then
      counter = counter + 1
    end
  end
  return counter
end

-- Only fully broken parts count: ordinary wear would flag mint cars and loaners as needing repair.
local function partConditionsNeedRepair(partConditions)
  return getNumberOfBrokenParts(partConditions) >= brokenPartsThreshold
end

local function getBrokenPartsThreshold()
  return brokenPartsThreshold
end

local function getSpawnedVehicleRepairPrice(vehId, partConditions)
  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
  if not vehicleData or not partConditions then return 0 end

  local price = 0
  local function walkTree(node)
    if not node.partPath then return end
    local pc = partConditions[node.partPath]
    if pc and pc.integrityValue and pc.integrityValue == 0 then
      local partValue = unknownPartRepairValue
      local activePartIdx = vehicleData.vdata.activeParts[node.partPath]
      if activePartIdx and vehicleData.vdata.activePartsData[activePartIdx] then
        partValue = vehicleData.vdata.activePartsData[activePartIdx].information.value or unknownPartRepairValue
      end
      price = addPartRepairCost(price, partValue * getPartMarketMultiplier())
    end
    if node.children then
      for _, child in pairs(node.children) do
        walkTree(child)
      end
    end
  end

  if vehicleData.config and vehicleData.config.partsTree then
    walkTree(vehicleData.config.partsTree)
  end
  return price
end

-- Vehicle value -----------------------------------------------------------------------------------

-- Installed parts that differ from the original vehicle, and their share of the sale value.
local function getVehiclePartsValueAdjustment(originalParts, installedParts, changedSlots, ageFactor, mileageFactor)
  local names = {}
  local installedPartSaleValue = 0
  for slot, part in pairs(installedParts) do
    names[slot] = part.name
    installedPartSaleValue = installedPartSaleValue + getPartValue(part, true)
  end
  local addedParts, removedParts = getPartDifference(originalParts, names, changedSlots)
  local adjustment = 0
  for slot in pairs(addedParts) do
    local part = installedParts[slot]
    if part then adjustment = adjustment + ADDED_PART_VALUE_FACTOR * getPartValue(part) end
  end
  for slot in pairs(removedParts) do
    local originalValue = tonumber(originalParts[slot] and originalParts[slot].value) or 0
    adjustment = adjustment - originalValue * ASSEMBLED_VEHICLE_FACTOR * ageFactor * mileageFactor
  end
  return adjustment, installedPartSaleValue, removedParts
end

local function getOriginalInstalledPartCount(originalParts)
  local count = 0
  for _, part in pairs(originalParts or {}) do
    if part and part.name and part.name ~= "" then
      count = count + 1
    end
  end
  return count
end

local function getVehicleValueFromParts(baseValue, originalParts, installedParts, changedSlots, ageFactor, mileageFactor, repairPrice)
  local adjustment, saleValue = getVehiclePartsValueAdjustment(
    originalParts, installedParts, changedSlots, ageFactor, mileageFactor)
  local missingParts = 0
  for slot, original in pairs(originalParts or {}) do
    local installed = installedParts[slot]
    if original.name and original.name ~= "" and (not installed or not installed.name or installed.name == "") then
      missingParts = missingParts + 1
    end
  end
  -- more than half the original parts gone: the car is worth only what its remaining parts sell for
  if originalParts and (getOriginalInstalledPartCount(originalParts) / 2) < missingParts then
    return math.max(saleValue, 0)
  end
  return math.max(baseValue + adjustment - (repairPrice or 0), 0)
end

local function getVehicleConfigKey(vehicle)
  if not vehicle or not vehicle.config then return nil end
  local configPath = vehicle.config.partConfigFilename
  if configPath then
    local _, configKey = path.splitWithoutExt(configPath)
    return configKey
  end
  return vehicle.config.key
end

local function getVehicleValue(configBaseValue, vehicle, ignoreDamage)
  local mileage = vehicle.mileage or 0

  local partInventory = overhaul_career_parts_partInventory.getInventory()

  local installedParts = {}
  for _, part in pairs(partInventory) do
    if part.location == vehicle.id then
      installedParts[part.containingSlot] = part
    end
  end
  local originalParts = vehicle.originalParts
  local currentYear = tonumber(os.date("%Y")) or 2026
  local vehicleAge = math.max(0, currentYear - (tonumber(vehicle.year) or currentYear))
  local configKey = getVehicleConfigKey(vehicle)
  local valuation = getVehicleValuation({
    modelName = vehicle.model,
    configKey = configKey,
    catalogBaseValue = configBaseValue,
    mileageMeters = mileage,
    age = vehicleAge
  })
  local adjustedBaseValue = valuation and valuation.bookValue
    or getAdjustedVehicleBaseValue(configBaseValue, {mileage = mileage, age = vehicleAge})
  local ageFactor = valuation and valuation.ageFactor or getAgeRetention(vehicleAge, 0)
  local mileageFactor = valuation and valuation.mileageFactor or getMileageRetention(mileage)
  local repairDetails = getRepairDetails(vehicle)
  if ignoreDamage then
    repairDetails.price = 0
  end

  return getVehicleValueFromParts(adjustedBaseValue, originalParts, installedParts, vehicle.changedSlots,
    ageFactor, mileageFactor, repairDetails.price)
end

-- Desirability: meet-and-greet reputation raises the value, each accident takes a little off.
local function getInventoryVehicleValue(inventoryId, ignoreDamage)
  local vehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  if not vehicle then return end
  local value = math.max(getVehicleValue(vehicle.configBaseValue, vehicle, ignoreDamage), 0)
  local meetValueBonus = overhaul_career_garage_inventory.getVehicleSaleValueBonus(inventoryId) or 0
  local accidents = overhaul_career_garage_inventory.getAccidents(inventoryId) or 0
  local accidentMultiplier = isHardcoreMode() and 0.9 or 0.95
  local desirabilityMultiplier = (1 + (tonumber(meetValueBonus) or 0)) * (accidentMultiplier ^ accidents)
  return value * clamp(desirabilityMultiplier, 0.85, 1.15)
end

local function getInventoryVehicleSellValue(inventoryId, options)
  local value = getInventoryVehicleValue(inventoryId, options and options.ignoreDamage)
  if not value then return end
  return value * getVehicleSellMarketMultiplier()
end

local function getVehicleMileageById(inventoryId)
  return overhaul_career_garage_inventory.getVehicles()[inventoryId].mileage or 0
end

-- Exports -----------------------------------------------------------------------------------------

M.getPartDifference = getPartDifference
M.getVehicleValueFromParts = getVehicleValueFromParts

M.getInventoryVehicleValue = getInventoryVehicleValue
M.getPartValue = getPartValue
M.getPartResaleValue = getPartResaleValue
M.getDepreciatedPartValue = getDepreciatedPartValue
M.getAdjustedVehicleBaseValue = getAdjustedVehicleBaseValue
M.getQuickVehicleValue = getQuickVehicleValue
M.getVehicleMileageById = getVehicleMileageById
M.getInventoryVehicleSellValue = getInventoryVehicleSellValue
M.getBrokenPartsThreshold = getBrokenPartsThreshold
M.getVehiclePcPartsCatalogSum = getVehiclePcPartsCatalogSum
M.getVehiclePartsCatalogValue = getVehiclePartsCatalogValue
M.clearVehiclePcPartsCatalogSumCache = clearVehiclePcPartsCatalogSumCache
M.saveCatalogCache = saveCatalogCache
M.onExtensionUnloaded = saveCatalogCache
M.getVehicleCatalogProfile = getVehicleCatalogProfile
M.getVehicleValuation = getVehicleValuation
M.getVehicleCatalogIntrinsicBookValue = getVehicleCatalogIntrinsicBookValue
M.getOrdinaryAgeRetention = getOrdinaryAgeRetention
M.getMileageRetention = getMileageRetention
M.getVehicleMileageRetention = getVehicleMileageRetention
M.getLowMileagePreservationFloor = getLowMileagePreservationFloor
M.getCommercialAgeFloor = getCommercialAgeFloor
M.getDieselTruckAgeFloor = getDieselTruckAgeFloor
M.getPowertrainValueModifiers = getPowertrainValueModifiers
M.getHighPerformanceScore = getHighPerformanceScore
M.getHighPerformanceRetentionFloor = getHighPerformanceRetentionFloor
M.getCommodityDepreciationMultiplier = getCommodityDepreciationMultiplier
M.getAntiqueAgeFloor = getAntiqueAgeFloor
M.getClassicActivation = getClassicActivation
M.getClassicAgeFloor = getClassicAgeFloor
M.getAgeRetention = getAgeRetention
M.getVehicleListingPriceRange = getVehicleListingPriceRange
M.getVehicleBuyMarketMultiplier = getVehicleBuyMarketMultiplier
M.getVehicleSellMarketMultiplier = getVehicleSellMarketMultiplier
M.applyVehicleBuyMarketToMoney = applyVehicleBuyMarketToMoney

M.getRepairDetails = getRepairDetails
M.getNumberOfBrokenParts = getNumberOfBrokenParts
M.partConditionsNeedRepair = partConditionsNeedRepair
M.getSpawnedVehicleRepairPrice = getSpawnedVehicleRepairPrice
M.getPartMarketMultiplier = getPartMarketMultiplier
return M
