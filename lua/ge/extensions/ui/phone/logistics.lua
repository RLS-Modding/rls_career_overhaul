local M = {}

M.dependencies = {
  'career_modules_delivery_generator',
  'career_modules_delivery_parcelManager',
  'career_modules_delivery_parcelMods',
  'career_modules_delivery_vehicleOfferManager',
  'career_modules_delivery_progress',
  'career_modules_delivery_tutorial',
  'career_modules_playerAttributes',
  'freeroam_organizations'
}

local dGenerator, dParcelManager, dParcelMods, dVehOfferManager, dProgress, dTutorial

local function onCareerActivated()
  dGenerator = career_modules_delivery_generator
  dParcelManager = career_modules_delivery_parcelManager
  dParcelMods = career_modules_delivery_parcelMods
  dVehOfferManager = career_modules_delivery_vehicleOfferManager
  dProgress = career_modules_delivery_progress
  dTutorial = career_modules_delivery_tutorial
end
M.onCareerActivated = onCareerActivated

local function ensureModules()
  if dGenerator and dParcelManager and dParcelMods and dVehOfferManager and dProgress and dTutorial then
    return
  end
  onCareerActivated()
end

local function getCurrentLevel()
  if getCurrentLevelIdentifier and getCurrentLevelIdentifier() then
    return getCurrentLevelIdentifier()
  end
  if core_levels and getMissionFilename and getMissionFilename() ~= '' then
    return core_levels.getLevelName(getMissionFilename())
  end
  return nil
end

local function isCareerActive()
  local state = core_gamestate and core_gamestate.state and core_gamestate.state.state
  if state == 'freeroam' then return false end
  if state == 'career' then return true end
  return career_career and career_career.isActive()
end

local function sendError(code, extras)
  local payload = extras or {}
  payload.code = code
  guihooks.trigger('phoneLogisticsError', payload)
end

local function getPlayerPos()
  local veh = getPlayerVehicle(0)
  if veh then
    return veh:getPosition()
  end
  return nil
end

local function getDistanceToPos(pos, playerPos)
  if not pos or not playerPos then return -1 end
  return math.floor((pos - playerPos):length())
end

local function sortPsEntries(a, b)
  return tostring(a.path) < tostring(b.path)
end

local function collectPsEntries(list, source)
  if not source then return end
  for key, value in pairs(source) do
    local ps = value.ps or value
    if ps and ps.getPath then
      table.insert(list, {
        ps = ps,
        path = ps:getPath(),
        name = value.name or key,
        isInspectSpot = value.isInspectSpot == true
      })
    end
  end
end

local function getPrimaryParkingSpotForFacility(fac)
  if not fac then return nil, nil end

  local inspectEntries = {}
  local regularEntries = {}
  collectPsEntries(regularEntries, fac.accessPointsByName or {})
  for _, entry in ipairs(regularEntries) do
    if entry.isInspectSpot then
      table.insert(inspectEntries, entry)
    end
  end

  if #inspectEntries > 0 then
    table.sort(inspectEntries, sortPsEntries)
    return inspectEntries[1].path, inspectEntries[1].ps
  end

  if #regularEntries > 0 then
    table.sort(regularEntries, sortPsEntries)
    return regularEntries[1].path, regularEntries[1].ps
  end

  local pickupEntries = {}
  collectPsEntries(pickupEntries, fac.pickUpSpots or {})
  if #pickupEntries > 0 then
    table.sort(pickupEntries, sortPsEntries)
    return pickupEntries[1].path, pickupEntries[1].ps
  end

  local dropoffEntries = {}
  collectPsEntries(dropoffEntries, fac.dropOffSpots or {})
  if #dropoffEntries > 0 then
    table.sort(dropoffEntries, sortPsEntries)
    return dropoffEntries[1].path, dropoffEntries[1].ps
  end

  return nil, nil
end

local function getOrganizationName(fac)
  if not fac or not fac.associatedOrganization then return nil end
  local org = freeroam_organizations.getUIDataForOrg(fac.associatedOrganization)
  return (org and org.name) or fac.associatedOrganization
end

