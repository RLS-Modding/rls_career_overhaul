-- Tire integration provenance and notices: licenses/tyre-thermals-NOTICE.md.
-- Pure tire-model helpers shared by GE, vehicle Lua, and standalone tests.
-- Classification and surface tuning stay shared so both VMs calculate the same wear.
local M = {}

local min = math.min
local max = math.max

local MILEAGE_SEED = {
  wearFraction = 0.6,
  referenceMiles = 300000,
  minimumRemaining = 0.40,
}

local WIDTH_WEAR = {
  referenceMeters = 0.205,
  minimumMeters = 0.150,
  minimumMultiplier = 0.75,
  maximumMultiplier = 1.25,
}

-- The exponent and gain calibrate the historical curve; they are empirical rather than physical units.
local TEMPERATURE_WEAR = {
  defaultWorkingC = 85,
  minimumWorkingC = 1,
  overheatExponent = 1.35,
  overheatGain = 8,
  maximumExtraWear = 5,
}

local DEFAULT_WET_GRIP_MULTIPLIERS = {
  standard = 1.00,
  sport = 0.94,
  race = 0.80,
  drag = 0.72,
}

local WET_CAPABLE_IDENTIFIERS = {
  "standard", "touring", "allseason", "all_season", "eco", "rally", "offroad",
  "off_road", "allterrain", "all_terrain", "winter", "snow", "mud",
}

local DEFAULT_SURFACE_TUNING = {
  thermalMultiplier = 1,
  abrasionMultiplier = 1,
}

local SURFACE_TUNING = {
  dirt = {
    thermalMultiplier = 0.55,
    abrasionMultiplier = 0.50,
    thermalSlipCap = 3.00,
    abrasionSlipCap = 2.50,
  },
  looseDirt = {
    thermalMultiplier = 0.40,
    abrasionMultiplier = 0.35,
    thermalSlipCap = 2.50,
    abrasionSlipCap = 2.00,
  },
  sand = {
    thermalMultiplier = 0.30,
    abrasionMultiplier = 0.25,
    thermalSlipCap = 1.75,
    abrasionSlipCap = 1.25,
  },
  mud = {
    thermalMultiplier = 0.10,
    abrasionMultiplier = 0.08,
    thermalSlipCap = 1.25,
    abrasionSlipCap = 0.75,
  },
}

local function containsAny(value, identifiers)
  for _, identifier in ipairs(identifiers) do
    local token = "_" .. string.lower(tostring(identifier)):gsub("[^%w]+", "_") .. "_"
    if string.find(value, token, 1, true) then return true end
  end
  return false
end

local function clamp(value, lower, upper)
  return min(max(tonumber(value) or 0, lower), upper)
end

function M.clamp(value, lower, upper)
  return clamp(value, lower, upper)
end

function M.remainingFromMiles(miles)
  -- Seed untracked tires from mileage; ongoing wear can still go below this floor.
  return clamp(1 - MILEAGE_SEED.wearFraction * max(tonumber(miles) or 0, 0)
    / MILEAGE_SEED.referenceMiles, MILEAGE_SEED.minimumRemaining, 1)
end

function M.widthWearMultiplier(widthMeters)
  local effectiveWidth = max(tonumber(widthMeters) or WIDTH_WEAR.referenceMeters, WIDTH_WEAR.minimumMeters)
  return clamp(WIDTH_WEAR.referenceMeters / effectiveWidth, WIDTH_WEAR.minimumMultiplier, WIDTH_WEAR.maximumMultiplier)
end

function M.temperatureWearMultiplier(temperatureC, workingTemperatureC)
  local working = max(tonumber(workingTemperatureC) or TEMPERATURE_WEAR.defaultWorkingC, TEMPERATURE_WEAR.minimumWorkingC)
  local overheat = max((tonumber(temperatureC) or working) - working, 0) / working
  return 1 + clamp(overheat ^ TEMPERATURE_WEAR.overheatExponent * TEMPERATURE_WEAR.overheatGain,
    0, TEMPERATURE_WEAR.maximumExtraWear)
end

