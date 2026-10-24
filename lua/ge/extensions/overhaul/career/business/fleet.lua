-- Business fleet records, spawned vehicles, garage spots, saved records and repairs.
-- Read config, state, fleet records, garage helpers, repairs, parts, update, lifecycle, public API, then hooks.
local capabilities = require("overhaul/lib/platform/capabilities")
local M = {}
local businessPartConditions = require('overhaul/lib/business/partConditions')
local saveState = require('overhaul/lib/business/saveState')

M.dependencies = {
  'gameplay_sites_sitesManager',
}

-- Config ------------------------------------------------------------------------------------------

local FLEET_INSURANCE_DEDUCTIBLE = 750

-- State -------------------------------------------------------------------------------------------

-- Activation resets fleet state so records and pending replies cannot leak across careers.
local fleetState = {
  businessVehicles = {},
  pulledOutVehicles = {},
  spawnedBusinessVehicles = {},
  vehicleIdCounters = {},
  fleetRepairsInProgress = {},
  fleetBaselineCaptures = {},
}
-- Config reads waiting for a vehicle's reply, keyed by callback id.
local pendingConfigCallbacks = {}

local parts = {}
local shared = {
  fleetState = fleetState,
  businessPartConditions = businessPartConditions,
  pendingConfigCallbacks = pendingConfigCallbacks,
  parts = parts,
}

-- Shared helpers ----------------------------------------------------------------------------------

function shared.normalizeBusinessId(businessId)
  return tonumber(businessId) or businessId
end

function shared.normalizeVehicleId(vehicleId)
  if vehicleId == nil then
    return nil
  end
  return tonumber(vehicleId) or vehicleId
end

function shared.getSpawnedVehicleId(businessId, vehicleId)
  if not businessId or not vehicleId then
    return nil
  end

  businessId = shared.normalizeBusinessId(businessId)
  vehicleId = tonumber(vehicleId) or vehicleId
  if fleetState.spawnedBusinessVehicles[businessId] and fleetState.spawnedBusinessVehicles[businessId][vehicleId] then
    return fleetState.spawnedBusinessVehicles[businessId][vehicleId]
  end
  return nil
end

function shared.clearCachesForStoredVehicle(businessId, vehicle)
  if not vehicle or vehicle.vehicleId == nil then
    return
  end
  local computer = capabilities.peek("businessComputer")
  if computer then computer.clearBusinessCachesForVehicle(businessId, vehicle.vehicleId) end
end

-- Saved fleet records ---------------------------------------------------------------------------

-- Save file for one business's vehicles; nil outside an active career or without a profile.
local function getBusinessVehiclesPath(businessId)
  if not overhaul_career_career.isActive() then
    return nil
  end
  return saveState.businessFilePath(businessId, "vehicles.json")
end

function shared.loadBusinessVehicles(businessId)
  if not businessId then
    return {}
  end

  businessId = shared.normalizeBusinessId(businessId)
  if fleetState.businessVehicles[businessId] then
    return fleetState.businessVehicles[businessId]
  end

  local filePath = getBusinessVehiclesPath(businessId)
  if not filePath then
    return {}
  end

  local data = jsonReadFile(filePath) or {}
  fleetState.businessVehicles[businessId] = data.vehicles or {}

  for _, vehicle in ipairs(fleetState.businessVehicles[businessId]) do
    if vehicle.vehicleId then
      vehicle.vehicleId = tonumber(vehicle.vehicleId) or vehicle.vehicleId
    end
  end

  local maxId = 0
  for _, vehicle in ipairs(fleetState.businessVehicles[businessId]) do
    local vehId = tonumber(vehicle.vehicleId)
    if vehId and vehId > maxId then
      maxId = vehId
    end
  end
  fleetState.vehicleIdCounters[businessId] = math.max((fleetState.vehicleIdCounters[businessId] or 1), maxId + 1)

  return fleetState.businessVehicles[businessId]
end

local function getNextVehicleId(businessId)
  businessId = shared.normalizeBusinessId(businessId)
  fleetState.vehicleIdCounters[businessId] = fleetState.vehicleIdCounters[businessId] or 1
  local nextId = fleetState.vehicleIdCounters[businessId]
  fleetState.vehicleIdCounters[businessId] = nextId + 1
  return nextId
end

