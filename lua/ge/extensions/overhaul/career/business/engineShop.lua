-- Engine-shop warehouse, production lines, upgrades, saved records and supply pickups.
-- Read config, state, parts, helpers, persistence, line rules, certification, supply, UI payloads, lifecycle, developer tools, the public API, then game hooks.
local recordCertification = require("overhaul/lib/progression/logbookFeed").register("overhaul.engineCertified", {
  title = "Engine certification completed", label = "Engine Works", icon = "engine"
}, "career/business/engineShop.lua")

local M = {}

local calendar = require("overhaul/lib/world/calendar")
local devConsole = require("overhaul/lib/lifecycle/devConsolePolicy")
local capabilities = require("overhaul/lib/platform/capabilities")
local saveState = require("overhaul/lib/business/saveState")
local levelData = require("overhaul/lib/world/levelData")

-- Config ---------------------------------------------------------------------------------------------

local config = {
  SHOP_TYPE = "engineShop",
  SAVE_VERSION = 4,
  SAVE_FILE = "engineShops.json",
  STARTING_WAREHOUSE = 15,
  LINE_SLOTS = 3,
  BRAND_PRICE_BONUS_MAX = 0.10,
  PRODUCT_PRICE_BONUS_MAX = 0.05,
  FRESH_VALUE_MARKET_MULTIPLIER = 1.55,
  LANDED_COST_FLOOR_MULTIPLIER = 1.15,
  CERTIFICATION_DURATION_SECONDS = 600,
  ENGINE_SALE_MIN_SECONDS = 300,
  ENGINE_SALE_MAX_SECONDS = 900,
  LEGACY_LINE_DURATION_MINUTES = {480, 420, 360, 300},
  LINE_DURATION_SECONDS = {900, 720, 480, 300},
  LINE_SUCCESS_CHANCES = {0.90, 0.94, 0.97, 0.99},
  LINE_BREAKDOWN_CHANCES = {0.05, 0.03, 0.02, 0.01},
  LINE_MAINTENANCE_DISCOUNTS = {0, 0.15, 0.30, 0.40},
  LINE_OVERHAUL_BASES = {2500, 5000, 10000},
}

-- Capacity upgrades bought once per shop; `requires` names the earlier upgrade.
local capacityUpgrades = {
  warehouse1 = {name = "Warehouse Expansion I", cost = 25000, effect = "Shared storage 15 to 25 spots."},
  warehouse2 = {name = "Warehouse Expansion II", cost = 75000, requires = "warehouse1", effect = "Shared storage 25 to 50 spots."},
  line2 = {name = "Production Line II", cost = 100000, effect = "Unlocks the second production line."},
  line3 = {name = "Production Line III", cost = 200000, requires = "line2", effect = "Unlocks the third production line."},
}

-- Per-line upgrades; each kind has three levels, and the descriptions match the levels.
local lineUpgradeDefs = {
  speed = {name = "Production Speed", costs = {5000, 15000, 30000}, descriptions = {"15m to 12m per engine", "12m to 8m per engine", "8m to 5m per engine"}},
  quality = {name = "Quality Control", costs = {5000, 15000, 30000}, descriptions = {"90% to 94% success", "94% to 97% success", "97% to 99% success"}},
  maintenance = {name = "Preventive Maintenance", costs = {5000, 15000, 30000}, descriptions = {"3% breakdown, 15% cheaper overhaul", "2% breakdown, 30% cheaper overhaul", "1% breakdown, 40% cheaper overhaul"}},
}

-- State ----------------------------------------------------------------------------------------------

-- Engine shop states by business id (replaced on load), shared with the engine shop parts.
local shop = {states = {}}
local statesLoaded = false
local activeBusinessId
local shopZones = {mapId = nil, byBusiness = {}}
local selectedBayInventoryId

local services = {}
local ownerServices = {}

-- Other extensions -----------------------------------------------------------------------------------

-- Logistics owners are reached through their capabilities, so this file names no logistics extension.
local function parcelManager() return capabilities.get("cargoMoves") end
local function generator() return capabilities.get("facilityDistances") end
local function general() return capabilities.get("deliveryPois") end

-- Time, money and helpers ----------------------------------------------------------------------------

function ownerServices.nowWorldMinutes()
  local weather = calendar.get()
  local day = math.max(0, math.floor(tonumber(weather.dayIndex) or 0))
  local minute = math.max(0, math.min(1439, math.floor(tonumber(weather.minuteOfDay) or 0)))
  return day * 1440 + minute, day, minute
end

function ownerServices.indexed(value)
  local economy = overhaul_career_economy_globalEconomy
  local index = economy and economy.getGlobalIndex and economy.getGlobalIndex() or 1
  return math.floor((tonumber(value) or 0) * index + 0.5)
end

local function notify(kind, title, message)
  guihooks.trigger("toastrMsg", {type = kind, title = title, msg = message})
end

function ownerServices.accountFor(id)
  return overhaul_career_economy_bank and overhaul_career_economy_bank.getBusinessAccount and overhaul_career_economy_bank.getBusinessAccount(config.SHOP_TYPE, tostring(id))
end

function ownerServices.pay(id, amount, label, description)
  amount = math.max(0, math.floor(tonumber(amount) or 0))
  if amount == 0 then return true end
  local account = ownerServices.accountFor(id)
  return account and overhaul_career_economy_bank.payFromAccount({money = {amount = amount, canBeNegative = false}}, account.id, label, description, {category = "business"}) == true
end

function ownerServices.reward(id, amount, label, description)
  amount = math.max(0, math.floor(tonumber(amount) or 0))
  if amount == 0 then return true end
  local account = ownerServices.accountFor(id)
  return account and overhaul_career_economy_bank.rewardToAccount({money = {amount = amount}}, account.id, label, description, {category = "business"}) == true
end

-- Save and load --------------------------------------------------------------------------------------

local function newLine(id)
  return {id = id, blueprintId = nil, running = false, broken = false, progressSeconds = 0,
    attemptStarted = false, upgrades = {speed = 0, quality = 0, maintenance = 0}, attempts = {}, overhaulCostSinceLastAttempt = 0}
end

-- Retain the cost window for each certified engine when a line changes assignments.
local function trimLineAttempts(state, line)
  local counts = {}
  for index = #line.attempts, 1, -1 do
    local blueprintId = tostring(line.attempts[index].blueprintId or "")
    counts[blueprintId] = (counts[blueprintId] or 0) + 1
    if not state.blueprints[blueprintId] or counts[blueprintId] > 20 then
      table.remove(line.attempts, index)
    end
  end
end

-- Saves from before version 2 kept finished engines in `products` and `revisions`; they become blueprints.
local function migrateLegacyState(id, state)
  if tonumber(state.version) and tonumber(state.version) >= 2 then return state end
  local blueprints = {}
  for revisionId, revision in pairs(state.revisions or {}) do
    local certification = revision.certification or {}
    if certification.status == "passed" then
      local product
      for _, candidate in pairs(state.products or {}) do
        for _, candidateRevisionId in ipairs(candidate.revisionIds or {}) do
          if tostring(candidateRevisionId) == tostring(revisionId) then product = candidate break end
        end
        if product then break end
      end
      local blueprintId = tostring(revisionId)
      blueprints[blueprintId] = {id = blueprintId,
        name = (product and product.name) or (revision.recipe and revision.recipe.rootEngineNiceName) or "Certified Engine",
        recipe = deepcopy(revision.recipe or {}), recipeSignature = revision.recipeSignature or (revision.recipe and revision.recipe.signature),
        freshValue = math.max(1, math.floor(tonumber(revision.freshValue) or 1)), certification = deepcopy(certification),
        listed = product and product.listed == true and tostring(product.salesRevisionId or product.activeRevisionId) == tostring(revisionId) or false,
        price = math.max(1, math.floor(tonumber(product and product.price) or (tonumber(revision.freshValue) or 1) * config.FRESH_VALUE_MARKET_MULTIPLIER)),
        awareness = math.max(0, math.min(100, tonumber(product and product.awareness) or 0)), createdAt = revision.createdAt or os.time()}
    end
  end
  state.blueprints = blueprints
  state.legacyFinishedToMaterialize = deepcopy(state.finishedStock or {})
  state.version = 2
  state.migrationPending = true
  return state
end

-- Version 3 stores progress in seconds; older saves were in minutes and get scaled to the new durations.
local function normalizeLines(state, loadedVersion)
  local oldLines = state.lines or {}
  state.lines = {}
  for lineId = 1, config.LINE_SLOTS do
    local old = oldLines[lineId] or {}
    local line = newLine(lineId)
    line.blueprintId = old.blueprintId or old.revisionId
    line.running = old.running == true or old.status == "running"
    line.broken = old.broken == true
    line.attemptStarted = old.attemptStarted == true
    line.attempts = type(old.attempts) == "table" and old.attempts or {}
    for _, attempt in ipairs(line.attempts) do
      -- Untagged history has no reliable producer; track its packages before pruning.
      if attempt.success == true and attempt.packageId ~= nil then
        state.manufacturedPackageIds[tostring(attempt.packageId)] = true
      end
    end
    trimLineAttempts(state, line)
    line.overhaulCostSinceLastAttempt = math.max(0, tonumber(old.overhaulCostSinceLastAttempt) or 0)
    if old.upgrades then
      for kind in pairs(line.upgrades) do line.upgrades[kind] = math.max(0, math.min(3, math.floor(tonumber(old.upgrades[kind]) or 0))) end
    elseif old.hires then
      line.upgrades.speed = old.hires.specialist and 1 or 0
      line.upgrades.quality = old.hires.inspector and 1 or 0
      line.upgrades.maintenance = old.hires.maintenance and 1 or 0
    end
    local speedLevel = math.max(0, math.min(3, math.floor(tonumber(line.upgrades.speed) or 0)))
    local newDuration = config.LINE_DURATION_SECONDS[speedLevel + 1]
    if loadedVersion < 3 then
      local oldDuration = config.LEGACY_LINE_DURATION_MINUTES[speedLevel + 1]
      local oldProgress = math.max(0, tonumber(old.progressMinutes) or tonumber(old.progressSeconds) or 0)
      line.progressSeconds = math.min(newDuration, oldDuration > 0 and oldProgress / oldDuration * newDuration or 0)
    else
      line.progressSeconds = math.max(0, tonumber(old.progressSeconds) or 0)
    end
    state.lines[lineId] = line
  end