function M.overheatGripWearMultiplier(inherentGrip, temperatureC, workingTemperatureC)
  local gripNormalizationSpan = 0.30
  local extraWearGain = 0.10

  local working = max(tonumber(workingTemperatureC) or 85, 1)
  local overheat = clamp(((tonumber(temperatureC) or working) - working) / working, 0, 1)
  local normalizedGrip = clamp(((tonumber(inherentGrip) or 1) - 1) / gripNormalizationSpan, 0, 1)
  return 1 + normalizedGrip * overheat * extraWearGain
end

function M.overheatWearMultiplier(inherentGrip, temperatureC, workingTemperatureC)
  local thermal = M.temperatureWearMultiplier(temperatureC, workingTemperatureC)
  local compound = M.overheatGripWearMultiplier(inherentGrip, temperatureC, workingTemperatureC)
  -- Halve extra overheating wear while preserving ordinary wear and the smooth transition at working temperature.
  return 1 + (thermal * compound - 1) * 0.5
end

function M.waterCoolingMultiplier(inWater)
  -- BeamNG's brake thermals use 1 + a default underwater coefficient of 20.
  return inWater == true and 21 or 1
end

function M.wheelTouchesWater(rotator, vehicleObject)
  if type(rotator) ~= "table" or vehicleObject == nil then return false end

  -- Contact and tread nodes reach shallow puddles that wheel-center axle nodes miss.
  if rotator.lastTreadContactNode ~= nil and vehicleObject:inWater(rotator.lastTreadContactNode) then
    return true
  end
  for _, nodeId in ipairs(rotator.treadNodes or {}) do
    if vehicleObject:inWater(nodeId) then return true end
  end
  for _, nodeId in ipairs(rotator.nodes or {}) do
    if vehicleObject:inWater(nodeId) then return true end
  end

  -- Simplified/custom wheels may not expose their tire node lists.
  return (rotator.node1 ~= nil and vehicleObject:inWater(rotator.node1)) or
         (rotator.node2 ~= nil and vehicleObject:inWater(rotator.node2)) or false
end

function M.temperatureWithAmbientFloor(temperatureC, ambientTemperatureC)
  local ambient = tonumber(ambientTemperatureC) or 21
  return max(tonumber(temperatureC) or ambient, ambient)
end

function M.slipSeverities(longitudinalSlip, lateralSlip)
  local longitudinal = math.abs(tonumber(longitudinalSlip) or 0)
  local lateral = math.abs(tonumber(lateralSlip) or 0)

  -- Restrict abrasion to obvious wheelspin and sustained slides so mild understeer contributes heat alone.
  local thermal = max(longitudinal - 0.15, 0) + max(lateral - 0.05, 0) * 0.20
  local longitudinalAbrasion = max(longitudinal - 1.00, 0)
  local lateralAbrasion = max(lateral - 1.50, 0) * 0.12
  local abrasion = longitudinalAbrasion + lateralAbrasion
  -- Keep separate cold-start calibrations: about 10 condition points/minute of burnout and 0.35 points/3 minutes of sliding.
  local wearMultiplier = abrasion > 0 and
    (longitudinalAbrasion * 8 + lateralAbrasion * 2.5) / abrasion or 1
  return thermal, abrasion, wearMultiplier
end

function M.surfaceTireTuning(groundName)
  local name = string.upper(tostring(groundName or ""))

  -- Match yielding surfaces first because DIRT_SANDY also contains DIRT.
  if string.find(name, "MUD", 1, true) then return SURFACE_TUNING.mud end
  if string.find(name, "SAND", 1, true) then return SURFACE_TUNING.sand end
  if string.find(name, "DIRT", 1, true) and string.find(name, "LOOSE", 1, true) then
    return SURFACE_TUNING.looseDirt
  end
  if string.find(name, "DIRT", 1, true) or string.find(name, "GRAVEL", 1, true) then
    return SURFACE_TUNING.dirt
  end
  return DEFAULT_SURFACE_TUNING
end

function M.smoothSlipCap(severity, cap)
  local value = max(tonumber(severity) or 0, 0)
  local limit = tonumber(cap)
  if not limit or limit <= 0 then return value end

  -- A smooth slip cap prevents loose-ground wheel-speed spikes from dominating heat.
  return value / math.sqrt(1 + (value / limit) ^ 2)
