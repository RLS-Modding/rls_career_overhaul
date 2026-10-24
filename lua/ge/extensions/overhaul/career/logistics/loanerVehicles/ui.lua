-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Loaner menu rows: which loaners a facility lists, whether each can be taken, and the row data the menu shows.
-- Part of the Overhaul fork of stock career/modules/loanerVehicles.lua. Map: shared helpers, fleet, space, availability, unlock text, row projection, part API.

local issued = require('overhaul/lib/vehicles/issued')

local ui = {}

-- Mileage added per second since the save was created: about 500 km per day, spread by 10% per offer.
local MILEAGE_PER_SAVE_SECOND = 5.8

function ui.new(inputs)
  local loanerState = inputs.state
  local offers, returns, dateUtils = inputs.offers, inputs.returns, inputs.dateUtils

  local function capacityIcon(kind) return overhaul_career_logistics_parcelMods.getModifierIcon(kind) end
  local function capacityText(key, values) return core_locales.contextTranslate(key, values) end

  -- Capacity labels for a config, or nil when the config lists no capacity.
  local function capacityLabels(configInfo)
    if not (configInfo and configInfo.capacity) then return nil end
    local labels = {}
    for _, capacity in ipairs(configInfo.capacity) do
      local label = require('overhaul/lib/logistics/cargoSemantics').capacityLabel(capacity, capacityIcon, capacityText)
      if label then table.insert(labels, label) end
    end
    return labels
  end

  -- Non-trailer loaners an organization already has out. A trailer never counts against the one-loaner limit.
  local function loanedNonTrailerCount(organizationId)
    local count = 0
    for _, vehicleInfo in pairs(overhaul_career_garage_inventory.getVehicles()) do
      if vehicleInfo.owningOrganization == organizationId then
        local configInfo = offers.getInventoryConfigInfo(vehicleInfo)
        if not offers.isTrailerVehicle(configInfo, vehicleInfo.model) then
          count = count + 1
        end
      end
    end
    return count
  end

  local function appliesRevenueShare(loanType)
    local record = issued.forVehicle({loanType = loanType})
    return not record or record.isWork
  end

  local function getLoaningOrgsOfVehicle(vehId)
    local loaningOrgs = {}
    if not vehId or vehId < 0 then return loaningOrgs end
    local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId)
    local vehInfo = overhaul_career_garage_inventory.getVehicles()[inventoryId]
    if vehInfo and vehInfo.owningOrganization and appliesRevenueShare(vehInfo.loanType) then
      loaningOrgs[vehInfo.owningOrganization] = true
    end

    local pullingVehicleId = core_trailerRespawn and core_trailerRespawn.getAttachedNonTrailer and core_trailerRespawn.getAttachedNonTrailer(vehId)
    if pullingVehicleId then
      local pullingInventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(pullingVehicleId)
      local pullingVehInfo = overhaul_career_garage_inventory.getVehicles()[pullingInventoryId]
      if pullingVehInfo and pullingVehInfo.owningOrganization and appliesRevenueShare(pullingVehInfo.loanType) then
        loaningOrgs[pullingVehInfo.owningOrganization] = true
      end
    end
    return loaningOrgs
  end

  -- Offers already marked for the next spawn, counted as non-trailers and trailers.
  local function countMarkedOffers()
    local nonTrailers, trailers = 0, 0
    for _, offer in pairs(loanerState.markedForSpawningLoaners) do
      local configInfo = offers.getConfigInfo(offer.model, offer.config)
      if offers.isTrailerVehicle(configInfo, offer.model) then
        trailers = trailers + 1
      else
        nonTrailers = nonTrailers + 1
      end
    end
    return nonTrailers, trailers
  end

  -- Spawned loaners ----------------------------------------------------------------------------------

  -- Mileage for a rental: the entry for the organization's reputation level, else the first entry listed.
  local function rentalMileageOf(rentalVehicleInfo, organization)
    if rentalVehicleInfo.mileages then
      local reputationLevel = organization and organization.reputation and organization.reputation.level or 0
      if rentalVehicleInfo.mileages[tostring(reputationLevel)] then
        return rentalVehicleInfo.mileages[tostring(reputationLevel)]
      else
        return select(2, next(rentalVehicleInfo.mileages))
      end
    end
    if rentalVehicleInfo.mileage then
      return rentalVehicleInfo.mileage
    end
    return 0
  end

  local function spawnedLoanerRow(vehInfo)
    local veh = deepcopy(vehInfo)
    local organization = overhaul_world_organizations.getOrganization(veh.owningOrganization)
    local configInfo = offers.getInventoryConfigInfo(vehInfo)
    local reputationLevel = offers.getOrganizationReputationLevel(organization)

    local record = issued.forVehicle(veh) or {}
    veh.loanerCut = not (record.isRental or record.isCompany) and (reputationLevel and reputationLevel.loanerCut or 0) or nil
    veh.hourlyRate = record.isRental and (veh.rentalHourlyRate or offers.getHourlyRateForOffer(veh)) or nil
    local nameOk, translatedName = pcall(overhaul_career_garage_inventory.getVehicleNiceNameTranslated, veh.id)
    veh.name = configInfo and configInfo.loanerName or (nameOk and translatedName or veh.niceName)
    if type(veh.name) ~= "string" or veh.name == "" then
      local offerName = configInfo and configInfo.Name
      offerName = core_locales.translateWithOrWithoutContext(offerName)
      veh.name = (type(offerName) == "string" and offerName ~= "") and offerName or (veh.model or "Loaner")
    end
    local mileageOk, mileage = pcall(overhaul_career_market_valueCalculator.getVehicleMileageById, veh.id)
    veh.vehMileage = mileageOk and mileage or 0
    veh.organizationName = organization and organization.name or veh.owningOrganization or "Unknown organization"
    veh.vehOfferType = offers.isTrailerVehicle(configInfo, vehInfo.model) and "trailer" or "vehicle"
    veh.enabled = true
    veh.isSpawnedLoaner = true
    local labels = capacityLabels(configInfo)
    if labels then veh.capacity = labels end
    return veh
  end

  local function formatSpawnedLoanersForUi()
    local rows = {}
    for _, vehInfo in ipairs(returns.getLoanedVehicles()) do
      table.insert(rows, spawnedLoanerRow(vehInfo))
    end
    return rows
  end

  -- Offer rows: the fleet ----------------------------------------------------------------------------

  -- A delivery facility may define a purpose-built fleet without changing every other facility that shares its organization. Existing organization fleets remain the fallback for facilities that do not opt in.
  local function loanableVehiclesOf(facility, organization)
    return facility.loanableVehicles or organization.loanableVehicles or {}
  end

  -- Offer rows: space and limits ---------------------------------------------------------------------

  -- Occupied stalls still count in the menu. Spawn highlights them and waits for Spawn vehicle once clear; it does not XY-nudge around blockers.
  local function facilityHasSpaceFor(facility, isTrailer, spawnsOfSameType)
    local spots = (isTrailer and facility.loanerTrailerSpots or facility.loanerNonTrailerSpots) or {}
    local remaining = spawnsOfSameType
    for _ in ipairs(spots) do
      remaining = remaining - 1
      if remaining < 0 then return true end
    end
    return (not isTrailer and offers.getInspectParkingSpot(facility)) and true or false
  end

  -- Offer rows: availability -------------------------------------------------------------------------

  -- The reputation lock: why the offer is disabled, and the unlock text that says what to reach.
  local function reputationLockOf(organization, requiredReputationLvl)
    local reputationLabel = offers.getReputationUnlockLabel(organization, requiredReputationLvl)
    local longLabel = core_locales.contextTranslate("ui.career.loaner.disableReason.requiresReputation", {
      reputationLabel = reputationLabel,
      organizationName = organization.name,
    })
    return {
      disableReason = {type = "locked", icon = "peopleOutline", level = requiredReputationLvl, label = longLabel},
      unlockInfo = {
        type = "minLevel",
        icon = "peopleOutline",
        longLabel = longLabel,
        shortLabel = core_locales.contextTranslate("ui.career.loaner.unlockInfo.reputationLevel", {
          reputationLabel = reputationLabel,
          level = requiredReputationLvl,
        }),
      },
    }
  end

  -- Enabled state and the reason it is disabled. Checks run in order and a later one overrides an earlier one: a reputation lock outranks a full stall or the one-loaner limit.
  local function offerAvailability(facility, organization, organizationId, isTrailer, spawnsOfSameType,
      numberNonTrailersToBeSpawned, requiredReputationLvl)
    local enabled, disableReason, unlockInfo = true, nil, nil
    if not facilityHasSpaceFor(facility, isTrailer, spawnsOfSameType) then
      enabled = false
      disableReason = {
        type = "noSpace",
        label = "There are no parking spots for loaner vehicles of this type.",
      }
    end

    if not isTrailer and (loanedNonTrailerCount(organizationId) + numberNonTrailersToBeSpawned) > 0 then
      enabled = false
      disableReason = {
        type = "limit",
        label = _tr("ui.career.loaner.disableReason.alreadyHaveLoaner"),
      }
    end

    local playerRepLevel = (organization.reputation and tonumber(organization.reputation.level)) or 0
    if requiredReputationLvl ~= nil and requiredReputationLvl > playerRepLevel then
      local lock = reputationLockOf(organization, requiredReputationLvl)
      enabled = false
      disableReason, unlockInfo = lock.disableReason, lock.unlockInfo
    end
    return enabled, disableReason, unlockInfo
  end

  -- Unlock text for an enabled offer that needs a reputation level; it names the level to keep.
  local function reputationUnlockInfo(organization, requiredReputationLvl)
    local reputationLabel = offers.getReputationUnlockLabel(organization, requiredReputationLvl)
    local repLabel = core_locales.contextTranslate("ui.career.loaner.unlockInfo.reputationLevel", {
      reputationLabel = reputationLabel,
      level = requiredReputationLvl,
    })
    return {
      type = "minLevel",
      icon = "peopleOutline",
      longLabel = core_locales.contextTranslate("ui.career.loaner.unlockInfo.requiresReputation", {reputationLabel = repLabel}),
      shortLabel = repLabel,
    }
  end

  -- Offer rows: the row -----------------------------------------------------------------------------

  local function saveFileAgeSeconds()
    local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
    local saveData = (savePath and jsonReadFile(savePath .. "/info.json")) or {}
    return saveData.creationDate and dateUtils.timeSince(saveData.creationDate) or 0
  end

  -- One row. Each row draws exactly one mileage number from the RNG, in fleet order, whether it is enabled or not.
  local function offerRevenueShare(organization, hourlyRental)
    local cut = (offers.getOrganizationReputationLevel(organization) or {}).loanerCut or 0
    -- Hourly rent replaces the organization's share of delivery revenue.
    if hourlyRental then return nil end
    return cut
  end

  -- The loaner name, else the config's name, else the model.
  local function offerDisplayName(configInfo, rentalVehicleInfo)
    local offerName = configInfo and (configInfo.loanerName or configInfo.Name)
    offerName = core_locales.translateWithOrWithoutContext(offerName)
    if type(offerName) ~= "string" or offerName == "" then
      offerName = rentalVehicleInfo.config or rentalVehicleInfo.model or "Loaner"
    end
    return offerName
  end

  local function offerRow(facility, organization, displayIndex, rentalVehicleInfo, secondsSinceSaveFileCreation)
    local organizationId = facility.associatedOrganization
    local configInfo = offers.getConfigInfo(rentalVehicleInfo.model, rentalVehicleInfo.config)
    local isTrailer = offers.isTrailerVehicle(configInfo, rentalVehicleInfo.model)
    local numberNonTrailersToBeSpawned, numberTrailersToBeSpawned = countMarkedOffers()
    local spawnsOfSameType = isTrailer and numberTrailersToBeSpawned or numberNonTrailersToBeSpawned

    local requiredSkillLevel = tonumber(rentalVehicleInfo.requiredSkillLevel or rentalVehicleInfo.requiredPoliceLevel) or 0
    local requiredReputationLvl = tonumber(rentalVehicleInfo.reputationLvl)
    local enabled, disableReason, unlockInfo = offerAvailability(facility, organization, organizationId,
      isTrailer, spawnsOfSameType, numberNonTrailersToBeSpawned, requiredReputationLvl)

    local hourlyRental = offers.usesIndependentHourlyRental(organization)
    local id = string.format("%s-%04d", organizationId, displayIndex)

    -- An offer already being brought out stays enabled, whatever its lock says.
    if loanerState.markedForSpawningLoaners[id] then
      enabled = true
      disableReason = nil
    end
    local offerName = offerDisplayName(configInfo, rentalVehicleInfo)
    local hourlyRate = hourlyRental and offers.getHourlyRateForOffer(rentalVehicleInfo) or nil
    local item = {
      id = id,
      model = rentalVehicleInfo.model,
      config = rentalVehicleInfo.config,
      loanerCut = offerRevenueShare(organization, hourlyRental),
      hourlyRate = hourlyRate,
      vehOfferType = isTrailer and "trailer" or "vehicle",
      name = offerName,
      vehMileage = rentalMileageOf(rentalVehicleInfo, organization)
        + (MILEAGE_PER_SAVE_SECOND + MILEAGE_PER_SAVE_SECOND * ((math.random() * 0.2) - 0.1)) * secondsSinceSaveFileCreation,
      thumbnail = configInfo and configInfo.preview or '/ui/images/appDefault.png',
      connector = rentalVehicleInfo.connector or "ConName",
      reputationLvl = rentalVehicleInfo.reputationLvl,
      deliveryLvl = rentalVehicleInfo.deliveryLvl,
      maxParcelPayloadKg = rentalVehicleInfo.maxParcelPayloadKg,
      enabled = enabled,
      disableReason = disableReason,
      unlockInfo = unlockInfo,
      organizationName = organization.name,
      capacity = rentalVehicleInfo.capacity or {},
      sourceFacility = {type = "deliveryProvider", id = facility.id},
      loanType = hourlyRental and "rental" or "work",
      rentalCategory = rentalVehicleInfo.rentalCategory,
      spawnWhenCommitingCargo = loanerState.markedForSpawningLoaners[id] and true or false,
      requiredSkillLevel = requiredSkillLevel > 0 and requiredSkillLevel or nil,
      requiredPoliceLevel = rentalVehicleInfo.requiredPoliceLevel and (requiredSkillLevel > 0 and requiredSkillLevel or nil) or nil,
    }
    local labels = capacityLabels(configInfo)
    if labels then item.capacity = labels end
    if enabled and requiredReputationLvl ~= nil then
      item.unlockInfo = reputationUnlockInfo(organization, requiredReputationLvl)
    end
    return item
  end

  local function formatLoanerOfferForUi(facility)
    local employment = overhaul_career_work_employment
    if overhaul_career_logistics_broker and not (employment and employment.isEmployed()) then return {} end
    facility = offers.getDeliveryFacility(facility.id) or facility
    local organization = overhaul_world_organizations.getOrganization(facility.associatedOrganization)
    if not organization then return nil end
    if offers.usesSkillUnlocks(organization) then return {} end

    local secondsSinceSaveFileCreation = saveFileAgeSeconds()
    local rows = {}
    for displayIndex, rentalVehicleInfo in ipairs(loanableVehiclesOf(facility, organization)) do
      table.insert(rows, offerRow(facility, organization, displayIndex, rentalVehicleInfo, secondsSinceSaveFileCreation))
    end
    return rows
  end

  return {
    appliesRevenueShare = appliesRevenueShare,
    getLoaningOrgsOfVehicle = getLoaningOrgsOfVehicle,
    formatLoanerOfferForUi = formatLoanerOfferForUi,
    formatSpawnedLoanersForUi = formatSpawnedLoanersForUi,
  }
end

return ui
