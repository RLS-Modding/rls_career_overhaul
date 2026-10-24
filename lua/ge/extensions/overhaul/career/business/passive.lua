-- Passive businesses (stores that earn while owned): ownership, production, finance history, supplier orders and selling.
-- Read config, state, save records, dashboards, management, supply pickup, balance refund, production, the public API, then game hooks.
local M = {}

local saveState = require("overhaul/lib/business/saveState")
local levelData = require("overhaul/lib/world/levelData")
local invariants = require("overhaul/career/business/passive/invariants")

-- Config ------------------------------------------------------------------------------------------

local SAVE_VERSION = 2
local PALLET_SLOTS = 128
local UPDATE_STEP_SECONDS = 0.5
local HISTORY_LIMIT = 60
local TOTAL_KEYS = {"collected", "supplies", "upgrades", "palletsSold", "salesRevenue"}

-- Prices before the balance pass; a store bought under them is refunded the difference.
local LEGACY_BALANCE = {
  miniMart = {storageUpgradeCosts = {8000, 12000, 18000, 26000}, wholesaleUpgradeCost = 18000},
  cafe = {storageUpgradeCosts = {9000, 14000, 21000, 30000}, wholesaleUpgradeCost = 22000},
  boutique = {storageUpgradeCosts = {14000, 22000, 34000, 50000}, wholesaleUpgradeCost = 35000},
  supermarket = {storageUpgradeCosts = {26000, 42000, 68000, 100000}, wholesaleUpgradeCost = 75000},
  nailSalon = {storageUpgradeCosts = {11000, 17000, 25000, 36000}, wholesaleUpgradeCost = 22000},
  giftShop = {storageUpgradeCosts = {10000, 16000, 24000, 34000}, wholesaleUpgradeCost = 28000},
  jewelryStore = {storageUpgradeCosts = {35000, 60000, 95000, 140000}, wholesaleUpgradeCost = 120000},
  dryCleaner = {storageUpgradeCosts = {10000, 16000, 24000, 34000}, wholesaleUpgradeCost = 18000},
  specialtyRetail = {storageUpgradeCosts = {18000, 28000, 42000, 62000}, wholesaleUpgradeCost = 48000},
}

-- State -------------------------------------------------------------------------------------------

local archetypes = {}
local properties = {}
local reservations = {}
local nextReservationId = 1
local saveVersion = SAVE_VERSION
local dataLoaded = false
local refundPaidThisLoad = false
local refundPaidForSavePath = nil
local activeBusinessId = nil
local updateAccumulator = 0

-- The supply pickup screen is open only while the player is parked at a supplier.
local pickup = {open = false, facId = nil, psPath = nil, loading = false}

local function resetPickup()
  pickup.open = false
  pickup.facId, pickup.psPath = nil, nil
  pickup.loading = false
end

-- Shared helpers ----------------------------------------------------------------------------------

local function indexed(baseValue)
  local index = overhaul_career_economy_globalEconomy and overhaul_career_economy_globalEconomy.getGlobalIndex() or 1
  return math.floor((tonumber(baseValue) or 0) * index + 0.0001)
end

local function notify(kind, title, message)
  guihooks.trigger("toastrMsg", {type = kind, title = title, msg = message})
end

local function loadArchetypes()
  archetypes = jsonReadFile("gameplay/overhaul/business/passiveBusinessArchetypes.json") or {}
end

local function owned(id)
  return overhaul_career_business_manager
    and overhaul_career_business_manager.isPurchasedBusiness("passiveBusiness", id) == true
end

local function getArchetype(stateOrId)
  local state = type(stateOrId) == "table" and stateOrId or properties[tostring(stateOrId)]
  return state and archetypes[state.archetypeId] or nil
end

-- A false supply type explicitly opts an ownership-only archetype out of retail.
local function supplyEnabled(state)
  local archetype = getArchetype(state)
  return archetype and archetype.supplyType ~= false
end

local function supplyName(stateOrId)
  local archetype = getArchetype(stateOrId)
  return archetype and archetype.supplyName or "Business Supplies"
end

local function getCapacity(state)
  local archetype = getArchetype(state)
  if not archetype or archetype.supplyType == false then return 0 end
  return tonumber(archetype.storageCapacities[state.storageLevel]) or 0
end

local function currentFacility(id)
  return overhaul_world_facilities.getFacilityIfExists
    and overhaul_world_facilities.getFacilityIfExists("passiveBusiness", id)
    or nil
end

local function businessName(stateOrId)
  local state = type(stateOrId) == "table" and stateOrId or properties[tostring(stateOrId)]
  local facility = state and currentFacility(state.id) or nil
  local archetype = getArchetype(state)
  return (facility and facility.name) or (archetype and archetype.name) or "Business"
end

-- Finance history ---------------------------------------------------------------------------------
-- Money events become history rows and lifetime totals on the property state.

local function financeTotals(state)
  local totals = type(state.financeTotals) == "table" and state.financeTotals or {}
  for _, key in ipairs(TOTAL_KEYS) do
    totals[key] = math.max(0, math.floor(tonumber(totals[key]) or 0))
  end
  state.financeTotals = totals
  return totals
end

local function addToTotals(totals, kind, amount)
  if kind == "collect" then
    totals.collected = totals.collected + amount
  elseif kind == "order" then
    totals.supplies = totals.supplies + amount
  elseif kind == "storage" or kind == "wholesale" then
    totals.upgrades = totals.upgrades + amount
  end
end

local function recordFinance(state, kind, amount, quantity)
  if not state then return end
  amount = math.max(0, math.floor(tonumber(amount) or 0))
  state.financeHistory = type(state.financeHistory) == "table" and state.financeHistory or {}
  table.insert(state.financeHistory, {t = os.time(), kind = kind, amount = amount, qty = quantity})
  while #state.financeHistory > HISTORY_LIMIT do table.remove(state.financeHistory, 1) end
  addToTotals(financeTotals(state), kind, amount)
end