end

local function normalizeCertificationJobs(state, loadedVersion)
  for _, job in pairs(state.certificationJobs) do
    if type(job) == "table" and not job.completed then
      if loadedVersion < 3 then
        local absolute = ownerServices.nowWorldMinutes()
        local submittedAt = tonumber(job.submittedAt) or absolute
        local readyAt = tonumber(job.readyAt) or (submittedAt + 60)
        local legacyDuration = math.max(1, readyAt - submittedAt)
        local legacyProgress = math.max(0, math.min(legacyDuration, absolute - submittedAt))
        job.progressSeconds = config.CERTIFICATION_DURATION_SECONDS * legacyProgress / legacyDuration
      else
        job.progressSeconds = math.max(0, tonumber(job.progressSeconds) or 0)
      end
      job.durationSeconds = config.CERTIFICATION_DURATION_SECONDS
    end
  end
end

local function normalizeSalesFields(state, loadedVersion)
  state.lastWorldMinutes = tonumber(state.lastWorldMinutes) or ownerServices.nowWorldMinutes()
  state.salesCycleProgressSeconds = math.max(0, tonumber(state.salesCycleProgressSeconds) or 0)
  state.salesUpdateAccumulatorSeconds = math.max(0, tonumber(state.salesUpdateAccumulatorSeconds) or 0)
  state.salesCycleDurationSeconds = tonumber(state.salesCycleDurationSeconds)
  if loadedVersion < 3 and state.salesCycleDurationSeconds and state.salesCycleDurationSeconds > 0 then
    state.salesCycleMigrationRatio = math.max(0, math.min(1, state.salesCycleProgressSeconds / state.salesCycleDurationSeconds))
    state.salesCycleProgressSeconds = 0
    state.salesCycleDurationSeconds = nil
  end
  state.salesCurrentBlueprintId = state.salesCurrentBlueprintId and tostring(state.salesCurrentBlueprintId) or nil
  state.salesCursorBlueprintId = state.salesCursorBlueprintId and tostring(state.salesCursorBlueprintId) or nil
end

-- An in-transit reservation has no cargo once the save is loaded, so it returns to available.
local function normalizeReservations(state)
  for _, reservation in pairs(state.reservations) do
    local facility = ownerServices.currentFacility(state.id)
    reservation.businessId = state.id
    reservation.mapId = reservation.mapId or (facility and (facility.mapId or getCurrentLevelIdentifier()))
    if reservation.mapId then reservation.mapId = levelData.resolveAlias("map", reservation.mapId) end
    for _, key in ipairs({"supplierFacilityId", "supplierParkingSpotName", "receivingFacilityId", "receivingParkingSpotName"}) do
      if reservation.mapId == getCurrentLevelIdentifier() then reservation[key] = reservation[key] or (facility and facility[key]) end
    end
    reservation.blueprintId = tostring(reservation.blueprintId or reservation.revisionId or "")
    reservation.revisionId = reservation.blueprintId
    if reservation.status == "inTransit" then reservation.status, reservation.cargoId = "available", nil end
  end
end

local function refreshHardwareIdentity(blueprint)
  if blueprint.hardwareIdentityVersion ~= 1 or not blueprint.hardwareIdentity then
    blueprint.hardwareIdentity = overhaul_career_parts_engines_engineCertification.computeHardwareIdentity(blueprint.recipe)
    blueprint.hardwareIdentityVersion = 1
  end
  return blueprint.hardwareIdentity
end

local function normalizeState(id, state)
  local loadedVersion = math.max(1, math.floor(tonumber(state and state.version) or 1))
  state = migrateLegacyState(id, type(state) == "table" and state or {})
  state.id = tostring(id)
  state.version = config.SAVE_VERSION
  state.blueprints = type(state.blueprints) == "table" and state.blueprints or {}
  state.certificationJobs = type(state.certificationJobs) == "table" and state.certificationJobs or {}
  state.rawStock = type(state.rawStock) == "table" and state.rawStock or {}
  state.reservations = type(state.reservations) == "table" and state.reservations or {}
  state.salesHistory = type(state.salesHistory) == "table" and state.salesHistory or {}
  state.manufacturedPackageIds = type(state.manufacturedPackageIds) == "table" and state.manufacturedPackageIds or {}
  state.upgrades = type(state.upgrades) == "table" and state.upgrades or {}
  state.brandPopularity = math.max(0, math.min(100, tonumber(state.brandPopularity) or 0))
  state.nextBlueprintId = math.max(1, math.floor(tonumber(state.nextBlueprintId) or 1))
  state.nextReservationId = math.max(1, math.floor(tonumber(state.nextReservationId) or 1))
  for key in pairs(state.blueprints) do local numeric = tonumber(key); if numeric then state.nextBlueprintId = math.max(state.nextBlueprintId, numeric + 1) end end
  normalizeLines(state, loadedVersion)
  normalizeCertificationJobs(state, loadedVersion)
  normalizeSalesFields(state, loadedVersion)
  normalizeReservations(state)
  for _, blueprint in pairs(state.blueprints) do refreshHardwareIdentity(blueprint) end
  return state
end

-- Keep player records and inventory intact. Only authority to manufacture/list
-- is suspended if the same recipe no longer passes the resolved physics limit.
local function refreshCertifications(state)
  local certifier = overhaul_career_parts_engines_engineCertification
  for _, blueprint in pairs(state.blueprints) do
    blueprint.certification = blueprint.certification or {}
    certifier.refreshAnalysis(blueprint.certification, blueprint.recipe)
    if blueprint.certification.status ~= "passed" then
      blueprint.listed = false
      for _, line in ipairs(state.lines) do
        if tostring(line.blueprintId) == tostring(blueprint.id) then line.running = false end
      end
    end
  end
  for _, job in pairs(state.certificationJobs) do
    if not job.completed then
      local status = job.status
      certifier.refreshAnalysis(job, job.recipe)
      job.status = status
    end
  end
end

function ownerServices.ensureState(id)
  id = tostring(id)
  if not shop.states[id] then shop.states[id] = normalizeState(id, {}) end
  refreshCertifications(shop.states[id])
  return shop.states[id]
end

-- Capacity and line rules ----------------------------------------------------------------------------

local function upgradeLiquidationValue(id)
  local state = ownerServices.ensureState(id)
  local total = 0
  for upgradeId, definition in pairs(capacityUpgrades) do
    if state.upgrades[upgradeId] then total = total + ownerServices.indexed(definition.cost) end
  end
  for _, line in ipairs(state.lines or {}) do
    for kind, definition in pairs(lineUpgradeDefs) do
      local level = math.max(0, math.min(3, math.floor(tonumber(line.upgrades and line.upgrades[kind]) or 0)))
      for index = 1, level do total = total + ownerServices.indexed(definition.costs[index]) end
    end
  end
  return math.floor(total + 0.5)
end

local function getLiquidationValue(id)
  local state = ownerServices.ensureState(id)
  local total = upgradeLiquidationValue(id)
  total = total + (overhaul_career_business_partInventory.getLiquidationValue(id) or 0)
  for blueprintId, quantity in pairs(state.rawStock) do
    local blueprint = state.blueprints[tostring(blueprintId)]
    if blueprint then total = total + math.max(0, tonumber(quantity) or 0) * math.max(0, tonumber(blueprint.freshValue) or 0) end
  end
  for _, reservation in pairs(state.reservations) do
    if reservation.status ~= "cancelled" and reservation.status ~= "delivered" then
      total = total + math.max(0, tonumber(reservation.paidCost) or 0)
    end
  end
  return math.floor(total + 0.5)
end

local function saveData(currentSavePath)
  if not currentSavePath then return end
  overhaul_career_saveSystem.jsonWriteFileSafe(saveState.featureFilePath(currentSavePath, config.SAVE_FILE), {version = config.SAVE_VERSION, states = shop.states}, true)
end

local function loadData()
  shop.states = {}
  statesLoaded = true
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  local data = savePath and jsonReadFile(saveState.featureFilePath(savePath, config.SAVE_FILE)) or {}
  for id, state in pairs(data and data.states or {}) do
    state = normalizeState(id, state)
    refreshCertifications(state)
    shop.states[tostring(id)] = state
    for _, blueprint in pairs(state.blueprints) do services.sales.normalizeBlueprintPrice(blueprint, state) end
    overhaul_career_parts_engines_enginePackages.repairManufacturedPackageYears(state.manufacturedPackageIds)
  end
end

local function owned(id)
  return overhaul_career_business_manager and overhaul_career_business_manager.isPurchasedBusiness(config.SHOP_TYPE, tostring(id)) == true
end

function ownerServices.warehouseCapacity(state)
  if state.upgrades.warehouse2 then return 50 end
  if state.upgrades.warehouse1 then return 25 end
  return config.STARTING_WAREHOUSE
end

function ownerServices.lineCapacity(state)
  if state.upgrades.line3 then return 3 end
  if state.upgrades.line2 then return 2 end
  return 1
end

local function rawCount(state)
  local total = 0
  for _, count in pairs(state.rawStock) do total = total + math.max(0, math.floor(tonumber(count) or 0)) end
  return total
end

local function reservationCount(state)
  local total = 0
  for _, reservation in pairs(state.reservations) do if reservation.status ~= "cancelled" and reservation.status ~= "delivered" then total = total + 1 end end
  return total
end