local function buildAvailableSystems(fac)
  local available = {}
  for key, value in pairs(fac.providedSystemsLookup or {}) do
    available[key] = value and true or false
  end

  local received = fac.receivedSystemsLookup or {}
  available.largeFluidDelivery = available.largeFluidDelivery or received.largeFluidDelivery or false
  available.largeDryBulkDelivery = available.largeDryBulkDelivery or received.largeDryBulkDelivery or false
  available.largeCementDelivery = available.largeCementDelivery or received.largeCementDelivery or false
  available.largeCashDelivery = available.largeCashDelivery or received.largeCashDelivery or false
  available.smallFluidDelivery = nil
  return available
end

local function hasTimedModifier(cargo)
  for _, mod in ipairs(cargo.modifiers or {}) do
    if mod.type == 'timed' then
      return true
    end
  end
  return false
end

local function getSortedKeys(tbl)
  local keys = {}
  for key in pairs(tbl or {}) do
    table.insert(keys, key)
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

local function buildLocationLabelShort(loc)
  return dParcelManager.getLocationLabelShort(loc)
end

local function buildLocationKey(loc)
  if not loc then
    return 'unknown'
  end
  if loc.type == 'multi' then
    local names = {}
    for _, dest in ipairs(loc.destinations or {}) do
      table.insert(names, buildLocationLabelShort(dest))
    end
    return 'multi:' .. table.concat(names, '|')
  end
  if loc.facId then
    return tostring(loc.facId)
  end
  return tostring(buildLocationLabelShort(loc))
end

local function buildDestinationSummary(loc, distance)
  local label = loc and buildLocationLabelShort(loc) or 'Unknown'
  local summary = {
    destinationKey = buildLocationKey(loc),
    destinationName = label,
    destinationFacilityId = loc and loc.type ~= 'multi' and loc.facId or nil,
    distance = distance or -1,
  }

  if loc and loc.type == 'multi' then
    local names = {}
    for _, dest in ipairs(loc.destinations or {}) do
      table.insert(names, buildLocationLabelShort(dest))
    end
    if #names > 0 then
      summary.destinationName = table.concat(names, ', ')
    end
    summary.destinationFacilityId = nil
  end

  return summary
end

local function buildModifierSignature(cargo)
  local modifierTypes = {}
  for _, mod in ipairs(cargo.modifiers or {}) do
    if mod.type ~= 'timed' then
      table.insert(modifierTypes, tostring(mod.type))
    end
  end
  table.sort(modifierTypes)
  return table.concat(modifierTypes, '+')
end

local function buildModifierKeys(cargo)
  local modifierKeys = {}
  for _, mod in ipairs(cargo and cargo.modifiers or {}) do
    modifierKeys[mod.type] = true
  end
  return modifierKeys
end

local function getLogisticsProgressionSnapshot()
  local attributeKey = 'logistics-delivery'
  if not career_modules_playerAttributes or not career_branches or not career_branches.calcBranchLevelFromValue then
    return nil
  end

  local value = career_modules_playerAttributes.getAttributeValue(attributeKey)
  if type(value) ~= 'number' then
    return nil
  end

  local level, _, _, prevThreshold, nextThreshold = career_branches.calcBranchLevelFromValue(value, attributeKey)
  if type(level) ~= 'number' then
    return nil
  end

  return {
    attributeKey = attributeKey,
    level = level,
    value = value,
    prevThreshold = type(prevThreshold) == 'number' and prevThreshold or nil,
    nextThreshold = type(nextThreshold) == 'number' and nextThreshold or nil,
  }
end

local function buildUnlockMetadata(unlocked, flagDefinition, unlockFlag)
  return {
    unlockFlag = unlockFlag,
    unlockLevel = flagDefinition and flagDefinition.level or nil,
    unlockInfo = flagDefinition and flagDefinition.unlockInfo or nil,
    isUnlockedByLevel = unlocked ~= false,
    lockedReason = flagDefinition and flagDefinition.lockedReason or nil,
  }
end