end

function M.combineWearComponents(distanceWear, slipWear, loadMultiplier)
  -- Slip abrasion already includes wheel load; apply extra load only to rolling wear to avoid counting it twice.
  return max(tonumber(distanceWear) or 0, 0) * max(tonumber(loadMultiplier) or 0, 0) +
         max(tonumber(slipWear) or 0, 0)
end

function M.gripMultiplier(remaining, temperatureC, workingTemperatureC)
  local peakTemperatureGrip = 1.01
  local temperatureDeviationReferenceC = 130
  local temperatureLossExponent = 1.3
  local temperatureLossGain = 0.12
  local maximumTemperatureLoss = 0.18

  local baseTreadGrip = 0.75
  local remainingTreadBlend = 0.25

  local minimumGripMultiplier = 0.60
  local maximumGripMultiplier = 1.02

  local tread = clamp(remaining, 0, 1)
  local working = max(tonumber(workingTemperatureC) or 85, 1)
  local distance = math.abs((tonumber(temperatureC) or working) - working)
  local temperatureGrip = peakTemperatureGrip - clamp((distance / temperatureDeviationReferenceC) ^
    temperatureLossExponent * temperatureLossGain, 0, maximumTemperatureLoss)
  local wearGrip = baseTreadGrip + remainingTreadBlend * math.sqrt(tread)
  return clamp(temperatureGrip * wearGrip, minimumGripMultiplier, maximumGripMultiplier)
end

function M.classifyTireCompound(tire)
  tire = type(tire) == "table" and tire or {}
  local identity = "_" .. string.lower(table.concat({
    tostring(tire.partOrigin or ""),
    tostring(tire.partPath or ""),
  }, " ")):gsub("[^%w]+", "_") .. "_"

  -- Explicit wet-capable families take priority over broad performance words in custom part paths.
  if containsAny(identity, WET_CAPABLE_IDENTIFIERS) then return "standard" end
  if containsAny(identity, {"drag"}) then return "drag" end
  if containsAny(identity, {"slick", "semislick", "semi_slick", "race", "racing", "competition"}) then
    return "race"
  end
  if containsAny(identity, {"sport", "performance", "highperformance", "high_performance"}) then
    return "sport"
  end

  local staticFriction = tonumber(tire.baseFriction or tire.frictionCoef) or 1
  local slidingFriction = tonumber(tire.slidingFriction or tire.slidingFrictionCoef) or staticFriction
  local averageFriction = (staticFriction + slidingFriction) * 0.5
  if averageFriction >= 1.20 then return "drag" end

  local treadCoef = tonumber(tire.treadCoef)
  if treadCoef and treadCoef <= 0.15 then return "race" end
  return "standard"
end

function M.wetGripMultiplier(wetness, tire, configuredMultipliers)
  return M.wetGripMultiplierForCompound(wetness, M.classifyTireCompound(tire), configuredMultipliers)
end

function M.wetGripMultiplierForCompound(wetness, compound, configuredMultipliers)
  local configured = type(configuredMultipliers) == "table" and configuredMultipliers or {}
  local fullWetMultiplier = tonumber(configured[compound]) or DEFAULT_WET_GRIP_MULTIPLIERS[compound] or 1
  fullWetMultiplier = clamp(fullWetMultiplier, 0.10, 1)
  local normalizedWetness = clamp(wetness, 0, 1)
  return 1 + (fullWetMultiplier - 1) * normalizedWetness, compound
end

function M.wetnessForSurface(wetness, groundName, wetGroundModels)
  if type(wetGroundModels) ~= "table" or wetGroundModels[tostring(groundName or "")] ~= true then
    return 0
  end
  return clamp(wetness, 0, 1)
end

function M.average(values, fallback)
  local total, count = 0, 0
  for _, value in pairs(values or {}) do
    if tonumber(value) then
      total = total + tonumber(value)
      count = count + 1
    end
  end
  return count > 0 and total / count or fallback
end

function M.selectProvider(externalPresent, apiCompatible)
  if externalPresent then
    return apiCompatible and "external" or "legacy"
  end
  return "bundled"
end

return M