function ownerServices.warehousePackages(id, blueprintId)
  local result = {}
  for _, package in ipairs(overhaul_career_parts_engines_enginePackages.listPackages({ownerType = "business", businessType = config.SHOP_TYPE, businessId = tostring(id)})) do
    if package.warehouseStock == true and (not blueprintId or tostring(package.blueprintId or package.productRevisionId) == tostring(blueprintId)) then result[#result + 1] = package end
  end
  table.sort(result, function(a, b) return tonumber(a.id) < tonumber(b.id) end)
  return result
end

function ownerServices.warehouseUsed(id, state)
  return rawCount(state) + reservationCount(state) + #ownerServices.warehousePackages(id)
end

local function findBlueprintBySignature(state, signature)
  for _, blueprint in pairs(state.blueprints) do if tostring(blueprint.recipeSignature) == tostring(signature) then return blueprint end end
end

function ownerServices.lineDuration(line) return config.LINE_DURATION_SECONDS[(line.upgrades.speed or 0) + 1] end
function ownerServices.lineSuccessChance(line) return config.LINE_SUCCESS_CHANCES[(line.upgrades.quality or 0) + 1] end
function ownerServices.lineBreakdownChance(line) return config.LINE_BREAKDOWN_CHANCES[(line.upgrades.maintenance or 0) + 1] end
function ownerServices.lineMaintenanceDiscount(line) return config.LINE_MAINTENANCE_DISCOUNTS[(line.upgrades.maintenance or 0) + 1] end

-- Production lines -------------------------------------------------------------------------------

local function assignLineBlueprint(id, lineId, blueprintId)
  local state = ownerServices.ensureState(id)
  lineId = tonumber(lineId)
  local line, blueprint = state.lines[lineId], state.blueprints[tostring(blueprintId)]
  if not line or lineId > ownerServices.lineCapacity(state) then return {success = false, message = "That production line is locked."} end
  if not blueprint then return {success = false, message = "Select a certified engine blueprint."} end
  if blueprint.certification.status ~= "passed" then return {success = false, message = blueprint.certification.reason or "This blueprint no longer passes its torque limit. Keep it and certify a revised engine package."} end
  if line.attemptStarted and tostring(line.blueprintId) ~= tostring(blueprintId) then
    return {success = false, message = "Stop after the current attempt before changing this line's blueprint."}
  end
  line.blueprintId = tostring(blueprintId)
  line.progressSeconds = 0
  line.attemptStarted = false
  return {success = true, message = blueprint.name .. " assigned to Production Line " .. tostring(lineId) .. "."}
end

local function setLineRunning(id, lineId, running)
  local state = ownerServices.ensureState(id)
  lineId = tonumber(lineId)
  local line = state.lines[lineId]
  if not line or lineId > ownerServices.lineCapacity(state) then return {success = false, message = "That production line is locked."} end
  if running and line.blueprintId then
    local blueprint = state.blueprints[tostring(line.blueprintId)]
    if not blueprint or blueprint.certification.status ~= "passed" then return {success = false, message = "This blueprint needs a passing certification before production can resume."} end
  end
  if running and not line.blueprintId then return {success = false, message = "Choose a certified engine blueprint first."} end
  if running and line.broken then return {success = false, message = "Overhaul this line before restarting it."} end
  line.running = running == true
  return {success = true, message = line.running and "Production line started." or "Production line stopped with progress preserved."}
end

local function purchaseLineUpgrade(id, lineId, upgradeKind)
  local state = ownerServices.ensureState(id)
  lineId = tonumber(lineId)
  local line, definition = state.lines[lineId], lineUpgradeDefs[tostring(upgradeKind)]
  if not line or lineId > ownerServices.lineCapacity(state) or not definition then return {success = false, message = "Line upgrade is unavailable."} end
  local currentLevel = math.max(0, math.min(3, tonumber(line.upgrades[upgradeKind]) or 0))
  if currentLevel >= 3 then return {success = false, message = "This line upgrade is already at Level 3."} end
  local cost = ownerServices.indexed(definition.costs[currentLevel + 1])
  if not ownerServices.pay(id, cost, definition.name, "Production Line " .. tostring(lineId) .. " upgrade") then
    return {success = false, message = "The Engine Works account cannot fund this upgrade."}
  end
  line.upgrades[upgradeKind] = currentLevel + 1
  return {success = true, message = definition.name .. " upgraded to Level " .. tostring(currentLevel + 1) .. "."}
end

local function overhaulLine(id, lineId)
  local state = ownerServices.ensureState(id)
  lineId = tonumber(lineId)
  local line = state.lines[lineId]
  if not line or not line.broken then return {success = false, message = "This line does not need an overhaul."} end
  local baseCost = ownerServices.indexed(config.LINE_OVERHAUL_BASES[lineId] or config.LINE_OVERHAUL_BASES[1])
  local cost = math.floor(baseCost * (1 - ownerServices.lineMaintenanceDiscount(line)) + 0.5)
  if not ownerServices.pay(id, cost, "Production line overhaul", "Restore Production Line " .. tostring(lineId)) then
    return {success = false, message = "The Engine Works account cannot fund the overhaul."}
  end
  line.broken = false
  line.overhaulCostSinceLastAttempt = (line.overhaulCostSinceLastAttempt or 0) + cost
  return {success = true, message = "Production Line " .. tostring(lineId) .. " was overhauled for $" .. tostring(cost) .. "."}
end

local function createFinishedPackage(id, state, blueprint)
  if ownerServices.warehouseUsed(id, state) > ownerServices.warehouseCapacity(state) then return nil, "Shared storage is full." end
  local package, err = overhaul_career_parts_engines_enginePackages.cloneFreshBusinessPackageFromRecipe(blueprint.recipe, blueprint.name,
    config.SHOP_TYPE, tostring(id), {blueprintId = tostring(blueprint.id), productRevisionId = tostring(blueprint.id), warehouseStock = true,
      recipeSignature = blueprint.recipeSignature, manufacturedAt = ownerServices.nowWorldMinutes(),
      manufacturedYear = overhaul_career_parts_engines_enginePackages.getCurrentManufacturingYear()})
  if package then state.manufacturedPackageIds[tostring(package.id)] = true end
  return package, err
end

local function processAttempt(id, state, line, forcedSuccess, forcedBreakdown)
  local blueprintId = tostring(line.blueprintId or "")
  local blueprint = state.blueprints[blueprintId]
  if not blueprint or (state.rawStock[blueprintId] or 0) <= 0 then
    line.attemptStarted = false
    line.progressSeconds = 0
    return false
  end
  state.rawStock[blueprintId] = state.rawStock[blueprintId] - 1
  local success = forcedSuccess ~= nil and forcedSuccess == true or nil
  if forcedSuccess == nil then success = math.random() < ownerServices.lineSuccessChance(line) end
  local package, packageError
  if success then
    package, packageError = createFinishedPackage(id, state, blueprint)
    if not package then success = false end
  end
  local cost = (blueprint.freshValue or 0) + (line.overhaulCostSinceLastAttempt or 0)
  line.attempts[#line.attempts + 1] = {at = ownerServices.nowWorldMinutes(), blueprintId = blueprintId,
    cost = cost, success = success, packageId = package and package.id, error = packageError}
  trimLineAttempts(state, line)
  line.overhaulCostSinceLastAttempt = 0
  line.attemptStarted = false
  local breakdown = forcedBreakdown ~= nil and forcedBreakdown == true or nil
  if forcedBreakdown == nil then breakdown = math.random() < ownerServices.lineBreakdownChance(line) end
  if breakdown then line.broken, line.running = true, false end
  return true
end

local function processProduction(id, state, elapsedSeconds)
  for lineId, line in ipairs(state.lines) do
    if lineId <= ownerServices.lineCapacity(state) and line.running and not line.broken and line.blueprintId then
      local blueprintId = tostring(line.blueprintId)
      if (state.rawStock[blueprintId] or 0) > 0 then
        line.attemptStarted = true
        line.progressSeconds = (line.progressSeconds or 0) + elapsedSeconds
        local duration = ownerServices.lineDuration(line)
        while line.running and not line.broken and line.progressSeconds >= duration and (state.rawStock[blueprintId] or 0) > 0 do
          line.progressSeconds = line.progressSeconds - duration
          processAttempt(id, state, line)
        end
      end
    end
  end
end

-- Certification --------------------------------------------------------------------------------------

local function recipeCertificationData(recipe)
  return overhaul_career_parts_engines_engineCertification.analyzeRecipe(recipe)
end

-- A passed engine becomes a blueprint once; a repeat pass for the same recipe reuses it.
local function certifiedBlueprint(state, job, packageId)
  local blueprint = findBlueprintBySignature(state, job.recipeSignature)
  if blueprint then
    blueprint.certification = {status = "passed", analysisVersion = job.analysisVersion, contentFingerprint = job.contentFingerprint, peakHorsepower = job.peakHorsepower, peakTorque = job.peakTorque,
      rating = job.rating, torqueLimit = job.torqueLimit, limiterRpm = job.limiterRpm, samples = deepcopy(job.samples)}
    return blueprint
  end
  local blueprintId = tostring(state.nextBlueprintId)
  state.nextBlueprintId = state.nextBlueprintId + 1
  blueprint = {id = blueprintId, name = job.packageName, recipe = deepcopy(job.recipe), recipeSignature = job.recipeSignature,
    freshValue = job.freshValue, certification = {status = "passed", analysisVersion = job.analysisVersion, contentFingerprint = job.contentFingerprint, peakHorsepower = job.peakHorsepower, peakTorque = job.peakTorque,
      rating = job.rating, torqueLimit = job.torqueLimit, limiterRpm = job.limiterRpm, samples = deepcopy(job.samples)}, listed = false,
    price = math.max(1, math.floor(job.freshValue * config.FRESH_VALUE_MARKET_MULTIPLIER + 0.5)), awareness = 0, createdAt = job.completedAt,
    sourcePackageId = tostring(packageId)}
  state.blueprints[blueprintId] = blueprint
  refreshHardwareIdentity(blueprint)
  return blueprint
end

local function completeCertification(id, state, packageId, job)
  if job.completed then return end
  job.completed, job.status = true, job.result
  job.completedAt = ownerServices.nowWorldMinutes()
  local package = overhaul_career_parts_engines_enginePackages.getPackage(packageId)
  if package then
    overhaul_career_parts_engines_enginePackages.setEngineShopCertification(packageId, {status = job.result, businessId = tostring(id),
      recipeSignature = job.recipeSignature, analysisVersion = job.analysisVersion, contentFingerprint = job.contentFingerprint, reason = job.reason, completedAt = job.completedAt, fee = job.fee, peakHorsepower = job.peakHorsepower,
      peakTorque = job.peakTorque, rating = job.rating, torqueLimit = job.torqueLimit, limiterRpm = job.limiterRpm, samples = job.samples})
  end
  recordCertification({detail = (job.packageName or "Engine package") .. " / " .. tostring(job.result)
    .. string.format(" / %.0f hp / %.0f Nm", job.peakHorsepower or 0, job.peakTorque or 0)})
  if job.result == "passed" then
    job.blueprintId = certifiedBlueprint(state, job, packageId).id
    notify("success", "Engine certification passed", string.format("%s is certified at %.0f hp and %.0f Nm.", job.packageName, job.peakHorsepower, job.peakTorque))
  elseif job.result == "unknown" then
    notify("warning", "Rating unknown", job.reason or "The engine rating could not be resolved. The stored package was returned intact.")
  else
    notify("error", "Engine certification failed", job.packageName .. " exceeded its resolved torque limit. The stored package was returned intact with a Failed tag.")
  end
end

local function processCertifications(id, state, elapsedSeconds)
  elapsedSeconds = math.max(0, tonumber(elapsedSeconds) or 0)
  for packageId, job in pairs(state.certificationJobs) do
    if not job.completed then
      job.durationSeconds = config.CERTIFICATION_DURATION_SECONDS
      job.progressSeconds = math.min(job.durationSeconds, math.max(0, tonumber(job.progressSeconds) or 0) + elapsedSeconds)
      if job.progressSeconds >= job.durationSeconds then completeCertification(id, state, packageId, job) end
    end
  end
end

local function startCertification(id, packageId)
  local state = ownerServices.ensureState(id)
  local package = overhaul_career_parts_engines_enginePackages.getPackage(packageId)
  if not package or package.ownerType == "business" then return {success = false, message = "Choose a personal Engine Package."} end
  local status = overhaul_career_parts_engines_enginePackages.getPackageStatus(package)
  if status ~= "stored" then return {success = false, message = "Certification requires the Engine Package to be stored, not installed in a car."} end
  local existing = state.certificationJobs[tostring(packageId)]
  if existing and not existing.completed then return {success = false, message = "This Engine Package is already in certification."} end
  local freshValue, recipe = overhaul_career_parts_engines_enginePackages.getFreshPackageValue(package)
  if not freshValue then return {success = false, message = recipe or "The package value could not be calculated."} end
  local signature = recipe.signature or overhaul_career_parts_engines_enginePackages.computeRecipeSignature(recipe)
  local data, certError = recipeCertificationData(recipe)
  if not data or data.result == "unknown" then return {success = false, message = certError or data.reason} end
  local fee = math.max(1, math.floor(freshValue * 0.05 + 0.5))
  if not ownerServices.pay(id, fee, "Engine certification", "10 active-minute stored-package certification") then
    return {success = false, message = "The Engine Works account cannot cover the certification fee."}
  end
  local absolute = ownerServices.nowWorldMinutes()
  local job = {packageId = tostring(packageId), packageName = package.name, recipe = recipe, recipeSignature = signature,
    freshValue = freshValue, fee = fee, submittedAt = absolute, durationSeconds = config.CERTIFICATION_DURATION_SECONDS,
    progressSeconds = 0, status = "pending", result = data.result, analysisVersion = data.analysisVersion, contentFingerprint = data.contentFingerprint,
    peakHorsepower = data.peakHorsepower, peakTorque = data.peakTorque, rating = data.rating, torqueLimit = data.torqueLimit, limiterRpm = data.limiterRpm, samples = data.samples}
  state.certificationJobs[tostring(packageId)] = job
  overhaul_career_parts_engines_enginePackages.setEngineShopCertification(packageId, {status = "pending", businessId = tostring(id),
    recipeSignature = signature, submittedAt = absolute, durationSeconds = config.CERTIFICATION_DURATION_SECONDS, progressSeconds = 0, fee = fee})
  return {success = true, message = string.format("%s entered certification for $%d. It will finish in 10 active minutes.", package.name, fee)}
end

-- Stored packages can be moved or junked; a package in certification is locked until its job completes.
local function packageReferenceGuard(package)
  if package.ownerType == "business" then return true end
  for _, state in pairs(shop.states) do
    local job = state.certificationJobs[tostring(package.id)]
    if job and not job.completed then return false, "This Engine Package is locked during certification." end
  end
  return true
end

-- Shop zone and bay ----------------------------------------------------------------------------------

function ownerServices.currentFacility(id)
  local facility = overhaul_world_facilities.getFacilityIfExists(config.SHOP_TYPE, tostring(id))
  local mapId = getCurrentLevelIdentifier()
  return facility and (not facility.mapId or facility.mapId == mapId) and facility or nil
end

local function getShopZones(id)
  local mapId = getCurrentLevelIdentifier()
  if shopZones.mapId ~= mapId then shopZones = {mapId = mapId, byBusiness = {}} end
  local facility = ownerServices.currentFacility(id)
  if not facility or type(facility.sitesFile) ~= "string" or type(facility.zoneNames) ~= "table" then
    log("W", "engineShop", "Service zone data unavailable for " .. tostring(id))
    return nil
  end
  local cached = shopZones.byBusiness[tostring(id)]
  if not cached or cached.path ~= facility.sitesFile then
    local sites = gameplay_sites_sitesManager.loadSites(facility.sitesFile)
    cached = {path = facility.sitesFile, zones = sites and sites.zones}
    shopZones.byBusiness[tostring(id)] = cached
    if not cached.zones or not next(facility.zoneNames or {}) then
      log("W", "engineShop", "Service zones unavailable for " .. tostring(id))
    end
  end
  return cached.zones, facility.zoneNames or {}
end

local function isInShopZone(id, vehObj)
  local zones, names = getShopZones(id)
  if not vehObj or not zones then return false end
  for _, zone in ipairs(zones.sorted or {}) do
    for _, name in ipairs(names) do
      if zone.name == name then
        if zone.containsVehicle and zone:containsVehicle(vehObj, true) then return true end
        if zone.containsPoint2D and zone:containsPoint2D(vehObj:getPosition()) then return true end
      end
    end
  end
  return false
end

local function localizedVehicles(id)
  local result = {}
  for inventoryId, vehicle in pairs(overhaul_career_garage_inventory.getVehicles() or {}) do
    local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
    local vehObj = vehId and getObjectByID(vehId)
    if vehObj and vehicle.owned == true and isInShopZone(id, vehObj) then
      result[#result + 1] = {inventoryId = inventoryId, vehId = vehId, niceName = vehicle.niceName or vehicle.model, model = vehicle.model}
    end
  end
  table.sort(result, function(a, b) return tostring(a.inventoryId) < tostring(b.inventoryId) end)
  return result
end

-- The bay vehicle the player picked, else the vehicle the garage has open, else the first one in the zone.
local function localizedVehicle(id)
  local vehicles = localizedVehicles(id)
  local current = overhaul_career_garage_inventory.getCurrentVehicle and overhaul_career_garage_inventory.getCurrentVehicle()
  local fallback
  for _, entry in ipairs(vehicles) do
    if selectedBayInventoryId and tostring(entry.inventoryId) == tostring(selectedBayInventoryId) then return entry end
    if not fallback and current and tostring(entry.inventoryId) == tostring(current) then fallback = entry end
  end
  return fallback or vehicles[1]
end

local function selectBayVehicle(id, inventoryId)
  for _, entry in ipairs(localizedVehicles(id)) do
    if tostring(entry.inventoryId) == tostring(inventoryId) then
      selectedBayInventoryId = entry.inventoryId
      return {success = true, message = "Selected " .. tostring(entry.niceName) .. " for work bay service."}
    end
  end
  return {success = false, message = "That vehicle is not inside the Engine Works service zone."}
end

-- Actions --------------------------------------------------------------------------------------------

local function purchaseUpgrade(id, upgradeId)
  local state = ownerServices.ensureState(id)
  local definition = capacityUpgrades[tostring(upgradeId)]
  if not definition or state.upgrades[upgradeId] then return {success = false, message = "Upgrade is unavailable."} end
  if definition.requires and not state.upgrades[definition.requires] then return {success = false, message = "Purchase the required earlier upgrade first."} end
  local cost = ownerServices.indexed(definition.cost)
  if not ownerServices.pay(id, cost, definition.name, "Engine Works capacity upgrade") then return {success = false, message = "The Engine Works account cannot fund this upgrade."} end
  state.upgrades[upgradeId] = true
  return {success = true, message = definition.name .. " purchased."}
end

local function orderRawMaterials(id, blueprintId, quantity)
  local state = ownerServices.ensureState(id)
  local blueprint = state.blueprints[tostring(blueprintId)]
  quantity = math.max(1, math.floor(tonumber(quantity) or 1))
  if not blueprint then return {success = false, message = "Choose a certified engine blueprint."} end
  if blueprint.certification.status ~= "passed" then return {success = false, message = blueprint.certification.reason or "This blueprint needs a passing certification before ordering more material."} end
  if ownerServices.warehouseUsed(id, state) + quantity > ownerServices.warehouseCapacity(state) then return {success = false, message = "The shared warehouse lacks enough unreserved spots."} end
  local facility = ownerServices.currentFacility(id)
  local source, destination, supplier = services.supply.endpoints(facility)
  if not source or not destination then
    log("W", "engineShop", "Supply endpoints unavailable for " .. tostring(id))
    return {success = false, message = "The local supplier or receiving point is unavailable."}
  end
  local cost = math.floor((blueprint.freshValue or 1) * quantity)
  if not ownerServices.pay(id, cost, "Engine raw materials", tostring(quantity) .. " prepaid 128-slot production load(s)") then
    return {success = false, message = "The Engine Works account cannot fund this order."}
  end
  for _ = 1, quantity do
    local reservationId = tostring(state.nextReservationId)
    state.nextReservationId = state.nextReservationId + 1
    state.reservations[reservationId] = {id = reservationId, businessId = tostring(id), blueprintId = tostring(blueprintId),
      revisionId = tostring(blueprintId), quantity = 1, status = "available", mapId = facility.mapId or getCurrentLevelIdentifier(),
      supplierFacilityId = facility.supplierFacilityId, supplierParkingSpotName = facility.supplierParkingSpotName,
      receivingFacilityId = facility.receivingFacilityId, receivingParkingSpotName = facility.receivingParkingSpotName,
      paidCost = blueprint.freshValue}
  end
  general().requestDeliveryPoiRefresh(true)
  return {success = true, message = string.format("Ordered %d paid load%s. Park at %s and choose Pickup engine materials; each needs 128 cargo slots.", quantity, quantity == 1 and "" or "s", supplier.name or "the supplier")}
end

local function junkWarehousePackage(id, packageId)
  local package = overhaul_career_parts_engines_enginePackages.getPackage(packageId)
  if not services.sales.destroyWarehousePackage(id, package) then return {success = false, message = "That physical warehouse engine could not be junked."} end
  return {success = true, message = "The selected physical engine was permanently junked. One storage spot is now free."}
end

local function installWarehousePackage(id, packageId)
  local vehicle = localizedVehicle(id)
  if not vehicle then return {success = false, message = "Spawn a personal vehicle inside the marked Engine Works garage zone first."} end
  local package = overhaul_career_parts_engines_enginePackages.getPackage(packageId)
  if not package or package.ownerType ~= "business" or tostring(package.businessId) ~= tostring(id) or package.warehouseStock ~= true then
    return {success = false, message = "Physical warehouse engine not found."}
  end
  local businessFields = {businessType = package.businessType, businessId = package.businessId,
    productRevisionId = package.productRevisionId, blueprintId = package.blueprintId}
  local personal, transferError = overhaul_career_parts_engines_enginePackages.transferBusinessPackageToPersonal(packageId)
  if not personal then return {success = false, message = transferError or "The warehouse engine could not be moved into personal ownership."} end
  local started, returned = false, false
  -- A failed install puts the engine back in the warehouse; the message only follows a start that was already announced.
  local function returnToWarehouse()
    if returned then return end
    returned = true
    local restored, restoreError = overhaul_career_parts_engines_enginePackages.transferPersonalPackageToBusiness(personal.id, businessFields)
    if not restored then
      log("E", "engineShop", "Warehouse engine could not be returned after a failed install: " .. tostring(restoreError))
    elseif started then
      ui_message("The engine installation failed. The engine is back in the Engine Works warehouse.", 8, "warning")
    end
  end
  local installError
  started, installError = overhaul_career_parts_engines_enginePackages.installPackageIntoVehicle(personal.id, vehicle.inventoryId,
    function(success) if not success then returnToWarehouse() end end)
  if not started then
    returnToWarehouse()
    return {success = false, message = installError or "The engine installation could not start."}
  end
  return {success = true, message = "The physical engine left business storage. Installation started; the outgoing engine will be captured into My Engine Packages."}
end

local function openEnginePackages(id)
  local vehicle = localizedVehicle(id)
  local opened = overhaul_career_parts_engines_enginePackages.openMenu(vehicle and vehicle.inventoryId or nil, nil,
    {businessType = config.SHOP_TYPE, businessId = tostring(id)})
  if not opened then return {success = false, message = "The Engine Packages screen could not be opened."} end
  return {success = true, message = vehicle and
    "Opened the garage-style Engine Packages manager for the vehicle in the shop." or
    "Opened the garage-style Engine Packages manager in browse-only mode."}
end

local function openParts(id)
  local vehicle = localizedVehicle(id)
  if not vehicle then return {success = false, message = "Spawn a personal vehicle inside the marked Engine Works garage zone first."} end
  overhaul_career_parts_partShopping.startShopping(vehicle.inventoryId, nil, {
    name = "business-computer",
    params = {businessType = config.SHOP_TYPE, businessId = tostring(id)}
  })
  return {success = true, message = "Opened Part Customization for the localized vehicle."}
end

local function openMyParts(id)
  overhaul_career_parts_partInventory.openMenu(nil, {
    name = "business-computer",
    params = {businessType = config.SHOP_TYPE, businessId = tostring(id)}
  })
  return {success = true, message = "Opened My Parts."}
end

local function openTuning(id)
  local vehicle = localizedVehicle(id)
  if not vehicle then return {success = false, message = "Spawn a personal vehicle inside the marked Engine Works garage zone first."} end
  overhaul_career_parts_tuning.start(vehicle.inventoryId, nil, {
    name = "business-computer",
    params = {businessType = config.SHOP_TYPE, businessId = tostring(id)}
  })
  return {success = true, message = "Opened Tuning for the localized vehicle."}
end

local function openRepair(id)
  local vehicle = localizedVehicle(id)
  if not vehicle then return {success = false, message = "Spawn a personal vehicle inside the marked Engine Works garage zone first."} end
  overhaul_career_repair_repairScreen.openRepairMenu(overhaul_career_garage_inventory.getVehicles()[vehicle.inventoryId], nil)
  return {success = true, message = "Opened Repair for the localized vehicle."}
end

-- Engine promotion and certified packages ------------------------------------------------------------

local function clearEngineSlot(spawnConfig, slotName)
  local function visit(node)
    for name, child in pairs(node and node.children or {}) do
      if name == slotName then child.chosenPartName, child.children, child.emptyPlaceholder = "", {}, true return true end
      if visit(child) then return true end
    end
  end
  return spawnConfig and spawnConfig.partsTree and visit(spawnConfig.partsTree) or false
end

-- Legacy promo fleet: the engines and cars that used to sit in the business fleet move into personal ownership.
local function transferLegacyPackages(id, legacyVehicles)
  local vehicleModels = {}
  for _, vehicle in ipairs(legacyVehicles) do
    vehicleModels[tostring(vehicle.vehicleId)] = (vehicle.vehicleConfig and vehicle.vehicleConfig.model_key)
      or vehicle.model_key or vehicle.model
  end
  local allPackages = overhaul_career_parts_engines_enginePackages.listPackages({ownerType = "business", businessType = config.SHOP_TYPE, businessId = tostring(id)})
  for _, package in ipairs(allPackages) do
    if not package.warehouseStock then
      overhaul_career_parts_engines_enginePackages.transferBusinessPackageToPersonal(package.id,
        vehicleModels[tostring(package.businessVehicleId or package.businessVehicleRef or "")])
    end
  end
end

-- Prefer the business garage; an authored local transform retains historical placement when needed.
local function legacyMigrationSpawn(id)
  local facility = ownerServices.currentFacility(id)
  if not facility then return nil end
  local garage = facility.businessGarageId and overhaul_world_facilities.getFacilityIfExists("businessGarage", facility.businessGarageId)
  local spots = garage and overhaul_world_facilities.getParkingSpotsForFacility(garage) or {}
  local spot = spots[1]
  local pos, rot = spot and spot.pos, spot and spot.rot
  if not pos then
    local spawn = levelData.resolveSpawn(facility.migrationVehicleSpawn, facility.mapId or getCurrentLevelIdentifier())
    pos, rot = spawn and spawn.pos, spawn and spawn.rot
  end
  if not pos or not rot then
    log("W", "engineShop", "Legacy vehicle retained until a local migration spawn is available for " .. tostring(id))
    return nil
  end
  return pos, rot
end

-- Spawns one legacy car as a personal vehicle; returns false when it could not be placed.
local function respawnLegacyVehicle(id, vehicle)
  local model = (vehicle.vehicleConfig and vehicle.vehicleConfig.model_key) or vehicle.model_key or vehicle.model
  local spawnConfig = deepcopy(vehicle.config or {})
  if not spawnConfig.partsTree and vehicle.vehicleConfig and vehicle.vehicleConfig.config then spawnConfig = deepcopy(vehicle.vehicleConfig.config) end
  if vehicle.enginePackageId then
    local migratedPackage = overhaul_career_parts_engines_enginePackages.getPackage(vehicle.enginePackageId)
    if migratedPackage then clearEngineSlot(spawnConfig, migratedPackage.rootSlotName) end
  end
  local pos, rot = legacyMigrationSpawn(id)
  if not pos or not rot then return false end
  local spawned
  if model and spawnConfig then
    local ok, result = pcall(core_vehicles.spawnNewVehicle, model, {config = spawnConfig, autoEnterVehicle = false,
      pos = pos, rot = rot})
    if ok then spawned = result end
  end
  if not spawned then return false end
  local inventoryId = overhaul_career_garage_inventory.addVehicle(spawned:getID(), nil, {owned = true, takesNoInventorySpace = true})
  if not inventoryId then
    spawned:delete()
    return false
  end
  local personal = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  personal.niceName = vehicle.niceName or personal.niceName
  personal.partConditions = deepcopy(vehicle.partConditions or personal.partConditions)
  personal.mileage = vehicle.mileage or personal.mileage
  overhaul_career_business_fleet.removeBusinessVehicleObject(tostring(id), vehicle.vehicleId)
  overhaul_career_business_fleet.removeVehicle(tostring(id), vehicle.vehicleId)
  return true
end

-- Finished engines saved as stock become warehouse packages as space allows; the rest waits for a later update.
local function materializeLegacyStock(id, state)
  for blueprintId, count in pairs(state.legacyFinishedToMaterialize or {}) do
    local blueprint = state.blueprints[tostring(blueprintId)]
    count = math.max(0, math.floor(tonumber(count) or 0))
    while blueprint and count > 0 and ownerServices.warehouseUsed(id, state) < ownerServices.warehouseCapacity(state) do
      local package = createFinishedPackage(id, state, blueprint)
      if not package then break end
      count = count - 1
    end
    state.legacyFinishedToMaterialize[blueprintId] = count
  end
end

local function migratePromoFleet(id, state)
  if not state.migrationPending then return true end
  local legacyVehicles = overhaul_career_business_fleet.getBusinessVehicles(tostring(id)) or {}
  if #legacyVehicles > 0 and not legacyMigrationSpawn(id) then return false end
  transferLegacyPackages(id, legacyVehicles)
  local remaining = {}
  for _, vehicle in ipairs(legacyVehicles) do
    if not respawnLegacyVehicle(id, vehicle) then remaining[#remaining + 1] = vehicle.vehicleId end
  end
  materializeLegacyStock(id, state)
  local stockRemaining = false
  for _, count in pairs(state.legacyFinishedToMaterialize or {}) do if tonumber(count) and tonumber(count) > 0 then stockRemaining = true end end
  state.migrationPending = #remaining > 0 or stockRemaining
  if not state.migrationPending then state.legacyFinishedToMaterialize = nil end
  return not state.migrationPending
end

local function packageCard(package, state)
  local status, installedId, missing = overhaul_career_parts_engines_enginePackages.getPackageStatus(package)
  local freshValue = overhaul_career_parts_engines_enginePackages.getFreshPackageValue(package)
  local certification = deepcopy(package.engineShopCertification)
  local job = state.certificationJobs[tostring(package.id)]
  if certification and certification.status == "pending" and job and not job.completed then
    certification.durationSeconds = config.CERTIFICATION_DURATION_SECONDS
    certification.progressSeconds = math.min(config.CERTIFICATION_DURATION_SECONDS, math.max(0, tonumber(job.progressSeconds) or 0))
    certification.remainingSeconds = math.max(0, certification.durationSeconds - certification.progressSeconds)
  end
  local recipe = overhaul_career_parts_engines_enginePackages.getRecipeFromPackage(package)
  local blueprint = recipe and findBlueprintBySignature(state, recipe.signature)
  return {id = tostring(package.id), name = package.name, engineName = package.rootEngineNiceName or package.rootEngineName,
    status = status, installedInventoryId = installedId, missingCount = missing, stored = status == "stored",
    freshValue = freshValue or 0, certificationFee = math.floor((freshValue or 0) * 0.05 + 0.5),
    certification = certification, certified = blueprint ~= nil and blueprint.certification.status == "passed", blueprintId = blueprint and blueprint.id,
    thumbnail = overhaul_career_parts_engines_enginePackages.getPackageThumbnailPath(package.id),
    dirtyDate = package.thumbnailAt or package.updatedAt or 0}
end

-- Adds a blueprint for a passed engine package that the shop has not recorded yet.
local function reconcileCertifiedPackages(state)
  for _, package in ipairs(overhaul_career_parts_engines_enginePackages.listPackages({ownerType = "personal"})) do
    local certification = package.engineShopCertification
    if certification and certification.status ~= "pending" then
      overhaul_career_parts_engines_engineCertification.refreshAnalysis(certification, overhaul_career_parts_engines_enginePackages.getRecipeFromPackage(package))
    end
    if certification and certification.status == "passed" and certification.recipeSignature and
        not findBlueprintBySignature(state, certification.recipeSignature) then
      local freshValue, recipe = overhaul_career_parts_engines_enginePackages.getFreshPackageValue(package)
      if freshValue and recipe and tostring(recipe.signature) == tostring(certification.recipeSignature) then
        local blueprintId = tostring(state.nextBlueprintId)
        state.nextBlueprintId = state.nextBlueprintId + 1
        state.blueprints[blueprintId] = {id = blueprintId, name = package.name, recipe = recipe,
          recipeSignature = recipe.signature, freshValue = freshValue,
          certification = {status = "passed", analysisVersion = certification.analysisVersion, contentFingerprint = certification.contentFingerprint, peakHorsepower = certification.peakHorsepower, peakTorque = certification.peakTorque,
            rating = certification.rating, torqueLimit = certification.torqueLimit, limiterRpm = certification.limiterRpm, samples = deepcopy(certification.samples or {})},
          listed = false, price = math.max(1, math.floor(freshValue * config.FRESH_VALUE_MARKET_MULTIPLIER + 0.5)), awareness = 0,
          createdAt = certification.completedAt or os.time(), sourcePackageId = tostring(package.id)}
        refreshHardwareIdentity(state.blueprints[blueprintId])
      end
    end
  end
end

-- UI payload -----------------------------------------------------------------------------------------

local function ensureTabsRegistered()
  overhaul_career_business_tabRegistry.clearTabs(config.SHOP_TYPE)
  -- icon: a stock bngIcons glyph name (the sidebar falls back to a neutral glyph for unknown names)
  local tabs = {
    {id = "dashboard", label = "Dashboard", icon = "powerGauge03", section = "ENGINE SHOP"},
    {id = "engines", label = "Engines", icon = "engine", section = "ENGINE SHOP"},
    {id = "myParts", label = "My Parts", icon = "wrench", section = "ENGINE SHOP"},
    {id = "production", label = "Production", icon = "cogs", section = "ENGINE SHOP"},
    {id = "warehouse", label = "Warehouse", icon = "cardboardBox", section = "ENGINE SHOP"},
    {id = "sales", label = "Sales", icon = "shoppingCart", section = "ENGINE SHOP"},
    {id = "upgrades", label = "Upgrades", icon = "arrowsUp", section = "ENGINE SHOP"},
    {id = "finances", label = "Finances", icon = "beamCurrency", section = "ENGINE SHOP"},
    {id = "overview", label = "Overview", icon = "info", section = "REFERENCE"},
  }
  for order, tab in ipairs(tabs) do
    overhaul_career_business_tabRegistry.registerTab(config.SHOP_TYPE, {
      id = tab.id,
      label = tab.label,
      icon = tab.icon,
      component = "EngineShopTab",
      data = {view = tab.id},
      section = tab.section,
      order = order
    })
  end
end

local function blueprintCards(id, state)
  local cards = {}
  for _, blueprint in pairs(state.blueprints) do
    local copy = deepcopy(blueprint)
    copy.finishedCount = #ownerServices.warehousePackages(id, blueprint.id)
    copy.rawCount = state.rawStock[tostring(blueprint.id)] or 0
    copy.landedCost = services.sales.landedCost(blueprint, state.lines)
    copy.marketValue = math.floor((copy.freshValue or 1) * config.FRESH_VALUE_MARKET_MULTIPLIER + 0.5)
    copy.suggestedPrice = math.floor(services.sales.supportedMarketPrice(blueprint, copy.landedCost, state) + 0.5)
    copy.maxSalePrice = services.sales.salePriceLimit(blueprint, copy.landedCost, state)
    local displayPrice = tonumber(copy.price) or copy.suggestedPrice
    if not displayPrice or displayPrice ~= displayPrice or displayPrice == math.huge or displayPrice == -math.huge then
      displayPrice = copy.suggestedPrice
    end
    copy.price = math.max(1, math.min(copy.maxSalePrice, math.floor(displayPrice)))
    copy.estimatedProfit = math.floor(copy.suggestedPrice - copy.landedCost + 0.5)
    copy.saleCycleSeconds = services.sales.saleCycleSeconds(blueprint, copy.landedCost, state)
    cards[#cards + 1] = copy
  end
  table.sort(cards, function(a, b) return tonumber(a.id) < tonumber(b.id) end)
  return cards
end

local function warehouseCards(id, state)
  local finished = {}
  for _, package in ipairs(ownerServices.warehousePackages(id)) do
    local blueprint = state.blueprints[tostring(package.blueprintId or package.productRevisionId)]
    finished[#finished + 1] = {id = tostring(package.id), name = package.name,
      engineName = package.rootEngineNiceName or package.rootEngineName, blueprintId = package.blueprintId or package.productRevisionId,
      thumbnail = package.thumbnail, manufacturedAt = package.manufacturedAt, recipeSignature = package.recipeSignature,
      compatible = localizedVehicle(id) ~= nil, blueprintName = blueprint and blueprint.name}
  end
  return finished
end

local function upgradeCards(state)
  local upgrades = {}
  for key, definition in pairs(capacityUpgrades) do
    upgrades[#upgrades + 1] = {id = key, name = definition.name, cost = ownerServices.indexed(definition.cost), effect = definition.effect,
      requires = definition.requires, owned = state.upgrades[key] == true}
  end
  table.sort(upgrades, function(a, b) return a.cost < b.cost end)
  return upgrades
end

local function lineUpgradeCards()
  local lineUpgrades = {}
  for kind, definition in pairs(lineUpgradeDefs) do
    lineUpgrades[kind] = {id = kind, name = definition.name, costs = {}, descriptions = deepcopy(definition.descriptions)}
    for index, cost in ipairs(definition.costs) do lineUpgrades[kind].costs[index] = ownerServices.indexed(cost) end
  end
  return lineUpgrades
end

local function reservationCards(state)
  local reservations = {}
  for _, reservation in pairs(state.reservations) do reservations[#reservations + 1] = deepcopy(reservation) end
  table.sort(reservations, function(a, b) return tonumber(a.id) < tonumber(b.id) end)
  return reservations
end

-- The sales banner: the listing being sold, its countdown and its current price, or why nothing is selling.
local function salesSnapshot(state, currentSale)
  local listedCount = 0
  for _, blueprint in pairs(state.blueprints) do if blueprint.listed then listedCount = listedCount + 1 end end
  local duration = currentSale and (tonumber(state.salesCycleDurationSeconds) or config.ENGINE_SALE_MAX_SECONDS) or 0
  local progress = currentSale and math.min(duration, math.max(0, tonumber(state.salesCycleProgressSeconds) or 0)) or 0
  local currentPrice = nil
  if currentSale then
    local saleCost = services.sales.landedCost(currentSale, state.lines)
    local saleLimit = services.sales.salePriceLimit(currentSale, saleCost, state)
    local rawSalePrice = tonumber(currentSale.price) or services.sales.supportedMarketPrice(currentSale, saleCost, state)
    if not rawSalePrice or rawSalePrice ~= rawSalePrice or rawSalePrice == math.huge or rawSalePrice == -math.huge then
      rawSalePrice = services.sales.supportedMarketPrice(currentSale, saleCost, state)
    end
    currentPrice = math.max(1, math.min(saleLimit, math.floor(rawSalePrice)))
  end
  return {
    state = currentSale and "selling" or (listedCount > 0 and "waitingForStock" or "notListed"),
    duration = duration,
    progress = progress,
    currentPrice = currentPrice,
  }
end

local function lineCards(state)
  local lines = deepcopy(state.lines)
  for _, line in ipairs(lines) do
    line.progressSeconds = math.max(0, tonumber(line.progressSeconds) or 0)
    line.cycleSeconds = ownerServices.lineDuration(line)
    line.successChance = ownerServices.lineSuccessChance(line)
    line.breakdownChance = ownerServices.lineBreakdownChance(line)
    line.maintenanceDiscount = ownerServices.lineMaintenanceDiscount(line)
  end
  return lines
end

local function getUIData(id)
  id = tostring(id)
  ensureTabsRegistered()
  local state = ownerServices.ensureState(id)
  local _, day, minute = ownerServices.nowWorldMinutes()
  processCertifications(id, state, 0)
  migratePromoFleet(id, state)
  reconcileCertifiedPackages(state)
  local currentSale = services.sales.ensureSalesCycle(id, state)
  local personalPackages = {}
  for _, package in ipairs(overhaul_career_parts_engines_enginePackages.listPackages({ownerType = "personal"})) do personalPackages[#personalPackages + 1] = packageCard(package, state) end
  table.sort(personalPackages, function(a, b) return string.lower(a.name or "") < string.lower(b.name or "") end)
  local blueprints = blueprintCards(id, state)
  local finished = warehouseCards(id, state)
  local upgrades = upgradeCards(state)
  local lineUpgrades = lineUpgradeCards()
  local account = ownerServices.accountFor(id)
  local localVehicle = localizedVehicle(id)
  local reservations = reservationCards(state)
  local sales = salesSnapshot(state, currentSale)
  local lines = lineCards(state)
  return {success = owned(id), businessId = id, businessType = config.SHOP_TYPE, businessName = (ownerServices.currentFacility(id) or {}).name or "Engine shop",
    supplierName = services.supply.supplierName(id),
    tabs = overhaul_career_business_tabRegistry.getTabs(config.SHOP_TYPE), showBusinessAccount = true,
    accountId = account and account.id, balance = account and (overhaul_career_economy_bank.getAccountBalance(account.id) or 0) or 0,
    brandPopularity = state.brandPopularity, packages = personalPackages, blueprints = blueprints, lines = lines,
    salesState = sales.state, salesCurrentBlueprintId = currentSale and tostring(currentSale.id) or nil,
    salesCurrentName = currentSale and currentSale.name or nil, salesCurrentPrice = sales.currentPrice,
    salesCycleSeconds = sales.duration, salesCycleProgressSeconds = sales.progress,
    salesCycleRemainingSeconds = math.max(0, sales.duration - sales.progress),
    lineCapacity = ownerServices.lineCapacity(state), lineUpgrades = lineUpgrades, warehousePackages = finished,
    rawStock = deepcopy(state.rawStock), reservations = reservations, warehouseCapacity = ownerServices.warehouseCapacity(state),
    warehouseUsed = ownerServices.warehouseUsed(id, state), warehouseFree = ownerServices.warehouseCapacity(state) - ownerServices.warehouseUsed(id, state),
    salesHistory = deepcopy(state.salesHistory), upgrades = upgrades, localizedVehicle = localVehicle,
    bayVehicles = localizedVehicles(id),
    dayIndex = day, minuteOfDay = minute, migrationPending = state.migrationPending == true,
    devTools = devConsole.isDevToolsEnabled()}
end

-- Parts ----------------------------------------------------------------------------------------------

services.sales = require("overhaul/career/business/engineShop/sales").new({config = config, host = ownerServices})

services.supply = require("overhaul/career/business/engineShop/supply").new({
  shop = shop, host = ownerServices, owned = owned, generator = generator,
  general = general, parcelManager = parcelManager,
})

-- Lifecycle ------------------------------------------------------------------------------------------

local function resetBusinessForSale(id)
  id = tostring(id)
  local state = shop.states[id]
  if not state then return true end
  local cargoList = parcelManager().getAllCargoCustomFilter(function(cargo)
    return cargo and cargo.data and tostring(cargo.data.engineShopBusinessId or "") == id
  end) or {}
  for _, cargo in ipairs(cargoList) do services.supply.returnCargoToSupplier(cargo, true) end
  for _, package in ipairs(overhaul_career_parts_engines_enginePackages.listPackages({ownerType = "personal"})) do
    if package.engineShopCertification and tostring(package.engineShopCertification.businessId or "") == id then
      overhaul_career_parts_engines_enginePackages.setEngineShopCertification(package.id, nil)
    end
  end
  for _, package in ipairs(overhaul_career_parts_engines_enginePackages.listPackages({ownerType = "business", businessType = config.SHOP_TYPE, businessId = id})) do
    overhaul_career_parts_engines_enginePackages.removeBusinessPackage(package.id)
  end
  overhaul_career_business_partInventory.clearBusinessParts(id)
  overhaul_career_business_fleet.clearBusinessInventory(id)
  shop.states[id] = nil
  if activeBusinessId == id then activeBusinessId = nil end
  services.supply.reset()
  general().requestDeliveryPoiRefresh(true)
  return true
end

local businessObject = {businessType = config.SHOP_TYPE, resaleMultiplier = 1,
  features = {bankAccount = true, inventory = false, finances = true, skillTrees = false, personalVehicle = true,
    xpSystem = false, operatingCosts = false},
  getUIData = getUIData, getLiquidationValue = getLiquidationValue, getMaxPulledOutVehicles = function() return 0 end,
  isVehicleKitLocked = function() return false end, resetBusinessForSale = resetBusinessForSale}

local function openMenu(id)
  id = tostring(id); activeBusinessId = id; ensureTabsRegistered(); migratePromoFleet(id, ownerServices.ensureState(id))
  local computer = capabilities.get("businessComputer")
  if not computer then return false end
  computer.setBusinessContext(config.SHOP_TYPE, id)
  extensions.ui_router.navigate("business-computer", {businessType = config.SHOP_TYPE, businessId = id})
  return true
end

-- Developer tools ------------------------------------------------------------------------------------

-- Each group records a failed check's name; the names come back in the result.
local function checkProductionRules(check, state)
  check(#state.lines == 3 and ownerServices.lineCapacity(state) == 1, "three visible lines and one starting unlock")
  check(ownerServices.warehouseCapacity(state) == 15, "starting warehouse")
  state.upgrades.warehouse1 = true; check(ownerServices.warehouseCapacity(state) == 25, "warehouse I")
  state.upgrades.warehouse2 = true; check(ownerServices.warehouseCapacity(state) == 50, "warehouse II")
  local line = newLine(1)
  check(ownerServices.lineDuration(line) == 900 and ownerServices.lineSuccessChance(line) == 0.90 and ownerServices.lineBreakdownChance(line) == 0.05, "base production")
  local exactCurve = true
  for level = 0, 3 do
    line.upgrades = {speed = level, quality = level, maintenance = level}
    exactCurve = exactCurve and ownerServices.lineDuration(line) == config.LINE_DURATION_SECONDS[level + 1]
      and ownerServices.lineSuccessChance(line) == config.LINE_SUCCESS_CHANCES[level + 1]
      and ownerServices.lineBreakdownChance(line) == config.LINE_BREAKDOWN_CHANCES[level + 1]
  end
  check(exactCurve, "exact production timer and risk curves")
  check(config.CERTIFICATION_DURATION_SECONDS == 600 and config.LINE_OVERHAUL_BASES[1] == 2500
    and config.LINE_OVERHAUL_BASES[2] == 5000 and config.LINE_OVERHAUL_BASES[3] == 10000,
    "exact certification timer and overhaul bases")
  line.upgrades = {speed = 3, quality = 3, maintenance = 3}
  check(ownerServices.lineDuration(line) == 300 and ownerServices.lineSuccessChance(line) == 0.99 and ownerServices.lineBreakdownChance(line) == 0.01 and ownerServices.lineMaintenanceDiscount(line) == 0.40, "level three production")
  local awareness = 50 + 30 * (1 - 50 / 100)
  check(math.abs(awareness - 65) < 0.001, "promotion diminishing returns")
  check(math.floor(10000 * 0.05 + 0.5) == 500, "five percent certification fee")
end

local function checkSalesRules(check, state)
  local testBlueprint = {id = "1", freshValue = 10000, awareness = 0, listed = true}
  state.blueprints[testBlueprint.id] = testBlueprint
  check(math.floor(services.sales.supportedMarketPrice(testBlueprint, 13500, state) + 0.5) == 15525, "fresh-value market anchor with cost protection")
  check(services.sales.salePriceLimit(testBlueprint, 13500, state) == 15525, "new brand cannot charge beyond the saturated timer")
  testBlueprint.price = 15525
  check(services.sales.saleCycleSeconds(testBlueprint, 13500, state) == 900, "supported-price sale takes fifteen minutes")
  testBlueprint.price = 7762
  check(services.sales.saleCycleSeconds(testBlueprint, 13500, state) == 450, "half-price launch discount halves the base interval")
  state.brandPopularity = 100
  testBlueprint.awareness = 100
  testBlueprint.price = math.floor(services.sales.supportedMarketPrice(testBlueprint, 13500, state) + 0.5)
  check(services.sales.saleCycleSeconds(testBlueprint, 13500, state) == 300, "mature supported-price sale takes five minutes")
  local matureLimit = services.sales.salePriceLimit(testBlueprint, 13500, state)
  check(matureLimit == testBlueprint.price * 2, "mature brand can charge twice the supported price")
  testBlueprint.price = 1000000
  check(services.sales.saleCycleSeconds(testBlueprint, 13500, state) == 900, "overpriced saved listing cannot shorten capped interval")
  local savedLimit = services.sales.salePriceLimit(testBlueprint, services.sales.landedCost(testBlueprint, state.lines), state)
  check(services.sales.normalizeBlueprintPrice(testBlueprint, state) and testBlueprint.price == savedLimit, "overpriced saved listing is capped")
end

local function checkSaveMigrations(check, absolute)
  local migrated = normalizeState("migration", {version = 2,
    lines = {{progressMinutes = 240, upgrades = {speed = 0, quality = 0, maintenance = 0}}},
    certificationJobs = {one = {submittedAt = absolute - 30, readyAt = absolute + 30, completed = false}},
    salesCycleProgressSeconds = 450, salesCycleDurationSeconds = 900})
  check(math.abs((migrated.lines[1].progressSeconds or 0) - 450) < 0.001, "production migration preserves progress ratio")
  check(math.abs((migrated.certificationJobs.one.progressSeconds or 0) - 300) < 0.001, "certification migration preserves progress ratio")
  check(math.abs((migrated.salesCycleMigrationRatio or 0) - 0.5) < 0.001, "sales migration preserves progress ratio")
end

local function checkEngineRecipes(check)
  local expectedHourlyProfit = (15500 - ((10000 + 0.05 * 2500) / 0.90)) * 0.90 * 4
  check(expectedHourlyProfit >= 14000 and expectedHourlyProfit <= 17000, "base ten-thousand-dollar engine hourly profit target")
  local stockV8 = recipeCertificationData({vehicleModel = "bluebuck", tree = {name = "bluebuck_engine_v8_423", children = {}}})
  check(stockV8 and #stockV8.samples > 0 and stockV8.peakTorque > 0, "CSV-backed stock V8 torque curve")
  local classicI4 = recipeCertificationData({vehicleModel = "bluebuck", tree = {name = "c_bluebuck_134_engine_flathead_i4", children = {}}})
  check(classicI4 and #classicI4.samples > 0 and classicI4.peakTorque > 0, "CSV-backed classic I4 torque curve")
end

local function runInvariantTests()
  local failures = {}
  local function check(value, name) if not value then failures[#failures + 1] = name end end
  local absolute = ownerServices.nowWorldMinutes()
  local state = normalizeState("test", {version = 3})
  checkProductionRules(check, state)
  checkSalesRules(check, state)
  checkSaveMigrations(check, absolute)
  checkEngineRecipes(check)
  return {success = #failures == 0, failures = failures, checks = 24}
end

local function debugAdvanceCalendar(id, minutes)
  if not devConsole.isDevToolsEnabled() then return devConsole.devToolsDisabledResult() end
  local state = ownerServices.ensureState(id); minutes = math.max(0, tonumber(minutes) or 0)
  local seconds = minutes * 60
  processProduction(id, state, seconds)
  processCertifications(id, state, seconds)
  services.sales.advanceSales(id, state, seconds)
  return {success = true, message = "Advanced Engine Works by " .. tostring(minutes) .. " active minutes."}
end

local function debugForceCertification(id, packageId, passed)
  if not devConsole.isDevToolsEnabled() then return devConsole.devToolsDisabledResult() end
  local state = ownerServices.ensureState(id); local job = state.certificationJobs[tostring(packageId)]
  if not job then return {success = false, message = "Start certification for this package first."} end
  job.result = passed == false and "failed" or "passed"
  job.progressSeconds = config.CERTIFICATION_DURATION_SECONDS
  completeCertification(id, state, tostring(packageId), job)
  return {success = true, message = "Certification result forced."}
end

local function debugForceProduction(id, lineId, success, breakdown)
  if not devConsole.isDevToolsEnabled() then return devConsole.devToolsDisabledResult() end
  local state = ownerServices.ensureState(id); local line = state.lines[tonumber(lineId)]
  if not line or not line.blueprintId then return {success = false, message = "Assign a blueprint first."} end
  if (state.rawStock[tostring(line.blueprintId)] or 0) <= 0 then return {success = false, message = "Add raw material first."} end
  processAttempt(id, state, line, success ~= false, breakdown == true)
  return {success = true, message = "Forced production outcome applied."}
end

local function debugAddRaw(id, blueprintId, quantity)
  if not devConsole.isDevToolsEnabled() then return devConsole.devToolsDisabledResult() end
  local state = ownerServices.ensureState(id); quantity = math.max(1, math.floor(tonumber(quantity) or 1))
  if not state.blueprints[tostring(blueprintId)] then return {success = false, message = "Blueprint not found."} end
  if ownerServices.warehouseUsed(id, state) + quantity > ownerServices.warehouseCapacity(state) then return {success = false, message = "Not enough shared warehouse space."} end
  state.rawStock[tostring(blueprintId)] = (state.rawStock[tostring(blueprintId)] or 0) + quantity
  return {success = true, message = "Debug raw material added."}
end

-- Public API -----------------------------------------------------------------------------------------

-- Owner brief is available before ownership and has no shop-state side effects.
M.getBriefData = function()
  return {
    brandPriceBonus = config.BRAND_PRICE_BONUS_MAX,
    productPriceBonus = config.PRODUCT_PRICE_BONUS_MAX,
    maxSaleSeconds = config.ENGINE_SALE_MAX_SECONDS
  }
end

M.getUIData = getUIData
M.openMenu = openMenu
M.getMaxPulledOutVehicles = function() return 0 end

M.startCertification = startCertification
M.assignLineBlueprint = assignLineBlueprint
M.setLineRunning = setLineRunning
M.purchaseLineUpgrade = purchaseLineUpgrade
M.overhaulLine = overhaulLine
M.setBlueprintListed = services.sales.setBlueprintListed
M.setBlueprintPrice = services.sales.setBlueprintPrice
M.orderRawMaterials = orderRawMaterials
M.junkWarehousePackage = junkWarehousePackage
M.installWarehousePackage = installWarehousePackage
M.purchaseUpgrade = purchaseUpgrade
M.openEnginePackages = openEnginePackages
M.openParts = openParts
M.openMyParts = openMyParts
M.selectBayVehicle = selectBayVehicle
M.openTuning = openTuning
M.openRepair = openRepair

M.getSupplyOfferCard = services.supply.getSupplyOfferCard
M.hasPaidSupplyAt = services.supply.hasPaidSupplyAt
M.getPaidSupplyPickupLocations = services.supply.getPaidSupplyPickupLocations
M.enterSupplyPickupScreen = services.supply.enterSupplyPickupScreen
M.requestSupplyPickupData = services.supply.requestSupplyPickupData
M.loadSupply = services.supply.loadSupply
M.closeSupplyPickupScreen = services.supply.closeSupplyPickupScreen
M.canDeliverSupplyCargo = services.supply.canDeliverSupplyCargo
M.deliverSupplyCargo = services.supply.deliverSupplyCargo
M.returnCargoToSupplier = services.supply.returnCargoToSupplier

M.runInvariantTests = runInvariantTests
M.debugAdvanceCalendar = debugAdvanceCalendar
M.debugForceCertification = debugForceCertification
M.debugForceProduction = debugForceProduction
M.debugAddRaw = debugAddRaw

-- Game hooks -----------------------------------------------------------------------------------------

function M.onRlsFreeroamRaceResultFinalized(payload)
  payload = payload or {}
  if payload.success == false or payload.completed == false or payload.didNotFinish == true then return end
  local inventoryId = payload.vehicleId and overhaul_career_garage_inventory.getInventoryIdFromVehicleId(payload.vehicleId)
  if not inventoryId and payload.vehicleId then
    for candidateId, vehId in pairs(overhaul_career_garage_inventory.getMapInventoryIdToVehId() or {}) do
      if tonumber(vehId) == tonumber(payload.vehicleId) then inventoryId = candidateId break end
    end
  end
  if not inventoryId then return end
  local installed
  for _, package in ipairs(overhaul_career_parts_engines_enginePackages.listPackages({ownerType = "personal"})) do
    if tonumber(package.installedInventoryId) == tonumber(inventoryId) then installed = package break end
  end
  -- A hardware replacement unlinks the old package. Read the raced engine in
  -- that case so a mismatched build still gets an explanation.
  local recipe, recipeReason
  if installed then
    recipe, recipeReason = overhaul_career_parts_engines_enginePackages.getRecipeFromPackage(installed)
  else
    local hasListed = false
    for id, state in pairs(shop.states) do
      if owned(id) then
        for _, blueprint in pairs(state.blueprints) do
          if blueprint.listed then hasListed = true break end
        end
      end
    end
    if not hasListed then return end
    recipe, recipeReason = overhaul_career_parts_engines_enginePackages.getInstalledEngineRecipe(inventoryId)
  end
  local identity, reason = overhaul_career_parts_engines_engineCertification.computeHardwareIdentity(recipe)
  if not identity then
    notify("warning", "Engine promotion unavailable", recipeReason or reason or "Engine hardware could not be identified.")
    return
  end
  local promoted, listed = false, false
  for id, state in pairs(shop.states) do
    if owned(id) then
      for _, blueprint in pairs(state.blueprints) do
        if blueprint.listed then
          listed = true
          if refreshHardwareIdentity(blueprint) == identity then
            promoted = true
            blueprint.awareness = math.min(100, (blueprint.awareness or 0) + 30 * (1 - (blueprint.awareness or 0) / 100))
            notify("success", "Engine promotion complete", string.format("%s awareness increased to %.0f.", blueprint.name, blueprint.awareness))
          end
        end
      end
    end
  end
  if listed and not promoted then
    notify("warning", "Engine promotion unavailable", "Different engine hardware than the certified blueprint.")
  end
end

function M.onCareerActivated()
  services.supply.reset()
  shopZones = {mapId = nil, byBusiness = {}}
  loadData()
  overhaul_career_business_manager.registerBusiness(config.SHOP_TYPE, businessObject, M)
  overhaul_career_business_manager.registerBusinessCallback(config.SHOP_TYPE, {onPurchase = function(id)
    ownerServices.ensureState(id)
    local capital = overhaul_career_business_manager.getPurchaseCapitalInjectionAmount(0)
    if capital > 0 then ownerServices.reward(id, capital, "Capital Injection", "Initial operating capital") end
  end, onMenuOpen = openMenu})
  ensureTabsRegistered()
  overhaul_career_parts_engines_enginePackages.registerPackageReferenceGuard(packageReferenceGuard, config.SHOP_TYPE)
end

function M.onOverhaulSaveCurrentProfile(path)
  if not statesLoaded then loadData() end
  saveData(path)
end

function M.onUpdate(dtReal, dtSim)
  if not overhaul_career_career.isActive() then return end
  local elapsed = math.max(0, tonumber(dtSim) or 0)
  if elapsed <= 0 then return end
  for id, state in pairs(shop.states) do
    if owned(id) then
      processCertifications(id, state, elapsed)
      processProduction(id, state, elapsed)
      state.salesUpdateAccumulatorSeconds = (state.salesUpdateAccumulatorSeconds or 0) + elapsed
      if state.salesUpdateAccumulatorSeconds >= 1 then
        local salesStep = math.floor(state.salesUpdateAccumulatorSeconds)
        state.salesUpdateAccumulatorSeconds = state.salesUpdateAccumulatorSeconds - salesStep
        services.sales.advanceSales(id, state, salesStep)
      end
    end
  end
end

M.activity = require('overhaul/career/business/engineShop/activity')(M)
return M
