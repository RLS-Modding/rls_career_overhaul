-- Racing team: team vehicle formatting, vehicle jobs (accept, decline, abandon) and team vehicle sales.
-- Created by racingTeam.lua, which owns offer state access, lifecycle, saving, ticks and every M function.
local part = {}

local bindOperations = require("overhaul/career/business/racingTeam/racingTeam/bindOperations")

-- Config ------------------------------------------------------------------------------------------

local PENDING_TEAM_VEHICLE_SALE_TIMEOUT_SEC = 30 -- a stalled put-away must not lock the vehicle's sale forever
local FLEET_REPAIR_DEDUCTIBLE_DEFAULT = 750

-- Shared helpers ----------------------------------------------------------------------------------

local function isUnusableJobRef(businessId, jobId)
  if not businessId or jobId == nil or jobId == false or jobId == "" then return true end
  return type(jobId) == "number" and jobId == 0
end

local function findJobEntry(parts, entries, jobId)
  for index, entry in ipairs(entries) do
    if parts.board.jobIdsMatch(jobId, entry.jobId) then return index, entry end
  end
  return nil, nil
end

local function advanceRacingTeamGoals(rtState, businessId)
  rtState.rtInternal.advanceRacingTeamGoalsIfReady(businessId)
end

local function teamVehicleSaleKey(businessId, vehicleId)
  return tostring(businessId) .. "|" .. tostring(tonumber(vehicleId) or vehicleId)
end

local function isTeamVehicleSalePending(teamSales, saleKey)
  local startedAt = teamSales.pendingTeamVehicleSales[saleKey]
  if startedAt and (os.clock() - startedAt) < PENDING_TEAM_VEHICLE_SALE_TIMEOUT_SEC then
    return true
  end
  teamSales.pendingTeamVehicleSales[saleKey] = nil
  return false
end

local function getTeamVehicleSaleAccountId(rtState, businessId, salePrice)
  if salePrice <= 0 then return false end
  local businessAccount = overhaul_career_economy_bank.getBusinessAccount(rtState.businessType, businessId)
  return businessAccount and (businessAccount.id or businessAccount.accountId) or nil
end

local function creditTeamVehicleSale(sale)
  if not sale.accountId or sale.price <= 0 then return end
  overhaul_career_economy_bank.rewardToAccount({
    money = { amount = sale.price }
  }, sale.accountId, "Vehicle Sale", "Sold vehicle from racing team inventory", {category = "sale"})
end

local function removeActiveJobById(parts, state, jobId)
  local index = findJobEntry(parts, state.active or {}, jobId)
  if not index then return false end
  table.remove(state.active, index)
  return true
end

-- Puts the vehicle away when it is pulled out; returns true when a put-away was scheduled.
local function schedulePulledOutPutAway(inv, businessId, removeId, onPutAway)
  do
    local pulledVehicles = inv.getPulledOutVehicles(businessId) or {}
    for _, pulled in ipairs(pulledVehicles) do
      local pulledId = tonumber(pulled.vehicleId) or pulled.vehicleId
      if pulledId == removeId then
        inv.putAwayVehicle(businessId, removeId, onPutAway)
        return true
      end
    end
    return false
  end

  local getPulled = inv.getPulledOutVehicle
  local pulledOutVehicle = getPulled and getPulled(businessId)
  if pulledOutVehicle then
    local pulledId = tonumber(pulledOutVehicle.vehicleId) or pulledOutVehicle.vehicleId
    if pulledId == removeId then
      inv.putAwayVehicle(businessId, nil, onPutAway)
      return true
    end
  end
  return false
end

-- Vehicle formatting ------------------------------------------------------------------------------

local function vehicleConfigKeys(vehicle)
  local modelKey = vehicle.vehicleConfig and vehicle.vehicleConfig.model_key or nil
  local configKey = vehicle.vehicleConfig and (vehicle.vehicleConfig.key or vehicle.vehicleConfig.config_key) or nil
  return modelKey, configKey
end

local function spawnedVehicleIdFor(vehicle, businessId, vehicleId)
  local spawnedVehicleId = nil
  do
    spawnedVehicleId = overhaul_career_business_fleet.getSpawnedVehicleId(businessId, vehicleId)
  end
  if vehicle.spawnedVehicleId then spawnedVehicleId = vehicle.spawnedVehicleId end
  return spawnedVehicleId
end

-- Book and sell values fall back to the purchase price when the valuation fails.
local function teamVehicleValues(parts, vehicle, businessId, vehicleId)
  local vehicleValue, sellValue = 0, 0
  local okVal = pcall(function()
    vehicleValue = parts.fleet.getTeamVehicleBookValue(vehicle)
    local _, linkedJob = parts.results.findActiveVehicleJobByVehicleId(parts.helpers.getOfferState(businessId), vehicleId)
    local saleFallback = tonumber(linkedJob and linkedJob.reward) or 0
    sellValue = parts.fleet.getTeamVehicleSellValue(vehicle, saleFallback)
  end)
  if not okVal then
    vehicleValue = math.max(0, math.floor(tonumber(vehicle.purchasePrice) or 0))
    sellValue = vehicleValue
  end
  return vehicleValue, sellValue