local function getParcelUnlockMetadata(modifierKeys)
  local lockedBecauseOfMods, flagDefinition = dParcelMods.lockedBecauseOfMods(modifierKeys)
  local selectedFlag, selectedLevel = nil, -math.huge

  for modKey in pairs(modifierKeys or {}) do
    local modData = dParcelMods.getModData(modKey)
    local unlockFlag = modData and modData.unlockFlag or nil
    if unlockFlag and career_modules_unlockFlags and career_modules_unlockFlags.getFlagDefinition then
      local definition = career_modules_unlockFlags.getFlagDefinition(unlockFlag)
      local level = definition and definition.level or -math.huge
      if level > selectedLevel then
        selectedFlag = unlockFlag
        selectedLevel = level
      end
    elseif unlockFlag and not selectedFlag then
      selectedFlag = unlockFlag
    end
  end

  return buildUnlockMetadata(not lockedBecauseOfMods, flagDefinition, selectedFlag)
end

local function getOfferUnlockMetadata(offer)
  local unlockTag = offer and offer.vehicle and offer.vehicle.unlockTag or nil
  local enabled, flagDefinition = true, nil
  if unlockTag then
    enabled, flagDefinition = dVehOfferManager.isVehicleTagUnlocked(unlockTag)
  end
  return buildUnlockMetadata(enabled, flagDefinition, unlockTag)
end

local function buildFacilityLocation(facId, psPath)
  if not facId or not psPath then return nil end
  return {
    type = 'facilityParkingspot',
    facId = facId,
    psPath = psPath,
  }
end

local function getMaterialTemplate(materialType)
  if not materialType then return nil end
  return dGenerator.getMaterialsTemplatesById(materialType)
end

local function getMaterialProviderLocation(fac, materialType)
  local accessPoint = dGenerator.selectAccessPointByLookupKeyByType(
    fac.accessPointsByName,
    materialType,
    'logisticTypesProvidedLookup'
  )
  if accessPoint and accessPoint.psPath then
    return buildFacilityLocation(fac.id, accessPoint.psPath)
  end

  local primaryPsPath = select(1, getPrimaryParkingSpotForFacility(fac))
  return buildFacilityLocation(fac.id, primaryPsPath)
end

local function getMaterialReceiverLocation(fac, materialType)
  local accessPoint = dGenerator.selectAccessPointByLookupKeyByType(
    fac.accessPointsByName,
    materialType,
    'logisticTypesReceivedLookup'
  )
  if accessPoint and accessPoint.psPath then
    return buildFacilityLocation(fac.id, accessPoint.psPath)
  end

  local primaryPsPath = select(1, getPrimaryParkingSpotForFacility(fac))
  return buildFacilityLocation(fac.id, primaryPsPath)
end

local function finalizeParcelForPhone(cargo)
  if cargo and cargo.type == 'parcel' and dGenerator.finalizeParcelItemDistanceAndRewards then
    dGenerator.finalizeParcelItemDistanceAndRewards(cargo)
  end
end

local function finalizeOfferPreview(offer)
  if dGenerator and dGenerator.finalizeVehicleOffer then
    dGenerator.finalizeVehicleOffer(offer)
  end
end

local function getVehicleThumb(offer)
  if not offer or not offer.vehicle then return '/ui/images/appDefault.png' end
  local vehicle = offer.vehicle
  local model = core_vehicles.getModel(vehicle.model)
  if not model or not model.configs or not vehicle.config then
    return '/ui/images/appDefault.png'
  end
  local config = model.configs[vehicle.config]
  return (config and config.preview) or '/ui/images/appDefault.png'
end

local function buildOfferPayload(offer)
  finalizeOfferPreview(offer)
  local unlockMetadata = getOfferUnlockMetadata(offer)

  return {
    offerId = offer.id,
    name = offer.vehicle and offer.vehicle.name or (offer.data and offer.data.type) or 'Offer',
    originName = buildLocationLabelShort(offer.origin),
    destinationName = offer.task and offer.task.destination and buildLocationLabelShort(offer.task.destination) or 'Unknown',
    reward = offer.rewards and offer.rewards.money or 0,
    distance = offer.data and offer.data.originalDistance or 0,
    requiredSkill = offer.data and offer.data.type == 'vehicle' and 'vehicleDelivery' or 'delivery',
    offerType = offer.data and offer.data.type or 'trailer',
    unlockTag = unlockMetadata.unlockFlag,
    vehicleName = offer.vehicle and offer.vehicle.name or nil,
    vehicleBrand = offer.vehicle and offer.vehicle.brand or nil,
    vehicleMileage = offer.vehicle and offer.vehicle.mileage or nil,
    thumbnail = getVehicleThumb(offer),
    unlockLevel = unlockMetadata.unlockLevel,
    unlockInfo = unlockMetadata.unlockInfo,
    isUnlockedByLevel = unlockMetadata.isUnlockedByLevel,
    lockedReason = unlockMetadata.lockedReason,
  }