function shared.getBusinessVehicles(businessId)
  return shared.loadBusinessVehicles(businessId)
end

function shared.getVehicleById(businessId, vehicleId)
  if not businessId or not vehicleId then
    return nil
  end

  vehicleId = tonumber(vehicleId) or vehicleId
  local vehicles = shared.loadBusinessVehicles(businessId)

  for _, vehicle in ipairs(vehicles) do
    local vehId = tonumber(vehicle.vehicleId) or vehicle.vehicleId
    if vehId == vehicleId then
      return vehicle
    end
  end

  return nil
end

-- Garage state and parking ----------------------------------------------------------------------

function shared.ensurePulledOutState(businessId)
  businessId = shared.normalizeBusinessId(businessId)
  if not fleetState.pulledOutVehicles[businessId] then
    fleetState.pulledOutVehicles[businessId] = {
      vehicles = {},
      activeVehicleId = nil,
      spotAssignments = {}
    }
  end
  return fleetState.pulledOutVehicles[businessId]
end

function shared.findPulledOutVehicleIndex(state, vehicleId)
  if not state or not state.vehicles then
    return nil
  end
  for index, vehicle in ipairs(state.vehicles) do
    if shared.normalizeVehicleId(vehicle.vehicleId) == vehicleId then
      return index
    end
  end
  return nil
end

function shared.getBusinessGarage(businessType, businessId)
  local business = overhaul_world_facilities.getFacility(businessType, businessId)
  if not business then
    return nil
  end

  if not business.businessGarageId then
    return nil
  end

  local businessGarages = overhaul_world_facilities.getFacilitiesByType("businessGarage")
  if not businessGarages then
    return nil
  end

  for _, garage in ipairs(businessGarages) do
    if garage.id == business.businessGarageId then
      return garage
    end
  end

  return nil
end

function shared.getBusinessGarageParkingSpots(businessType, businessId)
  local garage = shared.getBusinessGarage(businessType, businessId)
  if not garage then
    return {}
  end

  if not garage.sitesFile then
    return {}
  end

  local sites = gameplay_sites_sitesManager.loadSites(garage.sitesFile)
  if not sites or not sites.parkingSpots then
    return {}
  end

  local spots = {}
  for _, spotName in ipairs(garage.parkingSpotNames or {}) do
    local spot = sites.parkingSpots.byName[spotName]
    if spot and not spot.missing then
      table.insert(spots, spot)
    end
  end

  return spots
end

local function getBusinessGaragePosRot(businessType, businessId, veh, spotIndex)
  veh = veh or getPlayerVehicle(0)
  local garage = shared.getBusinessGarage(businessType, businessId)

  if not garage then return nil, nil end
  local parkingSpots = overhaul_world_facilities.getParkingSpotsForFacility(garage)
  if not parkingSpots or #parkingSpots == 0 then
    return nil, nil
  end

  if spotIndex and parkingSpots[spotIndex] then
    local spot = parkingSpots[spotIndex]
    return spot.pos, spot.rot
  end

  if not veh then
    local spot = parkingSpots[1]
    if spot then
      return spot.pos, spot.rot
    end
    return nil, nil
  end

  local parkingSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(veh:getID(), parkingSpots)
  if parkingSpot then
    return parkingSpot.pos, parkingSpot.rot
  end

  return parkingSpots[1].pos, parkingSpots[1].rot
end

-- Active vehicles and stored records ------------------------------------------------------------

local function getPulledOutVehicles(businessId)
  businessId = shared.normalizeBusinessId(businessId)
  local state = fleetState.pulledOutVehicles[businessId]
  if not state or not state.vehicles then
    return {}
  end
  return state.vehicles
end

local function getActiveVehicle(businessId)
  businessId = shared.normalizeBusinessId(businessId)
  local state = fleetState.pulledOutVehicles[businessId]
  if not state or not state.vehicles then
    return nil
  end
  if state.activeVehicleId then
    local index = shared.findPulledOutVehicleIndex(state, state.activeVehicleId)
    if index then
      return state.vehicles[index]
    end
  end
  return state.vehicles[1]
end

local function setActiveVehicle(businessId, vehicleId)
  if not businessId or not vehicleId then
    return false
  end
  businessId = shared.normalizeBusinessId(businessId)
  local state = fleetState.pulledOutVehicles[businessId]
  if not state then
    return false
  end
  local normalizedId = shared.normalizeVehicleId(vehicleId)
  local index = shared.findPulledOutVehicleIndex(state, normalizedId)
  if not index then
    return false
  end
  state.activeVehicleId = normalizedId
  return true
