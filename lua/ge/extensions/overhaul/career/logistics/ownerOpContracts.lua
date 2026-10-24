-- Owner-operator contracts. Map: config and state, catalog/generation/acceptance/escrow parts, save and update, public API, hooks.
-- Read remapRestoredHubProofIds, rekey, onOwnerOpCargoDelivered, onOwnerOpVehicleDelivered, copySaveRecord in order.

local M = {}

local balance = require("overhaul/lib/logistics/logisticsBalance")

-- Config
local logTag = "ownerOpContracts"
local DISTRIBUTOR_MAX_CONTRACT_CARS = 10
local DISTRIBUTOR_LOGISTIC_TYPE = "vehDeliveryNew"
local DISTRIBUTOR_FILTER_ID = "newVehDistributorFilter"
-- Kept as save/UI kind id; any vehicleDistributor facility can generate these.
local CAR_HAUL_KIND = "finkHaul"
local STORAGE_VERSION = 1
-- V3 distinguishes newly scaled offers from V2 quotes saved before the pay raise.
local QUOTE_VERSION = 3
local UPDATE_INTERVAL_S = 0.5

-- State
-- Contract board, the active contract and the last generation time. Saved with the career.
local state = {
  contracts = {},
  active = nil,
  lastGenAt = 0,
}
-- Not saved: a removed obsolete hub contract is announced on the next tick.
local obsoleteHubContractNotice = false

-- Parts
-- Built in dependency order: catalog, then generation, acceptance and escrow. Each receives only the inputs it reads; overhaul_career_* globals are read at call time.
local parts = {}
parts.catalog = require("overhaul/career/logistics/ownerOpContracts/catalog").new({
  balance = balance,
  distributorLogisticType = DISTRIBUTOR_LOGISTIC_TYPE,
  distributorFilterId = DISTRIBUTOR_FILTER_ID,
  getParcelTemplates = require("overhaul/lib/logistics/templates").loadParcelTemplates,
})
parts.generation = require("overhaul/career/logistics/ownerOpContracts/generation").new({
  state = state,
  catalog = parts.catalog,
  balance = balance,
  maxContractCars = DISTRIBUTOR_MAX_CONTRACT_CARS,
  carHaulKind = CAR_HAUL_KIND,
  quoteVersion = QUOTE_VERSION,
})
parts.acceptance = require("overhaul/career/logistics/ownerOpContracts/acceptance").new({
  state = state,
  catalog = parts.catalog,
  generation = parts.generation,
  logTag = logTag,
  distributorLogisticType = DISTRIBUTOR_LOGISTIC_TYPE,
  carHaulKind = CAR_HAUL_KIND,
})
parts.escrow = require("overhaul/career/logistics/ownerOpContracts/escrow").new({
  state = state,
  balance = balance,
  catalog = parts.catalog,
  generation = parts.generation,
  acceptance = parts.acceptance,
  logTag = logTag,
})

-- Reload and delivery hooks
-- Persistence assigns fresh native IDs on reload to avoid colliding with generated freight. Rebind only the current load's identity proof; the accepted quote and credited totals stay.
function M.remapRestoredHubProofIds(cargoIds, offerIds, sourceIds)
  if not parts.escrow.isHubContract() or state.active.phase ~= "dropoff" or not state.active.loadProof then return end
  local proof = state.active.loadProof
  cargoIds = cargoIds or {}
  offerIds = offerIds or {}
  sourceIds = sourceIds or cargoIds
  local function rekey(entries, ids)
    local result = {}
    for oldId, value in pairs(entries or {}) do
      local newId = ids[tostring(oldId)]
      if newId ~= nil then result[tostring(newId)] = value end
    end
    return result
  end
  proof.cargo = rekey(proof.cargo, sourceIds)
  proof.trailers = rekey(proof.trailers, offerIds)
  proof.creditedByCargo = rekey(proof.creditedByCargo, sourceIds)
  proof.completedCargo = rekey(proof.completedCargo, sourceIds)
  local oldDelivered = proof.delivered
  proof.delivered = rekey(oldDelivered, cargoIds)
  for key, value in pairs(rekey(oldDelivered, offerIds)) do
    proof.delivered[key] = value
  end
end