end

local function countParcelRowsForFacility(facilityId, availableOnly)
  local outgoingCargo = dParcelManager.getAllCargoForFacilityUnexpiredUndelivered(facilityId) or {}
  local rowsByKey = {}

  for _, cargo in ipairs(outgoingCargo) do
    if cargo.type == 'parcel' then
      finalizeParcelForPhone(cargo)
      local unlockMetadata = getParcelUnlockMetadata(buildModifierKeys(cargo))
      if not availableOnly or unlockMetadata.isUnlockedByLevel then
        local timed = hasTimedModifier(cargo)
        local modifierSignature = buildModifierSignature(cargo)
        local rowKey = table.concat({
          buildLocationKey(cargo.destination),
          tostring(cargo.name or 'Parcel'),
          tostring(cargo.slots or 0),
          timed and 'timed' or 'plain',
          modifierSignature,
        }, '|')
        rowsByKey[rowKey] = true
      end
    end
  end

  local count = 0
  for _ in pairs(rowsByKey) do
    count = count + 1
  end
  return count
end

local function countMaterialSourcesForFacility(fac)
  local count = 0

  for _, materialType in ipairs(getSortedKeys(fac.materialStorages or {})) do
    local storage = fac.materialStorages[materialType]
    local material = getMaterialTemplate(materialType)
    if storage and storage.isProvider and material and (storage.storedVolume or 0) > 0 then
      count = count + 1
    end
  end

  return count
end

local function countOffersForFacility(facilityId, offerType, availableOnly)
  local count = 0

  for _, offer in ipairs(dVehOfferManager.getAllOfferAtFacilityUnexpired(facilityId) or {}) do
    local currentType = offer.data and offer.data.type or 'trailer'
    local unlockMetadata = getOfferUnlockMetadata(offer)
    if currentType == offerType and offer.task and offer.task.destination and (not availableOnly or unlockMetadata.isUnlockedByLevel) then
      count = count + 1
    end
  end

  return count
end

local function buildParcelDestinationSections(facilityId)
  local outgoingCargo = dParcelManager.getAllCargoForFacilityUnexpiredUndelivered(facilityId) or {}
  local sectionsByKey = {}
  local orderedSections = {}

  for _, cargo in ipairs(outgoingCargo) do
    if cargo.type == 'parcel' then
      finalizeParcelForPhone(cargo)
      local distance = cargo.data and cargo.data.originalDistance or -1
      local destination = buildDestinationSummary(cargo.destination, distance)
      local section = sectionsByKey[destination.destinationKey]
      if not section then
        section = {
          destinationKey = destination.destinationKey,
          destinationName = destination.destinationName,
          destinationFacilityId = destination.destinationFacilityId,
          distance = destination.distance,
          rows = {},
          _rowsByKey = {},
        }
        sectionsByKey[destination.destinationKey] = section
        table.insert(orderedSections, section)
      elseif (section.distance or -1) < 0 and (distance or -1) >= 0 then
        section.distance = distance
      end

      local timed = hasTimedModifier(cargo)
      local modifierSignature = buildModifierSignature(cargo)
      local rowKey = table.concat({
        tostring(cargo.name or 'Parcel'),
        tostring(cargo.slots or 0),
        timed and 'timed' or 'plain',
        modifierSignature,
      }, '|')

      local row = section._rowsByKey[rowKey]
      if not row then
        local modifierKeys = buildModifierKeys(cargo)
        local unlockMetadata = getParcelUnlockMetadata(modifierKeys)
        row = {
          rowId = table.concat({
            destination.destinationKey,
            tostring(cargo.name or 'Parcel'),
            tostring(cargo.slots or 0),
            timed and 'timed' or 'plain',
            modifierSignature,
          }, '|'),
          representativeCargoId = cargo.id,
          parcelName = cargo.name or 'Parcel',
          quantity = 0,
          slotSize = cargo.slots or 0,
          rewardPerItem = cargo.rewards and cargo.rewards.money or 0,
          rewardTotal = 0,
          weightPerItem = cargo.weight or 0,
          weightTotal = 0,
          timed = timed,
          unlockFlag = unlockMetadata.unlockFlag,
          unlockLevel = unlockMetadata.unlockLevel,
          unlockInfo = unlockMetadata.unlockInfo,
          isUnlockedByLevel = unlockMetadata.isUnlockedByLevel,
          lockedReason = unlockMetadata.lockedReason,
        }
        section._rowsByKey[rowKey] = row
        table.insert(section.rows, row)
      end

      row.quantity = row.quantity + 1
      row.rewardTotal = row.rewardTotal + (cargo.rewards and cargo.rewards.money or 0)
      row.weightTotal = row.weightTotal + (cargo.weight or 0)
    end
  end

  for _, section in ipairs(orderedSections) do
    section.rowCount = #section.rows
    section._rowsByKey = nil
    table.sort(section.rows, function(a, b)
      if (a.slotSize or 0) ~= (b.slotSize or 0) then
        return (a.slotSize or 0) < (b.slotSize or 0)
      end
      if tostring(a.parcelName) ~= tostring(b.parcelName) then
        return tostring(a.parcelName) < tostring(b.parcelName)
      end
      return (a.rewardTotal or 0) > (b.rewardTotal or 0)
    end)
  end

  table.sort(orderedSections, function(a, b)
    local distA = a.distance and a.distance >= 0 and a.distance or math.huge
    local distB = b.distance and b.distance >= 0 and b.distance or math.huge
    if distA ~= distB then return distA < distB end
    return tostring(a.destinationName) < tostring(b.destinationName)
  end)

  return orderedSections