end

local function fleetRepairStatus(businessId, vehicleId)
  local needsRepair, deductible = false, FLEET_REPAIR_DEDUCTIBLE_DEFAULT
  do
    local quote = overhaul_career_business_fleet.getFleetInsuranceRepairQuote(businessId, vehicleId)
    if quote then
      needsRepair = quote.needsRepair == true
      deductible = math.max(0, math.floor(tonumber(quote.deductible) or FLEET_REPAIR_DEDUCTIBLE_DEFAULT))
    end
  end
  return needsRepair, deductible
end

-- A live power reading wins; without one, the class and power saved on the vehicle keep the card readable.
local function resolveFleetClass(vehicle, pwEff)
  local effectivePw = nil
  if type(pwEff) == "number" and pwEff > 0 then
    effectivePw = math.floor(pwEff * 100 + 0.5) / 100
  end
  local label = nil
  if type(pwEff) == "number" and pwEff > 0 then
    local sanctioned = overhaul_events_fre_sanctionedRacing
    if sanctioned and sanctioned.getSanctionedPwBracketLabelForPw then
      label = sanctioned.getSanctionedPwBracketLabelForPw(pwEff)
    end
  end

  local prevSnap = type(vehicle.savedFleetClassUi) == "table" and vehicle.savedFleetClassUi or nil
  if type(effectivePw) == "number" and effectivePw > 0 and type(label) == "string" and label ~= "" then
    vehicle.savedFleetClassUi = { performancePw = effectivePw, label = label }
  elseif prevSnap then
    if (label == nil or label == "") and type(prevSnap.label) == "string" and prevSnap.label ~= "" then
      label = prevSnap.label
    end
    if (effectivePw == nil or effectivePw <= 0) and type(prevSnap.performancePw) == "number" and prevSnap.performancePw > 0 then
      effectivePw = prevSnap.performancePw
    end
  end

  local statusMessage = nil
  if (label == nil or label == "") and not (type(effectivePw) == "number" and effectivePw > 0) then
    statusMessage = "no weight found for config - pull out vehicle or open parts"
  end
  return effectivePw, label, statusMessage
end

local function formatVehicleForUI(deps, vehicle, businessId)
  if not vehicle then return nil end
  local parts = deps.parts
  local vehicleId = tonumber(vehicle.vehicleId) or vehicle.vehicleId
  local modelKey, configKey = vehicleConfigKeys(vehicle)
  local name, vehicleYear, vehicleType, vehicleImage =
    require("overhaul/lib/business/helpers").extractDisplayInfo(parts.fleet.getCatalogVehicleInfo(modelKey, configKey))
  local vehicleName = name or modelKey or ("Vehicle " .. tostring(vehicleId))
  local spawnedVehicleId = spawnedVehicleIdFor(vehicle, businessId, vehicleId)
  local vehicleValue, sellValue = teamVehicleValues(parts, vehicle, businessId, vehicleId)
  local fleetRepairNeeded, fleetRepairDeductible = fleetRepairStatus(businessId, vehicleId)

  local fleetEffectiveHp = nil
  local hpEff = parts.fleet.getEffectiveTeamJobVehicleHp(businessId, vehicle)
  if hpEff then fleetEffectiveHp = math.floor(tonumber(hpEff) + 0.5) end
  local pwEff = parts.fleet.getEffectiveTeamJobVehiclePw(businessId, vehicle)
  local fleetEffectivePw, fleetSanctionedClassLabel, fleetClassStatusMessage = resolveFleetClass(vehicle, pwEff)

  return {
    id = tostring(vehicleId),
    vehicleId = vehicleId,
    vehicleName = vehicleName,
    vehicleYear = vehicleYear,
    vehicleType = vehicleType,
    vehicleImage = vehicleImage,
    storedTime = vehicle.storedTime,
    spawnedVehicleId = spawnedVehicleId,
    model_key = modelKey,
    config_key = configKey,
    vehicleValue = vehicleValue,
    sellValue = sellValue,
    fleetRepairNeeded = fleetRepairNeeded,
    fleetRepairDeductible = fleetRepairDeductible,
    fleetEffectiveHp = fleetEffectiveHp,
    fleetEffectivePw = fleetEffectivePw,
    fleetSanctionedClassLabel = fleetSanctionedClassLabel,
    fleetClassStatusMessage = fleetClassStatusMessage,
  }
end

-- Listing and accepting jobs ----------------------------------------------------------------------