end

local function getPulledOutVehicle(businessId)
  return getActiveVehicle(businessId)
end

local function removeVehicle(businessId, vehicleId)
  if not businessId or not vehicleId then
    return false
  end

  businessId = shared.normalizeBusinessId(businessId)
  vehicleId = tonumber(vehicleId) or vehicleId
  local vehicles = shared.loadBusinessVehicles(businessId)

  for i, vehicle in ipairs(vehicles) do
    local vehId = tonumber(vehicle.vehicleId) or vehicle.vehicleId
    if vehId == vehicleId then
      table.remove(vehicles, i)
      fleetState.businessVehicles[businessId] = vehicles
      return true
    end
  end

  return false
end

local function storeVehicle(businessId, vehicleData)
  if not businessId or not vehicleData then
    return false
  end

  businessId = shared.normalizeBusinessId(businessId)
  local vehicles = shared.loadBusinessVehicles(businessId)

  local vehicleId = vehicleData.vehicleId
  if vehicleId == nil then
    vehicleId = getNextVehicleId(businessId)
  end
  vehicleId = tonumber(vehicleId) or vehicleId
  if type(vehicleId) == "number" then
    local nextId = vehicleId + 1
    fleetState.vehicleIdCounters[businessId] = math.max(fleetState.vehicleIdCounters[businessId] or nextId, nextId)
  end
  vehicleData.vehicleId = vehicleId
  vehicleData.storedTime = os.time()

  table.insert(vehicles, vehicleData)
  fleetState.businessVehicles[businessId] = vehicles

  return true, vehicleId
end

local function updateVehicle(businessId, vehicleId, vehicleData)
  if not businessId or not vehicleId or not vehicleData then
    return false
  end

  vehicleId = tonumber(vehicleId) or vehicleId
  local vehicles = shared.loadBusinessVehicles(businessId)

  for _, vehicle in ipairs(vehicles) do
    local vehId = tonumber(vehicle.vehicleId) or vehicle.vehicleId
    if vehId == vehicleId then
      for key, value in pairs(vehicleData) do
        vehicle[key] = value
      end
      fleetState.businessVehicles[businessId] = vehicles
      return true
    end
  end

  return false
end

local function getBusinessJobIdentifier(businessId, jobId)
  return "business_" .. tostring(businessId) .. "_job_" .. tostring(jobId)
end

local function getJobIdFromVehicle(businessId, vehicleId)
  if not businessId or not vehicleId then
    return nil
  end

  vehicleId = tonumber(vehicleId) or vehicleId
  local vehicle = shared.getVehicleById(businessId, vehicleId)
  if vehicle and vehicle.jobId then
    return vehicle.jobId
  end
  return nil
end

local function getInventoryVehicleIdForJobId(businessId, jobId)
  if not businessId or not jobId then
    return nil
  end
  local want = tonumber(jobId) or jobId
  local vehicles = shared.getBusinessVehicles(businessId) or {}
  for _, v in ipairs(vehicles) do
    if v.jobId ~= nil then
      local vj = tonumber(v.jobId) or v.jobId
      if vj == want or tostring(v.jobId) == tostring(jobId) then
        return tonumber(v.vehicleId) or v.vehicleId
      end
    end
  end
  return nil
end

-- Inventory ids -----------------------------------------------------------------------------------

-- Records a spawned fleet vehicle the career inventory knows about, and returns its business and fleet id.
local function recordSpawnedVehicle(businessId, fleetVehicleId, spawnedVehicleId)
  if not fleetState.spawnedBusinessVehicles[businessId] then
    fleetState.spawnedBusinessVehicles[businessId] = {}
  end
  fleetState.spawnedBusinessVehicles[businessId][fleetVehicleId] = spawnedVehicleId
  return businessId, fleetVehicleId
end

