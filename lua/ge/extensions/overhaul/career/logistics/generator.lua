-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/career/modules/delivery/generator.lua (BeamNG 0.40).
-- This owner keeps facility, schedule and route state; named parts prepare routes, offers, materials and facilities.
-- Read config/state, shared helpers, named parts, offer counts, frame updates, public operations and lifecycle hooks.

local M = {}
local contractAmounts = require("overhaul/lib/logistics/materialContractAmounts")

local sharedCalc = require('overhaul/lib/logistics/calculators')
local balance = require('overhaul/lib/logistics/logisticsBalance')
local sharedTemplates = require('overhaul/lib/logistics/templates')
local stockOverrides = require('overhaul/lib/vehicles/stockVehicleOverrides')
local sharedFacilityScanner = require('overhaul/lib/logistics/facilityScanner')
local xpConfig = require('overhaul/lib/logistics/xpConfig')
local capabilities = require('overhaul/lib/platform/capabilities')

M.dependencies = {"gameplay_sites_sitesManager", "util_configListGenerator"}

-- Config -----------------------------------------------------------------------------------------
local minDeliveryDistance = 150

-- State ------------------------------------------------------------------------------------------
local ext = {
  parcelManager = nil,
  cargoScreen = nil,
  general = nil,
  generator = nil,
  progress = nil,
  vehicleOfferManager = nil,
  parcelMods = nil,
  vehicleTasks = nil,
  materialContracts = nil,
  step = nil,
}
local gen = {
  facilities = {},
  facilitiesById = {},
  parkingSpotsByPath = {},
  setupLevelIdentifier = nil,
  generationBatch = nil,
  runningGenerationBatch = false,
  cargoId = 0,
  groupId = 0,
  routes = {graph = nil},
  distanceCache = {},
  hasGeneratedThisFrame = false,
  nextGeneratorCheckTimestamp = -math.huge,
  ensuringCurrentOffers = false,
  offerBackfillAttempted = {},
  matchingCounts = nil,
  matchingFacilities = nil,
  matchingTotal = nil,
  economyLeafPolicies = nil,
}
local services = {
  ext = ext,
  contractAmounts = contractAmounts,
  sharedCalc = sharedCalc,
  balance = balance,
  sharedTemplates = sharedTemplates,
  stockOverrides = stockOverrides,
  sharedFacilityScanner = sharedFacilityScanner,
  xpConfig = xpConfig,
}

local generationClock = nil
local openEvents = {}
local setupInProgress = false
local generationSuppression = 0
local state = {gen = gen, openEvents = openEvents}

-- Shared helpers ---------------------------------------------------------------------------------
local function generationTime()
  if gen.runningGenerationBatch and generationClock then return generationClock end
  return ext.general.time()