function M.onOwnerOpCargoDelivered(cargoItems)
  for _, cargo in ipairs(cargoItems or {}) do
    if not parts.escrow.isHubContract() then break end
    if parts.escrow.hubCargoMatches(cargo, cargo.location and cargo.location.facId) then
      local rewards = cargo.adjustedRewards or cargo.rewards or {}
      parts.escrow.creditHubDelivery(cargo.id, cargo.data and cargo.data.ownerOpSourceCargoId, cargo.location.facId,
        tonumber(cargo.slots) or 0, false, rewards.money)
    end
  end
end

function M.onOwnerOpVehicleDelivered(items)
  for _, item in ipairs(items or {}) do
    if not parts.escrow.isHubContract() then break end
    local offer = item.offer or item
    local dest = offer and (offer.destination or (offer.task and offer.task.destination))
    if offer and offer.data and offer.data.type == "trailer" then
      local rewards = item.adjustedRewards or offer.rewards or {}
      parts.escrow.creditHubDelivery(offer.id, nil, dest and dest.facId, 1, true, rewards.money)
    end
  end
end

-- Save shape
local function copySaveRecord(record, forSave)
  if not forSave then return deepcopy(record) end
  local copy = {}
  for key, value in pairs(record) do copy[key] = value end
  return copy
end

-- Car-haul vehicles are saved in their compact form; other records have no vehicle list.
local function serializeCarHaulVehicles(copy)
  if copy.kind ~= "finkHaul" or type(copy.vehicles) ~= "table" then return end
  local vehicles = {}
  for _, veh in ipairs(copy.vehicles) do
    table.insert(vehicles, parts.catalog.serializeVehicle(veh))
  end
  copy.vehicles = vehicles
end

local function serializeContractRecord(contract, forSave)
  if not contract or not contract.id then return nil end
  local copy = copySaveRecord(contract, forSave)
  serializeCarHaulVehicles(copy)
  return copy
end

-- A save drops spawn and pending-offer state: those belong to the running session.
local function serializeActiveRecord(forSave)
  if not state.active then return nil end
  local copy = copySaveRecord(state.active, forSave)
  copy.spawning = nil
  copy.pendingOfferIds = nil
  serializeCarHaulVehicles(copy)
  return copy
end

local function serialize(forSave)
  local savedContracts = {}
  for id, contract in pairs(state.contracts) do
    local copy = serializeContractRecord(contract, forSave)
    if copy then
      savedContracts[id] = copy
    end
  end
  return {
    version = STORAGE_VERSION,
    contracts = savedContracts,
    active = serializeActiveRecord(forSave),
    lastGenAt = state.lastGenAt,
  }
end
M.serialize = serialize

function M.abandonBrokerContract(id)
  if not state.active or state.active.id ~= id then return false end
  local broker = overhaul_career_logistics_broker
  if not broker or not broker.jobForNative("cars", id) then return false end
  local tasks = overhaul_career_logistics_vehicleTasks
  for _, task in ipairs(tasks.getVehicleTasks()) do
    if task.offer.data and task.offer.data.finkContractId == id then tasks.giveBackDeliveryVehicle(task.vehId) end
  end
  state.contracts[id] = nil
  state.active = nil
  return true
end

-- Restores the saved board and active contract, then reconciles them with what the current catalog allows.
local function setup(savedState)
  state.contracts = {}
  state.active = nil
  state.lastGenAt = 0
  obsoleteHubContractNotice = false

  if type(savedState) == "table" then
    state.lastGenAt = tonumber(savedState.lastGenAt) or 0
    if type(savedState.contracts) == "table" then
      for id, contract in pairs(savedState.contracts) do
        if type(contract) == "table" then
          local copy = deepcopy(contract)
          copy.id = copy.id or id
          state.contracts[copy.id] = copy
        end
      end
    end
    if type(savedState.active) == "table" and savedState.active.id then
      state.active = deepcopy(savedState.active)
      state.active.logisticType = state.active.logisticType or (state.contracts[state.active.id] and state.contracts[state.active.id].logisticType)
      if parts.escrow.isHubContract() and parts.catalog.isVehicleHaulLogisticType(state.active.logisticType) then
        -- Old catalogs offered vehicle types as parcel hub contracts; they cannot resume as hub work.
        state.contracts[state.active.id] = nil
        state.active = nil
        obsoleteHubContractNotice = true
      elseif parts.escrow.isHubContract() and state.active.phase == "dropoff" and not state.active.loadProof then
        -- An old proximity-only pickup has no cargo identity to verify, so the load is required again.
        state.active.phase = "pickup"
      end
      if state.active then
        if state.active.stringMode and not state.active.deliveredByStop and state.active.loadProof then
          state.active.deliveredByStop = deepcopy(state.active.loadProof.deliveredByStop or {})
        end
        state.active.spawning = nil
        state.active.pendingOfferIds = nil
        if state.active.kind == "finkHaul" then
          state.active.escrowedRewards = state.active.escrowedRewards or {}
          state.active.escrowedMoney = math.floor(tonumber(state.active.escrowedMoney) or tonumber(state.active.escrowedRewards.money) or 0)
          for _, veh in ipairs(state.active.vehicles or {}) do
            if veh.logisticsBonusIncluded == nil then
              -- Pre-balance saves have no basePay; early balance saves have it.
              veh.logisticsBonusIncluded = veh.basePay ~= nil
            end
          end
        end
      end
    end
  end

  if not next(state.contracts) and not state.active then
    parts.generation.rebuildContracts(true)
    return
  end

  parts.escrow.reconcileCarHaulAfterLoad()