-- Inventory ids for job vehicles look like business_<businessId>_job_<jobId>.
local function resolveJobInventoryId(rest)
  local businessText, jobText = rest:match("^(.+)_job_(.+)$")
  if not (businessText and jobText) then
    return nil, nil
  end
  local businessId = shared.normalizeBusinessId(businessText)
  local wantJob = tonumber(jobText) or jobText
  for _, vehicle in ipairs(shared.getBusinessVehicles(businessId)) do
    if vehicle.jobId ~= nil then
      local vehJob = tonumber(vehicle.jobId) or vehicle.jobId
      if vehJob == wantJob then
        return businessId, tonumber(vehicle.vehicleId) or vehicle.vehicleId
      end
    end
  end
  return nil, nil
end

-- Inventory ids for other fleet vehicles look like business_<businessId>_<vehicleId>.
local function resolveVehicleInventoryId(rest)
  local underscorePos
  for i = #rest, 1, -1 do
    if rest:sub(i, i) == "_" and rest:sub(i + 1):match("^%d+$") then
      underscorePos = i
      break
    end
  end
  if not underscorePos then
    return nil, nil
  end
  local candidateBusinessId = shared.normalizeBusinessId(rest:sub(1, underscorePos - 1))
  local candidateVehicleId = tonumber(rest:sub(underscorePos + 1))
  if candidateBusinessId and candidateVehicleId and shared.getVehicleById(candidateBusinessId, candidateVehicleId) then
    return candidateBusinessId, candidateVehicleId
  end
  return nil, nil
end

local function tryResolveBusinessVehicleFromCareerInventory(spawnedVehicleId)
  if not spawnedVehicleId then
    return nil, nil
  end
  if not overhaul_career_career.isActive() then
    return nil, nil
  end
  local invId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(spawnedVehicleId)
  if not invId or type(invId) ~= "string" or invId:sub(1, 9) ~= "business_" then
    return nil, nil
  end

  local rest = invId:sub(10)
  local businessId, fleetVehicleId
  if rest:find("_job_", 1, true) then
    businessId, fleetVehicleId = resolveJobInventoryId(rest)
  else
    businessId, fleetVehicleId = resolveVehicleInventoryId(rest)
  end
  if not businessId or not fleetVehicleId then
    return nil, nil
  end
  return recordSpawnedVehicle(businessId, fleetVehicleId, spawnedVehicleId)
end

local function getBusinessVehicleFromSpawnedId(spawnedVehicleId)
  if not spawnedVehicleId then
    return nil, nil
  end

  for businessId, vehicles in pairs(fleetState.spawnedBusinessVehicles) do
    for vehicleId, spawnedId in pairs(vehicles) do
      if spawnedId == spawnedVehicleId then
        return businessId, vehicleId
      end
    end
  end

  return tryResolveBusinessVehicleFromCareerInventory(spawnedVehicleId)
end

local function resolveFreeroamLeaderboardInventoryId(spawnedVehicleId)
  if not spawnedVehicleId then
    return spawnedVehicleId
  end
  local businessId, vehicleId = getBusinessVehicleFromSpawnedId(spawnedVehicleId)
  if businessId and vehicleId then
    return parts.putAway.getBusinessVehicleIdentifier(businessId, vehicleId)
  end
  if overhaul_career_career.isActive() then
    return overhaul_career_garage_inventory.getInventoryIdFromVehicleId(spawnedVehicleId) or spawnedVehicleId
  end
  return spawnedVehicleId
end

-- Repairs -----------------------------------------------------------------------------------------

-- Charges the insurance deductible; returns a failure result when the business cannot pay it.
local function chargeInsuranceDeductible(businessType, businessId, cost)
  local account = overhaul_career_economy_bank.getBusinessAccount(businessType, businessId)
  if not account then
    return {success = false, errorCode = "noAccount"}
  end
  local paid = overhaul_career_economy_bank.payFromAccount({
    money = {amount = cost, canBeNegative = false},
  }, account.id, "Fleet insurance", "Vehicle repair deductible", {category = "insurance"})
  if not paid then
    return {success = false, errorCode = "noFunds", cost = cost}
  end
  return nil
end

local function refundInsuranceDeductible(businessType, businessId, cost)
  if cost <= 0 then
    return
  end
  local account = overhaul_career_economy_bank.getBusinessAccount(businessType, businessId)
  if account then
    overhaul_career_economy_bank.rewardToAccount({money = {amount = cost}}, account.id, "Refund", "Repair failed", {category = "refund"})
  end
end