local function getActiveJobs(deps, businessId)
  local state = deps.parts.helpers.getOfferState(businessId)
  return state.active or {}
end

local function getNewJobs(deps, businessId)
  local state = deps.parts.helpers.getOfferState(businessId)
  return state.new or {}
end

local function payVehicleCost(rtState, businessId, vehicleCost)
  local businessAccount = overhaul_career_economy_bank.getBusinessAccount(rtState.businessType, businessId)
  local accountId = businessAccount and (businessAccount.id or businessAccount.accountId)
  if not accountId then return false end
  return overhaul_career_economy_bank.payFromAccount({
    money = {
      amount = vehicleCost,
      canBeNegative = false
    }
  }, accountId, "Vehicle Purchase", "Purchased vehicle for racing team", {category = "purchase"}) and true or false
end

local function storeAcceptedVehicle(businessId, job, vehicleCost)
  if not job.vehicleConfig then
    return
  end
  local okStore, storedVehicleId = overhaul_career_business_fleet.storeVehicle(businessId, {
    vehicleConfig = job.vehicleConfig,
    mileage = job.mileage or 0,
    purchasePrice = vehicleCost,
    storedTime = os.time()
  })
  if okStore and storedVehicleId ~= nil then
    job.storedVehicleId = storedVehicleId
  end
end

local function acceptJob(deps, businessId, jobId)
  if isUnusableJobRef(businessId, jobId) then return false end
  local parts = deps.parts
  local state = parts.helpers.getOfferState(businessId)
  if #(state.active or {}) >= parts.board.getMaxActiveJobs(businessId) then return false end

  local foundIndex, job = findJobEntry(parts, state.new or {}, jobId)
  if not foundIndex then return false end

  local vehicleCost = tonumber(job.reward) or 0
  if vehicleCost > 0 and not payVehicleCost(deps.rtState, businessId, vehicleCost) then return false end

  table.remove(state.new, foundIndex)
  job.status = "active"
  job.acceptedTime = os.time()
  table.insert(state.active, job)
  storeAcceptedVehicle(businessId, job, vehicleCost)
  overhaul_career_saveSystem.saveCurrent()
  advanceRacingTeamGoals(deps.rtState, businessId)
  return true
end

local function declineJob(deps, businessId, jobId)
  if isUnusableJobRef(businessId, jobId) then return false end
  local state = deps.parts.helpers.getOfferState(businessId)
  local foundIndex = findJobEntry(deps.parts, state.new or {}, jobId)
  if not foundIndex then return false end
  table.remove(state.new, foundIndex)
  overhaul_career_saveSystem.saveCurrent()
  return true
end

-- Pending team vehicle sales ----------------------------------------------------------------------


-- Credits the sale and clears the driver and the active job, once the put-away has finished.
local function finishAbandonJob(deps, sale)
  local parts = deps.parts
  deps.teamSales.pendingTeamVehicleSales[sale.saleKey] = nil
  if not sale.inv.removeVehicle(sale.businessId, sale.vehicleId) then
    return false
  end
  creditTeamVehicleSale(sale)

  parts.results.clearRacingTeamDriverAssignmentForJob(sale.businessId, sale.job.jobId)
  removeActiveJobById(parts, parts.helpers.getOfferState(sale.businessId), sale.job.jobId)
  if parts.board.getRacingTeamDriverCapacity(sale.businessId) >= 1 then
    parts.results.racingTeamPersistDrivers(sale.businessId)
  end
  overhaul_career_saveSystem.saveCurrent()
  advanceRacingTeamGoals(deps.rtState, sale.businessId)
  return true
end

local function findJobVehicle(parts, vehicles, jobId, job)
  for _, vehicle in ipairs(vehicles) do
    if job.storedVehicleId ~= nil and tonumber(vehicle.vehicleId) == tonumber(job.storedVehicleId) then
      return vehicle
    end
    if job.storedVehicleId == nil and parts.board.jobIdsMatch(jobId, vehicle.jobId) then
      return vehicle
    end
  end
  return nil
end

