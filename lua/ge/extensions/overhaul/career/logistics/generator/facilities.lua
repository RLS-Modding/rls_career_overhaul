-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Builds delivery facilities, generator templates, access points and restored generator state.
-- generator.lua owns the live facility tables and tick; this part prepares them.
-- Map, in reading order:
--   templates           generator template cache, legacy material normalization, logistic type to system
--   loaner data         applying the loaner list and loaner spot lookups
--   facility setup      collectDeliveryFacilities, then setupFacilityRecord: progress, lookups, generators,
--                       sites, loaner / drop-off / manual access points, the spot indexes; then the systems
--   contract access     restoreMaterialAccess: re-enables saved material contracts whose material a map retired
--   setup entry         setup(loadData): reset, restore freight and parcels or generate them, restore or
--                       generate vehicle offers, finish; the public normalize and setup functions

-- Registers the contract's spot on the facility, with its material storage, for one side of the trade.
local function enableAccess(api, location, materialType, provider, quantity)
  local facility = location and api.getFacility(location.facId)
  if not facility then return end
  local spot = api.getSpot(location.psPath)
  if not spot then return end
  local name = spot.name
  local accessPoint = facility.accessPointsByName[name] or {name = name, facId = facility.id, psPath = location.psPath, ps = spot,
    logisticTypesProvidedLookup = {}, logisticTypesReceivedLookup = {}}
  facility.accessPointsByName[name] = accessPoint
  local key = provider and 'logisticTypesProvidedLookup' or 'logisticTypesReceivedLookup'
  accessPoint[key][materialType] = true
  facility[key][materialType] = true
  local spots = provider and facility.pickUpSpots or facility.dropOffSpots
  local found = false
  for _, existing in ipairs(spots) do
    if existing == spot then found = true end
  end
  if not found then spots[#spots + 1] = spot end
  local storage = facility.materialStorages[materialType] or {materialType = materialType, id = facility.id .. '-storage-' .. materialType,
    target = provider and quantity or 0, storedVolume = provider and quantity or 0, capacity = quantity, standardLoad = quantity, maxContractVolume = quantity}
  storage[provider and 'isProvider' or 'isReceiver'] = true
  storage.capacity = math.max(storage.capacity or 0, quantity)
  facility.materialStorages[materialType] = storage
  if api.getSystems then
    local systems = facility[provider and 'providedSystemsLookup' or 'receivedSystemsLookup']
    for system, enabled in pairs(api.getSystems(materialType, facility)) do
      if enabled then systems[system] = true end
    end
  end
end

local function savedContracts(data)
  local saved = data.materialContracts or {}
  local contracts = {}
  for _, contract in pairs(saved.activeContracts or {}) do contracts[#contracts + 1] = contract end
  if saved.activeContract then contracts[#contracts + 1] = saved.activeContract end
  return contracts
end

-- Moves an open contract onto its material's current id when its source still names the old one.
-- Returns true when the contract was restored.
local function restoreContract(api, contract, aliasesByContract)
  local isOpen = contract.status ~= 'completed' and (contract.deliveredAmount or 0) < (contract.totalAmount or 0)
  if not isOpen then return false end
  local source = api.getFacility(contract.sourceFacId)
  if not (source and source.legacyMaterialAliases) then return false end
  local oldType = contract.materialType
  local material = (source.legacyMaterialAliases or {})[oldType] or oldType
  if not api.getMaterial(material) then return false end
  contract.materialType = material
  aliasesByContract[contract.id] = material
  enableAccess(api, contract.origin, material, true, contract.totalAmount)
  enableAccess(api, contract.destination, material, false, contract.totalAmount)
  return true
end

-- Keeps accepted material work deliverable when a map retires material aliases and routes. Adds access only for saved active contracts; it never creates generators.
-- Returns how many saved contracts were restored; a save without contracts restores none.
local function restoreMaterialAccess(data, api)
  local aliasesByContract = {}
  local restored = 0
  for _, contract in ipairs(savedContracts(data)) do
    if restoreContract(api, contract, aliasesByContract) then restored = restored + 1 end
  end
  for _, cargo in ipairs(data.parcels or {}) do
    local material = cargo.data and aliasesByContract[cargo.data.materialContractId]
    if material then cargo.materialType = material end
  end
  return restored
end

local part = {}

-- Builds facility setup for one generator instance. Nothing is kept at file level, so each load of
-- generator.lua gets its own closures over its own state.
function part.new(inputs)
  local ext, gen = inputs.services.ext, inputs.state.gen
  local callbacks = inputs.callbacks
  local balance, sharedTemplates = inputs.services.balance, inputs.services.sharedTemplates

  local function createGeneratorTemplateCache(generator)
    if generator.type == "parcelProvider" or generator.type == "parcelReceiver" then
      generator.validTemplates = {}
      generator.sumChance = 0
      for _, item in ipairs(callbacks.getDeliveryParcelTemplates()) do
        local match = false
        for key, _ in pairs(generator.logisticTypesLookup) do
          match = match or item.logisticType == key
        end
        if generator.slotsMin and item.minSlots < generator.slotsMin then
          match = false
        end
        if generator.slotsMax and item.maxSlots > generator.slotsMax then
          match = false
        end
        if match then
          table.insert(generator.validTemplates, {item = item, chance = item.generationChance})
          generator.sumChance = generator.sumChance + item.generationChance
        end
      end
    end
  end

  local generatorTypeToDirection = {
    parcelProvider = "providedSystemsLookup",
    parcelReceiver = "receivedSystemsLookup",
    vehOfferProvider = "providedSystemsLookup",
    trailerOfferProvider = "providedSystemsLookup",
    materialProvider = "providedSystemsLookup",
    materialReceiver = "receivedSystemsLookup",
  }

  local compatibilityWarnings = {}

  local function addLogisticType(list, logisticType)
    if not callbacks.listContains(list, logisticType) then
      table.insert(list, logisticType)
    end
  end

  local function attachCompatibilityAccessPoint(fac, materialType, isProvider)
    local field = isProvider and "logisticTypesProvided" or "logisticTypesReceived"
    local accessPoints = fac.manualAccessPoints or {}
    local selected

    for _, accessPoint in ipairs(accessPoints) do
      if callbacks.listContains(accessPoint[field], materialType) then return end
    end
    for _, accessPoint in ipairs(accessPoints) do
      if callbacks.listContains(accessPoint[field], "parcel") then
        selected = accessPoint
        break
      end
    end
    selected = selected or accessPoints[1]
    if selected then
      selected[field] = selected[field] or {}
      addLogisticType(selected[field], materialType)
    end
  end

  local function legacyMaterialLookup(materialLookup)
    materialLookup = materialLookup or {}
    if not next(materialLookup) then
      for _, material in ipairs(callbacks.getMaterialsTemplates()) do materialLookup[material.id] = true end
    end
    return materialLookup
  end

  local function existingBulkGenerators(fac)
    local existing = {}
    for _, generator in ipairs(fac.logisticGenerators) do
      if (generator.type == "materialProvider" or generator.type == "materialReceiver") and generator.materialType then
        existing[generator.type .. ":" .. generator.materialType] = true
      end
    end
    return existing
  end

  -- Preserve original generator indexes for old saves. Recognized material IDs are removed from parcel generators and stable synthetic bulk generators are appended after every expansion-defined generator.
  local function normalizeLegacyMaterialGenerators(fac, materialLookup)
    if fac._bulkMaterialCompatibilityNormalized then return end
    fac.logisticGenerators = fac.logisticGenerators or {}

    materialLookup = legacyMaterialLookup(materialLookup)
    local existingBulk = existingBulkGenerators(fac)
    local pendingByKey = {}
    for originalIndex, generator in ipairs(fac.logisticGenerators) do
      if generator.type == "parcelProvider" or generator.type == "parcelReceiver" then
        local remainingTypes = {}
        local bulkType = generator.type == "parcelProvider" and "materialProvider" or "materialReceiver"
        for _, logisticType in ipairs(generator.logisticTypes or {}) do
          if materialLookup[logisticType] then
            local key = bulkType .. ":" .. logisticType
            if not existingBulk[key] and not pendingByKey[key] then
              pendingByKey[key] = {
                type = bulkType,
                logisticTypes = {logisticType},
                materialType = logisticType,
                capacity = 20000,
                target = bulkType == "materialProvider" and 20000 or 0,
                variance = 1000,
                interval = generator.interval or 300,
                rate = 4000,
                _syntheticBulkMaterial = true,
                _legacyGeneratorIndex = originalIndex
              }
            end
          else
            table.insert(remainingTypes, logisticType)
          end
        end
        generator.logisticTypes = remainingTypes
        generator._bulkCompatibilityDisabled = #remainingTypes == 0
      end
    end

    local pending = {}
    for _, generator in pairs(pendingByKey) do
      table.insert(pending, generator)
    end
    table.sort(pending, function(a, b)
      if a.materialType == b.materialType then return a.type < b.type end
      return a.materialType < b.materialType
    end)
    for _, generator in ipairs(pending) do
      table.insert(fac.logisticGenerators, generator)
      local isProvider = generator.type == "materialProvider"
      local directionList = isProvider and fac.logisticTypesProvided or fac.logisticTypesReceived
      addLogisticType(directionList, generator.materialType)
      attachCompatibilityAccessPoint(fac, generator.materialType, isProvider)

      local warningKey = tostring(fac.id) .. ":" .. generator.materialType
      if not compatibilityWarnings[warningKey] then
        compatibilityWarnings[warningKey] = true
        log("W", "", string.format(
          "Facility '%s' uses legacy material parcel generation for '%s'; using synthetic bulk storage.",
          tostring(fac.id), generator.materialType))
      end
    end
    fac._bulkMaterialCompatibilityNormalized = true
  end
  local function logisticTypeToSystem(type, fac)
    local parcelTemplateIdsByLogisticType = sharedTemplates.getTemplateIdsByLogisticType()
    if parcelTemplateIdsByLogisticType[type] and next(parcelTemplateIdsByLogisticType[type]) then
      return {parcelDelivery = true}
    end
    local materialData = callbacks.getMaterialsTemplatesById(type)
    if materialData then
      return require('overhaul/lib/logistics/cargoSemantics').materialSystems(materialData.type, fac, type)
    end
    return {}
  end

  local function addLoanerSpotsToFacility(resTable, priorityKey, fac, sites, accessPointsByName)
    local loanerSpots = deepcopy(fac.manualAccessPoints or {})
    table.sort(loanerSpots, function(a,b) return (a[priorityKey] or 0) < (b[priorityKey] or 0) end)
    for _, psData in ipairs(loanerSpots) do
      if psData[priorityKey] then
        local psFound = false
        for _, sitesFromFile in ipairs(sites) do
          local ps = sitesFromFile.parkingSpots.byName[psData.psName]
          if ps then
            table.insert(resTable, ps)

            local ap = accessPointsByName[ps.name] or { ps = ps }
            ap.isLoanerVehicleSpot = true
            accessPointsByName[ps.name] = ap

            gen.parkingSpotsByPath[ps:getPath()] = ps
            psFound = true
            break
          end
        end
        if not psFound then
          log("E", "delivery", "missing loaner parking spot " .. tostring(psData.psName) .. " for facility " .. tostring(fac.id))
        end
      end
    end
  end

  local facilitiesSetup = false

  local function validLoanerOverlay(record)
    if type(record) ~= 'table' then return false end
    if record.associatedOrganization ~= nil and type(record.associatedOrganization) ~= 'string' then return false end
    if record.loanableVehicles ~= nil and type(record.loanableVehicles) ~= 'table' then return false end
    if record.sitesFile ~= nil then
      if type(record.sitesFile) ~= 'string' or record.sitesFile:sub(1, 1) == '/'
        or record.sitesFile:find('..', 1, true) or not record.sitesFile:match('%.sites%.json$') then return false end
    end
    for _, field in ipairs({'nonTrailerSpots', 'trailerSpots'}) do
      if record[field] ~= nil then
        if type(record[field]) ~= 'table' then return false end
        for _, name in ipairs(record[field]) do
          if type(name) ~= 'string' or name == '' then return false end
        end
      end
    end
    return true
  end

  -- Loaner overlays live beside their owner's facilities. Other maps may reuse facility ids safely.
  local function loadFacilityLoanerData()
    local level = getCurrentLevelIdentifier()
    local records = {}
    if not level then return records end
    local root = require('overhaul/lib/world/levelData').assetPath(level, 'facilities/')
    local files = FS:findFiles(root, '*.facilities.json', -1, false, true) or {}
    table.sort(files)
    for _, file in ipairs(files) do
      local data = jsonReadFile(file)
      for id, record in pairs(type(data) == 'table' and type(data.loaners) == 'table' and data.loaners or {}) do
        if data.version == 1 and validLoanerOverlay(record) then
          local overlay = deepcopy(record)
          if overlay.sitesFile then
            overlay.sitesFile = file:match('^(.*[/])') .. overlay.sitesFile
          end
          records[id] = overlay
        else
          log('W', 'delivery', 'Ignoring invalid local loaner overlay: ' .. file .. ' / ' .. tostring(id))
        end
      end
    end
    return records
  end

  local function applyFacilityLoanerData(fac, loanerData)
    if not loanerData then return end

    fac.associatedOrganization = loanerData.associatedOrganization or fac.associatedOrganization
    fac.loanableVehicles = deepcopy(loanerData.loanableVehicles or fac.loanableVehicles or {})
    fac.manualAccessPoints = fac.manualAccessPoints or {}

    local function hasManualAccessPoint(psName)
      for _, accessPoint in ipairs(fac.manualAccessPoints) do
        if accessPoint.psName == psName then return true end
      end
      return false
    end

    for priority, psName in ipairs(loanerData.nonTrailerSpots or {}) do
      if not hasManualAccessPoint(psName) then
        table.insert(fac.manualAccessPoints, {
          psName = psName,
          isInspectSpot = false,
          logisticTypesProvided = {},
          logisticTypesReceived = {},
          loanerNonTrailerPriority = priority
        })
      end
    end

    for priority, psName in ipairs(loanerData.trailerSpots or {}) do
      if not hasManualAccessPoint(psName) then
        table.insert(fac.manualAccessPoints, {
          psName = psName,
          isInspectSpot = false,
          logisticTypesProvided = {},
          logisticTypesReceived = {},
          loanerTrailerPriority = priority
        })
      end
    end
  end

  local function resetFacilityState()
    require('overhaul/career/logistics/generator/routeCache').save(gen.routes)
    gen.facilities = {}
    gen.facilitiesById = {}
    gen.parkingSpotsByPath = {}
    gen.distanceCache = {}
    gen.routes = {graph = nil}
    gen.matchingCounts = nil
    gen.hasGeneratedThisFrame = false
    gen.nextGeneratorCheckTimestamp = -math.huge
    gen.generationBatch = nil
    gen.ensuringCurrentOffers = false
    facilitiesSetup = false
    gen.setupLevelIdentifier = nil
  end

  -- Facilities from the delivery-provider list, one per id. Duplicates and entries without an id are logged and dropped.
  local function collectDeliveryFacilities()
    local unique, seenIds = {}, {}
    for _, fac in ipairs(overhaul_world_facilities.getFacilitiesByType("deliveryProvider") or {}) do
      if fac and fac.id and not seenIds[fac.id] then
        seenIds[fac.id] = true
        table.insert(unique, fac)
      elseif fac and fac.id then
        log("W", "delivery", string.format("Ignoring duplicate logistics facility id '%s' during setup", tostring(fac.id)))
      else
        log("W", "delivery", "Ignoring logistics facility without an id during setup")
      end
    end
    return unique
  end

  -- Progress and material storage come from the save when it has them; otherwise both start empty.
  local function restoreFacilityProgress(fac, savedFacility)
    fac.progress = {
      deliveredFromHere = {
        countByType = {parcel = 0, vehicle = 0, trailer = 0, fluid = 0, dryBulk = 0},
        moneySum = 0,
      },
      deliveredToHere = {
        countByType = {parcel = 0, vehicle = 0, trailer = 0, fluid = 0, dryBulk = 0},
        moneySum = 0,
      },
      interacted = false,
    }
    if savedFacility and savedFacility.progress then
      fac.progress = savedFacility.progress
    end
    fac.materialStorages = {}
    if savedFacility and savedFacility.materialStorages then
      fac.materialStorages = savedFacility.materialStorages
    end
  end

  -- Logistic type lists become lookup tables; the systems each side offers start empty.
  local function setupLogisticTypeLookups(fac)
    fac.logisticTypesProvided = fac.logisticTypesProvided or {}
    fac.logisticTypesReceived = fac.logisticTypesReceived or {}
    fac.logisticTypesProvidedLookup = tableValuesAsLookupDict(fac.logisticTypesProvided)
    fac.logisticTypesReceivedLookup = tableValuesAsLookupDict(fac.logisticTypesReceived)
    fac.providedSystemsLookup = {}
    fac.receivedSystemsLookup = {}
    fac.logisticMaxItems = fac.logisticMaxItems or -1
    fac.logisticGenerators = fac.logisticGenerators or {}
    normalizeLegacyMaterialGenerators(fac)
  end

  -- One generator record: its name, its first due time (one random draw), its lookups and template cache. Returns true when it names a logistic type the facility does not list yet.
  local function setupGenerator(fac, generator, index, savedFacility)
    generator.name = string.format("%s %d %s %d", fac.name, index, generator.type, generator.interval)
    generator.nextGenerationTimestamp = ext.general.time() + (generator.interval) * math.random()
    local savedGenerator = savedFacility and savedFacility.logisticGenerators and savedFacility.logisticGenerators[index]
    if savedGenerator then
      generator.nextGenerationTimestamp = savedGenerator.nextGenerationTimestamp
    end

    generator.logisticTypes = generator.logisticTypes or {}
    local isMaterial = generator.type == "materialProvider" or generator.type == "materialReceiver"
    if isMaterial and generator.materialType and not callbacks.listContains(generator.logisticTypes, generator.materialType) then
      table.insert(generator.logisticTypes, generator.materialType)
    end
    generator.logisticTypesLookup = tableValuesAsLookupDict(generator.logisticTypes)
    createGeneratorTemplateCache(generator)
    if isMaterial then
      callbacks.setupMaterialStorage(fac, generator)
    end

    local direction = generatorTypeToDirection[generator.type]
    local missing = false
    for _, logisticType in ipairs(generator.logisticTypes) do
      if direction == "providedSystemsLookup" and not fac.logisticTypesProvidedLookup[logisticType] then
        fac.logisticTypesProvidedLookup[logisticType] = true
        missing = true
      end
      if direction == "receivedSystemsLookup" and not fac.logisticTypesReceivedLookup[logisticType] then
        fac.logisticTypesReceivedLookup[logisticType] = true
        missing = true
      end
    end
    if generator.type == "vehOfferProvider" then
      fac.providedSystemsLookup.vehicleDelivery = true
    end
    if generator.type == "trailerOfferProvider" then
      fac.providedSystemsLookup.trailerDelivery = true
    end
    return missing
  end

  local function logMissingLogisticTypes(fac)
    log("E", "", string.format("Fix Facility %s provided types: [\"%s\"]", fac.id, table.concat(tableKeysSorted(fac.logisticTypesProvidedLookup), '", "')))
    log("E", "", string.format("Fix Facility %s received types: [\"%s\"]", fac.id, table.concat(tableKeysSorted(fac.logisticTypesReceivedLookup), '", "')))
  end

  -- The facility's own parking-spot files, plus its local overlay's authored sites.
  local function loadFacilitySites(fac, facilityLoanerData)
    local sites = {}
    if type(fac.sitesFile) == "string" then
      table.insert(sites, gameplay_sites_sitesManager.loadSites(fac.sitesFile))
    else
      for _, sitesFile in ipairs(fac.sitesFile or {}) do
        table.insert(sites, gameplay_sites_sitesManager.loadSites(sitesFile))
      end
    end
    local overlay = facilityLoanerData[fac.id]
    if overlay and overlay.sitesFile then
      local loaded = gameplay_sites_sitesManager.loadSites(overlay.sitesFile)
      if loaded then table.insert(sites, loaded) end
    end
    return sites
  end

  local function attachLoanerAccessPoints(fac, sites, accessPointsByName)
    fac.loanerTrailerSpots = {}
    addLoanerSpotsToFacility(fac.loanerTrailerSpots, "loanerTrailerPriority", fac, sites, accessPointsByName)
    fac.loanerNonTrailerSpots = {}
    addLoanerSpotsToFacility(fac.loanerNonTrailerSpots, "loanerNonTrailerPriority", fac, sites, accessPointsByName)
  end

  -- Spots inside a drop-off zone become drop-off access points that take the facility's receivable types.
  local function attachDropOffAccessPoints(fac, sites, accessPointsByName)
    for _, filter in ipairs(fac.multiDropOffSpotFilter or {}) do
      if type(filter) == "table" and filter.type == "byZone" then
        local zoneName = filter.zoneName
        local psFound = false
        for _, sitesFromFile in ipairs(sites) do
          local zone = sitesFromFile.zones.byName[zoneName]
          for _, ps in ipairs(sitesFromFile.parkingSpots.sorted) do
            if zone and zone:containsPoint2D(ps.pos) then
              local ap = accessPointsByName[ps.name] or {ps = ps}
              ap.isDropOffSpot = true
              ap.logisticTypesReceivedLookup = deepcopy(fac.logisticTypesReceivedLookup)
              accessPointsByName[ps.name] = ap

              gen.parkingSpotsByPath[ps:getPath()] = ps
              psFound = true
            end
          end
        end
        if not psFound then
          log("E", "delivery", "missing drop-off parking spot in zone " .. tostring(zoneName) .. " of facility " .. tostring(fac.id))
        end
      end
    end
  end

  -- The facility's manual access points, each with the logistic types its save or map record lists.
  local function attachManualAccessPoints(fac, sites, accessPointsByName)
    for _, elem in ipairs(fac.manualAccessPoints or {}) do
      local psFound = false
      for _, sitesFromFile in ipairs(sites) do
        local ps = sitesFromFile.parkingSpots.byName[elem.psName]
        if ps then
          local accessPoint = accessPointsByName[ps.name] or {ps = ps}

          accessPoint.isInspectSpot = elem.isInspectSpot
          accessPoint.loanerNonTrailerPriority = elem.loanerNonTrailerPriority
          accessPoint.loanerTrailerPriority = elem.loanerTrailerPriority
          accessPoint.logisticTypesReceivedLookup = elem.logisticTypesReceived and tableValuesAsLookupDict(elem.logisticTypesReceived) or deepcopy(fac.logisticTypesReceivedLookup)
          accessPoint.logisticTypesProvidedLookup = elem.logisticTypesProvided and tableValuesAsLookupDict(elem.logisticTypesProvided) or deepcopy(fac.logisticTypesProvidedLookup)

          if elem.loanerNonTrailerPriority or elem.loanerTrailerPriority then
            fac.hasLoanerSpots = true
          end
          accessPointsByName[ps.name] = accessPoint

          gen.parkingSpotsByPath[ps:getPath()] = ps
          psFound = true
          break
        end
      end
      if not psFound then
        log("E", "delivery", "missing manual parking spot " .. tostring(elem.psName) .. " for facility " .. tostring(fac.id))
      end
    end
  end

  -- Every access point gets its name, facility and path; missing lookups become empty tables.
  local function finishAccessPoints(fac, accessPointsByName)
    for name, ap in pairs(accessPointsByName) do
      ap.name = name
      ap.facId = fac.id
      ap.psPath = ap.ps:getPath()
      ap.logisticTypesReceivedLookup = ap.logisticTypesReceivedLookup or {}
      ap.logisticTypesProvidedLookup = ap.logisticTypesProvidedLookup or {}
    end
    if not next(accessPointsByName) then
      log("E", "", "Facility " .. fac.id .. " has no access points!")
    end
    fac.accessPointsByName = accessPointsByName
  end

  -- Drop-off, pick-up and inspect spot lists, read from the access points in table order.
  local function buildFacilityIndexes(fac)
    fac.dropOffSpots = {}
    fac.pickUpSpots = {}
    fac.inspectSpots = {}
    for _, ap in pairs(fac.accessPointsByName) do
      if ap.isDropOffSpot or next(ap.logisticTypesReceivedLookup) then
        table.insert(fac.dropOffSpots, ap.ps)
      end
      if next(ap.logisticTypesProvidedLookup) then
        table.insert(fac.pickUpSpots, ap.ps)
      end
      if ap.isInspectSpot and ap.ps then
        table.insert(fac.inspectSpots, ap.ps)
      end
    end
  end

  -- Builds one facility from its map record and its save entry, then registers it.
  local function validateCommercialMetadata(fac)
    local broker = fac.broker
    if broker ~= nil then
      local valid = type(broker) == 'table'
      if valid then
        for _, field in ipairs({'enabled', 'commercial', 'defaultDepot'}) do
          if broker[field] ~= nil and type(broker[field]) ~= 'boolean' then valid = false end
        end
        if broker.order ~= nil and not require('overhaul/lib/platform/jsonCatalog').finite(broker.order) then valid = false end
      end
      if not valid then
        log('W', 'delivery', 'Invalid broker metadata at facility ' .. fac.id .. '; independent routing disabled')
        fac.broker = {enabled = false}
      end
    end
    local hauling = fac.ownerOpCarHauling
    if type(hauling) == 'table' then
      if hauling.refreshQueuedOffersOnRentalOpen ~= nil and type(hauling.refreshQueuedOffersOnRentalOpen) ~= 'boolean' then
        log('W', 'delivery', 'Invalid rental refresh flag at facility ' .. fac.id)
        hauling.refreshQueuedOffersOnRentalOpen = false
      end
      if hauling.contractMultiplier ~= nil and not require('overhaul/lib/platform/jsonCatalog').finite(hauling.contractMultiplier) then
        log('W', 'delivery', 'Invalid car-haul multiplier at facility ' .. fac.id .. '; using neutral balancing')
        hauling.contractMultiplier = nil
      end
    end
  end

  -- Fleets can belong to an organization; freight employers may also issue pool trucks.
  local function warnMissingLoanerSpots(fac)
    local org = fac.associatedOrganization and overhaul_world_organizations.getOrganization(fac.associatedOrganization)
    local fleet = fac.loanableVehicles or (org and org.loanableVehicles) or {}
    local needsTruck, needsTrailer = false, false
    for _, vehicle in ipairs(fleet) do
      local modelInfo = vehicle.model and core_vehicles.getModel(vehicle.model)
      local model = modelInfo and (modelInfo.model or modelInfo)
      if model and model.Type == 'Trailer' then needsTrailer = true else needsTruck = true end
    end
    if fac.associatedOrganization and not fac.omitEmployment
      and not (type(fac.loanableVehicles) == 'table' and not next(fac.loanableVehicles)) then
      for _, generator in ipairs(fac.logisticGenerators or {}) do
        if generator.type == 'parcelProvider' or generator.type == 'materialProvider'
          or generator.type == 'trailerOfferProvider' or generator.type == 'vehOfferProvider' then
          needsTruck = true
        end
      end
    end
    local missing = {}
    if needsTruck and not fac.loanerNonTrailerSpots[1] then missing[#missing + 1] = 'nontrailer' end
    if needsTrailer and not fac.loanerTrailerSpots[1] then missing[#missing + 1] = 'trailer' end
    if missing[1] then
      log('W', 'delivery', 'Facility ' .. fac.id .. ' has a facility/organization fleet or employment pool but no authored '
        .. table.concat(missing, ' and ') .. ' loaner spawn priorities; issuing those vehicles will be refused')
    end
  end

  local function setupFacilityRecord(fac, loadData, facilityLoanerData)
    validateCommercialMetadata(fac)
    applyFacilityLoanerData(fac, facilityLoanerData[fac.id])
    local savedFacility = loadData.facilities and loadData.facilities[fac.id]
    restoreFacilityProgress(fac, savedFacility)
    setupLogisticTypeLookups(fac)
    local missing = false
    for index, generator in ipairs(fac.logisticGenerators) do
      if setupGenerator(fac, generator, index, savedFacility) then
        missing = true
      end
    end
    if missing then
      logMissingLogisticTypes(fac)
    end

    local accessPointsByName = {}
    local sites = loadFacilitySites(fac, facilityLoanerData)
    attachLoanerAccessPoints(fac, sites, accessPointsByName)
    attachDropOffAccessPoints(fac, sites, accessPointsByName)
    attachManualAccessPoints(fac, sites, accessPointsByName)
    finishAccessPoints(fac, accessPointsByName)
    buildFacilityIndexes(fac)
    warnMissingLoanerSpots(fac)

    table.insert(gen.facilities, fac)
    gen.facilitiesById[fac.id] = fac
  end

  -- A facility's systems come from its logistic types, which are complete only once every facility is built.
  local function buildSystemLookups()
    local countProviders, countMixed, countReceivers = 0, 0, 0
    for _, fac in ipairs(gen.facilities) do
      for _, logisticType in ipairs(fac.logisticTypesProvided) do
        for sys, en in pairs(logisticTypeToSystem(logisticType, fac)) do
          if en then
            fac.providedSystemsLookup[sys] = true
          end
        end
      end
      for _, logisticType in ipairs(fac.logisticTypesReceived) do
        for sys, en in pairs(logisticTypeToSystem(logisticType, fac)) do
          if en then
            fac.receivedSystemsLookup[sys] = true
          end
        end
      end

      if next(fac.providedSystemsLookup) and next(fac.receivedSystemsLookup) then
        countMixed = countMixed + 1
      elseif next(fac.providedSystemsLookup) then
        countProviders = countProviders + 1
      elseif next(fac.receivedSystemsLookup) then
        countReceivers = countReceivers + 1
      end
    end
    return countProviders, countMixed, countReceivers
  end

  local function setupFacilities(loadData)
    if facilitiesSetup then return end
    local facilityLoanerData = loadFacilityLoanerData()
    for _, fac in ipairs(collectDeliveryFacilities()) do
      setupFacilityRecord(fac, loadData, facilityLoanerData)
    end
    local countProviders, countMixed, countReceivers = buildSystemLookups()
    table.sort(gen.facilities, function(a, b) return _tr(a.name) < _tr(b.name) end)
    log("I", "", string.format("Setup Logistics Facilities: %d Facilities (%d only provide, %d mixed, %d only receive), %d Parking spots", #tableKeys(gen.facilitiesById), countProviders, countMixed, countReceivers, #tableKeys(gen.parkingSpotsByPath)))
    facilitiesSetup = true
  end

  local function discardStaleLiveCargo()
    if not (ext.parcelManager and ext.parcelManager.getAllCargoCustomFilter) then return end
    for _, cargo in ipairs(ext.parcelManager.getAllCargoCustomFilter(function() return true end) or {}) do
      if not callbacks.isLoadedParcelAvailableOnCurrentMap(cargo) then
        ext.parcelManager.changeCargoLocation(cargo.id, {type = "delete"})
      end
    end
    if ext.parcelManager.cleanUpCargo then ext.parcelManager.cleanUpCargo() end
  end

  -- Facility and generation state is rebuilt from scratch; storage configured by an earlier setup is marked stale.
  local function resetSetupState(loadData)
    resetFacilityState()
    gen.setupLevelIdentifier = getCurrentLevelIdentifier()
    gen.offerBackfillAttempted = {}
    for _, savedFacility in pairs(loadData.facilities or {}) do
      for _, storage in pairs(savedFacility.materialStorages or {}) do
        if type(storage) == "table" then storage._configuredThisSetup = nil end
      end
    end
  end

  local function restoreMaterialContractAccess(loadData)
    restoreMaterialAccess(loadData, {
      getFacility = function(id) return gen.facilitiesById[id] end,
      getSpot = function(path)
        if not gen.parkingSpotsByPath[path] and type(path) == 'string' then
          local file, name = path:match('^(.-)#(.+)$')
          local sites = file and gameplay_sites_sitesManager.loadSites(file)
          gen.parkingSpotsByPath[path] = sites and sites.parkingSpots.byName[name]
        end
        return gen.parkingSpotsByPath[path]
      end,
      getMaterial = callbacks.getMaterialsTemplatesById,
      getSystems = logisticTypeToSystem,
    })
  end

  -- Parcel-manager reads can trigger generation. Setup suppresses that side effect, and IDs must stay above retained cargo even on a same-map rebuild or extension reload. Resetting to zero aliases restored freight to offers.
  local retainedParcelIds = {}
  local function raiseIdCountersAboveRetainedCargo(loadData)
    retainedParcelIds = {}
    for _, records in ipairs({loadData.parcels or {}, loadData.vehicleOffers or {}}) do
      for _, item in ipairs(records) do
        gen.cargoId = math.max(gen.cargoId, tonumber(item.id) or 0)
      end
    end
    for _, cargo in ipairs(ext.parcelManager.getAllCargoCustomFilter(function() return true end)) do
      retainedParcelIds[cargo.id] = true
      gen.cargoId = math.max(gen.cargoId, tonumber(cargo.id) or 0)
      gen.groupId = math.max(gen.groupId, tonumber(cargo.groupId) or 0)
    end
    for _, offer in ipairs(ext.vehicleOfferManager.getAllOfferCustomFilter(function() return true end)) do
      gen.cargoId = math.max(gen.cargoId, tonumber(offer.id) or 0)
    end
    if ext.vehicleOfferManager.resetOffersForLoad then
      ext.vehicleOfferManager.resetOffersForLoad()
    end
  end

  local function restoreOfferId(item)
    if item.id ~= nil then return end
    gen.cargoId = gen.cargoId + 1
    item.id = gen.cargoId
  end

  -- Game seconds a restored reservation keeps its offer open, so a reload does not strand it. The cargo screen shows the countdown, so this stays finite.
  local reservedOfferGraceSec = 3600

  -- Names the first facility or spot of a saved parcel that this map does not have, for the discard log.
  local function describeMissingLocation(cargo)
    for _, location in ipairs({cargo.location, cargo.origin, cargo.destination}) do
      if type(location) == "table" and location.type == "facilityParkingspot" then
        if not gen.facilitiesById[location.facId] then
          return string.format("facility %s", tostring(location.facId))
        end
        if not gen.parkingSpotsByPath[location.psPath] then
          return string.format("spot %s of facility %s", tostring(location.psPath), tostring(location.facId))
        end
      end
    end
    return "a vehicle or multi-stop location"
  end

  -- Retained facility work keeps its id for references outside logistics. Old
  -- saves without parcel ids allocate above every retained offer instead.
  local function restoreSavedParcel(cargo, counts)
    if cargo.id and retainedParcelIds[cargo.id] then return end
    if cargo.generatorLabel == "addMaterialAsParcelToContainer" then
      log("I", "", string.format("Discarding saved material cargo '%s'", tostring(cargo.name)))
      return
    end
    if not cargo.materialType then
      local template = callbacks.getParcelTemplateById(cargo.templateId)
      cargo.materialType = template and template.materialType
    end
    ext.general.migrateOfferAccess(cargo)
    if not callbacks.isLoadedParcelAvailableOnCurrentMap(cargo) then
      counts.discarded = counts.discarded + 1
      counts.missingLocations[describeMissingLocation(cargo)] = true
      return
    end
    -- A reload cannot replay the move that staged this cargo, so give the player time to find its marker and stage it again.
    if cargo.logisticsReserved and cargo.location.type == "facilityParkingspot" then
      cargo.offerExpiresAt = math.max(cargo.offerExpiresAt or 0, ext.general.time() + reservedOfferGraceSec)
    end
    restoreOfferId(cargo)
    retainedParcelIds[cargo.id] = true
    if callbacks.upgradeLoadedParcelIfNeeded(cargo) then
      counts.upgraded = counts.upgraded + 1
    end
    if require('overhaul/lib/logistics/cargoSemantics').cargo(cargo.type).parcel
        and (tonumber(cargo.data and cargo.data.logisticsPayRevision) or 0) < balance.payRevision
        and balance.scaleSavedOfferRewards(cargo.rewards) then
      cargo.data = cargo.data or {}
      cargo.data.logisticsPayRevision = balance.payRevision
    end
    ext.parcelManager.addCargo(cargo)
    counts.loaded = counts.loaded + 1
  end

  -- Returns how many saved parcels were restored; a save without parcels restores none.
  local function restoreSavedParcels(loadData)
    if not (loadData.parcels and next(loadData.parcels)) then return 0 end
    log("I", "", "Loading Parcels from file... " .. #loadData.parcels)
    local counts = {loaded = 0, upgraded = 0, discarded = 0, missingLocations = {}}
    for _, cargo in ipairs(loadData.parcels) do
      restoreSavedParcel(cargo, counts)
    end
    if counts.upgraded > 0 then
      log("I", "", string.format("Recalculated %d facility parcel offers with outdated or invalid rewards", counts.upgraded))
    end
    if counts.discarded > 0 then
      local missing = {}
      for description in pairs(counts.missingLocations) do missing[#missing + 1] = description end
      table.sort(missing)
      log("I", "delivery", string.format("Discarded %d saved parcel offers whose locations this map lacks: %s",
        counts.discarded, table.concat(missing, "; ")))
    end
    gen.groupId = math.max(gen.groupId, (loadData.general and loadData.general.maxGroupId) or 0) + 1
    return counts.loaded
  end

  local function generateInitialParcels()
    log("I", "", "Generating initial parcels...")
    for _, fac in ipairs(gen.facilities) do
      for _, generator in ipairs(fac.logisticGenerators) do
        if generator.type == "parcelProvider" or generator.type == "parcelReceiver" then
          for i = 0, round(240 / generator.interval) do
            callbacks.triggerGenerator(fac, generator, -generator.interval * i)
          end
        end
      end
    end
  end

  -- Restores a retained vehicle or trailer offer unless it belongs to another map.
  local function restoreSavedVehicleOffer(offer, counts)
    ext.general.migrateOfferAccess(offer)
    if not callbacks.isLoadedVehicleOfferAvailableOnCurrentMap(offer) then
      counts.discarded = counts.discarded + 1
      return
    end
    local filterId = offer and offer.vehicle and offer.vehicle.filterId
    local filter = callbacks.getVehicleFilterByIdSafe(filterId, "loadVehicleOffers")
    if not filter then
      return
    end

    offer.data = offer.data or {}
    local pricedTier = offer.data.type == "trailer" and balance.getTrailerPay(filter.unlockTag)
      or (offer.data.type == "vehicle" and balance.getVehiclePay(filter.unlockTag))
    if pricedTier and (tonumber(offer.data.logisticsPayRevision) or 0) < balance.payRevision
        and balance.scaleSavedOfferRewards(offer.rewards) then
      offer.data.logisticsPayRevision = balance.payRevision
    end

    restoreOfferId(offer)
    ext.vehicleOfferManager.addOffer(offer)
  end

  local function restoreSavedVehicleOffers(loadData)
    log("I", "", "Loading Vehicle Offers from file... " .. #loadData.vehicleOffers)
    local counts = {discarded = 0}
    for _, offer in ipairs(loadData.vehicleOffers) do
      restoreSavedVehicleOffer(offer, counts)
    end
    if counts.discarded > 0 then
      log("I", "delivery", string.format("Discarded %d saved vehicle/trailer offers from a different map", counts.discarded))
    end
  end

  local function generateInitialVehicleOffers()
    log("I", "", "Generating initial Vehicle Offers...")
    for _, fac in ipairs(gen.facilities) do
      for _, generator in ipairs(fac.logisticGenerators) do
        if generator.type == "vehOfferProvider" or generator.type == "trailerOfferProvider" then
          for i = 0, round(1000 / generator.interval) do
            callbacks.triggerGenerator(fac, generator, -generator.interval * i)
          end
        end
      end
    end
  end

  local function finishSetup()
    local availableCounts = callbacks.ensureCurrentOffers(true)
    require('overhaul/career/logistics/generator/routeCache').save(gen.routes)
    log("I", "delivery", string.format(
      "Delivery setup complete with %d parcels, %d vehicle offers, and %d trailer offers available",
      availableCounts.parcel, availableCounts.vehicle, availableCounts.trailer))
  end

  -- Rebuilds the delivery state for the current map from the map's facilities and the saved state.
  local function setup(loadData)
    resetSetupState(loadData)
    callbacks.getMaterialsTemplates()
    callbacks.getDeliveryVehicleTemplates()
    setupFacilities(loadData)
    discardStaleLiveCargo()
    restoreMaterialContractAccess(loadData)
    raiseIdCountersAboveRetainedCargo(loadData)
    restoreSavedParcels(loadData)
    generateInitialParcels()
    if loadData.vehicleOffers and next(loadData.vehicleOffers) then
      restoreSavedVehicleOffers(loadData)
    end
    generateInitialVehicleOffers()
    finishSetup()
  end

  return {
    normalizeLegacyMaterialGenerators = normalizeLegacyMaterialGenerators,
    setup = setup,
  }
end

return part