-- A spawned vehicle is repaired in place; its baseline is captured again once it is back.
local function repairSpawnedForInsurance(businessId, vehicleId, vehicle, businessType, cost)
  vehicle.fleetRepairBaselinePending = true
  local previousConditions = vehicle.partConditions
  vehicle.partConditions = nil
  if parts.condition.repairSpawnedBusinessVehicle(businessId, vehicleId) then
    return nil
  end
  vehicle.partConditions = previousConditions
  vehicle.fleetRepairBaselinePending = nil
  fleetState.fleetRepairsInProgress[vehicle] = nil
  refundInsuranceDeductible(businessType, businessId, cost)
  return {success = false, errorCode = "repairFailed", cost = cost}
end

-- A stored (not spawned) vehicle is repaired by clearing its conditions; the next spawn captures them.
local function repairStoredForInsurance(businessId, vehicleId, vehicle, businessType, cost)
  local stored = shared.getVehicleById(businessId, vehicleId)
  if not stored then
    refundInsuranceDeductible(businessType, businessId, cost)
    return {success = false, errorCode = "noVehicle"}
  end
  stored.partConditions = nil
  stored.fleetRepairBaselinePending = true
  fleetState.fleetRepairsInProgress[vehicle] = nil
  shared.clearCachesForStoredVehicle(businessId, stored)
  return nil
end

-- Parts -------------------------------------------------------------------------------------------

for _, name in ipairs({"condition", "garage", "putAway", "persistence"}) do
  parts[name] = require("overhaul/career/business/fleet/" .. name).new(shared)
end

-- Update ------------------------------------------------------------------------------------------

-- Samples a spawned vehicle's part conditions after a short settle, once per capture.
local function onUpdate(dtReal, dtSim)
  parts.persistence.onUpdate(dtReal)
  for vehicle, capture in pairs(fleetState.fleetBaselineCaptures) do
    local sid = shared.getSpawnedVehicleId(capture.businessId, vehicle.vehicleId)
    local vehObj = sid and getObjectByID(sid)
    if not vehicle.fleetRepairBaselinePending or sid ~= capture.spawnedId or not vehObj then
      fleetState.fleetBaselineCaptures[vehicle] = nil
      fleetState.fleetRepairsInProgress[vehicle] = nil
    else
      local dt = math.max(0, dtSim or 0)
      capture.elapsed = capture.elapsed + dt
      capture.quiet = capture.quiet + dt
      capture.interval = capture.interval + dt
      if capture.elapsed >= 3 and capture.interval >= 0.5 and not capture.awaiting then
        capture.interval = 0
        capture.awaiting = true
        parts.condition.sampleFleetRepairBaseline(capture.businessId, vehicle, vehObj)
      end
    end
  end
end

-- Lifecycle ---------------------------------------------------------------------------------------

local function onCareerActivated()
  parts.persistence.cancel()
  fleetState.businessVehicles = {}
  fleetState.pulledOutVehicles = {}
  fleetState.spawnedBusinessVehicles = {}
  fleetState.vehicleIdCounters = {}
  fleetState.fleetRepairsInProgress = {}
  fleetState.fleetBaselineCaptures = {}
end

-- Public API --------------------------------------------------------------------------------------

-- Damage since the repair baseline; zero while a repair or baseline capture is still pending.
function M.getFleetRepairDamage(businessId, vehicleId, damage)
  local vehicle = shared.getVehicleById(shared.normalizeBusinessId(businessId), vehicleId)
  if vehicle and (fleetState.fleetRepairsInProgress[vehicle] or vehicle.fleetRepairBaselinePending) then return 0 end
  return math.max(0, (tonumber(damage) or 0) - (vehicle and tonumber(vehicle.fleetRepairBaselineDamage) or 0))
end