local function abandonJob(deps, businessId, jobId)
  if isUnusableJobRef(businessId, jobId) then return false end
  local parts = deps.parts
  local state = parts.helpers.getOfferState(businessId)
  local foundIndex, job = findJobEntry(parts, state.active or {}, jobId)
  if not foundIndex then return false end

  local vehicles = overhaul_career_business_fleet.getBusinessVehicles(businessId) or {}
  local vehicleToRemove = findJobVehicle(parts, vehicles, jobId, job)
  if not vehicleToRemove then return false end

  local saleFallback = tonumber(job.reward) or 0
  local salePrice = parts.fleet.getTeamVehicleSellValue(vehicleToRemove, saleFallback)
  local accountId = getTeamVehicleSaleAccountId(deps.rtState, businessId, salePrice)
  if accountId == nil then return false end

  local removeId = tonumber(vehicleToRemove.vehicleId) or vehicleToRemove.vehicleId
  local saleKey = teamVehicleSaleKey(businessId, removeId)
  if isTeamVehicleSalePending(deps.teamSales, saleKey) then return false end
  deps.teamSales.pendingTeamVehicleSales[saleKey] = os.clock()

  local sale = {
    businessId = businessId,
    job = job,
    vehicleId = vehicleToRemove.vehicleId,
    saleKey = saleKey,
    accountId = accountId,
    price = salePrice,
    inv = overhaul_career_business_fleet,
  }
  -- The async put-away may replace state.active, so the job is looked up again when it finishes.
  local scheduledPutAway = schedulePulledOutPutAway(sale.inv, businessId, removeId, function(ok)
    if ok == false then
      deps.teamSales.pendingTeamVehicleSales[sale.saleKey] = nil
      ui_message("Could not put away the team vehicle. The job has not been abandoned. Please try again.", 10, "business")
      return
    end
    finishAbandonJob(deps, sale)
  end)
  if not scheduledPutAway then return finishAbandonJob(deps, sale) end
  return true
end

-- Credits the sale and clears any active job still linked to the vehicle, once the put-away has finished.
local function finishSellVehicle(deps, sale)
  local parts = deps.parts
  deps.teamSales.pendingTeamVehicleSales[sale.saleKey] = nil
  if not sale.inv.removeVehicle(sale.businessId, sale.vehicleId) then
    return false
  end
  creditTeamVehicleSale(sale)

  local _, currentLinkedJob = parts.results.findActiveVehicleJobByVehicleId(parts.helpers.getOfferState(sale.businessId), sale.vehicleId)
  if currentLinkedJob then
    parts.results.clearRacingTeamDriverAssignmentForJob(sale.businessId, currentLinkedJob.jobId)
    removeActiveJobById(parts, parts.helpers.getOfferState(sale.businessId), currentLinkedJob.jobId)
    if parts.board.getRacingTeamDriverCapacity(sale.businessId) >= 1 then
      parts.results.racingTeamPersistDrivers(sale.businessId)
    end
  end

  overhaul_career_saveSystem.saveCurrent()
  advanceRacingTeamGoals(deps.rtState, sale.businessId)
  return true
end

local function sellVehicle(deps, businessId, vehicleId)
  if not businessId or vehicleId == nil or vehicleId == false or vehicleId == "" then return false end
  local parts = deps.parts
  local state = parts.helpers.getOfferState(businessId)
  local removeId = tonumber(vehicleId) or vehicleId
  local vehicleToRemove = overhaul_career_business_fleet.getVehicleById
    and overhaul_career_business_fleet.getVehicleById(businessId, removeId)
    or nil
  if not vehicleToRemove then return false end

  local _, linkedJob = parts.results.findActiveVehicleJobByVehicleId(state, removeId)
  local saleFallback = tonumber(linkedJob and linkedJob.reward) or 0
  local salePrice = parts.fleet.getTeamVehicleSellValue(vehicleToRemove, saleFallback)
  local accountId = getTeamVehicleSaleAccountId(deps.rtState, businessId, salePrice)
  if accountId == nil then return false end

  local saleKey = teamVehicleSaleKey(businessId, removeId)
  if isTeamVehicleSalePending(deps.teamSales, saleKey) then return false end
  deps.teamSales.pendingTeamVehicleSales[saleKey] = os.clock()

  local sale = {
    businessId = businessId,
    vehicleId = removeId,
    saleKey = saleKey,
    accountId = accountId,
    price = salePrice,
    inv = overhaul_career_business_fleet,
  }
  local scheduledPutAway = schedulePulledOutPutAway(sale.inv, businessId, removeId, function(ok)
    if ok == false then
      deps.teamSales.pendingTeamVehicleSales[sale.saleKey] = nil
      ui_message("Could not put away the team vehicle. The sale has not been completed. Please try again.", 10, "business")
      return
    end
    finishSellVehicle(deps, sale)
  end)
  if not scheduledPutAway then return finishSellVehicle(deps, sale) end
  return true
end

-- Public API --------------------------------------------------------------------------------------


function part.new(inputs)
  local deps = {
    parts = inputs.parts,
    rtState = inputs.rtState,
    teamSales = inputs.teamSales,
  }
  inputs.rtState.formatVehicleForUI = function(vehicle, businessId)
    return formatVehicleForUI(deps, vehicle, businessId)
  end

  local api = bindOperations(deps, {
    abandonJob = abandonJob,
    acceptJob = acceptJob,
    declineJob = declineJob,
    getActiveJobs = getActiveJobs,
    getNewJobs = getNewJobs,
    sellVehicle = sellVehicle,
  })
  return api
end

return part