end
-- Profiler events opened by generation; a generator that yields closes them and reopens them next frame.
local function profilerPushEvent(name)
  openEvents[#openEvents + 1] = name
  _G.profilerPushEvent(name)
end
local function profilerPopEvent(name)
  openEvents[#openEvents] = nil
  _G.profilerPopEvent(name)
end
local function yieldGeneration()
  if not gen.runningGenerationBatch then return end
  for i = #openEvents, 1, -1 do _G.profilerPopEvent(openEvents[i]) end
  coroutine.yield()
  for i = 1, #openEvents do _G.profilerPushEvent(openEvents[i]) end
end

-- Customer collections on a company shift belong to the receiving organization.
local function getOfferOrganization(originFacility, destinationFacility, offerMode)
  if offerMode == "employment" and originFacility and originFacility.employmentCustomer == true
      and destinationFacility and destinationFacility.associatedOrganization then
    return destinationFacility.associatedOrganization
  end
  return originFacility and originFacility.associatedOrganization
end

local function endSuppression(ok, ...)
  generationSuppression = generationSuppression - 1
  if not ok then error((...), 0) end
  return ...
end
-- Called by background readers many times a second; passes results through without packing them.
M.withoutGeneration = function(fn, ...)
  generationSuppression = generationSuppression + 1
  return endSuppression(pcall(fn, ...))
end

-- Facility selection ---------------------------------------------------------------------------

-- Facility selection helpers --------------------------------------------------------------------

local function randomFromList(list)
  arrayShuffle(list)
  return list[1] or nil
end

local function listContains(list, value)
  for _, item in ipairs(list or {}) do
    if item == value then
      return true
    end
  end
  return false
end

local function selectFacilityByLookupKeyByType(logisticType, typeLookupKey, originId)
  local validFacs = {}
  for _, fac in ipairs(gen.facilities) do
    if fac.id ~= originId then
      if fac[typeLookupKey][logisticType] then
        table.insert(validFacs, fac)
      end
    end
  end
  return randomFromList(validFacs)
end

local function selectAccessPointByLookupKeyByType(accessPointsByName, logisticType, typeLookupKey)
  local validAps = {}
  for name, ap in pairs(accessPointsByName) do
    if ap[typeLookupKey] and ap[typeLookupKey][logisticType] then
      table.insert(validAps, ap)
    end
  end
  if not next(validAps) then
    log("E","","Could not find any access point with logisticType " .. logisticType .. " in this list via " .. typeLookupKey)
    for name, ap in pairs(accessPointsByName) do
      log("D","", name .. " -> " .. dumps(ap[typeLookupKey]))
    end
    log("D","", debug.tracesimple())
  end
  return randomFromList(validAps)
end
M.selectAccessPointByLookupKeyByType = selectAccessPointByLookupKeyByType

local function getFacilityById(id) return gen.facilitiesById[id] end
local function getParkingSpotByPath(path) return gen.parkingSpotsByPath[path] end
local function getMaterialsTemplatesById(id) return sharedTemplates.getMaterialTemplateById(id) end

local parts = {}

-- Parts ------------------------------------------------------------------------------------------
-- Preserve construction order and validate callbacks before a generator can run.
parts.routes = require('overhaul/career/logistics/generator/routes').new({
  state = state,
  services = services,
  callbacks = {getParkingSpotByPath = getParkingSpotByPath, yieldGeneration = yieldGeneration},
})
parts.offers = require('overhaul/career/logistics/generator/offers').new({
  state = state,
  services = services,
  rules = {minDeliveryDistance = minDeliveryDistance},
  callbacks = {
    generationTime = generationTime,
    yieldGeneration = yieldGeneration,
    getDistanceBetweenFacilities = parts.routes.getDistanceBetweenFacilities,
    getFacilityById = getFacilityById,
    getMaterialsTemplatesById = getMaterialsTemplatesById,
    getOfferOrganization = getOfferOrganization,
    profilerPopEvent = profilerPopEvent,
    profilerPushEvent = profilerPushEvent,
    randomFromList = randomFromList,
    selectAccessPointByLookupKeyByType = selectAccessPointByLookupKeyByType,
    selectFacilityByLookupKeyByType = selectFacilityByLookupKeyByType,
  },
})
parts.materials = require('overhaul/career/logistics/generator/materials').new({
  state = state,
  services = services,
  callbacks = {
    getDistanceBetweenFacilities = parts.routes.getDistanceBetweenFacilities,
    getFacilityById = getFacilityById,
    getMaterialsTemplatesById = getMaterialsTemplatesById,
    getParcelTemplateById = parts.offers.getParcelTemplateById,
    profilerPopEvent = profilerPopEvent,
    profilerPushEvent = profilerPushEvent,
    triggerParcelGenerator = parts.offers.triggerParcelGenerator,
    triggerVehicleOfferGenerator = parts.offers.triggerVehicleOfferGenerator,
  },
})

local isLocationAvailableOnCurrentMap = parts.offers.isLocationAvailableOnCurrentMap

M.finalizeParcelItemDistanceAndRewards = parts.offers.finalizeParcelItemDistanceAndRewards
M.getParcelTemplateById = parts.offers.getParcelTemplateById
M.finalizeVehicleOffer = parts.offers.finalizeVehicleOffer
M.getMaterialsTemplatesById = getMaterialsTemplatesById
M.splitOffPartsFromMaterialCargo = parts.materials.splitOffPartsFromMaterialCargo
M.changeMaterialAmountInFacility = parts.materials.changeMaterialAmountInFacility
M.moveMaterialToDestination = parts.materials.moveMaterialToDestination
M.addMaterialAsParcelToContainer = parts.materials.addMaterialAsParcelToContainer
M.addPassiveBusinessSupplyCargo = parts.materials.addPassiveBusinessSupplyCargo
M.addEngineShopSupplyCargo = parts.materials.addEngineShopSupplyCargo
M.finalizeMaterialDistances = parts.materials.finalizeMaterialDistances
M.finalizeMaterialDistanceRewards = parts.materials.finalizeMaterialDistanceRewards
M.triggerGenerator = parts.materials.triggerGenerator
M.getDistanceBetweenFacilities = parts.routes.getDistanceBetweenFacilities
M.getLocationCoordinates = parts.routes.getLocationCoordinates
M.distanceBetween = parts.routes.distanceBetween

local function runGenerator(fac, generator, timeOffset)
  if gen.runningGenerationBatch then
    timeOffset = (timeOffset or 0) + gen.generationBatch.now - ext.general.time()
    generationClock = ext.general.time()
  end
  M.triggerGenerator(fac, generator, timeOffset)
  if gen.runningGenerationBatch then coroutine.yield() end
end
-- Background readers only need to know whether a pool has reached its cap.
local function getAvailableOfferCounts(caps)
  local counts = {parcel = 0, vehicle = 0, trailer = 0}
  local parcelCap = caps == nil and math.huge or caps and caps.parcel
  if parcelCap and ext.parcelManager then
    local now = ext.general.time()
    local parcels = 0
    ext.parcelManager.getAllCargoCustomFilter(function(item)
      if parcels < parcelCap and require('overhaul/lib/logistics/cargoSemantics').cargo(item.type).parcel
        and (item.offerExpiresAt or -math.huge) > now
        and isLocationAvailableOnCurrentMap(item.location) then
        parcels = parcels + 1
      end
      return false
    end)
    counts.parcel = parcels
  end
  local vehicles = caps == nil or caps.vehicle or caps.trailer
  if vehicles and ext.vehicleOfferManager then
    for _, offer in ipairs(ext.vehicleOfferManager.getAllOfferUnexpired() or {}) do
      local offerType = offer.data and offer.data.type
      if offerType == "vehicle" or offerType == "trailer" then
        counts[offerType] = counts[offerType] + 1
      end
    end
  end
  return counts
end

local function generatorMatchesOfferType(generator, offerType)
  return require('overhaul/lib/logistics/cargoSemantics').generatorMatches(offerType, generator)
end

-- Offer kinds in the order counting and backfill visit them (gameplay/overhaul/logistics/offerTypes.json).
local MIXABLE_TYPES = {
  parcel = true,
  fluid = false,
  dryBulk = false,
  cement = false,
  cash = false,
}

local OFFER_TYPES_PATH = "/gameplay/overhaul/logistics/offerTypes.json"
local offerTypesList
local function offerTypes()
  offerTypesList = offerTypesList or jsonReadFile(OFFER_TYPES_PATH).offerTypes
  return offerTypesList
end
-- Generators per offer type, recounted when the facility list or its generator count changes.
local function getMatchingGeneratorCounts()
  local total = 0
  for _, fac in ipairs(gen.facilities or {}) do total = total + #(fac.logisticGenerators or {}) end
  if gen.matchingCounts and gen.matchingFacilities == gen.facilities and gen.matchingTotal == total then return gen.matchingCounts end
  local counts = {parcel = 0, vehicle = 0, trailer = 0}
  for _, fac in ipairs(gen.facilities or {}) do
    for _, generator in ipairs(fac.logisticGenerators or {}) do
      for _, offerType in ipairs(offerTypes()) do
        if generatorMatchesOfferType(generator, offerType) then counts[offerType] = counts[offerType] + 1 end
      end
    end
  end
  gen.matchingCounts, gen.matchingFacilities, gen.matchingTotal = counts, gen.facilities, total
  return counts
end

local function minimumHealthyCountFor(matchingGenerators)
  return math.min(12, math.max(1, math.ceil(matchingGenerators / 4)))
end

-- Backfill each sparse pool independently after reload so existing vehicles do not hide missing trailers.
-- Background readers use capped counts; explicit board requests still receive the full counts.
local function ensureCurrentOffers(wantCounts)
  if gen.ensuringCurrentOffers then return {parcel = 0, vehicle = 0, trailer = 0} end
  local matching = getMatchingGeneratorCounts()
  local caps, needed = {}, false
  for _, offerType in ipairs(offerTypes()) do
    if matching[offerType] > 0 and not gen.offerBackfillAttempted[offerType] then
      caps[offerType] = minimumHealthyCountFor(matching[offerType])
      needed = true
    end
  end
  if not needed and not wantCounts then return end
  gen.ensuringCurrentOffers = true
  local ok, countsOrError = xpcall(function()
    local counts = getAvailableOfferCounts(not wantCounts and caps or nil)
    for _, offerType in ipairs(offerTypes()) do
      local matchingGenerators = matching[offerType]
      local minimumHealthyCount = minimumHealthyCountFor(matchingGenerators)
      if matchingGenerators > 0 and counts[offerType] < minimumHealthyCount and not gen.offerBackfillAttempted[offerType] then
        gen.offerBackfillAttempted[offerType] = true
        for _, fac in ipairs(gen.facilities or {}) do
          for _, generator in ipairs(fac.logisticGenerators or {}) do
            if generatorMatchesOfferType(generator, offerType) then
              runGenerator(fac, generator, 0)
            end
          end
        end
        counts = getAvailableOfferCounts()
        if matchingGenerators > 0 then
          log(counts[offerType] > 0 and "I" or "W", "delivery", string.format(
            "Startup %s offer backfill ran %d generators and produced %d available offers (minimum %d)",
            offerType, matchingGenerators, counts[offerType], minimumHealthyCount))
        end
      end
    end
    return counts
  end, debug.traceback)
  gen.ensuringCurrentOffers = false
  if not ok then error(countsOrError) end
  return countsOrError
end

local function generateDue(now)
  ensureCurrentOffers()
  local nextCheck = math.huge
  for _, fac in ipairs(gen.facilities or {}) do
    for _, generator in ipairs(fac.logisticGenerators) do
      local nextGenerationTimestamp = tonumber(generator.nextGenerationTimestamp) or now
      if nextGenerationTimestamp <= now then
        generator.nextGenerationTimestamp = now + generator.interval
        runGenerator(fac, generator)
      end
      nextCheck = math.min(nextCheck, tonumber(generator.nextGenerationTimestamp) or math.huge)
    end
  end
  gen.nextGeneratorCheckTimestamp = nextCheck
  gen.hasGeneratedThisFrame = true
end

local function resumeGenerationBatch(budget)
  local started, count = os.clock(), 0
  repeat
    gen.runningGenerationBatch = true
    local ok, err = coroutine.resume(gen.generationBatch.thread)
    gen.runningGenerationBatch = false
    if not ok then
      gen.generationBatch = nil
      error(err, 0)
    end
    if coroutine.status(gen.generationBatch.thread) == 'dead' then
      gen.generationBatch = nil
      return
    end
    count = count + 1
  until budget and (count >= 2 or os.clock() - started >= budget)
end

local function triggerAllGenerators()
  if generationSuppression > 0 or setupInProgress or gen.runningGenerationBatch then return end
  if gen.generationBatch then resumeGenerationBatch() end
  if gen.ensuringCurrentOffers then return end
  local now = ext.general.time()
  if gen.hasGeneratedThisFrame and now < gen.nextGeneratorCheckTimestamp then return end
  if now >= gen.nextGeneratorCheckTimestamp then generateDue(now) end
  gen.hasGeneratedThisFrame = true
end

M.updateBackgroundGeneration = function(request)
  if generationSuppression > 0 or setupInProgress or gen.runningGenerationBatch or not ext.general then return end
  if not gen.generationBatch and request and gen.facilities[1] and not gen.ensuringCurrentOffers then
    local now = ext.general.time()
    if now >= gen.nextGeneratorCheckTimestamp then
      gen.generationBatch = {now = now, thread = coroutine.create(function() generateDue(now) end)}
    end
  end
  if gen.generationBatch then resumeGenerationBatch(0.002) end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  gen.hasGeneratedThisFrame = false
end
M.onUpdate = onUpdate

M.isMixable = function(type) return MIXABLE_TYPES[type] end

parts.facilities = require('overhaul/career/logistics/generator/facilities').new({
  state = state,
  services = services,
  callbacks = {
    ensureCurrentOffers = ensureCurrentOffers,
    getDeliveryParcelTemplates = parts.offers.getDeliveryParcelTemplates,
    getDeliveryVehicleTemplates = parts.offers.getDeliveryVehicleTemplates,
    getMaterialsTemplates = parts.materials.getMaterialsTemplates,
    getMaterialsTemplatesById = getMaterialsTemplatesById,
    getParcelTemplateById = parts.offers.getParcelTemplateById,
    getVehicleFilterByIdSafe = parts.offers.getVehicleFilterByIdSafe,
    isLoadedParcelAvailableOnCurrentMap = parts.offers.isLoadedParcelAvailableOnCurrentMap,
    isLoadedVehicleOfferAvailableOnCurrentMap = parts.offers.isLoadedVehicleOfferAvailableOnCurrentMap,
    listContains = listContains,
    setupMaterialStorage = parts.materials.setupMaterialStorage,
    triggerGenerator = parts.materials.triggerGenerator,
    upgradeLoadedParcelIfNeeded = parts.offers.upgradeLoadedParcelIfNeeded,
  },
})

M.normalizeLegacyMaterialGenerators = parts.facilities.normalizeLegacyMaterialGenerators

M.setup = function(loadData)
  if setupInProgress then return end
  setupInProgress = true
  local ok, result = xpcall(function() return parts.facilities.setup(loadData) end, debug.traceback)
  setupInProgress = false
  if not ok then error(result) end
  return result
end
M.allocateCargoId = function() gen.cargoId=gen.cargoId+1;return gen.cargoId end
M.allocateCargoGroupId = function() gen.groupId=gen.groupId+1;return gen.groupId end

-- Public API -------------------------------------------------------------------------------------

local function ensureCurrentMapFacilities()
  local general = overhaul_career_logistics_general
  if general and general.ensureSetupForCurrentMap then
    general.ensureSetupForCurrentMap()
  end
end

M.getFacilities = function()
  ensureCurrentMapFacilities()
  return gen.facilities
end
M.hasFacilities = function() return gen.facilities[1] ~= nil end
M.getSetupLevelIdentifier = function() return gen.setupLevelIdentifier end
M.getFacilityById = getFacilityById
M.getParkingSpotByPath = getParkingSpotByPath
M.getFacilitiesForOrganizationId = function(orgId)
  ensureCurrentMapFacilities()
  local ret = {}
  for _, fac in ipairs(gen.facilities) do
    if fac.associatedOrganization == orgId then
      table.insert(ret, {name = fac.name, id = fac.id})
    end
  end
  return ret
end
-- Career lifecycle ------------------------------------------------------------------------------
M.onCareerActivated = function()
  sharedTemplates.reset()
  ext.parcelManager = overhaul_career_logistics_parcelManager
  ext.cargoScreen = overhaul_career_logistics_cargoScreen
  ext.general = overhaul_career_logistics_general
  ext.generator = overhaul_career_logistics_generator
  ext.progress = overhaul_career_logistics_progress
  ext.vehicleOfferManager = overhaul_career_logistics_vehicleOfferManager
  ext.parcelMods = overhaul_career_logistics_parcelMods
  ext.vehicleTasks = overhaul_career_logistics_vehicleTasks
  ext.materialContracts = overhaul_career_logistics_materialContractManager
  ext.step = util_stepHandler
end

M.onExtensionUnloaded = function() require('overhaul/career/logistics/generator/routeCache').save(gen.routes) end
M.onNavgraphReloaded = function() gen.routes = {graph = nil}; gen.distanceCache = {} end
M.triggerAllGenerators = function()
  if generationSuppression > 0 or gen.runningGenerationBatch then return end
  ensureCurrentMapFacilities()
  return triggerAllGenerators()
end
M.getAvailableOfferCounts = getAvailableOfferCounts

-- Freight opportunities advertise independent work only when a company shift is inactive.
-- Providers are resolved for each query so a career reload cannot retain the previous owners.
function M.canNotifyMarketOpportunity()
  local shiftState = capabilities.get('marketShiftState')
  if not shiftState or shiftState.isOnShift() then return false end
  local freightAccess = capabilities.get('marketFreightAccess')
  return freightAccess ~= nil and freightAccess.isOwnerOpUnlocked() == true
end

-- Accepted work keeps its price stamp while open offers follow current demand.
local function cargoEconomySection(cargo)
  if cargo.materialType then
    local mat = M.getMaterialsTemplatesById(cargo.materialType)
    local matType = mat and mat.type
    return require('overhaul/lib/logistics/cargoSemantics').material(matType).economyKey
  end
  return "delivery_parcel"
end

local function rebakeOpenOffersEconomy(multByType)
  multByType = multByType or {}
  local function multFor(section)
    if multByType[section] ~= nil then return tonumber(multByType[section]) or 1 end
    return overhaul_career_economyAdjuster.getSectionMultiplier(section) or 1
  end

  local changed = 0

  if ext.vehicleOfferManager then
    local boardOffers = (ext.vehicleOfferManager.getOpenBoardOffers())
      or (ext.vehicleOfferManager.getAllOfferUnexpired())
      or {}
    for _, offer in ipairs(boardOffers) do
      if offer.rewards and not offer.spawned then
        local section = (offer.data and offer.data.type == "trailer") and "delivery_trailer" or "delivery_vehicle"
        if sharedCalc.rebakeRewardEconomy(offer.rewards, multFor(section)) then
          changed = changed + 1
        end
      end
    end
  end

  if ext.parcelManager and ext.general then
    local now = ext.general.time()
    local list = M.withoutGeneration(ext.parcelManager.getAllCargoCustomFilter, function(cargo)
      if not cargo or type(cargo.rewards) ~= "table" then return false end
      if not cargo.location or cargo.location.type ~= "facilityParkingspot" then return false end
      if cargo.offerExpiresAt and cargo.offerExpiresAt <= now then return false end
      if cargo._transientMove then return false end
      if cargo.data and cargo.data.materialContractId then return false end
      return true
    end)
    for _, cargo in ipairs(list or {}) do
      if sharedCalc.rebakeRewardEconomy(cargo.rewards, multFor(cargoEconomySection(cargo))) then
        changed = changed + 1
      end
    end
  end

  return changed
end
M.rebakeOpenOffersEconomy = rebakeOpenOffersEconomy

local function rebakeChangedEconomyLeaves(changedLeafIds)
  if type(changedLeafIds) ~= 'table' or #changedLeafIds == 0 then return end
  gen.economyLeafPolicies = gen.economyLeafPolicies or require('overhaul/lib/career/activityTaxonomy').load().byId
  for _, id in ipairs(changedLeafIds) do
    local policy = gen.economyLeafPolicies[id]
    if policy and policy.refreshOffers then return M.rebakeOpenOffersEconomy() end
  end
end

-- One refresh reads every open offer's multiplier again, even when several relevant leaves changed.
M.onOverhaulEconomyLeavesChanged = function(changedLeafIds)
  local ok, err = pcall(rebakeChangedEconomyLeaves, changedLeafIds)
  if not ok then log("E", "delivery", "rebakeOpenOffersEconomy failed: " .. tostring(err)) end
end

return M
