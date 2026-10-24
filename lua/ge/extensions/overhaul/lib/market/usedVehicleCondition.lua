-- Generates used-vehicle model years and mileage, with the wear each seller's cars carry.
-- Facility policies select reusable profiles; vehicle categories provide neutral defaults.
local M = {}
local jsonCatalog = require("overhaul/lib/platform/jsonCatalog")

local config = {
  MILES_TO_METERS = 1609.344, BASE_ANNUAL_MILES = 11500, MAX_USED_MILES = 300000,
  FACTORY_MIN_MILES = 5, FACTORY_MAX_MILES = 500, MISSING_YEARS_FALLBACK_MODEL_YEAR = 2023,
}

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

-- Engine helper when it exists; the fallback sums the same three draws.
local randomGauss3 = randomGauss3 or function() return math.random() + math.random() + math.random() end

local function normalizeYearRange(years)
  if type(years) ~= "table" then
    return nil
  end
  local minYear = tonumber(years.min)
  local maxYear = tonumber(years.max)
  if not jsonCatalog.finite(minYear) or not jsonCatalog.finite(maxYear) or minYear > maxYear then
    return nil
  end
  return {min = minYear, max = maxYear}
end

-- New factory cars: a few miles on the odometer.
local function factoryMileage()
  return (config.FACTORY_MIN_MILES + math.random() * (config.FACTORY_MAX_MILES - config.FACTORY_MIN_MILES)) * config.MILES_TO_METERS,
    nil, "factoryDelivery"
end

local function remanufacturedMileage(seller)
  local isCommercialRemanufacture = seller.remanCommercial == true
  local minMiles = isCommercialRemanufacture and 60000 or 20000
  local maxMiles = isCommercialRemanufacture and 180000 or 80000
  return (minMiles + randomGauss3() / 3 * (maxMiles - minMiles)) * config.MILES_TO_METERS,
    nil, isCommercialRemanufacture and "commercialReman" or "certifiedReman"
end

local profileCatalog

local function validProfile(profile)
  if type(profile) ~= 'table' then return false end
  for _, value in pairs(profile) do
    if not jsonCatalog.finite(value) or value < 0 then return false end
  end
  if (profile.minFactor or 0.75) > (profile.maxFactor or 1.25) then return false end
  if (profile.minMiles or 0) > (profile.maxMiles or config.MAX_USED_MILES) then return false end
  return true
end

local function conditionPolicies()
  if profileCatalog then return profileCatalog end
  local data = jsonReadFile('/gameplay/overhaul/market/usedVehicleProfiles.json')
  if type(data) ~= 'table' or data.version ~= 1 or type(data.profiles) ~= 'table' then
    log('W', 'usedVehicleCondition', 'Used-vehicle profile catalog unavailable')
    return {profiles = {}}
  end
  for id, profile in pairs(data.profiles) do
    if not validProfile(profile) then
      log('W', 'usedVehicleCondition', 'Ignoring invalid profile: ' .. tostring(id))
      data.profiles[id] = nil
    end
  end
  profileCatalog = data
  return profileCatalog
end

-- Dealer loading owns the diagnostic and skip; vehicle operations never quarantine a seller policy.
function M.validateSellerPolicy(seller)
  if seller.usedVehicleCondition ~= nil then
    if not validProfile(seller.usedVehicleCondition) then return false, 'invalid inline usedVehicleCondition' end
    return true
  end
  if seller.usedVehicleProfile ~= nil and not conditionPolicies().profiles[seller.usedVehicleProfile] then
    return false, 'usedVehicleProfile unavailable: ' .. tostring(seller.usedVehicleProfile)
  end
  return true
end

-- Explicit policies win; shipped sellers retain their authored category overrides.
local function profileForVehicle(seller, vehicleInfo)
  if type(seller.usedVehicleCondition) == 'table' then return seller.usedVehicleCondition end
  local catalog = conditionPolicies()
  local explicit = seller.usedVehicleProfile and catalog.profiles[seller.usedVehicleProfile]
  if seller.usedVehicleProfile and not explicit then
    return nil
  end
  if explicit and not seller.usedVehicleCategoryOverrides then return explicit end
  local categories = catalog.categoryProfiles or {}
  local category = (categories.configTypes or {})[vehicleInfo['Config Type']]
    or (categories.bodyStyles or {})[vehicleInfo['Body Style']]
  local channel = (catalog.channelProfiles or {})[seller.salesChannel]
  return catalog.profiles[category] or explicit or catalog.profiles[channel] or {}
end