end

local function buildMaterialDestinationSummaries(originFacility, materialType)
  local originLocation = getMaterialProviderLocation(originFacility, materialType)
  local destinations = {}

  for _, fac in ipairs(dGenerator.getFacilities() or {}) do
    local storage = fac.materialStorages and fac.materialStorages[materialType]
    local receivesType = fac.logisticTypesReceivedLookup and fac.logisticTypesReceivedLookup[materialType]
    if receivesType and storage and storage.id then
      local destinationLocation = getMaterialReceiverLocation(fac, materialType)
      local distance = -1
      if originLocation and destinationLocation and dGenerator.getDistanceBetweenFacilities then
        distance = dGenerator.getDistanceBetweenFacilities(originLocation, destinationLocation) or -1
      end
      local summary = buildDestinationSummary(destinationLocation, distance)
      summary.destinationKey = destinationLocation and summary.destinationKey or tostring(fac.id)
      summary.destinationName = destinationLocation and buildLocationLabelShort(destinationLocation) or fac.name
      summary.destinationFacilityId = fac.id
      summary.destinationParkingSpotPath = destinationLocation and destinationLocation.psPath or nil
      table.insert(destinations, summary)
    end
  end

  table.sort(destinations, function(a, b)
    local distA = a.distance and a.distance >= 0 and a.distance or math.huge
    local distB = b.distance and b.distance >= 0 and b.distance or math.huge
    if distA ~= distB then return distA < distB end
    return tostring(a.destinationName) < tostring(b.destinationName)
  end)

  local destinationCount = #destinations
  local trimmed = {}
  local maxDestinations = math.min(destinationCount, 10)
  for idx = 1, maxDestinations do
    table.insert(trimmed, destinations[idx])
  end

  return destinationCount, trimmed
end

local function buildMaterialSourceSections(fac)
  local sources = {}

  for _, materialType in ipairs(getSortedKeys(fac.materialStorages or {})) do
    local storage = fac.materialStorages[materialType]
    local material = getMaterialTemplate(materialType)
    if storage and storage.isProvider and material and (storage.storedVolume or 0) > 0 then
      local destinationCount, destinations = buildMaterialDestinationSummaries(fac, materialType)
      table.insert(sources, {
        storageId = storage.id,
        materialType = materialType,
        materialName = material.name or materialType,
        amountAvailable = storage.storedVolume or 0,
        units = material.units or 'L',
        rewardPerUnit = material.money or 0,
        density = material.density,
        destinationCount = destinationCount,
        destinations = destinations,
      })
    end
  end

  table.sort(sources, function(a, b)
    if (a.amountAvailable or 0) ~= (b.amountAvailable or 0) then
      return (a.amountAvailable or 0) > (b.amountAvailable or 0)
    end
    return tostring(a.materialName) < tostring(b.materialName)
  end)

  return sources