end
M.setup = setup

-- Per-frame update
local updateTimer = 0
local function onUpdate(dt)
  if obsoleteHubContractNotice then
    obsoleteHubContractNotice = false
    ui_message("An obsolete vehicle hub contract was removed. Choose a current car-hauling job instead.", 8, "warning")
  end
  if not state.active then return end
  updateTimer = updateTimer + (tonumber(dt) or 0)
  if updateTimer < UPDATE_INTERVAL_S then return end
  updateTimer = 0
  if parts.escrow.isHubContract() and parts.catalog.materialTemplate(state.active.logisticType)
    and not state.active.materialAmountRequired then
    -- Old saves recorded material trips without an executable native order.
    local previous = state.active
    local contract = deepcopy(previous)
    contract.trips = math.max(1, (previous.tripsRequired or 1) - (previous.tripsCompleted or 0))
    if not parts.acceptance.acceptBps(contract) then return end
    state.active.nativeMoney = previous.nativeMoney
  end
  parts.escrow.advanceBpsIfNear()
  parts.escrow.trackCarHaulDeliveries()
end

-- Public API
M.listContracts = parts.acceptance.listContracts
M.getBrokerOffer = function(id)
  parts.generation.rebuildContracts(false)
  return state.contracts[id] and deepcopy(state.contracts[id])
end
M.startBrokerContract = function(contract)
  if state.active then return false, "Finish the current car-hauling contract before collecting another." end
  -- Broker admission owns the skill gate; saved reservations remain collectable
  if not contract or contract.kind ~= "finkHaul" then return false, "Car-hauling work is locked." end
  return parts.acceptance.acceptCarHaul(deepcopy(contract))
end
M.cancelUnstartedBrokerContract = function(id)
  if not state.active or state.active.id ~= id then return true end
  for _, veh in ipairs(state.active.vehicles or {}) do
    if veh.status ~= "pending" then return false end
  end
  state.active = nil
  return true
end
M.isOwnerOpUnlocked = parts.catalog.ownerOpUnlocked
M.getOwnerOpHubFacilityIds = parts.acceptance.getOwnerOpHubFacilityIds
M.acceptContract = parts.escrow.acceptContract
M.abandonHubContract = parts.escrow.abandonHubContract
function M.onOverhaulMaterialContractAbandoned(contractId)
  if not state.active or state.active.nativeMaterialContractId ~= contractId then return end
  state.contracts[state.active.id] = nil
  state.active = nil
  ui_message("The owner-operator material order was abandoned.", 6, "info")
end
M.stageCarHaulTrip = parts.acceptance.stageCarHaulTrip
M.getActiveContract = parts.escrow.getActiveContract
M.rebuildContracts = function() parts.generation.rebuildContracts(true) end
M.spawnQueuedCarHaulOffers = parts.acceptance.spawnQueuedCarHaulOffers
M.consumeVehicleDropOffForContractEscrow = parts.escrow.consumeVehicleDropOffForContractEscrow
M.onCarHaulOfferAbandoned = parts.acceptance.onCarHaulOfferAbandoned

-- Game hooks
M.onUpdate = onUpdate
M.onCareerActivated = function()
end

-- The activity manifest is built last, once every public function above exists.
M.activity = require("overhaul/career/logistics/ownerOpContracts/activity")(M)

return M