-- Stores bought before finance history existed get a one-time backfill from the money log, where their labels
-- name them. Shared supply labels cannot identify one store's orders, so those count only for a lone archetype.
local function ensureFinanceBackfill(state)
  if not state or state.financeBackfilled then return end
  local sharesSupply = 0
  for _, other in pairs(properties) do
    if other.archetypeId == state.archetypeId then sharesSupply = sharesSupply + 1 end
  end
  local orderLabel = nil
  if sharesSupply <= 1 then orderLabel = supplyName(state) end
  local name = businessName(state)
  state.financeBackfilled = true
  local log = overhaul_career_economy_playerAttributes.getAttributeLog()
  if type(log) ~= "table" then return end
  local labels = {
    ["Collected " .. name .. " earnings"] = "collect",
    [name .. " storage upgrade"] = "storage",
    [name .. " wholesale agreement"] = "wholesale",
  }
  if orderLabel then labels["Ordered " .. orderLabel] = "order" end
  local found = {}
  for _, change in ipairs(log) do
    local reason = type(change) == "table" and change.reason or nil
    local kind = reason and labels[reason.label]
    local money = kind and change.attributeChange and tonumber(change.attributeChange.money)
    if money then
      found[#found + 1] = {t = tonumber(change.time) or 0, kind = kind, amount = math.floor(math.abs(money) + 0.5), backfilled = true}
    end
  end
  if #found == 0 then return end
  local totals = financeTotals(state)
  for _, row in ipairs(found) do addToTotals(totals, row.kind, row.amount) end
  -- backfilled rows go before anything recorded live, keeping the newest HISTORY_LIMIT
  local merged = {}
  for _, row in ipairs(found) do merged[#merged + 1] = row end
  for _, row in ipairs(state.financeHistory or {}) do merged[#merged + 1] = row end
  while #merged > HISTORY_LIMIT do table.remove(merged, 1) end
  state.financeHistory = merged
end

-- Saved records ----------------------------------------------------------------------------------

local function restoreLocation(record, id, fileVersion, property)
  local facility = currentFacility(id)
  record.mapId = record.mapId or (property and property.mapId) or (facility and (facility.mapId or getCurrentLevelIdentifier()))
  if not record.mapId then
    local mapId, alias = levelData.resolveAlias("passiveOwnerMap", tostring(id), {facilityId = tostring(id), saveVersion = fileVersion})
    if alias then record.mapId = mapId end
  end
  if record.mapId then record.mapId = levelData.resolveAlias("map", record.mapId) end
  for _, role in ipairs({"supplier", "receiving"}) do
    local facilityKey, parkingKey = role .. "FacilityId", role .. "ParkingSpotName"
    local scope = {levelId = record.mapId, facilityId = record[facilityKey], saveVersion = fileVersion}
    if record[parkingKey] then record[parkingKey] = levelData.resolveAlias("passiveParkingSpot", record[parkingKey], scope) end
  end
  if not record.mapId then log("W", "passiveBusiness", "Saved location unavailable for " .. tostring(id)) end
end

local function normalizeState(id, state, fileVersion)
  state = type(state) == "table" and state or {}
  state.id = tostring(id)
  local facility = currentFacility(id)
  state.archetypeId = (facility and facility.archetypeId) or state.archetypeId or "miniMart"
  restoreLocation(state, id, fileVersion)
  state.stock = math.max(0, math.floor(tonumber(state.stock) or 0))
  state.storageLevel = math.max(1, math.floor(tonumber(state.storageLevel) or 1))
  state.cycleProgress = math.max(0, tonumber(state.cycleProgress) or 0)
  state.uncollectedEarnings = math.max(0, math.floor(tonumber(state.uncollectedEarnings) or 0))
  state.wholesaleOwned = state.wholesaleOwned == true
  state.operating = state.operating ~= false
  if state.outOfStockNotified == nil then state.outOfStockNotified = true end
  return state
end

-- Refund for storage and wholesale upgrades bought under the legacy prices, at today's prices.
local function balanceRefundForState(state)
  local old = state and LEGACY_BALANCE[state.archetypeId]
  local current = state and archetypes[state.archetypeId]
  if not old or not current then return 0 end
  local refund = 0
  local purchasedStorageLevels = math.max(0, math.min(#old.storageUpgradeCosts, (tonumber(state.storageLevel) or 1) - 1))
  for level = 1, purchasedStorageLevels do
    refund = refund + math.max(0, indexed(old.storageUpgradeCosts[level]) - indexed(current.storageUpgradeCosts[level]))
  end
  if state.wholesaleOwned then
    refund = refund + math.max(0, indexed(old.wholesaleUpgradeCost) - indexed(current.wholesaleUpgradeCost))
  end
  return math.floor(refund + 0.5)
end

-- Restore in-transit orders to supplier-ready because their live cargo does not survive a reload.
local function migrateReservation(reservation, id, loadedProperties, fileVersion)
  reservation.id = tostring(reservation.id or id)
  local property = loadedProperties[tostring(reservation.orderedByPropertyId)]
  restoreLocation(reservation, reservation.orderedByPropertyId, fileVersion, property)
  local archetype = archetypes[reservation.archetypeId]
  if archetype then
    reservation.supplyType = reservation.supplyType or archetype.supplyType
    reservation.supplyName = reservation.supplyName or archetype.supplyName
    reservation.supplyTemplateId = reservation.supplyTemplateId or archetype.supplyTemplateId
    reservation.supplySlots = reservation.supplySlots or archetype.supplySlots
  end
  reservation.status = "available"
  reservation.cargoId = nil
end

local function loadData()
  properties, reservations, nextReservationId = {}, {}, 1
  local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
  if not currentSavePath then return 0 end
  dataLoaded = true
  local data = jsonReadFile(saveState.featureFilePath(currentSavePath, "passiveBusinesses.json")) or {}
  local fileVersion = math.max(1, math.floor(tonumber(data.version) or 1))
  for id, state in pairs(data.properties or {}) do
    properties[tostring(id)] = normalizeState(id, state, fileVersion)
  end
  for id, reservation in pairs(data.reservations or {}) do
    if type(reservation) == "table" then
      migrateReservation(reservation, id, properties, fileVersion)
      reservations[reservation.id] = reservation
    end
  end
  nextReservationId = math.max(1, math.floor(tonumber(data.nextReservationId) or 1))
  saveVersion = math.min(fileVersion, SAVE_VERSION)
  local refund = 0
  if fileVersion < SAVE_VERSION then
    for _, state in pairs(properties) do refund = refund + balanceRefundForState(state) end
  end
  return refund
end

local function ensureProperty(id)
  id = tostring(id)
  local facility = currentFacility(id)
  if properties[id] then
    properties[id].archetypeId = (facility and facility.archetypeId) or properties[id].archetypeId
    return properties[id]
  end
  properties[id] = normalizeState(id, {
    archetypeId = facility and facility.archetypeId or "miniMart",
    mapId = facility and facility.mapId or (getCurrentLevelIdentifier()) or nil,
    supplierFacilityId = facility and facility.supplierFacilityId,
    supplierParkingSpotName = facility and facility.supplierParkingSpotName,
    receivingFacilityId = facility and facility.receivingFacilityId,
    receivingParkingSpotName = facility and facility.receivingParkingSpotName,
    outOfStockNotified = true,
  }, SAVE_VERSION)
  return properties[id]
end

-- Property queries --------------------------------------------------------------------------------

local function isCurrentMap(record)
  return record and record.mapId == (getCurrentLevelIdentifier())
end

local function getOwnedStates(archetypeId, allMaps)
  local result = {}
  for id, state in pairs(properties) do
    if owned(id) and (allMaps or isCurrentMap(state)) and (not archetypeId or state.archetypeId == archetypeId) then
      result[#result + 1] = state
    end
  end
  return result
end

local function reservationCount(archetypeId, status)
  local count = 0
  for _, reservation in pairs(reservations) do
    if isCurrentMap(reservation) and (not archetypeId or reservation.archetypeId == archetypeId) and (not status or reservation.status == status) then
      count = count + 1
    end
  end
  return count
end

local function chainTotals(archetypeId)
  local capacity, stored = 0, 0
  for _, state in ipairs(getOwnedStates(archetypeId)) do
    if supplyEnabled(state) then
      capacity = capacity + getCapacity(state)
      stored = stored + state.stock
    end
  end
  local reserved = reservationCount(archetypeId)
  return capacity, stored, reserved
end

local function hasWholesale(archetypeId)
  for _, state in ipairs(getOwnedStates(archetypeId)) do
    if state.wholesaleOwned then return true end
  end
  return false
end

local function unitCost(archetypeId)
  local archetype = archetypes[archetypeId]
  if not archetype then return 0 end
  return indexed(hasWholesale(archetypeId) and archetype.wholesaleUnitCost or archetype.unitCost)
end

local function getSourceLocation(state)
  if not isCurrentMap(state) or not supplyEnabled(state) then return nil end
  local generator = overhaul_career_logistics_generator
  local facility = generator and generator.getFacilityById(state.supplierFacilityId)
  local accessPoint = facility and facility.accessPointsByName and facility.accessPointsByName[state.supplierParkingSpotName]
  return accessPoint and {type = "facilityParkingspot", facId = facility.id, psPath = accessPoint.psPath} or nil
end

-- Where an owned store's supplies are delivered.
local function receivingLocation(state)
  local generator = overhaul_career_logistics_generator
  local facility = generator and state.receivingFacilityId and generator.getFacilityById(state.receivingFacilityId)
  local accessPoint = facility and facility.accessPointsByName and facility.accessPointsByName[state.receivingParkingSpotName]
  return accessPoint and {type = "facilityParkingspot", facId = facility.id, psPath = accessPoint.psPath} or nil
end

local function getDestinationLocations(archetypeId)
  local result = {}
  if not overhaul_career_logistics_generator then return result end
  for _, state in ipairs(getOwnedStates(archetypeId)) do
    local destination = receivingLocation(state)
    if destination then result[#result + 1] = destination end
  end
  return result
end

local function getReservationForCargo(cargo)
  local id = cargo and cargo.data and cargo.data.passiveBusinessSupplyReservationId
  return id and reservations[tostring(id)] or nil
end

-- Kept self-contained: the route-map test extracts this function's source into its own environment.
local function getSupplyRouteDestination(cargo)
  local reservation = getReservationForCargo(cargo)
  local propertyId = reservation and reservation.orderedByPropertyId
  local state = propertyId and properties[tostring(propertyId)]
  local generator = overhaul_career_logistics_generator
  if not isCurrentMap(state) or not isCurrentMap(reservation) or not owned(state.id) or state.archetypeId ~= reservation.archetypeId or not generator then return nil end
  local facility = generator and state.receivingFacilityId and generator.getFacilityById(state.receivingFacilityId)
  local accessPoint = facility and facility.accessPointsByName and facility.accessPointsByName[state.receivingParkingSpotName]
  return accessPoint and {type = "facilityParkingspot", facId = facility.id, psPath = accessPoint.psPath} or nil
end

local function returnCargoToSupplier(cargo, forfeited)
  local reservation = getReservationForCargo(cargo)
  if not reservation then return false end
  if forfeited then
    reservations[reservation.id] = nil
  else
    reservation.status = "available"
    reservation.cargoId = nil
  end
  if cargo and cargo.id and overhaul_career_logistics_parcelManager then
    overhaul_career_logistics_parcelManager.changeCargoLocation(cargo.id, {type = "deleted"})
  end
  return true
end

local function returnAllCargoToSuppliers()
  if not overhaul_career_logistics_parcelManager then return end
  local cargoList = overhaul_career_logistics_parcelManager.getAllCargoCustomFilter(function(cargo)
    return cargo.data and cargo.data.passiveBusinessSupplyReservationId ~= nil
  end) or {}
  for _, cargo in ipairs(cargoList) do returnCargoToSupplier(cargo, false) end
  if overhaul_career_logistics_general then
    overhaul_career_logistics_general.requestUpdateContainerWeights()
  end
end

local function propertyForLocation(location, archetypeId)
  if not location then return nil end
  for _, state in ipairs(getOwnedStates(archetypeId)) do
    if state.receivingFacilityId == location.facId then
      return state
    end
  end
  return nil
end

local function canDeliverSupplyCargo(cargo, location)
  local reservation = getReservationForCargo(cargo)
  if not isCurrentMap(reservation) then return false end
  local state = propertyForLocation(location, reservation.archetypeId)
  return state ~= nil and state.stock < getCapacity(state)
end

local function deliverSupplyCargo(cargo, location)
  local reservation = getReservationForCargo(cargo)
  if not isCurrentMap(reservation) then return false end
  local state = propertyForLocation(location, reservation.archetypeId)
  if not state or state.stock >= getCapacity(state) then return false end
  state.stock = state.stock + 1
  state.outOfStockNotified = false
  reservations[reservation.id] = nil
  return true
end

local function ensureTabsRegistered()
  if not overhaul_career_business_tabRegistry then return end
  if #overhaul_career_business_tabRegistry.getTabs("passiveBusiness") > 0 then return end
  overhaul_career_business_tabRegistry.registerTab("passiveBusiness", {
    id = "dashboard",
    label = "Dashboard",
    icon = '<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M8 17v-5M12 17V7M16 17v-8"/>',
    component = "PassiveBusinessDashboard",
    section = "BUSINESS",
    order = 1,
  })
end

local function supplierFacilityInfo(facId)
  local generator = overhaul_career_logistics_generator
  local facility = generator and generator.getFacilityById and facId and generator.getFacilityById(facId)
  return facility and facility.name or "Business supplier", facility and facility.preview or nil
end

-- Dashboard ---------------------------------------------------------------------------------------

local function dashboardMetrics(state, archetype)
  local capacity = getCapacity(state)
  local nextCost = archetype.storageUpgradeCosts[state.storageLevel]
  local nextCapacity = archetype.storageCapacities[state.storageLevel + 1]
  local chainCapacity, chainStored, chainReserved = chainTotals(state.archetypeId)
  local chainFree = math.max(0, chainCapacity - chainStored - chainReserved)
  local price = unitCost(state.archetypeId)
  local revenue = indexed(archetype.unitRevenue)
  local baseCost = indexed(archetype.unitCost)
  local wholesaleCost = indexed(archetype.wholesaleUnitCost)
  local currentProfit = math.max(0, revenue - price)
  local baseProfitPerHour = archetype.cycleSeconds > 0 and math.floor((revenue - baseCost) * 3600 / archetype.cycleSeconds + 0.5) or 0
  local wholesaleProfitPerHour = archetype.cycleSeconds > 0 and math.floor((revenue - wholesaleCost) * 3600 / archetype.cycleSeconds + 0.5) or 0
  local wholesaleImprovementPerHour = math.max(0, wholesaleProfitPerHour - baseProfitPerHour)
  local wholesaleUpgradeCost = indexed(archetype.wholesaleUpgradeCost)
  local money = overhaul_career_economy_playerAttributes.getAttributeValue("money") or 0
  local affordable = price > 0 and math.floor(money / price) or 0
  -- An owned wholesale upgrade has no purchase cost left to show.
  local wholesaleUpgradeCostShown
  if state.wholesaleOwned then
    wholesaleUpgradeCostShown = nil
  else
    wholesaleUpgradeCostShown = wholesaleUpgradeCost
  end
  return {
    capacity = capacity,
    nextCost = nextCost,
    nextCapacity = nextCapacity,
    chainCapacity = chainCapacity,
    chainStored = chainStored,
    chainReserved = chainReserved,
    chainFree = chainFree,
    price = price,
    revenue = revenue,
    baseCost = baseCost,
    wholesaleCost = wholesaleCost,
    currentProfit = currentProfit,
    baseProfitPerHour = baseProfitPerHour,
    wholesaleProfitPerHour = wholesaleProfitPerHour,
    wholesaleImprovementPerHour = wholesaleImprovementPerHour,
    wholesaleUpgradeCost = wholesaleUpgradeCost,
    wholesaleUpgradeCostShown = wholesaleUpgradeCostShown,
    affordable = affordable,
  }
end

local function dashboardView(id, state, archetype, metrics)
  return {
    success = true,
    businessId = id,
    businessName = (currentFacility(id) and currentFacility(id).name) or archetype.name,
    supplierName = supplierFacilityInfo(state.supplierFacilityId),
    supplyName = archetype.supplyName,
    supplyType = archetype.supplyType,
    supplySlots = archetype.supplySlots,
    stock = state.stock,
    capacity = metrics.capacity,
    operating = state.operating,
    storageLevel = state.storageLevel,
    maxStorageLevel = #archetype.storageCapacities,
    remainingRuntimeSeconds = state.stock > 0
      and ((state.stock - 1) * archetype.cycleSeconds + (archetype.cycleSeconds - state.cycleProgress)) or 0,
    cycleSeconds = archetype.cycleSeconds,
    cycleProgress = state.cycleProgress,
    cycleRemainingSeconds = state.stock > 0 and math.max(0, archetype.cycleSeconds - state.cycleProgress) or 0,
    uncollectedEarnings = state.uncollectedEarnings,
    unitRevenue = metrics.revenue,
    unitCost = unitCost(state.archetypeId),
    netProfitPerPallet = metrics.currentProfit,
    netProfitPerHour = archetype.cycleSeconds > 0 and math.floor(metrics.currentProfit * 3600 / archetype.cycleSeconds + 0.5) or 0,
    baseNetProfitPerHour = metrics.baseProfitPerHour,
    wholesaleNetProfitPerHour = metrics.wholesaleProfitPerHour,
    wholesaleImprovementPerHour = metrics.wholesaleImprovementPerHour,
    wholesalePaybackSeconds = metrics.wholesaleImprovementPerHour > 0
      and math.floor(metrics.wholesaleUpgradeCost / metrics.wholesaleImprovementPerHour * 3600 + 0.5) or 0,
    nextStorageCapacity = metrics.nextCapacity,
    nextStorageRuntimeAddedSeconds = metrics.nextCapacity and math.max(0, metrics.nextCapacity - metrics.capacity) * archetype.cycleSeconds or 0,
    nextStorageUpgradeCost = metrics.nextCost and indexed(metrics.nextCost) or nil,
    wholesaleOwned = state.wholesaleOwned,
    wholesaleUpgradeCost = metrics.wholesaleUpgradeCostShown,
    baseUnitCost = metrics.baseCost,
    wholesaleUnitCost = metrics.wholesaleCost,
    chainCapacity = metrics.chainCapacity,
    chainStored = metrics.chainStored,
    chainReserved = metrics.chainReserved,
    chainFree = metrics.chainFree,
    paidAtSupplier = reservationCount(state.archetypeId, "available"),
    inTransit = reservationCount(state.archetypeId, "inTransit"),
    affordableQuantity = metrics.affordable,
    maximumOrder = math.min(metrics.chainFree, metrics.affordable),
  }
end

local function getDashboardData(id)
  id = tostring(id)
  if not owned(id) then return {success = false, message = "This property is not owned."} end
  local state = ensureProperty(id)
  if not isCurrentMap(state) then return {success = false, message = "Visit this property's map to manage it."} end
  local archetype = getArchetype(state)
  if not archetype then return {success = false, message = "Passive business archetype is missing."} end
  if archetype.supplyType == false then
    return {success = true, businessId = id, businessName = businessName(state), supplyEnabled = false,
      sectionIds = {"dashboard"},
      description = (currentFacility(id) or {}).description or archetype.name,
      uncollectedEarnings = state.uncollectedEarnings}
  end
  return dashboardView(id, state, archetype, dashboardMetrics(state, archetype))
end

-- History newest first plus lifetime totals for the Finances section.
local function getFinanceData(id)
  id = tostring(id)
  if not owned(id) then return {success = false, message = "This property is not owned."} end
  local state = ensureProperty(id)
  ensureFinanceBackfill(state)
  local totals = financeTotals(state)
  local history, since = {}, nil
  local rows = state.financeHistory or {}
  for i = #rows, 1, -1 do
    local row = rows[i]
    history[#history + 1] = {
      time = row.t,
      kind = row.kind,
      amount = row.amount,
      quantity = row.qty,
      income = row.kind == "collect",
    }
    if row.t and row.t > 0 and (not since or row.t < since) then since = row.t end
  end
  return {
    success = true,
    history = history,
    since = since,
    now = os.time(),
    totals = {
      collected = totals.collected,
      supplies = totals.supplies,
      upgrades = totals.upgrades,
      net = totals.collected - totals.supplies - totals.upgrades,
      palletsSold = totals.palletsSold,
      salesRevenue = totals.salesRevenue,
    },
  }
end

local function getUIData(id)
  ensureTabsRegistered()
  local dashboard = getDashboardData(id)
  dashboard.businessId = tostring(id)
  dashboard.businessType = "passiveBusiness"
  dashboard.businessName = dashboard.businessName or "Business"
  dashboard.tabs = overhaul_career_business_tabRegistry.getTabs("passiveBusiness")
  dashboard.showBusinessAccount = false
  dashboard.playerInZone = currentFacility(id) ~= nil
  return dashboard
end

local function openMenu(id)
  id = tostring(id)
  activeBusinessId = id
  ensureProperty(id)
  ensureTabsRegistered()
  extensions.ui_router.navigate("business-computer", {businessType = "passiveBusiness", businessId = id})
end

local function closeManagementSession(id)
  if id == nil or activeBusinessId == tostring(id) then activeBusinessId = nil end
  return true
end

-- Management actions ------------------------------------------------------------------------------

local function requirePhysicalManagement(id)
  id = tostring(id)
  return activeBusinessId == id and currentFacility(id) ~= nil and owned(id) and isCurrentMap(properties[id])
end

local function collectEarnings(id)
  id = tostring(id)
  if not requirePhysicalManagement(id) then return {success = false, message = "Visit this property to collect earnings."} end
  local state = ensureProperty(id)
  local amount = state.uncollectedEarnings
  if amount <= 0 then return {success = false, message = "There are no earnings to collect."} end
  ensureFinanceBackfill(state)
  state.uncollectedEarnings = 0
  overhaul_career_economy_payment.reward({money = {amount = amount}}, require("overhaul/lib/finance/metadata").tag({category = "business", label = "Collected " .. businessName(state) .. " earnings"}, "business", {locationId = id, locationName = businessName(state), vehicleRelated = false}), true)
  recordFinance(state, "collect", amount)
  overhaul_career_saveSystem.saveCurrent()
  return {success = true, amount = amount, dashboard = getDashboardData(id)}
end

local function setOperating(id, operating)
  id = tostring(id)
  if not requirePhysicalManagement(id) then return {success = false, message = "Visit this property to change store operations."} end
  local state = ensureProperty(id)
  if not supplyEnabled(state) then return {success = false, message = "This property has no retail operations."} end
  state.operating = operating == true
  overhaul_career_saveSystem.saveCurrent()
  return {
    success = true,
    message = state.operating and "The business is open and processing stock." or "The business is closed. Stock processing is paused.",
    dashboard = getDashboardData(id),
  }
end

local function purchaseStorageUpgrade(id)
  id = tostring(id)
  if not requirePhysicalManagement(id) then return {success = false, message = "Visit this property to purchase upgrades."} end
  local state = ensureProperty(id)
  if not supplyEnabled(state) then return {success = false, message = "This property has no supply storage."} end
  local archetype = getArchetype(state)
  local baseCost = archetype and archetype.storageUpgradeCosts[state.storageLevel]
  if not baseCost then return {success = false, message = "Storage is already at its maximum."} end
  local cost = indexed(baseCost)
  ensureFinanceBackfill(state)
  if not overhaul_career_economy_payment.pay({money = {amount = cost, canBeNegative = false}}, require("overhaul/lib/finance/metadata").tag({category = "purchase", label = businessName(state) .. " storage upgrade"}, "purchase", {locationId = id, locationName = businessName(state), vehicleRelated = false})) then
    return {success = false, message = "You cannot afford this storage upgrade."}
  end
  recordFinance(state, "storage", cost)
  state.storageLevel = state.storageLevel + 1
  overhaul_career_saveSystem.saveCurrent()
  return {success = true, dashboard = getDashboardData(id)}
end

local function purchaseWholesale(id)
  id = tostring(id)
  if not requirePhysicalManagement(id) then return {success = false, message = "Visit this property to purchase upgrades."} end
  local state = ensureProperty(id)
  if not supplyEnabled(state) then return {success = false, message = "This property has no supply orders."} end
  if state.wholesaleOwned then return {success = false, message = "Wholesale purchasing is already unlocked."} end
  local archetype = getArchetype(state)
  if not archetype then return {success = false, message = "Passive business archetype is missing."} end
  local cost = indexed(archetype.wholesaleUpgradeCost)
  ensureFinanceBackfill(state)
  if not overhaul_career_economy_payment.pay({money = {amount = cost, canBeNegative = false}}, require("overhaul/lib/finance/metadata").tag({category = "purchase", label = businessName(state) .. " wholesale agreement"}, "purchase", {locationId = id, locationName = businessName(state), vehicleRelated = false})) then
    return {success = false, message = "You cannot afford the wholesale agreement."}
  end
  recordFinance(state, "wholesale", cost)
  state.wholesaleOwned = true
  overhaul_career_saveSystem.saveCurrent()
  return {success = true, dashboard = getDashboardData(id)}
end

local function requestSaleQuote(id)
  id = tostring(id)
  if not requirePhysicalManagement(id) then return {success = false, message = "Visit this property to sell it."} end
  return overhaul_career_business_manager.requestBusinessSaleData("passiveBusiness", id)
end

local function sellStore(id)
  id = tostring(id)
  if not requirePhysicalManagement(id) then return {success = false, message = "Visit this property to sell it."} end
  return overhaul_career_business_manager.sellBusiness("passiveBusiness", id)
end

local function resetBusinessForSale(id)
  id = tostring(id)
  local state = properties[id]
  local archetypeId = state and state.archetypeId or "miniMart"
  properties[id] = nil
  local noRemainingProperties = #getOwnedStates(archetypeId) == 0
  local forfeited = {}
  for reservationId, reservation in pairs(reservations) do
    if isCurrentMap(reservation) and reservation.archetypeId == archetypeId
      and (reservation.orderedByPropertyId == id or (reservation.orderedByPropertyId == nil and noRemainingProperties)) then
      forfeited[reservationId] = true
    end
  end
  local cargoList = overhaul_career_logistics_parcelManager.getAllCargoCustomFilter(function(cargo)
    local reservation = getReservationForCargo(cargo)
    return reservation and forfeited[reservation.id] == true
  end) or {}
  for _, cargo in ipairs(cargoList) do returnCargoToSupplier(cargo, true) end
  for reservationId in pairs(forfeited) do reservations[reservationId] = nil end
  if activeBusinessId == id then activeBusinessId = nil end
end

local businessObject = {
  businessType = "passiveBusiness",
  features = {
    bankAccount = false,
    skillTrees = false,
    inventory = false,
    personalVehicle = false,
    finances = false,
    xpSystem = false,
    operatingCosts = false,
  },
  getUIData = getUIData,
  resetBusinessForSale = resetBusinessForSale,
}

-- Supply pickup -----------------------------------------------------------------------------------

-- Prefer the inventory thumbnail because it shows the vehicle's actual parts and paint.
local function vehicleThumb(vehId)
  if not vehId then return nil end
  local inventory = overhaul_career_garage_inventory
  if inventory and inventory.getInventoryIdFromVehicleId and inventory.getVehicleThumbnail then
    local invId = inventory.getInventoryIdFromVehicleId(vehId)
    if invId then
      -- no captured picture yet: render one now and push the screen data again when it lands
      if inventory.ensureVehicleThumbnail then
        inventory.ensureVehicleThumbnail(invId, function() if M.requestSupplyPickupData then M.requestSupplyPickupData() end end)
      end
      local ok, thumb = pcall(inventory.getVehicleThumbnail, invId)
      if ok and type(thumb) == "string" and thumb ~= "" then return thumb end
    end
  end
  local ok, details = pcall(core_vehicles.getVehicleDetails, vehId)
  if not ok or type(details) ~= "table" then return nil end
  local config = details.configs
  return type(config) == "table" and config.preview or nil
end

local function formatEquipment(containers)
  local equipment, palletCapacity = {}, 0
  for _, container in ipairs(containers or {}) do
    local supportsParcel = container.cargoTypesLookup and container.cargoTypesLookup.parcel
    local free = math.max(0, tonumber(container.freeCargoSlots) or 0)
    local pallets = supportsParcel and math.floor(free / PALLET_SLOTS) or 0
    palletCapacity = palletCapacity + pallets
    -- Only a container that cannot take a load explains why; eligible ones carry no reason.
    local reason
    if not supportsParcel then
      reason = "Parcel freight is not supported"
    elseif pallets > 0 then
      reason = nil
    else
      reason = "Less than 128 slots free"
    end
    equipment[#equipment + 1] = {
      vehId = container.vehId,
      containerId = container.containerId,
      vehicleName = container.vehName or "Vehicle",
      containerName = container.name or "Cargo container",
      thumbnail = vehicleThumb(container.vehId),
      used = math.max(0, tonumber(container.usedCargoSlots) or 0),
      capacity = math.max(0, tonumber(container.totalCargoSlots) or 0),
      free = free,
      pallets = pallets,
      eligible = pallets > 0,
      reason = reason,
    }
  end
  return equipment, palletCapacity
end

local function sourceStateAt(facId, psPath)
  for _, state in ipairs(getOwnedStates()) do
    local source = getSourceLocation(state)
    if source and source.facId == facId and source.psPath == psPath then return state end
  end
  return nil
end

local function reservationAtSource(reservation, facId, psPath)
  if not isCurrentMap(reservation) then return false end
  if not supplyEnabled(reservation) then return false end
  if not facId then return true end
  if reservation.supplierFacilityId ~= facId then return false end
  if reservation.supplierParkingSpotName == psPath then return true end
  for _, state in ipairs(getOwnedStates(reservation.archetypeId)) do
    local source = getSourceLocation(state)
    if source and source.facId == facId and source.psPath == psPath then return true end
  end
  return false
end

local function procurementData(containers, facId, psPath)
  local capacity, stored, reserved = chainTotals()
  local availablePaid = 0
  for _, reservation in pairs(reservations) do
    if reservation.status == "available" and reservationAtSource(reservation, facId, psPath) then availablePaid = availablePaid + 1 end
  end
  local equipment, vehicleCapacity = formatEquipment(containers)
  local maximum = math.min(vehicleCapacity, availablePaid)
  local facilityName, facilityPreview = supplierFacilityInfo(facId)
  return {
    facilityName = facilityName,
    facilityPreview = facilityPreview,
    available = #getOwnedStates() > 0,
    reason = capacity <= 0 and "Own a passive business before collecting supplies." or nil,
    supplyName = "Business Supplies",
    slotsPerPallet = PALLET_SLOTS,
    unitCost = 0,
    wholesaleActive = false,
    chainCapacity = capacity,
    chainStored = stored,
    chainReserved = reserved,
    chainFree = math.max(0, capacity - stored - reserved),
    paidAtSupplier = availablePaid,
    vehicleCapacity = vehicleCapacity,
    maximumLoad = maximum,
    equipment = equipment,
    loading = pickup.loading,
  }
end

local function requestSupplyPickupData()
  if not pickup.open then return false end
  overhaul_career_logistics_general.getNearbyVehicleCargoContainers(function(containers)
    if pickup.open then
      guihooks.trigger("passiveBusinessSupplyPickupData", procurementData(containers, pickup.facId, pickup.psPath))
    end
  end)
  return true
end

local function getPaidSupplyPickupLocations()
  local locations, seen = {}, {}
  if reservationCount(nil, "available") <= 0 then return locations end
  for _, state in ipairs(getOwnedStates()) do
    local source = getSourceLocation(state)
    if source and source.facId and source.psPath then
      local key = source.facId .. "|" .. source.psPath
      if not seen[key] then
        seen[key] = true
        locations[#locations + 1] = source
      end
    end
  end
  return locations
end

local function requestSupplyWorldMarkers()
  local general = overhaul_career_logistics_general
  if general and general.requestDeliveryPoiRefresh then
    general.requestDeliveryPoiRefresh(true)
  end
end

local function hasPaidSupplyAt(facId, psPath)
  for _, reservation in pairs(reservations) do
    if reservation.status == "available" and reservationAtSource(reservation, facId, psPath) then
      return true
    end
  end
  return false
end

local function enterSupplyPickupScreen(facId, psPath)
  if not sourceStateAt(facId, psPath) then
    notify("error", "Business Supplies", "Park at the supplier selected by an owned business and choose Pickup business supplies.")
    return false
  end
  pickup.open = true
  pickup.facId, pickup.psPath = facId, psPath
  pickup.loading = false
  overhaul_integration_services_markerInteraction.closeViewDetailPrompt(true)
  simTimeAuthority.pause(true)
  guihooks.trigger("ChangeState", {state = "overhaul.passiveBusinessSupplyPickup"})
  return true
end

local function closeSupplyPickupScreen()
  resetPickup()
  simTimeAuthority.pause(false)
  guihooks.trigger("ChangeState", {state = "play"})
  overhaul_integration_services_markerInteraction.setForceReevaluateOpenPrompt()
end

local function onSupplyPickupRouteLeave()
  resetPickup()
  simTimeAuthority.pause(false)
end

local function setSupplierRoute(id, showMessage)
  id = tostring(id)
  if not owned(id) then return {success = false, message = "This property is not owned."} end
  local state = ensureProperty(id)
  if not supplyEnabled(state) then return {success = false, message = "This property has no supplier."} end
  if not isCurrentMap(state) then return {success = false, message = "Travel to this property's map to collect supplies."} end
  if not hasPaidSupplyAt(state.supplierFacilityId, state.supplierParkingSpotName) then
    return {success = false, message = "There is no paid order waiting at this supplier."}
  end
  local source = getSourceLocation(state)
  local toPos = source and overhaul_career_logistics_generator.getLocationCoordinates(source) or nil
  if not toPos then
    return {success = false, message = "The business supplier pickup location is unavailable."}
  end
  freeroam_bigMapMode.setNavFocus(toPos)
  core_groundMarkers.setPath({toPos}, {clearPathOnReachingTarget = false})
  local message = "Route set to " .. supplierFacilityInfo(state.supplierFacilityId) .. ". Park there and choose Pickup business supplies."
  if showMessage ~= false then notify("info", supplyName(state) .. " pickup marked", message) end
  requestSupplyWorldMarkers()
  return {success = true, message = message}
end

local function newReservation(state, cost)
  local id = string.format("passive-supply-%d", nextReservationId)
  nextReservationId = nextReservationId + 1
  local archetype = getArchetype(state)
  local reservation = {
    id = id,
    archetypeId = state.archetypeId,
    supplyType = archetype.supplyType,
    supplyName = archetype.supplyName,
    supplyTemplateId = archetype.supplyTemplateId,
    supplySlots = archetype.supplySlots,
    supplierFacilityId = state.supplierFacilityId,
    supplierParkingSpotName = state.supplierParkingSpotName,
    paidCost = cost,
    orderedByPropertyId = state.id,
    mapId = state.mapId,
    status = "available",
  }
  reservations[id] = reservation
  return reservation
end

local function availableReservations(archetypeId, facId, psPath)
  local result = {}
  for _, reservation in pairs(reservations) do
    if (not archetypeId or reservation.archetypeId == archetypeId)
      and reservation.status == "available"
      and reservationAtSource(reservation, facId, psPath) then
      result[#result + 1] = reservation
    end
  end
  table.sort(result, function(left, right) return left.id < right.id end)
  return result
end

local function orderSupply(id, quantity)
  id = tostring(id)
  if not requirePhysicalManagement(id) then return {success = false, message = "Visit this property to order stock."} end
  local state = ensureProperty(id)
  if not supplyEnabled(state) then return {success = false, message = "This property has no supply orders."} end
  if not getSourceLocation(state) then return {success = false, message = "The business supplier pickup location is unavailable."} end
  local requested = math.floor(tonumber(quantity) or 0)
  if requested <= 0 then return {success = false, message = "Choose at least one pallet."} end
  local capacity, stored, reserved = chainTotals(state.archetypeId)
  local freeChain = math.max(0, capacity - stored - reserved)
  local price = unitCost(state.archetypeId)
  local money = overhaul_career_economy_playerAttributes.getAttributeValue("money") or 0
  local affordable = price > 0 and math.floor(money / price) or 0
  local maximum = math.min(freeChain, affordable)
  if requested > maximum then
    return {
      success = false,
      message = maximum > 0
        and string.format("You can order at most %d pallet%s.", maximum, maximum == 1 and "" or "s")
        or "No additional pallets can be ordered with the current wallet and chain capacity.",
    }
  end

  local total = requested * price
  ensureFinanceBackfill(state)
  if not overhaul_career_economy_payment.pay({money = {amount = total, canBeNegative = false}}, require("overhaul/lib/finance/metadata").tag({category = "business", label = "Ordered " .. supplyName(state)}, "business", {locationId = state.supplierFacilityId, vehicleRelated = false})) then
    return {success = false, message = "You cannot afford that order."}
  end
  recordFinance(state, "order", total, requested)
  for _ = 1, requested do newReservation(state, price) end
  overhaul_career_saveSystem.saveCurrent()
  requestSupplyWorldMarkers()
  local routeResult = setSupplierRoute(id, true)
  return {
    success = true,
    amount = total,
    quantity = requested,
    routeSet = routeResult.success == true,
    message = string.format("Ordered %d pallet%s for $%d. Pick up the paid order at %s.", requested, requested == 1 and "" or "s", total, supplierFacilityInfo(state.supplierFacilityId)),
    dashboard = getDashboardData(id),
  }
end

local function loadFailed(message)
  pickup.loading = false
  guihooks.trigger("passiveBusinessSupplyPickupResult", {success = false, message = message})
  requestSupplyPickupData()
end

-- Paid orders at this supplier that have a receiving point, up to count pallets.
local function reservationsToLoad(count, facId, psPath)
  local toLoad = {}
  for _, reservation in ipairs(availableReservations(nil, facId, psPath)) do
    if #toLoad >= count then break end
    local destinations = getDestinationLocations(reservation.archetypeId)
    if #destinations > 0 then
      toLoad[#toLoad + 1] = {reservation = reservation, destinations = destinations}
    end
  end
  return toLoad
end

-- Creates cargo in each container with room for whole pallets, until the orders run out. Returns the count loaded.
local function loadPalletsInto(containers, source, toLoad)
  local eligible = {}
  for _, container in ipairs(containers or {}) do
    local palletSpace = container.cargoTypesLookup and container.cargoTypesLookup.parcel and math.floor(math.max(0, container.freeCargoSlots or 0) / PALLET_SLOTS) or 0
    if palletSpace > 0 then eligible[#eligible + 1] = {container = container, pallets = palletSpace} end
  end
  local loaded = 0
  for _, slot in ipairs(eligible) do
    while slot.pallets > 0 and loaded < #toLoad do
      local loadItem = toLoad[loaded + 1]
      local reservation = loadItem.reservation
      local cargo = overhaul_career_logistics_generator.addPassiveBusinessSupplyCargo(slot.container, reservation, source, loadItem.destinations)
      if not cargo then break end
      reservation.status = "inTransit"
      reservation.cargoId = cargo.id
      loaded = loaded + 1
      slot.pallets = slot.pallets - 1
    end
  end
  return loaded
end

local function loadSupply(quantity)
  if not pickup.open or pickup.loading then return false end
  pickup.loading = true
  overhaul_career_logistics_general.getNearbyVehicleCargoContainers(function(containers)
    local limits = procurementData(containers, pickup.facId, pickup.psPath)
    local requested = math.max(0, math.floor(tonumber(quantity) or 0))
    local count = math.min(requested, limits.maximumLoad)
    if count <= 0 then
      return loadFailed("No paid order can be loaded. Order stock at an owned business, then bring at least 128 slots of nearby freight capacity.")
    end

    local sourceState = sourceStateAt(pickup.facId, pickup.psPath)
    local source = sourceState and getSourceLocation(sourceState)
    if not source then
      return loadFailed("The supplier is unavailable.")
    end

    local toLoad = reservationsToLoad(count, pickup.facId, pickup.psPath)
    if #toLoad == 0 then
      return loadFailed("No receiving point is available for the paid business supplies.")
    end

    -- Start delivery mode before creating the cargo: its save-safety hook would otherwise return the new pallets.
    if not overhaul_career_logistics_general.isDeliveryModeActive() then
      overhaul_career_logistics_general.startDeliveryMode()
    end

    local loaded = loadPalletsInto(containers, source, toLoad)
    if loaded > 0 then
      overhaul_career_logistics_parcelManager.applyTransientMoves(source)
      overhaul_career_logistics_general.requestUpdateContainerWeights()
      overhaul_career_logistics_tasklist.sendCargoToTasklist()
      overhaul_career_logistics_cargoScreen.onCargoPickedUp(true)
      guihooks.trigger("passiveBusinessSupplyPickupResult", {success = true, message = string.format("Loaded %d business supply pallet%s.", loaded, loaded == 1 and "" or "s")})
      closeSupplyPickupScreen()
    else
      loadFailed("No compatible 128-slot space was available.")
    end
  end)
  return true
end

local function getSupplyOfferCard(facId, psPath, containers)
  local sourceState = sourceStateAt(facId, psPath)
  local source = sourceState and getSourceLocation(sourceState)
  if not source then return nil end
  local distance = math.huge
  for archetypeId in pairs(archetypes) do
    for _, destination in ipairs(getDestinationLocations(archetypeId)) do
      local routeDistance = overhaul_career_logistics_generator.getDistanceBetweenFacilities(source, destination)
      if routeDistance then distance = math.min(distance, routeDistance) end
    end
  end
  if distance == math.huge then distance = 0 end
  local limits = procurementData(containers, facId, psPath)
  local enabled = limits.maximumLoad > 0
  local reason
  if limits.paidAtSupplier <= 0 then
    reason = "Order and pay for stock at an owned business first."
  elseif limits.vehicleCapacity <= 0 then
    reason = "Bring a freight container with at least 128 free parcel slots."
  end
  return {
    id = "passiveBusinessSupplies",
    cardType = "passiveBusinessSupplyOffer",
    isFacilityCard = true,
    name = "Business Supplies Pickup",
    type = "parcel",
    rewardMoney = 0,
    destinationName = "Owned Business",
    destinationNameLong = "A compatible owned business with free storage",
    distance = distance,
    slots = PALLET_SLOTS,
    enabled = enabled,
    disableReason = not enabled and {type = "noSpace", label = reason or "Supplies are unavailable."} or nil,
    modifiers = {},
    bigMapIds = {},
    supplyLimits = limits,
    sourceFacId = facId,
    origin = {facId = facId, psPath = psPath},
  }
end

-- Balance refund ----------------------------------------------------------------------------------

local function applyBalanceRefund(balanceRefund)
  if refundPaidThisLoad then
    saveVersion = SAVE_VERSION
    return
  end
  local refunded = overhaul_career_economy_payment.reward({money = {amount = balanceRefund}},
    {category = "refund", label = "Small-business balance refund", description = "Refunded the reduced cost of previously purchased storage and wholesale upgrades."}, true)
  if refunded ~= false then
    refundPaidThisLoad = true
    saveVersion = SAVE_VERSION
    overhaul_career_saveSystem.saveCurrent()
    notify("success", "Small-business balance refund", string.format("Refunded $%d for repriced storage and wholesale upgrades.", balanceRefund))
  else
    notify("error", "Small-business balance refund", "The refund could not be applied and will be retried next time this career loads.")
  end
end

-- Production --------------------------------------------------------------------------------------

local function advanceState(state, archetype, elapsed, revenuePerCycle)
  if not archetype or archetype.supplyType == false or state.stock <= 0 or elapsed <= 0 then return 0 end
  state.cycleProgress = state.cycleProgress + elapsed
  local processed = 0
  while state.stock > 0 and state.cycleProgress >= archetype.cycleSeconds do
    state.cycleProgress = state.cycleProgress - archetype.cycleSeconds
    state.stock = state.stock - 1
    state.uncollectedEarnings = state.uncollectedEarnings + revenuePerCycle
    processed = processed + 1
  end
  if processed > 0 then
    local totals = financeTotals(state)
    totals.palletsSold = totals.palletsSold + processed
    totals.salesRevenue = totals.salesRevenue + processed * revenuePerCycle
  end
  if state.stock <= 0 then state.cycleProgress = 0 end
  return processed
end

-- Public API --------------------------------------------------------------------------------------

M.openMenu = openMenu
M.closeManagementSession = closeManagementSession
M.getUIData = getUIData
M.getDashboardData = getDashboardData
M.getFinanceData = getFinanceData
M.collectEarnings = collectEarnings
M.setOperating = setOperating
M.purchaseStorageUpgrade = purchaseStorageUpgrade
M.purchaseWholesale = purchaseWholesale
M.orderSupply = orderSupply
M.setSupplierRoute = setSupplierRoute
M.requestSaleQuote = requestSaleQuote
M.sellStore = sellStore
M.getSupplyOfferCard = getSupplyOfferCard
M.hasPaidSupplyAt = hasPaidSupplyAt
M.getPaidSupplyPickupLocations = getPaidSupplyPickupLocations
M.enterSupplyPickupScreen = enterSupplyPickupScreen
M.requestSupplyPickupData = requestSupplyPickupData
M.loadSupply = loadSupply
M.closeSupplyPickupScreen = closeSupplyPickupScreen
M.onSupplyPickupRouteLeave = onSupplyPickupRouteLeave
M.returnCargoToSupplier = returnCargoToSupplier
M.returnAllCargoToSuppliers = returnAllCargoToSuppliers
M.canDeliverSupplyCargo = canDeliverSupplyCargo
M.deliverSupplyCargo = deliverSupplyCargo
M.isSupplyCargo = function(cargo) return getReservationForCargo(cargo) ~= nil end
M.getSupplyRouteDestination = getSupplyRouteDestination
M.getChainTotals = chainTotals
M.getSupplyProcurementLimits = procurementData

-- Embedded invariant checks; kept on the public table until the owner decides to remove them.
M.runInvariantTests = invariants.new({
  loadArchetypes = loadArchetypes,
  archetypes = function() return archetypes end,
  facilityData = function()
    return {passiveBusinesses = overhaul_world_facilities.getFacilitiesByType("passiveBusiness") or {}}
  end,
  locationAvailable = function(facilityId, parkingName)
    return receivingLocation({receivingFacilityId = facilityId, receivingParkingSpotName = parkingName}) ~= nil
  end,
  legacyBalance = LEGACY_BALANCE,
  indexed = indexed,
  balanceRefundForState = balanceRefundForState,
  advanceState = advanceState,
})

M.activity = require('overhaul/career/business/passive/activity')(M)

-- Game hooks --------------------------------------------------------------------------------------

function M.onCareerActivated()
  loadArchetypes()
  local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
  if refundPaidForSavePath ~= currentSavePath then
    refundPaidThisLoad = false
    refundPaidForSavePath = currentSavePath
  end
  local balanceRefund = loadData()
  overhaul_career_business_manager.registerBusiness("passiveBusiness", businessObject, M)
  overhaul_career_business_manager.registerBusinessCallback("passiveBusiness", {
    onPurchase = function(id) ensureProperty(id) end,
    onMenuOpen = openMenu,
  })
  ensureTabsRegistered()
  if balanceRefund > 0 then
    applyBalanceRefund(balanceRefund)
  elseif saveVersion < SAVE_VERSION then
    saveVersion = SAVE_VERSION
  end
end

function M.onClientEndMission()
  returnAllCargoToSuppliers()
  activeBusinessId = nil
  resetPickup()
end

function M.onUpdate(_, dtSim)
  if not overhaul_career_career.isActive() then return end
  local dt = math.max(0, tonumber(dtSim) or 0)
  if dt <= 0 then return end
  updateAccumulator = updateAccumulator + dt
  if updateAccumulator < UPDATE_STEP_SECONDS then return end
  local elapsed = updateAccumulator
  updateAccumulator = 0
  for _, state in ipairs(getOwnedStates(nil, true)) do
    local archetype = getArchetype(state)
    if archetype and archetype.supplyType ~= false and state.operating and state.stock > 0 then
      advanceState(state, archetype, elapsed, indexed(archetype.unitRevenue))
      if state.stock <= 0 and not state.outOfStockNotified then
        state.outOfStockNotified = true
        notify("warning", businessName(state) .. " out of stock", "Production has stopped. Order more " .. supplyName(state) .. ", then collect it from the property's supplier.")
      end
    end
  end
end

function M.onOverhaulSaveCurrentProfile(currentSavePath)
  -- Autosaves keep live cargo; reload restores supplier-ready orders and teardown returns the live cargo.
  if not dataLoaded then loadData() end
  if not currentSavePath then return end
  overhaul_career_saveSystem.jsonWriteFileSafe(saveState.featureFilePath(currentSavePath, "passiveBusinesses.json"), {
    version = saveVersion,
    properties = properties,
    reservations = reservations,
    nextReservationId = nextReservationId,
  }, true)
end

return M
