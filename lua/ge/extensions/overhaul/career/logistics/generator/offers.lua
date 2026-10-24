-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Logistics generator: parcel and vehicle offer generation.
-- Map, in reading order:
--   parcel finalizing   weights, distances and rewards; loaded parcels are upgraded when they are stale
--   availability        whether a stored location still exists on this map
--   parcel generation   templates, item building with duplicates, route pickers, the parcel trigger
--   vehicle generation  vehicle templates and filters, finalizing a vehicle offer, the vehicle trigger
--   API                 the names the facade and the other parts reach through the returned table
-- Built by career/logistics/generator.lua, which owns the facilities, the generation tick and the public functions.
local part = {}

-- Vehicle config selection ------------------------------------------------------------------------

-- Weighted pick: an item without the key weighs 1; when nothing weighs anything, the pick is uniform.
local function choose(list, weightKey)
  local total = 0
  for _, item in ipairs(list) do total = total + (item[weightKey] or 1) end
  if total <= 0 then return list[math.random(#list)] end
  local draw, sum = math.random(total), 0
  for _, item in ipairs(list) do
    sum = sum + (item[weightKey] or 1)
    if sum >= draw then return item end
  end
end

-- One filter per seller sub-filter (merged over the base filter), or the base filter alone.
local function sellerFilters(seller)
  local filters = {}
  if seller.subFilters and not tableIsEmpty(seller.subFilters) then
    for _, sub in ipairs(seller.subFilters) do
      local filter = deepcopy(seller.filter)
      tableMergeRecursive(filter, sub)
      filters[#filters + 1] = filter
    end
  else
    filters[1] = seller.filter
  end
  return filters
end

-- Picks a model by population, then one of its configs; falls back to a uniform pick among the matches.
local function pickMatched(matched, models, eligible, filter)
  local modelList = {}
  for model in pairs(models) do modelList[#modelList + 1] = {model_key = model, pop = 1} end
  table.sort(modelList, function(a, b) return a.model_key < b.model_key end)
  local model = choose(modelList, 'pop').model_key
  local configs = {}
  for _, item in ipairs(matched) do
    if item.info.model_key == model then configs[#configs + 1] = item.info end
  end
  local chosen = choose(configs, 'Population')
  local index = nil
  if chosen then
    for _, item in ipairs(matched) do
      if item.info == chosen then
        index = item.index
        break
      end
    end
  else
    -- The vanilla fallback's index into the original catalog.
    index = math.random(#matched)
  end
  local result = deepcopy(eligible[index])
  result.index, result.filter = index, filter
  return result
end

-- A deep copy of one eligible vehicle, with its catalog index and filter; nil when no filter matches.
local function getRandomVehicleInfo(seller, eligible)
  local filters = sellerFilters(seller)
  while not tableIsEmpty(eligible) do
    for i, filter in ipairs(filters) do filter.index = i end
    local filter = choose(filters, 'probability')
    local matched, models = {}, {}
    for i, info in ipairs(eligible) do
      if util_configListGenerator.doesVehiclePassFilter(info, filter) then
        matched[#matched + 1] = {info = info, index = i}
        models[info.model_key] = true
      end
    end
    if not matched[1] then
      table.remove(filters, filter.index)
      if tableIsEmpty(filters) then return end
    else
      return pickMatched(matched, models, eligible, filter)
    end
  end
end


-- Offer generation ---------------------------------------------------------------------------------

-- Instance-local closures keep reloaded careers isolated.
function part.new(inputs)
  local ext, gen = inputs.services.ext, inputs.state.gen
  local callbacks = inputs.callbacks
  local minDeliveryDistance = inputs.rules.minDeliveryDistance
  local sharedCalc = inputs.services.sharedCalc

  -- Parcel Finalizing, Templates and Generation ---------------------------------------------

  local getMoneyRewardForParcelItem = sharedCalc.getMoneyRewardForParcelItem

  local function getParcelTemplateById(templateId)
    return inputs.services.sharedTemplates.getTemplateById(templateId)
  end

  local function prepareParcelWeights(item, template)
    item.data = item.data or {}
    if item.data.rewardWeight == nil then
      item.data.rewardWeight = math.max(0, tonumber(item.weight) or 0)
    end
    item.weight = sharedCalc.getPhysicalWeightForParcel(
      template,
      item.slots,
      item.data.rewardWeight,
      item.groupSeed or item.id)
  end

  local function finalizeParcelItemDistanceAndRewards(item)
    item.data = item.data or {}
    local retryEstimatedDistance = item.rewards and item.data.distanceEstimated
    if item.rewards and not retryEstimatedDistance then return end

    local distance, routeReliable = callbacks.getDistanceBetweenFacilities(item.origin, item.destination)
    if retryEstimatedDistance and not routeReliable then return end

    item.data.originalDistance = distance
    if routeReliable then
      item.data.distanceEstimated = nil
    else
      item.data.distanceEstimated = true
    end
    local template = deepcopy(getParcelTemplateById(item.templateId))

    prepareParcelWeights(item, template)
    item.modifiers = ext.parcelMods.generateModifiers(item, template, distance)
    item.rewards = sharedCalc.getParcelReward(item, distance, item.organization)
  end
  local function shouldUpgradeLoadedParcel(cargo)
    local formulaVersion = tonumber(cargo.data and cargo.data.rewardFormulaVersion) or 1
    local originalDistance = tonumber(cargo.data and cargo.data.originalDistance)
    local invalidDistance = cargo.rewards and (not originalDistance or originalDistance <= 1)
    return require('overhaul/lib/logistics/cargoSemantics').cargo(cargo.type).parcel
      and cargo.location
      and cargo.location.type == "facilityParkingspot"
      and (formulaVersion < 4 or invalidDistance or (cargo.data and cargo.data.distanceEstimated))
  end

  local function upgradeLoadedParcelIfNeeded(cargo)
    if not shouldUpgradeLoadedParcel(cargo) then return false end

    local template = deepcopy(getParcelTemplateById(cargo.templateId))
    prepareParcelWeights(cargo, template)
    cargo.rewards = nil
    cargo.modifiers = nil
    finalizeParcelItemDistanceAndRewards(cargo)
    return true
  end

  local function isLocationAvailableOnCurrentMap(location)
    if type(location) ~= "table" then return false end
    if location.type == "facilityParkingspot" then
      return gen.facilitiesById[location.facId] ~= nil and gen.parkingSpotsByPath[location.psPath] ~= nil
    elseif location.type == "vehicle" then
      return location.vehId ~= nil and scenetree.findObjectById(location.vehId) ~= nil
    elseif location.type == "multi" then
      if type(location.destinations) ~= "table" or not next(location.destinations) then return false end
      for _, destination in ipairs(location.destinations) do
        if not isLocationAvailableOnCurrentMap(destination) then return false end
      end
      return true
    end
    return false
  end

  local function isLoadedParcelAvailableOnCurrentMap(cargo)
    return type(cargo) == "table"
      and isLocationAvailableOnCurrentMap(cargo.location)
      and isLocationAvailableOnCurrentMap(cargo.origin)
      and isLocationAvailableOnCurrentMap(cargo.destination)
  end

  local function isLoadedVehicleOfferAvailableOnCurrentMap(offer)
    if type(offer) ~= "table" or type(offer.locations) ~= "table" or not next(offer.locations) then
      return false
    end
    for _, location in ipairs(offer.locations) do
      if not isLocationAvailableOnCurrentMap(location) then return false end
    end

    local destination = offer.task and (offer.task.destination or offer.task.dropOff) or nil
    return isLocationAvailableOnCurrentMap(offer.origin or offer.locations[1])
      and isLocationAvailableOnCurrentMap(offer.spawnLocation or offer.origin or offer.locations[1])
      and isLocationAvailableOnCurrentMap(destination or offer.locations[#offer.locations])
  end

  local function getDeliveryParcelTemplates()
    return inputs.services.sharedTemplates.loadParcelTemplates()
  end

  local function getDeliveryItemTemplateFor(generator)
    local r = math.random() * generator.sumChance

    local sum = 0
    for _, item in ipairs(generator.validTemplates) do
      sum = sum + item.chance
      if sum >= r then
        return deepcopy(item.item)
      end
    end
  end

  local function getDuplicateAmount(template)
    if not template.duplicationChance then return 1 end

    local r = math.random() * template.duplicationChanceSum
    local sum = 0
    for amount, chance in ipairs(template.duplicationChance) do
      sum = sum + chance
      if sum >= r then
        return amount
      end
    end
  end

  local function generateItemWithDuplicates(template, origin, destination, timeOffset, generatorLabel, generator)
    callbacks.profilerPushEvent("Duplicate Item")
    local offerExpiresAt = callbacks.generationTime() + template.offerDuration * (0.9+math.random()*0.2) + timeOffset
    local originFacility = callbacks.getFacilityById(origin.facId)
    local itemName = callbacks.randomFromList(template.names)
    local slots = callbacks.randomFromList(template.slots)
    local authoredWeight = callbacks.randomFromList(template.weight) * (math.random()*0.2 + 0.9)
    local itemGroupSeed = round(math.random()*1000000)

    local item = {
      templateId = template.id,
      name = itemName,
      type = template.cargoType,
      slots = slots,
      offerExpiresAt = offerExpiresAt,
      data = {
        delivered = false,
        rewardWeight = authoredWeight,
        },
      materialType = template.materialType,
      location = deepcopy(origin),
      origin = deepcopy(origin),
      destination = deepcopy(destination),
      generatorLabel = generatorLabel,
      weight = sharedCalc.getPhysicalWeightForParcel(template, slots, authoredWeight, itemGroupSeed),
      density = template.density,
      generatedAtTimestamp = callbacks.generationTime() + timeOffset,
      groupSeed = itemGroupSeed,
      automaticDropOff = true,
      organization = callbacks.getOfferOrganization(originFacility, gen.facilitiesById[destination.facId], generator and generator.offerMode)
    }

    if template.materialType then
      local materialData = callbacks.getMaterialsTemplatesById(template.materialType)
      item.weight = item.slots * materialData.density
    end

    local duplicateAmount = getDuplicateAmount(template)
    gen.groupId = gen.groupId + 1
    for d = 1, duplicateAmount do
      local copy = deepcopy(item)
      gen.cargoId = gen.cargoId + 1
      copy.id = gen.cargoId
      copy.groupId = gen.groupId
      copy.offerMode = generator and generator.offerMode
      ext.parcelManager.addCargo(copy)
      if callbacks.yieldGeneration then callbacks.yieldGeneration() end
    end
    callbacks.profilerPopEvent("Duplicate Item")
    return duplicateAmount
  end

  -- A generation run gives up after this many rolls, whether or not they produced an item.
  local MAX_PARCEL_ROLLS = 10

  local function logMissingTemplate(generator)
    log("E","","No Template! " .. dumps(generator.logisticTypesLookup))
    for _, item in ipairs(getDeliveryParcelTemplates()) do
      dump(item.id, item.logisticType)
    end
  end

  local function isRouteTooShort(origin, destination, generator)
    return callbacks.getDistanceBetweenFacilities(origin, destination) < minDeliveryDistance
      and generator.allowShortDistance ~= true
  end

  -- One destination per access point, on every other facility, that receives this parcel type.
  local function collectMultiDestinations(fac, template)
    local destination = {type = "multi", destinations = {}}
    for _, f in ipairs(gen.facilities) do
      if f.id ~= fac.id and f.logisticTypesReceivedLookup[template.logisticType] then
        for _, ap in pairs(f.accessPointsByName) do
          if ap.logisticTypesReceivedLookup[template.logisticType] then
            table.insert(destination.destinations, {type = "facilityParkingspot", facId = f.id, psPath = ap.psPath})
          end
        end
      end
    end
    return destination
  end

  -- The provider at `fac` sends the parcel elsewhere. Returns origin, destination, or nothing when this roll is rejected (the reason is logged).
  local function pickProviderRoute(fac, generator, template)
    local originAp = callbacks.selectAccessPointByLookupKeyByType(fac.accessPointsByName, template.logisticType, "logisticTypesProvidedLookup")
    if not originAp then
      log("E","","Could not find AP in facility " .. fac.id .. " with providing type " .. template.logisticType)
      return
    end
    local origin = {type = "facilityParkingspot", facId = fac.id, psPath = originAp.psPath}
    if generator.multiDestination then
      return origin, collectMultiDestinations(fac, template)
    end

    local destinationFac = callbacks.selectFacilityByLookupKeyByType(template.logisticType, "logisticTypesReceivedLookup", fac.id)
    if not destinationFac then
      log("E","","Could not find facility with receiving type " .. template.logisticType)
      return
    end
    local destinationAp = callbacks.selectAccessPointByLookupKeyByType(destinationFac.accessPointsByName, template.logisticType, "logisticTypesReceivedLookup")
    if not destinationAp then
      log("E","","Could not find AP in facility " .. destinationFac.id .. " with receiving type " .. template.logisticType)
      return
    end
    local destination = {type = "facilityParkingspot", facId = destinationFac.id, psPath = destinationAp.psPath}
    if isRouteTooShort(origin, destination, generator) then return end
    return origin, destination
  end

  -- The receiver at `fac` gets the parcel from elsewhere. Same return as pickProviderRoute.
  local function pickReceiverRoute(fac, generator, template)
    local destinationAp = callbacks.selectAccessPointByLookupKeyByType(fac.accessPointsByName, template.logisticType, "logisticTypesReceivedLookup")
    if not destinationAp then
      log("E","","Could not find AP in facility " .. fac.id .. " with receiving type " .. template.logisticType)
      return
    end
    local destination = {type = "facilityParkingspot", facId = fac.id, psPath = destinationAp.psPath}

    local originFac = callbacks.selectFacilityByLookupKeyByType(template.logisticType, "logisticTypesProvidedLookup", fac.id)
    if not originFac then
      log("E","","Could not find facility with providing type " .. template.logisticType)
      return
    end
    local originAp = callbacks.selectAccessPointByLookupKeyByType(originFac.accessPointsByName, template.logisticType, "logisticTypesProvidedLookup")
    if not originAp then
      log("E","","Could not find AP in facility " .. originFac.id .. " with providing type " .. template.logisticType)
      return
    end
    local origin = {type = "facilityParkingspot", facId = originFac.id, psPath = originAp.psPath}
    if isRouteTooShort(origin, destination, generator) then return end
    return origin, destination
  end

  local routePickers = {parcelProvider = pickProviderRoute, parcelReceiver = pickReceiverRoute}

  -- One roll of the generator: adds the item (and its duplicates) unless the roll is skipped.
  local function rollParcelItem(fac, generator, timeOffset)
    local template = getDeliveryItemTemplateFor(generator)
    if not template then
      logMissingTemplate(generator)
      return
    end

    local pickRoute = routePickers[generator.type]
    local origin = nil
    local destination = nil
    callbacks.profilerPushEvent("Origin and Destination")
    if pickRoute then
      origin, destination = pickRoute(fac, generator, template)
    end
    callbacks.profilerPopEvent("Origin and Destination")
    if pickRoute and not origin then return end
    generateItemWithDuplicates(template, origin, destination, timeOffset, generator.name, generator)
  end

  local function triggerParcelGenerator(fac, generator, timeOffset)
    -- Tutorial-only generator records never produce offers; no career tutorial needs them any more.
    if generator.isTutorialGenerator then
      return
    end

    if generator.validTemplates and not generator.validTemplates[1] then
      if not generator._noTemplateWarned then
        generator._noTemplateWarned = true
        log("W", "", string.format("Parcel generator %s at %s has no parcel template on this level; skipped",
          tostring(generator.name), tostring(fac.id)))
      end
      return
    end

    local rollCount = math.random(generator.min, generator.max)
    if rollCount <= 0 then return end

    local remainingRolls = MAX_PARCEL_ROLLS
    for _ = 1, rollCount do
      rollParcelItem(fac, generator, timeOffset)
      if callbacks.yieldGeneration then callbacks.yieldGeneration() end
      remainingRolls = remainingRolls - 1
      if remainingRolls <= 0 then
        log("D","","Could not generate items after " .. MAX_PARCEL_ROLLS .. " tries: " .. fac.id.. " -> " .. dumps(generator))
        return
      end
    end
  end

  -- Vehicle Templates, Finalizing and Generation --------------------------------------------

  local eligibleVehicles
  local function getDeliveryVehicleTemplates()
    local templates = inputs.services.sharedTemplates.loadVehicleFilters()
    if not eligibleVehicles then
      eligibleVehicles = inputs.services.stockOverrides.getEligibleVehicleCatalog(false, true)
    end
    return templates
  end

  local function getVehicleFilterByIdSafe(filterId, context)
    getDeliveryVehicleTemplates()
    local filter = inputs.services.sharedTemplates.getVehicleFilterById(filterId)
    if filter then
      return filter
    end

    log("E", "", string.format("%s: unknown vehicle filterId '%s'", context or "delivery.generator", tostring(filterId)))
    return nil
  end

  local function getRandomVehicleFromFilterByFilterId(filterId)
    local filter = getVehicleFilterByIdSafe(filterId, "getRandomVehicleFromFilterByFilterId")
    if not filter then
      return nil
    end

    local info = getRandomVehicleInfo(filter, eligibleVehicles)
    if info then return info, (filter.filterName or "Vehicle") end
  end

  local function finalizeVehicleOffer(offer)

    if not offer.vehicle.model then
      local vehInfo, filterName = getRandomVehicleFromFilterByFilterId(offer.vehicle.filterId)

      if not vehInfo then
        log("E","","finalizeVehicleOffer: getRandomVehicleFromFilterByFilterId returned nil for filterId: " .. tostring(offer.vehicle.filterId))
        return
      end

      offer.vehicle.model = vehInfo.model_key
      offer.vehicle.config = vehInfo.key
      if vehInfo.filter.whiteList.Mileage then
        offer.vehicle.mileage = randomGauss3()/3 * (vehInfo.filter.whiteList.Mileage.max - vehInfo.filter.whiteList.Mileage.min) + vehInfo.filter.whiteList.Mileage.min
      else
        offer.vehicle.mileage = 0
      end
      offer.vehicle.brand = vehInfo.Brand
      offer.vehicle.name = vehInfo.Name
      offer.vehicle.filterName = filterName
    end

    if not offer.rewards then
      local lastLoc
      local distance = 0
      for i, loc in ipairs(offer.locations) do
        if lastLoc then
          distance = distance + callbacks.getDistanceBetweenFacilities(lastLoc, loc)
        end
        lastLoc = loc
      end

      offer.data.originalDistance = distance

      local filter = getVehicleFilterByIdSafe(offer.vehicle.filterId, "finalizeVehicleOffer")
      if not filter then
        return
      end

      offer.rewards = sharedCalc.getVehicleOfferReward(filter, distance, offer.data.type, offer.organization)
      offer.data.logisticsPayRevision = inputs.services.balance.payRevision
    end
  end
  -- Filters ship per level; generators naming a filter the level lacks are skipped.
  local warnedMissingFilters = {}
  local function getAvailableVehicleFilters(generator)
    if generator._availableFilters then return generator._availableFilters end
    getDeliveryVehicleTemplates()
    local available = {}
    local filters = type(generator.filter) == "table" and generator.filter or {generator.filter}
    for _, filterId in ipairs(filters) do
      if inputs.services.sharedTemplates.getVehicleFilterById(filterId) then
        available[#available + 1] = filterId
      elseif not warnedMissingFilters[filterId] then
        warnedMissingFilters[filterId] = true
        log("W", "", string.format("Vehicle filter '%s' does not exist on this level; generators using it are skipped", tostring(filterId)))
      end
    end
    generator._availableFilters = available
    return available
  end

  local function triggerVehicleOfferGenerator(fac, generator, timeOffset)
    local availableFilters = getAvailableVehicleFilters(generator)
    if not availableFilters[1] then return end
    -- Tutorial-only generator records never produce offers; no career tutorial needs them any more.
    if generator.isTutorialGenerator then
      return
    end

    local count = math.random(generator.min, generator.max)

    local haulDestination
    local haulExpiresAt
    for  i = 1, count do
      if callbacks.yieldGeneration then callbacks.yieldGeneration() end
      local logisticType = callbacks.randomFromList(generator.logisticTypes)

      local originAp = callbacks.selectAccessPointByLookupKeyByType(fac.accessPointsByName, logisticType, "logisticTypesProvidedLookup")
      if not originAp then
        log("E","","Could not find AP in facility " .. fac.id .. " with providing type " .. logisticType)
        goto continue
      end
      local origin = {type = "facilityParkingspot", facId = fac.id, psPath = originAp.psPath}

      local destinationFac = haulDestination and gen.facilitiesById[haulDestination.facId]
        or callbacks.selectFacilityByLookupKeyByType(logisticType, "logisticTypesReceivedLookup", fac.id)
      if not destinationFac then
        log("W","",string.format("Could not find target facility to deliver from %s with type %s", fac.id, logisticType))
        return
      end
      local destinationAp = haulDestination and destinationFac.accessPointsByName[haulDestination.name]
        or callbacks.selectAccessPointByLookupKeyByType(destinationFac.accessPointsByName, logisticType, "logisticTypesReceivedLookup")
      if not destinationAp then
        log("E","","Could not find AP in facility " .. destinationFac.id .. " with receiving type " .. logisticType)
        goto continue
      end

      local destination = {type = "facilityParkingspot", facId = destinationFac.id, psPath = destinationAp.psPath}
      if fac.carHaulFacility then
        haulDestination={facId=destinationFac.id,name=destinationAp.name}
      end
      local dropOff = deepcopy(destination)

      if callbacks.getDistanceBetweenFacilities(origin, dropOff) < minDeliveryDistance
          and generator.allowShortDistance ~= true then
        origin = nil
        dropOff = nil
        goto continue
      end

      local filterId = callbacks.randomFromList(availableFilters)
      local vehicleFilter = getVehicleFilterByIdSafe(filterId, "triggerVehicleOfferGenerator")
      if not vehicleFilter then
        goto continue
      end

      local vehType = vehicleFilter.type

      local task = nil
      local type = nil
      local name = nil
      if vehType == "vehicle" then
        task = {
          type = "vehicleDropOff",
          destination = dropOff,
          dropOff = dropOff,
          lookupType = logisticType,
        }
        type = "vehicle"
        name = _tr("ui.career.delivery.offerNames.vehicleTransport")
      elseif vehType == "trailer" then
        task = {
          type = "trailerDropOff",
          destination = dropOff,
          dropOff = dropOff,
          lookupType = logisticType,
        }
        type = "trailer"
        name = _tr("ui.career.delivery.offerNames.trailerTransport")
      end

      local offerDuration = generator.interval * (math.random() * 0.8 + 0.8)
      if generator.offerDuration then
        offerDuration = math.random() * (generator.offerDuration.max - generator.offerDuration.min) + generator.offerDuration.min
      end
      local expiresAt=callbacks.generationTime()+timeOffset+offerDuration
      if haulDestination then haulExpiresAt=haulExpiresAt or expiresAt;expiresAt=haulExpiresAt end

      gen.cargoId = gen.cargoId + 1
      local item = {
        id = gen.cargoId,
        name = name,

        task = task,

        vehicle = {
          filterId = filterId,
          unlockTag = vehicleFilter.unlockTag,
        },
        locations = {origin, dropOff},
        dropOffFacId = dropOff.facId,
        offerExpiresAt = expiresAt,

        spawnLocation = deepcopy(origin),
        origin = origin,

        data = {
          type = type,
          isTutorialVehicle = false
        },

        generatorLabel = generator.name,
        generatedAtTimestamp = callbacks.generationTime() + timeOffset,
        organization = callbacks.getOfferOrganization(fac, destinationFac, generator.offerMode)
      }
      item.offerMode = generator.offerMode
      ext.vehicleOfferManager.addOffer(item)
      ::continue::
    end
  end

  return {
    finalizeParcelItemDistanceAndRewards = finalizeParcelItemDistanceAndRewards,
    finalizeVehicleOffer = finalizeVehicleOffer,
    getDeliveryParcelTemplates = getDeliveryParcelTemplates,
    getDeliveryVehicleTemplates = getDeliveryVehicleTemplates,
    getParcelTemplateById = getParcelTemplateById,
    getVehicleFilterByIdSafe = getVehicleFilterByIdSafe,
    isLoadedParcelAvailableOnCurrentMap = isLoadedParcelAvailableOnCurrentMap,
    isLoadedVehicleOfferAvailableOnCurrentMap = isLoadedVehicleOfferAvailableOnCurrentMap,
    isLocationAvailableOnCurrentMap = isLocationAvailableOnCurrentMap,
    triggerParcelGenerator = triggerParcelGenerator,
    triggerVehicleOfferGenerator = triggerVehicleOfferGenerator,
    upgradeLoadedParcelIfNeeded = upgradeLoadedParcelIfNeeded,
  }
end

return part