-- Whether a stored vehicle has a part-condition snapshot, and whether that snapshot looks damaged.
function M.getSavedPartConditionFlags(vehicle)
  local hasSnapshot = false
  local looksDamaged = false
  local partConditions = vehicle and vehicle.partConditions
  if type(partConditions) ~= "table" then
    return false, false
  end
  for _ in pairs(partConditions) do
    hasSnapshot = true
    break
  end
  if not hasSnapshot then
    return false, false
  end
  local baseline = vehicle.fleetRepairBaseline or {}
  for partId, cond in pairs(partConditions) do
    if type(cond) == "table" then
      local iv = tonumber(cond.integrityValue)
      local base = baseline[partId]
      local baseIntegrity = type(base) == "table" and tonumber(base.integrityValue) or 1
      if iv ~= nil and iv < (baseIntegrity or 1) - 0.001 then
        looksDamaged = true
        break
      end
      local vs = cond.visualState
      local baseVisual = type(base) == "table" and base.visualState
      local baseReplacement = type(baseVisual) == "table" and type(baseVisual.jbeam) == "table" and baseVisual.jbeam.needsReplacement
      if type(vs) == "table" and type(vs.jbeam) == "table" and vs.jbeam.needsReplacement
        and not baseReplacement and (baseIntegrity or 1) > 0.001 then
        looksDamaged = true
        break
      end
    end
  end
  return hasSnapshot, looksDamaged
end

-- Fleet records
M.getBusinessVehicles = shared.getBusinessVehicles
M.storeVehicle = storeVehicle
M.removeVehicle = removeVehicle
M.getVehicleById = shared.getVehicleById
M.updateVehicle = updateVehicle
M.getBusinessGarage = shared.getBusinessGarage
M.getBusinessGarageParkingSpots = shared.getBusinessGarageParkingSpots
M.getBusinessGaragePosRot = getBusinessGaragePosRot
M.getBusinessJobIdentifier = getBusinessJobIdentifier
M.getJobIdFromVehicle = getJobIdFromVehicle
M.getInventoryVehicleIdForJobId = getInventoryVehicleIdForJobId
M.getBusinessVehicleFromSpawnedId = getBusinessVehicleFromSpawnedId
M.resolveFreeroamLeaderboardInventoryId = resolveFreeroamLeaderboardInventoryId
M.getSpawnedVehicleId = shared.getSpawnedVehicleId

-- Saved as a no-op: vehicles are written by onOverhaulSaveCurrentProfile. Painting still calls it.
function M.saveBusinessVehicles()
end

-- Pulled-out vehicles and garage placement
M.pullOutVehicle = parts.garage.pullOutVehicle
M.putAwayVehicle = parts.putAway.putAwayVehicle
M.getPulledOutVehicle = getPulledOutVehicle
M.getPulledOutVehicles = getPulledOutVehicles
M.getActiveVehicle = getActiveVehicle
M.setActiveVehicle = setActiveVehicle
M.spawnBusinessVehicle = parts.garage.spawnBusinessVehicle
M.teleportToBusinessGarage = parts.garage.teleportToBusinessGarage
M.removeBusinessVehicleObject = parts.garage.removeBusinessVehicleObject
M.clearBusinessInventory = parts.garage.clearBusinessInventory
M.registerFleetVehicleDeliveredDriveIn = parts.garage.registerFleetVehicleDeliveredDriveIn
M.teleportSpawnedBusinessVehicleToSpot = parts.putAway.teleportSpawnedBusinessVehicleToSpot
M.deliverFleetVehicleAtPurchase = parts.putAway.deliverFleetVehicleAtPurchase
M.requestFleetVehicleStatsRead = parts.putAway.requestFleetVehicleStatsRead
M.emergencyRespawnPulledOutVehicle = parts.putAway.emergencyRespawnPulledOutVehicle
M.getBusinessVehicleIdentifier = parts.putAway.getBusinessVehicleIdentifier
M.persistSpawnedFleetVehiclePartConditions = parts.putAway.persistSpawnedVehiclePartConditions

-- Condition and repair
M.repairSpawnedBusinessVehicle = parts.condition.repairSpawnedBusinessVehicle
M.primeFleetRepairSnapshots = parts.condition.primeFleetRepairSnapshots

-- Whether a fleet vehicle needs an insurance-style repair, and the deductible it would cost.
function M.getFleetInsuranceRepairQuote(businessId, vehicleId)
  businessId = shared.normalizeBusinessId(businessId)
  vehicleId = tonumber(vehicleId) or vehicleId
  local vehicle = shared.getVehicleById(businessId, vehicleId)
  if not vehicle then
    return nil
  end
  local _, looksDamaged = M.getSavedPartConditionFlags(vehicle)
  local sid = shared.getSpawnedVehicleId(businessId, vehicleId)
  local liveDamage = sid and map.objects[sid] and map.objects[sid].damage
  if vehicle.fleetRepairBaseline and liveDamage then
    looksDamaged = looksDamaged or M.getFleetRepairDamage(businessId, vehicleId, liveDamage) >= 1500
  end
  return {
    needsRepair = looksDamaged == true and not fleetState.fleetRepairsInProgress[vehicle] and not vehicle.fleetRepairBaselinePending,
    deductible = FLEET_INSURANCE_DEDUCTIBLE,
  }
