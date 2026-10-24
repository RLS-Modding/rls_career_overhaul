-- Loaner offers: which organization vehicles a facility can loan, the hourly rate, config and facility lookups, and the marks that queue a car for the next spawn. The marks live in the extension state.
-- Read usesSkillUnlocks, usesIndependentHourlyRental, getConfigInfo, getInventoryConfigInfo, isTrailerVehicle in order.

local offers = {}

-- Organizations with this unlock mode lock loaners behind a skill, not a reputation.
local UNLOCK_MODE_SKILL_LEVEL = "skillLevel"
local MATERIALS_BASE_RATE_PER_HOUR = 35
local VEHICLE_BASE_RATE_PER_HOUR = 25
local RATE_PER_REPUTATION_LEVEL = 15
local MINIMUM_RATE_PER_HOUR = 15
local NO_REPUTATION_LEVEL = -1

function offers.new(inputs)
  local loanerState = inputs.state

  -- Skill-unlock organizations list no loaners; every other organization rents by the hour.
  local function usesSkillUnlocks(organization)
    return (organization and organization.loanerUnlockMode == UNLOCK_MODE_SKILL_LEVEL) or false
  end

  local function usesIndependentHourlyRental(organization)
    return not usesSkillUnlocks(organization)
  end

  local function getConfigInfo(model, config)
    if not model or not config then return nil end
    local configInfo = core_vehicles.getConfig(model, config)
    if configInfo and configInfo.infoFilename then
      local rawInfo = jsonReadFile(configInfo.infoFilename)
      configInfo.loanerName = rawInfo and rawInfo.loanerName or nil
    end
    return configInfo
  end

  local function getInventoryConfigInfo(vehicleInfo)
    if not vehicleInfo then return nil end
    local config = vehicleInfo.config
    local configFilename = nil
    if type(config) == "table" and type(config.partConfigFilename) == "string" then
      local _, filename = path.splitWithoutExt(config.partConfigFilename)
      configFilename = filename
    elseif type(config) == "string" then
      local _, filename = path.splitWithoutExt(config)
      configFilename = filename or config
    end
    return getConfigInfo(vehicleInfo.model, configFilename)
  end

  local function isTrailerVehicle(configInfo, model)
    local aggregates = configInfo and configInfo.aggregates
    if aggregates and aggregates.Type and aggregates.Type.Trailer then
      return true
    end
    local modelInfo = model and core_vehicles.getModel(model)
    local modelData = modelInfo and (modelInfo.model or modelInfo)
    return modelData and modelData.Type == "Trailer" or false
  end

  local function isMaterialsEquipment(item)
    item = item or {}
    if overhaul_career_logistics_loanerCapabilities then
      return overhaul_career_logistics_loanerCapabilities.isMaterialsEquipment(item)
    end
    return false
  end

  local function getHourlyRateForOffer(item)
    local reputationLevel = tonumber(item and item.reputationLvl) or NO_REPUTATION_LEVEL
    local baseRate = isMaterialsEquipment(item) and MATERIALS_BASE_RATE_PER_HOUR or VEHICLE_BASE_RATE_PER_HOUR
    return math.max(MINIMUM_RATE_PER_HOUR, math.floor(baseRate + RATE_PER_REPUTATION_LEVEL * (reputationLevel + 1)))
  end

  -- Organization reputation levels are stored from level -1, so index 1 is level -1.
  local function getOrganizationReputationLevel(organization, level)
    if not organization or type(organization.reputationLevels) ~= "table" then return nil end
    local reputationLevel = level
    if reputationLevel == nil and organization.reputation then
      reputationLevel = organization.reputation.level
    end
    return organization.reputationLevels[(tonumber(reputationLevel) or 0) + 2]
  end

  local function getReputationUnlockLabel(organization, reputationLvl)
    local info = getOrganizationReputationLevel(organization, reputationLvl)
    if type(info) == "table" then
      if type(info.label) == "string" and info.label ~= "" then
        return info.label
      end
      for _, unlock in ipairs(info.unlocks or {}) do
        if type(unlock) == "table" and type(unlock.label) == "string" and unlock.label ~= "" then
          return unlock.label
        end
      end
    end
    return string.format("level %d", tonumber(reputationLvl) or 0)
  end

  local function flattenXY(dir, fallback)
    local flat = vec3(dir.x, dir.y, 0)
    if flat:squaredLength() > 1e-6 then
      flat:normalize()
      return flat
    end
    return fallback or vec3(0, -1, 0)
  end

  local function getDeliveryFacility(facilityId)
    if not facilityId then return nil end
    local facility = overhaul_career_logistics_generator.getFacilityById(facilityId)
    if facility then return facility end
    return overhaul_world_facilities.getFacility("deliveryProvider", facilityId, true)
  end

  local function getInspectParkingSpot(facility)
    if not facility then return nil end
    if facility.inspectSpots and facility.inspectSpots[1] then
      return facility.inspectSpots[1]
    end
    if facility.accessPointsByName then
      for _, accessPoint in pairs(facility.accessPointsByName) do
        if accessPoint.isInspectSpot and accessPoint.ps then
          return accessPoint.ps
        end
      end
    end
    return nil
  end

  local function markForSpawning(offer)
    local marked = loanerState.markedForSpawningLoaners
    if marked[offer.id] then
      marked[offer.id] = nil
    else
      marked[offer.id] = offer
    end
  end

  local function setMarkedForSpawning(offer, marked)
    if not offer or not offer.id then return end
    if marked then
      loanerState.markedForSpawningLoaners[offer.id] = offer
    else
      loanerState.markedForSpawningLoaners[offer.id] = nil
    end
  end

  local function unmarkAllForSpawning()
    loanerState.markedForSpawningLoaners = {}
  end

  local function hasMarkedOffers()
    return next(loanerState.markedForSpawningLoaners) ~= nil
  end

  -- A company offer has no facility or id of its own when it is marked; fill in what is missing.
  local function markCompanyOffer(offer, sourceFacilityId, idPrefix)
    if not offer then return end
    offer.loanType = "company"
    if not offer.sourceFacility or not offer.sourceFacility.id then
      if sourceFacilityId then
        offer.sourceFacility = { type = "deliveryProvider", id = sourceFacilityId }
      end
    end
    if not offer.id then
      local facilityId = offer.sourceFacility and offer.sourceFacility.id or sourceFacilityId or "company"
      offer.id = string.format("%s-%s-%s-%s", idPrefix or "company",
        tostring(facilityId), tostring(offer.model or "m"), tostring(offer.config or "c"))
    end
    setMarkedForSpawning(offer, true)
  end

  return {
    flattenXY = flattenXY,
    getConfigInfo = getConfigInfo,
    getDeliveryFacility = getDeliveryFacility,
    getInspectParkingSpot = getInspectParkingSpot,
    getInventoryConfigInfo = getInventoryConfigInfo,
    getHourlyRateForOffer = getHourlyRateForOffer,
    getOrganizationReputationLevel = getOrganizationReputationLevel,
    getReputationUnlockLabel = getReputationUnlockLabel,
    isMaterialsEquipment = isMaterialsEquipment,
    isTrailerVehicle = isTrailerVehicle,
    usesSkillUnlocks = usesSkillUnlocks,
    usesIndependentHourlyRental = usesIndependentHourlyRental,
    markForSpawning = markForSpawning,
    setMarkedForSpawning = setMarkedForSpawning,
    unmarkAllForSpawning = unmarkAllForSpawning,
    hasMarkedOffers = hasMarkedOffers,
    markCompanyOffer = markCompanyOffer,
  }
end

return offers