end

local function buildOfferDestinationSections(facilityId, offerType)
  local rawOffers = dVehOfferManager.getAllOfferAtFacilityUnexpired(facilityId) or {}
  local sectionsByKey = {}
  local orderedSections = {}

  for _, offer in ipairs(rawOffers) do
    local payload = buildOfferPayload(offer)
    if payload.offerType == offerType and offer.task and offer.task.destination then
      local destination = buildDestinationSummary(offer.task.destination, payload.distance)
      local section = sectionsByKey[destination.destinationKey]
      if not section then
        section = {
          destinationKey = destination.destinationKey,
          destinationName = destination.destinationName,
          destinationFacilityId = destination.destinationFacilityId,
          distance = destination.distance,
          rows = {},
        }
        sectionsByKey[destination.destinationKey] = section
        table.insert(orderedSections, section)
      elseif (section.distance or -1) < 0 and (payload.distance or -1) >= 0 then
        section.distance = payload.distance
      end

      table.insert(section.rows, payload)
    end
  end

  for _, section in ipairs(orderedSections) do
    table.sort(section.rows, function(a, b)
      if (a.reward or 0) ~= (b.reward or 0) then
        return (a.reward or 0) > (b.reward or 0)
      end
      return tostring(a.name) < tostring(b.name)
    end)
    section.rowCount = #section.rows
  end

  table.sort(orderedSections, function(a, b)
    local distA = a.distance and a.distance >= 0 and a.distance or math.huge
    local distB = b.distance and b.distance >= 0 and b.distance or math.huge
    if distA ~= distB then return distA < distB end
    return tostring(a.destinationName) < tostring(b.destinationName)
  end)

  return orderedSections
end

local function buildFacilityBadges(parcelCount, materialCount, vehicleCount, trailerCount)
  local badges = {}
  if parcelCount > 0 then table.insert(badges, 'parcel') end
  if materialCount > 0 then table.insert(badges, 'material') end
  if vehicleCount > 0 then table.insert(badges, 'vehicle') end
  if trailerCount > 0 then table.insert(badges, 'trailer') end
  return badges
end

local function buildFacilitySummary(fac, playerPos)
  local primaryParkingSpotPath, primaryPs = getPrimaryParkingSpotForFacility(fac)
  local position = primaryPs and primaryPs.pos or nil
  if not position and primaryParkingSpotPath then
    position = dGenerator.getLocationCoordinates({
      type = 'facilityParkingspot',
      facId = fac.id,
      psPath = primaryParkingSpotPath
    })
  end

  local parcelCount = countParcelRowsForFacility(fac.id)
  local materialCount = countMaterialSourcesForFacility(fac)
  local vehicleCount = countOffersForFacility(fac.id, 'vehicle')
  local trailerCount = countOffersForFacility(fac.id, 'trailer')
  local availableParcelCount = countParcelRowsForFacility(fac.id, true)
  local availableVehicleCount = countOffersForFacility(fac.id, 'vehicle', true)
  local availableTrailerCount = countOffersForFacility(fac.id, 'trailer', true)

  return {
    id = fac.id,
    name = fac.name,
    organizationId = fac.associatedOrganization,
    organizationName = getOrganizationName(fac),
    preview = fac.preview,
    primaryParkingSpotPath = primaryParkingSpotPath,
    position = position and { x = position.x, y = position.y, z = position.z } or nil,
    distance = getDistanceToPos(position, playerPos),
    availableSystems = buildAvailableSystems(fac),
    counts = {
      parcelGroups = parcelCount,
      materialGroups = materialCount,
      vehicleOffers = vehicleCount,
      trailerOffers = trailerCount,
      availableParcelGroups = availableParcelCount,
      availableVehicleOffers = availableVehicleCount,
      availableTrailerOffers = availableTrailerCount,
    },
    totalVisibleJobs = parcelCount + materialCount + vehicleCount + trailerCount,
    totalAvailableByLevelJobs = availableParcelCount + availableVehicleCount + availableTrailerCount,
    badges = buildFacilityBadges(parcelCount, materialCount, vehicleCount, trailerCount)
  }