end

function M.repairFleetVehicleInsuranceStyle(businessId, vehicleId, businessType)
  businessId = shared.normalizeBusinessId(businessId)
  vehicleId = tonumber(vehicleId) or vehicleId
  local quote = M.getFleetInsuranceRepairQuote(businessId, vehicleId)
  if not quote or not quote.needsRepair then
    return {success = false, errorCode = "nothingToRepair"}
  end
  if not businessType then
    return {success = false, errorCode = "unknownBusiness"}
  end
  local cost = math.max(0, math.floor(tonumber(quote.deductible) or FLEET_INSURANCE_DEDUCTIBLE))
  local vehicle = shared.getVehicleById(businessId, vehicleId)
  fleetState.fleetRepairsInProgress[vehicle] = true
  if cost > 0 then
    local failure = chargeInsuranceDeductible(businessType, businessId, cost)
    if failure then
      fleetState.fleetRepairsInProgress[vehicle] = nil
      return failure
    end
  end

  local failure
  if shared.getSpawnedVehicleId(businessId, vehicleId) then
    failure = repairSpawnedForInsurance(businessId, vehicleId, vehicle, businessType, cost)
  else
    failure = repairStoredForInsurance(businessId, vehicleId, vehicle, businessType, cost)
  end
  if failure then
    return failure
  end

  ui_message(string.format("Vehicle repaired. Insurance deductible: $%d.", cost), 5, "Business Computer", "info")
  overhaul_career_saveSystem.saveCurrent()
  return {success = true, cost = cost}
end

-- Game hooks --------------------------------------------------------------------------------------

M.onUpdate = onUpdate
M.onCareerActivated = onCareerActivated

-- Fleet repair baseline replies from the vehicle, and per-frame baseline sampling.
function M.onFleetRepairBaseline(businessId, vehicleId, spawnedId, conditions, damage)
  businessId = shared.normalizeBusinessId(businessId)
  vehicleId = tonumber(vehicleId) or vehicleId
  local vehicle = shared.getVehicleById(businessId, vehicleId)
  local capture = vehicle and fleetState.fleetBaselineCaptures[vehicle]
  if not capture or not vehicle.fleetRepairBaselinePending or capture.spawnedId ~= spawnedId
    or shared.getSpawnedVehicleId(businessId, vehicleId) ~= spawnedId or type(conditions) ~= "table" then return end
  capture.awaiting = nil
  damage = math.max(0, tonumber(damage) or 0)
  -- Spawn breakgroups must finish; mileage and paint do not measure new damage.
  if not capture.conditions or not parts.condition.sameFleetDamageState(conditions, capture.conditions)
    or math.abs(damage - capture.damage) > 1 then
    capture.quiet = 0
  end
  capture.conditions, capture.damage = deepcopy(conditions), damage
  if capture.quiet < 1 then return end
  vehicle.partConditions = deepcopy(conditions)
  vehicle.fleetRepairBaseline = deepcopy(conditions)
  vehicle.fleetRepairBaselineDamage = math.max(0, tonumber(damage) or 0)
  vehicle.fleetRepairBaselinePending = nil
  fleetState.fleetRepairsInProgress[vehicle] = nil
  fleetState.fleetBaselineCaptures[vehicle] = nil
  overhaul_career_saveSystem.saveCurrent()
end

M.onOverhaulSaveCurrentProfile = parts.persistence.save
M.onOverhaulBeforeSetProfile = parts.persistence.cancel
M.onExtensionUnloaded = parts.persistence.cancel

function M.onVehicleConfigReceived(callbackId, config)
  local callbackData = pendingConfigCallbacks[callbackId]
  if not callbackData then
    return
  end

  pendingConfigCallbacks[callbackId] = nil

  local businessId = callbackData.businessId
  local vehicleId = callbackData.vehicleId

  if not config then
    return
  end

  updateVehicle(businessId, vehicleId, {
    config = config,
    vars = config.vars
  })
end

return M