-- Expected miles for the age, scaled by the profile's random factor and bounded by it.
local function ageCurveMiles(profile, vehicleAgeYears)
  local expectedMileageMiles = M.getExpectedMileageMiles(vehicleAgeYears, profile.annualMiles)
  local minFactor = tonumber(profile.minFactor) or 0.75
  local maxFactor = tonumber(profile.maxFactor) or 1.25
  local mileageFactor = minFactor + randomGauss3() / 3 * (maxFactor - minFactor)
  local mileageMiles = expectedMileageMiles * mileageFactor

  if vehicleAgeYears == 0 then
    mileageMiles = math.max(50, math.min(mileageMiles, 15000))
  elseif vehicleAgeYears >= 15 then
    mileageMiles = math.max(mileageMiles, tonumber(profile.minMiles) or 5000)
  end
  mileageMiles = clamp(mileageMiles, tonumber(profile.minMiles) or 0, tonumber(profile.maxMiles) or config.MAX_USED_MILES)
  if mileageMiles >= config.MAX_USED_MILES then
    -- Spreads extreme-use cars over a 270k-300k band, not one hard-capped odometer.
    mileageMiles = config.MAX_USED_MILES - math.random() * 30000
  end
  return mileageMiles
end

-- Wear policy can represent competition use or restored and collector classics.
local function wearForVehicle(vehicleAgeYears, profile, odometerMeters)
  if profile.wearFactor and profile.wearFactor > 1 then
    return odometerMeters * profile.wearFactor, "competitionWear"
  end
  if profile.classicMinAge and vehicleAgeYears >= profile.classicMinAge then
    if math.random() < (profile.restoredClassicChance or 0) then
      return math.max((profile.restoredMinMiles or 0) * config.MILES_TO_METERS, odometerMeters * (profile.restoredWearFactor or 1)), "restoredClassic"
    end
    return odometerMeters * (profile.collectorWearFactor or 1), "collectorDriver"
  end
  return nil, "ageCurve"
end

-- Survivors age slowly after 25 years, so classics do not all turn into 400k-mile cars.
function M.getExpectedMileageMiles(vehicleAgeYears, annualMiles)
  vehicleAgeYears = math.max(0, tonumber(vehicleAgeYears) or 0)
  annualMiles = tonumber(annualMiles) or config.BASE_ANNUAL_MILES
  if vehicleAgeYears <= 25 then
    return vehicleAgeYears * annualMiles
  end
  return 25 * annualMiles + (vehicleAgeYears - 25) * math.min(annualMiles, 2500)
end

-- Returns odometer meters, wear meters (nil unless the seller's wear shows) and the mileage class.
function M.generateAgeDrivenMileage(seller, vehicleInfo, year)
  local currentYear = tonumber(os.date("%Y")) or 2026
  local vehicleAgeYears = math.max(0, currentYear - (tonumber(year) or currentYear))
  local channel = seller.salesChannel or "local"

  if channel == "factory" then
    return factoryMileage()
  end
  if channel == "remanufactured" then
    return remanufacturedMileage(seller)
  end

  local profile = profileForVehicle(seller, vehicleInfo)
  if not profile then return nil, nil, "unavailable" end
  if vehicleAgeYears >= 25 and math.random() < (tonumber(profile.timeCapsuleChance) or 0) then
    return (5000 + randomGauss3() / 3 * 15000) * config.MILES_TO_METERS, nil, "timeCapsule"
  end

  local odometerMeters = math.max(0, ageCurveMiles(profile, vehicleAgeYears) * config.MILES_TO_METERS)
  local wearMileageMeters, mileageCategory = wearForVehicle(vehicleAgeYears, profile, odometerMeters)
  return odometerMeters, wearMileageMeters, mileageCategory
end

-- Returns {min, max} for a vehicle's years, from Years or its aggregates; nil when unusable.
function M.safeYearsRange(vehicleInfo)
  if type(vehicleInfo) ~= "table" then
    return nil
  end
  return normalizeYearRange(vehicleInfo.Years) or
    normalizeYearRange(type(vehicleInfo.aggregates) == "table" and vehicleInfo.aggregates.Years or nil)
end

-- Sets vehicleInfo.year, Mileage, wearMileage and mileageClass; nil when the years are empty.
function M.generateUsedVehicleCondition(seller, vehicleInfo)
  local years = M.safeYearsRange(vehicleInfo)
  local filter = vehicleInfo.filter or {}
  if years then
    local bounds = filter.whiteList and filter.whiteList.Years or {}
    local minYear = math.max(years.min, tonumber(bounds.min) or years.min)
    local maxYear = math.min(years.max, tonumber(bounds.max) or years.max)
    if minYear > maxYear then return nil end
    vehicleInfo.year = math.random(minYear, maxYear)
  else
    vehicleInfo.year = tonumber(vehicleInfo.year) or config.MISSING_YEARS_FALLBACK_MODEL_YEAR
  end
  vehicleInfo.Mileage, vehicleInfo.wearMileage, vehicleInfo.mileageClass =
    M.generateAgeDrivenMileage(seller or {salesChannel = "private"}, vehicleInfo, vehicleInfo.year)
  return vehicleInfo.Mileage and vehicleInfo or nil
end

M.profileForVehicle = profileForVehicle
return M