end

local function requestFacilityList()
  ensureModules()
  if not isCareerActive() then
    guihooks.trigger('phoneLogisticsFacilityList', {
      careerActive = false,
      levelId = getCurrentLevel() or '',
      generatedAt = os.time(),
      facilities = {}
    })
    return
  end

  dGenerator.triggerAllGenerators()

  local tutorialActive = dTutorial.isCargoDeliveryTutorialActive and dTutorial.isCargoDeliveryTutorialActive() or false
  local playerPos = getPlayerPos()
  local facilities = {}

  for _, fac in ipairs(dGenerator.getFacilities() or {}) do
    if dProgress.isFacilityVisible(fac.id, tutorialActive) then
      local summary = buildFacilitySummary(fac, playerPos)
      if (summary.totalVisibleJobs or 0) > 0 then
        table.insert(facilities, summary)
      end
    end
  end

  table.sort(facilities, function(a, b)
    local distA = a.distance and a.distance >= 0 and a.distance or math.huge
    local distB = b.distance and b.distance >= 0 and b.distance or math.huge
    if distA ~= distB then return distA < distB end
    return tostring(a.name) < tostring(b.name)
  end)

  guihooks.trigger('phoneLogisticsFacilityList', {
    careerActive = true,
    levelId = getCurrentLevel() or '',
    generatedAt = os.time(),
    facilities = facilities
  })
end
M.requestFacilityList = requestFacilityList

local function requestFacilityDetail(facilityId)
  ensureModules()
  if not isCareerActive() then
    sendError('career_inactive', { facilityId = facilityId })
    return
  end

  dGenerator.triggerAllGenerators()

  local fac = dGenerator.getFacilityById(facilityId)
  if not fac then
    sendError('facility_not_found', { facilityId = facilityId })
    return
  end

  local playerPos = getPlayerPos()
  local primaryParkingSpotPath, primaryPs = getPrimaryParkingSpotForFacility(fac)
  local position = primaryPs and primaryPs.pos or nil
  if not position and primaryParkingSpotPath then
    position = dGenerator.getLocationCoordinates({
      type = 'facilityParkingspot',
      facId = fac.id,
      psPath = primaryParkingSpotPath
    })
  end

  guihooks.trigger('phoneLogisticsFacilityDetail', {
    facilityId = facilityId,
    generatedAt = os.time(),
    progression = {
      logistics = getLogisticsProgressionSnapshot()
    },
    facility = {
      id = fac.id,
      name = fac.name,
      organizationId = fac.associatedOrganization,
      organizationName = getOrganizationName(fac),
      preview = fac.preview,
      longDescription = fac.facilityInformation,
      primaryParkingSpotPath = primaryParkingSpotPath,
      availableSystems = buildAvailableSystems(fac),
      distance = getDistanceToPos(position, playerPos)
    },
    parcelDestinations = buildParcelDestinationSections(fac.id),
    materialSources = buildMaterialSourceSections(fac),
    vehicleOfferDestinations = buildOfferDestinationSections(fac.id, 'vehicle'),
    trailerOfferDestinations = buildOfferDestinationSections(fac.id, 'trailer')
  })
end
M.requestFacilityDetail = requestFacilityDetail

local function navigateToFacility(facilityId, parkingSpotPath)
  ensureModules()
  local fac = dGenerator.getFacilityById(facilityId)
  if not fac then
    sendError('facility_not_found', { facilityId = facilityId })
    return
  end

  local targetParkingSpotPath = parkingSpotPath
  if not targetParkingSpotPath or targetParkingSpotPath == '' then
    targetParkingSpotPath = select(1, getPrimaryParkingSpotForFacility(fac))
  end

  if not targetParkingSpotPath then
    sendError('facility_missing_route_target', { facilityId = facilityId })
    return
  end

  local toPos = dGenerator.getLocationCoordinates({
    type = 'facilityParkingspot',
    facId = fac.id,
    psPath = targetParkingSpotPath
  })
  if toPos then
    core_groundMarkers.setPath(toPos, { clearPathOnReachingTarget = true })
  end
end
M.navigateToFacility = navigateToFacility

return M
